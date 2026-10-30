import Foundation
import JTKit
import OSLog

/// Under tests the app reaches no saved tenant and no GitHub repository, and
/// keeps its files and settings out of the real ones (JTKit ROADMAP step 11,
/// decided by Jordy). "Under tests" is the host of the unit tests and a
/// sandbox launch (`-JTKitSandbox YES`, which the UI tests use). Every
/// attempt to reach a saved tenant (a sign-in, a token, a Graph request) or
/// GitHub is refused before anything is sent and written down, so the release
/// check can show it in its report and fail. The demo tenant is not a tenant:
/// it is answered inside the app and never refused.
///
/// The one way to a real tenant under tests is the release check's live
/// checks: an `AuthManager` made for exactly one allow-listed tenant
/// (`UnderTestSignIn.liveCheck`) with a `TenantSession` on JTKit's guarded
/// network.
nonisolated enum UnderTest {
    /// Whether this process is the host of the unit tests.
    static let isUnitTestHost: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }()

    /// Whether this launch is under tests.
    static let isActive: Bool = isUnitTestHost
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
        || AppDemo.isSandboxLaunch

    /// Where refused attempts are written: the container's temporary folder,
    /// the same for the test host and the app the UI tests launch. The
    /// release check empties it before every run.
    static let folder = FileManager.default.temporaryDirectory
        .appending(path: "IntuneDeployer-under-test", directoryHint: .isDirectory)

    /// The message a refused attempt gives.
    static let refusal = "Refused under tests: a saved tenant and GitHub are never reached while tests run."

    /// Where the app keeps its files: Application Support/Intune Deployer,
    /// or in the unit-test host a folder of this process in the temporary
    /// folder, so neither the hosted app nor a test can write the real
    /// `tenants.json`, `sources.json`, item edits, platform choices or GitHub
    /// cache (removed when the process ends).
    static let dataFolder: URL = isUnitTestHost ? unitTestHostFolder : realDataFolder

    /// Application Support/Intune Deployer. Under tests only read, by the
    /// live checks (the saved tenant of the allow-listed tenant).
    static var realDataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intune Deployer", isDirectory: true)
    }

    private static let unitTestHostFolder: URL = {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "IntuneDeployer-unit-test-host/\(getpid())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        atexit {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
                .appending(path: "IntuneDeployer-unit-test-host/\(getpid())"))
        }
        return folder
    }()
}

/// The refused attempts to reach a saved tenant or GitHub, one JSON line
/// each: what was tried (sign-in, token, method, host and path), never a
/// query, token or account.
nonisolated final class SavedTenantGuard: Sendable {
    static let shared = SavedTenantGuard(fileURL: UnderTest.folder.appending(path: "saved-tenant-requests.jsonl"))

    nonisolated struct Attempt: Codable, Sendable, Equatable {
        var time: Date
        var process: String
        var what: String
    }

    let fileURL: URL
    private let lock = NSLock()
    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "UnderTest")

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(_ what: String) {
        Self.logger.error("Refused under tests: \(what, privacy: .public)")
        let attempt = Attempt(time: Date(), process: UnderTest.isUnitTestHost ? "unit test host" : "UI test run", what: what)
        guard let line = try? JSONEncoder().encode(attempt) else { return }
        lock.withLock {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // O_APPEND: the test host and the app the UI tests launch may both write.
            let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            let data = line + Data("\n".utf8)
            _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        }
    }

    func attempts() -> [Attempt] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Attempt.self, from: Data($0.utf8)) }
    }

    /// A session that sends nothing: every request is written down as
    /// "<kind> METHOD host/path" and fails before it leaves the Mac.
    func refusingSession(kind: String) -> URLSession {
        let id = UUID().uuidString
        RefusingURLProtocol.register(self, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusingURLProtocol.self]
        configuration.httpAdditionalHeaders = [RefusingURLProtocol.guardHeader: id, RefusingURLProtocol.kindHeader: kind]
        return URLSession(configuration: configuration)
    }
}

/// The error of a refused attempt.
nonisolated struct UnderTestRefusal: LocalizedError, Sendable {
    var errorDescription: String? { UnderTest.refusal }
}

/// Fails every request of a refusing session and records it with its guard.
nonisolated final class RefusingURLProtocol: URLProtocol, @unchecked Sendable {
    static let guardHeader = "X-IntuneDeployer-Under-Test"
    static let kindHeader = "X-IntuneDeployer-Under-Test-Kind"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var guards: [String: SavedTenantGuard] = [:]

    static func register(_ savedTenantGuard: SavedTenantGuard, id: String) {
        lock.withLock { guards[id] = savedTenantGuard }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.guardHeader) ?? ""
        let kind = request.value(forHTTPHeaderField: Self.kindHeader) ?? "request"
        let savedTenantGuard = Self.lock.withLock { Self.guards[id] } ?? .shared
        savedTenantGuard.record("\(kind): \(request.httpMethod ?? "GET") \(request.url?.host() ?? "")\(request.url?.path() ?? "")")
        client?.urlProtocol(self, didFailWithError: UnderTestRefusal())
    }

    override func stopLoading() {}
}
