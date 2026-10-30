import Foundation
import JTKit
import JTKitLiveCheck
import JTKitMSAL
import Testing
@testable import Intune_Deployer

// The release check's live checks (JTKit ROADMAP step 11), on the Intune test
// tenant only (role intune-test, "create and remove"). Skipped unless the
// release check switches them on (`JTKIT_LIVE=1`), so ⌘U never reaches a
// tenant. Decided by Jordy on 2026-10-30:
// - Sign-in: the saved Microsoft sign-in of the one saved profile whose
//   tenant ID is intune-test's, matched strictly; tokens from MSAL's cache
//   only. When MSAL needs its window, the run stops and says so. Every other
//   saved tenant gets no request at all (`UnderTest`, `SavedTenantGuard`).
// - A small `JTKTEST` baseline (a filter, a shell script, a custom attribute,
//   a Settings Catalog policy, a compliance policy; no app), applied with the
//   app's own Plan and Apply, read back, a second Plan with nothing to do,
//   one update, then removed with the app's own deletion path (orphans
//   ticked in a Plan), only objects this run created.
// - Assignments only to one empty `JTKTEST` group the run creates, 0 members
//   checked before anything is assigned; never All devices, All users or an
//   existing group (also refused by JTKit's guarded network, 0.12.5).
// - Old `[AUTOTEST]` objects are swept once (legacy prefix, by identity tag).
// - No device actions of any kind.
// The app's Plan and Apply run behind a fence that lets only the requests of
// each step through; the test code reads back and removes through JTKit's
// guarded network. Nothing is written to the app's real files or settings.

private let live = LiveCheckRun.isEnabled

#if JTKIT_FAULT_BREAK_BUILD
#error("Broken on purpose: release check --fault break-build")
#endif

private enum Role {
    static let intune = "intune-test"
}

private struct LiveFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Permissions for everything a run does: the app's Plan and Apply, and the
/// test code's group (create, members, delete, permanent delete).
private let liveScopes = GraphScopes.applyScopes(allowGroupCreation: true)

/// "MISSING PERMISSION" for 401/403, the error otherwise; no tenant name.
private func failure(_ error: any Error) -> String {
    if let graph = error as? GraphError, let status = graph.status, status == 401 || status == 403 {
        return "MISSING PERMISSION (\(status)): \(graph.localizedDescription)"
    }
    if (error as? MicrosoftSignInError) == .interactionRequired {
        return "Microsoft needs you: open Intune Deployer, choose the intune-test tenant and sign in once (an Apply there also grants the write permissions); then run the release check again"
    }
    return error.localizedDescription
}

private func status(of error: any Error) -> Int? {
    (error as? GraphError)?.status
}

/// A read of a removed object: 404, or for Settings Catalog policies 400
/// with the code "ResourceNotFound" (seen on 2026-10-30).
private func isGone(_ error: any Error) -> Bool {
    guard let graph = error as? GraphError else { return false }
    if graph.status == 404 { return true }
    if case .status(400, let body, _, _, _) = graph.kind { return body?.code == "ResourceNotFound" }
    return false
}

/// No attempt to reach a saved tenant or GitHub under tests so far (the
/// unit tests, the smoke tests and this run share the attempts file).
@MainActor
private func checkNoSavedTenantRequests(_ run: LiveCheckRun, when: String) {
    let attempts = SavedTenantGuard.shared.attempts()
    run.record(step: "no request to a saved tenant or GitHub under tests (\(when))", passed: attempts.isEmpty,
               note: attempts.isEmpty ? nil : "\(attempts.count) refused: \(attempts.map(\.what).joined(separator: "; "))")
    #expect(attempts.isEmpty, "\(attempts.map(\.what))")
}

// MARK: - The tenant

/// intune-test, as the live checks reach it: an in-memory profile with the
/// client ID and account of the saved profile of that tenant ID, the app's
/// sign-in for that one tenant, and a Graph client for the test code on
/// JTKit's guarded network.
@MainActor
private struct LiveTenant {
    let run: LiveCheckRun
    let tenantID: String
    let profile: TenantProfile
    let auth: AuthManager
    let log = ActivityLog()
    /// The test code's client: creates the group, reads back, removes.
    let api: Graph.Client

