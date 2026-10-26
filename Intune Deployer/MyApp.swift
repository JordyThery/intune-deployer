import JTKit
import SwiftUI

@main
struct IntuneDeployerApp: App {
    @State private var sourceStore: SourceStore
    @State private var tenantStore = TenantStore()
    @State private var auth: AuthManager
    @State private var activityLog: ActivityLog
    @State private var session: TenantSession
    @State private var updates = UpdateChecker(configuration: UpdateConfiguration(
        owner: "JordyThery",
        repository: "intune-deployer",
        appName: "Intune Deployer"
    ))
    @State private var tour = IntuneDeployerTour.makeState()

    init() {
        let auth = AuthManager()
        let log = ActivityLog()
        _sourceStore = State(initialValue: SourceStore(activityLog: log))
        _auth = State(initialValue: auth)
        _activityLog = State(initialValue: log)
        _session = State(initialValue: TenantSession(auth: auth, activityLog: log))
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
                .frame(minWidth: 900, minHeight: 560)
                .task { await updates.checkAutomatically() }
        }
        .commands {
            AppInfoCommands(appName: "Intune Deployer") { updates.checkManually() }
            CommandGroup(after: .help) {
                Button("Guided Tour") { tour.start() }
            }
            // The toolbar picker's items, as JTKit's Connection menu.
            ConnectionCommands(
                store: tenantStore.connections,
                selection: Binding(get: { tenantStore.selectedProfileID },
                                   set: { tenantStore.selectedProfileID = $0 })
            )
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
        }

        AboutWindow(configuration: .intuneDeployer)
    }
}
