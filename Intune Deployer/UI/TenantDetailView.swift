import JTKit
import SwiftUI

/// Detail column when a tenant profile is selected in the sidebar:
/// profile summary plus quick actions.
struct TenantDetailView: View {
    @Environment(TenantSession.self) private var session
    @Environment(AuthManager.self) private var auth
    let profile: TenantProfile

    @State private var isEditing = false
    @State private var showingPreflight = false
    @State private var showingRemoveBaseline = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "building.2")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                            .font(.title2.bold())
                        Text(profile.tenantID)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                GroupBox("Profile") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Client ID", value: profile.hasValidClientID ? profile.clientID : "missing — add it in Settings › Connections")
                        LabeledContent("Account", value: auth.account(for: profile)?.username ?? "not signed in")
                        LabeledContent("Naming prefix", value: profile.namingPrefix.isEmpty ? "none" : profile.namingPrefix)
                        LabeledContent("Variables", value: "\(profile.variables.count)")
                        LabeledContent("Included items", value: "\(profile.selectedItemIDs.count)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.callout)
                }

                if let checks = session.preflightChecks {
                    GroupBox("Preflight") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(checks) { check in
                                HStack(spacing: 8) {
                                    Image(systemName: check.status.symbolName)
                                        .foregroundStyle(check.status == .ok ? .green : check.status == .warning ? .yellow : .red)
                                    Text(check.title)
                                    Spacer()
                                }
                                .font(.callout)
                                .help(check.message)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    Button("Baseline Settings…") { isEditing = true }
                        .help("Naming prefix, group creation, default assignments and variables")
                    SettingsTabLink(SettingsTabName.connections) { Text("Edit Connection…") }
                        .help("Name, tenant ID and client ID, in Settings › Connections")
                    Button("Run Preflight…") { showingPreflight = true }
                        .disabled(!auth.isSignedIn(profile))
                        .help(auth.isSignedIn(profile) ? "" : "Sign in to this tenant first")
                    Spacer()
                    Button("Remove Baseline…", role: .destructive) { showingRemoveBaseline = true }
                        .disabled(!auth.isSignedIn(profile))
                        .help(auth.isSignedIn(profile)
                            ? "Delete every object this app created in the tenant (typed confirmation required)"
                            : "Sign in to this tenant first")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $isEditing) {
            BaselineSettingsView(profile: profile)
        }
        .sheet(isPresented: $showingPreflight) {
            PreflightView(profile: profile)
        }
        .sheet(isPresented: $showingRemoveBaseline) {
            RemoveBaselineView(profile: profile)
        }
    }
}
