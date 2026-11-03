import Foundation
import JTKit
import JTKitTestSupport
import SwiftUI
import Testing
@testable import Intune_Deployer

// The fixes of the release gate's independent review (2026-10-31).

private let tenantA = "aaaaaaaa-0000-4000-8000-00000000000a"

/// A made-up access token for a tenant (only its `tid` claim is read).
private func token(tid: String) -> String {
    func encode(_ object: [String: Any]) -> String {
        (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    return "\(encode(["alg": "none"])).\(encode(["tid": tid])).sig"
}

private func json(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func list(_ objects: [[String: Any]]) -> MockResponse {
    .json(200, json(["value": objects]))
}

private func writes(_ server: MockServer) -> [RecordedRequest] {
    server.requests.filter { $0.method != "GET" }
}

private func tempFolder(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// A session on a fake Graph whose tokens are for `tenant`; `scopes`
/// collects the permissions each token was asked for.
@MainActor
private func session(_ server: MockServer, tenant: String = tenantA,
                     scopes: (@MainActor ([String]) -> Void)? = nil) -> TenantSession {
    let savedTenantGuard = TestRun.AttemptLog(fileURL: FileManager.default.temporaryDirectory
        .appending(path: "IntuneDeployerTests-guard-\(UUID().uuidString).jsonl"))
    return TenantSession(auth: AuthManager(underTest: .refuseAll(savedTenantGuard)), activityLog: ActivityLog(),
                         realTenantSession: server.session,
                         tokenProvider: { _, asked, _ in scopes?(asked); return token(tid: tenant) })
}

/// A source store on a folder of files, scanned.
@MainActor
private func scannedStore(_ files: [String: String], root: URL? = nil, folder: URL = tempFolder("store")) async throws
    -> (store: SourceStore, root: URL) {
    let root = try root ?? Fixtures.makeTree(files: files)
    let store = SourceStore(folder: folder)
    store.addLocalFolder(at: root)
    try await waitForItems(store, count: files.count)
    return (store, root)
}

@MainActor
private func waitForItems(_ store: SourceStore, count: Int) async throws {
    for _ in 0..<250 {
        if store.sources.allSatisfy({ store.scanResults[$0.id] != nil && !store.scanningSourceIDs.contains($0.id) }),
           store.items(for: Set(store.sources.map(\.id))).count >= count { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("the source wasn't scanned")
}

@MainActor
private func allItems(_ store: SourceStore) -> [InferredItem] {
    store.items(for: Set(store.sources.map(\.id)))
}

private func tagged(_ item: InferredItem, _ profile: TenantProfile) -> String {
    ItemIdentity.tag(forShortID: item.id, profileID: profile.id)
}

// MARK: - App content

@Suite("Release gate: app packages")
struct AppContentGateTests {
    private static let v1 = AppPackageInfo(primaryBundleID: "com.example.tool", primaryBundleVersion: "1.0", includedApps: [])
    private static let v2 = AppPackageInfo(primaryBundleID: "com.example.tool", primaryBundleVersion: "2.0", includedApps: [])

    /// The tenant's app as deployed with `info`, its content committed.
    private static func deployed(_ item: InferredItem, _ profile: TenantProfile, info: AppPackageInfo) throws -> RemoteObject {
        let built = try PayloadBuilder.build(item: item, fileData: Data(), namingPrefix: profile.namingPrefix, variables: [:],
                                             appInfo: info, profileID: profile.id)
        var body = try #require(try JSONSerialization.jsonObject(with: built.body) as? [String: Any])
        body["id"] = "app-1"
        body["committedContentVersion"] = "1"
        return RemoteObject(id: "app-1", displayName: built.displayName, description: body["description"] as? String,
                            body: try JSONSerialization.data(withJSONObject: body))
    }

    private static func plan(_ item: InferredItem, _ profile: TenantProfile, info: AppPackageInfo, existing: [RemoteObject],
                             package: PlanInput.PackageFile, committedFiles: [String: [CommittedFile]] = [:]) -> Plan {
        var input = PlanInput(selectedItems: [.init(item: item, fileData: Data(), appInfo: info, package: package)],
                              profile: profile, existingObjects: [.apps: existing], groups: [:], knownSettingDefinitionIDs: nil)
        input.committedFiles = committedFiles
        return PlanEngine.makePlan(input: input)
    }

    @MainActor
    @Test("An app update uploads and commits the content before the new version is written")
    func uploadBeforeVersion() async throws {
        let package = "pkg bytes, version 2"
        let (store, root) = try await scannedStore(["apps/Tool.pkg": package])
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(allItems(store).first)
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [item.id]
        let data = Data(package.utf8)
        let plan = Self.plan(item, profile, info: Self.v2, existing: [try Self.deployed(item, profile, info: Self.v1)],
                             package: .init(size: data.count, hash: ItemEditStore.hash(data)))
        #expect(plan.actions.first?.uploadsPackage == true)

        // The upload fails at its first step.
        let server = MockServer { request in
            if request.method == "GET" { return .json(200, #"{"id":"me"}"#) }
            if request.path.hasSuffix("/contentVersions") { return .json(400, #"{"error":{"code":"BadRequest","message":"No"}}"#) }
            return .json(200, "{}")
        }
        let session = session(server)
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: [item], sourceStore: store)
        #expect(!writes(server).contains { $0.method == "PATCH" }, "the new version isn't written: \(writes(server).map(\.path))")
        #expect(session.applyResults?.contains { $0.title.hasPrefix("Upload content") && $0.isFailure } == true)
        #expect(session.applyResults?.contains { $0.title.hasPrefix("Update") } == false)

        // So the next Plan still sees version 1.0 in the tenant and uploads again.
        let again = Self.plan(item, profile, info: Self.v2, existing: [try Self.deployed(item, profile, info: Self.v1)],
                              package: .init(size: data.count, hash: ItemEditStore.hash(data)))
        #expect(again.actions.first?.uploadsPackage == true)
    }

    @Test("Plan notices a committed package that isn't the file, and uploads it again")
    func contentThatNeverArrived() throws {
        let item = InferredItem(id: "0a0b0c0d", sourceID: UUID(), relativePath: "apps/Tool.pkg", fileURL: URL(filePath: "/tmp/fixture/apps/Tool.pkg"),
                                type: .app, displayName: "Tool", detectionReason: "test")
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [item.id]
        let remote = try Self.deployed(item, profile, info: Self.v2)
        let package = PlanInput.PackageFile(size: 9_000, hash: "h")
        func kind(_ files: [CommittedFile]?) -> PlanActionKind? {
            Self.plan(item, profile, info: Self.v2, existing: [remote], package: package,
                      committedFiles: files.map { ["app-1": $0] } ?? [:]).actions.first?.kind
        }
        #expect(kind([CommittedFile(name: "Tool.pkg", size: 9_000)]) == .unchanged)
        #expect(kind(nil) == .unchanged, "files that can't be read aren't a reason to upload")
        #expect(kind([CommittedFile(name: "Tool.pkg", size: nil)]) == .unchanged)
        for files in [[CommittedFile(name: "Tool.pkg", size: 3_000)], []] {
            guard case .update(let changes) = kind(files) else {
                Issue.record("not an update")
                continue
            }
            #expect(changes.map(\.path) == [PlanEngine.missingContentPath])
        }
        let warned = Self.plan(item, profile, info: Self.v2, existing: [remote], package: package, committedFiles: ["app-1": []])
        #expect(warned.actions.first?.warnings.contains { $0.contains("isn’t this file") } == true)
        #expect(warned.actions.first?.warnings.contains { $0.hasPrefix("Apply uploads the package") } == true)
        #expect(CommittedFile(graph: Data(#"{"name":"Tool.pkg","sizeInBytes":12}"#.utf8))?.size == 12)
        #expect(CommittedFile(graph: Data(#"{"name":"Tool.pkg","size":34}"#.utf8))?.size == 34)
    }

    @MainActor
    @Test("A package replaced since the Plan isn't uploaded")
    func packageChangedSincePlan() async throws {
        let (store, root) = try await scannedStore(["apps/Tool.pkg": "the file as planned"])
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(allItems(store).first)
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [item.id]
        let plan = Self.plan(item, profile, info: Self.v1, existing: [], package: .init(size: 1, hash: "another file"))
        let server = MockServer { request in
            request.method == "GET" ? .json(200, #"{"id":"me"}"#) : .json(201, #"{"id":"app-new"}"#)
        }
        let session = session(server)
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: [item], sourceStore: store)
        let upload = session.applyResults?.first { $0.title.hasPrefix("Upload content") }
        guard case .failure(let message) = upload?.outcome else {
            Issue.record("the upload wasn't refused")
            return
        }
        #expect(message.contains("changed since the Plan"))
        #expect(!server.requests.contains { $0.path.contains("contentVersions") })
    }
}

// MARK: - Deletion offers

@MainActor
@Suite("Release gate: Plan never offers wanted objects for deletion")
struct DeletionOfferGateTests {
    @Test("An item that fails to build keeps its tenant object, and Apply refuses a plan with errors")
    func buildFailedIsNoOrphan() async throws {
        let item = InferredItem(id: "0a0b0c0d", sourceID: UUID(), relativePath: "apps/Tool.pkg", fileURL: URL(filePath: "/tmp/fixture/apps/Tool.pkg"),
                                type: .app, displayName: "Tool", detectionReason: "test")
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [item.id]
        let object = RemoteObject(id: "app-1", displayName: "Tool", description: tagged(item, profile), body: Data("{}".utf8))
        // No bundle info: the payload can't be built.
        var selected = PlanInput.SelectedItem(item: item, fileData: Data())
        selected.inspectionError = "xar couldn’t open the package"
        let plan = PlanEngine.makePlan(input: PlanInput(selectedItems: [selected], profile: profile,
                                                        existingObjects: [.apps: [object]], groups: [:], knownSettingDefinitionIDs: nil))
        #expect(plan.hasErrors)
        #expect(plan.errors.first?.message.contains("xar couldn’t open the package") == true, "the inspection's error is shown")
        #expect(plan.orphans.isEmpty)

        let server = MockServer { _ in .json(201, #"{"id":"new-1"}"#) }
        let session = session(server)
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: ["app-1"], items: [], sourceStore: SourceStore(folder: tempFolder("s")))
        #expect(server.requests.isEmpty)
        #expect(session.applyResults?.map(\.title) == ["Apply"])
    }

    @Test("Plan doesn't run while a chosen item may be in a source that isn't scanned")
    func unscannedSource() async throws {
        #expect(TenantSession.unscannedSourcesProblem(missing: 0, sources: ["Baseline"]) == nil)
        #expect(TenantSession.unscannedSourcesProblem(missing: 2, sources: []) == nil)
        let problem = try #require(TenantSession.unscannedSourcesProblem(missing: 2, sources: ["Baseline"]))
        #expect(problem.contains("2 chosen items aren’t") && problem.contains("“Baseline” isn’t scanned"))

        let (store, root) = try await scannedStore(["scripts/hello.sh": Fixtures.plainScript])
        let item = try #require(allItems(store).first)
        // The folder disappears (an unmounted drive): its scan fails.
        try FileManager.default.removeItem(at: root)
        await store.scan(sourceID: item.sourceID)
        #expect(!store.unscannedSourceNames.isEmpty)

        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [item.id, "0f0f0f0f"]
        let server = MockServer { _ in list([]) }
        let session = session(server)
        await session.plan(profile: profile, items: [], sourceStore: store)
        #expect(session.planError?.contains("aren’t in the scanned sources") == true)
        #expect(session.currentPlan == nil)
        #expect(server.requests.isEmpty)
    }
}

// MARK: - Item identity

@MainActor
@Suite("Release gate: item identity survives removing a source and another Mac")
struct IdentityGateTests {
    @Test("A source removed and added again keeps its item IDs")
    func reAddedSource() async throws {
        let (store, root) = try await scannedStore(["scripts/hello.sh": Fixtures.plainScript])
        defer { try? FileManager.default.removeItem(at: root) }
        let before = allItems(store).map(\.id)
        let sourceID = try #require(store.sources.first?.id)
        store.removeSource(id: sourceID)
        store.addLocalFolder(at: root)
        try await waitForItems(store, count: 1)
        #expect(store.sources.first?.id == sourceID)
        #expect(allItems(store).map(\.id) == before)
    }

    @Test("A second folder with the same name gets its own identity while the first is there")
    func twoFoldersWithOneName() async throws {
        let (store, root) = try await scannedStore(["scripts/hello.sh": Fixtures.plainScript])
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = tempFolder("copy").appending(path: root.lastPathComponent)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root, to: copy)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        store.addLocalFolder(at: copy)
        try await waitForItems(store, count: 2)
        #expect(Set(store.sources.map(\.id)).count == 2)
    }

    @Test("A profile exported with its sources, imported on another Mac: the same files get the same IDs")
    func importOnAnotherMac() async throws {
        let (macA, root) = try await scannedStore(["scripts/hello.sh": Fixtures.plainScript])
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(allItems(macA).first)
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [item.id]
        profile.assignments[item.id] = .single(.allUsers)
        let exported = Data(try profile.exportText(sourceIdentities: macA.currentIdentities).utf8)
        #expect(TenantProfile.exportedIdentities(in: exported) == macA.currentIdentities)

        // Mac B: the profile first, then the same folder.
        let macB = SourceStore(folder: tempFolder("mac-b"))
        let imported = macB.adopt(try TenantProfile.importedProfile(from: exported, existingIDs: []),
                                  identities: TenantProfile.exportedIdentities(in: exported))
        macB.addLocalFolder(at: root)
        try await waitForItems(macB, count: 1)
        #expect(allItems(macB).map(\.id) == [item.id])
        #expect(imported.selectedItemIDs == [item.id])
    }

    @Test("Imported while the source is already here under another identity: the choices move, and Plan updates the deployed objects")
    func importWithSourceAlreadyHere() async throws {
        let (macA, root) = try await scannedStore(["scripts/hello.sh": Fixtures.plainScript])
        defer { try? FileManager.default.removeItem(at: root) }
        let itemA = try #require(allItems(macA).first)
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA, namingPrefix: "[LAB]")
        profile.selectedItemIDs = [itemA.id]
        profile.assignments[itemA.id] = .single(.allUsers)
        let exported = Data(try profile.exportText(sourceIdentities: macA.currentIdentities).utf8)

        let (macB, _) = try await scannedStore(["scripts/hello.sh": Fixtures.plainScript], root: root, folder: tempFolder("mac-b"))
        let itemB = try #require(allItems(macB).first)
        #expect(itemB.id != itemA.id)
        let imported = macB.adopt(try TenantProfile.importedProfile(from: exported, existingIDs: []),
                                  identities: TenantProfile.exportedIdentities(in: exported))
        #expect(imported.selectedItemIDs == [itemB.id])
        #expect(imported.assignments[itemB.id] == .single(.allUsers))
        #expect(macB.earlierIDs(of: itemB) == [itemA.id])

        // The object Mac A deployed is matched and updated (re-tagged), never a create plus a deletion.
        let built = try PayloadBuilder.build(item: itemA, fileData: Data(Fixtures.plainScript.utf8), namingPrefix: "[LAB]",
                                             variables: [:], profileID: profile.id)
        let object = RemoteObject(id: "script-1", displayName: built.displayName, description: tagged(itemA, profile), body: built.body)
        var selected = PlanInput.SelectedItem(item: itemB, fileData: Data(Fixtures.plainScript.utf8))
        selected.earlierIDs = macB.earlierIDs(of: itemB)
        let plan = PlanEngine.makePlan(input: PlanInput(selectedItems: [selected], profile: imported,
                                                        existingObjects: [.shellScripts: [object]], groups: [:], knownSettingDefinitionIDs: nil))
        #expect(plan.orphans.isEmpty)
        #expect(plan.createCount == 0)
        #expect(plan.actions.first?.existingObjectID == "script-1")
    }

    @Test("Sources added before identities were kept keep their IDs")
    func existingSourcesAreRemembered() async throws {
        let folder = tempFolder("legacy")
        let (store, root) = try await scannedStore(["scripts/hello.sh": Fixtures.plainScript], folder: folder)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = try #require(store.sources.first?.id)
        // As an older build left it: sources.json, no identities.
        try FileManager.default.removeItem(at: folder.appending(path: "source-identities.json"))
        let reopened = SourceStore(folder: folder)
        reopened.removeSource(id: sourceID)
        reopened.addLocalFolder(at: root)
        #expect(reopened.sources.first?.id == sourceID)
    }
}

// MARK: - Saved files

@MainActor
@Suite("Release gate: unreadable saved files are kept aside")
struct SavedFileGateTests {
    @Test("An unreadable sources.json or platform-overrides.json is never saved over",
          arguments: ["sources.json", "platform-overrides.json"])
    func unreadableFile(name: String) async throws {
        let folder = tempFolder("unreadable")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = Data("[{\"id\": half-written".utf8)
        try broken.write(to: folder.appending(path: name))

        let store = SourceStore(folder: folder)
        #expect(store.problems.count == 1)
        #expect(store.problems.first?.contains("couldn’t be read, so changes aren’t saved") == true)
        let root = try Fixtures.makeTree(files: ["Profiles/wifi.mobileconfig": Fixtures.mobileconfig])
        defer { try? FileManager.default.removeItem(at: root) }
        store.addLocalFolder(at: root)
        try await waitForItems(store, count: 1)
        if let item = allItems(store).first { store.platformOverrides.set(.iOSiPadOS, for: item) }
        #expect(try Data(contentsOf: folder.appending(path: name)) == broken)
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("\(name).unreadable-") }
        #expect(copies.count == 1)
    }
}

// MARK: - Assignments, tenant switch, Remove Baseline

@MainActor
@Suite("Release gate: assignments, tenant switch and Remove Baseline")
struct ApplyGateTests {
    @Test("A new target is a group still to be named, never All devices")
    func newTargets() throws {
        #expect(AssignmentTarget().scope == .group)
        #expect(try JSONDecoder().decode(AssignmentTarget.self, from: Data("{}".utf8)).scope == .group)
        let item = InferredItem(id: "0a0b0c0d", sourceID: UUID(), relativePath: "scripts/a.sh", fileURL: URL(filePath: "/tmp/fixture/scripts/a.sh"),
                                type: .shellScript, displayName: "a", detectionReason: "test")
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [item.id]
        profile.defaultAssignments[.shellScript] = .single(.group)
        let plan = PlanEngine.makePlan(input: PlanInput(selectedItems: [.init(item: item, fileData: Data(Fixtures.plainScript.utf8))],
                                                        profile: profile, existingObjects: [:], groups: [:], knownSettingDefinitionIDs: nil))
        #expect(plan.errors.contains { $0.message == "Assignment group name is empty" })
        #expect(plan.actions.first?.assignments == nil)
    }

    @Test("While an Apply runs, a tenant switch keeps its plan and results, and the tenant in use doesn't change")
    func tenantSwitchDuringApply() throws {
        let session = session(MockServer { _ in list([]) })
        session.currentPlan = Plan()
        session.applyResults = [ApplyResult(title: "Create something", outcome: .success)]
        session.isApplying = true
        session.reset()
        #expect(session.applyResults?.count == 1)
        #expect(session.currentPlan != nil)
        session.isApplying = false
        session.reset()
        #expect(session.applyResults == nil)

        let folder = tempFolder("switch")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tenants = TenantStore(storageURL: folder.appending(path: "tenants.json"), defaults: TestSettings.makeDefaults("switch").defaults)
        let first = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        let second = TenantProfile(displayName: "Lab 2", clientID: "c", tenantID: tenantA)
        try tenants.connections.save(first)
        try tenants.connections.save(second)
        tenants.selectedProfileID = first.id
        tenants.connectionRole(lockedWhile: { true }).selection.wrappedValue = second.id
        #expect(tenants.selectedProfileID == first.id)
        tenants.connectionRole(lockedWhile: { false }).selection.wrappedValue = second.id
        #expect(tenants.selectedProfileID == second.id)
    }

    @Test("A filter renamed in the baseline: assignments naming its new name use the existing filter")
    func renamedFilter() async throws {
        let filterItem = InferredItem(id: "0f1f2f3f", sourceID: UUID(), relativePath: "filters/ade.json",
                                      fileURL: URL(filePath: "/tmp/fixture/filters/ade.json"), type: .assignmentFilter,
                                      displayName: "ade", detectionReason: "test")
        let policy = InferredItem(id: "0c1c2c3c", sourceID: UUID(), relativePath: "compliance/encryption.json",
                                  fileURL: URL(filePath: "/tmp/fixture/compliance/encryption.json"), type: .compliancePolicy,
                                  displayName: "encryption", detectionReason: "test")
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [filterItem.id, policy.id]
        var target = AssignmentTarget(scope: .group, groupName: "Lab Macs")
        target.filterName = "macOS - ADE Macs v2"
        profile.assignments[policy.id] = AssignmentIntent(targets: [target])
        let filterJSON = #"{"displayName": "macOS - ADE Macs v2", "platform": "macOS", "rule": "(device.deviceOwnership -eq \"Corporate\")"}"#
        let renamed = RemoteObject(id: "filter-1", displayName: "macOS - ADE Macs", description: tagged(filterItem, profile),
                                   body: Data(#"{"displayName": "macOS - ADE Macs", "platform": "macOS"}"#.utf8))
        let plan = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [.init(item: filterItem, fileData: Data(filterJSON.utf8)), .init(item: policy, fileData: Data(Fixtures.complianceJSON.utf8))],
            profile: profile, existingObjects: [.assignmentFilters: [renamed]],
            groups: ["Lab Macs": .found(id: "group-1", isDynamic: false)], knownSettingDefinitionIDs: nil))
        #expect(!plan.hasErrors, "\(plan.errors.map(\.message))")

        let server = MockServer { request in
            request.method == "GET" ? .json(200, #"{"id":"me"}"#) : .json(201, #"{"id":"policy-1"}"#)
        }
        let session = session(server)
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: SourceStore(folder: tempFolder("s")))
        #expect(session.applyResults?.contains(where: \.isFailure) == false, "\(session.applyResults?.map(\.title) ?? [])")
        let assign = try #require(writes(server).first { $0.path.hasSuffix("/assign") })
        #expect(assign.bodyString.contains("filter-1"))
    }

    @Test("Remove Baseline deletes only what it counted, and asks for group deletes even with group creation off")
    func removeBaselineCountedAndScopes() async throws {
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA, namingPrefix: "[LAB]")
        profile.assignments["x"] = AssignmentIntent(targets: [AssignmentTarget(scope: .group, groupName: "Lab Macs")])
        let mine = ItemIdentity.profileTag(for: profile.id)
        let server = MockServer { request in
            guard request.method == "GET" else { return .json(204, "") }
            switch request.path {
            case "/beta/deviceManagement/deviceShellScripts":
                return list([["id": "s-counted", "displayName": "[LAB] A", "description": "[IntuneDeployer:0123abcd] \(mine)"],
                             ["id": "s-new", "displayName": "[LAB] B", "description": "[IntuneDeployer:0123abce] \(mine)"]])
            case "/v1.0/groups":
                return list([["id": "g-empty", "displayName": "Lab Macs", "description": "\(TenantSession.createdGroupDescription) \(mine)"]])
            default:
                return list([])
            }
        }
        var asked: [[String]] = []
        let session = session(server) { asked.append($0) }
        let counted = TenantSession.RemovalCount(objectIDs: ["s-counted"], groupIDs: ["g-empty"])
        await session.removeBaseline(profile: profile, counted: counted)
        #expect(Set(writes(server).map(\.path)) == ["/beta/deviceManagement/deviceShellScripts/s-counted", "/v1.0/groups/g-empty"])
        #expect(session.applyResults?.contains { $0.title == "Keep [LAB] B" } == true)
        #expect(asked.allSatisfy { $0.contains("Group.ReadWrite.All") }, "\(asked)")
        #expect(try await session.removalCount(profile: profile).count == 3)
    }
}

// MARK: - Smaller fixes

@Suite("Release gate: smaller fixes")
struct SmallerGateTests {
    @Test("A custom attribute's runAsAccount=user is deployed and survives export and import")
    func customAttributeRunAs() throws {
        let script = "#!/bin/zsh\n# intune: type=customAttribute runAsAccount=user\necho 1\n"
        let sourceID = UUID()
        guard case .item(let item) = InferenceEngine.classify(data: Data(script.utf8), url: URL(filePath: "/tmp/fixture/a.sh"),
                                                              relativePath: "a.sh", sourceID: sourceID) else {
            Issue.record("not an item")
            return
        }
        #expect(item.type == .customAttribute)
        #expect(item.scriptSettings?.runAsAccount == .user)
        let built = try PayloadBuilder.build(item: item, fileData: Data(script.utf8), namingPrefix: "", variables: [:])
        var body = try #require(try JSONSerialization.jsonObject(with: built.body) as? [String: Any])
        #expect(body["runAsAccount"] as? String == "user")

        body["id"] = "ca-1"
        guard case .file(let file) = TenantExporter.export(collection: .customAttributes,
                                                            body: try JSONSerialization.data(withJSONObject: body), namingPrefix: "") else {
            Issue.record("not exported")
            return
        }
        guard case .item(let reimported) = InferenceEngine.classify(data: file.contents, url: URL(filePath: "/tmp/fixture/b.sh"),
                                                                    relativePath: "b.sh", sourceID: sourceID) else {
            Issue.record("the export isn't an item")
            return
        }
        #expect(reimported.type == .customAttribute)
        #expect(reimported.scriptSettings?.runAsAccount == .user)
    }

    @Test("Export removes the profile tag too")
    func exportStripsProfileTag() {
        #expect(TenantExporter.cleanedDescription("Disk encryption [IntuneDeployer:0123abcd] [IntuneDeployerProfile:7c01a9e2]")
            == "Disk encryption")
        #expect(TenantExporter.cleanedDescription("Managed by Intune Deployer [IntuneDeployer:0123abcd] [IntuneDeployerProfile:7c01a9e2]") == nil)
    }

    @Test("The as-built report masks a variable's value only where the variable is, also inside base64 content")
    func reportMasksVariables() throws {
        let secret = "correct-horse-battery"
        func item(_ path: String, _ type: ItemType) -> InferredItem {
            InferredItem(id: ItemIdentity.shortID(sourceID: UUID(), relativePath: path), sourceID: UUID(), relativePath: path,
                         fileURL: URL(filePath: "/tmp/fixture/\(path)"), type: type, displayName: "Item", detectionReason: "test")
        }
        let script = item("scripts/wifi.sh", .shellScript)
        let compliance = item("compliance/encryption.json", .compliancePolicy)
        let numeric = item("compliance/numeric.json", .compliancePolicy)
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        // "macOS" is a value elsewhere too: only where {{Platform}} is may it be masked
        profile.variables = ["WiFiPSK": secret, "Platform": "macOS", "Grace": "24"]
        profile.selectedItemIDs = [script.id, compliance.id, numeric.id]
        let numericJSON = ##"{"@odata.type": "#microsoft.graph.macOSCompliancePolicy", "displayName": "Numeric", "passwordMinimumLength": {{Grace}}}"##
        let plan = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [
                .init(item: script, fileData: Data("#!/bin/zsh\necho PSK is {{WiFiPSK}} on {{Platform}}\n".utf8)),
                .init(item: compliance, fileData: Data(Fixtures.complianceJSON.utf8)),
                .init(item: numeric, fileData: Data(numericJSON.utf8)),
            ],
            profile: profile, existingObjects: [:], groups: [:], knownSettingDefinitionIDs: nil))
        #expect(plan.actions.first { $0.id == compliance.id }?.reportPayload == .same, "no variable in it")
        #expect(plan.actions.first { $0.id == numeric.id }?.reportPayload == .leftOut)
        guard case .masked(let maskedScript) = try #require(plan.actions.first { $0.id == script.id }).reportPayload,
              let body = try JSONSerialization.jsonObject(with: maskedScript) as? [String: Any],
              let content = (body["scriptContent"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            Issue.record("the script's report payload isn't masked")
            return
        }
        #expect(String(decoding: content, as: UTF8.self) == "#!/bin/zsh\necho PSK is •••• on ••••\n")

        let input = AsBuiltReport.Input(profileName: "Lab", tenantID: tenantA, namingPrefix: "", plan: plan,
                                        results: [ApplyResult(title: "Create Item", outcome: .success)], date: .now)
        for report in [AsBuiltReport.markdown(input), AsBuiltReport.html(input)] {
            #expect(!report.contains(secret))
            #expect(!report.contains(Data("PSK is \(secret)".utf8).base64EncodedString().prefix(12)))
            #expect(report.contains("#microsoft.graph.macOSCompliancePolicy"), "the same text elsewhere isn't masked")
            #expect(report.contains("Left out"))
            #expect(report.contains("Succeeded"))
            #expect(!report.contains("✅") && !report.contains("⚠️"))
        }
    }

    @Test("A helper tool gets no input and is stopped after its time")
    func helperToolTimeout() throws {
        // Without input, cat ends at once instead of waiting for a typed answer.
        #expect(try AppPackageInspector.run("/bin/cat", []) == "")
        #expect(throws: AppInspectionError.timedOut(seconds: 0)) { try AppPackageInspector.run("/bin/sleep", ["5"], timeout: 0.3) }
        // a failing tool is a failure, not a time-out
        #expect(throws: AppInspectionError.toolFailed("")) { try AppPackageInspector.run("/usr/bin/false", []) }
    }

    @Test("A committed file's size is read from size, the field Graph returns, before sizeInBytes")
    func committedFileSize() {
        #expect(CommittedFile(graph: Data(#"{"name":"a.pkg","size":10,"sizeInBytes":99}"#.utf8))?.size == 10)
        #expect(CommittedFile(graph: Data(#"{"name":"a.pkg","sizeInBytes":99}"#.utf8))?.size == 99)
        #expect(CommittedFile(graph: Data(#"{"name":"a.pkg"}"#.utf8))?.size == nil)
    }

    @Test("Package inspection gets more time for a larger package, and says when it ran out")
    func inspectionTimeFitsTheSize() {
        #expect(AppPackageInspector.timeout(forSize: 0) == 300)
        #expect(AppPackageInspector.timeout(forSize: 40_000_000) == 360)
        #expect(AppPackageInspector.timeout(forSize: 12_500_000_000) == 300 + 13 * 60)
        #expect(AppInspectionError.timedOut(seconds: 1080).localizedDescription
            == "Reading the package took longer than 18 minutes, so it was stopped. Check that it opens in Finder, then run Plan again.")
    }

    @Test("The results line counts skipped steps apart")
    func resultsSummary() {
        let ok = ApplyResult(title: "a", outcome: .success)
        let skipped = ApplyResult(title: "b", outcome: .skipped("No tenant object ID. Run Plan again."))
        let failed = ApplyResult(title: "c", outcome: .failure("No"))
        #expect(ApplyResult.summary([ok, ok]) == "Applied 2 steps successfully")
        #expect(ApplyResult.summary([ok, skipped]) == "1 step applied, 1 skipped")
        #expect(ApplyResult.summary([ok, skipped, failed]) == "1 of 3 steps failed")
    }

    @Test("Default file names never contain / or :")
    func safeFileNames() {
        #expect(TenantProfile.fileNameSafe("Lab/One: Two") == "Lab-One- Two")
        #expect(TenantProfile.fileNameSafe(" / ") == "-")
        #expect(TenantProfile.fileNameSafe("  ") == "Tenant")
    }

    @MainActor
    @Test("Under tests the GitHub token is never read from the Keychain, and Settings says when saving fails")
    func gitHubToken() async throws {
        #expect(!(GitHubTokenStore.appStore is KeychainSecretStore))
        #expect(try GitHubTokenStore.load() == nil, "the test host's store starts empty")
        var reads = 0
        let store = SourceStore(folder: tempFolder("token"), gitHubToken: { reads += 1; return nil })
        await store.checkGitHubUpdates()
        #expect(reads == 0, "no GitHub source, so no token is read")
        #expect(GitHubTokenStore.status(saving: "github_pat_x", succeeded: true) == "Token saved to the Keychain")
        #expect(GitHubTokenStore.status(saving: "github_pat_x", succeeded: false).contains("didn’t save"))
        #expect(GitHubTokenStore.status(saving: " ", succeeded: false).contains("didn’t remove"))
    }

    @Test("A misspelled key in a script's header is shown with its detection")
    func unknownDirectiveKeys() {
        let script = "#!/bin/zsh\n# intune: frequncy=60\necho 1\n"
        guard case .item(let item) = InferenceEngine.classify(data: Data(script.utf8), url: URL(filePath: "/tmp/fixture/a.sh"),
                                                              relativePath: "a.sh", sourceID: UUID()) else {
            Issue.record("not an item")
            return
        }
        #expect(item.detectionReason.contains("Ignored in the # intune: line: frequncy"))
    }
}

// MARK: - Reads go through the tenant check

@MainActor
@Suite("Release gate: Plan's reads")
struct PlanReadGateTests {
    @Test("A profile with a verified domain is confirmed before Plan reads anything else")
    func domainBeforeReads() async throws {
        let (store, root) = try await scannedStore(["scripts/hello.sh": Fixtures.plainScript])
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: "lab.example")
        profile.selectedItemIDs = Set(allItems(store).map(\.id))
        let server = MockServer { request in
            request.path.hasSuffix("/organization") ? list([["id": tenantA, "verifiedDomains": [["name": "other.example"]]]]) : list([])
        }
        let session = session(server)
        await session.plan(profile: profile, items: allItems(store), sourceStore: store)
        #expect(session.planError != nil)
        #expect(server.requests.map(\.path) == ["/v1.0/organization"], "nothing else is read")
    }

    @Test("Custom attribute assignments are read expanded, without the route that answers 400")
    func customAttributeAssignments() async throws {
        let (store, root) = try await scannedStore(["Custom Attributes/battery.sh": Fixtures.attributeScriptByFolder])
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(allItems(store).first)
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [item.id]
        let object = json(["id": "ca-1", "displayName": "battery", "description": tagged(item, profile)])
        let expanded = json(["id": "ca-1", "displayName": "battery", "description": tagged(item, profile), "assignments": [] as [Any]])
        let server = MockServer { request in
            switch request.path {
            case "/beta/deviceManagement/deviceCustomAttributeShellScripts": .json(200, "{\"value\": [\(object)]}")
            case "/beta/deviceManagement/deviceCustomAttributeShellScripts/ca-1": .json(200, expanded)
            default: list([])
            }
        }
        let session = session(server)
        await session.plan(profile: profile, items: [item], sourceStore: store)
        #expect(session.planError == nil, "\(session.planError ?? "")")
        #expect(!server.requests.contains { $0.path.hasSuffix("/ca-1/assignments") })
        #expect(server.requests.contains { $0.path.hasSuffix("/ca-1") && $0.queryValue("$expand") == "assignments" })
    }
}
