import SwiftUI

/// Lists the existing Intune objects in the selected tenant, grouped by type.
/// Objects created by this app (identity tag in the description) get a badge.
struct TenantInventoryView: View {
    @Environment(TenantSession.self) private var session
    @Environment(AuthManager.self) private var auth
    let profile: TenantProfile

    var body: some View {
        List {
            ForEach(TenantCollection.allCases) { collection in
                Section {
                    if let error = session.inventoryErrors[collection] {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if let objects = session.inventory[collection] {
                        if objects.isEmpty {
                            Text("None")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(objects) { object in
                            HStack {
                                Image(systemName: collection.symbolName)
                                    .foregroundStyle(.tint)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(object.resolvedName)
                                    if let modified = object.lastModifiedDateTime {
                                        Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let shortID = object.taggedShortID {
                                    Text("Managed")
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                        .help("Created by Intune Deployer — identity tag \(ItemIdentity.tag(forShortID: shortID))")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(collection.displayName)
                        if let objects = session.inventory[collection] {
                            Text("\(objects.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if !auth.isSignedIn(profile) {
                ContentUnavailableView(
                    "Not Signed In",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Sign in to list this tenant's existing objects.")
                )
            } else if session.inventory.isEmpty && session.inventoryErrors.isEmpty && !session.isLoadingInventory {
                ContentUnavailableView {
                    Label("Inventory Not Loaded", systemImage: "cloud")
                } description: {
                    Text("Load the existing Intune objects in \(profile.displayName).")
                } actions: {
                    Button("Load Inventory") {
                        Task { await session.loadInventory(for: profile) }
                    }
                }
            } else if session.isLoadingInventory && session.inventory.isEmpty {
                ProgressView("Loading inventory…")
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await session.loadInventory(for: profile) }
                } label: {
                    Label("Reload Inventory", systemImage: "arrow.clockwise.icloud")
                }
                .disabled(!auth.isSignedIn(profile) || session.isLoadingInventory)
                .help("Fetch the tenant's current objects again from Microsoft Graph")
            }
        }
        .navigationTitle(profile.displayName)
    }
}
