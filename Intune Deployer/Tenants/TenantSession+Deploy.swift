import Foundation
import OSLog

/// Planning (dry-run) and apply orchestration for the active tenant.
extension TenantSession {
    private static let deployLogger = Logger(subsystem: "be.jordythery.intune-deployer", category: "Deploy")

    // MARK: - Plan

    /// Builds a dry-run plan: fetch tenant state, then run the pure engine.
    func plan(profile: TenantProfile, items: [InferredItem], sourceStore: SourceStore) async {
        guard !isApplying else {
            planError = "An apply is still running — wait for it to finish."
            return
        }
        isPlanning = true
        planError = nil
        currentPlan = nil
        applyResults = nil
        defer { isPlanning = false }
        let startedGeneration = generation

        // Selected items with file contents (security-scoped reads). App
        // packages are inspected for bundle metadata instead of being held
        // in memory; their bytes are read again at apply time.
        var selected: [PlanInput.SelectedItem] = []
        for item in items where profile.selectedItemIDs.contains(item.id) {
            do {
                let data = try sourceStore.fileContents(of: item)
                if item.type == .app {
                    let appInfo = try? await Self.inspectAppPackage(named: item.fileURL.lastPathComponent, data: data)
                    selected.append(PlanInput.SelectedItem(item: item, fileData: Data(), appInfo: appInfo))
                } else {
                    let isEdited = sourceStore.edits.edit(for: item.id) != nil
                    selected.append(PlanInput.SelectedItem(item: item, fileData: data, isEdited: isEdited))
                }
            } catch {
                planError = "Could not read \(item.relativePath): \(error.localizedDescription)"
                return
            }
        }

        let client = client(for: profile, scopes: GraphScopes.planRead)
        do {
            let existing = try await fetchExistingObjects(client: client)
            let groups = try await lookUpGroups(
                names: referencedGroupNames(profile: profile, items: selected.map(\.item)),
                client: client
            )
            let needsCatalog = selected.contains { $0.item.type == .settingsCatalog }
            let knownDefinitions = needsCatalog ? await fetchSettingDefinitionIDs(client: client) : nil

            let input = PlanInput(
                selectedItems: selected,
                profile: profile,
                existingObjects: existing,
                groups: groups,
                knownSettingDefinitionIDs: knownDefinitions
            )
            let plan = await Task.detached(priority: .userInitiated) {
                PlanEngine.makePlan(input: input)
            }.value
            guard generation == startedGeneration else { return }
            currentPlan = plan
        } catch {
            guard generation == startedGeneration else { return }
            planError = error.localizedDescription
        }
    }

