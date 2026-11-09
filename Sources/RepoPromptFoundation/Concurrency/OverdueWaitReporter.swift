import Foundation
import os

/// Diagnostics only: logs a wait that has outlived a threshold, so a hang names what it is waiting on.
/// The watcher is created only for waits that are already suspended, never changes their outcome,
/// and must be cancelled by the caller when the wait ends.
package enum OverdueWaitReporter {
    package static let defaultRepeatInterval: Duration = .seconds(300)

    private static let logger = Logger(subsystem: "com.pvncher.repoprompt.ce", category: "MCPWaitDiagnostics")

    /// - Parameter fields: evaluated lazily when a report is due; `nil` skips that report.
    package static func begin(
        event: String,
        threshold: Duration,
        repeatInterval: Duration = defaultRepeatInterval,
        fields: @escaping @Sendable () -> String?,
        report: @escaping @Sendable (String) -> Void = { line in
            logger.notice("\(line, privacy: .public)")
        }
    ) -> Task<Void, Never> {
        let started = ContinuousClock.now
        return Task.detached(priority: .utility) {
            var delay = threshold
            while true {
                do { try await Task.sleep(for: delay) } catch { return }
                delay = repeatInterval
                guard let fields = fields() else { continue }
                let components = started.duration(to: .now).components
                let waitMilliseconds = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
                report("mcp_wait_overdue event=\(event) wait_ms=\(waitMilliseconds) \(fields)")
            }
        }
    }
}
