import Foundation
import JTKit
import Testing
@testable import Intune_Deployer

/// Integration tests against a real tenant. They run inside the host app's
/// container, reusing its tenant profiles and cached MSAL tokens, and skip
/// silently when no signed-in profile is available.
///
/// The read-only dry-run always runs when possible. The WRITE lifecycle test
/// additionally requires the environment variable INTUNE_DEPLOYER_LIVE_WRITE=1
/// (set it on the test scheme or `xcodebuild test`) so a plain test run never
/// writes to anyone's tenant. It creates objects prefixed "[AUTOTEST]" with
/// their own identity tags and deletes exactly those objects afterwards —
/// existing deployments are never touched.
@MainActor
@Suite("Live tenant", .serialized)
struct LiveTenantTests {
    /// The first configured profile with a restorable account, or nil to skip.
    private func signedInProfile(auth: AuthManager) -> TenantProfile? {
        let store = TenantStore()
        for profile in store.profiles where profile.hasValidClientID {
            auth.restoreAccount(for: profile)
            if auth.isSignedIn(profile) {
                return profile
            }
        }
        print("LiveTenantTests skipped: no tenant profile with a cached sign-in")
        return nil
    }

    private var liveWritesEnabled: Bool {
        // xcodebuild cannot inject environment variables into app-hosted
        // tests; the user-defaults key enables scripted runs:
        //   defaults write be.jordythery.intune-deployer LiveWriteTests -bool true
        ProcessInfo.processInfo.environment["INTUNE_DEPLOYER_LIVE_WRITE"] == "1"
            || UserDefaults.standard.bool(forKey: "LiveWriteTests")
    }

    // MARK: - Read-only: dry-run plan over the real sources

    @Test func dryRunPlanOverRealSourcesSucceeds() async throws {
        let auth = AuthManager()
        guard let profile = signedInProfile(auth: auth) else { return }

        let sourceStore = SourceStore()
        await sourceStore.rescanAll()
        let items = sourceStore.items(for: Set(sourceStore.sources.map(\.id)))
        guard !items.isEmpty else {
            print("LiveTenantTests skipped: no sources configured")
            return
        }

        let session = TenantSession(auth: auth, activityLog: ActivityLog())
        await session.plan(profile: profile, items: items, sourceStore: sourceStore)

        #expect(session.planError == nil, "plan failed: \(session.planError ?? "")")
        let plan = try #require(session.currentPlan)
        print("Dry-run plan: \(plan.createCount) create, \(plan.updateCount) update, \(plan.unchangedCount) unchanged, \(plan.orphans.count) orphaned, \(plan.errors.count) errors")
        // The plan itself must compute; per-item errors (e.g. unresolved
        // variables in the user's files) are allowed and reported above.
    }

    // MARK: - Read-only: export real tenant objects and read them back

    @Test func exportFromTenantRescansAsItems() async throws {
        let auth = AuthManager()
        guard let profile = signedInProfile(auth: auth) else { return }

        let session = TenantSession(auth: auth, activityLog: ActivityLog())
        await session.loadInventory(for: profile)
        #expect(session.inventoryErrors.isEmpty, "inventory errors: \(session.inventoryErrors)")

        // Up to three objects per exportable type keeps the run short.
        let selection = TenantExporter.exportableCollections.flatMap { collection in
            (session.inventory[collection] ?? []).prefix(3).map {
                ExportSelection(collection: collection, objectID: $0.id, name: $0.resolvedName)
            }
        }
        guard !selection.isEmpty else {
            print("LiveTenantTests: tenant has no exportable objects")
            return
        }

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "live-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let summary = await session.export(selection, profile: profile, to: folder)
        print("Live export: \(summary.written.count) written, \(summary.skipped.count) skipped")
        for skipped in summary.skipped { print("  skipped \(skipped.name): \(skipped.reason)") }

        // Every written file must be recognised again — nothing lands in Skipped.
        let scan = try InferenceEngine.scan(root: folder, sourceID: UUID())
        #expect(scan.items.count == summary.written.count)
        #expect(scan.skipped.isEmpty, "unreadable exports: \(scan.skipped)")
        // Fetch failures (as opposed to unsupported objects) are bugs.
        #expect(!summary.skipped.contains { $0.reason.localizedCaseInsensitiveContains("http") })
    }

    /// Deletes every tagged object named "[AUTOTEST]…" — leftovers from
    /// interrupted runs must never accumulate in the tenant.
    private func sweepAutotestObjects(client: GraphClient) async throws -> Int {
        var deleted = 0
        for collection in TenantCollection.allCases {
            let bodies = try await client.listRaw(collection.listPath, version: collection.version)
            for body in bodies {
                guard let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let id = dict["id"] as? String else { continue }
                let name = (dict["displayName"] as? String) ?? (dict["name"] as? String) ?? ""
                let description = dict["description"] as? String ?? ""
                guard name.hasPrefix("[AUTOTEST]"), ItemIdentity.shortID(inDescription: description) != nil else { continue }
                try await client.delete("\(collection.listPath)/\(id)", version: collection.version)
                deleted += 1
            }
        }
        return deleted
    }

