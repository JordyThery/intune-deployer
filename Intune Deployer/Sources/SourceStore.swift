import Foundation
import JTKit
import Observation
import OSLog

/// Manages baseline sources: persistence, security-scoped access (local
/// folders), GitHub sync/caching, and scanning.
@MainActor
@Observable
final class SourceStore {
    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "SourceStore")

    private(set) var sources: [BaselineSource] = []
    private(set) var scanResults: [UUID: ScanResult] = [:]
    /// Per-source scan/sync failure message (bookmark broken, download failed, …).
    private(set) var scanErrors: [UUID: String] = [:]
    private(set) var scanningSourceIDs: Set<UUID> = []
    /// Newer release tag per GitHub source, when one is available.
    private(set) var availableUpdates: [UUID: String] = [:]

    /// In-app content overrides; items read through `fileContents(of:)` and
    /// the scan overlay see edited content instead of the file.
    let edits: ItemEditStore
    /// Per-item platform choices for `.mobileconfig` profiles.
    let platformOverrides: PlatformOverrideStore

    private let file: SavedList<BaselineSource>
    /// Every identity each source key had (`source-identities.json`).
    private let identityFile: SavedList<SourceIdentity>
    private(set) var identities: [SourceIdentity] = []
    /// Where the sources are saved (`sources.json`).
    var fileLocation: URL { file.fileURL }
    private let cacheRoot: URL
    /// The GitHub token: the app's store (under tests one that starts empty).
    private let gitHubToken: @MainActor () throws -> String?
    /// GitHub requests go through JTKit's request recorder into the activity log.
    private let gitHub: RequestRecorder
    /// Monotonic per-source scan counter: only the latest-started scan may
    /// publish results, so an older scan finishing late cannot overwrite a
    /// newer one (e.g. the rescan after saving an item edit).
    private var scanGenerations: [UUID: Int] = [:]

    /// - Parameters:
    ///   - folder: where sources, the GitHub cache, edits and platform
    ///     choices are kept; Application Support/Intune Deployer by default
    ///     (a sandbox run uses demo mode's temporary folder).
    ///   - gitHubSession: sends the GitHub requests (a sandbox run's reaches
    ///     nothing); by default the real network, under tests a session that
    ///     refuses and records every request (`UnderTest.attempts`).
    ///   - gitHubToken: the GitHub token; by default `GitHubTokenStore`'s.
    init(storageURL: URL? = nil, editStore: ItemEditStore? = nil, platformStore: PlatformOverrideStore? = nil,
         activityLog: ActivityLog? = nil, folder: URL? = nil, gitHubSession: URLSession? = nil,
         gitHubToken: (@MainActor () throws -> String?)? = nil) {
        let gitHubSession = gitHubSession
            ?? (UnderTest.isActive ? UnderTest.refusingSession(kind: "GitHub") : .shared)
        // Application Support/Intune Deployer; under the unit tests a temporary folder.
        let base = folder ?? UnderTest.dataFolder
        let storageURL = storageURL ?? base.appendingPathComponent("sources.json")
        self.file = SavedList(fileURL: storageURL, name: "sources")
        self.identityFile = SavedList(fileURL: storageURL.deletingLastPathComponent().appendingPathComponent("source-identities.json"),
                                      name: "source identities")
        self.gitHubToken = gitHubToken ?? { try GitHubTokenStore.load() }
        self.cacheRoot = base.appendingPathComponent("GitHubSources", isDirectory: true)
        self.edits = editStore ?? ItemEditStore(storageURL: folder?.appendingPathComponent("item-edits.json"))
        self.platformOverrides = platformStore
            ?? PlatformOverrideStore(storageURL: folder?.appendingPathComponent("platform-overrides.json"))
        self.gitHub = RequestRecorder(session: gitHubSession, log: activityLog, category: "GitHub", service: "GitHub")
        load()
    }

    /// Why some of the app's saved data isn't saved: a file that couldn't be
    /// read (kept aside, never saved over). Empty when all is well.
    var problems: [String] {
        [file.problem, identityFile.problem, edits.problem, platformOverrides.problem].compactMap(\.self)
    }

    /// Sources whose items aren't all known: not scanned yet, scanning, or
    /// the last scan or sync failed. Plan doesn't run while a chosen item
    /// may be in one of them.
    var unscannedSourceNames: [String] {
        sources.filter { scanResults[$0.id] == nil || scanErrors[$0.id] != nil || scanningSourceIDs.contains($0.id) }
            .map(\.name)
    }

    // MARK: - Source identity

    /// The ID for a new source with this key: the identity the key had
    /// before (a source removed and added again, or named by an imported
    /// tenant profile) unless a current source uses it, else a new one.
    private func newSourceID(forKey key: String) -> UUID {
        let inUse = Set(sources.map(\.id))
        if let earlier = identities.first(where: { $0.key == key && !inUse.contains($0.sourceID) }) {
            return earlier.sourceID
        }
        let id = UUID()
        remember(SourceIdentity(key: key, sourceID: id))
        return id
    }

    private func remember(_ identity: SourceIdentity) {
        guard !identities.contains(identity) else { return }
        identities.append(identity)
        identityFile.save(identities)
    }

    /// The identities of the current sources, for a tenant profile export.
    var currentIdentities: [SourceIdentity] {
        sources.map { SourceIdentity(key: $0.identityKey, sourceID: $0.id) }
    }

    /// Item IDs an item had under its source's earlier identities (one no
    /// current source uses), so Plan still matches the objects deployed
    /// under them.
    func earlierIDs(of item: InferredItem) -> Set<String> {
        guard let source = sources.first(where: { $0.id == item.sourceID }) else { return [] }
        let inUse = Set(sources.map(\.id))
        return Set(identities.filter { $0.key == source.identityKey && !inUse.contains($0.sourceID) }
            .map { ItemIdentity.shortID(sourceID: $0.sourceID, relativePath: item.relativePath) })
    }

    /// An imported tenant profile with the identities of its sources: they
    /// are remembered, so the sources keep their item IDs when added on this
    /// Mac. A source already here under another identity keeps it; the
    /// profile's chosen items and assignments are moved to its item IDs,
    /// and Plan matches the objects deployed under the profile's.
    func adopt(_ profile: TenantProfile, identities imported: [SourceIdentity]) -> TenantProfile {
        imported.forEach(remember)
        var profile = profile
        for identity in imported {
            for source in sources where source.identityKey == identity.key && source.id != identity.sourceID {
                for item in scanResults[source.id]?.items ?? [] {
                    let earlier = ItemIdentity.shortID(sourceID: identity.sourceID, relativePath: item.relativePath)
                    if profile.selectedItemIDs.remove(earlier) != nil { profile.selectedItemIDs.insert(item.id) }
                    if let intent = profile.assignments.removeValue(forKey: earlier) { profile.assignments[item.id] = intent }
                }
            }
        }
        return profile
    }

    // MARK: - Managing sources

    /// Adds a local folder source from a user-picked URL (e.g. fileImporter).
    func addLocalFolder(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let name = url.lastPathComponent
            let kind = BaselineSource.Kind.localFolder(bookmark: bookmark)
            let source = BaselineSource(
                id: newSourceID(forKey: BaselineSource.identityKey(name: name, kind: kind)),
                name: name,
                kind: kind,
                lastKnownPath: url.path
            )
            sources.append(source)
            save()
            Task { await scan(sourceID: source.id) }
        } catch {
            Self.logger.error("Failed to create bookmark: \(error.localizedDescription)")
        }
    }

    /// Adds a GitHub repository source and starts its first sync.
    func addGitHubSource(_ spec: GitHubSpec) {
        let kind = BaselineSource.Kind.gitHub(spec)
        let source = BaselineSource(
            id: newSourceID(forKey: BaselineSource.identityKey(name: spec.displayName, kind: kind)),
            name: spec.displayName,
            kind: kind,
            lastKnownPath: spec.repoURL?.absoluteString ?? ""
        )
        sources.append(source)
        save()
        Task { await syncGitHub(sourceID: source.id) }
    }

    func removeSource(id: UUID) {
        sources.removeAll { $0.id == id }
        scanResults[id] = nil
        scanErrors[id] = nil
        availableUpdates[id] = nil
        edits.removeAll(forSource: id)
        platformOverrides.removeAll(forSource: id)
        try? FileManager.default.removeItem(at: cacheDirectory(for: id))
        save()
    }

    // MARK: - Scanning

    func rescanAll() async {
        for source in sources {
            if source.isGitHub, !cacheExists(for: source.id) {
                await syncGitHub(sourceID: source.id)
            } else {
                await scan(sourceID: source.id)
            }
        }
        await checkGitHubUpdates()
    }

    func scan(sourceID: UUID) async {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        switch source.kind {
        case .localFolder:
            await scanLocalFolder(source)
        case .gitHub:
            await scanGitHubCache(source)
        }
    }

    // MARK: - Local folders

    private func scanLocalFolder(_ source: BaselineSource) async {
        guard case .localFolder(let bookmark) = source.kind,
              let index = sources.firstIndex(where: { $0.id == source.id }) else { return }

        scanningSourceIDs.insert(source.id)
        scanErrors[source.id] = nil
        defer { scanningSourceIDs.remove(source.id) }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // Refresh the bookmark so future launches keep working.
                if let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    sources[index].kind = .localFolder(bookmark: fresh)
                }
            }
            sources[index].lastKnownPath = url.path
            save()

            guard url.startAccessingSecurityScopedResource() else {
                scanErrors[source.id] = "macOS denied access to the folder. Remove the source and add it again."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            try await runScan(root: url, source: source)
        } catch {
            scanErrors[source.id] = "Scan failed: \(error.localizedDescription)"
            Self.logger.error("Scan failed for \(source.name, privacy: .public): \(error.localizedDescription)")
        }
    }

    // MARK: - GitHub sources

    /// Downloads (or refreshes) the repo content, then scans it.
    func syncGitHub(sourceID: UUID) async {
        guard let source = sources.first(where: { $0.id == sourceID }),
              let spec = source.gitHubSpec,
              // A sync is already running for this source (e.g. Sync Now
              // chosen twice) — two extractions into one cache would collide.
              !scanningSourceIDs.contains(sourceID) else { return }

        scanningSourceIDs.insert(sourceID)
        scanErrors[sourceID] = nil
        defer { scanningSourceIDs.remove(sourceID) }

        // A Keychain that can't be read doesn't stop the sync: a public
        // repository needs no token. Its problem is shown only when GitHub
        // then refuses (a private repository, or the rate limit).
        let token: String?
        var tokenProblem: String?
        do {
            token = try gitHubToken()
        } catch {
            token = nil
            tokenProblem = error.localizedDescription
        }
        do {
            let info = try await GitHubClient.fetchRepoInfo(owner: spec.owner, repo: spec.repo, token: token, recorder: gitHub)
            let releases = try await GitHubClient.fetchReleases(owner: spec.owner, repo: spec.repo, token: token, recorder: gitHub)
            let release = GitHubClient.pickRelease(from: releases, tagPrefix: spec.tagPrefix)
            let ref = release?.tagName ?? info.defaultBranch

            _ = try await GitHubClient.downloadAndExtract(
                owner: spec.owner,
                repo: spec.repo,
                ref: ref,
                into: contentDirectory(for: sourceID),
                token: token,
                recorder: gitHub
            )

            // The source may have been removed or edited during the download.
            guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
            sources[index].gitHub = GitHubSyncState(
                syncedTag: release?.tagName,
                defaultBranch: info.defaultBranch,
                licenseName: info.license?.name,
                licenseSPDX: info.license?.spdxId,
                lastSynced: .now
            )
            sources[index].lastKnownPath = info.htmlUrl ?? source.lastKnownPath
            availableUpdates[sourceID] = nil
            save()

            await scanGitHubCache(sources[index])
        } catch {
            var message = "Sync failed: \(error.localizedDescription)"
            if let tokenProblem, GitHubError.isRefusal(error) {
                message += " The saved GitHub token wasn’t used: \(tokenProblem)"
            }
            scanErrors[sourceID] = message
            Self.logger.error("GitHub sync failed for \(source.name, privacy: .public): \(error.localizedDescription)")
        }
    }

    private func scanGitHubCache(_ source: BaselineSource) async {
        scanningSourceIDs.insert(source.id)
        defer { scanningSourceIDs.remove(source.id) }
        guard cacheExists(for: source.id) else {
            scanErrors[source.id] = "Not synced yet. Choose Sync Now from the source’s context menu."
            return
        }
        do {
            let root = try gitHubScanRoot(for: source)
            try await runScan(root: root, source: source)
            scanErrors[source.id] = nil
        } catch {
            scanErrors[source.id] = "Scan failed: \(error.localizedDescription)"
        }
    }

    /// Checks all GitHub sources for a newer matching release tag.
    func checkGitHubUpdates() async {
        let gitHubSources = sources.filter(\.isGitHub).map(\.id)
        guard !gitHubSources.isEmpty else { return }
        // A Keychain that can't be read skips the check; Sync Now says why.
        let token: String?
        do {
            token = try gitHubToken()
        } catch {
            Self.logger.error("GitHub update check skipped: \(error.localizedDescription)")
            return
        }
        for sourceID in gitHubSources {
            guard let spec = sources.first(where: { $0.id == sourceID })?.gitHubSpec,
                  let releases = try? await GitHubClient.fetchReleases(owner: spec.owner, repo: spec.repo, token: token,
                                                                       recorder: gitHub),
                  let source = sources.first(where: { $0.id == sourceID }) else { continue }
            let latest = GitHubClient.pickRelease(from: releases, tagPrefix: spec.tagPrefix)
            if let latest, latest.tagName != source.gitHub?.syncedTag {
                availableUpdates[sourceID] = latest.tagName
            } else {
                availableUpdates[sourceID] = nil
            }
        }
    }

    private func cacheDirectory(for sourceID: UUID) -> URL {
        cacheRoot.appending(path: sourceID.uuidString, directoryHint: .isDirectory)
    }

    private func contentDirectory(for sourceID: UUID) -> URL {
        cacheDirectory(for: sourceID).appending(path: "content", directoryHint: .isDirectory)
    }

    private func cacheExists(for sourceID: UUID) -> Bool {
        (try? GitHubClient.contentRoot(in: contentDirectory(for: sourceID))) != nil
    }

    private func gitHubScanRoot(for source: BaselineSource) throws -> URL {
        var root = try GitHubClient.contentRoot(in: contentDirectory(for: source.id))
        if let subfolder = source.gitHubSpec?.subfolder, !subfolder.isEmpty {
            guard !subfolder.split(separator: "/").contains("..") else {
                throw GitHubError.notFound("The subfolder must stay inside the repository.")
            }
            root = root.appending(path: subfolder)
            guard FileManager.default.fileExists(atPath: root.path) else {
                throw GitHubError.notFound("Subfolder “\(subfolder)” doesn’t exist in the synced repository.")
            }
        }
        return root
    }

    // MARK: - Shared scan path

    private func runScan(root: URL, source: BaselineSource) async throws {
        let sourceID = source.id
        let generation = (scanGenerations[sourceID] ?? 0) + 1
        scanGenerations[sourceID] = generation
        let overrides = edits.overrides(forSource: sourceID)
        let platforms = platformOverrides.overrides(forSource: sourceID)
        let (result, originals, considered) = try await Task.detached(priority: .userInitiated) {
            let result = try InferenceEngine.scan(root: root, sourceID: sourceID, overrides: overrides, platformOverrides: platforms)
            // Current on-disk content of every edited file, for reconciliation.
            // A file that exists but momentarily fails to read is taken out of
            // consideration so a transient error cannot delete the edit.
            var originals: [String: Data] = [:]
            var considered = Set(overrides.keys)
            for path in overrides.keys {
                let fileURL = root.appending(path: path)
                if let data = try? Data(contentsOf: fileURL) {
                    originals[path] = data
                } else if FileManager.default.fileExists(atPath: fileURL.path) {
                    considered.remove(path)
                }
            }
            return (result, originals, considered)
        }.value
        // A newer scan started while this one ran — discard, it will publish.
        guard scanGenerations[sourceID] == generation else { return }
        // Edits cleared here were byte-identical to the file, and edits for
        // deleted files have no item — the scan result stays consistent.
        edits.reconcile(sourceID: sourceID, originalContents: originals, consideredPaths: considered)
        platformOverrides.reconcile(
            sourceID: sourceID,
            validPaths: Set(result.items.map(\.relativePath)),
            consideredPaths: Set(platforms.keys)
        )
        scanResults[sourceID] = result
        Self.logger.info("Scanned \(source.name, privacy: .public): \(result.items.count) items, \(result.skipped.count) skipped")
    }

    // MARK: - File access

    /// An item's effective content: the in-app edit when one exists, else the
    /// file. Preview, token scanning, plan and apply all read through here.
    func fileContents(of item: InferredItem) throws -> Data {
        if let override = edits.contentOverride(for: item.id) {
            return override
        }
        return try originalFileContents(of: item)
    }

    /// Reads an item's file, bypassing any in-app edit. Local folders need
    /// security-scoped access; the GitHub cache lives in the app's container
    /// and is read directly.
    func originalFileContents(of item: InferredItem) throws -> Data {
        guard let source = sources.first(where: { $0.id == item.sourceID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        switch source.kind {
        case .localFolder(let bookmark):
            var isStale = false
            let folderURL = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard folderURL.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission)
            }
            defer { folderURL.stopAccessingSecurityScopedResource() }
            return try Data(contentsOf: folderURL.appending(path: item.relativePath))

        case .gitHub:
            let root = try gitHubScanRoot(for: source)
            return try Data(contentsOf: root.appending(path: item.relativePath))
        }
    }

    // MARK: - Derived data

    func items(for sourceIDs: Set<UUID>) -> [InferredItem] {
        sources
            .filter { sourceIDs.contains($0.id) }
            .flatMap { scanResults[$0.id]?.items ?? [] }
    }

    func skippedFiles(for sourceIDs: Set<UUID>) -> [SkippedFile] {
        sources
            .filter { sourceIDs.contains($0.id) }
            .flatMap { scanResults[$0.id]?.skipped ?? [] }
    }

    // MARK: - Persistence

    private func load() {
        sources = file.load()
        identities = identityFile.load()
        // Sources added before identities were kept: their key gets their ID.
        for source in sources where !identities.contains(where: { $0.key == source.identityKey }) {
            remember(SourceIdentity(key: source.identityKey, sourceID: source.id))
        }
    }

    private func save() {
        file.save(sources)
    }
}
