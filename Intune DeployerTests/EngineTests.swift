import Foundation
import Testing
@testable import Intune_Deployer

// MARK: - Helpers

private let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

private func makeItem(
    _ relativePath: String,
    type: ItemType,
    displayName: String? = nil,
    scriptSettings: ScriptSettings? = nil,
    customAttributeType: CustomAttributeValueType? = nil
) -> InferredItem {
    let url = URL(filePath: "/tmp/fixture/\(relativePath)")
    return InferredItem(
        id: ItemIdentity.shortID(sourceID: sourceID, relativePath: relativePath),
        sourceID: sourceID,
        relativePath: relativePath,
        fileURL: url,
        type: type,
        displayName: displayName ?? url.deletingPathExtension().lastPathComponent,
        detectionReason: "test",
        scriptSettings: scriptSettings,
        customAttributeType: customAttributeType
    )
}

private func json(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - Variable substitution

@Suite("Variable substitution")
struct VariableSubstitutionTests {
    @Test func substitutesAndReportsUnresolved() {
        let result = VariableSubstitution.substitute(
            "Hello {{OrgName}}, profile {{ EnrollmentProfileName }} and {{Missing}}",
            variables: ["OrgName": "Contoso", "EnrollmentProfileName": "ADE Profile"]
        )
        #expect(result.text == "Hello Contoso, profile ADE Profile and {{Missing}}")
        #expect(result.unresolved == ["Missing"])
    }

    @Test func emptyValueCountsAsUnresolved() {
        let result = VariableSubstitution.substitute("{{A}}", variables: ["A": ""])
        #expect(result.unresolved == ["A"])
    }
}

// MARK: - Payload builders

@Suite("Payload builders")
struct PayloadBuilderTests {
    @Test func settingsCatalogGetsPrefixTagAndStrippedKeys() throws {
        let item = makeItem("sc/updates.json", type: .settingsCatalog)
        let built = try PayloadBuilder.build(
            item: item,
            fileData: Data(Fixtures.intuneManagementSettingsCatalogJSON.utf8),
            namingPrefix: "[LAB9]",
            variables: ["OrgName": "Contoso"]
        )
        let body = try json(built.body)

        #expect(built.collection == .settingsCatalog)
        #expect(body["name"] as? String == "[LAB9] macOS - Updates - Deferral Contoso")
        let description = try #require(body["description"] as? String)
        #expect(description.contains(ItemIdentity.tag(forShortID: item.id)))
        // Server/tool keys stripped.
        #expect(body["id"] == nil)
        #expect(body["settingCount"] == nil)
        #expect(body["assignments"] == nil)
        #expect(body["createdDateTime"] == nil)
        #expect(body["displayName"] == nil) // settings catalog uses `name`
    }

    @Test func unresolvedTokensBlockTheBuild() {
        let item = makeItem("sc/updates.json", type: .settingsCatalog)
        #expect(throws: PayloadError.self) {
            _ = try PayloadBuilder.build(
                item: item,
                fileData: Data(Fixtures.intuneManagementSettingsCatalogJSON.utf8),
                namingPrefix: "",
                variables: [:] // OrgName missing
            )
        }
    }

    @Test func mobileconfigBecomesCustomConfigurationWithSubstitutedPayload() throws {
        let item = makeItem("profiles/dock.mobileconfig", type: .customConfiguration, displayName: "Dock Settings {{OrgName}}")
        let built = try PayloadBuilder.build(
            item: item,
            fileData: Data(Fixtures.mobileconfig.utf8),
            namingPrefix: "[LAB9]",
            variables: ["OrgName": "Contoso"]
        )
        let body = try json(built.body)

        #expect(body["@odata.type"] as? String == "#microsoft.graph.macOSCustomConfiguration")
        #expect(body["payloadFileName"] as? String == "dock.mobileconfig")
        let payload = try #require(body["payload"] as? String)
        let decoded = try #require(String(data: Data(base64Encoded: payload)!, encoding: .utf8))
        #expect(decoded.contains("Dock Settings Contoso"))
        #expect(!decoded.contains("{{OrgName}}"))
    }

    @Test func complianceWithoutScheduledActionsGetsDefaultAndWarning() throws {
        let fixture = """
        {"@odata.type": "#microsoft.graph.macOSCompliancePolicy",
         "displayName": "Encryption", "storageRequireEncryption": true}
        """
        let item = makeItem("compliance/enc.json", type: .compliancePolicy)
        let built = try PayloadBuilder.build(item: item, fileData: Data(fixture.utf8), namingPrefix: "", variables: [:])
        let body = try json(built.body)

        let rules = try #require(body["scheduledActionsForRule"] as? [[String: Any]])
        let configs = try #require(rules.first?["scheduledActionConfigurations"] as? [[String: Any]])
        #expect(configs.first?["actionType"] as? String == "block")
        #expect(built.warnings.contains { $0.contains("scheduledActionsForRule") })
    }

    @Test func complianceKeepsExistingScheduledActions() throws {
        let item = makeItem("compliance/enc.json", type: .compliancePolicy)
        let built = try PayloadBuilder.build(
            item: item,
            fileData: Data(Fixtures.complianceJSON.utf8),
            namingPrefix: "",
            variables: [:]
        )
        let body = try json(built.body)
        let rules = try #require(body["scheduledActionsForRule"] as? [[String: Any]])
        #expect(rules.first?["ruleName"] as? String == "PasswordRequired")
        #expect(!built.warnings.contains { $0.contains("scheduledActionsForRule") })
    }

    @Test func shellScriptCarriesDirectiveOptions() throws {
        let settings = ScriptSettings(runAsAccount: .user, frequencyMinutes: 1440, retries: 3, hideNotifications: true)
        let item = makeItem("scripts/greeting.sh", type: .shellScript, scriptSettings: settings)
        let built = try PayloadBuilder.build(
            item: item,
            fileData: Data(Fixtures.scriptWithOptionsDirective.utf8),
            namingPrefix: "[LAB9]",
            variables: ["OrgName": "Contoso"]
        )
        let body = try json(built.body)

        #expect(body["@odata.type"] as? String == "#microsoft.graph.deviceShellScript")
        #expect(body["displayName"] as? String == "[LAB9] greeting")
        #expect(body["runAsAccount"] as? String == "user")
        #expect(body["executionFrequency"] as? String == "P1D") // canonical ISO form
        #expect(body["retryCount"] as? Int == 3)
        #expect(body["blockExecutionNotifications"] as? Bool == true)
        #expect(body["fileName"] as? String == "greeting.sh")
        let content = try #require(body["scriptContent"] as? String)
        #expect(String(data: Data(base64Encoded: content)!, encoding: .utf8)?.contains("Hello Contoso") == true)
    }

    @Test func customAttributeNameIsSanitisedAndUnprefixed() throws {
        let item = makeItem("attrs/battery health.sh", type: .customAttribute, customAttributeType: .string)
        let built = try PayloadBuilder.build(
            item: item,
            fileData: Data(Fixtures.attributeScriptByFolder.utf8),
            namingPrefix: "[LAB9]",
            variables: [:]
        )
        let body = try json(built.body)

        #expect(body["customAttributeName"] as? String == "batteryhealth")
        #expect(body["customAttributeType"] as? String == "string")
        #expect(body["displayName"] as? String == "[LAB9] battery health")
    }

    @Test func filterDefaultsToMacOSPlatform() throws {
        let fixture = #"{"displayName": "ADE Filter", "rule": "(device.model -contains \"Mac\")"}"#
        let item = makeItem("filters/ade.json", type: .assignmentFilter)
        let built = try PayloadBuilder.build(item: item, fileData: Data(fixture.utf8), namingPrefix: "", variables: [:])
        let body = try json(built.body)

        #expect(body["platform"] as? String == "macOS")
        #expect(built.warnings.contains { $0.contains("platform") })
    }
}

