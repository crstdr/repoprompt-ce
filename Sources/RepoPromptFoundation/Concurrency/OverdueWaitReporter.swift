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

    /// Cancels the timer when the wait ends. `cancel()` is asynchronous by design (it may run under a
    /// caller's lock while a handler waits for that lock), so one report already in flight can still
    /// be written just after it returns.
    package final class Watch: @unchecked Sendable {
        fileprivate final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isCancelled: Bool { lock.withLock { value } }
            func cancel() { lock.withLock { value = true } }
        }

        private let timer: DispatchSourceTimer
        fileprivate let flag: Flag

        fileprivate init(timer: DispatchSourceTimer, flag: Flag) {
            self.timer = timer
            self.flag = flag
        }

        package func cancel() {
            flag.cancel()
            timer.cancel()
        }

        deinit {
            cancel()
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
        let flag = Watch.Flag()
        timer.setEventHandler {
            guard !flag.isCancelled, let fields = fields(), !flag.isCancelled else { return }
            let waitMilliseconds = milliseconds(started.duration(to: .now))
            report("mcp_wait_overdue event=\(event) wait_ms=\(waitMilliseconds) \(fields)")
        }
        timer.resume()
        return Watch(timer: timer, flag: flag)
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
