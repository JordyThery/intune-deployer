import SwiftUI

/// Apply with two or more ticked deletions: the number of deletions is typed
/// before anything is written (JTKit's rule for what can't be undone). Shown
/// at the bottom of the Plan sheet, in place of its buttons, rather than as
/// a sheet on top of it.
struct ApplyDeletionsConfirmation: View {
    let title: String
    let deletions: Int
    let tenant: String
    let cancel: () -> Void
    let apply: () -> Void

    @State private var typed = ""
    @FocusState private var isTyping: Bool

    private var problem: String? {
        ApplyConfirmation.typingProblem(typed, deletions: deletions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.headline)
            Text("Changes are written to the tenant through Microsoft Graph and are not undone automatically.")
                .font(.callout)
            Text(ApplyConfirmation.deletionLine(deletions: deletions, tenant: tenant))
                .font(.callout.bold())
            HStack {
                TextField("Type \(deletions) to confirm", text: $typed, prompt: Text(verbatim: "\(deletions)"))
                    .frame(maxWidth: 220)
                    .focused($isTyping)
                // why Apply is still dimmed, once something is typed
                if let problem, !typed.isEmpty {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                // no Return shortcut: a destructive button is never the default (HIG)
                Button("Apply", role: .destructive) { apply() }
                    .disabled(problem != nil)
                    .help(problem ?? "")
            }
        }
        .padding()
        .onAppear { isTyping = true }
    }
}
