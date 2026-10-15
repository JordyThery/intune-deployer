import SwiftUI

/// Content column: inferred items for the selected sources, with selection
/// checkboxes, search, type filters and a skipped-files section. Supports
/// multi-selection (⇧/⌘-click, ⌘A) for bulk include/exclude and assignment.
struct ItemListView: View {
    @Environment(SourceStore.self) private var store
    @Environment(TenantStore.self) private var tenantStore
    let selectedSourceIDs: Set<UUID>
    @Binding var selectedItemIDs: Set<String>
    @Binding var searchText: String
    @Binding var typeFilter: ItemType?

    @FocusState private var listFocused: Bool

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

    private var includedShownCount: Int {
        guard let profile = tenantStore.selectedProfile else { return 0 }
        return items.count { profile.selectedItemIDs.contains($0.id) }
    }

    var body: some View {
        List(selection: $selectedItemIDs) {
            Section {
                ForEach(items) { item in
                    ItemRow(
                        item: item,
                        sourceName: sourceName(for: item),
                        isSelected: selectionBinding(for: item),
                        hasActiveProfile: tenantStore.selectedProfile != nil,
                        edit: store.edits.edit(for: item.id)
                    )
                    .tag(item.id)
                }
            } header: {
                itemsHeader
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
        .focused($listFocused)
        .onAppear { listFocused = true }
        .contextMenu(forSelectionType: String.self) { ids in
            rowContextMenu(ids: ids)
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
                    Button("Include All Shown") { setIncluded(true, itemIDs: items.map(\.id)) }
                        .disabled(includedShownCount == items.count)
                    Button("Exclude All Shown") { setIncluded(false, itemIDs: items.map(\.id)) }
                        .disabled(includedShownCount == 0)
                } label: {
                    Label("Selection", systemImage: "checklist")
                }
                .help("Include or exclude every item currently shown (respects search and type filter)")
                .disabled(tenantStore.selectedProfile == nil || items.isEmpty)
            }
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

    // MARK: - Header

    /// Mixed-state checkbox toggling every shown item, plus a deploy count.
    private var itemsHeader: some View {
        HStack(spacing: 6) {
            if tenantStore.selectedProfile != nil, !items.isEmpty {
                let allIncluded = includedShownCount == items.count
                Button {
                    setIncluded(!allIncluded, itemIDs: items.map(\.id))
                } label: {
                    Image(systemName: allIncluded
                        ? "checkmark.square.fill"
                        : includedShownCount == 0 ? "square" : "minus.square.fill")
                }
                .buttonStyle(.borderless)
                .help(allIncluded ? "Exclude all shown items" : "Include all shown items")
                .accessibilityLabel(allIncluded ? "Exclude all shown items" : "Include all shown items")
            }
            Text("Items")
            Spacer()
            if tenantStore.selectedProfile != nil {
                Text("\(includedShownCount) of \(items.count) selected")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(items.count)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func rowContextMenu(ids: Set<String>) -> some View {
        let hasProfile = tenantStore.selectedProfile != nil
        Button("Include for Deployment") { setIncluded(true, itemIDs: Array(ids)) }
            .disabled(!hasProfile || ids.isEmpty)
        Button("Exclude from Deployment") { setIncluded(false, itemIDs: Array(ids)) }
            .disabled(!hasProfile || ids.isEmpty)
        Divider()
        Menu("Assign To") {
            Button("Type Default") { setAssignmentEntries(ids: ids, intent: nil) }
            Divider()
            ForEach(AssignmentIntent.Mode.allCases.filter { $0 != .group }, id: \.self) { mode in
                Button(mode.displayName) {
                    var intent = AssignmentIntent()
                    intent.mode = mode
                    setAssignmentEntries(ids: ids, intent: intent)
                }
            }
            // Groups and filters need names — use the assignment editor.
        }
        .disabled(!hasProfile || ids.isEmpty)
    }

    // MARK: - Bulk edits

    private func setIncluded(_ included: Bool, itemIDs: [String]) {
        guard var profile = tenantStore.selectedProfile else { return }
        if included {
            profile.selectedItemIDs.formUnion(itemIDs)
        } else {
            profile.selectedItemIDs.subtract(itemIDs)
        }
        tenantStore.update(profile)
    }

    /// nil removes the per-item entries so the type default applies again.
    private func setAssignmentEntries(ids: Set<String>, intent: AssignmentIntent?) {
        guard var profile = tenantStore.selectedProfile else { return }
        for id in ids {
            profile.assignments[id] = intent
        }
        tenantStore.update(profile)
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
    let edit: ItemEdit?

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
            if let edit {
                if edit.hasConflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("The source file changed since the in-app edit — review it in the item's details")
                        .accessibilityLabel("Edited in the app; source changed since the edit")
                } else {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.secondary)
                        .help("Content was edited in the app — the edit deploys instead of the file")
                        .accessibilityLabel("Edited in the app")
                }
            }
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
