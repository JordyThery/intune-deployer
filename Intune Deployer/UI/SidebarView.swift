import JTKit
import SwiftUI
import UniformTypeIdentifiers

/// What the sidebar can select: baseline sources (multi) or the tenant in use.
enum SidebarSelection: Hashable {
    case source(UUID)
    case tenant(UUID)
}

/// Sidebar: baseline sources with scan status, plus the tenant in use.
struct SidebarView: View {
    @Environment(SourceStore.self) private var store
    @Environment(TenantStore.self) private var tenantStore
    @Binding var selection: Set<SidebarSelection>

    @State private var isPickingFolder = false
    @State private var isAddingGitHubSource = false

    var body: some View {
        List(selection: $selection) {
            Section("Sources") {
                ForEach(store.sources) { source in
                    sourceRow(source)
                        .tag(SidebarSelection.source(source.id))
                        .contextMenu {
                            if source.isGitHub {
                                Button(store.availableUpdates[source.id].map { "Update to \($0)" } ?? "Sync Now") {
                                    Task { await store.syncGitHub(sourceID: source.id) }
                                }
                                Button("Check for Updates") {
                                    Task { await store.checkGitHubUpdates() }
                                }
                                if let url = source.gitHubSpec?.repoURL {
                                    Link("Open on GitHub", destination: url)
                                }
                            } else {
                                Button("Rescan") {
                                    Task { await store.scan(sourceID: source.id) }
                                }
                            }
                            Button("Remove Source", role: .destructive) {
                                selection.remove(.source(source.id))
                                store.removeSource(id: source.id)
                            }
                        }
                }
                Button {
                    isPickingFolder = true
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Button {
                    isAddingGitHubSource = true
                } label: {
                    Label("Add GitHub Repository…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .tourAnchor(TourAnchorID.sources)

            // Tenants are managed in Settings › Connections; the one in use
            // (chosen in the toolbar) opens the tenant view here.
            Section("Tenant") {
                if let profile = tenantStore.selectedProfile {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                            Text(profile.tenantID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "building.2")
                    }
                    .tag(SidebarSelection.tenant(profile.id))
                    .contextMenu {
                        SettingsTabLink(SettingsTabName.connections) { Text("Edit Connection…") }
                    }
                } else if tenantStore.profiles.isEmpty {
                    SettingsTabLink(SettingsTabName.connections) {
                        Label("Add Tenant Profile…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text("Choose a tenant in the toolbar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
            .tourAnchor(TourAnchorID.tenantProfiles)
        }
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.addLocalFolder(at: url)
            }
        }
        .sheet(isPresented: $isAddingGitHubSource) {
            GitHubSourceEditorView()
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: BaselineSource) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                    statusText(for: source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: source.isGitHub ? "arrow.triangle.branch" : "folder")
            }
            Spacer()
            if store.scanningSourceIDs.contains(source.id) {
                ProgressView()
                    .controlSize(.small)
            } else if store.scanErrors[source.id] != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(store.scanErrors[source.id] ?? "")
                    .accessibilityLabel("Problem: \(store.scanErrors[source.id] ?? "scan failed")")
            } else if let newTag = store.availableUpdates[source.id] {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                    .help("Update available — choose “Update to \(newTag)” in the context menu")
                    .accessibilityLabel("Update available: \(newTag)")
            }
        }
    }

    private func statusText(for source: BaselineSource) -> Text {
        if let error = store.scanErrors[source.id] {
            return Text(error)
        }
        var parts: [String] = []
        if source.isGitHub {
            if let tag = source.gitHub?.syncedTag {
                parts.append(tag)
            } else if let branch = source.gitHub?.defaultBranch {
                parts.append(branch)
            }
        }
        if let result = store.scanResults[source.id] {
            parts.append("\(result.items.count) item\(result.items.count == 1 ? "" : "s") · \(result.skipped.count) skipped")
        } else if parts.isEmpty {
            parts.append(source.isGitHub ? "Not synced yet" : "Not scanned yet")
        }
        return Text(parts.joined(separator: " · "))
    }
}