    init(_ run: LiveCheckRun) throws {
        self.run = run
        let entry = try run.entry(role: Role.intune, service: .intune)
        guard let tenantID = entry.entraTenantID?.lowercased(), UUID(uuidString: tenantID) != nil else {
            throw LiveFailure("\(Role.intune): the allow-list has no Entra tenant ID")
        }
        self.tenantID = tenantID
        // The saved profiles, read only (never through the app's store,
        // which may save).
        let file = JSONFileConnectionStorage<TenantProfile>(fileURL: UnderTest.realDataFolder.appending(path: "tenants.json"))
        let matches = try file.load().filter { $0.tenantID.trimmingCharacters(in: .whitespaces).lowercased() == tenantID }
        guard matches.count == 1, let saved = matches.first else {
            throw LiveFailure("\(Role.intune): \(matches.count) saved Intune Deployer tenants have its tenant ID (needs exactly 1)")
        }
        guard saved.hasValidClientID else { throw LiveFailure("\(Role.intune): the saved tenant has no valid client ID") }
        profile = TenantProfile(displayName: Role.intune, clientID: saved.clientID, tenantID: tenantID,
                                namingPrefix: run.prefix, accountIdentifier: saved.accountIdentifier)
        auth = AuthManager(underTest: .liveCheck(tenantID: tenantID, guard: .shared))
        auth.restoreAccount(for: profile)
        guard auth.isSignedIn(profile) else {
            throw LiveFailure("\(Role.intune): MSAL has no signed-in account of exactly this tenant: open Intune Deployer, choose that tenant and sign in once")
        }
        api = TenantSession(auth: auth, activityLog: log, realTenantSession: run.network.session)
            .client(for: profile, scopes: liveScopes)
    }

    /// The app's session, on `network` (a fence over the guarded network).
    func session(on network: URLSession) -> TenantSession {
        TenantSession(auth: auth, activityLog: log, realTenantSession: network)
    }

    var target: String { "intune:\(tenantID)" }

    /// This run's objects in the ledger (not the sweep's, not removed).
    func runObjects() -> [Ledger.Item] {
        run.ledger.items.filter { $0.target == target && !$0.fromSweep && !$0.removed }
    }
}

// MARK: - The fence

/// The app's network during a live step: only the requests the step needs
/// go on to JTKit's guarded network; anything else is refused before it's
/// sent and stops the check. Writes are counted.
private nonisolated final class Fence: @unchecked Sendable {
    nonisolated struct Rule: Sendable {
        var name: String
        var allows: @Sendable (_ method: String, _ path: String) -> Bool
    }

    let inner: URLSession
    private(set) var session: URLSession!
    private let lock = NSLock()
    private var rule = Rule(name: "reads only") { method, _ in method == "GET" || method == "HEAD" }
    private var writesStorage: [String] = []
    private var refusalsStorage: [String] = []

    init(inner: URLSession) {
        self.inner = inner
        let id = UUID().uuidString
        FenceProtocol.register(self, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FenceProtocol.self]
        configuration.httpAdditionalHeaders = [FenceProtocol.header: id]
        session = URLSession(configuration: configuration)
    }

    func set(_ rule: Rule) { lock.withLock { self.rule = rule } }
    var writes: [String] { lock.withLock { writesStorage } }
    var refusals: [String] { lock.withLock { refusalsStorage } }

    /// Whether a request may go on; records writes and refusals.
    func admit(method: String, path: String) -> Bool {
        lock.withLock {
            let isRead = method == "GET" || method == "HEAD"
            guard rule.allows(method, path) else {
                refusalsStorage.append("\(method) \(path) (\(rule.name))")
                return false
            }
            if !isRead { writesStorage.append("\(method) \(path)") }
            return true
        }
    }

    // Graph paths: /<version>/<collection path>/<id>[/<action>]
    static func segments(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }
    static func isID(_ segment: String) -> Bool { UUID(uuidString: segment) != nil }
    static func isRead(_ method: String) -> Bool { method == "GET" || method == "HEAD" }
    /// A create: a POST to a collection (no ID in the path), never a group.
    static func isCreate(_ method: String, _ path: String) -> Bool {
        method == "POST" && !segments(path).contains(where: isID) && segments(path).contains("deviceManagement")
    }
    static func isAssign(_ method: String, _ path: String) -> Bool {
        let parts = segments(path)
        return method == "POST" && parts.last == "assign" && parts.count >= 2 && isID(parts[parts.count - 2])
    }
}

