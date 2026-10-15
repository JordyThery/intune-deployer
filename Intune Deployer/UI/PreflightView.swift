import SwiftUI

/// Read-only tenant readiness checklist.
struct PreflightView: View {
    @Environment(TenantSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let profile: TenantProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Preflight — \(profile.displayName)", systemImage: "checklist")
                    .font(.title3.bold())
                Spacer()
                if session.isRunningPreflight {
                    ProgressView().controlSize(.small)
                }
            }
            .padding()

            Divider()

            if let checks = session.preflightChecks {
                List(checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.status.symbolName)
                            .foregroundStyle(color(for: check.status))
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.title).font(.headline)
                            Text(check.message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if let guidance = check.guidance {
                                Text(guidance)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let link = check.link {
                                Link(link.host() ?? link.absoluteString, destination: link)
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else if session.isRunningPreflight {
                Spacer()
                ProgressView("Running checks…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ContentUnavailableView(
                    "No Checks Run Yet",
                    systemImage: "checklist",
                    description: Text("Run preflight to verify this tenant is ready for deployment.")
                )
            }

            Divider()
            HStack {
                Button("Run Again") {
                    Task { await session.runPreflight(for: profile) }
                }
                .disabled(session.isRunningPreflight)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 480)
        .task {
            if session.preflightChecks == nil {
                await session.runPreflight(for: profile)
            }
        }
    }

    private func color(for status: PreflightCheck.Status) -> Color {
        switch status {
        case .ok: .green
        case .warning: .yellow
        case .failed: .red
        }
    }
}
