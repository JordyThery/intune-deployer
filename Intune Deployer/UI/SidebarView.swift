import SwiftUI
import UniformTypeIdentifiers

/// What the sidebar can select: baseline sources (multi) or a tenant profile.
enum SidebarSelection: Hashable {
    case source(UUID)
    case tenant(UUID)
}

/// Sidebar: baseline sources with scan status, plus tenant profiles.
struct SidebarView: View {
    @Environment(SourceStore.self) private var store
    @Environment(TenantStore.self) private var tenantStore
    @Environment(AuthManager.self) private var auth
    @Binding var selection: Set<SidebarSelection>

    @State private var isPickingFolder = false
    @State private var isAddingGitHubSource = false
    @State private var isAddingProfile = false
    @State private var isImportingProfile = false
    @State private var editingProfile: TenantProfile?
    @State private var profilePendingDeletion: TenantProfile?
    @State private var importError: String?

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
            .tourAnchor(.sources)

            Section("Tenant Profiles") {
                ForEach(tenantStore.profiles) { profile in
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
                        Button("Edit…") { editingProfile = profile }
                        Button("Delete Tenant Profile…", role: .destructive) {
                            profilePendingDeletion = profile
                        }
                    }
                }
                Button {
                    isAddingProfile = true
                } label: {
                    Label("Add Tenant Profile…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Button {
                    isImportingProfile = true
                } label: {
                    Label("Import Tenant Profile…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
            }
            .tourAnchor(.tenantProfiles)
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
        .fileImporter(
            isPresented: $isImportingProfile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                importProfile(from: url)
            }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $isAddingProfile) {
            TenantProfileEditorView(profile: nil)
        }
        .sheet(item: $editingProfile) { profile in
            TenantProfileEditorView(profile: profile)
        }
        .confirmationDialog(
            "Delete the tenant profile “\(profilePendingDeletion?.displayName ?? "")”?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let profile = profilePendingDeletion else { return }
                selection.remove(.tenant(profile.id))
                tenantStore.remove(id: profile.id)
                Task { await auth.signOut(profile: profile) }
                profilePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { profilePendingDeletion = nil }
        } message: {
            Text("Its item selection, variables and assignments are removed, and the profile's account is signed out. Objects in the tenant are not affected.")
        }
    }

    private func importProfile(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            var profile = try JSONDecoder().decode(TenantProfile.self, from: data)
            profile.accountIdentifier = nil // sign in on this machine
            if tenantStore.profiles.contains(where: { $0.id == profile.id }) {
                profile.id = UUID()
                profile.displayName += " (imported)"
            }
            tenantStore.add(profile)
        } catch {
            importError = "Not a valid tenant profile: \(error.localizedDescription)"
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
