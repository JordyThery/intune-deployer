import SwiftUI

/// Sheet for adding any GitHub repository as a baseline source. The app never
/// suggests or preconfigures repositories.
struct GitHubSourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SourceStore.self) private var store

    @State private var repoInput = ""
    @State private var subfolder = ""
    @State private var tagPrefix = ""

    private var parsed: (owner: String, repo: String)? {
        GitHubSpec.parseRepoInput(repoInput)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Repository", text: $repoInput, prompt: Text("owner/repo or GitHub URL"))
                        .font(.body.monospaced())
                    TextField("Subfolder", text: $subfolder, prompt: Text("optional, e.g. macOS"))
                    TextField("Release tag prefix", text: $tagPrefix, prompt: Text("optional, e.g. macos-v"))
                        .font(.body.monospaced())
                } header: {
                    Text("GitHub Repository")
                } footer: {
                    Text("""
                    The latest published release matching the tag prefix is downloaded \
                    (or the default branch when the repository has no releases) and cached \
                    locally. The repository's license is shown with its items — review any \
                    third-party baseline before deploying it.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    guard let (owner, repo) = parsed else { return }
                    store.addGitHubSource(GitHubSpec(
                        owner: owner,
                        repo: repo,
                        subfolder: subfolder.trimmingCharacters(in: .whitespaces).isEmpty ? nil : subfolder.trimmingCharacters(in: .whitespaces),
                        tagPrefix: tagPrefix.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tagPrefix.trimmingCharacters(in: .whitespaces)
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed == nil)
            }
            .padding()
        }
        .frame(width: 480, height: 300)
    }
}
