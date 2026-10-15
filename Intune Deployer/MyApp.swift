import SwiftUI

@main
struct IntuneDeployerApp: App {
    @State private var sourceStore = SourceStore()
    @State private var tenantStore = TenantStore()
    @State private var auth: AuthManager
    @State private var activityLog: ActivityLog
    @State private var session: TenantSession
    @State private var updates = UpdateChecker()
    @State private var tour = TourState()

    init() {
        let auth = AuthManager()
        let log = ActivityLog()
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkManually() }
            }
            CommandGroup(after: .help) {
                Button("Guided Tour") { tour.start() }
            }
        }

        Window("Activity Log", id: "activity-log") {
            ActivityLogView()
                .environment(activityLog)
                .frame(minWidth: 640, minHeight: 320)
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Settings {
            SettingsView()
        }
    }
}
