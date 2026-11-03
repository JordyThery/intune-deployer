import JTKit
import SwiftUI

@main
struct IntuneDeployerApp: App {
    @State private var sourceStore: SourceStore
    @State private var tenantStore: TenantStore
    @State private var auth: AuthManager
    @State private var activityLog: ActivityLog
    @State private var session: TenantSession
    @State private var updates = UpdateChecker(configuration: UpdateConfiguration(
        owner: "JordyThery",
        repository: "intune-deployer",
        appName: "Intune Deployer"
    ))
    @State private var tour = AppDemo.tour()

    init() {
        let tenants = AppDemo.tenantStore()
        let auth = AuthManager(demo: AppDemo.mode)
        let log = ActivityLog()
        let session = TenantSession(auth: auth, activityLog: log, demo: AppDemo.mode)
        // A profile remembers the tenant ID its sign-in named, so tenants are
        // compared by it, not as typed.
        let remember: @MainActor (TenantProfile, String) -> Void = { profile, tenantID in
            tenants.noteSignedInTenant(tenantID, for: profile.id, typed: profile.tenantID)
        }
        auth.onSignedInTenant = remember
        session.onTenantConfirmed = remember
        _tenantStore = State(initialValue: tenants)
        _sourceStore = State(initialValue: AppDemo.sourceStore(activityLog: log))
        _auth = State(initialValue: auth)
        _activityLog = State(initialValue: log)
        _session = State(initialValue: session)
    }

    var body: some Scene {
        // A single main window: sources, tenant session and plan state are
        // app-wide and would conflict across windows.
        Window("Intune Deployer", id: "main") {
            ContentView()
                .environment(sourceStore)
                .environment(tenantStore)
                .environment(auth)
                .environment(activityLog)
                .environment(session)
                .environment(updates)
                .environment(tour)
                .environment(AppDemo.mode)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    guard !AppDemo.isSandboxed else { return }
                    await updates.checkAutomatically()
                }
        }
        .commands {
            AppInfoCommands(appName: "Intune Deployer") { updates.checkManually() }
            SidebarCommands()
            ToolbarCommands()
            MainCommands()
            CommandGroup(after: .help) {
                Button("Guided Tour") { tour.start() }
            }
            // The toolbar picker's items, as JTKit's Connection menu, with Demo Mode.
            ConnectionCommands(
                store: tenantStore.connections,
                roles: [tenantStore.connectionRole(lockedWhile: { session.isPlanning || session.isApplying })]
            ) {
                DemoModeSwitch(session: session)
            }
        }

        ActivityLogWindow(
            log: activityLog,
            emptyDescription: "Graph, GitHub and upload requests appear here as they happen."
        )

        // General holds item editing; Connections and GitHub follow, and
        // JTKit adds Updates last.
        SettingsWindow(updates: updates, opensTabsByName: true) {
            SettingsContent.general
        } tabs: {
            SettingsContent.tabs(tenants: tenantStore, auth: auth, sources: sourceStore, session: session)
                // Settings › Connections notes that these are the real tenants.
                .environment(AppDemo.mode)
        }

        AboutWindow(configuration: .intuneDeployer)
    }
}

/// JTKit's "Demo Mode" switch, for the toolbar picker and the Connection
/// menu. Dimmed while a Plan or an Apply runs, so demo mode can't cut into it.
struct DemoModeSwitch: View {
    let session: TenantSession

    var body: some View {
        DemoModeToggle(demo: AppDemo.mode)
            .disabled(session.isPlanning || session.isApplying)
    }
}
