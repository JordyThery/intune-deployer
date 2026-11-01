import SwiftUI

/// Deletes the tenant profile's own objects in the tenant: it first counts
/// them, then asks for the tenant profile's name, and deletes only what it
/// counted.
struct RemoveBaselineView: View {
    @Environment(TenantSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let profile: TenantProfile

    @State private var typedName = ""
    @State private var started = false
    @State private var counted: TenantSession.RemovalCount?
    private var objectCount: Int? { counted?.count }
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
                    This deletes the objects this tenant profile deployed (its profile tag, or \
                    its naming prefix for older objects), the template filters it created and \
                    its empty groups. Other profiles’ objects and untagged objects are never \
                    touched. This can’t be undone.
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
                    .keyboardShortcut(.cancelAction)
                if !started {
                    Button("Delete Tagged Objects", role: .destructive) {
                        started = true
                        Task { await session.removeBaseline(profile: profile, counted: counted) }
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
                Label("Couldn’t count the objects.", systemImage: "exclamationmark.triangle.fill")
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
                Text("Counting the objects this tenant profile deployed…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func count() async {
        counted = nil
        countError = nil
        do {
            counted = try await session.removalCount(profile: profile)
        } catch {
            countError = error.localizedDescription
        }
    }
}
