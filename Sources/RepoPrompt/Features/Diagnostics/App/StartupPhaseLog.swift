import Darwin
import Foundation
import os

/// Always-on, low-volume startup phase timing for launch-latency diagnosis.
///
/// Emits one line per phase boundary (`begin`/`end`) or point event (`event`) to the
/// unified log at default level, with milliseconds elapsed since process exec, so a slow
/// launch can be attributed across the pre-window path without Instruments:
///
///     log show --style compact --last 15m \
///         --predicate 'processID == <pid> AND category == "Startup"'
///
/// Marker content is restricted to phase names, durations, window ordinals and counts.
/// No paths, workspace or chat names, identifiers or other user data are emitted.
enum StartupPhaseLog {
    /// Static phase identifiers; new phases are added here, never interpolated at call sites.
    enum Phase: String, CaseIterable {
        case bootstrap
        case appInit
        case windowComposition
        case workspaceCorpusLoad
        case authorityBootstrapWait
        case bridgeInitialProjection
        case windowAttached
        case windowAppeared
        case restoreEntryAssigned
        case restoreWorkspace
    }

    /// Clock and emission seam; tests substitute a scripted clock and a capture sink.
    struct Runtime {
        var uptime: @Sendable () -> TimeInterval
        var processStartUptime: TimeInterval
        var emit: @Sendable (String) -> Void
    }

    /// A `begin` boundary's token; `end` emits the matching `end` line with `span_ms`.
    struct Span {
        let phase: Phase
        let window: Int?
        let startUptime: TimeInterval
        let runtime: Runtime

        /// Emits the `end` marker. `fields` keys are restricted to `[A-Za-z0-9_]` and
        /// values are integers, so nothing user-identifying can reach the log.
        func end(extraFields: [String: Int] = [:]) {
            let now = runtime.uptime()
            runtime.emit(
                StartupPhaseLog.render(
                    phase: phase,
                    boundary: "end",
                    window: window,
                    elapsedMS: StartupPhaseLog.elapsedMilliseconds(
                        now: now, processStart: runtime.processStartUptime
                    ),
                    spanMS: StartupPhaseLog.spanMilliseconds(from: startUptime, to: now),
                    fields: extraFields
                )
            )
        }
    }

    private static let logger = Logger(subsystem: "com.pvncher.repoprompt.ce", category: "Startup")

    private static let productionRuntime = Runtime(
        uptime: { ProcessInfo.processInfo.systemUptime },
        processStartUptime: processStartUptime(),
        emit: { message in logger.log("\(message, privacy: .public)") }
    )

    private static func runtime() -> Runtime {
        #if DEBUG
            stateLock.lock()
            defer { stateLock.unlock() }
            return testingRuntime ?? productionRuntime
        #else
            return productionRuntime
        #endif
    }

    static func mark(_ phase: Phase, window: Int? = nil, fields: [String: Int] = [:]) {
        let runtime = runtime()
        runtime.emit(
            render(
                phase: phase,
                boundary: "event",
                window: window,
                elapsedMS: elapsedMilliseconds(now: runtime.uptime(), processStart: runtime.processStartUptime),
                spanMS: nil,
                fields: fields
            )
        )
    }

    static func begin(_ phase: Phase, window: Int? = nil) -> Span {
        let runtime = runtime()
        let startUptime = runtime.uptime()
        runtime.emit(
            render(
                phase: phase,
                boundary: "begin",
                window: window,
                elapsedMS: elapsedMilliseconds(now: startUptime, processStart: runtime.processStartUptime),
                spanMS: nil,
                fields: [:]
            )
        )
        return Span(phase: phase, window: window, startUptime: startUptime, runtime: runtime)
    }

    static func elapsedMilliseconds(now: TimeInterval, processStart: TimeInterval) -> Int {
        Int(max(0, (now - processStart) * 1000).rounded())
    }

    static func spanMilliseconds(from start: TimeInterval, to end: TimeInterval) -> Int {
        Int(max(0, (end - start) * 1000).rounded())
    }

    static func render(
        phase: Phase,
        boundary: String,
        window: Int?,
        elapsedMS: Int,
        spanMS: Int?,
        fields: [String: Int]
    ) -> String {
        var parts = ["phase=\(phase.rawValue)", "boundary=\(boundary)"]
        if let window {
            parts.append("window=\(window)")
        }
        parts.append("elapsed_ms=\(elapsedMS)")
        if let spanMS {
            parts.append("span_ms=\(spanMS)")
        }
        for key in fields.keys.sorted() {
            let sanitized = sanitizeFieldKey(key)
            guard !sanitized.isEmpty, let value = fields[key] else { continue }
            parts.append("\(sanitized)=\(value)")
        }
        return parts.joined(separator: " ")
    }

    private static func sanitizeFieldKey(_ key: String) -> String {
        String(key.filter { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    /// Wall-clock process start converted to the `systemUptime` timebase so `elapsed_ms`
    /// covers dyld and early runtime work before `main`, keeping it comparable with the
    /// LaunchServices check-in times recorded by external startup profiles.
    static func processStartUptime(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            return nowUptime
        }
        let startWall = TimeInterval(info.kp_proc.p_starttime.tv_sec)
            + TimeInterval(info.kp_proc.p_starttime.tv_usec) / 1_000_000
        return nowUptime - max(0, Date().timeIntervalSince1970 - startWall)
    }

    #if DEBUG
        private static let stateLock = NSLock()
        private static var testingRuntime: Runtime?

        static func installForTesting(_ runtime: Runtime) {
            stateLock.lock()
            testingRuntime = runtime
            stateLock.unlock()
        }

        static func resetForTesting() {
            stateLock.lock()
            testingRuntime = nil
            stateLock.unlock()
        }
    #endif
}
