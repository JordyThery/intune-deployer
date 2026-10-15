import Foundation
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

    private let storageURL: URL
    private let cacheRoot: URL
    /// Monotonic per-source scan counter: only the latest-started scan may
    /// publish results, so an older scan finishing late cannot overwrite a
    /// newer one (e.g. the rescan after saving an item edit).
    private var scanGenerations: [UUID: Int] = [:]

    init(storageURL: URL? = nil, editStore: ItemEditStore? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intune Deployer", isDirectory: true)
        self.storageURL = storageURL ?? base.appendingPathComponent("sources.json")
        self.cacheRoot = base.appendingPathComponent("GitHubSources", isDirectory: true)
        self.edits = editStore ?? ItemEditStore()
        load()
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
            let source = BaselineSource(
                name: url.lastPathComponent,
                kind: .localFolder(bookmark: bookmark),
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
        let source = BaselineSource(
            name: spec.displayName,
            kind: .gitHub(spec),
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

        do {
            let token = GitHubTokenStore.load()
            let info = try await GitHubClient.fetchRepoInfo(owner: spec.owner, repo: spec.repo, token: token)
            let releases = try await GitHubClient.fetchReleases(owner: spec.owner, repo: spec.repo, token: token)
            let release = GitHubClient.pickRelease(from: releases, tagPrefix: spec.tagPrefix)
            let ref = release?.tagName ?? info.defaultBranch

            _ = try await GitHubClient.downloadAndExtract(
                owner: spec.owner,
                repo: spec.repo,
                ref: ref,
                into: contentDirectory(for: sourceID),
                token: token
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
            scanErrors[sourceID] = "Sync failed: \(error.localizedDescription)"
            Self.logger.error("GitHub sync failed for \(source.name, privacy: .public): \(error.localizedDescription)")
        }
    }

    private func scanGitHubCache(_ source: BaselineSource) async {
        scanningSourceIDs.insert(source.id)
        defer { scanningSourceIDs.remove(source.id) }
        guard cacheExists(for: source.id) else {
            scanErrors[source.id] = "Not synced yet — choose Sync Now from the source's context menu."
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
        let token = GitHubTokenStore.load()
        for sourceID in sources.filter(\.isGitHub).map(\.id) {
            guard let spec = sources.first(where: { $0.id == sourceID })?.gitHubSpec,
                  let releases = try? await GitHubClient.fetchReleases(owner: spec.owner, repo: spec.repo, token: token),
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
                throw GitHubError.notFound("The subfolder must stay inside the repository")
            }
            root = root.appending(path: subfolder)
            guard FileManager.default.fileExists(atPath: root.path) else {
                throw GitHubError.notFound("Subfolder “\(subfolder)” does not exist in the synced repository")
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
        let (result, originals, considered) = try await Task.detached(priority: .userInitiated) {
            let result = try InferenceEngine.scan(root: root, sourceID: sourceID, overrides: overrides)
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
    /// security-scoped access; the GitHub cache lives in our container and is
    /// read directly.
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
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            sources = try JSONDecoder().decode([BaselineSource].self, from: data)
        } catch {
            Self.logger.error("Failed to decode sources.json: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sources).write(to: storageURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save sources.json: \(error.localizedDescription)")
        }
    }
}
