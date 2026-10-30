import JTKit
import SwiftUI

@main
struct IntuneDeployerApp: App {
    @State private var sourceStore: SourceStore
    @State private var tenantStore = AppDemo.tenantStore()
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
        let auth = AuthManager(demo: AppDemo.mode)
        let log = ActivityLog()
        _sourceStore = State(initialValue: AppDemo.sourceStore(activityLog: log))
        _auth = State(initialValue: auth)
        _activityLog = State(initialValue: log)
        _session = State(initialValue: TenantSession(auth: auth, activityLog: log, demo: AppDemo.mode))
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
            CommandGroup(after: .help) {
                Button("Guided Tour") { tour.start() }
            }
            // The toolbar picker's items, as JTKit's Connection menu, with Demo Mode.
            ConnectionCommands(
                store: tenantStore.connections,
                roles: [tenantStore.connectionRole(selection: Binding(get: { tenantStore.selectedProfileID },
                                                                      set: { tenantStore.selectedProfileID = $0 }))]
            ) {
                DemoModeSwitch(session: session)
            }
        }

        ActivityLogWindow(
            log: activityLog,
            emptyDescription: "Graph, GitHub and upload requests appear here as they happen."
        )

        // JTKit's General tab starts with Appearance; item editing goes below
        // it. Connections and GitHub follow, and JTKit adds Updates last.
        SettingsWindow(updates: updates, opensTabsByName: true) {
            SettingsContent.general
        } tabs: {
            SettingsContent.tabs(tenants: tenantStore, auth: auth)
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