    // MARK: - Full lifecycle: create → idempotent re-plan → delete

    @Test func deployLifecycleCreatesIsIdempotentAndCleansUp() async throws {
        guard liveWritesEnabled else {
            print("LiveTenantTests skipped: set INTUNE_DEPLOYER_LIVE_WRITE=1 to run the write lifecycle")
            return
        }
        let auth = AuthManager()
        guard let realProfile = signedInProfile(auth: auth) else { return }

        // Synthetic source in the container: unique source ID → unique item
        // identities → no collision with anything deployed from real sources.
        let fixtureRoot = try Fixtures.makeTree(files: [
            "Settings Catalog/gatekeeper.json": Fixtures.settingsCatalogJSON,
            "Profiles/dock.mobileconfig": Fixtures.mobileconfig,
            "Compliance/encryption.json": Fixtures.complianceJSON,
            "Filters/ade.json": Fixtures.assignmentFilterJSON,
            "Scripts/greeting.sh": Fixtures.scriptWithOptionsDirective,
            "Custom Attributes/battery.sh": Fixtures.attributeScriptByFolder,
            // iOS/iPadOS objects: stated in the JSON, or via the export
            // folder rule for the profile.
            "iOS Compliance/passcode.json": Fixtures.iosComplianceJSON,
            "iOS Catalog/restrictions.json": Fixtures.iosSettingsCatalogJSON,
            "iOS Filters/ade.json": Fixtures.iosFilterJSON,
            "iOS and iPadOS/Profiles/wifi.mobileconfig": Fixtures.mobileconfig,
        ])
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let storeDir = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let sourceStore = SourceStore(storageURL: storeDir.appending(path: "sources.json"))
        sourceStore.addLocalFolder(at: fixtureRoot)
        let sourceID = try #require(sourceStore.sources.first?.id)
        // addLocalFolder schedules its own initial scan; wait for it instead
        // of racing it (a superseded scan discards its results by design).
        for _ in 0..<200 where sourceStore.items(for: [sourceID]).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let items = sourceStore.items(for: [sourceID])
        #expect(items.count == 10)
        #expect(items.count { $0.platform == .iOSiPadOS } == 4)

        // Temporary profile reusing the real registration and cached account.
        var intent = AssignmentIntent()
        intent.first.scope = .allDevices
        let scriptItem = try #require(items.first { $0.type == .shellScript })
        var assignments = [scriptItem.id: intent]

        // Multiple targets with an exclusion, using two existing groups so
        // the test never creates (and has to clean up) directory objects.
        let session = TenantSession(auth: auth, activityLog: ActivityLog())
        let readClient = session.client(for: realProfile, scopes: GraphScopes.planRead)
        let groupList = try await readClient.get(GroupPage.self, "groups?$top=2&$select=id,displayName", version: .v1)
        let complianceItem = try #require(items.first { $0.type == .compliancePolicy && $0.platform == .macOS })
        let multiTarget = groupList.value.count == 2
        if multiTarget {
            assignments[complianceItem.id] = AssignmentIntent(targets: [
                AssignmentTarget(scope: .allDevices),
                AssignmentTarget(scope: .group, groupName: groupList.value[0].displayName),
                AssignmentTarget(kind: .exclude, scope: .group, groupName: groupList.value[1].displayName),
            ])
        } else {
            print("LiveTenantTests: fewer than two groups, skipping the multi-target check")
        }

        let profile = TenantProfile(
            displayName: "AUTOTEST \(realProfile.displayName)",
            clientID: realProfile.clientID,
            tenantID: realProfile.tenantID,
            namingPrefix: "[AUTOTEST]",
            variables: ["OrgName": "AutoTest", "EnrollmentProfileName": "AutoTest ADE"],
            selectedItemIDs: Set(items.map(\.id)),
            assignments: assignments,
            accountIdentifier: realProfile.accountIdentifier
        )
        auth.restoreAccount(for: profile)
        try #require(auth.isSignedIn(profile), "cached account did not restore for the temporary profile")

        let cleanupClient = session.client(for: profile, scopes: GraphScopes.applyScopes(allowGroupCreation: false))

        // 0. Remove leftovers from any previously interrupted run.
        let leftovers = try await sweepAutotestObjects(client: cleanupClient)
        if leftovers > 0 { print("Swept \(leftovers) leftover [AUTOTEST] object(s)") }

        // 1. Plan: everything is new.
        await session.plan(profile: profile, items: items, sourceStore: sourceStore)
        #expect(session.planError == nil, "plan failed: \(session.planError ?? "")")
        var plan = try #require(session.currentPlan)
        #expect(!plan.hasErrors, "plan errors: \(plan.errors.map(\.message))")
        #expect(plan.createCount == 10, "expected 10 creates, got \(plan.createCount)")

        // 2. Apply.
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: items, sourceStore: sourceStore)
        let results = try #require(session.applyResults)
        let failures = results.filter(\.isFailure)
        #expect(failures.isEmpty, "apply failures: \(failures.map(\.title))")

