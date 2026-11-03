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
    /// The tenant object's assignments are already exactly `assignments`
    /// (read at plan time), so Apply sends none. False when they couldn't
    /// be read: Apply then sends them.
    var assignmentsUpToDate = false
    /// An app's package as Plan read it; Apply refuses to upload another.
    var package: PlanInput.PackageFile?
    /// The payload as the as-built report shows it: built again with "••••"
    /// for every variable, so a value is masked only where a variable put it.
    var reportPayload: ReportPayload = .same

    /// The payload for the as-built report.
    enum ReportPayload: Sendable, Equatable {
        /// No variable in it: the payload as sent.
        case same
        /// With "••••" where each variable's value is.
        case masked(Data)
        /// It has variable values but couldn't be built masked (a variable
        /// outside a string, e.g. a number): left out of the report.
        case leftOut
    }

    /// Whether Apply uploads this app's package.
    var uploadsPackage: Bool {
        collection == .apps && PlanEngine.uploadsPackage(kind)
    }

    /// Whether Apply sends this action's assignments.
    var sendsAssignments: Bool {
        assignments != nil && (kind == .create || !assignmentsUpToDate)
    }
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

/// A tenant object carrying the app's identity tag whose item is no longer selected.
nonisolated struct OrphanedObject: Sendable, Identifiable, Hashable {
    var id: String { objectID }
    let collection: TenantCollection
    let objectID: String
    let displayName: String
    let shortID: String
}

/// A plan error: Apply is refused until it is fixed. Warnings belong to
/// their action (`PlanItemAction.warnings`).
nonisolated struct PlanIssue: Sendable, Identifiable {
    enum Severity: Sendable {
        case error
    }

    let id = UUID()
    let severity: Severity
    /// Display name of the related item, if any.
    let itemName: String?
    let message: String
}

/// The dry-run result. Nothing is written until the user applies it.
nonisolated struct Plan: Sendable {
    /// The profile and tenant the plan was made for; Apply refuses it for
    /// any other. Nil only in plans made by tests.
    var profileID: UUID?
    var tenantID: String?
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
    enum Outcome: Sendable, Equatable {
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

    var isSkipped: Bool {
        if case .skipped = outcome { true } else { false }
    }

    /// The line under finished results: skipped steps are counted apart
    /// from the ones that were applied.
    static func summary(_ results: [ApplyResult]) -> String {
        let failures = results.count(where: \.isFailure)
        let skipped = results.count(where: \.isSkipped)
        let applied = results.count - failures - skipped
        func steps(_ count: Int) -> String { "\(count) step\(count == 1 ? "" : "s")" }
        if failures > 0 {
            return "\(failures) of \(steps(results.count)) failed"
        }
        if skipped > 0 {
            return "\(steps(applied)) applied, \(skipped) skipped"
        }
        return "Applied \(steps(applied)) successfully"
    }
}
