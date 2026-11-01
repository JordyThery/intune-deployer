import Foundation
import JTKit
import OSLog

/// Planning (dry run) and apply orchestration for the tenant in use.
extension TenantSession {
    private static let deployLogger = Logger(subsystem: "be.jordythery.intune-deployer", category: "Deploy")

    // MARK: - Plan

    /// Builds a dry-run plan: fetch tenant state, then run the pure engine.
    func plan(profile: TenantProfile, items: [InferredItem], sourceStore: SourceStore) async {
        guard !isApplying else {
            planError = "Apply is still running. Wait for it to finish."
            return
        }
        planError = nil
        currentPlan = nil
        applyResults = nil
        // A chosen item missing from the scanned items is a file that left
        // the baseline, or an item of a source that isn't scanned (a failed
        // sync, an unmounted drive). Only the first may become a deletion
        // offer, so the Plan waits until every source is scanned.
        if let problem = Self.unscannedSourcesProblem(
            missing: profile.selectedItemIDs.subtracting(items.map(\.id)).count,
            sources: sourceStore.unscannedSourceNames) {
            planError = problem
            return
        }
        isPlanning = true
        defer { isPlanning = false }
        let startedGeneration = generation

        // Selected items with file contents (security-scoped reads). App
        // packages are inspected for bundle metadata instead of being held
        // in memory; their bytes are read again at apply time.
        var selected: [PlanInput.SelectedItem] = []
        for item in items where profile.selectedItemIDs.contains(item.id) {
            let earlierIDs = sourceStore.earlierIDs(of: item)
            do {
                let data = try sourceStore.fileContents(of: item)
                if item.type == .app {
                    let inspection = await Self.inspectAppPackage(named: item.fileURL.lastPathComponent, data: data)
                    let hash = await Self.packageHash(data)
                    var app = PlanInput.SelectedItem(item: item, fileData: Data(), appInfo: try? inspection.get(),
                                                     package: PlanInput.PackageFile(size: data.count, hash: hash))
                    if case .failure(let error) = inspection { app.inspectionError = error.localizedDescription }
                    app.earlierIDs = earlierIDs
                    selected.append(app)
                } else {
                    let isEdited = sourceStore.edits.edit(for: item.id) != nil
                    var file = PlanInput.SelectedItem(item: item, fileData: data, isEdited: isEdited)
                    file.earlierIDs = earlierIDs
                    selected.append(file)
                }
            } catch {
                planError = "Couldn’t read \(item.relativePath): \(error.localizedDescription)"
                return
            }
        }

        if profile.isDemo {
            addToDemoCatalog(settingsIn: selected.filter { $0.item.type == .settingsCatalog }.map(\.fileData))
        }
        do {
            let client = try await checkedClient(for: profile, scopes: GraphScopes.planRead)
            let existing = try await fetchExistingObjects(client: client)
            let groups = try await lookUpGroups(
                names: referencedGroupNames(profile: profile, items: selected.map(\.item)),
                client: client
            )
            let needsCatalog = selected.contains { $0.item.type == .settingsCatalog }
            let knownDefinitions = needsCatalog ? await fetchSettingDefinitionIDs(client: client) : nil
            let selectedIDs = selected.reduce(into: Set<String>()) { $0.formUnion($1.allIDs) }
            let assignments = await fetchAssignments(of: existing, itemIDs: selectedIDs, client: client)
            let committedFiles = await fetchCommittedFiles(of: existing[.apps] ?? [], itemIDs: selectedIDs, client: client)

            let input = PlanInput(
                selectedItems: selected,
                profile: profile,
                existingObjects: existing,
                groups: groups,
                knownSettingDefinitionIDs: knownDefinitions,
                existingAssignments: assignments,
                committedFiles: committedFiles
            )
            var plan = await Task.detached(priority: .userInitiated) {
                PlanEngine.makePlan(input: input)
            }.value
            // Readable names for changed settings; failures fall back to IDs.
            let changes = plan.actions.flatMap(\.settingChanges)
            plan.settingDefinitions = await Self.fetchSettingDefinitions(
                leafIDs: Set(changes.map(\.definitionID)),
                parentIDs: Set(changes.flatMap(\.parentDefinitionIDs)),
                known: knownDefinitions,
                client: client
            )
            guard generation == startedGeneration else { return }
            currentPlan = plan
        } catch {
            guard generation == startedGeneration else { return }
            planError = error.localizedDescription
        }
    }

