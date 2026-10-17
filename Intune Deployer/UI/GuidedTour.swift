import SwiftUI

// An interactive walkthrough of the deployment workflow: a dimmed overlay
// with a spotlight on the relevant part of the window and a callout card
// per step. It needs no sources or tenants configured, starts automatically
// on first launch, and can be replayed from Help › Guided Tour.

// MARK: - State

/// The tour's only state: the current step, nil when the tour is off.
@MainActor @Observable
final class TourState {
    var index: Int?

    func start() {
        index = 0
    }

    func end() {
        index = nil
        UserDefaults.standard.set(true, forKey: "hasSeenGuidedTour")
    }

    func startOnFirstLaunch() {
        // Mark it seen right away so a relaunch can't restart a skipped tour.
        guard !UserDefaults.standard.bool(forKey: "hasSeenGuidedTour") else { return }
        UserDefaults.standard.set(true, forKey: "hasSeenGuidedTour")
        start()
    }
}

// MARK: - Anchors

/// Parts of the window the tour can spotlight.
enum TourAnchorID: Hashable {
    case sources
    case tenantProfiles
    case items
    case detail
}

/// Collects every anchor per target: a modifier on a List `Section` lands on
/// each of its rows, so the spotlight unions all of them into one rectangle.
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourAnchorID: [Anchor<CGRect>]] = [:]
    static func reduce(value: inout [TourAnchorID: [Anchor<CGRect>]],
                       nextValue: () -> [TourAnchorID: [Anchor<CGRect>]]) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}

extension View {
    /// Marks a view as a tour spotlight target.
    func tourAnchor(_ id: TourAnchorID) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: [$0]] }
    }
}

// MARK: - Steps

struct TourStep {
    let title: String
    let text: String
    /// The spotlighted part of the window; nil centers the card.
    var anchor: TourAnchorID?
    /// Where the card goes when the target is in the toolbar, which the
    /// spotlight cannot reach.
    var pointsAtToolbar = false

    static let all: [TourStep] = [
        TourStep(title: "Welcome to Intune Deployer",
                 text: "This app deploys macOS and iOS/iPadOS configuration to Microsoft Intune from plain files — no manifests, no PowerShell. This tour walks through the workflow; nothing is read or written while it runs."),
        TourStep(title: "1 · Sources",
                 text: "Add a local folder or a GitHub repository here. Sources are scanned recursively: Settings Catalog JSON, .mobileconfig profiles, compliance policies, shell scripts, custom attributes, assignment filters and app packages (.pkg, .dmg, .ipa) become items; everything else is listed under Skipped with a reason.",
                 anchor: .sources),
        TourStep(title: "2 · Tenant profiles",
                 text: "Each Entra tenant gets a profile with its own app registration (client ID and tenant ID — see the README for the one-time setup), a naming prefix, variable values and default assignments per item type. Item selection and assignments are stored per profile.",
                 anchor: .tenantProfiles),
        TourStep(title: "3 · Sign in",
                 text: "Pick the active tenant in the toolbar and sign in with an account that has Intune permissions there. Microsoft Graph permissions are delegated and requested incrementally — reading at sign-in, writing at first Apply.",
                 pointsAtToolbar: true),
        TourStep(title: "4 · Choose items",
                 text: "The checkboxes decide what is deployed to the active tenant; highlighting rows is separate. Use ⇧/⌘-click or ⌘A to work on many items at once, the header checkbox or the Selection menu to include or exclude everything shown, and search or the type filter to narrow the list.",
                 anchor: .items),
        TourStep(title: "5 · Item details",
                 text: "The detail column shows what was detected and why, the variables a file uses, a preview, and the item's assignment — all devices, all users, or a group, with an optional filter. “Type default” follows the tenant profile; selecting several items edits them all at once.",
                 anchor: .detail),
        TourStep(title: "6 · Plan, then Apply",
                 text: "Plan (⌘P) is a dry run: it reads the tenant and shows creates, field-level update diffs, unchanged items, warnings and errors — nothing is written until you confirm Apply. Objects the app created but you no longer select are deleted only when explicitly ticked.",
                 pointsAtToolbar: true),
        TourStep(title: "7 · The tenant view",
                 text: "Select a tenant profile in the sidebar for a read-only preflight checklist (MDM authority, Apple MDM push certificate, ADE tokens) and the tenant's existing objects, which you can export as baseline files. Objects the app creates carry an identity tag, so re-runs update instead of duplicating — anything without the tag is never touched.",
                 anchor: .tenantProfiles),
        TourStep(title: "That's the tour",
                 text: "Start by adding a source and a tenant profile. The activity log (⌘⇧L) records every Graph request, and an as-built report can be exported after each Apply. Replay this tour any time from Help › Guided Tour."),
    ]
}

