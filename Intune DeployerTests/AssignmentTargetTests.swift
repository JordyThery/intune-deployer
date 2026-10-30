import Foundation
import Testing
@testable import Intune_Deployer

private let sourceID = UUID(uuidString: "55555555-4444-3333-2222-111111111111")!

private func makeItem(_ relativePath: String, type: ItemType, platform: ItemPlatform = .macOS) -> InferredItem {
    let url = URL(filePath: "/tmp/fixture/\(relativePath)")
    return InferredItem(
        id: ItemIdentity.shortID(sourceID: sourceID, relativePath: relativePath),
        sourceID: sourceID,
        relativePath: relativePath,
        fileURL: url,
        type: type,
        platform: platform,
        displayName: url.deletingPathExtension().lastPathComponent,
        detectionReason: "test"
    )
}

private func plan(
    _ intent: AssignmentIntent,
    item: InferredItem = makeItem("c.json", type: .compliancePolicy),
    fixture: String = Fixtures.complianceJSON,
    groups: [String: GroupLookup] = [:]
) -> Plan {
    PlanEngine.makePlan(input: PlanInput(
        selectedItems: [.init(item: item, fileData: Data(fixture.utf8))],
        profile: TenantProfile(
            displayName: "T", clientID: "e445f0a6-0000-0000-0000-000000000000", tenantID: "t",
            selectedItemIDs: [item.id],
            assignments: [item.id: intent]
        ),
        existingObjects: [:],
        groups: groups,
        knownSettingDefinitionIDs: nil
    ))
}

