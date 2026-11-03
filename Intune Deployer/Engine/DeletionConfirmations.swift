import Foundation
import JTKit

/// What the Apply confirmation says and when Apply can be pressed; the plan
/// sheet shows it, kept here so tests can check it.
/// What Apply… was pressed with: the ticked deletions are taken once, so
/// the number the confirmation shows (or asks to type) is the number of
/// objects Apply deletes.
nonisolated struct ApplyRequest: Identifiable, Sendable, Equatable {
    let id = UUID()
    /// Tenant object IDs of the ticked orphans; Apply deletes exactly these.
    let deleteOrphanIDs: Set<String>

    var deletions: Int { deleteOrphanIDs.count }

    /// The number to type before Apply; nil when the dialog is enough.
    var typedCount: Int? { ApplyConfirmation.typedCount(deletions: deletions) }
}

nonisolated enum ApplyConfirmation {
    /// From two ticked deletions, the number of deletions is typed before
    /// Apply: JTKit's rule for what can't be undone.
    static func typedCount(deletions: Int) -> Int? {
        deletionRule(deletions).typedCount
    }

    /// What is still missing before Apply can be pressed, nil when nothing is.
    static func typingProblem(_ typed: String, deletions: Int) -> String? {
        deletionRule(deletions).problem(typedCount: typed)
    }

    private static func deletionRule(_ deletions: Int) -> MDMCommand.Confirmation {
        MDMCommand.Confirmation(action: "Delete", subject: nil, count: deletions, message: "",
                                irreversible: true, connectionName: nil, isDestructive: true)
    }

    /// "3 objects are deleted from “Contoso”. This can’t be undone."
    static func deletionLine(deletions: Int, tenant: String) -> String {
        "\(deletions) object\(deletions == 1 ? " is" : "s are") deleted from “\(tenant)”. This can’t be undone."
    }

    /// Whether applying would do anything: creates, updates, prerequisites,
    /// assignments that differ from the tenant's, or ticked orphan deletions.
    static func hasWork(_ plan: Plan?, deletions: Int) -> Bool {
        guard let plan else { return false }
        return plan.createCount > 0
            || plan.updateCount > 0
            || deletions > 0
            || plan.actions.contains(where: \.sendsAssignments)
    }

    static func canApply(_ plan: Plan?, deletions: Int, isPlanning: Bool, isApplying: Bool) -> Bool {
        guard let plan else { return false }
        return !plan.hasErrors && hasWork(plan, deletions: deletions) && !isPlanning && !isApplying
    }

    /// "2 creates, 1 update, 3 assignments, 2 deletions"
    static func summary(_ plan: Plan?, deletions: Int) -> String {
        guard let plan else { return "changes" }
        var parts = [
            "\(plan.createCount) create\(plan.createCount == 1 ? "" : "s")",
            "\(plan.updateCount) update\(plan.updateCount == 1 ? "" : "s")",
        ]
        let assignmentCount = plan.actions.count(where: \.sendsAssignments)
        if assignmentCount > 0 {
            parts.append("\(assignmentCount) assignment\(assignmentCount == 1 ? "" : "s")")
        }
        if deletions > 0 {
            parts.append("\(deletions) deletion\(deletions == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }
}

/// What Remove Baseline says and when its delete button can be pressed.
nonisolated enum RemoveBaselineConfirmation {
    /// Once the tagged objects are counted, with something to delete, and
    /// the tenant's name typed exactly (capitals count, nothing trimmed).
    static func canDelete(typedName: String, profileName: String, isApplying: Bool, objectCount: Int?) -> Bool {
        typedName == profileName && !isApplying && (objectCount ?? 0) > 0
    }

    /// The count, shown before anything is typed.
    static func countLine(_ count: Int) -> String {
        switch count {
        case 0: "This tenant profile has no objects in the tenant. There is nothing to delete."
        case 1: "1 object will be deleted."
        default: "\(count) objects will be deleted."
        }
    }
}
