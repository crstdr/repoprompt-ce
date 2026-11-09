import Dispatch
import Foundation
import os

/// Diagnostics only: logs a wait that has outlived a threshold, so a hang names what it is waiting on.
/// The timer runs on a dedicated dispatch queue, not the Swift cooperative pool, so it still fires when
/// that pool is starved and leaves nothing scheduled once cancelled. It is created only for waits that
/// are already suspended, never changes their outcome, and must be cancelled by the caller when the
/// wait ends.
package enum OverdueWaitReporter {
    package static let defaultRepeatInterval: Duration = .seconds(300)

    private static let logger = Logger(subsystem: "com.pvncher.repoprompt.ce", category: "MCPWaitDiagnostics")
    private static let queue = DispatchQueue(label: "com.pvncher.repoprompt.ce.wait-diagnostics", qos: .utility)

    package final class Watch: @unchecked Sendable {
        private let timer: DispatchSourceTimer

        fileprivate init(timer: DispatchSourceTimer) {
            self.timer = timer
        }

        package func cancel() {
            timer.cancel()
        }
    }

    /// - Parameter fields: evaluated lazily when a report is due; `nil` skips that report.
    package static func begin(
        event: String,
        threshold: Duration,
        repeatInterval: Duration = defaultRepeatInterval,
        fields: @escaping @Sendable () -> String?,
        report: @escaping @Sendable (String) -> Void = { line in
            logger.notice("\(line, privacy: .public)")
        }
    ) -> Watch {
        let started = ContinuousClock.now
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let thresholdNanoseconds = nanoseconds(threshold)
        timer.schedule(
            deadline: .now() + .nanoseconds(thresholdNanoseconds),
            repeating: .nanoseconds(nanoseconds(repeatInterval)),
            leeway: .nanoseconds(min(1_000_000_000, thresholdNanoseconds / 4))
        )
        timer.setEventHandler {
            guard !timer.isCancelled, let fields = fields() else { return }
            let waitMilliseconds = milliseconds(started.duration(to: .now))
            report("mcp_wait_overdue event=\(event) wait_ms=\(waitMilliseconds) \(fields)")
        }
        timer.resume()
        return Watch(timer: timer)
    }

    private static func nanoseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(clamping: components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000)
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }
}
