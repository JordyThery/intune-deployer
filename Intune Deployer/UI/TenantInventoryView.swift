import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lists the existing Intune objects in the selected tenant, grouped by type.
/// Objects created by this app (identity tag in the description) get a badge.
/// Objects can be exported as baseline files (app packages excepted).
struct TenantInventoryView: View {
    @Environment(TenantSession.self) private var session
    @Environment(AuthManager.self) private var auth
    let profile: TenantProfile

    @State private var selection: Set<ExportSelection> = []
    @State private var pendingExport: [ExportSelection] = []
    @State private var isPickingExportFolder = false
    @State private var exportSummary: ExportSummary?

    var body: some View {
        List(selection: $selection) {
            ForEach(TenantCollection.allCases) { collection in
                Section {
                    if let error = session.inventoryErrors[collection] {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    } else if let objects = session.inventory[collection] {
                        if objects.isEmpty {
                            Text("None")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .selectionDisabled()
                        }
                        ForEach(objects) { object in
                            row(object, collection: collection)
                                .tag(exportSelection(object, collection: collection))
                                // App content cannot be downloaded from Graph.
                                .selectionDisabled(collection == .apps)
                        }
                    }
                } header: {
                    HStack {
                        Text(collection.displayName)
                        if let objects = session.inventory[collection] {
                            Text("\(objects.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: ExportSelection.self) { picked in
            Button("Export…") { beginExport(Array(picked)) }
                .disabled(picked.isEmpty || session.isExporting)
        }
        .overlay {
            if !auth.isSignedIn(profile) {
                ContentUnavailableView(
                    "Not Signed In",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Sign in to list this tenant's existing objects.")
                )
            } else if session.inventory.isEmpty && session.inventoryErrors.isEmpty && !session.isLoadingInventory {
                ContentUnavailableView {
                    Label("Inventory Not Loaded", systemImage: "cloud")
                } description: {
                    Text("Load the existing Intune objects in \(profile.displayName).")
                } actions: {
                    Button("Load Inventory") {
                        Task { await session.loadInventory(for: profile) }
                    }
                }
            } else if session.isLoadingInventory && session.inventory.isEmpty {
                ProgressView("Loading inventory…")
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await session.loadInventory(for: profile) }
                } label: {
                    Label("Reload Inventory", systemImage: "arrow.clockwise.icloud")
                }
                .disabled(!auth.isSignedIn(profile) || session.isLoadingInventory)
                .help("Fetch the tenant's current objects again from Microsoft Graph")
            }
            ToolbarItem {
                if session.isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .help("Exporting…")
                } else {
                    Button {
                        beginExport(allExportable)
                    } label: {
                        Label("Export All", systemImage: "square.and.arrow.up")
                    }
                    .disabled(allExportable.isEmpty)
                    .help("Export every object except app packages as baseline files. To export only some, select them and choose Export… from the context menu.")
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingExportFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let folder = urls.first else { return }
            let picked = pendingExport
            Task {
                exportSummary = await session.export(picked, profile: profile, to: folder)
            }
        }
        .fileDialogMessage("Choose a folder for the exported files. Existing files are never overwritten.")
        .fileDialogConfirmationLabel("Export")
        .alert(
            exportSummary.map { "\($0.written.count) File\($0.written.count == 1 ? "" : "s") Exported" } ?? "",
            isPresented: Binding(
                get: { exportSummary != nil },
                set: { if !$0 { exportSummary = nil } }
            ),
            presenting: exportSummary
        ) { summary in
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([summary.folder])
            }
            Button("OK", role: .cancel) {}
        } message: { summary in
            Text(summaryMessage(summary))
        }
        .onChange(of: profile.id) { selection = [] }
        .navigationTitle(profile.displayName)
    }

    private func row(_ object: TenantObject, collection: TenantCollection) -> some View {
        HStack {
            Image(systemName: collection.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(object.resolvedName)
                if let modified = object.lastModifiedDateTime {
                    Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let shortID = object.taggedShortID {
                Text("Managed")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .help("Created by Intune Deployer — identity tag \(ItemIdentity.tag(forShortID: shortID))")
            }
        }
    }

    // MARK: - Export

    private func exportSelection(_ object: TenantObject, collection: TenantCollection) -> ExportSelection {
        ExportSelection(collection: collection, objectID: object.id, name: object.resolvedName)
    }

    private var allExportable: [ExportSelection] {
        TenantExporter.exportableCollections.flatMap { collection in
            (session.inventory[collection] ?? []).map { exportSelection($0, collection: collection) }
        }
    }

    private func beginExport(_ picked: [ExportSelection]) {
        let exportable = picked.filter { $0.collection != .apps }
        guard !exportable.isEmpty else { return }
        pendingExport = exportable
        isPickingExportFolder = true
    }

    private func summaryMessage(_ summary: ExportSummary) -> String {
        var text = "Saved to \(summary.folder.lastPathComponent), one folder per type."
        if !summary.skipped.isEmpty {
            let shown = summary.skipped.prefix(8).map { "• \($0.name): \($0.reason)" }
            text += "\n\n\(summary.skipped.count) skipped:\n" + shown.joined(separator: "\n")
            if summary.skipped.count > shown.count {
                text += "\n… and \(summary.skipped.count - shown.count) more"
            }
        }
        return text
    }
}
