import Foundation

/// A single field-level difference between desired and tenant state.
nonisolated struct FieldChange: Sendable, Hashable, Identifiable {
    var id: String { path }
    /// Dotted path, e.g. "settings[2].settingInstance.choiceSettingValue".
    let path: String
    let oldValue: String
    let newValue: String
}

nonisolated enum PlanActionKind: Sendable, Hashable {
    case create
    case update([FieldChange])
    case unchanged

    var label: String {
        switch self {
        case .create: "Create"
        case .update: "Update"
        case .unchanged: "Unchanged"
        }
    }
}

/// One planned operation on an Intune object.
nonisolated struct PlanItemAction: Sendable, Identifiable {
    /// Item short ID (identity hash).
    let id: String
    let collection: TenantCollection
    let displayName: String
    let kind: PlanActionKind
    /// Desired Graph body, ready to POST (create) or PUT/PATCH (update).
    let payload: Data
    /// Tenant object ID when updating.
    let existingObjectID: String?
    /// Resolved include/exclude targets; nil means "leave assignments
    /// untouched". Posting happens via the /assign action and replaces the
    /// whole set.
    let assignments: [ResolvedAssignment]?
    /// Setting-level changes of a Settings Catalog update (empty otherwise);
    /// the raw field changes stay in `kind`.
    var settingChanges: [SettingChange] = []
    let warnings: [String]
}

/// A static security group the apply step will create (opt-in only).
nonisolated struct PlannedGroupCreation: Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
}

/// A filter created from the built-in template because an intent referenced it.
nonisolated struct PlannedFilterCreation: Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    /// Rule with variables already substituted.
    let rule: String
    let platform: ItemPlatform
}

/// A tenant object carrying our identity tag whose item is no longer selected.
nonisolated struct OrphanedObject: Sendable, Identifiable, Hashable {
    var id: String { objectID }
    let collection: TenantCollection
    let objectID: String
    let displayName: String
    let shortID: String
}

nonisolated struct PlanIssue: Sendable, Identifiable {
    enum Severity: Sendable {
        case error
        case warning
    }

    let id = UUID()
    let severity: Severity
    /// Display name of the related item, if any.
    let itemName: String?
    let message: String
}

/// The dry-run result. Nothing is written until the user applies it.
nonisolated struct Plan: Sendable {
    var actions: [PlanItemAction] = []
    var groupsToCreate: [PlannedGroupCreation] = []
    var filtersToCreate: [PlannedFilterCreation] = []
    var orphans: [OrphanedObject] = []
    var issues: [PlanIssue] = []
    /// Names for the setting definitions the plan's setting changes refer
    /// to; filled after planning, missing entries fall back to the ID.
    var settingDefinitions: [String: SettingDefinitionInfo] = [:]

    var errors: [PlanIssue] { issues.filter { $0.severity == .error } }
    var hasErrors: Bool { !errors.isEmpty }

    var createCount: Int { actions.count(where: { $0.kind == .create }) + groupsToCreate.count + filtersToCreate.count }
    var updateCount: Int {
        actions.count(where: { if case .update = $0.kind { true } else { false } })
    }
    var unchangedCount: Int { actions.count(where: { $0.kind == .unchanged }) }
}

// MARK: - Apply results

nonisolated struct ApplyResult: Sendable, Identifiable {
    enum Outcome: Sendable {
        case success
        case failure(String)
        case skipped(String)
    }

    let id = UUID()
    let title: String
    let outcome: Outcome

    var isFailure: Bool {
        if case .failure = outcome { true } else { false }
    }
}
