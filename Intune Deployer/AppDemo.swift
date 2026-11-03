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
    /// In the unit tests' host it starts as a sandbox run (off, never saved),
    /// so a saved `demoMode` can't switch it on and nothing writes it.
    static let mode = TestRun.isUnitTestHost
        ? DemoMode(key: "demoMode", arguments: ProcessInfo.processInfo.arguments + [DemoMode.sandboxArgument, "YES"])
        : DemoMode(key: "demoMode")

    /// A sandbox run (`-JTKitSandbox YES`, UI tests) or the unit tests' host
    /// (JTKit's release check): the real tenants, the tenant in use, sources,
    /// settings and the tour are never read or written, GitHub is blocked
    /// and there is no update check.
    /// A launch under the release check's live-check switch
    /// (`-JTKitLiveCheck`) counts as one too.
    static var isSandboxed: Bool { DemoMode.isSandboxLaunch || TestRun.isUnitTestHost || LiveLaunch.isSwitched }

    /// Where a sandboxed launch keeps its tenants and sources: demo mode's
    /// temporary folder; under the live-check switch the run's folder for
    /// app files (`UnderTest.dataFolder`).
    private static var sandboxFolder: URL { LiveLaunch.isSwitched ? UnderTest.dataFolder : mode.scratchDirectory }

    /// The saved tenants for this launch: when sandboxed an empty list in
    /// the sandbox folder, so the real ones and the tenant in use are never
    /// read or written.
    static func tenantStore() -> TenantStore {
        guard isSandboxed else { return TenantStore(demo: mode) }
        return TenantStore(storageURL: sandboxFolder.appendingPathComponent("tenants.json"),
                           defaults: sandboxedDefaults(), demo: mode)
    }

    /// The baseline sources for this launch: when sandboxed in the sandbox
    /// folder, with GitHub blocked (public lookups are off there).
    static func sourceStore(activityLog: ActivityLog) -> SourceStore {
        guard isSandboxed else { return SourceStore(activityLog: activityLog) }
        return SourceStore(activityLog: activityLog, folder: sandboxFolder,
                           gitHubSession: DemoNetwork(servers: [:]).session)
    }

    /// The tour's "seen" setting: when sandboxed the sandbox settings.
    static func tour() -> TourState<TourAnchorID> {
        isSandboxed ? IntuneDeployerTour.makeState(defaults: sandboxedDefaults()) : IntuneDeployerTour.makeState()
    }

    /// Settings when sandboxed: JTKit's sandbox settings for a sandbox run;
    /// in the unit tests' host a file in its temporary folder, so it leaves
    /// no file in Preferences. One per launch, empty when it starts.
    static func sandboxedDefaults() -> UserDefaults {
        guard TestRun.isUnitTestHost else { return DemoMode.sandboxDefaults() }
        return unitTestHostDefaults
    }

    private static let unitTestHostDefaults: UserDefaults = {
        let domain = UnderTest.dataFolder.appending(path: "settings").path
        let defaults = UserDefaults(suiteName: domain) ?? .standard
        defaults.removePersistentDomain(forName: domain)
        return defaults
    }()
}
