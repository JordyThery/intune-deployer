import Foundation

/// A tenant object fetched for planning (full body for diffing).
nonisolated struct RemoteObject: Sendable {
    let id: String
    let displayName: String
    let description: String?
    let body: Data

    var taggedShortID: String? {
        description.flatMap(ItemIdentity.shortID(inDescription:))
    }
}

nonisolated enum GroupLookup: Sendable {
    case found(id: String, isDynamic: Bool)
    case missing
}

/// Everything the pure plan computation needs — fetched up front so the
/// engine itself is synchronous and fully testable.
nonisolated struct PlanInput: Sendable {
    struct SelectedItem: Sendable {
        let item: InferredItem
        let fileData: Data
        /// Bundle info for .pkg/.dmg items, inspected before planning.
        /// nil for other types, or when inspection failed (plan error).
        let appInfo: AppPackageInfo?

        init(item: InferredItem, fileData: Data, appInfo: AppPackageInfo? = nil) {
            self.item = item
            self.fileData = fileData
            self.appInfo = appInfo
        }
    }

    let selectedItems: [SelectedItem]
    let profile: TenantProfile
    /// Existing tenant objects per collection, with full bodies.
    let existingObjects: [TenantCollection: [RemoteObject]]
    /// Lookup results for every group name referenced by an intent.
    let groups: [String: GroupLookup]
    /// Valid Settings Catalog setting definition IDs; nil when the tenant
    /// catalog could not be fetched (validation skipped with a warning).
    let knownSettingDefinitionIDs: Set<String>?
}

nonisolated extension TenantCollection {
    /// Deployment order: filters/groups → custom attributes → scripts →
    /// apps → configuration profiles → compliance. Assignments run last.
    var applyOrder: Int {
        switch self {
        case .assignmentFilters: 0
        case .customAttributes: 1
        case .shellScripts: 2
        case .apps: 3
        case .deviceConfigurations: 4
        case .settingsCatalog: 5
        case .compliancePolicies: 6
        }
    }
}

