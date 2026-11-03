import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Intune_Deployer

@Suite("GitHub sources")
struct GitHubSourceTests {
    // MARK: - Repo input parsing

    @Test func parsesOwnerRepoFromVariousInputs() {
        let expectations: [(String, (String, String)?)] = [
            ("microsoft/intune-my-macs", ("microsoft", "intune-my-macs")),
            ("https://github.com/SkipToTheEndpoint/OpenIntuneBaseline", ("SkipToTheEndpoint", "OpenIntuneBaseline")),
            ("http://github.com/a/b.git", ("a", "b")),
            ("github.com/a/b/tree/main/macOS", ("a", "b")),
            ("  owner/repo  ", ("owner", "repo")),
            ("justoneword", nil),
            ("", nil),
        ]
        for (input, expected) in expectations {
            let parsed = GitHubSpec.parseRepoInput(input)
            #expect(parsed?.owner == expected?.0, "input: \(input)")
            #expect(parsed?.repo == expected?.1, "input: \(input)")
        }
    }

    // MARK: - Release picking

    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, daysAgo: Int) -> GitHubClient.Release {
        GitHubClient.Release(
            tagName: tag,
            draft: draft,
            prerelease: prerelease,
            publishedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)
        )
    }

    @Test func picksLatestPublishedReleaseMatchingPrefix() {
        let releases = [
            release("windows-v4.0", daysAgo: 1),
            release("macos-v2.0", daysAgo: 10),
            release("macos-v2.1", prerelease: true, daysAgo: 2),
            release("macos-v1.9", daysAgo: 60),
            release("macos-v3.0", draft: true, daysAgo: 0),
        ]
        // Prefix filter: newest published macos-v*, skipping drafts/prereleases.
        #expect(GitHubClient.pickRelease(from: releases, tagPrefix: "macos-v")?.tagName == "macos-v2.0")
        // Case-insensitive prefix.
        #expect(GitHubClient.pickRelease(from: releases, tagPrefix: "MACOS-")?.tagName == "macos-v2.0")
        // No prefix: newest published overall.
        #expect(GitHubClient.pickRelease(from: releases, tagPrefix: nil)?.tagName == "windows-v4.0")
        // No match → nil (sync falls back to the default branch).
        #expect(GitHubClient.pickRelease(from: releases, tagPrefix: "linux-") == nil)
        #expect(GitHubClient.pickRelease(from: [], tagPrefix: nil) == nil)
    }

    // MARK: - Zipball content root

    @Test func findsSingleTopLevelFolderInExtractedZipball() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = dir.appending(path: "owner-repo-abc123/macOS")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        let root = try GitHubClient.contentRoot(in: dir)
        #expect(root.lastPathComponent == "owner-repo-abc123")

        // Two top-level folders → unexpected layout → throws.
        try FileManager.default.createDirectory(at: dir.appending(path: "second"), withIntermediateDirectories: true)
        #expect(throws: GitHubError.self) {
            _ = try GitHubClient.contentRoot(in: dir)
        }
    }

    // MARK: - Token storage

    /// On a fake store: the real Keychain item is the user's own token, which
    /// a test must never overwrite or delete.
    @Test func tokenIsTrimmedAndEmptyDeletes() throws {
        let store = InMemorySecretStore()
        GitHubTokenStore.save("  github_pat_test_123\n", to: store)
        #expect(try GitHubTokenStore.load(from: store) == "github_pat_test_123")
        #expect(try store.readSecret(for: "personal-access-token") == "github_pat_test_123")
        // Saving empty removes the token.
        GitHubTokenStore.save("   ", to: store)
        #expect(try GitHubTokenStore.load(from: store) == nil)
        #expect(try store.readSecret(for: "personal-access-token") == nil)
    }

    @MainActor
    @Test("A Keychain that can't be read is reported as such, not as no token")
    func unreadableKeychainIsReported() async throws {
        let store = InMemorySecretStore()
        GitHubTokenStore.save("github_pat_test_123", to: store)
        store.refusesReads = true
        #expect(throws: SecretStoreError.self) { try GitHubTokenStore.load(from: store) }

        let folder = FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-keychain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = SourceStore(folder: folder, gitHubSession: UnderTest.refusingSession(kind: "GitHub", log: TestRun.AttemptLog(fileURL: folder.appending(path: "attempts.jsonl"))),
                                  gitHubToken: { try GitHubTokenStore.load(from: store) })
        sources.addGitHubSource(GitHubSpec(owner: "example", repo: "baseline"))
        let id = try #require(sources.sources.first?.id)
        for _ in 0..<200 where sources.scanErrors[id] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sources.scanErrors[id]?.contains("Keychain couldn’t be read") == true)
    }

    @Test func tokenKeepsItsKeychainNames() {
        #expect(GitHubTokenStore.keychain.service == "be.jordythery.intune-deployer.github")
        #expect(GitHubTokenStore.keychain.accessibility == .whenUnlocked)
        #expect(GitHubTokenStore.account == "personal-access-token")
    }

    // MARK: - Persistence migration

    @Test func legacyLocalFolderSourceStillDecodes() throws {
        // sources.json written by earlier builds (no gitHub key).
        let legacy = Data(#"""
        [{"id": "11111111-2222-3333-4444-555555555555",
          "name": "Baselines",
          "kind": {"localFolder": {"bookmark": "AAEC"}},
          "lastKnownPath": "/Users/x/Baselines"}]
        """#.utf8)
        let sources = try JSONDecoder().decode([BaselineSource].self, from: legacy)
        #expect(sources.count == 1)
        #expect(!sources[0].isGitHub)
        #expect(sources[0].gitHub == nil)
    }

    @Test func gitHubSourceRoundTripsThroughJSON() throws {
        let source = BaselineSource(
            name: "owner/repo · macOS",
            kind: .gitHub(GitHubSpec(owner: "owner", repo: "repo", subfolder: "macOS", tagPrefix: "macos-v")),
            lastKnownPath: "https://github.com/owner/repo",
            gitHub: GitHubSyncState(
                syncedTag: "macos-v2.0",
                defaultBranch: "main",
                licenseName: "MIT License",
                licenseSPDX: "MIT",
                lastSynced: .now
            )
        )
        let data = try JSONEncoder().encode([source])
        let decoded = try JSONDecoder().decode([BaselineSource].self, from: data)
        #expect(decoded.first?.gitHubSpec?.tagPrefix == "macos-v")
        #expect(decoded.first?.gitHub?.licenseSPDX == "MIT")
    }
}
