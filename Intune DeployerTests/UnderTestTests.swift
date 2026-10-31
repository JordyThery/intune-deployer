import CryptoKit
import Foundation
import JTKit
import JTKitMSAL
import Testing
@testable import Intune_Deployer

/// Under tests the app reaches no saved tenant and no GitHub repository,
/// writes none of its real files and leaves no settings file behind (JTKit
/// ROADMAP step 11, decided by Jordy; bugs 8 and 9 of its survey). Every
/// guard here writes to a guard file of its own, never the shared one the
/// release check reads.
@MainActor
@Suite("Under tests", .serialized)
struct UnderTestTests {
    /// Counts every attempt to set up MSAL; fails it, so nothing can reach MSAL.
    final class MSALTrap {
        var calls = 0
        func make(_ clientID: String) throws -> MicrosoftSignIn {
            calls += 1
            throw MicrosoftSignInError.noWindow
        }
    }

    private func privateGuard() -> TestRun.AttemptLog {
        TestRun.AttemptLog(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "IntuneDeployerTests-guard-\(UUID().uuidString).jsonl"))
    }

    private func realProfile(tenantID: String = UUID().uuidString) -> TenantProfile {
        TenantProfile(displayName: "Lab", clientID: UUID().uuidString, tenantID: tenantID,
                      accountIdentifier: "uid.\(tenantID)")
    }

    // MARK: - The unit-test host

    @Test("The unit tests' host runs under tests, with its files in a temporary folder, never Application Support")
    func theHostIsSandboxed() {
        #expect(TestRun.isUnitTestHost)
        #expect(TestRun.isActive)
        #expect(AppDemo.isSandboxed)
        #expect(!AppDemo.mode.isOn, "a saved demoMode can't switch demo mode on in the host")
        #expect(UnderTest.dataFolder.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(UnderTest.dataFolder.standardizedFileURL != UnderTest.realDataFolder.standardizedFileURL)
        #expect(AppDemo.sandboxedDefaults() !== UserDefaults.standard)
    }

    /// The real files, as a hash per file (or "absent"), never their content.
    private func realFiles() -> [String: String] {
        var result: [String: String] = [:]
        for name in ["sources.json", "tenants.json", "item-edits.json", "platform-overrides.json"] {
            let url = UnderTest.realDataFolder.appending(path: name)
            guard let data = try? Data(contentsOf: url),
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { result[name] = "absent"; continue }
            result[name] = SHA256.hash(data: data).description + " \(date.timeIntervalSince1970)"
        }
        return result
    }

    @Test("Under ⌘U the real sources.json (and tenants.json, edits, platform choices) isn't written (bug 8)")
    func realFilesAreNotWritten() async throws {
        let before = realFiles()

        // What the hosted app does at launch: its stores, then a rescan.
        let log = ActivityLog()
        let launched = AppDemo.sourceStore(activityLog: log)
        #expect(!launched.fileLocation.path.hasPrefix(UnderTest.realDataFolder.path))
        await launched.rescanAll()
        let tenants = AppDemo.tenantStore()
        #expect(tenants.profiles.isEmpty, "the saved tenants aren't read")

        // A store made the default way, as a test or the app would: it saves
        // into the host's temporary folder.
        let root = try Fixtures.makeTree(files: ["Scripts/hello.sh": "#!/bin/zsh\necho hi\n"])
        let store = SourceStore(activityLog: log)
        #expect(store.fileLocation.deletingLastPathComponent().standardizedFileURL == UnderTest.dataFolder.standardizedFileURL)
        store.addLocalFolder(at: root)
        let sourceID = try #require(store.sources.first?.id)
        for _ in 0..<200 where store.items(for: [sourceID]).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try #require(store.items(for: [sourceID]).first)
        store.edits.save(ItemEdit(itemID: item.id, sourceID: sourceID, relativePath: item.relativePath,
                                  content: Data("#!/bin/zsh\necho edited\n".utf8), baseContentHash: "", modified: Date()))
        store.edits.revert(itemID: item.id)
        store.platformOverrides.set(.iOSiPadOS, for: item)
        #expect(FileManager.default.fileExists(atPath: store.fileLocation.path), "it did save, in the temporary folder")

        #expect(realFiles() == before)
    }

    @Test("Test settings stay out of Preferences (bug 9)")
    func settingsStayOutOfPreferences() throws {
        let preferences = TestSettings.preferencesFolder
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? [])

        let (domain, defaults) = TestSettings.makeDefaults("bug-9")
        defaults.set(true, forKey: "hasSeenGuidedTour")
        defaults.synchronize()
        let tour = IntuneDeployerTour.makeState(defaults: TestSettings.makeDefaults("tour").defaults)
        tour.startOnFirstLaunch()
        let hostDefaults = AppDemo.sandboxedDefaults()
        hostDefaults.set("x", forKey: "check")
        hostDefaults.synchronize()
        hostDefaults.removeObject(forKey: "check")

        #expect(domain.hasPrefix(TestSettings.folder.path))
        #expect(FileManager.default.fileExists(atPath: domain + ".plist"))
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? [])
        #expect(after.subtracting(before).isEmpty, "\(after.subtracting(before))")
    }

    @Test("A test process's settings folder is removed by the next run once that process has ended (bug 9)")
    func endedProcessFoldersAreRemoved() throws {
        _ = TestSettings.folder
        // A process number no process has: the highest macOS allows, plus one.
        let ended = TestSettings.root.appending(path: "99999", directoryHint: .isDirectory)
        try #require(kill(99999, 0) != 0)
        try FileManager.default.createDirectory(at: ended, withIntermediateDirectories: true)
        try Data().write(to: ended.appending(path: "left.plist"))
        TestSettings.removeEndedProcessFolders()
        #expect(!FileManager.default.fileExists(atPath: ended.path))
        #expect(FileManager.default.fileExists(atPath: TestSettings.folder.path), "this process's own folder stays")
    }

    // MARK: - Saved tenants

    @Test("By default, under tests, a saved tenant gets no sign-in, token or sign-out; each is written down")
    func savedTenantsAreRefused() async throws {
        if case .refuseAll = AuthManager().underTest {} else { Issue.record("the default isn't refuseAll under tests") }

        let trap = MSALTrap()
        let savedTenantGuard = privateGuard()
        let auth = AuthManager(makeSignIn: { try trap.make($0) }, underTest: .refuseAll(savedTenantGuard))
        let profile = realProfile()
        auth.restoreAccount(for: profile)
        #expect(!auth.isSignedIn(profile))
        await #expect(throws: UnderTest.refused) {
            _ = try await auth.accessToken(profile: profile, scopes: GraphScopes.tenantRead)
        }
        await #expect(throws: UnderTest.refused) {
            _ = try await auth.signIn(profile: profile)
        }
        // Not signed in (as every saved tenant under tests): a sign-out, e.g.
        // after deleting it in Settings, has nothing to reach and isn't an attempt.
        await auth.signOut(profile: profile)
        #expect(trap.calls == 0, "MSAL is never set up")
        #expect(savedTenantGuard.attempts().map(\.what) == [
            "restore the saved sign-in of a saved tenant", "token for a saved tenant", "interactive sign-in",
        ])
    }

    @Test("The live checks reach only their one tenant, never with Microsoft's window")
    func liveCheckReachesOnlyItsTenant() async throws {
        let trap = MSALTrap()
        let savedTenantGuard = privateGuard()
        let allowed = UUID().uuidString.lowercased()
        let auth = AuthManager(makeSignIn: { try trap.make($0) }, underTest: .liveCheck(tenantID: allowed, guard: savedTenantGuard))

        let other = realProfile()
        auth.restoreAccount(for: other)
        await #expect(throws: UnderTest.refused) {
            _ = try await auth.accessToken(profile: other, scopes: GraphScopes.tenantRead)
        }
        #expect(trap.calls == 0)
        #expect(savedTenantGuard.attempts().count == 2)

        // The allowed tenant (its ID in capitals counts too) reaches MSAL.
        let live = realProfile(tenantID: allowed.uppercased())
        auth.restoreAccount(for: live)
        #expect(trap.calls == 1)
        #expect(savedTenantGuard.attempts().count == 2)
        // … but never its window.
        await #expect(throws: UnderTest.refused) { _ = try await auth.signIn(profile: live) }
    }

    @Test("A refusing network sends nothing and writes down method, host and path, never the query")
    func refusingNetwork() async throws {
        let savedTenantGuard = privateGuard()
        let session = UnderTest.refusingSession(kind: "Graph", log: savedTenantGuard)
        let url = try #require(URL(string: "https://graph.microsoft.com/v1.0/groups?$filter=displayName%20eq%20'Secret'"))
        await #expect { _ = try await session.data(from: url) } throws: { error in
            (error as? URLError)?.code == .resourceUnavailable && error.localizedDescription == UnderTest.refusal
        }
        #expect(savedTenantGuard.attempts().map(\.what) == ["Graph: GET graph.microsoft.com/v1.0/groups"])

        // A Graph client of a real tenant under tests reaches the same kind of network.
        let auth = AuthManager(makeSignIn: { _ in throw MicrosoftSignInError.noWindow }, underTest: .refuseAll(savedTenantGuard))
        let tenantSession = TenantSession(auth: auth, activityLog: ActivityLog(),
                                          realTenantSession: UnderTest.refusingSession(kind: "Graph", log: savedTenantGuard))
        await #expect(throws: (any Error).self) {
            _ = try await tenantSession.client(for: realProfile()).getRaw("organization", version: .v1)
        }
        #expect(savedTenantGuard.attempts().count == 2, "the token was refused, nothing was sent")
    }

    @Test("A source store's GitHub requests under tests go to a refusing network by default")
    func gitHubIsRefusedByDefault() async throws {
        let savedTenantGuard = privateGuard()
        let folder = FileManager.default.temporaryDirectory.appending(path: "IntuneDeployerTests-github-\(UUID().uuidString)")
        let store = SourceStore(activityLog: ActivityLog(), folder: folder,
                                gitHubSession: UnderTest.refusingSession(kind: "GitHub", log: savedTenantGuard))
        store.addGitHubSource(GitHubSpec(owner: "example", repo: "baseline"))
        for _ in 0..<200 where savedTenantGuard.attempts().isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(savedTenantGuard.attempts().first?.what.hasPrefix("GitHub: GET api.github.com/") == true)
        try? FileManager.default.removeItem(at: folder)
    }
}
