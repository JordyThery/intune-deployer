import SwiftUI

/// Detail column when several items are highlighted: a type breakdown,
/// bulk include/exclude and a bulk assignment editor.
struct MultiItemDetailView: View {
    @Environment(TenantStore.self) private var tenantStore
    let items: [InferredItem]

    private var includedCount: Int {
        guard let profile = tenantStore.selectedProfile else { return 0 }
        return items.count { profile.selectedItemIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                deploymentSection
                // Assignment filters cannot themselves be assigned.
                let assignable = items.filter { $0.type != .assignmentFilter }
                if let profile = tenantStore.selectedProfile, !assignable.isEmpty {
                    AssignmentEditorView(items: assignable, profile: profile)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.on.square")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(items.count) Items")
                    .font(.title2.bold())
                Text(typeBreakdown)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// e.g. "3 × Shell Script, 2 × Settings Catalog".
    private var typeBreakdown: String {
        let counts = Dictionary(grouping: items, by: \.type).mapValues(\.count)
        return ItemType.allCases
            .compactMap { type in counts[type].map { "\($0) × \(type.displayName)" } }
            .joined(separator: ", ")
    }

    private var deploymentSection: some View {
        GroupBox("Deployment") {
            VStack(alignment: .leading, spacing: 8) {
                if tenantStore.selectedProfile == nil {
                    Text("Select a tenant profile to choose items for deployment.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(includedCount) of \(items.count) included for deployment")
                    HStack {
                        Button("Include All") { setIncluded(true) }
                            .disabled(includedCount == items.count)
                        Button("Exclude All") { setIncluded(false) }
                            .disabled(includedCount == 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setIncluded(_ included: Bool) {
        guard var profile = tenantStore.selectedProfile else { return }
        for item in items {
            if included {
                profile.selectedItemIDs.insert(item.id)
            } else {
                profile.selectedItemIDs.remove(item.id)
            }
        }
        tenantStore.update(profile)
    }
}
