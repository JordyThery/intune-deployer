import JTKit
import SwiftUI
import UniformTypeIdentifiers

/// Detail column when a tenant profile is selected in the sidebar:
/// profile summary plus quick actions.
struct TenantDetailView: View {
    @Environment(TenantSession.self) private var session
    @Environment(AuthManager.self) private var auth
    let profile: TenantProfile

    @State private var isEditing = false
    @State private var showingPreflight = false
    @State private var showingRemoveBaseline = false
    @State private var exportDocument: TextExportDocument?

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
                        LabeledContent("Client ID", value: profile.hasValidClientID ? profile.clientID : "missing — edit the profile")
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
                    Button("Edit Profile…") { isEditing = true }
                    Button("Run Preflight…") { showingPreflight = true }
                        .disabled(!auth.isSignedIn(profile))
                        .help(auth.isSignedIn(profile) ? "" : "Sign in to this tenant first")
                    Button("Export Profile…") { exportProfile() }
                        .help("Save this profile as JSON (sign-in state is not included)")
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
            TenantProfileEditorView(profile: profile)
        }
        .sheet(isPresented: $showingPreflight) {
            PreflightView(profile: profile)
        }
        .sheet(isPresented: $showingRemoveBaseline) {
            RemoveBaselineView(profile: profile)
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: .json,
            defaultFilename: "\(profile.displayName).intune-deployer-profile.json"
        ) { _ in
            exportDocument = nil
        }
    }

    /// The MSAL account identifier is machine/account-specific and is
    /// stripped from exports.
    private func exportProfile() {
        var exported = profile
        exported.accountIdentifier = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(exported),
              let json = String(data: data, encoding: .utf8) else { return }
        exportDocument = TextExportDocument(text: json)
    }
}