// MARK: - Overlay

/// The dimmed overlay with the spotlight cutout and the callout card.
/// Attach with `.guidedTour(_:)` on the window's root view.
struct GuidedTourOverlay: View {

    @Environment(TourState.self) private var tour
    let anchors: [TourAnchorID: [Anchor<CGRect>]]

    var body: some View {
        if let index = tour.index, TourStep.all.indices.contains(index) {
            let step = TourStep.all[index]
            GeometryReader { proxy in
                let target = step.anchor
                    .flatMap { anchors[$0] }
                    .flatMap { list -> CGRect? in
                        // a List section can emit a zero-sized placeholder at
                        // the origin; it must not poison the union
                        let rects = list.map { proxy[$0] }.filter { $0.width > 1 && $0.height > 1 }
                        guard let first = rects.first else { return nil }
                        return rects.dropFirst().reduce(first) { $0.union($1) }
                    }
                    .map { $0.insetBy(dx: -4, dy: -4) }

                ZStack {
                    spotlight(in: proxy, cutout: target)
                    card(for: step, index: index)
                        .frame(maxWidth: 400)
                        .position(cardPosition(for: step, target: target, in: proxy.size))
                }
            }
            .transition(.opacity)
        }
    }

    /// The dim layer; a rounded cutout is left clear over the target. The
    /// rect extends into the safe areas by hand — `ignoresSafeArea` would
    /// shift the whole path's coordinate space up by the title-bar inset.
    private func spotlight(in proxy: GeometryProxy, cutout: CGRect?) -> some View {
        let insets = proxy.safeAreaInsets
        var path = Path(CGRect(x: -insets.leading,
                               y: -insets.top,
                               width: proxy.size.width + insets.leading + insets.trailing,
                               height: proxy.size.height + insets.top + insets.bottom))
        if let cutout {
            path.addRoundedRect(in: cutout, cornerSize: CGSize(width: 8, height: 8))
        }
        return path
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
    }

    private func card(for step: TourStep, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if step.pointsAtToolbar {
                    Image(systemName: "arrow.up")
                }
                Text(step.title)
                    .font(.headline)
                Spacer()
                Text("\(index + 1) / \(TourStep.all.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(step.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Skip Tour") { tour.end() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if index > 0 {
                    Button("Back") { tour.index = index - 1 }
                }
                if index + 1 < TourStep.all.count {
                    Button("Next") { tour.index = index + 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { tour.end() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(radius: 12)
    }

    /// The card sits next to its target, clamped to the window; toolbar
    /// steps pin it top-trailing, anchorless steps center it.
    private func cardPosition(for step: TourStep, target: CGRect?, in size: CGSize) -> CGPoint {
        let cardSize = CGSize(width: 400, height: 190)
        var point: CGPoint
        if let target {
            // beside the target when it hugs a window edge, otherwise below
            if target.maxX + cardSize.width + 24 < size.width {
                point = CGPoint(x: target.maxX + 24 + cardSize.width / 2, y: target.midY)
            } else if target.minX - cardSize.width - 24 > 0 {
                point = CGPoint(x: target.minX - 24 - cardSize.width / 2, y: target.midY)
            } else {
                point = CGPoint(x: target.midX, y: target.maxY + 24 + cardSize.height / 2)
            }
        } else if step.pointsAtToolbar {
            point = CGPoint(x: size.width - cardSize.width / 2 - 24, y: cardSize.height / 2 + 24)
        } else {
            point = CGPoint(x: size.width / 2, y: size.height / 2)
        }
        point.x = min(max(point.x, cardSize.width / 2 + 12), size.width - cardSize.width / 2 - 12)
        point.y = min(max(point.y, cardSize.height / 2 + 12), size.height - cardSize.height / 2 - 12)
        return point
    }
}

extension View {
    /// Shows the guided tour over this view whenever `TourState.index` is
    /// set, and starts it automatically on first launch.
    func guidedTour(_ tour: TourState) -> some View {
        overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GuidedTourOverlay(anchors: anchors)
                .animation(.easeInOut(duration: 0.2), value: tour.index)
        }
        .task {
            tour.startOnFirstLaunch()
        }
    }
}