private nonisolated final class FenceProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-JTKTEST-Fence"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fences: [String: Fence] = [:]
    private var upstreamTask: URLSessionDataTask?

    static func register(_ fence: Fence, id: String) { lock.withLock { fences[id] = fence } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.header), let fence = Self.lock.withLock({ Self.fences[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path(percentEncoded: false) ?? ""
        guard fence.admit(method: method, path: path) else {
            client?.urlProtocol(self, didFailWithError: LiveFailure("The live check's fence refused \(method) \(path)"))
            return
        }
        var outgoing = request
        outgoing.setValue(nil, forHTTPHeaderField: Self.header)
        if outgoing.httpBody == nil, let stream = request.httpBodyStream {
            let body = Self.read(stream)
            // Clearing the stream also clears the body: clear it first.
            outgoing.httpBodyStream = nil
            outgoing.httpBody = body
        }
        let task = fence.inner.dataTask(with: outgoing) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            self.client?.urlProtocol(self, didLoad: data ?? Data())
            self.client?.urlProtocolDidFinishLoading(self)
        }
        upstreamTask = task
        task.resume()
    }

    override func stopLoading() { upstreamTask?.cancel() }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: - Removal (the test code)

/// The collection path and version of a ledger resource.
private func location(of resource: String) -> (path: String, version: Graph.Version)? {
    func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
    if normalized(resource) == "groups" { return ("groups", .v1) }
    for collection in TenantCollection.allCases
    where normalized(collection.listPath.split(separator: "/").last.map(String.init) ?? "") == normalized(resource) {
        return (collection.listPath, collection.version)
    }
    return nil
}

/// Removes the ledger's outstanding objects of this tenant (assigned objects
/// first, filters next, groups last); a 404 counts as gone, a group's
/// dependants are retried for two minutes. Returns what couldn't be removed.
@MainActor
private func removeOutstanding(_ tenant: LiveTenant) async -> [String] {
    func rank(_ item: Ledger.Item) -> Int {
        switch item.resource {
        case "groups": 2
        case "assignmentfilters": 1
        default: 0
        }
    }
    var problems: [String] = []
    let items = tenant.run.ledger.outstanding.filter { $0.target == tenant.target }.sorted { rank($0) < rank($1) }
    for item in items {
        guard let location = location(of: item.resource) else {
            problems.append("\(item.resource) \(item.id): unknown kind of object")
            continue
        }
        var removed = false
        for attempt in 0..<8 where !removed {
            do {
                try await tenant.api.delete("\(location.path)/\(item.id)", version: location.version)
                removed = true
            } catch where status(of: error) == 404 {
                tenant.run.ledger.markRemoved(target: item.target, resource: item.resource, id: item.id)
                removed = true
            } catch {
                if attempt == 7 { problems.append("\(item.resource) “\(item.name)”: \(failure(error))") }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
    return problems
}

/// Empties Entra's recycle bin of the groups this run created and removed
/// (JTKit refuses any other permanent delete). Each emptied group is noted
/// in the run folder, so the cleanup doesn't look for it again.
@MainActor
private func purgeDeletedGroups(_ tenant: LiveTenant) async -> (purged: Int, problems: [String]) {
    let noted = tenant.run.runFolder.appending(path: "purged-groups.txt")
    var purgedIDs = Set(((try? String(contentsOf: noted, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    var purged = 0
    var problems: [String] = []
    let groups = tenant.run.ledger.items.filter {
        $0.target == tenant.target && $0.resource == "groups" && !$0.fromSweep && $0.removed && !purgedIDs.contains($0.id.lowercased())
    }
    for group in groups {
        var done = false, failed = false
        // A deleted group can take a moment to appear in the recycle bin.
        for _ in 0..<10 where !done && !failed {
            do {
                try await tenant.api.delete("directory/deletedItems/\(group.id)", version: .v1)
                done = true
            } catch where status(of: error) == 404 {
                try? await Task.sleep(for: .seconds(3))
            } catch {
                problems.append("group “\(group.name)”: \(failure(error))")
                failed = true
            }
        }
        if done {
            purged += 1
            purgedIDs.insert(group.id.lowercased())
            try? Data(purgedIDs.sorted().joined(separator: "\n").utf8).write(to: noted, options: .atomic)
        } else if !failed {
            problems.append("group “\(group.name)”: not found in Entra's recycle bin after 30 seconds")
        }
    }
    return (purged, problems)
}

// MARK: - The test host's Keychain item names

@Suite("Live: Keychain item names seen by the test host", .enabled(if: live), .serialized)
struct LiveHostKeychainTests {
    /// MSAL's sign-in cache (every item in its own access group, which only
    /// the app can see) and the GitHub token: names only, as hashes; never a value.
    @Test func recordNames() throws {
        let run = try LiveCheckRun.current()
        let lines = try run.recordHostKeychainNames(services: ["be.jordythery.intune-deployer.github"],
                                                    accessGroups: ["com.microsoft.identity.universalstorage"])
        run.record(step: "Keychain item names seen by the test host (\(run.hostKeychainLabel ?? "?"))", passed: true,
                   note: "\(lines.count) items, hashes only")
    }
}

// MARK: - Stage 1: sign in

@MainActor
@Suite("Live: sign in", .enabled(if: live), .serialized)
struct LiveSignInTests {
    @Test func signInAndRead() async throws {
        let run = try LiveCheckRun.current()
        checkNoSavedTenantRequests(run, when: "start")
        let step = "sign in: \(Role.intune) (the saved Microsoft sign-in, MSAL's cache only)"
        do {
            let tenant = try LiveTenant(run)
            // Every permission the run needs, now, so a missing consent stops
            // the run before anything exists.
            _ = try await tenant.auth.accessToken(profile: tenant.profile, scopes: liveScopes)
            nonisolated struct Organization: Decodable, Sendable { let id: String }
            let organization = try await tenant.api.get(Organization.self, "organization/\(tenant.tenantID)?$select=id", version: .v1)
            guard organization.id.lowercased() == tenant.tenantID else { throw LiveFailure("the organization read answered another tenant") }
            let leftovers = try await countLeftovers(tenant)
            run.record(step: step, passed: true,
                       note: "token tenant checked on every request; JTKTEST objects: \(leftovers.test), [AUTOTEST] objects: \(leftovers.legacy)")
        } catch {
            run.record(step: step, passed: false, note: failure(error))
            throw error
        }
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }

    /// Objects named as test objects, counted (read only).
    private func countLeftovers(_ tenant: LiveTenant) async throws -> (test: Int, legacy: Int) {
        var test = 0, legacy = 0
        for collection in TenantCollection.allCases {
            for body in try await tenant.api.listRaw(collection.listPath, version: collection.version) {
                let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let name = object["displayName"] as? String ?? object["name"] as? String ?? ""
                if name.hasPrefix(LiveCheckRun.testPrefix + " ") { test += 1 }
                if name.hasPrefix("[AUTOTEST]") { legacy += 1 }
            }
        }
        let filter = "startswith(displayName,'\(LiveCheckRun.testPrefix) ')".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        test += try await tenant.api.listRaw("groups?$filter=\(filter)&$select=id", version: .v1).count
        return (test, legacy)
    }
}

// MARK: - Stage 4: the lifecycle

@MainActor
@Suite("Live: baseline lifecycle", .enabled(if: live), .serialized)
struct LiveLifecycleTests {
    /// While bug 1 (assignments are never compared) isn't fixed, an Apply of
    /// an unchanged baseline sends every assignment again. Once it's fixed,
    /// set this to false: the second Apply must then send nothing.
    static let resendsAssignmentsUntilBug1IsFixed = true

    @Test func baseline() async throws {
        let run = try LiveCheckRun.current()
        checkNoSavedTenantRequests(run, when: "before the lifecycle")
        if run.fault == "saved-tenant-attempt" {
            // The app's own sign-in, as the app makes it under tests, asked for
            // the saved tenant: refused before MSAL and written down.
            let saved = try LiveTenant(run).profile
            _ = try? await AuthManager().accessToken(profile: saved, scopes: GraphScopes.tenantRead)
            checkNoSavedTenantRequests(run, when: "saved-tenant-attempt (--fault)")
            throw LiveFailure("saved-tenant-attempt: a request to a saved tenant was attempted under tests")
        }

        let tenant = try LiveTenant(run)
        let fence = Fence(inner: run.network.session)
        let session = tenant.session(on: fence.session)

        func step(_ name: String) -> String { "\(Role.intune): \(name)" }
        func require(_ name: String, _ passed: Bool, note: String? = nil) throws {
            run.record(step: step(name), passed: passed, note: note)
            if !passed { throw LiveFailure("\(step(name)): \(note ?? "failed")") }
        }
        func attempt<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
            do { return try await body() } catch {
                run.record(step: step(name), passed: false, note: failure(error))
                throw error
            }
        }
        func applyFailures() -> [String] {
            (session.applyResults ?? []).compactMap { result in
                switch result.outcome {
                case .success: nil
                case .failure(let message): "\(result.title): \(message)"
                case .skipped(let message): "\(result.title) skipped: \(message)"
                }
            }
        }

        // 1. One empty JTKTEST group, made by the test code; 0 members.
        let groupName = "\(run.prefix) – Group"
        let groupID = try await attempt("create the empty test group") {
            let body: [String: Any] = [
                "displayName": groupName, "description": "JTKit release check: empty test group, removed by the run",
                "mailEnabled": false, "mailNickname": "jtktest\(UUID().uuidString.prefix(8).lowercased())",
                "securityEnabled": true, "groupTypes": [] as [String],
            ]
            let response = try await tenant.api.post("groups", version: .v1, body: try JSONSerialization.data(withJSONObject: body))
            guard let id = ((try? JSONSerialization.jsonObject(with: response)) as? [String: Any])?["id"] as? String else {
                throw LiveFailure("the group create returned no ID")
            }
            return id.lowercased()
        }
        func checkGroupEmpty(_ when: String) async throws {
            let members = try await attempt("the test group has no members (\(when))") {
                try await tenant.api.listRaw("groups/\(groupID)/transitiveMembers?$select=id", version: .v1)
            }
            let group = try await attempt("read the test group (\(when))") {
                try await tenant.api.getRaw("groups/\(groupID)?$select=id,displayName,groupTypes,membershipRule", version: .v1)
            }
            let object = (try? JSONSerialization.jsonObject(with: group)) as? [String: Any] ?? [:]
            let rule = object["membershipRule"]
            let isStatic = ((object["groupTypes"] as? [String]) ?? []).isEmpty && (rule == nil || rule is NSNull)
            try require("the test group is static with 0 members (\(when))", members.isEmpty && isStatic,
                        note: "\(isStatic ? "static" : "dynamic"), \(members.count) members")
        }
        try await checkGroupEmpty("before anything is assigned")

        // Plan finds groups by name: wait until the new group is listed.
        let filter = "displayName eq '\(groupName)'".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var listed = false
        for _ in 0..<40 where !listed {
            listed = ((try? await tenant.api.listRaw("groups?$filter=\(filter)&$select=id", version: .v1)) ?? [])
                .compactMap { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["id"] as? String }
                .map { $0.lowercased() } == [groupID]
            if !listed { try await Task.sleep(for: .seconds(3)) }
        }
        try require("the test group is found by its name, and only it", listed)

        // 2. The baseline: five files in a temporary folder.
        let root = try Fixtures.makeTree(files: [
            "Filters/no-device.json": """
            {
              "displayName": "macOS - No Device",
              "platform": "macOS",
              "rule": "(device.deviceName -eq \\"JTKTEST-no-such-device\\")"
            }
            """,
            "Scripts/hello.sh": "#!/bin/zsh\necho \"JTKTEST live check\"\n",
            "Custom Attributes/battery.sh": Fixtures.attributeScriptByFolder,
            "Settings Catalog/content-caching.json": Fixtures.settingsCatalogJSON,
            "Compliance/encryption.json": Fixtures.complianceJSON,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let storeFolder = FileManager.default.temporaryDirectory.appending(path: "IntuneDeployer-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeFolder) }
        let store = SourceStore(activityLog: tenant.log, folder: storeFolder)
        store.addLocalFolder(at: root)
        let sourceID = try #require(store.sources.first?.id)
        for _ in 0..<200 where store.items(for: [sourceID]).count < 5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let items = store.items(for: [sourceID])
        let types = Set(items.map(\.type))
        try require("the baseline has its five items", items.count == 5
                        && types == [.assignmentFilter, .shellScript, .customAttribute, .settingsCatalog, .compliancePolicy],
                    note: items.map { "\($0.type)" }.sorted().joined(separator: ", "))

        let toGroup = AssignmentIntent(targets: [AssignmentTarget(kind: .include, scope: .group, groupName: groupName)])
        var profile = tenant.profile
        profile.selectedItemIDs = Set(items.map(\.id))
        for item in items where item.type != .assignmentFilter { profile.assignments[item.id] = toGroup }

        // 3. Plan: exactly five creates, assigned only to the test group.
        fence.set(.init(name: "Plan: reads only") { method, _ in Fence.isRead(method) })
        await session.plan(profile: profile, items: items, sourceStore: store)
        if let error = session.planError { try require("Plan", false, note: error) }
        var plan = try #require(session.currentPlan)
        try require("Plan: five creates, nothing else", !plan.hasErrors && plan.actions.count == 5
                        && plan.actions.allSatisfy { $0.kind == .create } && plan.groupsToCreate.isEmpty && plan.filtersToCreate.isEmpty,
                    note: describe(plan))
        let assigned = plan.actions.compactMap(\.assignments)
        let onlyTheGroup = assigned.count == 4 && assigned.allSatisfy { targets in
            targets.count == 1 && targets.allSatisfy { target in
                guard case .group(let id?, _) = target.target else { return false }
                return id.lowercased() == groupID && !target.isExclusion && target.filter == nil
            }
        }
        try require("Plan assigns only to the test group (never All devices, All users or another group)", onlyTheGroup,
                    note: "\(assigned.count) assigned objects")
        let othersTagged = plan.orphans.count
        run.record(step: step("Plan leaves the tenant's other Intune Deployer objects alone"), passed: true,
                   note: "\(othersTagged) listed as orphans, none ticked")

        // 4. Apply (the app's own): creates and assignments only.
        fence.set(.init(name: "Apply: creates and assignments") { method, path in
            Fence.isRead(method) || Fence.isCreate(method, path) || Fence.isAssign(method, path)
        })
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: items, sourceStore: store)
        let created = tenant.runObjects().filter { $0.resource != "groups" }
        try require("Apply: five created and four assigned, nothing failed",
                    applyFailures().isEmpty && created.count == 5 && fence.refusals.isEmpty
                        && fence.writes.count(where: { $0.hasSuffix("/assign") }) == 4,
                    note: (applyFailures() + fence.refusals).joined(separator: "; "))

        // 5. Second Plan: nothing to do; then read back.
        fence.set(.init(name: "Plan: reads only") { method, _ in Fence.isRead(method) })
        plan = try await planAgain(session, profile, items, store, require)
        try require("second Plan: nothing to do", isNothingToDo(plan), note: describe(plan))
        try await readBack(plan, tenant: tenant, groupID: groupID, scriptText: "JTKTEST live check", require: require, attempt: attempt)
        try await checkGroupEmpty("after the assignments")
        try run.injectFault("fail-live-step", at: step("after the baseline was applied"))

        if run.fault == "all-devices-attempt" {
            // The app's own Apply, asked to assign the script to All devices:
            // JTKit's guarded network must refuse it before it's sent.
            var allDevices = profile
            let script = try #require(items.first { $0.type == .shellScript })
            allDevices.assignments[script.id] = .single(.allDevices)
            await session.plan(profile: allDevices, items: items, sourceStore: store)
            let faulty = try #require(session.currentPlan)
            fence.set(.init(name: "Apply: assignments (fault)") { method, path in Fence.isRead(method) || Fence.isAssign(method, path) })
            await session.apply(profile: allDevices, plan: faulty, deleteOrphanIDs: [], items: items, sourceStore: store)
            let refused = run.network.refusals.filter { $0.reason.contains("All devices") }
            run.record(step: "all-devices-attempt (--fault)", passed: false,
                       note: refused.isEmpty ? "NOT refused" : "refused before it was sent: \(refused.map(\.reason).joined(separator: "; "))")
            throw LiveFailure("all-devices-attempt: an assignment to All devices was attempted")
        }

        // 6. A second Apply of the unchanged baseline.
        let writesBefore = fence.writes.count
        fence.set(.init(name: "second Apply: assignments only") { method, path in Fence.isRead(method) || Fence.isAssign(method, path) })
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: items, sourceStore: store)
        let resent = Array(fence.writes.dropFirst(writesBefore))
        if Self.resendsAssignmentsUntilBug1IsFixed {
            try require("second Apply sends only the assignments again (bug 1, still to fix)",
                        applyFailures().isEmpty && fence.refusals.isEmpty && resent.allSatisfy { $0.hasSuffix("/assign") },
                        note: "\(resent.count) assignments sent again, each replacing the same set; once bug 1 is fixed this must be 0")
        } else {
            try require("second Apply sends nothing", applyFailures().isEmpty && resent.isEmpty, note: resent.joined(separator: "; "))
        }

        // 7. One update: the script changes; Plan shows exactly that.
        try Data("#!/bin/zsh\necho \"JTKTEST live check, updated\"\n".utf8).write(to: root.appending(path: "Scripts/hello.sh"))
        plan = try await planAgain(session, profile, items, store, require)
        let updates = plan.actions.filter { if case .update = $0.kind { true } else { false } }
        try require("Plan after editing the script: one update, four unchanged",
                    !plan.hasErrors && updates.count == 1 && updates.first?.collection == .shellScripts && plan.unchangedCount == 4
                        && plan.createCount == 0, note: describe(plan))
        fence.set(.init(name: "Apply: the update and assignments") { method, path in
            let parts = Fence.segments(path)
            let onObject = parts.count >= 2 && Fence.isID(parts.last ?? "")
            return Fence.isRead(method) || Fence.isAssign(method, path) || ((method == "PATCH" || method == "PUT") && onObject)
        })
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: items, sourceStore: store)
        try require("Apply the update", applyFailures().isEmpty && fence.refusals.isEmpty, note: applyFailures().joined(separator: "; "))
        fence.set(.init(name: "Plan: reads only") { method, _ in Fence.isRead(method) })
        plan = try await planAgain(session, profile, items, store, require)
        try require("Plan after the update: nothing to do", isNothingToDo(plan), note: describe(plan))
        try await readBack(plan, tenant: tenant, groupID: groupID, scriptText: "JTKTEST live check, updated", require: require, attempt: attempt)

        // 8. Removal with the app's own deletion path: a Plan without the
        // items lists them as orphans; only this run's are ticked.
        var emptied = profile
        emptied.selectedItemIDs = []
        plan = try await planAgain(session, emptied, items, store, require)
        let runIDs = Set(tenant.runObjects().filter { $0.resource != "groups" }.map { $0.id.lowercased() })
        let ticked = plan.orphans.filter { runIDs.contains($0.objectID.lowercased()) }
        try require("the deletion Plan lists this run's five objects as orphans",
                    ticked.count == 5 && Set(ticked.map { $0.objectID.lowercased() }) == runIDs
                        && ticked.allSatisfy { $0.displayName.hasPrefix(run.prefix) },
                    note: "\(ticked.count) of this run's objects ticked; \(plan.orphans.count - ticked.count) others left unticked")
        let deletions = ticked.count
        try require("the app's confirmation asks for the count typed", ApplyConfirmation.typedCount(deletions: deletions) == deletions
                        && ApplyConfirmation.typingProblem("\(deletions)", deletions: deletions) == nil
                        && ApplyConfirmation.typingProblem("\(deletions - 1)", deletions: deletions) != nil
                        && ApplyConfirmation.canApply(plan, deletions: deletions, isPlanning: false, isApplying: false))
        let deletable = Set(ticked.map { $0.objectID.lowercased() })
        fence.set(.init(name: "Apply: delete this run's objects") { method, path in
            Fence.isRead(method) || (method == "DELETE" && deletable.contains(Fence.segments(path).last?.lowercased() ?? ""))
        })
        await session.apply(profile: emptied, plan: plan, deleteOrphanIDs: Set(ticked.map(\.objectID)), items: items, sourceStore: store)
        try require("Apply deletes this run's five objects, nothing else",
                    applyFailures().isEmpty && fence.refusals.isEmpty && fence.writes.suffix(deletions).allSatisfy { $0.hasPrefix("DELETE ") }
                        && tenant.runObjects().filter({ $0.resource != "groups" }).isEmpty,
                    note: (applyFailures() + fence.refusals).joined(separator: "; "))
        var stillThere: [String] = []
        for orphan in ticked {
            do {
                _ = try await tenant.api.getRaw("\(orphan.collection.listPath)/\(orphan.objectID)", version: orphan.collection.version)
                stillThere.append(orphan.displayName)
            } catch where isGone(error) {
            } catch {
                stillThere.append("\(orphan.displayName): \(failure(error))")
            }
        }
        try require("read back: the five objects are gone", stillThere.isEmpty, note: stillThere.joined(separator: "; "))

        // 9. The group: removed by the test code, then from the recycle bin.
        try await attempt("remove the test group") {
            try await tenant.api.delete("groups/\(groupID)", version: .v1)
        }
        let purge = await purgeDeletedGroups(tenant)
        try require("the test group is removed and emptied from Entra's recycle bin", purge.problems.isEmpty && purge.purged == 1,
                    note: purge.problems.joined(separator: "; "))

        checkNoSavedTenantRequests(run, when: "after the lifecycle")
        #expect(tenant.runObjects().isEmpty)
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
        #expect(fence.refusals.isEmpty, "\(fence.refusals)")
    }

    private func planAgain(_ session: TenantSession, _ profile: TenantProfile, _ items: [InferredItem], _ store: SourceStore,
                           _ require: (String, Bool, String?) throws -> Void) async throws -> Plan {
        session.currentPlan = nil
        await session.plan(profile: profile, items: items, sourceStore: store)
        if let error = session.planError { try require("Plan", false, error) }
        return try #require(session.currentPlan)
    }

    /// Nothing to create, update or delete (assignments aside: bug 1).
    private func isNothingToDo(_ plan: Plan) -> Bool {
        !plan.hasErrors && plan.createCount == 0 && plan.updateCount == 0 && plan.unchangedCount == plan.actions.count
            && plan.actions.count == 5
    }

    private func describe(_ plan: Plan) -> String {
        "\(plan.createCount) creates, \(plan.updateCount) updates, \(plan.unchangedCount) unchanged, \(plan.orphans.count) orphans"
            + (plan.errors.isEmpty ? "" : "; errors: \(plan.errors.map(\.message).joined(separator: "; "))")
    }

    /// Reads the objects back with the test code: name, identity tag, the
    /// content that matters, assignments only to the test group.
    private func readBack(_ plan: Plan, tenant: LiveTenant, groupID: String, scriptText: String,
                          require: (String, Bool, String?) throws -> Void,
                          attempt: (String, () async throws -> Data) async throws -> Data) async throws {
        var problems: [String] = []
        for action in plan.actions {
            guard let id = action.existingObjectID else { problems.append("\(action.displayName): no object"); continue }
            let path = "\(action.collection.listPath)/\(id)"
            let expand = action.collection == .compliancePolicies
                ? "?$expand=scheduledActionsForRule($expand=scheduledActionConfigurations)" : ""
            let body = try await attempt("read back \(action.collection.displayName)") {
                try await tenant.api.getRaw(path + expand, version: action.collection.version)
            }
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let name = object["displayName"] as? String ?? object["name"] as? String ?? ""
            if !name.hasPrefix(tenant.run.prefix) { problems.append("\(action.collection.displayName): name without the run's prefix") }
            if !(object["description"] as? String ?? "").contains(ItemIdentity.tag(forShortID: action.id)) {
                problems.append("\(action.collection.displayName): no identity tag")
            }
            func script() -> String {
                (object["scriptContent"] as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
            switch action.collection {
            case .shellScripts where !script().contains(scriptText):
                problems.append("script: its content isn't the file's")
            case .customAttributes where !script().contains("battery"):
                problems.append("custom attribute: its content isn't the file's")
            case .assignmentFilters where !(object["rule"] as? String ?? "").contains("JTKTEST-no-such-device"):
                problems.append("filter: its rule isn't the file's")
            case .compliancePolicies:
                let actions = (object["scheduledActionsForRule"] as? [[String: Any]] ?? [])
                    .flatMap { $0["scheduledActionConfigurations"] as? [[String: Any]] ?? [] }
                    .compactMap { $0["actionType"] as? String }
                if object["storageRequireEncryption"] as? Bool != true || actions.isEmpty || !actions.allSatisfy({ $0 == "block" }) {
                    problems.append("compliance: encryption \(object["storageRequireEncryption"] ?? "missing"), actions \(actions)")
                }
            case .settingsCatalog:
                let settings = try await attempt("read back the Settings Catalog settings") {
                    try await tenant.api.getRaw("\(path)/settings", version: .beta)
                }
                if !String(decoding: settings, as: UTF8.self).contains("com.apple.applicationaccess_allowcontentcaching_false") {
                    problems.append("Settings Catalog: the setting isn't the file's")
                }
            default:
                break
            }
            guard action.collection != .assignmentFilters else { continue }
            // Custom attribute scripts have no …/assignments route (400 "No
            // method match route template"); their assignments come expanded.
            let assignments: [Any]
            do {
                assignments = try await tenant.api.listRaw("\(path)/assignments", version: action.collection.version)
                    .compactMap { try? JSONSerialization.jsonObject(with: $0) }
            } catch where status(of: error) == 400 {
                let expanded = try await attempt("read back the assignments of \(action.collection.displayName)") {
                    try await tenant.api.getRaw("\(path)?$expand=assignments", version: action.collection.version)
                }
                assignments = ((try? JSONSerialization.jsonObject(with: expanded)) as? [String: Any])?["assignments"] as? [Any] ?? []
            } catch {
                problems.append("\(action.collection.displayName): assignments can't be read: \(failure(error))")
                continue
            }
            let targets = assignments.compactMap { ($0 as? [String: Any])?["target"] as? [String: Any] }
            let onlyTheGroup = targets.count == 1 && targets.allSatisfy {
                $0["@odata.type"] as? String == "#microsoft.graph.groupAssignmentTarget" && ($0["groupId"] as? String)?.lowercased() == groupID
            }
            if !onlyTheGroup { problems.append("\(action.collection.displayName): assigned to \(targets.count) targets, not only the test group") }
        }
        try require("read back: names, identity tags, content and assignments match", problems.isEmpty, problems.joined(separator: "; "))
    }
}

// MARK: - Cleanup (every exit)

@MainActor
@Suite("Live: cleanup", .enabled(if: live), .serialized)
struct LiveCleanupTests {
    @Test func removeTestObjects() async throws {
        let run = try LiveCheckRun.current()
        defer { checkNoSavedTenantRequests(run, when: "end of the run") }
        let tenant = try LiveTenant(run)
        var problems = await removeOutstanding(tenant)
        let purge = await purgeDeletedGroups(tenant)
        problems += purge.problems

        // Once, on the first run: old [AUTOTEST] objects, by name and identity tag.
        var legacy = 0
        if !run.legacyPrefixes.isEmpty {
            for collection in TenantCollection.allCases {
                do {
                    for body in try await tenant.api.listRaw(collection.listPath, version: collection.version) {
                        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                        guard let id = object["id"] as? String else { continue }
                        let name = object["displayName"] as? String ?? object["name"] as? String ?? ""
                        guard run.isLegacyTestObject(name),
                              ItemIdentity.shortID(inDescription: object["description"] as? String ?? "") != nil else { continue }
                        try run.adoptForSweep(role: Role.intune, service: .intune,
                                              resource: String(collection.listPath.split(separator: "/").last ?? ""), id: id, name: name)
                        legacy += 1
                    }
                } catch {
                    problems.append("sweep of \(collection.displayName): \(failure(error))")
                }
            }
            problems += await removeOutstanding(tenant)
        }

        let left = run.ledger.outstanding.filter { $0.target == tenant.target }
        run.record(step: "cleanup", passed: problems.isEmpty && left.isEmpty,
                   note: (["\(purge.purged) test groups emptied from the recycle bin", "\(legacy) old [AUTOTEST] objects found"]
                          + problems + left.map { "left: \($0.resource) “\($0.name)”" }).joined(separator: "; "))
        #expect(problems.isEmpty, "\(problems)")
        #expect(left.isEmpty)
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }
}