@Suite("Assignment targets")
struct AssignmentTargetTests {
    @Test func includesAndExclusionsResolveTogether() throws {
        var intent = AssignmentIntent(targets: [
            AssignmentTarget(scope: .allDevices),
            AssignmentTarget(scope: .group, groupName: "Pilot Macs"),
            AssignmentTarget(kind: .exclude, scope: .group, groupName: "Lab Devices"),
        ])
        intent.targets[0].filterName = BuiltInFilterTemplate.name(for: .macOS)
        let profile = TenantProfile(
            displayName: "T", clientID: "c", tenantID: "t",
            variables: ["EnrollmentProfileName": "ADE"]
        )
        let item = makeItem("c.json", type: .compliancePolicy)
        let result = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [.init(item: item, fileData: Data(Fixtures.complianceJSON.utf8))],
            profile: {
                var p = profile
                p.selectedItemIDs = [item.id]
                p.assignments = [item.id: intent]
                return p
            }(),
            existingObjects: [:],
            groups: ["Pilot Macs": .found(id: "g1", isDynamic: false), "Lab Devices": .found(id: "g2", isDynamic: false)],
            knownSettingDefinitionIDs: nil
        ))
        #expect(!result.hasErrors, "\(result.errors.map(\.message))")
        let assignments = try #require(result.actions.first?.assignments)
        #expect(assignments.count == 3)
        #expect(assignments[0].target == .allDevices && assignments[0].filter != nil)
        #expect(assignments[1].target == .group(id: "g1", name: "Pilot Macs") && !assignments[1].isExclusion)
        #expect(assignments[2].target == .group(id: "g2", name: "Lab Devices") && assignments[2].isExclusion)
        #expect(assignments[2].filter == nil)
    }

    @Test func sameGroupIncludedAndExcludedIsAnError() {
        let result = plan(
            AssignmentIntent(targets: [
                AssignmentTarget(scope: .group, groupName: "Pilots"),
                AssignmentTarget(kind: .exclude, scope: .group, groupName: "pilots"),
            ]),
            groups: ["Pilots": .found(id: "g1", isDynamic: false), "pilots": .found(id: "g1", isDynamic: false)]
        )
        #expect(result.hasErrors)
        // Never a partial list that would replace the tenant's assignments.
        #expect(result.actions.first?.assignments == nil)
    }

    @Test func exclusionsMustTargetGroups() {
        let result = plan(AssignmentIntent(targets: [AssignmentTarget(kind: .exclude, scope: .allDevices)]))
        #expect(result.hasErrors)
        #expect(result.actions.first?.assignments == nil)
    }

    @Test func overlappingAndExclusionOnlyListsWarn() {
        let both = plan(AssignmentIntent(targets: [AssignmentTarget(scope: .allDevices), AssignmentTarget(scope: .allUsers)]))
        #expect(!both.hasErrors)
        #expect(both.actions.first?.warnings.contains { $0.contains("both All devices and All users") } == true)

        let onlyExcludes = plan(
            AssignmentIntent(targets: [AssignmentTarget(kind: .exclude, scope: .group, groupName: "Lab")]),
            groups: ["Lab": .found(id: "g", isDynamic: false)]
        )
        #expect(onlyExcludes.actions.first?.warnings.contains { $0.contains("Only exclusions") } == true)
    }

    @Test func duplicateTargetsCollapseOrConflict() throws {
        let groups: [String: GroupLookup] = ["Pilots": .found(id: "g1", isDynamic: false), "pilots ": .found(id: "g1", isDynamic: false)]
        let repeated = plan(
            AssignmentIntent(targets: [
                AssignmentTarget(scope: .group, groupName: "Pilots"),
                AssignmentTarget(scope: .group, groupName: "pilots "),
            ]),
            groups: groups
        )
        #expect(!repeated.hasErrors)
        #expect(try #require(repeated.actions.first?.assignments).count == 1)

        var filtered = AssignmentTarget(scope: .group, groupName: "pilots ")
        filtered.filterName = "Some Filter"
        let ambiguous = plan(AssignmentIntent(targets: [AssignmentTarget(scope: .group, groupName: "Pilots"), filtered]), groups: groups)
        #expect(ambiguous.errors.contains { $0.message.contains("more than once") })
        #expect(ambiguous.actions.first?.assignments == nil)
    }

    @Test func emptyTargetListLeavesAssignmentsUntouched() {
        let result = plan(AssignmentIntent())
        #expect(result.actions.first?.assignments == nil)
    }

    @Test func singleTargetIntentsFromEarlierBuildsLoadAsOneTarget() throws {
        let legacy = Data(#"{"mode":"group","groupName":"Pilots","filterName":"ADE","filterMode":"exclude","appIntent":"available"}"#.utf8)
        let intent = try JSONDecoder().decode(AssignmentIntent.self, from: legacy)
        #expect(intent.targets == [{
            var t = AssignmentTarget(scope: .group, groupName: "Pilots")
            t.filterName = "ADE"
            t.filterMode = .exclude
            t.appIntent = .available
            return t
        }()])

        let none = try JSONDecoder().decode(AssignmentIntent.self, from: Data(#"{"mode":"none"}"#.utf8))
        #expect(none.leavesUnchanged)

        // Round trip in the new format.
        let encoded = try JSONEncoder().encode(intent)
        #expect(try JSONDecoder().decode(AssignmentIntent.self, from: encoded) == intent)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"targets\""))
    }

    @Test func profilesFromEarlierBuildsKeepTheirAssignments() throws {
        let legacy = Data("""
        {"id":"11111111-2222-3333-4444-555555555555","displayName":"Old","tenantID":"t",
         "assignments":{"abc12345":{"mode":"allDevices","groupName":"","filterName":"","filterMode":"include"}},
         "defaultAssignments":["shellScript",{"mode":"allUsers","groupName":"","filterName":"","filterMode":"include"}]}
        """.utf8)
        let profile = try JSONDecoder().decode(TenantProfile.self, from: legacy)
        #expect(profile.assignments["abc12345"]?.targets.first?.scope == .allDevices)
        #expect(profile.defaultAssignments[.shellScript]?.targets.first?.scope == .allUsers)
    }
}

// MARK: - Settings Catalog diff

