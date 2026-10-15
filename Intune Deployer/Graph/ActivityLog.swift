import Foundation
import Observation

/// One logged Graph request. Never contains tokens, headers or payloads —
/// only method, path, status and timing.
nonisolated struct ActivityLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let method: String
    let path: String
    let status: Int?
    let duration: TimeInterval
    /// Short, non-sensitive note (e.g. "will retry (attempt 2)").
    let note: String?

    var isFailure: Bool { (status ?? 0) >= 400 || status == nil }
}

/// In-app activity log shown in its own window.
@MainActor
@Observable
final class ActivityLog {
    private(set) var entries: [ActivityLogEntry] = []
    private let maxEntries = 1000

    func append(_ entry: ActivityLogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