    /// Why a Plan doesn't run: chosen items are missing while a source
    /// isn't scanned, so their objects would wrongly be offered for deletion.
    nonisolated static func unscannedSourcesProblem(missing: Int, sources: [String]) -> String? {
        guard missing > 0, !sources.isEmpty else { return nil }
        let names = sources.map { "“\($0)”" }.formatted(.list(type: .and))
        let items = missing == 1 ? "1 chosen item isn’t" : "\(missing) chosen items aren’t"
        return "\(items) in the scanned sources, and \(names) \(sources.count == 1 ? "isn’t" : "aren’t") scanned. "
            + "Plan doesn’t run, so their objects aren’t offered for deletion. Refresh the sources (⌘R), then run Plan again."
    }

    /// Writes the package to a container temp file and inspects it there
    /// (the helper tools can't read security-scoped originals). Runs off the
    /// main actor: xar/hdiutil block their thread.
    @concurrent
    nonisolated private static func inspectAppPackage(named fileName: String, data: Data) async -> Result<AppPackageInfo, any Error> {
        Result {
            let dir = FileManager.default.temporaryDirectory.appending(path: "inspect-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let fileURL = dir.appending(path: fileName)
            try data.write(to: fileURL)
            return try AppPackageInspector.inspect(packageAt: fileURL)
        }
    }

    /// SHA-256 of a package, off the main actor (packages can be large).
    @concurrent
    nonisolated static func packageHash(_ data: Data) async -> String {
        ItemEditStore.hash(data)
    }

    /// Fetches all managed collections with full bodies; merges the settings
    /// of tagged Settings Catalog policies (the list endpoint omits them).
    /// The mixed mobileApps collection is filtered to the app package types.
    private func fetchExistingObjects(client: Graph.Client) async throws -> [TenantCollection: [RemoteObject]] {
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
        // objects with the app's identity tag.
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

    /// The assignments of the tagged objects the selected items match, so
    /// Plan can tell whether Apply needs to send them. An object whose
    /// assignments can't be read is left out: Apply then sends them. Custom
    /// attribute scripts have no `…/assignments` route (Graph answers 400):
    /// their assignments are read expanded.
    private func fetchAssignments(of existing: [TenantCollection: [RemoteObject]], itemIDs: Set<String>,
                                  client: Graph.Client) async -> [String: Set<AssignmentEntry>] {
        var result: [String: Set<AssignmentEntry>] = [:]
        for (collection, objects) in existing {
            for object in objects where object.taggedShortID.map(itemIDs.contains) == true {
                let path = "\(collection.listPath)/\(object.id)"
                var entries: [Any]?
                if collection != .customAttributes,
                   let list = try? await client.listRaw("\(path)/assignments", version: collection.version) {
                    entries = list.compactMap { try? JSONSerialization.jsonObject(with: $0) }
                } else if let body = try? await client.getRaw("\(path)?$expand=assignments", version: collection.version),
                          let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          let expanded = dict["assignments"] as? [Any] {
                    entries = expanded
                }
                if let entries {
                    result[object.id.lowercased()] = Set(entries.compactMap { AssignmentEntry(graph: $0) })
                }
            }
        }
        return result
    }

    /// The files of the content version each tagged app names as committed,
    /// so Plan can tell whether the package in the tenant is the file. An
    /// app whose files can't be read is left out (no check).
    private func fetchCommittedFiles(of apps: [RemoteObject], itemIDs: Set<String>,
                                     client: Graph.Client) async -> [String: [CommittedFile]] {
        var result: [String: [CommittedFile]] = [:]
        for app in apps where app.taggedShortID.map(itemIDs.contains) == true {
            guard let version = PlanEngine.committedContentVersion(of: app) else { continue }
            let path = "deviceAppManagement/mobileApps/\(app.id)/microsoft.graph.mobileLobApp/contentVersions/\(version)/files"
            guard let bodies = try? await client.listRaw(path, version: .beta) else { continue }
            result[app.id.lowercased()] = bodies.compactMap(CommittedFile.init(graph:))
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
            for target in intent.targets where target.scope == .group {
                let name = target.trimmedGroupName
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

    /// The groups with exactly this display name. `$filter=displayName eq '…'`
    /// works without ConsistencyLevel (v1.0); the value is percent-encoded so
    /// &, + and # in group names survive the query string.
    private func groups<Group: Decodable & Sendable>(named name: String, select: String,
                                                    as type: Group.Type, client: Graph.Client) async throws -> [Group] {
        let escaped = name.replacingOccurrences(of: "'", with: "''")
        let filter = "displayName eq '\(escaped)'"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~'() "))) ?? ""
        return try await client.list(type, "groups?$filter=\(filter)&$select=\(select)", version: .v1)
    }

    private func lookUpGroups(names: Set<String>, client: Graph.Client) async throws -> [String: GroupLookup] {
        var result: [String: GroupLookup] = [:]
        for name in names {
            let matches = try await groups(named: name, select: "id,displayName,groupTypes", as: GroupObject.self, client: client)
            if matches.count > 1 {
                result[name] = .ambiguous(count: matches.count)
            } else if let match = matches.first {
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

    /// Display names (and choice option names) for the given setting
    /// definitions, via GET deviceManagement/configurationSettings/{id}
    /// (beta). Best-effort: capped at 100 definitions (changed settings
    /// first) and 20 seconds; missing names fall back to the ID.
    nonisolated private static func fetchSettingDefinitions(
        leafIDs: Set<String>,
        parentIDs: Set<String>,
        known: Set<String>?,
        client: Graph.Client
    ) async -> [String: SettingDefinitionInfo] {
        nonisolated struct Definition: Decodable, Sendable {
            nonisolated struct Option: Decodable, Sendable {
                let itemId: String?
                let displayName: String?
            }
            let id: String
            let displayName: String?
            let options: [Option]?
        }
        enum Outcome: Sendable {
            case definition(Definition?)
            case timedOut
        }
        // IDs come from the policy file and become a URL path segment: only
        // well-formed IDs the tenant knows are requested.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-{}")
        func isRequestable(_ id: String) -> Bool {
            !id.isEmpty && id.unicodeScalars.allSatisfy(allowed.contains) && (known?.contains(id) ?? true)
        }
        let ids = (leafIDs.sorted() + parentIDs.subtracting(leafIDs).sorted()).filter(isRequestable).prefix(100)
        guard !ids.isEmpty else { return [:] }

        var result: [String: SettingDefinitionInfo] = [:]
        await withTaskGroup(of: Outcome.self) { group in
            for id in ids {
                group.addTask {
                    .definition(try? await client.get(Definition.self, "deviceManagement/configurationSettings/\(id)", version: .beta))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return .timedOut
            }
            var pending = ids.count
            for await outcome in group {
                guard case .definition(let definition) = outcome else {
                    group.cancelAll()
                    break
                }
                pending -= 1
                if let definition, let name = definition.displayName, !name.isEmpty {
                    var options: [String: String] = [:]
                    for option in definition.options ?? [] {
                        if let itemID = option.itemId, let optionName = option.displayName {
                            options[itemID] = optionName
                        }
                    }
                    result[definition.id] = SettingDefinitionInfo(displayName: name, options: options)
                }
                if pending == 0 {
                    group.cancelAll()
                    break
                }
            }
        }
        return result
    }

    /// Fetches valid setting definition IDs for validation. Returns nil when
    /// unavailable (plan shows a warning instead of failing).
    private func fetchSettingDefinitionIDs(client: Graph.Client) async -> Set<String>? {
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
            Self.deployLogger.warning("Settings Catalog fetch failed; skipping validation: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Apply

    /// Executes the plan: groups/filters first, then objects in order, then
    /// orphan deletions (opt-in) and assignments. Continues on per-item
    /// failure and reports every step.
    ///
    /// Refused, with nothing sent: while another Plan or Apply runs (returns
    /// false and leaves that one's results alone), and for a plan made for
    /// another profile or tenant or with errors (one failed result). Every
    /// write goes through a client whose tokens are checked against the
    /// profile's tenant.
    @discardableResult
    func apply(
        profile: TenantProfile,
        plan: Plan,
        deleteOrphanIDs: Set<String>,
        items: [InferredItem],
        sourceStore: SourceStore
    ) async -> Bool {
        guard !isApplying, !isPlanning else { return false }
        isApplying = true
        applyResults = []
        defer { isApplying = false }

        func report(_ title: String, _ outcome: ApplyResult.Outcome) {
            applyResults?.append(ApplyResult(title: title, outcome: outcome))
        }

        let tenant = profile.tenantID.trimmingCharacters(in: .whitespaces).lowercased()
        guard plan.profileID == profile.id, plan.tenantID == tenant else {
            report("Apply", .failure("This plan was made for another tenant profile or tenant ID. Run Plan again for “\(profile.displayName)”."))
            return true
        }
        guard !plan.hasErrors else {
            report("Apply", .failure("The plan has errors. Fix them, then run Plan again."))
            return true
        }
        let client: Graph.Client
        do {
            client = try await writeClient(for: profile,
                                           scopes: GraphScopes.applyScopes(allowGroupCreation: profile.allowGroupCreation))
        } catch {
            report("Tenant check", .failure(error.localizedDescription))
            return true
        }
        var createdGroupIDs: [String: String] = [:]
        var createdFilterIDs: [String: String] = [:]
        var assignmentQueue: [(action: PlanItemAction, objectID: String)] = []

        // Warm up the write-scope token first (may trigger a one-time consent
        // prompt). If authorization fails, abort with one clear result instead
        // of failing every step.
        do {
            nonisolated struct MeID: Decodable, Sendable { let id: String }
            _ = try await client.get(MeID.self, "me?$select=id", version: .v1)
        } catch {
            report("Write permission", .failure(error.localizedDescription))
            return true
        }

        // 1. Missing groups (opt-in).
        for group in plan.groupsToCreate {
            do {
                createdGroupIDs[group.name] = try await createGroup(named: group.name, profile: profile, client: client)
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
                    // The profile's tag, so Remove Baseline can find it.
                    "description": "\(Self.templateFilterDescription) \(ItemIdentity.profileTag(for: profile.id))",
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
                    if action.assignments != nil {
                        assignmentQueue.append((action, newID))
                    }

                case .update:
                    guard let objectID = action.existingObjectID else {
                        report("Update \(action.displayName)", .skipped("No tenant object ID. Run Plan again."))
                        continue
                    }
                    // New content first: the new version is written only once
                    // its package is committed, so a failed upload leaves the
                    // old version in place and the next Plan uploads again.
                    if action.uploadsPackage {
                        do {
                            try await uploadAppContent(action: action, appID: objectID, client: client, items: items, sourceStore: sourceStore)
                            report("Upload content for \(action.displayName)", .success)
                        } catch {
                            report("Upload content for \(action.displayName)", .failure(error.localizedDescription))
                            continue
                        }
                    }
                    try await update(action: action, objectID: objectID, client: client)
                    report("Update \(action.displayName)", .success)
                    if action.collection == .assignmentFilters {
                        createdFilterIDs[action.displayName] = objectID
                    }
                    if action.sendsAssignments {
                        assignmentQueue.append((action, objectID))
                    }

                case .unchanged:
                    // A filter renamed in the baseline is matched by its tag,
                    // so assignments naming its new name use this object.
                    if action.collection == .assignmentFilters, let objectID = action.existingObjectID {
                        createdFilterIDs[action.displayName] = objectID
                    }
                    // Only assignments that differ from the tenant's.
                    if let objectID = action.existingObjectID, action.sendsAssignments {
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
            guard let assignments = action.assignments else { continue }
            do {
                try await assign(
                    assignments,
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
        return true
    }

    // MARK: - Apply helpers

    private func uploadAppContent(
        action: PlanItemAction,
        appID: String,
        client: Graph.Client,
        items: [InferredItem],
        sourceStore: SourceStore
    ) async throws {
        guard let item = items.first(where: { $0.id == action.id }) else {
            throw PayloadError.unsupportedItem("App file is no longer available")
        }
        let fileData = try sourceStore.fileContents(of: item)
        // The package Plan inspected, or nothing: a file replaced since then
        // would be uploaded under the inspected bundle version.
        if let package = action.package, await Self.packageHash(fileData) != package.hash {
            throw PayloadError.unsupportedItem("“\(item.relativePath)” changed since the Plan. Run Plan again.")
        }
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

    private func update(action: PlanItemAction, objectID: String, client: Graph.Client) async throws {
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
                // replaces the rules, so sending it twice does no harm
                try await client.post("\(path)/scheduleActionsForRules", version: .v1, body: body, safeToRepeat: true)
            }

        case .customAttributes:
            // customAttributeName/customAttributeType are rejected on update
            // (the Intune admin center grays them out; not documented).
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

    /// Posts the full include/exclude set in one /assign call (it replaces
    /// the existing assignments).
    private func assign(
        _ assignments: [ResolvedAssignment],
        action: PlanItemAction,
        objectID: String,
        createdGroupIDs: [String: String],
        createdFilterIDs: [String: String],
        client: Graph.Client
    ) async throws {
        let entries = try AssignmentBody.entries(assignments, collection: action.collection,
                                                 createdGroupIDs: createdGroupIDs, createdFilterIDs: createdFilterIDs)
        let body = try JSONSerialization.data(withJSONObject: [AssignmentBody.parameterName(for: action.collection): entries])
        // replaces the assignments, so sending it twice does no harm
        try await client.post("\(action.collection.listPath)/\(objectID)/assign", version: action.collection.version, body: body,
                              safeToRepeat: true)
    }

    /// What a group or template filter the app creates says, before the
    /// profile's tag (Remove Baseline finds them by both).
    nonisolated static let createdGroupDescription = "Created by Intune Deployer"
    nonisolated static let templateFilterDescription = "Created by Intune Deployer (built-in template)"

    private func createGroup(named name: String, profile: TenantProfile, client: Graph.Client) async throws -> String {
        // mailNickname: ≤64 chars, restricted ASCII set (group-post-groups doc).
        var nickname = name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined().lowercased()
        if nickname.isEmpty { nickname = "intunedeployer" }
        let body: [String: Any] = [
            "displayName": name,
            "mailEnabled": false,
            "mailNickname": String(nickname.prefix(64)),
            "securityEnabled": true,
            "groupTypes": [] as [String],
            "description": "\(Self.createdGroupDescription) \(ItemIdentity.profileTag(for: profile.id))",
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

    /// Whether Remove Baseline deletes this tenant object: one of this
    /// profile's tagged objects, or a template filter it created.
    nonisolated private static func isRemovable(_ object: RemoteObject, in collection: TenantCollection, profile: TenantProfile) -> Bool {
        if object.taggedShortID != nil {
            return ItemIdentity.belongs(description: object.description, displayName: object.displayName, to: profile)
        }
        guard collection == .assignmentFilters, let description = object.description else { return false }
        return description.hasPrefix(templateFilterDescription)
            && ItemIdentity.profileMarker(inDescription: description) == ItemIdentity.profileMarker(for: profile.id)
    }

    nonisolated private struct GroupRecord: Decodable, Sendable {
        let id: String
        let displayName: String?
        let description: String?
    }

    /// A group the profile's assignments name, and whether Remove Baseline
    /// may delete it: only when it carries this profile's tag (this
    /// profile's Apply created it) and has no members. Every other group is
    /// listed and kept: untagged, another profile's, or with members.
    nonisolated struct NamedGroup: Sendable {
        let id: String
        let name: String
        /// Created by this profile (its tag in the description).
        let isThisProfiles: Bool
        /// Counted only for this profile's groups.
        let members: Int?

        var isDeletable: Bool { isThisProfiles && members == 0 }

        /// Why it's kept; nil when it's deleted.
        var keptBecause: String? {
            if !isThisProfiles { return "Not created by this tenant profile" }
            guard let members, members > 0 else { return nil }
            return "It has \(members) member\(members == 1 ? "" : "s")"
        }
    }

    /// The groups the profile's assignments name.
    func namedGroups(profile: TenantProfile, client: Graph.Client) async throws -> [NamedGroup] {
        let intents = Array(profile.assignments.values) + Array(profile.defaultAssignments.values)
        let names = Set(intents.flatMap(\.targets).filter { $0.scope == .group }.map(\.trimmedGroupName).filter { !$0.isEmpty })
        let marker = ItemIdentity.profileMarker(for: profile.id)
        var found: [NamedGroup] = []
        for name in names.sorted() {
            for group in try await groups(named: name, select: "id,displayName,description", as: GroupRecord.self, client: client) {
                let description = group.description ?? ""
                let isThisProfiles = description.hasPrefix(Self.createdGroupDescription)
                    && ItemIdentity.profileMarker(inDescription: description) == marker
                let members = isThisProfiles ? try await client.listRaw("groups/\(group.id)/members?$select=id", version: .v1).count : nil
                found.append(NamedGroup(id: group.id, name: group.displayName ?? name, isThisProfiles: isThisProfiles, members: members))
            }
        }
        return found
    }

    /// What Remove Baseline would delete, counted before anything is typed:
    /// this profile's tagged objects, its template filters and the groups
    /// it created that have no members. Remove Baseline deletes only these.
    nonisolated struct RemovalCount: Sendable {
        /// Tenant object IDs (lowercased).
        var objectIDs: Set<String> = []
        /// IDs of the groups that are deleted (lowercased).
        var groupIDs: Set<String> = []

        var count: Int { objectIDs.count + groupIDs.count }
    }

    /// Counts what Remove Baseline would delete. Reads only.
    func removalCount(profile: TenantProfile) async throws -> RemovalCount {
        let client = try await checkedClient(for: profile, scopes: GraphScopes.planRead)
        var counted = RemovalCount()
        for collection in TenantCollection.allCases {
            for body in try await client.listRaw(collection.listPath, version: collection.version) {
                guard let object = Self.remoteObject(from: body), Self.isRemovable(object, in: collection, profile: profile) else { continue }
                counted.objectIDs.insert(object.id.lowercased())
            }
        }
        for group in try await namedGroups(profile: profile, client: client) where group.isDeletable {
            counted.groupIDs.insert(group.id.lowercased())
        }
        return counted
    }

    /// How many objects Remove Baseline would delete.
    func taggedObjectCount(profile: TenantProfile) async throws -> Int {
        try await removalCount(profile: profile).count
    }

    /// Deletes this profile's tagged objects, the template filters it
    /// created and the groups that carry its tag and have no members; every
    /// other group its assignments name is listed and kept. Untagged objects
    /// and other profiles' objects are never touched. With `counted`, only
    /// the counted objects are deleted: one that became the profile's since
    /// the count is listed and kept. UI requires a typed confirmation of the
    /// tenant name first. Refused while a Plan or Apply runs; every write is
    /// tenant-checked.
    @discardableResult
    func removeBaseline(profile: TenantProfile, counted: RemovalCount? = nil) async -> Bool {
        guard !isApplying, !isPlanning else { return false }
        isApplying = true
        applyResults = []
        defer { isApplying = false }

        func report(_ title: String, _ outcome: ApplyResult.Outcome) {
            applyResults?.append(ApplyResult(title: title, outcome: outcome))
        }
        let notCounted = "Not in the count shown. Run Remove Baseline again to delete it."

        // Deleting a group the profile created needs Group.ReadWrite.All,
        // even when group creation has been switched off since.
        let deletesGroups = counted.map { !$0.groupIDs.isEmpty } ?? true
        let client: Graph.Client
        do {
            client = try await writeClient(for: profile, scopes: GraphScopes.applyScopes(
                allowGroupCreation: profile.allowGroupCreation || (deletesGroups && profile.hasNamedGroups)))
        } catch {
            report("Tenant check", .failure(error.localizedDescription))
            return true
        }
        for collection in TenantCollection.allCases.sorted(by: { $0.applyOrder > $1.applyOrder }) {
            do {
                let objects = try await client.listRaw(collection.listPath, version: collection.version)
                for body in objects {
                    guard let object = Self.remoteObject(from: body), Self.isRemovable(object, in: collection, profile: profile) else { continue }
                    if let counted, !counted.objectIDs.contains(object.id.lowercased()) {
                        report("Keep \(object.displayName)", .skipped(notCounted))
                        continue
                    }
                    do {
                        try await client.delete("\(collection.listPath)/\(object.id)", version: collection.version)
                        report("Delete \(object.displayName)", .success)
                    } catch {
                        report("Delete \(object.displayName)", .failure(error.localizedDescription))
                    }
                }
            } catch {
                report("List \(collection.displayName)", .failure(error.localizedDescription))
            }
        }
        // Last, the groups the profile names: assignments to them are gone.
        // Only this profile's empty groups are deleted; the rest are listed.
        do {
            for group in try await namedGroups(profile: profile, client: client) {
                let name = group.name
                if let reason = group.keptBecause {
                    report("Keep group “\(name)”", .skipped(reason))
                    continue
                }
                guard group.isDeletable else { continue }
                if let counted, !counted.groupIDs.contains(group.id.lowercased()) {
                    report("Keep group “\(name)”", .skipped(notCounted))
                    continue
                }
                do {
                    try await client.delete("groups/\(group.id)", version: .v1)
                    report("Delete group “\(name)”", .success)
                } catch {
                    report("Delete group “\(name)”", .failure(error.localizedDescription))
                }
            }
        } catch {
            report("List the groups this profile’s assignments name", .failure(error.localizedDescription))
        }
        return true
    }
}
