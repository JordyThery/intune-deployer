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
        #expect(results.contains { $0.title.hasPrefix("Create") && $0.outcome == .skipped(Stopping.sentence) })
        #expect(results.last?.outcome == .skipped(Stopping.rest))
        #expect(!results.contains { $0.isFailure })
        #expect(session.waits.statusText == nil)
    }
}
