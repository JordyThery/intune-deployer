import JTKit
import SwiftUI

struct ContentView: View {
    @Environment(SourceStore.self) private var store
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantSession.self) private var session
    @Environment(AuthManager.self) private var auth
    @Environment(UpdateChecker.self) private var updates
    @Environment(TourState<TourAnchorID>.self) private var tour

    @State private var sidebarSelection: Set<SidebarSelection> = []
    @State private var selectedItemIDs: Set<String> = []
    @State private var searchText = ""
    @State private var typeFilter: ItemType?
    @State private var platformFilter: ItemPlatform?
    @State private var authErrorMessage: String?
    @State private var showingPlan = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            if let profile = selectedSidebarTenant {
                TenantInventoryView(profile: profile)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380)
            } else {
                ItemListView(
                    selectedSourceIDs: selectedSourceIDs,
                    selectedItemIDs: $selectedItemIDs,
                    searchText: $searchText,
                    typeFilter: $typeFilter,
                    platformFilter: $platformFilter
                )
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
                .tourAnchor(TourAnchorID.items)
            }
        } detail: {
            Group {
                if let profile = selectedSidebarTenant {
                    TenantDetailView(profile: profile)
                } else if selectedItems.count > 1 {
                    MultiItemDetailView(items: selectedItems)
                } else if let item = selectedItems.first {
                    ItemDetailView(item: item)
                } else {
                    ContentUnavailableView(
                        "No Item Selected",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Select an item to see its detected type, variables, preview and assignment.")
                    )
                }
            }
            .tourAnchor(TourAnchorID.detail)
        }
        .toolbar {
            ToolbarItem {
                tenantPicker
            }
            ToolbarItem {
                Button {
                    Task { await store.rescanAll() }
                } label: {
                    Label("Refresh Sources", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Rescan all sources (⌘R)")
                .disabled(store.sources.isEmpty || !store.scanningSourceIDs.isEmpty)
            }
            ToolbarItem {
                Button {
                    session.currentPlan = nil
                    showingPlan = true
                } label: {
                    Label("Plan", systemImage: "list.bullet.clipboard")
                }
                .keyboardShortcut("p", modifiers: .command)
                .help("Dry-run: compute what would change in the active tenant (⌘P)")
                .disabled(!canPlan)
            }
            ToolbarItem {
                accountButton
            }
        }
        .sheet(isPresented: Binding(
            get: { updates.isPresented },
            set: { updates.isPresented = $0 }
        )) {
            UpdateView()
                .environment(updates)
        }
        .sheet(isPresented: $showingPlan) {
            if let profile = tenantStore.selectedProfile {
                PlanView(profile: profile, items: allItems)
            }
        }
        .navigationTitle("Intune Deployer")
        .alert("Sign-in Failed", isPresented: Binding(
            get: { authErrorMessage != nil },
            set: { if !$0 { authErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authErrorMessage ?? "")
        }
        .alert("Tenant Profile Not Saved", isPresented: Binding(
            get: { tenantStore.saveError != nil },
            set: { if !$0 { tenantStore.saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tenantStore.saveError ?? "")
        }
        .task {
            // Restore cached accounts for all profiles (keychain token cache).
            for profile in tenantStore.profiles {
                auth.restoreAccount(for: profile)
            }
            await store.rescanAll()
            if sidebarSelection.isEmpty, let first = store.sources.first {
                sidebarSelection = [.source(first.id)]
            }
        }
        // The tenant in use changes with the picker and with Demo Mode.
        .onChange(of: tenantStore.selectedProfile?.id) {
            session.reset()
            if let profile = tenantStore.selectedProfile {
                auth.restoreAccount(for: profile)
            }
            // Keep the sidebar in step when it was showing a tenant profile.
            let tenantSelections = sidebarSelection.filter { if case .tenant = $0 { true } else { false } }
            if !tenantSelections.isEmpty {
                sidebarSelection.subtract(tenantSelections)
                if let id = tenantStore.selectedProfile?.id {
                    sidebarSelection.insert(.tenant(id))
                }
            }
        }
        .onChange(of: selectedSidebarTenant?.id) {
            // Browsing a tenant in the sidebar also makes it the active
            // tenant; the demo tenant is never saved as the one in use.
            if let profile = selectedSidebarTenant, !profile.isDemo, tenantStore.selectedProfileID != profile.id {
                tenantStore.selectedProfileID = profile.id
            }
        }
        .guidedTour(tour)
    }

    // MARK: - Toolbar pieces

    /// JTKit's picker: the tenant in use, the saved tenants, Demo Mode and
    /// "Edit Connections…"; the Connection menu has the same items.
    private var tenantPicker: some View {
        ConnectionPicker(
            store: tenantStore.connections,
            role: tenantStore.connectionRole(selection: Binding(get: { tenantStore.selectedProfileID },
                                                                set: { tenantStore.selectedProfileID = $0 }))
        ) {
            DemoModeSwitch(session: session)
        }
    }

    /// Sign-in state for the ACTIVE tenant profile (every tenant has its own
    /// registration and account).
    @ViewBuilder
    private var accountButton: some View {
        if let profile = tenantStore.selectedProfile {
            if profile.isDemo, let account = auth.account(for: profile) {
                // Demo Mode's sample account: no sign-in, nothing to sign out of.
                Menu {
                    Text(account.username)
                    Divider()
                    Text("Sample account in \(DemoMode.title)")
                } label: {
                    Label("Account", systemImage: "person.crop.circle.badge.checkmark")
                }
                .help("\(profile.displayName): signed in as \(account.username). \(DemoMode.helpText)")
            } else if let account = auth.account(for: profile) {
                Menu {
                    Text(account.username)
                    Divider()
                    Button("Sign Out of \(profile.displayName)") {
                        Task { await auth.signOut(profile: profile) }
                    }
                } label: {
                    Label("Account", systemImage: "person.crop.circle.badge.checkmark")
                }
                .help("\(profile.displayName): signed in as \(account.username)")
            } else {
                Button {
                    Task { await signIn(profile: profile) }
                } label: {
                    if auth.signingInProfileIDs.contains(profile.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sign In", systemImage: "person.crop.circle")
                    }
                }
                .disabled(auth.signingInProfileIDs.contains(profile.id))
                .help("Sign in to \(profile.displayName)")
            }
        } else {
            Button {} label: {
                Label("Sign In", systemImage: "person.crop.circle")
            }
            .disabled(true)
            .help("Add and select a tenant profile to sign in")
        }
    }

    private func signIn(profile: TenantProfile) async {
        do {
            let account = try await auth.signIn(profile: profile)
            // Remember which account belongs to this tenant profile.
            // Re-read the profile: it may have been edited during sign-in.
            if var updated = tenantStore.profiles.first(where: { $0.id == profile.id }) {
                updated.accountIdentifier = account.identifier
                tenantStore.update(updated)
            }
        } catch {
            // User cancelling the sign-in sheet is not an error worth alerting.
            if AuthManager.isCancellation(error) {
                return
            }
            authErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Plan helpers

    /// All scanned items across every source — a profile may select items
    /// from sources that aren't focused in the sidebar.
    private var allItems: [InferredItem] {
        store.items(for: Set(store.sources.map(\.id)))
    }

    private var canPlan: Bool {
        guard let profile = tenantStore.selectedProfile else { return false }
        return auth.isSignedIn(profile)
            && !profile.selectedItemIDs.isEmpty
            && !session.isApplying
            && !session.isPlanning
    }

    // MARK: - Selection helpers

    private var selectedSourceIDs: Set<UUID> {
        Set(sidebarSelection.compactMap {
            if case .source(let id) = $0 { id } else { nil }
        })
    }

    private var selectedSidebarTenant: TenantProfile? {
        // Deterministic when several rows are selected: first in list order.
        let tenantIDs = Set(sidebarSelection.compactMap {
            if case .tenant(let id) = $0 { id } else { nil }
        })
        // the tenant in use (the demo tenant in demo mode), else the first saved one
        if let inUse = tenantStore.selectedProfile, tenantIDs.contains(inUse.id) { return inUse }
        return tenantStore.profiles.first { tenantIDs.contains($0.id) }
    }

    /// Highlighted items in list order (highlight ≠ deploy checkbox).
    private var selectedItems: [InferredItem] {
        guard !selectedItemIDs.isEmpty else { return [] }
        return store.items(for: selectedSourceIDs).filter { selectedItemIDs.contains($0.id) }
    }
}
