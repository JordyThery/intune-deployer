import Foundation

/// Where a GitHub baseline source comes from. The user supplies any
/// owner/repo — the app never preconfigures or suggests repositories.
nonisolated struct GitHubSpec: Codable, Sendable, Hashable {
    var owner: String
    var repo: String
    /// Optional folder within the repository to scan (e.g. "macOS").
    var subfolder: String?
    /// Optional release tag prefix filter (e.g. "macos-v"), for repos that
    /// tag releases per platform.
    var tagPrefix: String?

    var displayName: String {
        if let subfolder, !subfolder.isEmpty {
            return "\(owner)/\(repo) · \(subfolder)"
        }
        return "\(owner)/\(repo)"
    }

    var repoURL: URL? {
        URL(string: "https://github.com/\(owner)/\(repo)")
    }

    /// Accepts "owner/repo", "github.com/owner/repo", or a full URL
    /// (with optional .git suffix).
    static func parseRepoInput(_ input: String) -> (owner: String, repo: String)? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "github.com/", "www.github.com/"] {
            if text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
            }
        }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}

/// What was last synced from GitHub for a source (persisted).
nonisolated struct GitHubSyncState: Codable, Sendable, Hashable {
    /// Release tag the cache was built from; nil = default-branch snapshot.
    var syncedTag: String?
    var defaultBranch: String?
    var licenseName: String?
    var licenseSPDX: String?
    var lastSynced: Date?
}

/// A baseline source: a folder of plain files that items are inferred from —
/// either a local folder (security-scoped bookmark) or any GitHub repository.
nonisolated struct BaselineSource: Identifiable, Codable, Sendable, Hashable {
    enum Kind: Codable, Sendable, Hashable {
        case localFolder(bookmark: Data)
        case gitHub(GitHubSpec)
    }

    let id: UUID
    var name: String
    var kind: Kind
    /// Last resolved content path or repository URL; persisted for
    /// diagnostics (not currently shown in the UI).
    var lastKnownPath: String
    /// Sync details for GitHub sources.
    var gitHub: GitHubSyncState?

    init(id: UUID = UUID(), name: String, kind: Kind, lastKnownPath: String, gitHub: GitHubSyncState? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.lastKnownPath = lastKnownPath
        self.gitHub = gitHub
    }

    var gitHubSpec: GitHubSpec? {
        if case .gitHub(let spec) = kind { spec } else { nil }
    }

    var isGitHub: Bool { gitHubSpec != nil }
}
