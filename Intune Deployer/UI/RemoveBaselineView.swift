import SwiftUI

/// Deletes every object tagged by this app in the tenant. It first counts
/// them, then asks for the tenant's display name.
struct RemoveBaselineView: View {
    @Environment(TenantSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let profile: TenantProfile

    @State private var typedName = ""
    @State private var started = false
    @State private var objectCount: Int?
    @State private var countError: String?

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

                    countRow

                    TextField("Type the tenant profile name to confirm", text: $typedName, prompt: Text(profile.displayName))
                        .disabled((objectCount ?? 0) == 0)
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
                    .disabled(!RemoveBaselineConfirmation.canDelete(typedName: typedName, profileName: profile.displayName,
                                                                    isApplying: session.isApplying, objectCount: objectCount))
                }
            }
            .padding()
        }
        .frame(width: 560, height: 400)
        .task { await count() }
    }

    /// How many objects go, before anything is typed.
    @ViewBuilder
    private var countRow: some View {
        if let objectCount {
            Text(RemoveBaselineConfirmation.countLine(objectCount))
                .font(.callout.bold())
        } else if let countError {
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn’t count the tagged objects.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                Text(countError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Count Again") { Task { await count() } }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Counting the objects this app created…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func count() async {
        objectCount = nil
        countError = nil
        do {
            objectCount = try await session.taggedObjectCount(profile: profile)
        } catch {
            countError = error.localizedDescription
        }
    }
}
