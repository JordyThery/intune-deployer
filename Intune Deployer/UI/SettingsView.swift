import JTKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's own parts of JTKit's Settings window: General (below JTKit's
/// Appearance), then the Connections and GitHub tabs. JTKit adds Updates last.
@MainActor
enum SettingsContent {
    /// General tab, below Appearance.
    static var general: some View {
        ItemEditingSection()
    }

    /// The app's tabs, between General and Updates.
    @ViewBuilder static func tabs(tenants: TenantStore, auth: AuthManager) -> some View {
        TenantConnectionsTab(tenants: tenants, auth: auth)
        SettingsTab("GitHub", systemImage: "key") {
            GitHubAccessSection()
        }
    }
}

struct ItemEditingSection: View {
    // Same key ItemDetailView reads; unset means disabled.
    @AppStorage("enableItemEditing") private var enableItemEditing = false

    var body: some View {
        Section {
            Toggle("Enable item editing", isOn: $enableItemEditing)
        } header: {
            Text("Item Editing")
        } footer: {
            Text("""
            Shows an Edit button on items so their content can be changed inside the \
            app. Edits never modify the source files — they are deployed instead of \
            the file until reverted, and are marked in the item list and every plan. \
            Turning this off hides the button; existing edits stay applied.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Settings › Connections: JTKit's shared list and editor for the tenant
/// profiles' name, tenant ID and client ID, with import and export. The
/// baseline settings stay in the main window. "Use This Connection" sets the
/// tenant in use, as the toolbar picker does.
struct TenantConnectionsTab: View {
    let tenants: TenantStore
    let auth: AuthManager

    var body: some View {
        ConnectionsSettingsTab(
            store: tenants.connections,
            services: [.intune],
            allowsChangingService: false,
            signInMethods: [.intune: [.microsoftInteractive]],
            roles: [.active(selection: Binding(get: { tenants.selectedProfileID },
                                               set: { tenants.selectedProfileID = $0 }))],
            height: 600,
            footer: """
            Tenant ID: Entra admin center → Overview. Client ID: the Application (client) ID of \
            the app registration an admin creates in that tenant. Naming prefix, default \
            assignments and variables are set in the main window: select the tenant in the \
            sidebar, then Baseline Settings….
            """,
            newRecord: { _ in TenantProfile(displayName: "New tenant") },
            importer: tenants.makeImport(),
            deleteMessage: "Its item selection, variables and assignments are removed, and the tenant's account is signed out. Objects in the tenant are not affected.",
            didDelete: { profile in
                tenants.didDelete(profile)
                Task { await auth.signOut(profile: profile) }
            }
        ) { $profile in
            AppRegistrationSection()
            TenantExportSection(saved: tenants.connections.record(id: profile.id))
        }
    }
}

/// Saves a tenant profile as a file to import on another Mac.
private struct TenantExportSection: View {
    let saved: TenantProfile?
    @State private var exportDocument: TextExportDocument?

    var body: some View {
        Section {
            Button("Export Tenant Profile…") {
                exportDocument = (try? saved?.exportText()).map { TextExportDocument(text: $0) }
            }
            .disabled(saved == nil)
            .fileExporter(
                isPresented: Binding(
                    get: { exportDocument != nil },
                    set: { if !$0 { exportDocument = nil } }
                ),
                document: exportDocument,
                contentType: .json,
                defaultFilename: "\(saved?.displayName ?? "Tenant").intune-deployer-profile.json"
            ) { _ in
                exportDocument = nil
            }
        } footer: {
            Text("The saved profile with its baseline (items, assignments, variables), to import on another Mac with + › Import Tenant Profile…. Sign-in is not included.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Registration reference: every tenant gets its own app registration, and
/// all of them use these identical values.
struct AppRegistrationSection: View {
    var body: some View {
        Section {
            LabeledContent("Bundle ID") {
                Text(AppRegistrationInfo.bundleID)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("Redirect URI") {
                Text(AppRegistrationInfo.redirectURI)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text("App Registration Values")
        } footer: {
            Text("""
            For each tenant you deploy to, an admin creates an app registration in that \
            Entra tenant: single-tenant, public client, no secret. Add the “iOS/macOS” \
            platform with the bundle ID above so the redirect URI is accepted, then enter \
            the registration's Application (client) ID and the tenant ID above. See the \
            README for step-by-step instructions.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct GitHubAccessSection: View {
    @State private var gitHubToken = ""
    @State private var tokenStatus: String?

    var body: some View {
        Section {
            SecureField("Personal access token", text: $gitHubToken, prompt: Text("github_pat_… (optional)"))
                .font(.body.monospaced())
            HStack {
                Button("Save Token") {
                    GitHubTokenStore.save(gitHubToken)
                    tokenStatus = gitHubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Token removed" : "Token saved to the Keychain"
                }
                Button("Remove Token") {
                    GitHubTokenStore.delete()
                    gitHubToken = ""
                    tokenStatus = "Token removed"
                }
                if let tokenStatus {
                    Text(tokenStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("GitHub Access")
        } footer: {
            Text("""
            Only needed for private repositories (it also raises the API rate limit). \
            Create a fine-grained personal access token with read-only Contents \
            permission for the repositories you use. Stored in the Keychain, never in \
            files.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear {
            gitHubToken = GitHubTokenStore.load() ?? ""
        }
    }
}

#if DEBUG
#Preview {
    SettingsTabs {
        SettingsContent.general
    } tabs: {
        SettingsContent.tabs(tenants: TenantStore(storageURL: FileManager.default.temporaryDirectory
                                 .appending(path: "intune-deployer-preview/tenants.json")),
                             auth: AuthManager())
    }
    .environment(UpdateChecker(configuration: UpdateConfiguration(
        owner: "JordyThery",
        repository: "intune-deployer",
        appName: "Intune Deployer"
    )))
}
#endif
