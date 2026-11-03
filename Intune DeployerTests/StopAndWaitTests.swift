import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Intune_Deployer

// Waits before a retry are shown with Stop (JTKit's RequestWaits), and a
// stopped run says so in one plain sentence.

private let tenantA = "aaaaaaaa-0000-4000-8000-00000000000a"

/// A made-up access token for a tenant (only its `tid` claim is read).
private func token(tid: String) -> String {
    func encode(_ object: [String: Any]) -> String {
        (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    return "\(encode(["alg": "none"])).\(encode(["tid": tid])).sig"
}

@MainActor
private func session(_ server: MockServer) -> TenantSession {
    let savedTenantGuard = TestRun.AttemptLog(fileURL: FileManager.default.temporaryDirectory
        .appending(path: "IntuneDeployerTests-guard-\(UUID().uuidString).jsonl"))
    return TenantSession(auth: AuthManager(underTest: .refuseAll(savedTenantGuard)), activityLog: ActivityLog(),
                         realTenantSession: server.session, tokenProvider: { _, _, _ in token(tid: tenantA) })
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<250 where !condition() {
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite("Retry waits and Stop")
struct StopAndWaitTests {
    @Test("A stop is said in one plain sentence, never as Swift's cancellation text")
    func stopSentence() {
        #expect(Stopping.isStop(CancellationError()))
        #expect(Stopping.isStop(URLError(.cancelled)))
        #expect(!Stopping.isStop(URLError(.timedOut)))
        #expect(Stopping.describe(CancellationError()) == "Stopped before it finished.")
    }

    @MainActor
    @Test("A wait before a retry shows with Stop; Stop ends the Apply and nothing after it is sent")
    func stopDuringApply() async throws {
        let root = try Fixtures.makeTree(files: ["scripts/one.sh": "#!/bin/zsh\necho 1\n", "scripts/two.sh": "#!/bin/zsh\necho 2\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SourceStore(folder: FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-stop-\(UUID().uuidString)"))
        store.addLocalFolder(at: root)
        try await waitUntil { store.items(for: Set(store.sources.map(\.id))).count == 2 && store.scanningSourceIDs.isEmpty }
        let items = store.items(for: Set(store.sources.map(\.id)))
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = Set(items.map(\.id))

        // Every create is asked to wait a minute.
        let server = MockServer { request in
            if request.method == "GET" {
                return request.path.hasSuffix("/me") ? .json(200, #"{"id":"me"}"#) : .json(200, #"{"value":[]}"#)
            }
            return .json(429, #"{"error":{"code":"TooManyRequests","message":"Slow down"}}"#, headers: ["Retry-After": "60"])
        }
        let session = session(server)
        await session.plan(profile: profile, items: items, sourceStore: store)
        let plan = try #require(session.currentPlan, "\(session.planError ?? "")")
        #expect(plan.actions.count == 2)

        let apply = Task { await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: items, sourceStore: store) }
        try await waitUntil { session.waits.statusText != nil }
        #expect(session.waits.statusText?.contains("Microsoft asked to wait") == true)
        session.waits.cancelAll()
        await apply.value

        #expect(server.requests.filter { $0.method == "POST" }.count == 1, "the second create isn't sent")
        let results = try #require(session.applyResults)
        #expect(results.contains { $0.title.hasPrefix("Create") && $0.outcome == .stopped(Stopping.sentence) }, "a create waits only after a 429: it was never done")
        #expect(results.last?.outcome == .skipped(Stopping.rest))
        #expect(!results.contains { $0.isFailure })
        #expect(session.waits.statusText == nil)
    }

    /// A shell script object in the tenant, tagged by `profile`.
    private static func taggedScript(_ id: String, shortID: String, profile: TenantProfile) -> String {
        #"{"id":"\#(id)","displayName":"Script \#(id)","fileName":"s.sh","scriptContent":"ZWNobw==","description":"\#(ItemIdentity.tag(forShortID: shortID, profileID: profile.id))"}"#
    }

    @MainActor
    @Test("Stop during the wait before an update is sent again: the update may have been carried out, and the report says so")
    func stopDuringUpdateRetry() async throws {
        let profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        var plan = Plan()
        plan.profileID = profile.id
        plan.tenantID = tenantA
        plan.actions = ["obj-1", "obj-2"].map { id in
            PlanItemAction(id: "0a0b0c0\(id.last!)", collection: .shellScripts, displayName: "Script \(id)",
                           kind: .update([FieldChange(path: "scriptContent", oldValue: "a", newValue: "b")]),
                           payload: Data(#"{"displayName":"Script"}"#.utf8), existingObjectID: id, assignments: nil, warnings: [])
        }
        // Graph answers the update with a server error, which it can send after making the change.
        let server = MockServer { request in
            request.method == "GET" ? .json(200, #"{"id":"me"}"#) : .json(503, #"{"error":{"code":"ServiceUnavailable","message":"Busy"}}"#, headers: ["Retry-After": "60"])
        }
        let session = session(server)
        let store = SourceStore(folder: FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-stop-\(UUID().uuidString)"))
        let apply = Task { await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: store) }
        try await waitUntil { session.waits.statusText != nil }
        session.waits.cancelAll()
        await apply.value

        #expect(server.requests.filter { $0.method == "PATCH" }.count == 1, "the second update isn't sent")
        let results = try #require(session.applyResults)
        #expect(results.first { $0.title.hasPrefix("Update") }?.outcome == .stopped(Stopping.mayHaveBeenDone))
        #expect(results.last?.outcome == .skipped(Stopping.rest))
        #expect(ApplyResult.summary(results).contains("1 stopped"))
        let report = AsBuiltReport.markdown(AsBuiltReport.Input(profileName: "Lab", tenantID: tenantA, namingPrefix: "", plan: plan,
                                                                results: results, date: .now))
        #expect(report.contains("| Update Script obj-1 | Stopped; this change may already have been carried out. Run Plan again. |"))
        #expect(!report.contains("Skipped: Stopped;"))
    }

    @MainActor
    @Test("Stop during Remove Baseline: nothing is deleted after it, the groups step is skipped, and a closing line says so")
    func stopDuringRemoveBaseline() async throws {
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.assignments["0a0b0c01"] = AssignmentIntent(targets: [AssignmentTarget(kind: .include, scope: .group, groupName: "Pilots")])
        let scripts = "{\"value\":[\(Self.taggedScript("obj-1", shortID: "0a0b0c01", profile: profile)),\(Self.taggedScript("obj-2", shortID: "0a0b0c02", profile: profile))]}"
        let server = MockServer { request in
            if request.method == "DELETE" {
                return .json(503, #"{"error":{"code":"ServiceUnavailable","message":"Busy"}}"#, headers: ["Retry-After": "60"])
            }
            if request.path.hasSuffix("/deviceShellScripts") { return .json(200, scripts) }
            return .json(200, #"{"value":[]}"#)
        }
        let session = session(server)
        let removal = Task { await session.removeBaseline(profile: profile) }
        try await waitUntil { session.waits.statusText != nil }
        session.waits.cancelAll()
        _ = await removal.value

        #expect(server.requests.filter { $0.method == "DELETE" }.count == 1, "nothing is deleted after the stop")
        #expect(!server.requests.contains { $0.path.contains("/groups") }, "the groups step is skipped")
        let results = try #require(session.applyResults)
        #expect(results.contains { $0.title.hasPrefix("Delete") && $0.outcome == .stopped(Stopping.mayHaveBeenDone) })
        #expect(results.last?.title == "Remove Baseline")
        #expect(results.last?.outcome == .skipped("Stopped. The remaining objects weren’t deleted."))
    }

    @MainActor
    @Test("Stop during a Plan's assignment read ends the Plan instead of planning without the answer")
    func stopDuringPlanRead() async throws {
        let root = try Fixtures.makeTree(files: ["scripts/one.sh": "#!/bin/zsh\necho 1\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SourceStore(folder: FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-stop-\(UUID().uuidString)"))
        store.addLocalFolder(at: root)
        try await waitUntil { store.items(for: Set(store.sources.map(\.id))).count == 1 && store.scanningSourceIDs.isEmpty }
        let item = try #require(store.items(for: Set(store.sources.map(\.id))).first)
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [item.id]
        let script = Self.taggedScript("obj-1", shortID: item.id, profile: profile)
        let server = MockServer { request in
            let path = request.path
            if path.hasSuffix("/assignments") {
                return .json(429, #"{"error":{"code":"TooManyRequests","message":"Slow down"}}"#, headers: ["Retry-After": "60"])
            }
            if path.hasSuffix("/deviceShellScripts") { return .json(200, "{\"value\":[\(script)]}") }
            if path.hasSuffix("/deviceShellScripts/obj-1") { return .json(200, script) }
            return .json(200, #"{"value":[]}"#)
        }
        let session = session(server)
        let plan = Task { await session.plan(profile: profile, items: [item], sourceStore: store) }
        try await waitUntil { session.waits.statusText != nil }
        session.waits.cancelAll()
        await plan.value
        #expect(session.currentPlan == nil)
        #expect(session.planError == Stopping.sentence)
    }

    @MainActor
    @Test("The tenant's setting IDs are read once per session and tenant, again after the tenant in use changes")
    func settingIDsReadOnce() async throws {
        let root = try Fixtures.makeTree(files: ["catalog/caching.json": Fixtures.settingsCatalogJSON])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SourceStore(folder: FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-ids-\(UUID().uuidString)"))
        store.addLocalFolder(at: root)
        try await waitUntil { store.items(for: Set(store.sources.map(\.id))).count == 1 && store.scanningSourceIDs.isEmpty }
        let items = store.items(for: Set(store.sources.map(\.id)))
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = Set(items.map(\.id))
        let ids = #"{"value":[{"id":"com.apple.applicationaccess_com.apple.applicationaccess"},{"id":"com.apple.applicationaccess_allowcontentcaching"}]}"#
        let server = MockServer { request in
            request.url.absoluteString.contains("configurationSettings?") ? .json(200, ids) : .json(200, #"{"value":[]}"#)
        }
        let session = session(server)
        func reads() -> Int { server.requests.count { $0.url.absoluteString.contains("configurationSettings?") } }
        await session.plan(profile: profile, items: items, sourceStore: store)
        #expect(session.currentPlan?.hasErrors == false, "\(session.planError ?? "") \(session.currentPlan?.issues.map(\.message) ?? [])")
        await session.plan(profile: profile, items: items, sourceStore: store)
        #expect(reads() == 1, "read once for both Plans")
        session.reset()
        await session.plan(profile: profile, items: items, sourceStore: store)
        #expect(reads() == 2, "read again after the tenant in use changed")
    }

    @MainActor
    @Test("A tenant sheet clears the open-sheet flag only while the flag still names it")
    func sheetFlag() {
        let session = session(MockServer { _ in .json(200, "{}") })
        session.sheetAppeared(.plan)
        #expect(session.locksTenant)
        // Remove Baseline opens right after the Plan closed, before the Plan's disappearing arrives
        session.sheetAppeared(.removeBaseline)
        session.sheetDisappeared(.plan)
        #expect(session.presentedSheet == .removeBaseline, "the open sheet is still known")
        #expect(session.locksTenant)
        session.sheetDisappeared(.removeBaseline)
        #expect(session.presentedSheet == nil)
        #expect(!session.locksTenant)
    }
}
