import SwiftUI

/// Deletes every object tagged by this app in the tenant, after the user
/// types the tenant's display name to confirm.
struct RemoveBaselineView: View {
    @Environment(TenantSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let profile: TenantProfile

    @State private var typedName = ""
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Remove Baseline — \(profile.displayName)", systemImage: "trash")
                    .font(.title3.bold())
                Spacer()
                if session.isApplying {
                    ProgressView().controlSize(.small)
                }
            }
            .padding()
            Divider()

            if started {
                ApplyResultsList(results: session.applyResults ?? [], isRunning: session.isApplying)
            } else {
                Form {
                    Text("""
                    This deletes every Intune object in this tenant that carries this app's \
                    identity tag ([IntuneDeployer:…] in the description) — across all \
                    supported types. Objects without the tag are never touched. This cannot \
                    be undone.
                    """)
                    .font(.callout)

                    TextField("Type the tenant profile name to confirm", text: $typedName, prompt: Text(profile.displayName))
                }
                .formStyle(.grouped)
            }

            Divider()
            HStack {
                Spacer()
                Button(started ? "Close" : "Cancel") { dismiss() }
                if !started {
                    Button("Delete Tagged Objects", role: .destructive) {
                        started = true
                        Task { await session.removeBaseline(profile: profile) }
                    }
                    .disabled(typedName != profile.displayName || session.isApplying)
                }
            }
            .padding()
        }
        .frame(width: 560, height: 380)
    }
}