        // 3. Re-plan: everything must be unchanged (idempotency).
        session.currentPlan = nil
        await session.plan(profile: profile, items: items, sourceStore: sourceStore)
        plan = try #require(session.currentPlan)
        #expect(!plan.hasErrors)
        for action in plan.actions {
            if case .update(let changes) = action.kind {
                Issue.record("“\(action.displayName)” is not idempotent: \(changes.map { "\($0.path): \($0.oldValue) → \($0.newValue)" })")
            }
        }
        #expect(plan.unchangedCount == 10, "expected 10 unchanged, got \(plan.unchangedCount)")

        // The compliance policy carries both includes and the exclusion.
        if multiTarget {
            let policyID = try #require(plan.actions.first { $0.id == complianceItem.id }?.existingObjectID)
            let remote = try await readClient.listRaw("\(TenantCollection.compliancePolicies.listPath)/\(policyID)/assignments", version: .v1)
            let types = remote.compactMap { body -> String? in
                let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                return (dict?["target"] as? [String: Any])?["@odata.type"] as? String
            }
            #expect(types.sorted() == [
                "#microsoft.graph.allDevicesAssignmentTarget",
                "#microsoft.graph.exclusionGroupAssignmentTarget",
                "#microsoft.graph.groupAssignmentTarget",
            ], "remote assignment targets: \(types)")
        }

        // 4. Edit one file → exactly that item plans as an update.
        let scriptURL = fixtureRoot.appending(path: "Scripts/greeting.sh")
        let edited = Fixtures.scriptWithOptionsDirective + "\necho edited\n"
        try Data(edited.utf8).write(to: scriptURL)
        session.currentPlan = nil
        await session.plan(profile: profile, items: items, sourceStore: sourceStore)
        plan = try #require(session.currentPlan)
        #expect(plan.updateCount == 1, "expected 1 update after editing the script, got \(plan.updateCount)")
        #expect(plan.unchangedCount == 9)

        // 4b. A changed Settings Catalog value is reported by setting name.
        let catalogURL = fixtureRoot.appending(path: "Settings Catalog/gatekeeper.json")
        try Data(Fixtures.settingsCatalogJSON.replacingOccurrences(of: "allowcontentcaching_false", with: "allowcontentcaching_true").utf8)
            .write(to: catalogURL)
        session.currentPlan = nil
        await session.plan(profile: profile, items: items, sourceStore: sourceStore)
        plan = try #require(session.currentPlan)
        let catalogAction = try #require(plan.actions.first { $0.collection == .settingsCatalog && $0.settingChanges.count == 1 })
        let change = try #require(catalogAction.settingChanges.first)
        #expect(change.kind == .changed)
        let definition = try #require(plan.settingDefinitions[change.definitionID], "definition \(change.definitionID) was not resolved")
        #expect(!definition.displayName.isEmpty)
        #expect(change.newValue.flatMap { definition.options[$0] } != nil, "option name missing for \(change.newValue ?? "")")
        print("Live settings change: \(definition.displayName) → \(change.newValue.flatMap { definition.options[$0] } ?? "?")")
        // Restore the file and re-plan, so only the script update is applied.
        try Data(Fixtures.settingsCatalogJSON.utf8).write(to: catalogURL)
        session.currentPlan = nil
        await session.plan(profile: profile, items: items, sourceStore: sourceStore)
        plan = try #require(session.currentPlan)
        #expect(plan.updateCount == 1)

        // 5. Apply the update, then delete every test object precisely.
        await session.apply(profile: profile, plan: plan, deleteOrphanIDs: [], items: items, sourceStore: sourceStore)
        session.currentPlan = nil
        await session.plan(profile: profile, items: items, sourceStore: sourceStore)
        plan = try #require(session.currentPlan)

        var deletedCount = 0
        for action in plan.actions {
            guard let objectID = action.existingObjectID else {
                Issue.record("“\(action.displayName)” has no tenant object to delete")
                continue
            }
            try? await cleanupClient.delete("\(action.collection.listPath)/\(objectID)", version: action.collection.version)
            deletedCount += 1
        }
        // Final sweep catches anything the targeted deletes missed.
        let swept = try await sweepAutotestObjects(client: cleanupClient)
        #expect(deletedCount == 10, "deleted \(deletedCount) of 10 (final sweep removed \(swept))")
        print("Live lifecycle complete: 10 created, 1 updated, \(deletedCount) deleted, \(swept) swept")
    }
}

/// One page of `GET /groups` with only the fields the live test needs.
private nonisolated struct GroupPage: Decodable, Sendable {
    struct Group: Decodable, Sendable {
        let id: String
        let displayName: String
    }
    let value: [Group]
}