    /// Writes the package to a container temp file and inspects it there
    /// (the helper tools can't read security-scoped originals). Runs off the
    /// main actor: xar/hdiutil block their thread.
    @concurrent
    nonisolated private static func inspectAppPackage(named fileName: String, data: Data) async throws -> AppPackageInfo {
        let dir = FileManager.default.temporaryDirectory.appending(path: "inspect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: fileName)
        try data.write(to: fileURL)
        return try AppPackageInspector.inspect(packageAt: fileURL)
    }

    /// Fetches all managed collections with full bodies; merges the settings
    /// of tagged Settings Catalog policies (the list endpoint omits them).
    /// The mixed mobileApps collection is filtered to the managed macOS types.
    private func fetchExistingObjects(client: GraphClient) async throws -> [TenantCollection: [RemoteObject]] {
        var result: [TenantCollection: [RemoteObject]] = [:]
        try await withThrowingTaskGroup(of: (TenantCollection, [RemoteObject]).self) { group in
            for collection in TenantCollection.allCases {
                group.addTask {
                    // Compliance scheduled actions are a navigation property;
                    // without the expand they are missing from the diff.
                    // TODO(verify): this $expand is portal/community practice,
                    // not documented on the list page.
                    let path = collection == .compliancePolicies
                        ? "\(collection.listPath)?$expand=scheduledActionsForRule($expand=scheduledActionConfigurations)"
                        : collection.listPath
                    var bodies = try await client.listRaw(path, version: collection.version)
                    if collection == .apps {
                        bodies = bodies.filter { body in
                            guard let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                                  let type = dict["@odata.type"] as? String else { return false }
                            return TenantCollection.managedAppODataTypes.contains(type)
                        }
                    }
                    return (collection, bodies.compactMap(Self.remoteObject(from:)))
                }
            }
            for try await (collection, objects) in group {
                result[collection] = objects
            }
        }

        // Settings Catalog diffing needs the settings; fetch them only for
        // objects we manage (identity tag present).
        if var policies = result[.settingsCatalog] {
            for index in policies.indices where policies[index].taggedShortID != nil {
                let policy = policies[index]
                // GET .../configurationPolicies/{id}/settings is the documented
                // settings read route.
                let settings = try await client.listRaw(
                    "deviceManagement/configurationPolicies/\(policy.id)/settings",
                    version: .beta
                )
                policies[index] = Self.merging(settings: settings, into: policy)
            }
            result[.settingsCatalog] = policies
        }

        // Script list responses omit scriptContent (and custom attribute
        // metadata); fetch tagged objects individually so diffs see them.
        for collection in [TenantCollection.shellScripts, .customAttributes] {
            guard var objects = result[collection] else { continue }
            for index in objects.indices where objects[index].taggedShortID != nil {
                let body = try await client.getRaw(
                    "\(collection.listPath)/\(objects[index].id)",
                    version: collection.version
                )
                if let full = Self.remoteObject(from: body) {
                    objects[index] = full
                }
            }
            result[collection] = objects
        }
        return result
    }

    nonisolated private static func remoteObject(from body: Data) -> RemoteObject? {
        guard let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = dict["id"] as? String else { return nil }
        return RemoteObject(
            id: id,
            displayName: (dict["displayName"] as? String) ?? (dict["name"] as? String) ?? id,
            description: dict["description"] as? String,
            body: body
        )
    }

    nonisolated private static func merging(settings: [Data], into object: RemoteObject) -> RemoteObject {
        guard var dict = try? JSONSerialization.jsonObject(with: object.body) as? [String: Any] else {
            return object
        }
        dict["settings"] = settings.compactMap { try? JSONSerialization.jsonObject(with: $0) }
        guard let merged = try? JSONSerialization.data(withJSONObject: dict) else { return object }
        return RemoteObject(id: object.id, displayName: object.displayName, description: object.description, body: merged)
    }

    private func referencedGroupNames(profile: TenantProfile, items: [InferredItem]) -> Set<String> {
        var names = Set<String>()
        for item in items {
            let intent = profile.effectiveAssignment(for: item.id, type: item.type)
            if intent.mode == .group {
                let name = intent.groupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names
    }

    nonisolated private struct GroupObject: Decodable, Sendable {
        let id: String
        let displayName: String?
        let groupTypes: [String]?
    }

    private func lookUpGroups(names: Set<String>, client: GraphClient) async throws -> [String: GroupLookup] {
        var result: [String: GroupLookup] = [:]
        for name in names {
            // $filter=displayName eq '…' works without ConsistencyLevel (v1.0).
            // The value is percent-encoded so &, + and # in group names
            // survive the query string.
            let escaped = name.replacingOccurrences(of: "'", with: "''")
            let filter = "displayName eq '\(escaped)'"
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~'() "))) ?? ""
            let matches = try await client.list(
                GroupObject.self,
                "groups?$filter=\(filter)&$select=id,displayName,groupTypes",
                version: .v1
            )
            if let match = matches.first {
                result[name] = .found(
                    id: match.id,
                    isDynamic: match.groupTypes?.contains("DynamicMembership") == true
                )
            } else {
                result[name] = .missing
            }
        }
        return result
    }

    nonisolated private struct SettingDefinition: Decodable, Sendable {
        let id: String
    }

    /// Fetches valid setting definition IDs for validation. Returns nil when
    /// unavailable (plan shows a warning instead of failing).
    private func fetchSettingDefinitionIDs(client: GraphClient) async -> Set<String>? {
        // TODO(verify): the $filter/$top parameters on configurationSettings
        // are not documented on Learn (the endpoint itself is). The portal
        // uses a platform filter; try that first, fall back to an unfiltered
        // paged fetch, and skip validation when both fail.
        let filtered = "deviceManagement/configurationSettings?$select=id&$top=1000"
            + "&$filter=(platforms has 'macOS' or platforms has 'iOS') and technologies has 'mdm'"
        if let ids = try? await client.list(SettingDefinition.self, filtered, version: .beta) {
            return Set(ids.map(\.id))
        }
        do {
            let all = try await client.list(
                SettingDefinition.self,
                "deviceManagement/configurationSettings?$select=id&$top=1000",
                version: .beta
            )
            return Set(all.map(\.id))
        } catch {
            Self.deployLogger.warning("Setting catalog fetch failed; skipping validation: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Apply

    /// Executes the plan: groups/filters first, then objects in order, then
    /// orphan deletions (opt-in) and assignments. Continues on per-item
    /// failure and reports every step.
    func apply(
        profile: TenantProfile,
        plan: Plan,
        deleteOrphanIDs: Set<String>,
        items: [InferredItem],
        sourceStore: SourceStore
    ) async {
        isApplying = true
        applyResults = []
        defer { isApplying = false }

        let client = client(for: profile, scopes: GraphScopes.applyScopes(allowGroupCreation: profile.allowGroupCreation))
        var createdGroupIDs: [String: String] = [:]
        var createdFilterIDs: [String: String] = [:]
        var assignmentQueue: [(action: PlanItemAction, objectID: String)] = []

        func report(_ title: String, _ outcome: ApplyResult.Outcome) {
            applyResults?.append(ApplyResult(title: title, outcome: outcome))
        }

        // Warm up the write-scope token first (may trigger a one-time consent
        // prompt). If authorization fails, abort with one clear result instead
        // of failing every step.
        do {
            nonisolated struct MeID: Decodable, Sendable { let id: String }
            _ = try await client.get(MeID.self, "me?$select=id", version: .v1)
        } catch {
            report("Authorize write access", .failure(error.localizedDescription))
            return
        }

        // 1. Missing groups (opt-in).
        for group in plan.groupsToCreate {
            do {
                createdGroupIDs[group.name] = try await createGroup(named: group.name, client: client)
                report("Create group “\(group.name)”", .success)
            } catch {
                report("Create group “\(group.name)”", .failure(error.localizedDescription))
            }
        }

        // 2. Built-in template filters.
        for filter in plan.filtersToCreate {
            do {
                let body: [String: Any] = [
                    "@odata.type": "#microsoft.graph.deviceAndAppManagementAssignmentFilter",
                    "displayName": filter.name,
                    "description": "Created by Intune Deployer (built-in template)",
                    "platform": filter.platform.filterPlatformValue,
                    "rule": filter.rule,
                ]
                let response = try await client.post(
                    TenantCollection.assignmentFilters.listPath,
                    version: .beta,
                    body: try JSONSerialization.data(withJSONObject: body)
                )
                createdFilterIDs[filter.name] = Self.objectID(from: response)
                report("Create filter “\(filter.name)”", .success)
            } catch {
                report("Create filter “\(filter.name)”", .failure(error.localizedDescription))
            }
        }

        // 3. Objects in deployment order.
        for action in plan.actions {
            do {
                switch action.kind {
                case .create:
                    let response = try await client.post(action.collection.listPath, version: action.collection.version, body: action.payload)
                    guard let newID = Self.objectID(from: response) else {
                        report("Create \(action.displayName)", .failure("Graph returned no object ID"))
                        continue
                    }
                    if action.collection == .assignmentFilters {
                        createdFilterIDs[action.displayName] = newID
                    }
                    report("Create \(action.displayName)", .success)
                    if action.collection == .apps {
                        // The app object exists; now encrypt + upload content.
                        do {
                            try await uploadAppContent(action: action, appID: newID, client: client, items: items, sourceStore: sourceStore)
                            report("Upload content for \(action.displayName)", .success)
                        } catch {
                            report("Upload content for \(action.displayName)", .failure(error.localizedDescription))
                            continue // without content, skip assignment
                        }
                    }
                    if action.assignment != nil {
                        assignmentQueue.append((action, newID))
                    }

                case .update(let changes):
                    guard let objectID = action.existingObjectID else {
                        report("Update \(action.displayName)", .skipped("No tenant object ID — re-run Plan"))
                        continue
                    }
                    try await update(action: action, objectID: objectID, client: client)
                    report("Update \(action.displayName)", .success)
                    // A changed bundle version, file or provisioning expiry
                    // (an .ipa re-signed in place) means new binary content.
                    if action.collection == .apps,
                       changes.contains(where: { ["primaryBundleVersion", "versionNumber", "buildNumber", "fileName", "expirationDateTime"].contains($0.path) }) {
                        do {
                            try await uploadAppContent(action: action, appID: objectID, client: client, items: items, sourceStore: sourceStore)
                            report("Upload content for \(action.displayName)", .success)
                        } catch {
                            report("Upload content for \(action.displayName)", .failure(error.localizedDescription))
                            continue
                        }
                    }
                    if action.assignment != nil {
                        assignmentQueue.append((action, objectID))
                    }

                case .unchanged:
                    if let objectID = action.existingObjectID, action.assignment != nil {
                        assignmentQueue.append((action, objectID))
                    }
                }
            } catch {
                report("\(action.kind.label) \(action.displayName)", .failure(error.localizedDescription))
            }
        }

        // 4. Orphans — only the ones the user explicitly ticked.
        for orphan in plan.orphans where deleteOrphanIDs.contains(orphan.objectID) {
            do {
                try await client.delete("\(orphan.collection.listPath)/\(orphan.objectID)", version: orphan.collection.version)
                report("Delete orphan \(orphan.displayName)", .success)
            } catch {
                report("Delete orphan \(orphan.displayName)", .failure(error.localizedDescription))
            }
        }

        // 5. Assignments, last.
        for (action, objectID) in assignmentQueue {
            guard let assignment = action.assignment else { continue }
            do {
                try await assign(
                    assignment,
                    action: action,
                    objectID: objectID,
                    createdGroupIDs: createdGroupIDs,
                    createdFilterIDs: createdFilterIDs,
                    client: client
                )
                report("Assign \(action.displayName)", .success)
            } catch {
                report("Assign \(action.displayName)", .failure(error.localizedDescription))
            }
        }
    }

    // MARK: - Apply helpers

    private func uploadAppContent(
        action: PlanItemAction,
        appID: String,
        client: GraphClient,
        items: [InferredItem],
        sourceStore: SourceStore
    ) async throws {
        guard let item = items.first(where: { $0.id == action.id }) else {
            throw PayloadError.unsupportedItem("App file is no longer available")
        }
        let fileData = try sourceStore.fileContents(of: item)
        let payload = (try? JSONSerialization.jsonObject(with: action.payload) as? [String: Any]) ?? [:]
        let odataType = payload["@odata.type"] as? String ?? "#microsoft.graph.macOSPkgApp"
        var uploader = AppContentUploader(client: client, appID: appID, appODataType: odataType)
        if odataType == "#microsoft.graph.iosLobApp" {
            uploader.manifest = AppContentUploader.iosManifest(
                bundleID: payload["bundleId"] as? String ?? "",
                bundleVersion: payload["versionNumber"] as? String ?? "",
                title: payload["displayName"] as? String ?? item.displayName
            )
        }
        try await uploader.upload(fileName: item.fileURL.lastPathComponent, fileData: fileData)
    }

    private func update(action: PlanItemAction, objectID: String, client: GraphClient) async throws {
        let path = "\(action.collection.listPath)/\(objectID)"
        switch action.collection {
        case .settingsCatalog:
            // TODO(verify): replacing a Settings Catalog policy incl. settings
            // via PUT is what the Intune portal does, but Learn documents only
            // PATCH (without settings) and per-setting navigation CRUD.
            try await client.put(path, version: .beta, body: action.payload)

        case .compliancePolicies:
            // PATCH the policy without scheduled actions, then update rules
            // via the documented scheduleActionsForRules action.
            guard var dict = try JSONSerialization.jsonObject(with: action.payload) as? [String: Any] else {
                throw PayloadError.invalidJSON(action.displayName)
            }
            let rules = dict["scheduledActionsForRule"]
            dict["scheduledActionsForRule"] = nil
            try await client.patch(path, version: .v1, body: try JSONSerialization.data(withJSONObject: dict))
            if let rules {
                let body = try JSONSerialization.data(withJSONObject: ["deviceComplianceScheduledActionForRules": rules])
                try await client.post("\(path)/scheduleActionsForRules", version: .v1, body: body)
            }

        case .customAttributes:
            // customAttributeName/customAttributeType are rejected on update
            // (the portal greys them out; not documented).
            guard var dict = try JSONSerialization.jsonObject(with: action.payload) as? [String: Any] else {
                throw PayloadError.invalidJSON(action.displayName)
            }
            dict["customAttributeName"] = nil
            dict["customAttributeType"] = nil
            try await client.patch(path, version: .beta, body: try JSONSerialization.data(withJSONObject: dict))

        default:
            try await client.patch(path, version: action.collection.version, body: action.payload)
        }
    }

    private func assign(
        _ assignment: ResolvedAssignment,
        action: PlanItemAction,
        objectID: String,
        createdGroupIDs: [String: String],
        createdFilterIDs: [String: String],
        client: GraphClient
    ) async throws {
        var target: [String: Any]
        switch assignment.target {
        case .allDevices:
            target = ["@odata.type": "#microsoft.graph.allDevicesAssignmentTarget"]
        case .allUsers:
            target = ["@odata.type": "#microsoft.graph.allLicensedUsersAssignmentTarget"]
        case .group(let id, let name):
            guard let groupID = id ?? createdGroupIDs[name] else {
                throw PayloadError.unsupportedItem("Group “\(name)” was not created")
            }
            target = ["@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": groupID]
        }

        if let filter = assignment.filter {
            let filterID: String?
            switch filter {
            case .existing(let id): filterID = id
            case .pendingCreation(let name): filterID = createdFilterIDs[name]
            }
            guard let filterID else {
                throw PayloadError.unsupportedItem("Assignment filter was not created")
            }
            target["deviceAndAppManagementAssignmentFilterId"] = filterID
            target["deviceAndAppManagementAssignmentFilterType"] = assignment.filterMode.rawValue
        }

        // Scripts use deviceManagementScriptAssignments; apps use
        // mobileAppAssignments with an install intent; other collections use
        // assignments. The /assign action replaces the full assignment set.
        // TODO(verify): the configurationPolicies assign body shape follows
        // the documented sibling actions; its own doc page is unpublished.
        let entries: [[String: Any]]
        let parameterName: String
        switch action.collection {
        case .shellScripts, .customAttributes:
            parameterName = "deviceManagementScriptAssignments"
            entries = [["target": target]]
        case .apps:
            parameterName = "mobileAppAssignments"
            entries = [[
                "@odata.type": "#microsoft.graph.mobileAppAssignment",
                "intent": assignment.appIntent.rawValue,
                "target": target,
            ]]
        default:
            parameterName = "assignments"
            entries = [["target": target]]
        }
        let body = try JSONSerialization.data(withJSONObject: [parameterName: entries])
        try await client.post("\(action.collection.listPath)/\(objectID)/assign", version: action.collection.version, body: body)
    }

    private func createGroup(named name: String, client: GraphClient) async throws -> String {
        // mailNickname: ≤64 chars, restricted ASCII set (group-post-groups doc).
        var nickname = name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined().lowercased()
        if nickname.isEmpty { nickname = "intunedeployer" }
        let body: [String: Any] = [
            "displayName": name,
            "mailEnabled": false,
            "mailNickname": String(nickname.prefix(64)),
            "securityEnabled": true,
            "groupTypes": [] as [String],
            "description": "Created by Intune Deployer",
        ]
        let response = try await client.post("groups", version: .v1, body: try JSONSerialization.data(withJSONObject: body))
        guard let id = Self.objectID(from: response) else {
            throw PayloadError.unsupportedItem("Graph returned no ID for group “\(name)”")
        }
        return id
    }

    nonisolated private static func objectID(from response: Data) -> String? {
        guard let dict = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else { return nil }
        return dict["id"] as? String
    }

    // MARK: - Remove baseline

    /// Deletes every object carrying our identity tag. UI requires a typed
    /// confirmation of the tenant name first. Untagged objects are never touched.
    func removeBaseline(profile: TenantProfile) async {
        isApplying = true
        applyResults = []
        defer { isApplying = false }

        let client = client(for: profile, scopes: GraphScopes.applyScopes(allowGroupCreation: false))
        for collection in TenantCollection.allCases.sorted(by: { $0.applyOrder > $1.applyOrder }) {
            do {
                let objects = try await client.listRaw(collection.listPath, version: collection.version)
                for body in objects {
                    guard let object = Self.remoteObject(from: body), object.taggedShortID != nil else { continue }
                    do {
                        try await client.delete("\(collection.listPath)/\(object.id)", version: collection.version)
                        applyResults?.append(ApplyResult(title: "Delete \(object.displayName)", outcome: .success))
                    } catch {
                        applyResults?.append(ApplyResult(title: "Delete \(object.displayName)", outcome: .failure(error.localizedDescription)))
                    }
                }
            } catch {
                applyResults?.append(ApplyResult(
                    title: "List \(collection.displayName)",
                    outcome: .failure(error.localizedDescription)
                ))
            }
        }
    }
}
