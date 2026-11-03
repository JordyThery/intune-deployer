import Foundation
import JTKit
import JTKitTestSupport
import os
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

@Suite("GitHub sync, end to end")
struct GitHubSyncTests {
    /// A zip shaped like GitHub's zipball: one "owner-repo-sha" folder.
    private static func zipball(files: [String: String]) throws -> Data {
        let work = FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-zipball-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appending(path: "example-baseline-abc1234")
        for (path, contents) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let zip = work.appending(path: "zipball.zip")
        _ = try AppPackageInspector.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.path, zip.path])
        return try Data(contentsOf: zip)
    }

    @MainActor
    @Test("A GitHub source syncs its latest release, is scanned, and a newer release shows as an update")
    func syncAndUpdate() async throws {
        let zip = try Self.zipball(files: ["scripts/hello.sh": Fixtures.plainScript])
        let v1 = #"{"tag_name":"v1.0","draft":false,"prerelease":false,"published_at":"2026-10-01T00:00:00Z"}"#
        let releases = OSAllocatedUnfairLock(initialState: [v1])
        let server = MockServer { request in
            let path = request.path
            if path.hasSuffix("/repos/example/baseline") {
                return .json(200, #"{"default_branch":"main","html_url":"https://github.com/example/baseline","license":{"name":"MIT License","spdx_id":"MIT"}}"#)
            }
            if path.hasSuffix("/releases") {
                return .json(200, "[" + releases.withLock { $0 }.joined(separator: ",") + "]")
            }
            if path.hasSuffix("/zipball/v1.0") { return MockResponse(status: 200, headers: ["Content-Type": "application/zip"], body: zip) }
            return .json(404, #"{"message":"Not Found"}"#)
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SourceStore(activityLog: ActivityLog(), folder: folder, gitHubSession: server.session, gitHubToken: { nil })
        store.addGitHubSource(GitHubSpec(owner: "example", repo: "baseline"))
        let id = try #require(store.sources.first?.id)
        for _ in 0..<250 where store.items(for: [id]).isEmpty && store.scanErrors[id] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.scanErrors[id] == nil, "\(store.scanErrors[id] ?? "")")
        #expect(store.items(for: [id]).map(\.relativePath) == ["scripts/hello.sh"])
        #expect(store.sources.first?.gitHub?.syncedTag == "v1.0")
        #expect(store.sources.first?.gitHub?.licenseSPDX == "MIT")

        await store.checkGitHubUpdates()
        #expect(store.availableUpdates[id] == nil, "nothing newer yet")
        releases.withLock { $0.append(#"{"tag_name":"v1.1","draft":false,"prerelease":false,"published_at":"2026-10-20T00:00:00Z"}"#) }
        await store.checkGitHubUpdates()
        #expect(store.availableUpdates[id] == "v1.1")
    }
}
