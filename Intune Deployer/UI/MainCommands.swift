import SwiftUI

/// What the main window offers the menu bar: every toolbar command and the
/// sidebar's add buttons are menu items too, so they work with Full Keyboard
/// Access and with the toolbar hidden. A nil action is dimmed.
struct MainWindowActions {
    var plan: (() -> Void)?
    var refreshSources: (() -> Void)?
    /// Sign in to the tenant in use; nil when signed in or nothing to sign in to.
    var signIn: (() -> Void)?
    /// Sign out of the tenant in use, with the menu item's title.
    var signOut: (title: String, action: () -> Void)?
    var addFolder: () -> Void
    var addGitHubRepository: () -> Void
}

extension FocusedValues {
    @Entry var mainWindow: MainWindowActions?
}

/// File › Add Folder… and Add GitHub Repository…, and the Tenant menu with
/// Plan (⌘P), Refresh Sources (⌘R) and sign-in.
struct MainCommands: Commands {
    @FocusedValue(\.mainWindow) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Folder…") { actions?.addFolder() }
                .disabled(actions == nil)
            Button("Add GitHub Repository…") { actions?.addGitHubRepository() }
                .disabled(actions == nil)
        }
        CommandMenu("Tenant") {
            Button("Plan…") { actions?.plan?() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(actions?.plan == nil)
            Button("Refresh Sources") { actions?.refreshSources?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions?.refreshSources == nil)
            Divider()
            if let signOut = actions?.signOut {
                Button(signOut.title) { signOut.action() }
            } else {
                Button("Sign In") { actions?.signIn?() }
                    .disabled(actions?.signIn == nil)
            }
        }
    }
}
