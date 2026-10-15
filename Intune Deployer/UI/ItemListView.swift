import SwiftUI

/// Content column: inferred items for the selected sources, with selection
/// checkboxes, search, type filters and a skipped-files section.
struct ItemListView: View {
    @Environment(SourceStore.self) private var store
    @Environment(TenantStore.self) private var tenantStore
    let selectedSourceIDs: Set<UUID>
    @Binding var selectedItemID: String?
    @Binding var searchText: String
    @Binding var typeFilter: ItemType?

    private var items: [InferredItem] {
        var items = store.items(for: selectedSourceIDs)
        if let typeFilter {
            items = items.filter { $0.type == typeFilter }
        }
        if !searchText.isEmpty {
            items = items.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
                    || $0.relativePath.localizedCaseInsensitiveContains(searchText)
            }
        }
        return items
    }

    private var skipped: [SkippedFile] {
        store.skippedFiles(for: selectedSourceIDs)
    }

    var body: some View {
        List(selection: $selectedItemID) {
            Section {
                ForEach(items) { item in
                    ItemRow(
                        item: item,
                        sourceName: sourceName(for: item),
                        isSelected: selectionBinding(for: item),
                        hasActiveProfile: tenantStore.selectedProfile != nil
                    )
                    .tag(item.id)
                }
            } header: {
                Text("Items")
                    .badge(items.count)
            }

            if !skipped.isEmpty {
                Section {
                    ForEach(skipped) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.relativePath)
                                .font(.callout)
                            Text(file.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .selectionDisabled()
                    }
                } header: {
                    Text("Skipped")
                        .badge(skipped.count)
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search items")
        .overlay {
            if selectedSourceIDs.isEmpty {
                ContentUnavailableView(
                    "No Source Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select one or more sources in the sidebar.")
                )
            } else if items.isEmpty && skipped.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Items" : "No Results",
                    systemImage: searchText.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(searchText.isEmpty
                        ? "No supported files were found in the selected sources."
                        : "No items match “\(searchText)”.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Type", selection: $typeFilter) {
                        Text("All Types").tag(ItemType?.none)
                        Divider()
                        ForEach(ItemType.allCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.symbolName)
                                .tag(ItemType?.some(type))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: typeFilter == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filter items by type")
            }
        }
    }

    private func sourceName(for item: InferredItem) -> String {
        store.sources.first { $0.id == item.sourceID }?.name ?? "?"
    }

    /// Selection lives on the active tenant profile — it is what gets planned
    /// and deployed. Checkboxes are disabled while no profile is active.
    private func selectionBinding(for item: InferredItem) -> Binding<Bool> {
        Binding(
            get: { tenantStore.selectedProfile?.selectedItemIDs.contains(item.id) ?? false },
            set: { isOn in
                guard var updated = tenantStore.selectedProfile else { return }
                if isOn {
                    updated.selectedItemIDs.insert(item.id)
                } else {
                    updated.selectedItemIDs.remove(item.id)
                }
                tenantStore.update(updated)
            }
        )
    }
}

private struct ItemRow: View {
    let item: InferredItem
    let sourceName: String
    @Binding var isSelected: Bool
    let hasActiveProfile: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Deploy \(item.displayName)", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!hasActiveProfile)
                .help(hasActiveProfile ? "" : "Select a tenant profile to choose items for deployment")
            Image(systemName: item.type.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .help(item.type.displayName)
                .accessibilityHidden(true) // type is in the row text
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                HStack(spacing: 6) {
                    Text(item.type.displayName)
                    Text("·")
                    Text(sourceName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !item.tokens.isEmpty {
                Image(systemName: "curlybraces")
                    .foregroundStyle(.secondary)
                    .help("Uses variables: \(item.tokens.joined(separator: ", "))")
                    .accessibilityLabel("Uses variables \(item.tokens.joined(separator: ", "))")
            }
        }
        .padding(.vertical, 2)
    }
}
