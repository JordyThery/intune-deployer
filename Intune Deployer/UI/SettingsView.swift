import SwiftUI

/// Registration reference: every tenant gets its own app registration, and
/// all of them use these identical values.
struct SettingsView: View {
    @State private var gitHubToken = ""
    @State private var tokenStatus: String?

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
        .onAppear {
            gitHubToken = GitHubTokenStore.load() ?? ""
        }
    }
}