/// Pure dry-run computation: payloads, matching by identity tag, diffing,
/// assignment resolution, ordering. No network access.
nonisolated enum PlanEngine {
    static func makePlan(input: PlanInput) -> Plan {
        var plan = Plan()
        var groupsToCreate: Set<String> = []
        var templateFilters: [String: String] = [:] // name → substituted rule

        // Filter items created in this same plan (lowercased name → canonical
        // display name), so intents can reference them before they exist and
        // apply can look them up by the exact created name.
        var pendingFilterNames: [String: String] = [:]
        var builtPayloads: [(PlanInput.SelectedItem, PayloadBuilder.Built)] = []

        for selected in input.selectedItems {
            do {
                let built = try PayloadBuilder.build(
                    item: selected.item,
                    fileData: selected.fileData,
                    namingPrefix: input.profile.namingPrefix,
                    variables: input.profile.variables,
                    appInfo: selected.appInfo
                )
                if built.collection == .assignmentFilters {
                    pendingFilterNames[built.displayName.lowercased()] = built.displayName
                }
                builtPayloads.append((selected, built))
            } catch {
                plan.issues.append(PlanIssue(
                    severity: .error,
                    itemName: selected.item.displayName,
                    message: error.localizedDescription
                ))
            }
        }

        let existingFilters = input.existingObjects[.assignmentFilters] ?? []

        for (selected, built) in builtPayloads {
            var warnings = built.warnings
            let item = selected.item

            // Settings Catalog: validate settingDefinitionIds against the tenant.
            if built.collection == .settingsCatalog {
                validateSettingDefinitions(
                    body: built.body,
                    known: input.knownSettingDefinitionIDs,
                    itemName: built.displayName,
                    issues: &plan.issues,
                    warnings: &warnings
                )
            }

            // Resolve the assignment intent (explicit, else per-type default).
            var intent = input.profile.effectiveAssignment(for: item.id, type: item.type)
            if !item.type.supportsAssignmentFilters,
               !intent.filterName.trimmingCharacters(in: .whitespaces).isEmpty {
                warnings.append("Intune does not support assignment filters on \(item.type.displayName.lowercased())s — filter “\(intent.filterName)” is ignored")
                intent.filterName = ""
            }
            let assignment = resolveAssignment(
                intent: intent,
                itemName: built.displayName,
                input: input,
                existingFilters: existingFilters,
                pendingFilterNames: pendingFilterNames,
                groupsToCreate: &groupsToCreate,
                templateFilters: &templateFilters,
                issues: &plan.issues,
                warnings: &warnings
            )

            // Match tenant object by identity tag.
            let matches = (input.existingObjects[built.collection] ?? [])
                .filter { $0.taggedShortID == item.id }
            if matches.count > 1 {
                warnings.append("Multiple tenant objects carry this item's identity tag (was one duplicated in the portal?) — only “\(matches[0].displayName)” is managed")
            }
            let existing = matches.first

            let kind: PlanActionKind
            if let existing {
                do {
                    let changes = try GraphDiff.changes(
                        desired: built.body,
                        remote: existing.body,
                        ignoringKeys: Self.diffIgnoredKeys(for: built.collection)
                    )
                    kind = changes.isEmpty ? .unchanged : .update(changes)
                } catch {
                    // Never treat an uncomparable object as unchanged.
                    warnings.append("Could not compare with the tenant object — it will be updated")
                    kind = .update([FieldChange(path: "(comparison failed)", oldValue: "tenant state", newValue: "desired state")])
                }
            } else {
                kind = .create
            }

            plan.actions.append(PlanItemAction(
                id: item.id,
                collection: built.collection,
                displayName: built.displayName,
                kind: kind,
                payload: built.body,
                existingObjectID: existing?.id,
                assignment: assignment,
                warnings: warnings
            ))
        }

        plan.actions.sort {
            ($0.collection.applyOrder, $0.displayName) < ($1.collection.applyOrder, $1.displayName)
        }
        plan.groupsToCreate = groupsToCreate.sorted().map(PlannedGroupCreation.init(name:))
        plan.filtersToCreate = templateFilters
            .map { PlannedFilterCreation(name: $0.key, rule: $0.value) }
            .sorted { $0.name < $1.name }

        // Orphans: objects tagged by us whose item is no longer selected, or
        // whose item now deploys to a different collection (type change).
        // Objects without our tag are never considered.
        let selectedCollections = Dictionary(
            builtPayloads.map { ($0.0.item.id, $0.1.collection) },
            uniquingKeysWith: { first, _ in first }
        )
        for (collection, objects) in input.existingObjects {
            for object in objects {
                if let shortID = object.taggedShortID, selectedCollections[shortID] != collection {
                    plan.orphans.append(OrphanedObject(
                        collection: collection,
                        objectID: object.id,
                        displayName: object.displayName,
                        shortID: shortID
                    ))
                }
            }
        }
        plan.orphans.sort { $0.displayName < $1.displayName }
        return plan
    }

    /// Fields the service rewrites or returns inconsistently, excluded from
    /// change detection (verified against live tenant behaviour):
    /// - custom attributes: name/type are immutable and often returned null
    /// - compliance: the service stores rule names as null
    static func diffIgnoredKeys(for collection: TenantCollection) -> Set<String> {
        switch collection {
        case .customAttributes: ["customAttributeName", "customAttributeType"]
        case .compliancePolicies: ["ruleName"]
        default: []
        }
    }

    // MARK: - Assignment resolution

    private static func resolveAssignment(
        intent: AssignmentIntent,
        itemName: String,
        input: PlanInput,
        existingFilters: [RemoteObject],
        pendingFilterNames: [String: String],
        groupsToCreate: inout Set<String>,
        templateFilters: inout [String: String],
        issues: inout [PlanIssue],
        warnings: inout [String]
    ) -> ResolvedAssignment? {
        let target: ResolvedAssignment.Target
        switch intent.mode {
        case .none:
            return nil
        case .allDevices:
            target = .allDevices
        case .allUsers:
            target = .allUsers
        case .group:
            let name = intent.groupName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                issues.append(PlanIssue(severity: .error, itemName: itemName, message: "Assignment group name is empty"))
                return nil
            }
            switch input.groups[name] {
            case .found(let id, let isDynamic):
                if isDynamic {
                    warnings.append("“\(name)” is a dynamic group — delivery of enrollment-critical policies may be delayed past Await Configuration")
                }
                target = .group(id: id, name: name)
            case .missing, nil:
                if input.profile.allowGroupCreation {
                    groupsToCreate.insert(name)
                    target = .group(id: nil, name: name)
                } else {
                    issues.append(PlanIssue(
                        severity: .error,
                        itemName: itemName,
                        message: "Group “\(name)” does not exist. Enable group creation in the tenant profile, or create it manually."
                    ))
                    return nil
                }
            }
        }

        // Filter resolution.
        var filter: ResolvedAssignment.FilterResolution?
        let filterName = intent.filterName.trimmingCharacters(in: .whitespaces)
        if !filterName.isEmpty {
            if let existing = existingFilters.first(where: { $0.displayName.caseInsensitiveCompare(filterName) == .orderedSame }) {
                filter = .existing(id: existing.id)
            } else if let canonicalName = pendingFilterNames[filterName.lowercased()] {
                filter = .pendingCreation(name: canonicalName)
            } else if filterName.caseInsensitiveCompare(BuiltInFilterTemplate.name) == .orderedSame {
                // Create the built-in ADE template filter during apply.
                let substitution = VariableSubstitution.substitute(
                    BuiltInFilterTemplate.rule,
                    variables: input.profile.variables
                )
                if substitution.unresolved.isEmpty {
                    templateFilters[BuiltInFilterTemplate.name] = substitution.text
                    filter = .pendingCreation(name: BuiltInFilterTemplate.name)
                } else {
                    issues.append(PlanIssue(
                        severity: .error,
                        itemName: itemName,
                        message: "The built-in ADE filter needs the \(BuiltInFilterTemplate.requiredToken) variable — set it in the tenant profile"
                    ))
                }
            } else {
                issues.append(PlanIssue(
                    severity: .error,
                    itemName: itemName,
                    message: "Assignment filter “\(filterName)” not found in the tenant or in the selected items"
                ))
            }
        }

        return ResolvedAssignment(target: target, filter: filter, filterMode: intent.filterMode)
    }

    // MARK: - Settings Catalog validation

    private static func validateSettingDefinitions(
        body: Data,
        known: Set<String>?,
        itemName: String,
        issues: inout [PlanIssue],
        warnings: inout [String]
    ) {
        let used = settingDefinitionIDs(in: body)
        guard !used.isEmpty else { return }
        guard let known else {
            warnings.append("Could not fetch the tenant's setting catalog — settingDefinitionIds not validated")
            return
        }
        let unknown = used.subtracting(known).sorted()
        if !unknown.isEmpty {
            issues.append(PlanIssue(
                severity: .error,
                itemName: itemName,
                message: "Unknown settingDefinitionIds in this tenant: \(unknown.joined(separator: ", "))"
            ))
        }
    }

    /// Collects every `settingDefinitionId` value in the payload.
    static func settingDefinitionIDs(in body: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return [] }
        var ids = Set<String>()
        collectSettingDefinitionIDs(object, into: &ids)
        return ids
    }

    private static func collectSettingDefinitionIDs(_ value: Any, into ids: inout Set<String>) {
        if let dict = value as? [String: Any] {
            if let id = dict["settingDefinitionId"] as? String {
                ids.insert(id)
            }
            for nested in dict.values {
                collectSettingDefinitionIDs(nested, into: &ids)
            }
        } else if let array = value as? [Any] {
            for element in array {
                collectSettingDefinitionIDs(element, into: &ids)
            }
        }
    }
}
