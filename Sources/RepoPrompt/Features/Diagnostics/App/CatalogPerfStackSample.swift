import Darwin
import Foundation
import RepoPromptProcess

/// Fixed self-only command, pipe-only output. Never log raw launch errors, stdout or stderr.
/// An inert /bin/sleep probe confirmed `sample -file /dev/stdout` delivers the call graph
/// through the pipe. Omitting -file would create a raw report in /tmp and is forbidden.
enum CatalogPerfStackSample {
    struct Input {
        private(set) var stdout = Data()
        private(set) var stderrBytes = 0
        private var pendingLineBytes = 0
        private(set) var failed = false

        mutating func append(_ data: Data, standardError: Bool) {
            guard !failed else { return }
            if standardError {
                stderrBytes += data.count
                failed = stderrBytes > 64 * 1024
                return // stderr is counted, never retained or parsed.
            }
            guard stdout.count + data.count <= 1024 * 1024 else { failed = true
                return
            }
            for byte in data {
                if byte == 10 { pendingLineBytes = 0 } else { pendingLineBytes += 1 }
                if pendingLineBytes > 8192 { failed = true
                    return
                }
            }
            stdout.append(data)
        }
    }

    static func capture(ticket: CatalogPerfStallWatchdog.Ticket) async -> Data? {
        guard ticket.isValid else { return nil }
        let child: SpawnedProcess
        do {
            child = try ProcessLauncher.spawn(
                command: "/usr/bin/sample",
                arguments: [String(getpid()), "1", "10", "-file", "/dev/stdout"],
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                workingDirectory: "/",
                purpose: .tool
            )
        } catch { return nil }
        try? child.stdin?.close()
        let observer = ChildProcessExitObserver.observe(pid: child.pid)
        defer {
            try? child.stdout.close()
            try? child.stderr.close()
        }
        let descriptors = [child.stdout.fileDescriptor, child.stderr.fileDescriptor]
        var configured = true
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFL)
            if flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0 { configured = false }
        }
        var input = Input()
        var eof = [false, false]
        let started = uptime()
        var outcome: ChildProcessExitObserver.Outcome?
        if configured {
            while ticket.isValid, !input.failed, uptime() - started < 3 {
                drain(descriptors: descriptors, eof: &eof, input: &input)
                outcome = await observer.wait(timeout: 0)
                if outcome != nil { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let succeeded = configured && ticket.isValid && !input.failed && outcome == .exited(.exited(code: 0))
        if !succeeded { ticket.cancel() }
        await ProcessTermination.terminateObservedProcessFamily(
            observer: observer, processGroupID: child.processGroupID,
            sigtermGrace: 0.1, sigkillGrace: 0.1
        )
        let drainStarted = uptime()
        while configured, !eof.allSatisfy(\.self), !input.failed, uptime() - drainStarted < 0.5 {
            drain(descriptors: descriptors, eof: &eof, input: &input)
            if !eof.allSatisfy(\.self) { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        // Close pipes even if exit notification/reap is delayed. Keep sole-reap ownership and
        // the watchdog admission occupied until actual settlement, never signal a reused PID.
        try? child.stdout.close()
        try? child.stderr.close()
        _ = await observer.wait()
        guard succeeded, ticket.isValid, !input.failed, eof.allSatisfy(\.self) else { return nil }
        return CatalogPerfStackArtifact.symbols(from: input.stdout)
    }

    private static func uptime() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private static func drain(descriptors: [Int32], eof: inout [Bool], input: inout Input) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        for index in descriptors.indices where !eof[index] {
            // Bound each nonblocking drain turn as well as cumulative allocation.
            for _ in 0 ..< 64 {
                let count = Darwin.read(descriptors[index], &buffer, buffer.count)
                if count > 0 {
                    input.append(Data(buffer.prefix(count)), standardError: index == 1)
                    if input.failed { return }
                } else if count == 0 {
                    eof[index] = true
                    break
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                } else {
                    // Unreadable pipes invalidate the capture.
                    input.append(Data(repeating: 0, count: 64 * 1024 + 1), standardError: true)
                    return
                }
            }
        }
    }
}
