import Foundation
import XCTest

/// Bounded async enter/release fence for deterministic concurrency tests.
///
/// Cancellation is sticky so a task cancelled before its continuation is registered cannot park
/// forever. Multiple entrants remain parked until the shared fence is released.
final class TestReleaseFence: @unchecked Sendable {
    private let name: String
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledWaiters = Set<UUID>()

    init(name: String = "test release fence") {
        self.name = name
    }

    func enterAndWait() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(continuation, waiterID: waiterID)
            }
        } onCancel: {
            cancel(waiterID: waiterID)
        }
    }

    @discardableResult
    func waitUntilEntered(
        timeout: TimeInterval = 10,
        failOnTimeout: Bool = true
    ) async -> Bool {
        if hasEntered { return true }
        do {
            try await AsyncTestWait.waitUntil(
                "\(name) entered",
                timeout: timeout
            ) {
                self.hasEntered
            }
            return true
        } catch {
            if failOnTimeout {
                XCTFail(error.localizedDescription)
            }
            return hasEntered
        }
    }

    func release() {
        condition.lock()
        released = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        cancelledWaiters.removeAll()
        condition.broadcast()
        condition.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }

    private var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>, waiterID: UUID) {
        condition.lock()
        entered = true
        condition.broadcast()
        if released || Task.isCancelled || cancelledWaiters.remove(waiterID) != nil {
            condition.unlock()
            continuation.resume()
        } else {
            continuations[waiterID] = continuation
            condition.unlock()
        }
    }

    private func cancel(waiterID: UUID) {
        condition.lock()
        let continuation = continuations.removeValue(forKey: waiterID)
        if continuation == nil {
            cancelledWaiters.insert(waiterID)
        }
        condition.broadcast()
        condition.unlock()
        continuation?.resume()
    }
}
