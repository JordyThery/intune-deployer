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
    var addFolder: (() -> Void)?
    var addGitHubRepository: (() -> Void)?
}

/// The tenant view's commands, while it's shown (`TenantDetailView`). A nil
/// action is dimmed, as its button is.
struct TenantDetailActions {
    var baselineSettings: (() -> Void)?
    var runPreflight: (() -> Void)?
    var removeBaseline: (() -> Void)?
}

/// The tenant inventory's commands, while it's shown (`TenantInventoryView`).
struct TenantInventoryActions {
    var reloadInventory: (() -> Void)?
    var exportAll: (() -> Void)?
}

extension FocusedValues {
    @Entry var mainWindow: MainWindowActions?
    @Entry var tenantDetail: TenantDetailActions?
    @Entry var tenantInventory: TenantInventoryActions?
}

/// File › Add Folder… and Add GitHub Repository…, and the Tenant menu with
/// Plan (⌘P), Refresh Sources (⌘R), sign-in and the tenant view's commands.
/// Each is unavailable when its button in the window is (or isn't shown).
struct MainCommands: Commands {
    @FocusedValue(\.mainWindow) private var actions
    @FocusedValue(\.tenantDetail) private var detail
    @FocusedValue(\.tenantInventory) private var inventory

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Folder…") { actions?.addFolder?() }
                .disabled(actions?.addFolder == nil)
            Button("Add GitHub Repository…") { actions?.addGitHubRepository?() }
                .disabled(actions?.addGitHubRepository == nil)
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
            Divider()
            Button("Baseline Settings…") { detail?.baselineSettings?() }
                .disabled(detail?.baselineSettings == nil)
            Button("Run Preflight…") { detail?.runPreflight?() }
                .disabled(detail?.runPreflight == nil)
            Button("Reload Inventory") { inventory?.reloadInventory?() }
                .disabled(inventory?.reloadInventory == nil)
            Button("Export All…") { inventory?.exportAll?() }
                .disabled(inventory?.exportAll == nil)
            Divider()
            Button("Remove Baseline…") { detail?.removeBaseline?() }
                .disabled(detail?.removeBaseline == nil)
        }
    }
}
