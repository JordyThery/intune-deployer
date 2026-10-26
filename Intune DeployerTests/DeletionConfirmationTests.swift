import Foundation
import Testing
@testable import Intune_Deployer

/// What Apply and Remove Baseline ask before deleting.
@Suite("Deletion confirmations")
struct DeletionConfirmationTests {
    private func action(_ kind: PlanActionKind, assignments: [ResolvedAssignment]? = nil) -> PlanItemAction {
        PlanItemAction(id: UUID().uuidString, collection: .compliancePolicies, displayName: "Policy", kind: kind,
                       payload: Data(), existingObjectID: nil, assignments: assignments, warnings: [])
    }

    private func plan(creates: Int = 0, updates: Int = 0, unchanged: Int = 0, groups: Int = 0,
                      assignments: Int = 0, error: Bool = false) -> Plan {
        var plan = Plan()
        plan.actions += (0..<creates).map { _ in action(.create) }
        plan.actions += (0..<updates).map { _ in action(.update([])) }
        plan.actions += (0..<unchanged).map { _ in action(.unchanged) }
        plan.actions += (0..<assignments).map { _ in action(.unchanged, assignments: []) }
        plan.groupsToCreate = (0..<groups).map { PlannedGroupCreation(name: "Group \($0)") }
        if error {
            plan.issues = [PlanIssue(severity: .error, itemName: nil, message: "Broken")]
        }
        return plan
    }

    @Test("The Apply summary counts creates (groups included), updates, assignments and deletions")
    func summary() {
        #expect(ApplyConfirmation.summary(plan(creates: 1, updates: 1, groups: 1), deletions: 0)
            == "2 creates, 1 update")
        #expect(ApplyConfirmation.summary(plan(updates: 2, assignments: 3), deletions: 1)
            == "0 creates, 2 updates, 3 assignments, 1 deletion")
        #expect(ApplyConfirmation.summary(plan(creates: 1, assignments: 1), deletions: 2)
            == "1 create, 0 updates, 1 assignment, 2 deletions")
        #expect(ApplyConfirmation.summary(nil, deletions: 0) == "changes")
    }

    @Test("A plan has work with creates, updates, assignment refreshes or ticked deletions")
    func hasWork() {
        #expect(!ApplyConfirmation.hasWork(plan(unchanged: 3), deletions: 0))
        #expect(ApplyConfirmation.hasWork(plan(unchanged: 3), deletions: 1))
        #expect(ApplyConfirmation.hasWork(plan(assignments: 1), deletions: 0))
        #expect(ApplyConfirmation.hasWork(plan(groups: 1), deletions: 0))
        #expect(!ApplyConfirmation.hasWork(nil, deletions: 1))
    }

    @Test("Apply is greyed out without a plan, with errors, without work, or while busy")
    func canApply() {
        let work = plan(creates: 1)
        #expect(ApplyConfirmation.canApply(work, deletions: 0, isPlanning: false, isApplying: false))
        #expect(!ApplyConfirmation.canApply(nil, deletions: 0, isPlanning: false, isApplying: false))
        #expect(!ApplyConfirmation.canApply(plan(creates: 1, error: true), deletions: 0, isPlanning: false, isApplying: false))
        #expect(!ApplyConfirmation.canApply(plan(unchanged: 1), deletions: 0, isPlanning: false, isApplying: false))
        #expect(!ApplyConfirmation.canApply(work, deletions: 0, isPlanning: true, isApplying: false))
        #expect(!ApplyConfirmation.canApply(work, deletions: 0, isPlanning: false, isApplying: true))
    }

    @Test("Remove Baseline needs the tenant's name typed exactly")
    func removeBaselineName() {
        #expect(RemoveBaselineConfirmation.canDelete(typedName: "Lab9 Pro", profileName: "Lab9 Pro", isApplying: false, objectCount: 3))
        #expect(!RemoveBaselineConfirmation.canDelete(typedName: "lab9 pro", profileName: "Lab9 Pro", isApplying: false, objectCount: 3))
        #expect(!RemoveBaselineConfirmation.canDelete(typedName: "Lab9 Pro ", profileName: "Lab9 Pro", isApplying: false, objectCount: 3))
        #expect(!RemoveBaselineConfirmation.canDelete(typedName: "", profileName: "Lab9 Pro", isApplying: false, objectCount: 3))
    }

    @Test("Remove Baseline is greyed out while applying")
    func removeBaselineBusy() {
        #expect(!RemoveBaselineConfirmation.canDelete(typedName: "Lab9 Pro", profileName: "Lab9 Pro", isApplying: true, objectCount: 3))
    }

    // MARK: - New in step 8 (decided by Jordy)

    @Test("Remove Baseline first counts what it deletes: not before the count, not with nothing to delete")
    func removeBaselineCount() {
        #expect(!RemoveBaselineConfirmation.canDelete(typedName: "Lab9 Pro", profileName: "Lab9 Pro", isApplying: false, objectCount: nil))
        #expect(!RemoveBaselineConfirmation.canDelete(typedName: "Lab9 Pro", profileName: "Lab9 Pro", isApplying: false, objectCount: 0))
        #expect(RemoveBaselineConfirmation.countLine(12) == "12 objects will be deleted.")
        #expect(RemoveBaselineConfirmation.countLine(1) == "1 object will be deleted.")
        #expect(RemoveBaselineConfirmation.countLine(0).contains("nothing to delete"))
    }

    @Test("Apply with two or more deletions asks to type their number; with one, the dialog is enough")
    func applyTypedCount() {
        #expect(ApplyConfirmation.typedCount(deletions: 0) == nil)
        #expect(ApplyConfirmation.typedCount(deletions: 1) == nil)
        #expect(ApplyConfirmation.typedCount(deletions: 2) == 2)
        #expect(ApplyConfirmation.typingProblem("", deletions: 3) == "Type 3 to confirm.")
        #expect(ApplyConfirmation.typingProblem("2", deletions: 3) == "Type 3 to confirm.")
        #expect(ApplyConfirmation.typingProblem(" 3 ", deletions: 3) == nil)
        #expect(ApplyConfirmation.typingProblem("", deletions: 1) == nil)
        #expect(ApplyConfirmation.deletionLine(deletions: 3, tenant: "Lab9 Pro") == "3 objects are deleted from “Lab9 Pro”. This can’t be undone.")
    }
}
