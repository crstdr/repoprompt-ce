import Foundation
import os
import RepoPromptFoundation

package enum MCPDomainToolAdmissionLimits {
    package static let exclusiveConnection = 1
    package static let controlConnection = 8
    package static let smallReadConnection = 2
    package static let smallReadPerWindow = 2
    package static let fileReadConnection = ContentReadConcurrencyCapacity.maximumConcurrentReads
    package static let fileReadPerWindow = ContentReadConcurrencyCapacity.maximumConcurrentReads
    package static let gitReadConnection = 2
    package static let fileSearchConnection = 4
    package static let gitReadPerRepository = 1
}

/// Protocol-neutral, cancellation-safe admission keyed by the physical state resource.
/// Connection lanes provide client ordering; this controller bounds cross-connection work.
package final class MCPDomainToolResourceAdmissionController: @unchecked Sendable {
    package enum AdmissionError: Error, Equatable, Sendable {
        case closed
    }

    package struct Snapshot: Equatable, Sendable {
        package let activeLeaseCount: Int
        package let waiterCount: Int
        package let isClosed: Bool
    }

    package enum Resource: Hashable, Sendable {
        case appWide
        case window(Int)
        case repository(String)
    }

    /// Opaque identifiers for the call that waits for, or holds, a lease. Logged only when a wait is overdue.
    package struct WaitContext: Equatable, Sendable {
        package let tool: String
        package let connection: String
        package let run: String?

        package init(tool: String, connection: String, run: String?) {
            self.tool = tool
            self.connection = connection
            self.run = run
        }
    }

    package final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseAction: (() -> Void)?

        fileprivate init(releaseAction: @escaping () -> Void) {
            self.releaseAction = releaseAction
        }

        @discardableResult
        package func release() -> Bool {
            let action: (() -> Void)? = lock.withLock {
                defer { releaseAction = nil }
                return releaseAction
            }
            action?()
            return action != nil
        }

        deinit {
            release()
        }
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Lease, Error>
        let context: WaitContext?
        let overdueWatcher: OverdueWaitReporter.Watch?
    }

    private struct Holder {
        let resource: Resource
        let context: WaitContext
        let acquiredAt: ContinuousClock.Instant
        var lastReportedAt: ContinuousClock.Instant?
    }

    package let limit: Int
    private let lock = NSLock()
    private var activeCountByResource: [Resource: Int] = [:]
    private var waitersByResource: [Resource: [Waiter]] = [:]
    private var resourceByWaiterID: [UUID: Resource] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []
    private var isClosed = false
    private var holdersByLeaseID: [UUID: Holder] = [:]
    private let overdueThreshold: Duration?
    private let overdueRepeatInterval: Duration
    private let overdueReport: @Sendable (String) -> Void

    /// A non-nil `overdueThreshold` logs waiters that carry a `WaitContext` once they have waited that long.
    package init(
        limit: Int,
        overdueThreshold: Duration? = nil,
        overdueRepeatInterval: Duration = OverdueWaitReporter.defaultRepeatInterval,
        overdueReport: (@Sendable (String) -> Void)? = nil
    ) {
        precondition(limit > 0)
        self.limit = limit
        self.overdueThreshold = overdueThreshold
        self.overdueRepeatInterval = overdueRepeatInterval
        self.overdueReport = overdueReport ?? { line in
            Self.logger.notice("\(line, privacy: .public)")
        }
    }

    private static let logger = Logger(subsystem: "com.pvncher.repoprompt.ce", category: "MCPWaitDiagnostics")

    package func acquire(
        _ resource: Resource,
        context: WaitContext? = nil,
        admissionDeadline: MCPDomainAdmissionDeadline? = nil
    ) async throws -> Lease {
        guard let admissionDeadline else {
            return try await acquireWithoutDeadline(resource, context: context)
        }
        try admissionDeadline.check()
        return try await withThrowingTaskGroup(of: Lease.self) { group in
            group.addTask {
                try await self.acquireWithoutDeadline(resource, context: context)
            }
            group.addTask {
                try await admissionDeadline.waitUntilExpired()
            }
            do {
                guard let lease = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                try? await group.waitForAll()
                do {
                    try admissionDeadline.check()
                    return lease
                } catch {
                    lease.release()
                    throw error
                }
            } catch {
                group.cancelAll()
                try? await group.waitForAll()
                throw error
            }
        }
    }

    private func acquireWithoutDeadline(_ resource: Resource, context: WaitContext?) async throws -> Lease {
        try Task.checkCancellation()

        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediateResult: Result<Lease, Error>? = lock.withLock {
                    if cancelledWaiterIDs.remove(waiterID) != nil || Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard !isClosed else {
                        return .failure(AdmissionError.closed)
                    }
                    guard canAcquire(resource), waitersByResource[resource]?.isEmpty != false else {
                        let waiter = Waiter(
                            id: waiterID,
                            continuation: continuation,
                            context: context,
                            overdueWatcher: startOverdueWatcher(waiterID: waiterID, resource: resource, context: context)
                        )
                        waitersByResource[resource, default: []].append(waiter)
                        resourceByWaiterID[waiterID] = resource
                        return nil
                    }
                    activate(resource)
                    return .success(makeLease(for: resource, context: context))
                }
                if let immediateResult {
                    continuation.resume(with: immediateResult)
                }
            }
        } onCancel: {
            self.cancelWaiter(waiterID)
        }

        do {
            try Task.checkCancellation()
            return lease
        } catch {
            _ = lock.withLock { cancelledWaiterIDs.remove(waiterID) }
            lease.release()
            throw error
        }
    }

    package func activeCount(for resource: Resource) -> Int {
        lock.withLock { activeCountByResource[resource] ?? 0 }
    }

    package func waiterCount(for resource: Resource) -> Int {
        lock.withLock { waitersByResource[resource]?.count ?? 0 }
    }

    package func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                activeLeaseCount: activeCountByResource.values.reduce(0, +),
                waiterCount: resourceByWaiterID.count,
                isClosed: isClosed
            )
        }
    }

    @discardableResult
    package func close() -> Int {
        let waiters: [Waiter] = lock.withLock {
            guard !isClosed else { return [] }
            isClosed = true
            let waiters = waitersByResource.values.flatMap(\.self)
            waitersByResource.removeAll()
            resourceByWaiterID.removeAll()
            cancelledWaiterIDs.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.overdueWatcher?.cancel()
            waiter.continuation.resume(throwing: AdmissionError.closed)
        }
        return waiters.count
    }

    private func canAcquire(_ resource: Resource) -> Bool {
        (activeCountByResource[resource] ?? 0) < limit
    }

    private func activate(_ resource: Resource) {
        activeCountByResource[resource, default: 0] += 1
    }

    /// Called with `lock` held.
    private func makeLease(for resource: Resource, context: WaitContext?) -> Lease {
        var leaseID: UUID?
        if let context {
            let id = UUID()
            holdersByLeaseID[id] = Holder(resource: resource, context: context, acquiredAt: .now)
            leaseID = id
        }
        return Lease { [weak self] in
            self?.release(resource, leaseID: leaseID)
        }
    }

    private func release(_ resource: Resource, leaseID: UUID?) {
        let handoffs: [(CheckedContinuation<Lease, Error>, Lease)] = lock.withLock {
            if let leaseID { holdersByLeaseID.removeValue(forKey: leaseID) }
            let nextCount = max(0, (activeCountByResource[resource] ?? 0) - 1)
            if nextCount == 0 {
                activeCountByResource.removeValue(forKey: resource)
            } else {
                activeCountByResource[resource] = nextCount
            }

            var handoffs: [(CheckedContinuation<Lease, Error>, Lease)] = []
            while !isClosed, canAcquire(resource), var waiters = waitersByResource[resource], !waiters.isEmpty {
                let next = waiters.removeFirst()
                resourceByWaiterID.removeValue(forKey: next.id)
                if waiters.isEmpty {
                    waitersByResource.removeValue(forKey: resource)
                } else {
                    waitersByResource[resource] = waiters
                }
                activate(resource)
                next.overdueWatcher?.cancel()
                handoffs.append((next.continuation, makeLease(for: resource, context: next.context)))
            }
            return handoffs
        }
        for handoff in handoffs {
            handoff.0.resume(returning: handoff.1)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        let continuation: CheckedContinuation<Lease, Error>? = lock.withLock {
            guard let resource = resourceByWaiterID.removeValue(forKey: waiterID),
                  var waiters = waitersByResource[resource],
                  let index = waiters.firstIndex(where: { $0.id == waiterID })
            else {
                if !isClosed {
                    cancelledWaiterIDs.insert(waiterID)
                }
                return nil
            }

            let waiter = waiters.remove(at: index)
            waiter.overdueWatcher?.cancel()
            if waiters.isEmpty {
                waitersByResource.removeValue(forKey: resource)
            } else {
                waitersByResource[resource] = waiters
            }
            return waiter.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    /// Called with `lock` held, for a waiter that is about to be queued.
    private func startOverdueWatcher(waiterID: UUID, resource: Resource, context: WaitContext?) -> OverdueWaitReporter.Watch? {
        guard let overdueThreshold, let context else { return nil }
        return OverdueWaitReporter.begin(
            event: "admission",
            threshold: overdueThreshold,
            repeatInterval: overdueRepeatInterval,
            fields: { [weak self] in
                self?.overdueFields(waiterID: waiterID, resource: resource, waiter: context)
            },
            report: overdueReport
        )
    }

    /// The waiter's report, or `nil` when it is no longer queued or every tracked holder was reported recently.
    /// With no tracked holder it always reports, since that is the lost-wakeup or untracked-holder shape.
    private func overdueFields(waiterID: UUID, resource: Resource, waiter: WaitContext) -> String? {
        let now = ContinuousClock.now
        return lock.withLock {
            guard resourceByWaiterID[waiterID] != nil else { return nil }
            let active = activeCountByResource[resource] ?? 0
            let tracked = holdersByLeaseID.filter { $0.value.resource == resource }
            let due = tracked.filter { _, holder in
                holder.lastReportedAt.map { $0.duration(to: now) >= overdueRepeatInterval } != false
            }
            guard tracked.isEmpty || !due.isEmpty else { return nil }
            var fields = "resource=\(Self.describe(resource)) waiter_tool=\(waiter.tool) waiter_conn=\(waiter.connection)"
                + " waiter_run=\(waiter.run ?? "-") waiters=\(waitersByResource[resource]?.count ?? 0)"
                + " holders=\(tracked.isEmpty ? "untracked" : String(due.count)) active=\(active)"
            if !tracked.isEmpty, active > tracked.count {
                fields += " untracked_holders=\(active - tracked.count)"
            }
            for (index, entry) in due.sorted(by: { $0.value.acquiredAt < $1.value.acquiredAt }).enumerated() {
                holdersByLeaseID[entry.key]?.lastReportedAt = now
                let holder = entry.value
                let age = holder.acquiredAt.duration(to: now).components
                fields += " holder\(index)_tool=\(holder.context.tool) holder\(index)_conn=\(holder.context.connection)"
                    + " holder\(index)_run=\(holder.context.run ?? "-") holder\(index)_phase=unknown"
                    + " holder\(index)_age_ms=\(age.seconds * 1000 + age.attoseconds / 1_000_000_000_000_000)"
            }
            return fields
        }
    }

    private static func describe(_ resource: Resource) -> String {
        switch resource {
        case .appWide: "app"
        case let .window(id): "window:\(id)"
        case .repository: "repository"
        }
    }
}
