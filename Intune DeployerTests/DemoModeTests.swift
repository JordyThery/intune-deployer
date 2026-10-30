import Foundation
import JTKit
import JTKitMSAL
import Testing
@testable import Intune_Deployer

/// Demo mode: "Contoso Intune (Demo)" on JTKit's demo tenant, run through the
/// app's real Plan, Apply, Remove Baseline, upload and Preflight, without MSAL
/// and without touching the saved tenants.
@MainActor
@Suite("Demo Mode", .serialized)
struct DemoModeTests {
    /// Counts every attempt to set up MSAL; fails it, so nothing can reach MSAL.
    final class MSALTrap {
        var calls = 0
        func make(_ clientID: String) throws -> MicrosoftSignIn {
            calls += 1
            throw MicrosoftSignInError.noWindow
        }
    }

    private func demoMode(scenario: String? = nil) -> DemoMode {
        let defaults = TestSettings.makeDefaults("demo").defaults
        var arguments = ["app"]
        if let scenario { arguments += [DemoMode.scenarioArgument, scenario] }
        let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: arguments)
        demo.isOn = true
        return demo
    }

    private func auth(_ demo: DemoMode?, trap: MSALTrap, underTest: UnderTestSignIn? = nil) -> AuthManager {
        guard let underTest else { return AuthManager(demo: demo, makeSignIn: { try trap.make($0) }) }
        return AuthManager(demo: demo, makeSignIn: { try trap.make($0) }, underTest: underTest)
    }

    /// The live lifecycle test's ten fixture items, scanned from a temporary source.
    private func fixtureItems() async throws -> (items: [InferredItem], store: SourceStore, root: URL, folder: URL) {
        let root = try Fixtures.makeTree(files: [
            "Settings Catalog/gatekeeper.json": Fixtures.settingsCatalogJSON,
            "Profiles/dock.mobileconfig": Fixtures.mobileconfig,
            "Compliance/encryption.json": Fixtures.complianceJSON,
            "Filters/ade.json": Fixtures.assignmentFilterJSON,
            "Scripts/greeting.sh": Fixtures.scriptWithOptionsDirective,
            "Custom Attributes/battery.sh": Fixtures.attributeScriptByFolder,
            "iOS Compliance/passcode.json": Fixtures.iosComplianceJSON,
            "iOS Catalog/restrictions.json": Fixtures.iosSettingsCatalogJSON,
            "iOS Filters/ade.json": Fixtures.iosFilterJSON,
            "iOS and iPadOS/Profiles/wifi.mobileconfig": Fixtures.mobileconfig,
        ])
        let folder = FileManager.default.temporaryDirectory.appending(path: "demo-\(UUID().uuidString)")
        let store = SourceStore(storageURL: folder.appending(path: "sources.json"),
                                editStore: ItemEditStore(storageURL: folder.appending(path: "item-edits.json")),
                                platformStore: PlatformOverrideStore(storageURL: folder.appending(path: "platform-overrides.json")))
        store.addLocalFolder(at: root)
        let sourceID = try #require(store.sources.first?.id)
        for _ in 0..<200 where store.items(for: [sourceID]).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        return (store.items(for: [sourceID]), store, root, folder)
    }

    private func demoProfile(items: [InferredItem]) throws -> TenantProfile {
        var profile = TenantProfile.demo
        profile.variables = ["OrgName": "Contoso", "EnrollmentProfileName": "Contoso ADE"]
        profile.selectedItemIDs = Set(items.map(\.id))
        var intent = AssignmentIntent()
        intent.first.scope = .group
        intent.first.groupName = "Contoso Macs"
        let script = try #require(items.first { $0.type == .shellScript })
        profile.assignments = [script.id: intent]
        return profile
    }

    // MARK: - The whole deploy, on the demo tenant

    @Test("Plan, Apply, a second Plan, an edit and Remove Baseline run on the demo tenant; MSAL is never set up")
    func lifecycle() async throws {
        let demo = demoMode()
        let trap = MSALTrap()
        let auth = auth(demo, trap: trap)
        let log = ActivityLog()
        let session = TenantSession(auth: auth, activityLog: log, demo: demo)
        let (items, sourceStore, root, folder) = try await fixtureItems()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(items.count == 10)
        let profile = try demoProfile(items: items)
        #expect(profile.isDemo && profile.displayName == "Contoso Intune (Demo)")
        #expect(auth.isSignedIn(profile))

        // 1. Plan: everything new; the left-over tagged object is the one deletion.
        await session.plan(profile: profile, items: items, sourceStore: sourceStore)
        #expect(session.planError == nil, "\(session.planError ?? "")")
        var plan = try #require(session.currentPlan)
        #expect(!plan.hasErrors, "\(plan.errors.map(\.message))")
        #expect(plan.createCount == 10)
        #expect(plan.orphans.map(\.displayName) == ["Contoso – Legacy Wi-Fi"])

        // 2. Apply, deleting the left-over.
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: Set(plan.orphans.map(\.id)),
                            items: items, sourceStore: sourceStore)
        let results = try #require(session.applyResults)
        #expect(results.filter(\.isFailure).isEmpty, "\(results.filter(\.isFailure).map { "\($0.title): \($0.outcome)" })")

        // 3. A second Plan: nothing to change, nothing left over.
        session.currentPlan = nil
        await session.plan(profile: profile, items: items, sourceStore: sourceStore)
        plan = try #require(session.currentPlan)
        for action in plan.actions {
            if case .update(let changes) = action.kind {
                Issue.record("“\(action.displayName)” changes again: \(changes.map { "\($0.path): \($0.oldValue) → \($0.newValue)" })")
            }
        }
        #expect(plan.unchangedCount == 10)
        #expect(plan.orphans.isEmpty)

        // 4. An edited file is an update.
        try Data((Fixtures.scriptWithOptionsDirective + "\necho edited\n").utf8)
            .write(to: root.appending(path: "Scripts/greeting.sh"))
        session.currentPlan = nil
        await session.plan(profile: profile, items: items, sourceStore: sourceStore)
        plan = try #require(session.currentPlan)
        #expect(plan.updateCount == 1 && plan.unchangedCount == 9)

        // 5. Remove Baseline: every tagged object goes; Contoso's own stay.
        await session.removeBaseline(profile: profile)
        #expect(session.applyResults?.filter(\.isFailure).isEmpty == true)
        #expect(session.applyResults?.filter { $0.title.hasPrefix("Delete") }.count == 10)
        // The Contoso group the assignments name isn't this profile's: listed and kept.
        let kept = session.applyResults?.filter { $0.title.hasPrefix("Keep group") } ?? []
        #expect(kept.count == (session.applyResults?.count ?? 0) - 10 && kept.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
        let configurations = demo.intuneServer.objects(at: TenantCollection.deviceConfigurations.listPath)
        #expect(configurations.count == 1, "Contoso – Dock, untagged, stays")

        // Nothing went to MSAL, everything to the demo tenant under its name.
        #expect(trap.calls == 0)
        #expect(!log.entries.isEmpty)
        #expect(log.entries.allSatisfy { $0.connection == "Contoso Intune (Demo)" })
        #expect(log.entries.allSatisfy { $0.status != 401 })
    }

    @Test("An app's content is uploaded to the demo storage host and the app is published")
    func upload() async throws {
        let demo = demoMode()
        let session = TenantSession(auth: auth(demo, trap: MSALTrap()), activityLog: ActivityLog(), demo: demo)
        let client = session.client(for: .demo, scopes: GraphScopes.applyScopes(allowGroupCreation: false))
        let created = try await client.post("deviceAppManagement/mobileApps", version: .beta, body: Data("""
            {"@odata.type":"#microsoft.graph.macOSPkgApp","displayName":"Contoso Tool","description":""}
            """.utf8))
        let appID = try #require((try JSONSerialization.jsonObject(with: created) as? [String: Any])?["id"] as? String)
        let contents = Data(repeating: 0x41, count: 7 * 1024 * 1024)
        let started = ContinuousClock.now
        try await AppContentUploader(client: client, appID: appID, appODataType: "#microsoft.graph.macOSPkgApp")
            .upload(fileName: "ContosoTool.pkg", fileData: contents)
        #expect(ContinuousClock.now - started < .seconds(4), "no waiting for upload states")
        #expect(demo.intuneServer.uploadedBytes > contents.count, "encrypted content, two blocks")
        let app = try await client.getRaw("deviceAppManagement/mobileApps/\(appID)?$select=publishingState", version: .beta)
        #expect(String(decoding: app, as: UTF8.self).contains("\"published\""))
    }

    @Test("missingPermission: Plan works, every write is refused with Graph's 403 naming the permission")
    func missingPermission() async throws {
        let demo = demoMode(scenario: "missingPermission")
        let session = TenantSession(auth: auth(demo, trap: MSALTrap()), activityLog: ActivityLog(), demo: demo)
        let (items, sourceStore, root, folder) = try await fixtureItems()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: folder)
        }
        let profile = try demoProfile(items: items)
        await session.plan(profile: profile, items: items, sourceStore: sourceStore)
        let plan = try #require(session.currentPlan)
        #expect(plan.createCount == 10)
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: items, sourceStore: sourceStore)
        let failures = try #require(session.applyResults).filter(\.isFailure)
        #expect(!failures.isEmpty)
        let messages = failures.compactMap { result -> String? in
            if case .failure(let message) = result.outcome { message } else { nil }
        }
        #expect(messages.contains { $0.contains("403") && $0.contains("DeviceManagementConfiguration.ReadWrite.All") },
                "\(messages)")
        #expect(demo.intuneServer.objects(at: TenantCollection.deviceConfigurations.listPath).count == 2, "nothing written")
    }

    @Test("Preflight passes on the demo tenant: Intune authority, APNs, ADE, permissions")
    func preflight() async throws {
        let demo = demoMode()
        let session = TenantSession(auth: auth(demo, trap: MSALTrap()), activityLog: ActivityLog(), demo: demo)
        await session.runPreflight(for: .demo)
        let checks = try #require(session.preflightChecks)
        #expect(!checks.isEmpty)
        #expect(checks.allSatisfy { $0.status == .ok }, "\(checks.map { "\($0.title): \($0.message)" })")
    }

    // MARK: - Never MSAL, never the real network

    @Test("The demo tenant never sets up MSAL, in or out of demo mode; a real tenant still does")
    func neverMSAL() async throws {
        let trap = MSALTrap()
        let demo = demoMode()
        let withDemo = auth(demo, trap: trap)
        let profile = TenantProfile.demo
        withDemo.restoreAccount(for: profile)
        #expect(withDemo.isSignedIn(profile))
        #expect(withDemo.account(for: profile)?.username == "demo.sample@contoso.example")
        #expect(try await withDemo.signIn(profile: profile).username == "demo.sample@contoso.example")
        #expect(try await withDemo.accessToken(profile: profile, scopes: GraphScopes.planRead) == DemoIntuneServer.delegatedToken)
        #expect(withDemo.grantedScopes(for: profile).contains("Group.Read.All"), "granted as asked, step by step")
        await withDemo.signOut(profile: profile)
        #expect(withDemo.isSignedIn(profile), "nothing to sign out of")

        // without demo mode the demo tenant is simply not signed in
        let withoutDemo = auth(nil, trap: trap)
        withoutDemo.restoreAccount(for: profile)
        #expect(!withoutDemo.isSignedIn(profile))
        await #expect(throws: (any Error).self) {
            _ = try await withoutDemo.accessToken(profile: profile, scopes: GraphScopes.tenantRead)
        }
        #expect(trap.calls == 0)

        // the trap is the real way in: outside tests a real tenant reaches it
        let real = TenantProfile(displayName: "Lab", clientID: UUID().uuidString, tenantID: UUID().uuidString)
        auth(demo, trap: trap, underTest: .off).restoreAccount(for: real)
        #expect(trap.calls == 1)
    }

    @Test("A real tenant's client uses its own network (under tests one that refuses everything), the demo tenant's never does")
    func networks() {
        let demo = demoMode()
        let session = TenantSession(auth: auth(demo, trap: MSALTrap()), activityLog: ActivityLog(), demo: demo)
        let real = TenantProfile(displayName: "Lab", clientID: UUID().uuidString, tenantID: UUID().uuidString)
        let realSession = session.client(for: real).recorder.session
        #expect(realSession !== URLSession.shared, "under tests never the real network")
        #expect(realSession !== demo.microsoftSignIn().session)
        let given = URLSession(configuration: .ephemeral)
        let live = TenantSession(auth: auth(demo, trap: MSALTrap()), activityLog: ActivityLog(), demo: demo, realTenantSession: given)
        #expect(live.client(for: real).recorder.session === given)
        #expect(session.client(for: .demo).recorder.session === demo.microsoftSignIn().session)
        let withoutDemo = TenantSession(auth: auth(nil, trap: MSALTrap()), activityLog: ActivityLog())
        #expect(withoutDemo.client(for: .demo).recorder.session !== URLSession.shared)
    }

    // MARK: - Saved tenants untouched

    private func tenantStore(_ demo: DemoMode?) throws -> (TenantStore, URL, UserDefaults) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "demo-tenants-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "tenants.json")
        let defaults = TestSettings.makeDefaults("demo-tenants").defaults
        let store = TenantStore(storageURL: url, defaults: defaults, demo: demo)
        return (store, url, defaults)
    }

    @Test("In demo mode the demo tenant is in use; its baseline stays in memory; the saved tenants and the one in use don't change")
    func savedTenantsUntouched() throws {
        let demo = demoMode()
        demo.isOn = false
        let (store, url, defaults) = try tenantStore(demo)
        let real = TenantProfile(displayName: "Lab", clientID: UUID().uuidString, tenantID: UUID().uuidString)
        try store.connections.save(real)
        store.selectedProfileID = real.id
        let bytes = try Data(contentsOf: url)
        let selection = defaults.string(forKey: TenantStore.selectionKey)

        demo.isOn = true
        #expect(store.selectedProfile?.id == TenantProfile.demo.id)
        var edited = try #require(store.selectedProfile)
        edited.selectedItemIDs = ["abc12345"]
        edited.namingPrefix = "[CONTOSO]"
        store.update(edited)
        #expect(store.saveError == nil)
        #expect(store.selectedProfile?.selectedItemIDs == ["abc12345"])
        #expect(store.profile(id: TenantProfile.demo.id)?.namingPrefix == "[CONTOSO]")
        #expect(store.profiles.map(\.id) == [real.id], "the demo tenant isn't in the saved list")
        #expect(try Data(contentsOf: url) == bytes)
        #expect(defaults.string(forKey: TenantStore.selectionKey) == selection)
        #expect(throws: ConnectionStoreError.self) { try store.connections.save(edited) }

        demo.isOn = false
        #expect(store.selectedProfile?.id == real.id)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("An exported demo tenant is refused on import, under its own ID or a new one; a real profile still imports")
    func importRefusesDemoTenant() throws {
        let exported = Data(try TenantProfile.demo.exportText().utf8)
        for existing in [Set<UUID>(), [TenantProfile.demo.id]] {
            #expect(throws: TenantStoreError.demoProfile("Contoso Intune (Demo)")) {
                _ = try TenantProfile.importedProfile(from: exported, existingIDs: existing)
            }
        }
        var renamed = TenantProfile.demo
        renamed.id = UUID()
        renamed.displayName = "Not a demo, honest"
        #expect(throws: TenantStoreError.self) {
            _ = try TenantProfile.importedProfile(from: Data(try renamed.exportText().utf8), existingIDs: [])
        }
        let real = TenantProfile(displayName: "Lab", clientID: UUID().uuidString, tenantID: UUID().uuidString)
        #expect(try TenantProfile.importedProfile(from: Data(try real.exportText().utf8), existingIDs: []).id == real.id)
    }

    @Test("Saving a demo tenant in the saved list fails from every side")
    func demoNeverSaved() throws {
        let (store, url, _) = try tenantStore(nil)
        var renamed = TenantProfile.demo
        renamed.id = UUID()
        #expect(throws: ConnectionStoreError.self) { try store.connections.save(renamed) }
        store.update(renamed)
        #expect(store.saveError != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path) || store.profiles.isEmpty)
    }
}
