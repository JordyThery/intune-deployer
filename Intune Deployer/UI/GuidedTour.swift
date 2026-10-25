import Foundation
import JTKit

// An interactive walkthrough of the deployment workflow, drawn by JTKit: a
// dimmed overlay with a spotlight on the relevant part of the window and a
// callout card per step. It needs no sources or tenants configured, starts
// automatically on first launch, and can be replayed from Help › Guided Tour.

/// Parts of the window the tour can spotlight.
nonisolated enum TourAnchorID: Hashable, Sendable {
    case sources
    case tenantProfiles
    case items
    case detail
}

enum IntuneDeployerTour {
    /// Keeps the app's existing "tour seen" key so the tour doesn't reappear.
    static func makeState(defaults: UserDefaults = .standard) -> TourState<TourAnchorID> {
        TourState(steps: steps, firstLaunchDefaultsKey: "hasSeenGuidedTour", defaults: defaults)
    }

    private static let steps: [TourStep<TourAnchorID>] = [
        TourStep(title: "Welcome to Intune Deployer",
                 text: "This app deploys macOS and iOS/iPadOS configuration to Microsoft Intune from plain files — no manifests, no PowerShell. This tour walks through the workflow; nothing is read or written while it runs."),
        TourStep(title: "1 · Sources",
                 text: "Add a local folder or a GitHub repository here. Sources are scanned recursively: Settings Catalog JSON, .mobileconfig profiles, compliance policies, shell scripts, custom attributes, assignment filters and app packages (.pkg, .dmg, .ipa) become items; everything else is listed under Skipped with a reason.",
                 anchorID: .sources),
        TourStep(title: "2 · Tenant profiles",
                 text: "Each Entra tenant gets a profile with its own app registration: add it in Settings › Connections (client ID and tenant ID — see the README for the one-time setup), or from the Connection menu. The tenant in use appears here; its Baseline Settings hold the naming prefix, variable values and default assignments per item type. Item selection and assignments are stored per profile.",
                 anchorID: .tenantProfiles),
        TourStep(title: "3 · Sign in",
                 text: "Pick the active tenant in the toolbar and sign in with an account that has Intune permissions there. Microsoft Graph permissions are delegated and requested incrementally — reading at sign-in, writing at first Apply.",
                 pointsAtToolbar: true),
        TourStep(title: "4 · Choose items",
                 text: "The checkboxes decide what is deployed to the active tenant; highlighting rows is separate. Use ⇧/⌘-click or ⌘A to work on many items at once, the header checkbox or the Selection menu to include or exclude everything shown, and search or the type and platform filters to narrow the list.",
                 anchorID: .items),
        TourStep(title: "5 · Item details",
                 text: "The detail column shows what was detected and why, the variables a file uses, a preview, and the item's assignments — all devices, all users or groups, with optional filters, plus excluded groups. “Type default” follows the tenant profile; selecting several items edits them all at once.",
                 anchorID: .detail),
        TourStep(title: "6 · Plan, then Apply",
                 text: "Plan (⌘P) is a dry run: it reads the tenant and shows creates, update diffs (Settings Catalog changes by setting name, with the raw JSON one click away), unchanged items, warnings and errors — nothing is written until you confirm Apply. Objects the app created but you no longer select are deleted only when explicitly ticked.",
                 pointsAtToolbar: true),
        TourStep(title: "7 · The tenant view",
                 text: "Select the tenant in the sidebar for a read-only preflight checklist (MDM authority, Apple MDM push certificate, ADE tokens) and the tenant's existing objects, which you can export as baseline files. Objects the app creates carry an identity tag, so re-runs update instead of duplicating — anything without the tag is never touched.",
                 anchorID: .tenantProfiles),
        TourStep(title: "That's the tour",
                 text: "Start by adding a source and a tenant profile. The activity log (⌘⇧L) records every Graph request, and an as-built report can be exported after each Apply. Replay this tour any time from Help › Guided Tour."),
    ]
}
