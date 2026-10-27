import Foundation
import JTKit

/// The app's demo mode, one per launch: JTKit's switch, saved under
/// `demoMode`, and the demo tenant "Contoso Intune (Demo)" on JTKit's demo
/// Intune server.
///
/// In demo mode Plan, Apply, deletions, Remove Baseline, export and
/// Preflight run the app's real code against the demo tenant, with their
/// real confirmations. No sign-in window opens; MSAL, its Keychain cache and
/// the real signed-in accounts aren't used (`AuthManager`). Baseline sources,
/// item edits and platform choices stay real; the GitHub token is read, never
/// written (Settings › GitHub).
@MainActor
enum AppDemo {
    static let mode = DemoMode(key: "demoMode")

    /// The saved tenants for this launch: in a sandbox run (`-JTKitSandbox
    /// YES`, UI tests) an empty list in demo mode's temporary folder, so the
    /// real ones and the tenant in use are never read or written.
    static func tenantStore() -> TenantStore {
        guard isSandboxLaunch else { return TenantStore(demo: mode) }
        return TenantStore(storageURL: mode.scratchDirectory.appendingPathComponent("tenants.json"),
                           defaults: DemoMode.sandboxDefaults(), demo: mode)
    }

    /// The baseline sources for this launch: in a sandbox run in demo mode's
    /// temporary folder, with GitHub blocked (public lookups are off there).
    static func sourceStore(activityLog: ActivityLog) -> SourceStore {
        guard isSandboxLaunch else { return SourceStore(activityLog: activityLog) }
        return SourceStore(activityLog: activityLog, folder: mode.scratchDirectory,
                           gitHubSession: DemoNetwork(servers: [:]).session)
    }

    /// Started with `-JTKitSandbox YES`: no update check and no GitHub lookups.
    nonisolated static var isSandboxLaunch: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.lastIndex(of: DemoMode.sandboxArgument), arguments.indices.contains(index + 1)
        else { return false }
        return ["yes", "true", "1"].contains(arguments[index + 1].lowercased())
    }
}
