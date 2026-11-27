import Foundation
import os
import RepoPromptShared

/// Per-call context for one window-exclusive mutation call. It carries release-visible stage
/// timings (log-only: tool name, server-generated IDs, durations; never paths or contents) and the
/// absolute pre-write wait deadline. The dispatcher creates one per call and installs it as a
/// task-local around provider invocation, so the edit host and workspace store can report their
/// stages without threading parameters through unrelated APIs.
package final class MCPDomainMutationCall: @unchecked Sendable {
    @TaskLocal package static var current: MCPDomainMutationCall?

    package enum Stage: String {
        case connectionLaneQueue = "queue.connection_lane"
        case windowLeaseQueue = "queue.window_lease"
        case lease
        case originalRead = "original_read"
        case gitSyncWait = "git_sync_wait"
        case write
    }

    package enum Outcome: String {
        case completed
        case expired
        case cancelled
        case failed
    }

    package struct Span {
        fileprivate let stage: Stage
        fileprivate let start: ContinuousClock.Instant
        fileprivate let detail: String?
    }

    package let invocationID: UUID
    package let toolName: String
    /// Absolute deadline shared by every pre-write wait of this call. Waits that cannot have
    /// started a mutation (admission queues, the Git-sync wait before the original read) give up
    /// here so the caller still receives a retryable answer before its own deadline.
    package let preWriteWaitDeadline: MCPDomainAdmissionDeadline
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var windowID: Int?

    private static let logger = Logger(subsystem: "com.repoprompt.ce", category: "MutationCall")

    package init(
        invocationID: UUID,
        toolName: String,
        watchdogEnvironment: MCPToolExecutionWatchdogEnvironment
    ) {
        self.invocationID = invocationID
        self.toolName = toolName
        origin = clock.now
        preWriteWaitDeadline = MCPDomainAdmissionDeadline(
            instant: watchdogEnvironment.now() + MCPTimeoutPolicy.mutationPreWriteWaitBudget,
            now: watchdogEnvironment.now,
            sleep: watchdogEnvironment.sleep
        )
    }

    package func setWindowID(_ windowID: Int?) {
        lock.withLock { self.windowID = windowID }
    }

    package func begin(_ stage: Stage, detail: String? = nil) -> Span {
        let span = Span(stage: stage, start: clock.now, detail: detail)
        emit(event: "begin", stage: stage, detail: detail, duration: nil, outcome: nil)
        return span
    }

    package func end(_ span: Span, _ outcome: Outcome) {
        emit(
            event: "end",
            stage: span.stage,
            detail: span.detail,
            duration: span.start.duration(to: clock.now),
            outcome: outcome
        )
    }

    private func emit(event: String, stage: Stage, detail: String?, duration: Duration?, outcome: Outcome?) {
        let elapsed = origin.duration(to: clock.now)
        let (sequence, windowID) = lock.withLock { () -> (UInt64, Int?) in
            self.sequence &+= 1
            return (self.sequence, self.windowID)
        }
        var line = "mutation_call event=\(event) stage=\(stage.rawValue) tool=\(toolName)"
            + " call=\(invocationID.uuidString) window=\(windowID.map(String.init) ?? "-")"
            + " seq=\(sequence) t_ms=\(Self.milliseconds(elapsed))"
        if let detail { line += " phase=\(detail)" }
        if let duration { line += " duration_ms=\(Self.milliseconds(duration))" }
        if let outcome { line += " outcome=\(outcome.rawValue)" }
        Self.logger.notice("\(line, privacy: .public)")
        #if DEBUG
            Self.debugObserverLock.withLock { Self.debugObserver }?(line)
        #endif
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }

    #if DEBUG
        private static let debugObserverLock = NSLock()
        private nonisolated(unsafe) static var debugObserver: (@Sendable (String) -> Void)?

        /// Test-only tap on the emitted log lines.
        package static func setDebugObserverForTesting(_ observer: (@Sendable (String) -> Void)?) {
            debugObserverLock.withLock { debugObserver = observer }
        }
    #endif
}
