import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Intune_Deployer

// Tenants are compared by the tenant ID Microsoft's sign-in names, not as
// typed: a profile with the tenant's domain and one with its tenant ID are
// the same tenant.

private let tenantA = "aaaaaaaa-0000-4000-8000-00000000000a"
private let tenantB = "bbbbbbbb-0000-4000-8000-00000000000b"
private let domainA = "contoso.example"

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

@MainActor
private func tenantStore(_ name: String) -> (TenantStore, URL) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-\(name)-\(UUID().uuidString)")
    let store = TenantStore(storageURL: folder.appending(path: "tenants.json"), defaults: TestSettings.makeDefaults(name).defaults)
    return (store, folder)
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<250 where !condition() {
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite("Tenants compared by their tenant ID")
struct TenantIdentityTests {
    @Test("The tenant field must be a tenant ID or a domain; the editor says so")
    func tenantIDIssue() {
        #expect(TenantProfile(tenantID: tenantA).tenantIDIssue == nil)
        #expect(TenantProfile(tenantID: " \(domainA) ").tenantIDIssue == nil)
        #expect(TenantProfile(tenantID: "").tenantIDIssue == nil, "an empty field is just not filled in yet")
        for wrong in ["organizations", "common", "contoso.example:443", "https://contoso.example", "contoso .example"] {
            #expect(TenantProfile(tenantID: wrong).tenantIDIssue?.contains("isn’t a tenant ID or a domain") == true, "\(wrong)")
        }
    }

    @Test("A sign-in's tenant ID counts only for the tenant field it was learned for")
    func knownTenantID() {
        var profile = TenantProfile(tenantID: tenantA.uppercased())
        #expect(profile.knownTenantID == tenantA)
        profile.tenantID = domainA
        #expect(profile.knownTenantID == nil)
        profile.signedInTenant = .init(typed: domainA, id: tenantA)
        #expect(profile.knownTenantID == tenantA)
        profile.tenantID = "fabrikam.example"
        #expect(profile.knownTenantID == nil, "the field changed since")
    }

    @MainActor
    @Test("A domain profile and a tenant ID profile of one tenant are the same tenant")
    func domainAndIDAreOneTenant() throws {
        let (store, folder) = tenantStore("same-tenant")
        defer { try? FileManager.default.removeItem(at: folder) }
        let byDomain = TenantProfile(displayName: "By domain", clientID: "c", tenantID: domainA)
        let byID = TenantProfile(displayName: "By ID", clientID: "c", tenantID: tenantA)
        try store.connections.save(byDomain)
        try store.connections.save(byID)

        // before the domain profile signed in: possibly the same tenant
        #expect(!store.isOnlyProfile(forTenantOf: byDomain), "its own tenant isn't known yet")
        #expect(!store.isOnlyProfile(forTenantOf: byID), "the domain could be this tenant")

        store.noteSignedInTenant(tenantA.uppercased(), for: byDomain.id, typed: domainA)
        #expect(!store.isOnlyProfile(forTenantOf: byDomain))
        #expect(!store.isOnlyProfile(forTenantOf: byID))

        // a domain of another tenant, once signed in, doesn't count
        store.noteSignedInTenant(tenantB, for: byDomain.id, typed: domainA)
        #expect(store.isOnlyProfile(forTenantOf: byDomain))
        #expect(store.isOnlyProfile(forTenantOf: byID))
    }

    @MainActor
    @Test("The learned tenant ID is saved in tenants.json, never exported, and dropped on import")
    func learnedTenantIsSaved() throws {
        let (store, folder) = tenantStore("learned")
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: domainA)
        try store.connections.save(profile)
        store.noteSignedInTenant(tenantA, for: profile.id, typed: "  CONTOSO.example ")
        #expect(store.saveError == nil)

        let reloaded = TenantStore(storageURL: folder.appending(path: "tenants.json"), defaults: TestSettings.makeDefaults("learned-2").defaults)
        let saved = try #require(reloaded.profiles.first)
        #expect(saved.knownTenantID == tenantA)
        #expect(reloaded.isOnlyProfile(forTenantOf: saved))

        let exported = try saved.exportText()
        #expect(!exported.contains("signedInTenant"))
        var withTenant = saved
        withTenant.signedInTenant = .init(typed: domainA, id: tenantA)
        let data = try JSONEncoder().encode(withTenant)
        #expect(try TenantProfile.importedProfile(from: data, existingIDs: []).signedInTenant == nil)

        // a field typed differently from the one it was learned for isn't saved
        store.noteSignedInTenant(tenantB, for: profile.id, typed: "fabrikam.example")
        #expect(store.profiles.first?.knownTenantID == tenantA)
    }

    @MainActor
    @Test("Plan of the only profile, typed as a domain, claims the objects from before profile tags; filters get no assignment reads")
    func planConfirmsDomainFirst() async throws {
        let root = try Fixtures.makeTree(files: ["filters/macs.json": Fixtures.assignmentFilterJSON, "scripts/hello.sh": Fixtures.plainScript])
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = SourceStore(folder: FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-domain-\(UUID().uuidString)"))
        sources.addLocalFolder(at: root)
        try await waitUntil { sources.items(for: Set(sources.sources.map(\.id))).count == 2 && sources.scanningSourceIDs.isEmpty }
        let items = sources.items(for: Set(sources.sources.map(\.id)))
        let filter = try #require(items.first { $0.type == .assignmentFilter })

        let (store, folder) = tenantStore("domain-plan")
        defer { try? FileManager.default.removeItem(at: folder) }
        var profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: domainA)
        profile.selectedItemIDs = Set(items.map(\.id))
        try store.connections.save(profile)

        // deployed by 1.5: the item tag only; and the filter, already in the tenant
        let legacy: [String: Any] = ["id": "legacy-1", "displayName": "Old script", "fileName": "old.sh",
                                     "description": "Managed by Intune Deployer [IntuneDeployer:0badc0de]",
                                     "scriptContent": Data("echo".utf8).base64EncodedString()]
        let deployedFilter: [String: Any] = ["id": "filter-1", "displayName": filter.displayName, "platform": "macOS",
                                             "rule": "(device.model -startsWith \"Mac\")",
                                             "description": "[IntuneDeployer:\(filter.id)]"]
        let legacyJSON = json(legacy)
        let scripts = json(["value": [legacy]])
        let filters = json(["value": [deployedFilter]])
        let server = MockServer { request in
            let path = request.path
            if path.hasSuffix("/organization") {
                return .json(200, json(["value": [["id": tenantA, "verifiedDomains": [["name": domainA]]]]]))
            }
            if path.hasSuffix("/deviceShellScripts") { return .json(200, scripts) }
            if path.hasSuffix("/deviceShellScripts/legacy-1") { return .json(200, legacyJSON) }
            if path.hasSuffix("/assignmentFilters") { return .json(200, filters) }
            if path.contains("assignmentFilters/") { return .json(400, #"{"error":{"code":"BadRequest","message":"No"}}"#) }
            return .json(200, #"{"value":[]}"#)
        }
        let guardLog = TestRun.AttemptLog(fileURL: folder.appending(path: "guard.jsonl"))
        let session = TenantSession(auth: AuthManager(underTest: .refuseAll(guardLog)), activityLog: ActivityLog(),
                                    realTenantSession: server.session, tokenProvider: { _, _, _ in token(tid: tenantA) })
        session.onTenantConfirmed = { profile, tenant in store.noteSignedInTenant(tenant, for: profile.id, typed: profile.tenantID) }

        #expect(!store.isOnlyProfile(forTenantOf: profile), "not known before the Plan's tenant check")
        await session.plan(profile: profile, items: items, sourceStore: sources,
                           isOnlyProfileForTenant: store.isOnlyProfile(forTenantOf: profile))
        let plan = try #require(session.currentPlan, "\(session.planError ?? "")")
        #expect(plan.orphans.map(\.objectID) == ["legacy-1"], "the tenant was confirmed first, so the rule applies")
        #expect(store.profiles.first?.knownTenantID == tenantA)
        #expect(!server.requests.contains { $0.path.contains("assignmentFilters/") }, "\(server.requests.map(\.path))")
    }
}

@Suite("Inventory and tenant export, end to end")
struct InventoryExportTests {
    @MainActor
    @Test("The inventory lists each collection and reports a failing one; export merges settings, expands compliance and reports failures")
    func inventoryAndExport() async throws {
        let policy: [String: Any] = ["id": "sc-1", "name": "[LAB] Dock", "description": "[IntuneDeployer:0a0b0c0d]",
                                     "platforms": "macOS", "technologies": "mdm"]
        let setting: [String: Any] = ["id": "0", "settingInstance": [
            "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
            "settingDefinitionId": "com.apple.dock_autohide",
            "choiceSettingValue": ["value": "com.apple.dock_autohide_true", "children": [] as [Any]],
        ]]
        let compliance: [String: Any] = ["id": "cp-1", "@odata.type": "#microsoft.graph.macOSCompliancePolicy",
                                         "displayName": "[LAB] Encryption", "storageRequireEncryption": true,
                                         "scheduledActionsForRule": [["ruleName": NSNull(), "scheduledActionConfigurations": [
                                             ["actionType": "block", "gracePeriodHours": 0]]]]]
        let policyJSON = json(policy)
        let settings = json(["value": [setting]])
        let policies = json(["value": [policy]])
        let compliances = json(["value": [compliance]])
        let server = MockServer { request in
            let path = request.path
            if path.hasSuffix("/configurationPolicies/sc-1/settings") { return .json(200, settings) }
            if path.hasSuffix("/configurationPolicies/sc-1") { return .json(200, policyJSON) }
            if path.hasSuffix("/configurationPolicies") { return .json(200, policies) }
            if path.hasSuffix("/deviceCompliancePolicies") { return .json(200, compliances) }
            if path.hasSuffix("/deviceShellScripts") || path.contains("/deviceShellScripts/") {
                return .json(403, #"{"error":{"code":"Forbidden","message":"Not allowed"}}"#)
            }
            return .json(200, #"{"value":[]}"#)
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let guardLog = TestRun.AttemptLog(fileURL: folder.appending(path: "guard.jsonl"))
        let session = TenantSession(auth: AuthManager(underTest: .refuseAll(guardLog)), activityLog: ActivityLog(),
                                    realTenantSession: server.session, tokenProvider: { _, _, _ in token(tid: tenantA) })
        let profile = TenantProfile(displayName: "Lab", clientID: "c", tenantID: tenantA, namingPrefix: "[LAB]")

        await session.loadInventory(for: profile)
        #expect(session.inventory[.settingsCatalog]?.map(\.id) == ["sc-1"])
        #expect(session.inventory[.compliancePolicies]?.map(\.id) == ["cp-1"])
        #expect(session.inventoryErrors[.shellScripts] != nil, "a refused collection is reported")
        #expect(session.inventoryErrors[.settingsCatalog] == nil)

        let summary = await session.export([
            ExportSelection(collection: .settingsCatalog, objectID: "sc-1", name: "[LAB] Dock"),
            ExportSelection(collection: .compliancePolicies, objectID: "cp-1", name: "[LAB] Encryption"),
            ExportSelection(collection: .shellScripts, objectID: "sh-1", name: "Refused script"),
        ], profile: profile, to: folder.appending(path: "out"))
        #expect(summary.written.count == 2, "\(summary.written) \(summary.skipped)")
        #expect(summary.skipped.map(\.name) == ["Refused script"])
        #expect(server.requests.contains { $0.url.absoluteString.contains("scheduledActionsForRule") }, "compliance is read expanded")
        let catalog = try #require(summary.written.first { $0.hasSuffix(".json") && !$0.lowercased().contains("compliance") })
        let text = try String(contentsOf: folder.appending(path: "out").appending(path: catalog), encoding: .utf8)
        #expect(text.contains("com.apple.dock_autohide"), "the settings are merged into the policy")
        #expect(!text.contains("IntuneDeployer"), "no tags in exported files")
        #expect(!text.contains("[LAB]"), "no naming prefix in exported files")
    }
}
