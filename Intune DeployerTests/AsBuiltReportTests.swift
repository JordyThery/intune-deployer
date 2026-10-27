import Foundation
import Testing
@testable import Intune_Deployer

@Suite("As-built report")
struct AsBuiltReportTests {
    private func sampleInput() -> AsBuiltReport.Input {
        var plan = Plan()
        plan.actions = [
            PlanItemAction(
                id: "3f9a1c2e",
                collection: .settingsCatalog,
                displayName: "[CONTOSO] Disable Content Caching",
                kind: .create,
                payload: Data(#"{"name": "[CONTOSO] Disable Content Caching", "platforms": "macOS"}"#.utf8),
                existingObjectID: nil,
                assignments: [ResolvedAssignment(target: .allDevices, filter: nil)],
                warnings: ["Example warning"]
            ),
        ]
        plan.groupsToCreate = [PlannedGroupCreation(name: "macOS Pilots")]
        return AsBuiltReport.Input(
            profileName: "Demo & Co <test>",
            tenantID: "efccb476-07c8-4c09-be3d-6927868b2402",
            namingPrefix: "[CONTOSO]",
            plan: plan,
            results: [
                ApplyResult(title: "Create [CONTOSO] Disable Content Caching", outcome: .success),
                ApplyResult(title: "Assign [CONTOSO] Disable Content Caching", outcome: .failure("HTTP 400")),
            ],
            date: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    @Test func markdownContainsItemsAssignmentsAndResults() {
        let markdown = AsBuiltReport.markdown(sampleInput())
        #expect(markdown.contains("# As-Built Report — Demo & Co <test>"))
        #expect(markdown.contains("[CONTOSO] Disable Content Caching"))
        #expect(markdown.contains("| Assignment | All devices |"))
        #expect(markdown.contains("[IntuneDeployer:3f9a1c2e]"))
        #expect(markdown.contains("macOS Pilots"))
        #expect(markdown.contains("```json"))
        #expect(markdown.contains("platforms"))
        #expect(markdown.contains("1 of 2 steps failed"))
        #expect(markdown.contains("⚠️ Example warning"))
    }

    @Test func htmlIsEscapedAndComplete() {
        let html = AsBuiltReport.html(sampleInput())
        #expect(html.contains("Demo &amp; Co &lt;test&gt;"))
        #expect(!html.contains("Demo & Co <test>")) // raw form must not leak
        #expect(html.contains("<details>"))
        #expect(html.contains("All devices"))
        #expect(html.contains("❌ HTTP 400"))
        #expect(html.hasPrefix("<!DOCTYPE html>"))
    }

    @Test func assignmentDescriptionsAreReadable() {
        #expect(AsBuiltReport.assignmentDescription(nil) == "Not assigned (left untouched)")
        #expect(AsBuiltReport.assignmentDescription(
            [ResolvedAssignment(target: .group(id: "g1", name: "Pilots"), filter: .pendingCreation(name: "ADE"), filterMode: .exclude)]
        ) == "Group “Pilots” with exclude filter “ADE”")
    }
}
