import SwiftUI

/// Apply with two or more ticked deletions: the number of deletions is typed
/// before anything is written (ROADMAP step 8, decided by Jordy).
struct ApplyDeletionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let deletions: Int
    let tenant: String
    let apply: () -> Void

    @State private var typed = ""

    private var problem: String? {
        ApplyConfirmation.typingProblem(typed, deletions: deletions)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: "exclamationmark.triangle")
                    .font(.title3.bold())
                Spacer()
            }
            .padding()
            Divider()

            Form {
                Text("Changes are written to the tenant through Microsoft Graph and are not undone automatically.")
                    .font(.callout)
                Text(ApplyConfirmation.deletionLine(deletions: deletions, tenant: tenant))
                    .font(.callout.bold())
                // no Return shortcut: a destructive button is never the default (HIG)
                TextField("Type \(deletions) to confirm", text: $typed, prompt: Text(verbatim: "\(deletions)"))
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply", role: .destructive) {
                    dismiss()
                    apply()
                }
                .disabled(problem != nil)
                .help(problem ?? "")
            }
            .padding()
        }
        .frame(width: 520)
    }
}
