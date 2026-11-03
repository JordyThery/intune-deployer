import Foundation

/// A run ended with Stop (a wait before a retry ended, JTKit's
/// `RequestWaits.cancelAll()`), said as one plain sentence everywhere:
/// Plan, Apply, Remove Baseline, Preflight, the inventory and export.
/// Swift's own text for a cancellation is never shown.
nonisolated enum Stopping {
    /// For a read or a step stopped part of the way.
    static let sentence = "Stopped before it finished."

    /// What a run that was stopped says about the steps it didn't send.
    static let rest = "Stopped. The remaining steps weren’t sent. Run Plan again to see what’s left."

    /// Whether the error is a stop, not a failure.
    static func isStop(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// An error as the app says it: the plain sentence for a stop, else its own text.
    static func describe(_ error: any Error) -> String {
        isStop(error) ? sentence : error.localizedDescription
    }
}