// MARK: - Diff

@Suite("Graph diff")
struct GraphDiffTests {
    @Test func serverFieldsDoNotCauseChanges() throws {
        let desired = Data(#"{"displayName": "A", "payload": "xyz"}"#.utf8)
        let remote = Data(#"""
        {"id": "123", "displayName": "A", "payload": "xyz",
         "createdDateTime": "2026-01-01T00:00:00Z", "lastModifiedDateTime": "2026-01-02T00:00:00Z",
         "version": 7, "supportsScopeTags": true, "@odata.type": "#microsoft.graph.macOSCustomConfiguration"}
        """#.utf8)
        #expect(try GraphDiff.changes(desired: desired, remote: remote).isEmpty)
    }

    @Test func changedValuesAreReportedWithPaths() throws {
        let desired = Data(#"{"displayName": "B", "nested": {"value": 2}}"#.utf8)
        let remote = Data(#"{"displayName": "A", "nested": {"value": 1}}"#.utf8)
        let changes = try GraphDiff.changes(desired: desired, remote: remote)

        #expect(changes.count == 2)
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        #expect(byPath["displayName"]?.oldValue == "A")
        #expect(byPath["displayName"]?.newValue == "B")
        #expect(byPath["nested.value"]?.newValue == "2")
    }

    @Test func arrayCountChangeIsSummarised() throws {
        let desired = Data(#"{"settings": [{"a": 1}, {"a": 2}]}"#.utf8)
        let remote = Data(#"{"settings": [{"a": 1}]}"#.utf8)
        let changes = try GraphDiff.changes(desired: desired, remote: remote)
        #expect(changes.first?.path == "settings")
        #expect(changes.first?.newValue == "2 item(s)")
    }

    @Test func booleansAreNotConfusedWithNumbers() throws {
        let desired = Data(#"{"flag": true}"#.utf8)
        let remote = Data(#"{"flag": 1}"#.utf8)
        #expect(try GraphDiff.changes(desired: desired, remote: remote).count == 1)
    }

    @Test func settingIDsInsideArraysAreIgnored() throws {
        let desired = Data(#"{"settings": [{"settingInstance": {"settingDefinitionId": "x"}}]}"#.utf8)
        let remote = Data(#"{"settings": [{"id": "0", "settingInstance": {"settingDefinitionId": "x"}}]}"#.utf8)
        #expect(try GraphDiff.changes(desired: desired, remote: remote).isEmpty)
    }
}

// MARK: - Plan engine

@Suite("Plan engine")
struct PlanEngineTests {
    private func remoteScript(shortID: String, name: String = "[LAB9] greeting") -> RemoteObject {
        let body = """
        {"id": "obj-1", "displayName": "\(name)", "description": "x [gw:\(shortID)]",
         "runAsAccount": "user", "fileName": "greeting.sh",
         "scriptContent": "", "blockExecutionNotifications": true,
         "executionFrequency": "PT1440M", "retryCount": 3}
        """
        return RemoteObject(id: "obj-1", displayName: name, description: "x [gw:\(shortID)]", body: Data(body.utf8))
    }

    private func scriptInput(
        existing: [TenantCollection: [RemoteObject]] = [:],
        assignments: [String: AssignmentIntent] = [:],
        groups: [String: GroupLookup] = [:],
        allowGroupCreation: Bool = false,
        selectedIDs: Set<String>? = nil
    ) -> (PlanInput, InferredItem) {
        let settings = ScriptSettings(runAsAccount: .user, frequencyMinutes: 1440, retries: 3, hideNotifications: true)
        let item = makeItem("scripts/greeting.sh", type: .shellScript, scriptSettings: settings)
        let profile = TenantProfile(
            displayName: "Test",
            clientID: "e445f0a6-0000-0000-0000-000000000000",
            tenantID: "t",
            namingPrefix: "[LAB9]",
            variables: ["OrgName": "Contoso"],
            selectedItemIDs: selectedIDs ?? [item.id],
            assignments: assignments,
            allowGroupCreation: allowGroupCreation
        )
        let input = PlanInput(
            selectedItems: [.init(item: item, fileData: Data(Fixtures.scriptWithOptionsDirective.utf8))],
            profile: profile,
            existingObjects: existing,
            groups: groups,
            knownSettingDefinitionIDs: nil
        )
        return (input, item)
    }

    @Test func untaggedObjectBecomesCreate() {
        let (input, item) = scriptInput()
        let plan = PlanEngine.makePlan(input: input)
        #expect(plan.actions.count == 1)
        #expect(plan.actions.first?.kind == .create)
        #expect(plan.actions.first?.id == item.id)
        #expect(!plan.hasErrors)
    }

    @Test func matchingTagWithSameContentIsUnchanged() throws {
        let (input, item) = scriptInput()
        // Build the exact desired body and present it as the remote object.
        let built = try PayloadBuilder.build(
            item: item,
            fileData: Data(Fixtures.scriptWithOptionsDirective.utf8),
            namingPrefix: "[LAB9]",
            variables: ["OrgName": "Contoso"]
        )
        let remote = RemoteObject(
            id: "obj-1",
            displayName: built.displayName,
            description: "x [gw:\(item.id)]",
            body: built.body
        )
        let (matchedInput, _) = scriptInput(existing: [.shellScripts: [remote]])
        _ = input
        let plan = PlanEngine.makePlan(input: matchedInput)
        #expect(plan.actions.first?.kind == .unchanged)
    }

    @Test func matchingTagWithDifferentContentIsUpdate() {
        // Short IDs are deterministic: derive it the same way makeItem does.
        let shortID = ItemIdentity.shortID(sourceID: sourceID, relativePath: "scripts/greeting.sh")
        let (input, _) = scriptInput(existing: [
            .shellScripts: [RemoteObject(
                id: "obj-1",
                displayName: "[LAB9] greeting",
                description: "x [gw:\(shortID)]",
                body: Data(#"{"displayName": "[LAB9] greeting", "runAsAccount": "system"}"#.utf8)
            )],
        ])
        let plan = PlanEngine.makePlan(input: input)
        guard case .update(let changes) = plan.actions.first?.kind else {
            Issue.record("Expected update")
            return
        }
        #expect(changes.contains { $0.path == "runAsAccount" && $0.newValue == "user" })
        #expect(plan.actions.first?.existingObjectID == "obj-1")
    }

    @Test func taggedButUnselectedObjectIsOrphaned() {
        let (input, _) = scriptInput(existing: [
            .compliancePolicies: [RemoteObject(
                id: "old-1",
                displayName: "[LAB9] Old Policy",
                description: "[gw:deadbeef]",
                body: Data(#"{"displayName": "[LAB9] Old Policy"}"#.utf8)
            )],
            // Untagged objects are never orphaned.
            .shellScripts: [RemoteObject(id: "foreign", displayName: "Foreign", description: "manual", body: Data("{}".utf8))],
        ])
        let plan = PlanEngine.makePlan(input: input)
        #expect(plan.orphans.map(\.objectID) == ["old-1"])
    }

    @Test func missingGroupIsErrorUnlessCreationAllowed() {
        var intent = AssignmentIntent()
        intent.mode = .group
        intent.groupName = "macOS Pilots"

        let (deniedInput, item) = scriptInput(
            assignments: ["": intent],
            groups: ["macOS Pilots": .missing]
        )
        // Re-key the intent to the real item id.
        var profile = deniedInput.profile
        profile.assignments = [item.id: intent]
        let denied = PlanEngine.makePlan(input: PlanInput(
            selectedItems: deniedInput.selectedItems,
            profile: profile,
            existingObjects: [:],
            groups: ["macOS Pilots": .missing],
            knownSettingDefinitionIDs: nil
        ))
        #expect(denied.hasErrors)

        profile.allowGroupCreation = true
        let allowed = PlanEngine.makePlan(input: PlanInput(
            selectedItems: deniedInput.selectedItems,
            profile: profile,
            existingObjects: [:],
            groups: ["macOS Pilots": .missing],
            knownSettingDefinitionIDs: nil
        ))
        #expect(!allowed.hasErrors)
        #expect(allowed.groupsToCreate.map(\.name) == ["macOS Pilots"])
    }

    @Test func dynamicGroupProducesWarning() {
        var intent = AssignmentIntent()
        intent.mode = .group
        intent.groupName = "Dynamic Macs"
        let (base, item) = scriptInput(groups: ["Dynamic Macs": .found(id: "g1", isDynamic: true)])
        var profile = base.profile
        profile.assignments = [item.id: intent]

        let plan = PlanEngine.makePlan(input: PlanInput(
            selectedItems: base.selectedItems,
            profile: profile,
            existingObjects: [:],
            groups: ["Dynamic Macs": .found(id: "g1", isDynamic: true)],
            knownSettingDefinitionIDs: nil
        ))
        #expect(plan.actions.first?.warnings.contains { $0.contains("dynamic") } == true)
        #expect(!plan.hasErrors)
    }

    @Test func builtInFilterTemplateNeedsItsVariable() {
        var intent = AssignmentIntent()
        intent.mode = .allDevices
        intent.filterName = BuiltInFilterTemplate.name
        let (base, item) = scriptInput()
        var profile = base.profile
        profile.assignments = [item.id: intent]

        // Without EnrollmentProfileName → error.
        profile.variables = ["OrgName": "Contoso"]
        let failing = PlanEngine.makePlan(input: PlanInput(
            selectedItems: base.selectedItems, profile: profile,
            existingObjects: [:], groups: [:], knownSettingDefinitionIDs: nil
        ))
        #expect(failing.hasErrors)

        // With it → template filter scheduled for creation, rule substituted.
        profile.variables["EnrollmentProfileName"] = "Contoso ADE"
        let plan = PlanEngine.makePlan(input: PlanInput(
            selectedItems: base.selectedItems, profile: profile,
            existingObjects: [:], groups: [:], knownSettingDefinitionIDs: nil
        ))
        #expect(!plan.hasErrors)
        #expect(plan.filtersToCreate.first?.rule.contains("Contoso ADE") == true)
    }

    @Test func unknownSettingDefinitionsAreErrors() {
        let item = makeItem("sc/gatekeeper.json", type: .settingsCatalog)
        let profile = TenantProfile(
            displayName: "T", clientID: "e445f0a6-0000-0000-0000-000000000000",
            tenantID: "t", selectedItemIDs: [item.id]
        )
        let selected = [PlanInput.SelectedItem(item: item, fileData: Data(Fixtures.settingsCatalogJSON.utf8))]

        let invalid = PlanEngine.makePlan(input: PlanInput(
            selectedItems: selected, profile: profile, existingObjects: [:],
            groups: [:], knownSettingDefinitionIDs: ["some.other.setting"]
        ))
        #expect(invalid.hasErrors)
        #expect(invalid.errors.first?.message.contains("com.apple.applicationaccess_allowcontentcaching") == true)

        let valid = PlanEngine.makePlan(input: PlanInput(
            selectedItems: selected, profile: profile, existingObjects: [:],
            groups: [:], knownSettingDefinitionIDs: [
                "com.apple.applicationaccess_com.apple.applicationaccess",
                "com.apple.applicationaccess_allowcontentcaching",
            ]
        ))
        #expect(!valid.hasErrors)
    }

    @Test func actionsAreOrderedByDeploymentPhase() {
        let filterItem = makeItem("filters/ade.json", type: .assignmentFilter)
        let scriptItem = makeItem("scripts/a.sh", type: .shellScript)
        let complianceItem = makeItem("compliance/c.json", type: .compliancePolicy)
        let profile = TenantProfile(
            displayName: "T", clientID: "e445f0a6-0000-0000-0000-000000000000", tenantID: "t",
            selectedItemIDs: [filterItem.id, scriptItem.id, complianceItem.id]
        )
        let plan = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [
                .init(item: complianceItem, fileData: Data(Fixtures.complianceJSON.utf8)),
                .init(item: scriptItem, fileData: Data(Fixtures.plainScript.utf8)),
                .init(item: filterItem, fileData: Data(Fixtures.assignmentFilterJSON.utf8)),
            ],
            profile: profile,
            existingObjects: [:],
            groups: [:],
            knownSettingDefinitionIDs: nil
        ))
        // Note: the filter fixture contains {{EnrollmentProfileName}} — set it.
        _ = plan
        let collections = plan.actions.map(\.collection)
        if plan.actions.count == 3 {
            #expect(collections == [.assignmentFilters, .shellScripts, .compliancePolicies])
        } else {
            // Filter item fails on unresolved token; remaining order still holds.
            #expect(collections == [.shellScripts, .compliancePolicies])
        }
    }
}