@Suite("Settings Catalog diff")
struct SettingsCatalogDiffTests {
    private func policy(_ settings: String) -> Data {
        Data(#"{"name":"P","platforms":"macOS","technologies":"mdm","settings":[\#(settings)]}"#.utf8)
    }

    private func choice(_ id: String, _ value: String, children: String = "") -> String {
        ##"{"settingInstance":{"@odata.type":"#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance","settingDefinitionId":"\##(id)","choiceSettingValue":{"value":"\##(value)","children":[\##(children)]}}}"##
    }

    private func group(_ id: String, children: String) -> String {
        ##"{"settingInstance":{"@odata.type":"#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance","settingDefinitionId":"\##(id)","groupSettingCollectionValue":[{"children":[\##(children)]}]}}"##
    }

    private func childChoice(_ id: String, _ value: String) -> String {
        ##"{"@odata.type":"#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance","settingDefinitionId":"\##(id)","choiceSettingValue":{"value":"\##(value)","children":[]}}"##
    }

    @Test func changedAddedAndRemovedSettingsAreReportedWithParents() throws {
        let remote = policy(group("restrictions", children: [
            childChoice("allowcamera", "allowcamera_true"),
            childChoice("allowairdrop", "allowairdrop_true"),
        ].joined(separator: ",")))
        let desired = policy(group("restrictions", children: [
            childChoice("allowcamera", "allowcamera_false"),
            childChoice("allowscreenshot", "allowscreenshot_false"),
        ].joined(separator: ",")))

        let changes = try #require(SettingsCatalogDiff.changes(desired: desired, remote: remote))
        let byID = Dictionary(uniqueKeysWithValues: changes.map { ($0.definitionID, $0) })
        #expect(byID["allowcamera"]?.kind == .changed)
        #expect(byID["allowcamera"]?.oldValue == "allowcamera_true")
        #expect(byID["allowcamera"]?.newValue == "allowcamera_false")
        #expect(byID["allowcamera"]?.parentDefinitionIDs == ["restrictions"])
        #expect(byID["allowscreenshot"]?.kind == .added)
        #expect(byID["allowairdrop"]?.kind == .removed)
        #expect(SettingsCatalogDiff.referencedDefinitionIDs(changes).contains("restrictions"))
    }

    @Test func reorderedSettingsAreNotChanges() throws {
        let first = choice("a", "a_1")
        let second = choice("b", "b_1")
        let changes = try #require(SettingsCatalogDiff.changes(
            desired: policy([first, second].joined(separator: ",")),
            remote: policy([second, first].joined(separator: ","))
        ))
        #expect(changes.isEmpty)
    }

    @Test func reorderedSettingsPlanAsUnchangedButRealChangesStillUpdate() throws {
        let item = makeItem("sc/p.json", type: .settingsCatalog)
        let profile = TenantProfile(displayName: "T", clientID: "c", tenantID: "t", selectedItemIDs: [item.id])
        let built = try PayloadBuilder.build(item: item, fileData: Data(Fixtures.settingsCatalogJSON.utf8), namingPrefix: "", variables: [:],
                                             profileID: profile.id)

        // Same body, settings array reversed on the remote side.
        var remoteDict = try #require(try JSONSerialization.jsonObject(with: built.body) as? [String: Any])
        let settings = try #require(remoteDict["settings"] as? [Any])
        remoteDict["settings"] = Array(settings.reversed()) + []
        let remote = RemoteObject(
            id: "obj", displayName: built.displayName,
            description: "x [IntuneDeployer:\(item.id)]",
            body: try JSONSerialization.data(withJSONObject: remoteDict)
        )
        let unchanged = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [.init(item: item, fileData: Data(Fixtures.settingsCatalogJSON.utf8))],
            profile: profile, existingObjects: [.settingsCatalog: [remote]], groups: [:], knownSettingDefinitionIDs: nil
        ))
        #expect(unchanged.actions.first?.kind == .unchanged)

        // A real value change plans as an update with a setting change.
        let edited = Fixtures.settingsCatalogJSON.replacingOccurrences(of: "allowcontentcaching_false", with: "allowcontentcaching_true")
        let changed = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [.init(item: item, fileData: Data(edited.utf8))],
            profile: profile, existingObjects: [.settingsCatalog: [remote]], groups: [:], knownSettingDefinitionIDs: nil
        ))
        guard case .update(let raw) = changed.actions.first?.kind else {
            Issue.record("Expected an update")
            return
        }
        #expect(!raw.isEmpty) // raw view still has the field-level change
        #expect(changed.actions.first?.settingChanges.map(\.kind) == [.changed])
    }

    @Test func changesOutsideComparedFieldsFallBackToRawUpdate() throws {
        let item = makeItem("sc/p.json", type: .settingsCatalog)
        let profile = TenantProfile(displayName: "T", clientID: "c", tenantID: "t", selectedItemIDs: [item.id])
        let built = try PayloadBuilder.build(item: item, fileData: Data(Fixtures.settingsCatalogJSON.utf8), namingPrefix: "", variables: [:],
                                             profileID: profile.id)
        func planAgainst(_ edit: (inout [String: Any]) -> Void) throws -> PlanItemAction? {
            var remoteDict = try #require(try JSONSerialization.jsonObject(with: built.body) as? [String: Any])
            edit(&remoteDict)
            let remote = RemoteObject(
                id: "obj", displayName: built.displayName,
                description: "x [IntuneDeployer:\(item.id)]",
                body: try JSONSerialization.data(withJSONObject: remoteDict)
            )
            return PlanEngine.makePlan(input: PlanInput(
                selectedItems: [.init(item: item, fileData: Data(Fixtures.settingsCatalogJSON.utf8))],
                profile: profile, existingObjects: [.settingsCatalog: [remote]], groups: [:], knownSettingDefinitionIDs: nil
            )).actions.first
        }

        // A template reference only the raw diff sees still plans an update.
        let templated = Fixtures.settingsCatalogJSON.replacingOccurrences(
            of: #""settingDefinitionId": "com.apple.applicationaccess_com.apple.applicationaccess","#,
            with: #""settingDefinitionId": "com.apple.applicationaccess_com.apple.applicationaccess", "settingInstanceTemplateReference": {"settingInstanceTemplateId": "t1"},"#
        )
        let templatedBuilt = try PayloadBuilder.build(item: item, fileData: Data(templated.utf8), namingPrefix: "", variables: [:])
        let remote = RemoteObject(id: "obj", displayName: built.displayName, description: "x [IntuneDeployer:\(item.id)]", body: built.body)
        let templatedPlan = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [.init(item: item, fileData: Data(templated.utf8))],
            profile: profile, existingObjects: [.settingsCatalog: [remote]], groups: [:], knownSettingDefinitionIDs: nil
        ))
        #expect(templatedBuilt.body != built.body)
        guard case .update = templatedPlan.actions.first?.kind else {
            Issue.record("A template reference change must plan as an update")
            return
        }

        // A name change plans an update without positional settings noise.
        let renamed = try #require(try planAgainst { $0["name"] = "Old name" })
        guard case .update(let changes) = renamed.kind else {
            Issue.record("Expected an update")
            return
        }
        #expect(changes.map(\.path) == ["name"])
    }

    @Test func emptyGroupInstanceCountsAsAChange() throws {
        let one = policy(group("g", children: childChoice("c", "c_1")))
        let two = Data(##"{"name":"P","settings":[{"settingInstance":{"@odata.type":"#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance","settingDefinitionId":"g","groupSettingCollectionValue":[{"children":[{"@odata.type":"#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance","settingDefinitionId":"c","choiceSettingValue":{"value":"c_1","children":[]}}]},{"children":[]}]}}]}"##.utf8)
        let changes = try #require(SettingsCatalogDiff.changes(desired: two, remote: one))
        #expect(changes.map(\.definitionID) == ["g"])
    }

    @Test func unknownInstanceTypesStillDetectChanges() throws {
        let custom = { (value: String) in
            ##"{"settingInstance":{"@odata.type":"#microsoft.graph.someFutureInstance","settingDefinitionId":"x","futureValue":{"v":"\##(value)"}}}"##
        }
        let changes = try #require(SettingsCatalogDiff.changes(desired: policy(custom("1")), remote: policy(custom("2"))))
        #expect(changes.map(\.kind) == [.changed])
    }
}
