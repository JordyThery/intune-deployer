import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Intune_Deployer

// The bugs found by JTKit ROADMAP step 11's survey of Intune Deployer, fixed
// on 2026-10-30 in the order Jordy chose: 5, 7, 2, then 1, 3, 4, 6, 10.

private let tenantA = "aaaaaaaa-0000-4000-8000-00000000000a"
private let tenantB = "bbbbbbbb-0000-4000-8000-00000000000b"
private let surveySourceID = UUID()

private func makeItem(_ relativePath: String, type: ItemType, platform: ItemPlatform = .macOS) -> InferredItem {
    let url = URL(filePath: "/tmp/fixture/\(relativePath)")
    return InferredItem(id: ItemIdentity.shortID(sourceID: surveySourceID, relativePath: relativePath), sourceID: surveySourceID,
                        relativePath: relativePath, fileURL: url, type: type, platform: platform,
                        displayName: url.deletingPathExtension().lastPathComponent, detectionReason: "test")
}

/// A made-up access token for a tenant (only its `tid` claim is read).
private func token(tid: String?) -> String {
    func encode(_ object: [String: Any]) -> String {
        (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    let claims: [String: Any] = tid.map { ["tid": $0] } ?? ["aud": "graph"]
    return "\(encode(["alg": "none"])).\(encode(claims)).sig"
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

@MainActor
private func session(_ server: MockServer, tokenTenant: String?) -> TenantSession {
    let savedTenantGuard = TestRun.AttemptLog(fileURL: FileManager.default.temporaryDirectory
        .appending(path: "IntuneDeployerTests-guard-\(UUID().uuidString).jsonl"))
    return TenantSession(auth: AuthManager(underTest: .refuseAll(savedTenantGuard)), activityLog: ActivityLog(),
                         realTenantSession: server.session, tokenProvider: { _, _, _ in token(tid: tokenTenant) })
}

@MainActor
private func emptyStore() -> SourceStore {
    SourceStore(folder: FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-store-\(UUID().uuidString)"))
}

/// One shell script item, and a profile for tenant A that selects it.
private func scriptPlan(profile: TenantProfile? = nil, existing: [TenantCollection: [RemoteObject]] = [:],
                        assignments: [String: Set<AssignmentEntry>] = [:], intent: AssignmentIntent? = nil,
                        groups: [String: GroupLookup] = [:]) -> (Plan, TenantProfile, InferredItem) {
    let item = makeItem("scripts/hello.sh", type: .shellScript)
    var profile = profile ?? TenantProfile(displayName: "Lab", clientID: UUID().uuidString, tenantID: tenantA, namingPrefix: "[LAB]")
    profile.selectedItemIDs = [item.id]
    if let intent { profile.assignments[item.id] = intent }
    let plan = PlanEngine.makePlan(input: PlanInput(
        selectedItems: [.init(item: item, fileData: Data(Fixtures.plainScript.utf8))],
        profile: profile, existingObjects: existing, groups: groups, knownSettingDefinitionIDs: nil,
        existingAssignments: assignments))
    return (plan, profile, item)
}

// MARK: - Bug 5: the token's tenant

@MainActor
@Suite("Bug 5: every write needs a token of the profile's tenant")
struct TenantCheckTests {
    @Test func readsTheTokensTenant() {
        #expect(TenantCheck.tenantID(ofAccessToken: token(tid: tenantA.uppercased())) == tenantA)
        #expect(TenantCheck.tenantID(ofAccessToken: token(tid: nil)) == nil)
        #expect(TenantCheck.tenantID(ofAccessToken: "not-a-jwt") == nil)
    }

    @Test("A token of another tenant: Apply sends nothing")
    func otherTenantSendsNothing() async {
        let server = MockServer { _ in .json(201, #"{"id":"new-1"}"#) }
        let (plan, profile, _) = scriptPlan()
        let session = session(server, tokenTenant: tenantB)
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: emptyStore())
        #expect(server.requests.isEmpty, "nothing was sent: \(server.requests.map(\.path))")
        #expect(session.applyResults?.first?.isFailure == true)
    }

    @Test("A token without a tenant: Apply sends nothing")
    func unreadableTokenSendsNothing() async {
        let server = MockServer { _ in .json(201, #"{"id":"new-1"}"#) }
        let (plan, profile, _) = scriptPlan()
        await session(server, tokenTenant: nil).apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: emptyStore())
        #expect(server.requests.isEmpty)
    }

    @Test("The profile's tenant: Apply writes")
    func sameTenantWrites() async {
        let server = MockServer { request in request.method == "GET" ? .json(200, #"{"id":"me"}"#) : .json(201, #"{"id":"new-1"}"#) }
        let (plan, profile, _) = scriptPlan()
        let session = session(server, tokenTenant: tenantA)
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: emptyStore())
        #expect(writes(server).map(\.path) == ["/beta/deviceManagement/deviceShellScripts"])
        #expect(session.applyResults?.contains(where: \.isFailure) == false)
    }

    @Test("A profile with a verified domain: writes only after the token's tenant lists that domain")
    func domainProfiles() async {
        let organization: @Sendable (String) -> MockResponse = { domain in
            list([["id": tenantA, "verifiedDomains": [["name": domain]]]])
        }
        let profile = TenantProfile(displayName: "Lab", clientID: UUID().uuidString, tenantID: "lab.example", namingPrefix: "[LAB]")

        let other = MockServer { request in
            request.path.hasSuffix("/organization") ? organization("other.example") : .json(201, #"{"id":"new-1"}"#)
        }
        let (plan, planned, _) = scriptPlan(profile: profile)
        let refused = session(other, tokenTenant: tenantA)
        await refused.apply(profile: planned, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: emptyStore())
        #expect(writes(other).isEmpty)
        #expect(refused.applyResults?.first?.title == "Check the tenant")

        let same = MockServer { request in
            if request.path.hasSuffix("/organization") { return organization("LAB.example") }
            return request.method == "GET" ? .json(200, #"{"id":"me"}"#) : .json(201, #"{"id":"new-1"}"#)
        }
        await session(same, tokenTenant: tenantA).apply(profile: planned, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: emptyStore())
        #expect(writes(same).count == 1)
    }
}

// MARK: - Bug 7: the plan's tenant, one run at a time

@MainActor
@Suite("Bug 7: Apply refuses another tenant's plan and a second run")
struct ApplyGuardTests {
    @Test("A plan made for another profile or tenant ID is refused")
    func otherProfilesPlan() async {
        let server = MockServer { _ in .json(201, #"{"id":"new-1"}"#) }
        let (plan, profile, _) = scriptPlan()
        var otherTenant = profile
        otherTenant.tenantID = tenantB
        let other = TenantProfile(displayName: "Other", clientID: profile.clientID, tenantID: tenantA)
        for target in [otherTenant, other] {
            let session = session(server, tokenTenant: target.tenantID)
            await session.apply(profile: target, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: emptyStore())
            #expect(session.applyResults?.map(\.title) == ["Apply"])
        }
        var unplanned = plan
        unplanned.profileID = nil
        let session = session(server, tokenTenant: tenantA)
        await session.apply(profile: profile, plan: unplanned, deleteOrphanIDs: [], items: [], sourceStore: emptyStore())
        #expect(session.applyResults?.map(\.title) == ["Apply"])
        #expect(server.requests.isEmpty)
    }

    @Test("While a Plan or an Apply runs, Apply and Remove Baseline do nothing, and leave that run's results alone")
    func oneRunAtATime() async {
        let server = MockServer { _ in .json(201, #"{"id":"new-1"}"#) }
        let (plan, profile, _) = scriptPlan()
        let session = session(server, tokenTenant: tenantA)
        let running = [ApplyResult(title: "Create something", outcome: .success)]
        session.applyResults = running
        session.isApplying = true
        #expect(await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: emptyStore()) == false)
        #expect(await session.removeBaseline(profile: profile) == false)
        #expect(session.applyResults?.map(\.title) == running.map(\.title))
        session.isApplying = false
        session.isPlanning = true
        #expect(await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: emptyStore()) == false)
        #expect(server.requests.isEmpty)
    }
}

// MARK: - Bug 2: this profile's objects only

@Suite("Bug 2: orphans and Remove Baseline cover only this profile's objects")
struct ProfileScopeTests {
    private let profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA, namingPrefix: "[LAB]")

    @Test func whichObjectsBelongToAProfile() {
        let other = UUID()
        let mine = "x [IntuneDeployer:0123abcd] \(ItemIdentity.profileTag(for: profile.id))"
        #expect(ItemIdentity.belongs(description: mine, displayName: "anything", to: profile))
        #expect(!ItemIdentity.belongs(description: "x [IntuneDeployer:0123abcd] \(ItemIdentity.profileTag(for: other))",
                                      displayName: "[LAB] Script", to: profile), "another profile's tag wins over the name")
        // Deployed before profile tags: by the naming prefix only.
        #expect(ItemIdentity.belongs(description: "[IntuneDeployer:0123abcd]", displayName: "[LAB] Script", to: profile))
        #expect(!ItemIdentity.belongs(description: "[IntuneDeployer:0123abcd]", displayName: "[LABS] Script", to: profile))
        var noPrefix = profile
        noPrefix.namingPrefix = ""
        #expect(!ItemIdentity.belongs(description: "[IntuneDeployer:0123abcd]", displayName: "Script", to: noPrefix))
    }

    @Test func newObjectsCarryTheProfileTag() throws {
        let item = makeItem("scripts/hello.sh", type: .shellScript)
        let built = try PayloadBuilder.build(item: item, fileData: Data(Fixtures.plainScript.utf8), namingPrefix: "[LAB]",
                                             variables: [:], profileID: profile.id)
        let body = try #require(try JSONSerialization.jsonObject(with: built.body) as? [String: Any])
        let description = try #require(body["description"] as? String)
        #expect(ItemIdentity.shortID(inDescription: description) == item.id, "older builds still read the item tag")
        #expect(ItemIdentity.profileMarker(inDescription: description) == ItemIdentity.profileMarker(for: profile.id))
        // A second build replaces both tags instead of adding more.
        #expect(PayloadBuilder.taggedDescription(description, tag: ItemIdentity.tag(forShortID: item.id, profileID: profile.id)) == description)
    }

    @Test("Another profile's objects are never its orphans")
    func orphansOfThisProfileOnly() {
        func object(_ id: String, _ name: String, profileID: UUID?) -> RemoteObject {
            RemoteObject(id: id, displayName: name,
                         description: "[IntuneDeployer:0123abcd]" + (profileID.map { " " + ItemIdentity.profileTag(for: $0) } ?? ""),
                         body: Data("{}".utf8))
        }
        let (plan, _, _) = scriptPlan(profile: profile, existing: [.compliancePolicies: [
            object("mine", "[LAB] Old", profileID: profile.id),
            object("theirs", "[LAB] Theirs", profileID: UUID()),
            object("legacy-mine", "[LAB] Legacy", profileID: nil),
            object("legacy-other", "[OTHER] Legacy", profileID: nil),
        ]])
        #expect(plan.orphans.map(\.objectID).sorted() == ["legacy-mine", "mine"])
    }

    @MainActor
    @Test("Remove Baseline deletes only this profile's objects, its template filters and its empty groups")
    func removeBaselineScope() async throws {
        var profile = profile
        profile.assignments["x"] = AssignmentIntent(targets: [AssignmentTarget(scope: .group, groupName: "Lab Macs"),
                                                              AssignmentTarget(scope: .group, groupName: "Lab Staff")])
        profile.defaultAssignments[.compliancePolicy] = AssignmentIntent(targets: [
            AssignmentTarget(scope: .group, groupName: "Lab Printers"), AssignmentTarget(scope: .group, groupName: "Lab Shared")])
        let mine = ItemIdentity.profileTag(for: profile.id)
        let theirs = ItemIdentity.profileTag(for: UUID())
        let server = MockServer { request in
            guard request.method == "GET" else { return .json(204, "") }
            switch request.path {
            case "/beta/deviceManagement/deviceShellScripts":
                return list([["id": "s-mine", "displayName": "[LAB] A", "description": "[IntuneDeployer:0123abcd] \(mine)"],
                             ["id": "s-theirs", "displayName": "[LAB] B", "description": "[IntuneDeployer:0123abce] \(theirs)"],
                             ["id": "s-untagged", "displayName": "[LAB] C", "description": "made by hand"]])
            case "/beta/deviceManagement/assignmentFilters":
                return list([["id": "f-mine", "displayName": "macOS - ADE", "description": "\(TenantSession.templateFilterDescription) \(mine)"],
                             ["id": "f-theirs", "displayName": "macOS - ADE 2", "description": "\(TenantSession.templateFilterDescription) \(theirs)"]])
            case "/v1.0/groups":
                let name = request.queryValue("$filter") ?? ""
                if name.contains("Lab Macs") {
                    return list([["id": "g-empty", "displayName": "Lab Macs", "description": "\(TenantSession.createdGroupDescription) \(mine)"]])
                }
                if name.contains("Lab Printers") {
                    // Made in the portal, or by an older build: no tag.
                    return list([["id": "g-untagged", "displayName": "Lab Printers", "description": TenantSession.createdGroupDescription]])
                }
                if name.contains("Lab Shared") {
                    return list([["id": "g-theirs", "displayName": "Lab Shared", "description": "\(TenantSession.createdGroupDescription) \(theirs)"]])
                }
                return list([["id": "g-full", "displayName": "Lab Staff", "description": "\(TenantSession.createdGroupDescription) \(mine)"]])
            case "/v1.0/groups/g-full/members":
                return list([["id": "user-1"]])
            case "/v1.0/groups/g-untagged/members", "/v1.0/groups/g-theirs/members":
                return list([])
            default:
                return list([])
            }
        }
        let session = session(server, tokenTenant: tenantA)
        #expect(try await session.taggedObjectCount(profile: profile) == 3)
        await session.removeBaseline(profile: profile)
        #expect(Set(writes(server).map(\.path)) == ["/beta/deviceManagement/deviceShellScripts/s-mine",
                                                    "/beta/deviceManagement/assignmentFilters/f-mine", "/v1.0/groups/g-empty"])
        #expect(writes(server).allSatisfy { $0.method == "DELETE" })
        let kept = (session.applyResults ?? []).filter { $0.title.hasPrefix("Keep group") }.map(\.title).sorted()
        #expect(kept == ["Keep group “Lab Printers”", "Keep group “Lab Shared”", "Keep group “Lab Staff”"],
                "untagged, another profile's and non-empty groups are listed, never deleted")
        #expect(!server.requests.contains { $0.path.hasPrefix("/v1.0/groups/g-untagged") || $0.path.hasPrefix("/v1.0/groups/g-theirs") },
                "nothing is even read of groups that aren't this profile's")
    }

    @MainActor
    @Test("Baseline Settings warns when another profile uses the same naming prefix")
    func sharedNamingPrefix() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-prefix-\(UUID().uuidString)")
        let store = TenantStore(storageURL: folder.appending(path: "tenants.json"), defaults: TestSettings.makeDefaults("prefix").defaults)
        let lab = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA, namingPrefix: "[LAB]")
        let second = TenantProfile(displayName: "Lab 2", clientID: "c", tenantID: tenantB, namingPrefix: " [lab] ")
        let other = TenantProfile(displayName: "Other", clientID: "c", tenantID: tenantB, namingPrefix: "[OTHER]")
        let none = TenantProfile(displayName: "None", clientID: "c", tenantID: tenantB, namingPrefix: "")
        for profile in [lab, second, other, none] { try store.connections.save(profile) }
        #expect(store.profiles(sharingPrefix: "[LAB]", besides: lab.id).map(\.displayName) == ["Lab 2"])
        #expect(store.profiles(sharingPrefix: "[OTHER]", besides: other.id).isEmpty)
        #expect(store.profiles(sharingPrefix: "", besides: none.id).isEmpty, "an empty prefix claims nothing")
        #expect(store.profiles(sharingPrefix: "[NEW]", besides: lab.id).isEmpty)
        try? FileManager.default.removeItem(at: folder)
    }
}

// MARK: - Bug 1: assignments compared

@Suite("Bug 1: assignments are compared, not sent again when they match")
struct AssignmentComparisonTests {
    private let group = "11111111-2222-4333-8444-555555555555"
    private var intent: AssignmentIntent { AssignmentIntent(targets: [AssignmentTarget(scope: .group, groupName: "Lab Macs")]) }

    private func existing(_ item: InferredItem, profile: TenantProfile) throws -> RemoteObject {
        let built = try PayloadBuilder.build(item: item, fileData: Data(Fixtures.plainScript.utf8), namingPrefix: profile.namingPrefix,
                                             variables: [:], profileID: profile.id)
        return RemoteObject(id: "OBJ-1", displayName: built.displayName,
                            description: "[IntuneDeployer:\(item.id)] \(ItemIdentity.profileTag(for: profile.id))", body: built.body)
    }

    private func remote(_ type: String, group: String?, filter: String? = nil, filterType: String = "none") -> AssignmentEntry? {
        var target: [String: Any] = ["@odata.type": type, "deviceAndAppManagementAssignmentFilterType": filterType]
        if let group { target["groupId"] = group }
        if let filter { target["deviceAndAppManagementAssignmentFilterId"] = filter }
        return AssignmentEntry(graph: ["id": "a1", "target": target])
    }

    @Test("Graph's forms of the same assignment are equal; other targets aren't")
    func entries() {
        let ours = AssignmentEntry(graph: ["target": ["@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": group.uppercased()]])
        #expect(ours == remote("#microsoft.graph.groupAssignmentTarget", group: group))
        #expect(ours == remote("#microsoft.graph.groupAssignmentTarget", group: group, filter: "00000000-0000-0000-0000-000000000000"))
        #expect(ours != remote("#microsoft.graph.exclusionGroupAssignmentTarget", group: group))
        #expect(ours != remote("#microsoft.graph.allDevicesAssignmentTarget", group: nil))
        #expect(ours != remote("#microsoft.graph.groupAssignmentTarget", group: group, filter: "abc", filterType: "include"))
    }

    @Test("Unchanged with the same assignments: nothing to do, Apply sends nothing")
    func sameAssignments() throws {
        let item = makeItem("scripts/hello.sh", type: .shellScript)
        let profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA, namingPrefix: "[LAB]")
        let object = try existing(item, profile: profile)
        let same: Set<AssignmentEntry> = [remote("#microsoft.graph.groupAssignmentTarget", group: group)!]
        let (plan, _, _) = scriptPlan(profile: profile, existing: [.shellScripts: [object]], assignments: ["obj-1": same],
                                      intent: intent, groups: ["Lab Macs": .found(id: group, isDynamic: false)])
        #expect(plan.actions.first?.kind == .unchanged)
        #expect(plan.actions.first?.assignmentsUpToDate == true)
        #expect(plan.actions.first?.sendsAssignments == false)
        #expect(!ApplyConfirmation.hasWork(plan, deletions: 0), "Everything is already up to date")
    }

    @Test("Different, or unreadable, assignments are sent")
    func differentAssignments() throws {
        let item = makeItem("scripts/hello.sh", type: .shellScript)
        let profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA, namingPrefix: "[LAB]")
        let object = try existing(item, profile: profile)
        let groups: [String: GroupLookup] = ["Lab Macs": .found(id: group, isDynamic: false)]
        let allDevices: Set<AssignmentEntry> = [remote("#microsoft.graph.allDevicesAssignmentTarget", group: nil)!]
        for assignments in [["obj-1": allDevices], ["obj-1": []], [:]] {
            let (plan, _, _) = scriptPlan(profile: profile, existing: [.shellScripts: [object]], assignments: assignments,
                                          intent: intent, groups: groups)
            #expect(plan.actions.first?.sendsAssignments == true)
            #expect(ApplyConfirmation.hasWork(plan, deletions: 0))
        }
    }

    @MainActor
    @Test("Apply of an unchanged plan with matching assignments sends nothing")
    func applySendsNothing() async throws {
        let item = makeItem("scripts/hello.sh", type: .shellScript)
        let profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA, namingPrefix: "[LAB]")
        let same: Set<AssignmentEntry> = [remote("#microsoft.graph.groupAssignmentTarget", group: group)!]
        let (plan, planned, _) = scriptPlan(profile: profile, existing: [.shellScripts: [try existing(item, profile: profile)]],
                                            assignments: ["obj-1": same], intent: intent,
                                            groups: ["Lab Macs": .found(id: group, isDynamic: false)])
        let server = MockServer { _ in .json(200, #"{"id":"me"}"#) }
        await session(server, tokenTenant: tenantA).apply(profile: planned, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: emptyStore())
        #expect(writes(server).isEmpty)
    }
}

// MARK: - Bugs 3, 4, 6, 10

@Suite("Bugs 3, 4, 6 and 10")
struct MoreSurveyFixTests {
    @MainActor
    @Test("Bug 3: a created group and a template filter carry the profile's tag")
    func createdObjectsAreTagged() async throws {
        let item = makeItem("scripts/hello.sh", type: .shellScript)
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA, namingPrefix: "[LAB]",
                                    variables: ["EnrollmentProfileName": "Lab ADE"], allowGroupCreation: true)
        profile.selectedItemIDs = [item.id]
        var plan = Plan()
        plan.profileID = profile.id
        plan.tenantID = tenantA
        plan.groupsToCreate = [PlannedGroupCreation(name: "Lab Macs")]
        plan.filtersToCreate = [PlannedFilterCreation(name: "macOS - ADE", rule: "(device.enrollmentProfileName -eq \"Lab ADE\")", platform: .macOS)]
        let server = MockServer { request in request.method == "GET" ? .json(200, #"{"id":"me"}"#) : .json(201, #"{"id":"new-1"}"#) }
        await session(server, tokenTenant: tenantA).apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: [], sourceStore: emptyStore())
        let bodies = writes(server).map(\.bodyString)
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0.contains(ItemIdentity.profileMarker(for: profile.id)) })
    }

    @Test("Bug 4: an app without uploaded content plans an upload")
    func appWithoutContentIsUploadedAgain() throws {
        let item = makeItem("apps/Tool.pkg", type: .app)
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [item.id]
        let info = AppPackageInfo(primaryBundleID: "com.example.tool", primaryBundleVersion: "1.0", includedApps: [])
        let built = try PayloadBuilder.build(item: item, fileData: Data(), namingPrefix: "", variables: [:], appInfo: info,
                                             profileID: profile.id)
        func plan(committed: String?) -> Plan {
            var body = (try? JSONSerialization.jsonObject(with: built.body) as? [String: Any]) ?? [:]
            body["committedContentVersion"] = committed
            let remote = RemoteObject(id: "app-1", displayName: built.displayName, description: "[IntuneDeployer:\(item.id)]",
                                      body: try! JSONSerialization.data(withJSONObject: body))
            return PlanEngine.makePlan(input: PlanInput(selectedItems: [.init(item: item, fileData: Data(), appInfo: info)],
                                                        profile: profile, existingObjects: [.apps: [remote]], groups: [:],
                                                        knownSettingDefinitionIDs: nil))
        }
        guard case .update(let changes) = plan(committed: nil).actions.first?.kind else {
            Issue.record("not an update")
            return
        }
        #expect(changes.map(\.path) == [PlanEngine.missingContentPath])
        #expect(plan(committed: "1").actions.first?.kind == .unchanged)
    }

    @Test("Bug 6: several groups with the same name are a plan error")
    func ambiguousGroupName() {
        let (plan, _, _) = scriptPlan(intent: AssignmentIntent(targets: [AssignmentTarget(scope: .group, groupName: "Lab Macs")]),
                                      groups: ["Lab Macs": .ambiguous(count: 2)])
        #expect(plan.hasErrors)
        #expect(plan.errors.first?.message.contains("2 groups are named “Lab Macs”") == true)
        #expect(plan.actions.first?.assignments == nil, "nothing is assigned")
    }

    @Test("Bug 10: a tenant filter without a platform isn't assigned")
    func filterWithoutPlatform() {
        let filter = RemoteObject(id: "f-1", displayName: "Lab Filter", description: nil, body: Data(#"{"displayName":"Lab Filter"}"#.utf8))
        var target = AssignmentTarget(scope: .group, groupName: "Lab Macs")
        target.filterName = "Lab Filter"
        let item = makeItem("compliance/encryption.json", type: .compliancePolicy)
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA)
        profile.selectedItemIDs = [item.id]
        profile.assignments[item.id] = AssignmentIntent(targets: [target])
        let plan = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [.init(item: item, fileData: Data(Fixtures.complianceJSON.utf8))], profile: profile,
            existingObjects: [.assignmentFilters: [filter]], groups: ["Lab Macs": .found(id: "g-1", isDynamic: false)],
            knownSettingDefinitionIDs: nil))
        #expect(plan.errors.contains { $0.message.contains("has no platform") })
    }
}
