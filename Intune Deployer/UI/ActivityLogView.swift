import SwiftUI

/// Separate window listing every Graph request (method, path, status, time).
struct ActivityLogView: View {
    @Environment(ActivityLog.self) private var log

    var body: some View {
        Table(log.entries.reversed()) {
            TableColumn("Time") { entry in
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .monospacedDigit()
            }
            .width(90)
            TableColumn("Method") { entry in
                Text(entry.method)
                    .font(.callout.monospaced())
            }
            .width(60)
            TableColumn("Path") { entry in
                Text(entry.path)
                    .font(.callout.monospaced())
                    .help(entry.path)
            }
            TableColumn("Status") { entry in
                Text(entry.status.map(String.init) ?? "—")
                    .foregroundStyle(entry.isFailure ? .red : .primary)
                    .monospacedDigit()
            }
            .width(50)
            TableColumn("Duration") { entry in
                Text(String(format: "%.2fs", entry.duration))
                    .monospacedDigit()
            }
            .width(70)
            TableColumn("Note") { entry in
                Text(entry.note ?? "")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if log.entries.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Graph requests appear here as they happen.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    log.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(log.entries.isEmpty)
            }
        }
        .navigationTitle("Activity Log")
    }
}
