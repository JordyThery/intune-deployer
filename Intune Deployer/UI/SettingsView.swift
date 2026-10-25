import JTKit
import SwiftUI

/// The app's own parts of JTKit's Settings window: General (below JTKit's
/// Appearance), then the Connections and GitHub tabs. JTKit adds Updates last.
@MainActor
enum SettingsContent {
    /// General tab, below Appearance.
    static var general: some View {
        ItemEditingSection()
    }

    /// The app's tabs, between General and Updates.
    @ViewBuilder static var tabs: some View {
        SettingsTab("Connections", systemImage: "network") {
            AppRegistrationSection()
        }
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
            the registration's Application (client) ID and the tenant ID in the tenant \
            profile here in the app. See the README for step-by-step instructions.
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
        SettingsContent.tabs
    }
    .environment(UpdateChecker(configuration: UpdateConfiguration(
        owner: "JordyThery",
        repository: "intune-deployer",
        appName: "Intune Deployer"
    )))
}
#endif
