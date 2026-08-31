import Foundation

struct AsyncTestConditionTimeout: Error, LocalizedError {
    let description: String
    let timeout: TimeInterval

    var errorDescription: String? {
        "Timed out after \(timeout)s waiting for \(description)"
    }
}

enum AsyncTestWait {
    /// Bounded async wait for actor/debug state that has no explicit test signal.
    /// Uses exponential backoff so tests avoid scheduler spin while preserving a
    /// deterministic timeout diagnostic.
    static func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        initialDelayNanoseconds: UInt64 = 1_000_000,
        maximumDelayNanoseconds: UInt64 = 25_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        try await waitUntilThrowing(
            description,
            timeout: timeout,
            initialDelayNanoseconds: initialDelayNanoseconds,
            maximumDelayNanoseconds: maximumDelayNanoseconds,
            condition: condition
        )
    }

    static func waitUntilThrowing(
        _ description: String,
        timeout: TimeInterval = 3,
        initialDelayNanoseconds: UInt64 = 1_000_000,
        maximumDelayNanoseconds: UInt64 = 25_000_000,
        condition: @escaping () async throws -> Bool
    ) async throws {
        let timeoutDuration = Duration.seconds(max(0, timeout))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeoutDuration)
        let maximumDelay = max(1, min(maximumDelayNanoseconds, UInt64(Int64.max)))
        var delay = max(1, min(initialDelayNanoseconds, maximumDelay))

        while true {
            if try await condition() { return }
            let now = clock.now
            guard now < deadline else {
                throw AsyncTestConditionTimeout(description: description, timeout: timeout)
            }
            let sleepDeadline = min(
                deadline,
                now.advanced(by: .nanoseconds(Int64(delay)))
            )
            try await clock.sleep(until: sleepDeadline, tolerance: .zero)
            delay = min(delay > maximumDelay / 2 ? maximumDelay : delay * 2, maximumDelay)
        }
    }
}
