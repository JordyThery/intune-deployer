import Foundation
import JTKit
import OSLog

/// Under tests the app reaches no saved tenant and no GitHub repository, and
/// keeps its files and settings out of the real ones (JTKit ROADMAP step 11,
/// decided by Jordy). "Under tests" is the host of the unit tests and a
/// sandbox launch (`-JTKitSandbox YES`, which the UI tests use; JTKit's
/// `TestRun.isActive`). Every attempt to reach a saved tenant (a sign-in, a
/// token, a Graph request) or GitHub is refused before anything is sent and
/// written down, so the release check can show it in its report and fail.
/// The demo tenant is not a tenant: it is answered inside the app and never
/// refused.
///
/// The one way to a real tenant under tests is the release check's live
/// checks: an `AuthManager` made for exactly one allow-listed tenant
/// (`UnderTestSignIn.liveCheck`) with a `TenantSession` on JTKit's guarded
/// network.
nonisolated enum UnderTest {
    /// Where refused attempts are written: the container's temporary folder,
    /// the same for the test host and the app the UI tests launch. The
    /// release check empties it before every run.
    static let folder = TestRun.attemptsFolder(named: "IntuneDeployer-under-test")

    /// The message a refused attempt gives.
    static let refusal = "Refused under tests: a saved tenant and GitHub are never reached while tests run."

    /// The refused attempts to reach a saved tenant or GitHub, one JSON line
    /// each: what was tried (sign-in, token, method, host and path), never a
    /// query, token or account.
    static let attempts = TestRun.AttemptLog(fileURL: folder.appending(path: "saved-tenant-requests.jsonl"),
                                             logger: Logger(subsystem: "be.jordythery.intune-deployer", category: "UnderTest"))

    /// The error of a refused sign-in, token or sign-out.
    static var refused: TestRun.Refusal { TestRun.Refusal(refusal) }

    /// A session that sends nothing: every request is written to `log` as
    /// "<kind>: METHOD host/path" and fails before it leaves the Mac.
    static func refusingSession(kind: String, log: TestRun.AttemptLog = attempts) -> URLSession {
        TestRun.refusingSession(log: log, kind: kind, message: refusal)
    }

    /// Where the app keeps its files: Application Support/Intune Deployer,
    /// or in the unit-test host a folder of this process in the temporary
    /// folder, so neither the hosted app nor a test can write the real
    /// `tenants.json`, `sources.json`, item edits, platform choices or GitHub
    /// cache (removed when the process ends).
    static let dataFolder: URL = TestRun.isUnitTestHost ? unitTestHostFolder : realDataFolder

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
