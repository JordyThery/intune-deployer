import Foundation
import OSLog

nonisolated enum GitHubError: LocalizedError {
    case http(Int, String)
    case notFound(String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let context):
            "GitHub returned HTTP \(status) for \(context)\(status == 403 ? " — possibly rate-limited, try again later" : "")"
        case .notFound(let what):
            what
        case .extractionFailed(let reason):
            "Could not extract the downloaded archive: \(reason)"
        }
    }
}

/// Minimal GitHub REST client. Requests run unauthenticated (60 req/h) unless
/// a personal access token is configured, which also enables private
/// repositories and raises the limit to 5,000 req/h.
nonisolated enum GitHubClient {
    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "GitHub")
    private static let apiBase = URL(string: "https://api.github.com")!

    struct RepoInfo: Decodable, Sendable {
        struct License: Decodable, Sendable {
            let name: String?
            let spdxId: String?
        }

        let fullName: String
        let defaultBranch: String
        let htmlUrl: String?
        let license: License?
    }

    struct Release: Decodable, Sendable, Equatable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?
    }

    // MARK: - Metadata

    static func fetchRepoInfo(owner: String, repo: String, token: String? = nil) async throws -> RepoInfo {
        try await get(RepoInfo.self, path: "repos/\(owner)/\(repo)", context: "\(owner)/\(repo)", token: token)
    }

    /// Returns the 100 most recent releases (not paged further; tag-prefix
    /// matches older than that are not considered).
    static func fetchReleases(owner: String, repo: String, token: String? = nil) async throws -> [Release] {
        try await get([Release].self, path: "repos/\(owner)/\(repo)/releases?per_page=100", context: "\(owner)/\(repo) releases", token: token)
    }

    /// Latest published (non-draft, non-prerelease) release, optionally
    /// restricted to tags starting with `tagPrefix` (case-insensitive).
    static func pickRelease(from releases: [Release], tagPrefix: String?) -> Release? {
        let prefix = tagPrefix?.trimmingCharacters(in: .whitespaces) ?? ""
        return releases
            .filter { !$0.draft && !$0.prerelease }
            .filter { prefix.isEmpty || $0.tagName.lowercased().hasPrefix(prefix.lowercased()) }
            .max { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) }
    }

    // MARK: - Download

    /// Downloads the zipball for `ref` and extracts it into `destination`.
    /// The previous content is replaced only after a successful extraction.
    /// Returns the content root — the single top-level directory GitHub puts
    /// into its zipballs ("owner-repo-sha/"). Runs off the main actor: ditto
    /// blocks its thread.
    @concurrent
    static func downloadAndExtract(owner: String, repo: String, ref: String, into destination: URL, token: String? = nil) async throws -> URL {
        // For private repos the 302 Location already carries an ephemeral
        // token, so the redirect to codeload works after auth at the API.
        let url = apiBase.appending(path: "repos/\(owner)/\(repo)/zipball/\(ref)")
        let (tempFile, response) = try await URLSession.shared.download(for: request(for: url, token: token))
        defer { try? FileManager.default.removeItem(at: tempFile) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GitHubError.http((response as? HTTPURLResponse)?.statusCode ?? -1, "zipball of \(owner)/\(repo)@\(ref)")
        }

        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        // Zip needs a .zip extension for ditto; extraction runs inside the
        // sandbox container (the child process inherits our sandbox).
        let zipURL = parent.appending(path: "\(destination.lastPathComponent).zip")
        try? fileManager.removeItem(at: zipURL)
        try fileManager.moveItem(at: tempFile, to: zipURL)
        defer { try? fileManager.removeItem(at: zipURL) }

        // Extract next to the destination, then swap in, so a failed download
        // never destroys the last good cache.
        let staging = parent.appending(path: "\(destination.lastPathComponent)-staging")
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try extractZip(at: zipURL, to: staging)
            _ = try contentRoot(in: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
        return try contentRoot(in: destination)
    }

    private static func extractZip(at zipURL: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destination.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain the pipe before waiting so large output cannot deadlock.
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = output.isEmpty ? "ditto exit \(process.terminationStatus)" : output
            throw GitHubError.extractionFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// GitHub zipballs contain exactly one top-level "owner-repo-sha" folder.
    static func contentRoot(in directory: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let directories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard let root = directories.first, directories.count == 1 else {
            throw GitHubError.extractionFailed("expected one top-level folder, found \(directories.count)")
        }
        return root
    }

    // MARK: - Plumbing

    private static func request(for url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func get<T: Decodable & Sendable>(_ type: T.Type, path: String, context: String, token: String?) async throws -> T {
        let url = apiBase.appending(path: path.split(separator: "?").first.map(String.init) ?? path)
        // Re-attach a query string if present (appending(path:) would escape it).
        let finalURL: URL
        if let queryStart = path.firstIndex(of: "?") {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.query = String(path[path.index(after: queryStart)...])
            finalURL = components.url ?? url
        } else {
            finalURL = url
        }

        let (data, response) = try await URLSession.shared.data(for: request(for: finalURL, token: token))
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.http(-1, context)
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 {
                throw GitHubError.notFound(
                    token == nil
                        ? "\(context) was not found on GitHub. Private repository? Add a personal access token in Settings."
                        : "\(context) was not found on GitHub — check the name, and that your access token can read this repository."
                )
            }
            if http.statusCode == 401 {
                throw GitHubError.http(401, "\(context) — the GitHub token in Settings is invalid or expired")
            }
            throw GitHubError.http(http.statusCode, context)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            logger.error("GitHub decode failed for \(context, privacy: .public): \(error.localizedDescription)")
            throw error
        }
    }
}
