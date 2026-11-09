import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class OverdueSettlementReports: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) {
            lock.withLock { lines.append(line) }
        }

        var count: Int {
            lock.withLock { lines.count }
        }

        var all: [String] {
            lock.withLock { lines }
        }

        /// A cancelled watch can still land one report that was already in flight, and no more.
        func assertSettled(
            after interval: Duration,
            atCancel: Int,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            try await Task.sleep(for: interval * 4)
            XCTAssertLessThanOrEqual(count, atCancel + 1, "\(all)", file: file, line: line)
        }

        func waitForFirstReport() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while count == 0 {
                guard ContinuousClock.now < deadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    final class MCPOverdueWaitSettlementTests: XCTestCase {
        private typealias Join = WorkspaceFileContextStore.ScopedIngressBarrierJoin

        private static let interval = Duration.milliseconds(60)

        private func makeJoin(_ reports: OverdueSettlementReports) -> Join {
            Join(
                rootID: UUID(),
                overdueThreshold: .milliseconds(30),
                overdueRepeatInterval: Self.interval,
                overdueReport: { reports.append($0) }
            )
        }

        private func output() -> WorkspaceFileContextStore.ScopedIngressBarrierTaskOutput {
            let sample = WorkspaceIngressBarrierSample(
                rootID: UUID(),
                rootPath: "/tmp/root",
                pendingRawEventCountBeforeFlush: 0,
                acceptedWatcherWatermark: 1,
                publishedServicePublicationSequence: 1,
                appliedServicePublicationSequence: 1,
                appliedWatcherWatermark: 1
            )
            return .init(sample: sample, completedAtNanoseconds: 0)
        }

        func testIngressJoinCompletionStopsReporting() async throws {
            let reports = OverdueSettlementReports()
            let join = makeJoin(reports)
            let waiter = Task { await join.value() }
            try await reports.waitForFirstReport()
            XCTAssertTrue(reports.all[0].contains("event=root_ingress"), "\(reports.all)")

            join.complete(with: output())
            let result = await waiter.value
            XCTAssertNotNil(result)
            try await reports.assertSettled(after: Self.interval, atCancel: reports.count)
        }

        func testIngressJoinCancellationStopsReporting() async throws {
            let reports = OverdueSettlementReports()
            let join = makeJoin(reports)
            let waiter = Task { await join.value() }
            try await reports.waitForFirstReport()

            waiter.cancel()
            let result = await waiter.value
            XCTAssertNil(result)
            try await reports.assertSettled(after: Self.interval, atCancel: reports.count)
        }

        func testCancelledCallerOnCompletedIngressJoinGetsNil() async {
            let join = Join(rootID: UUID())
            join.complete(with: output())
            let caller = Task {
                while !Task.isCancelled {
                    await Task.yield()
                }
                return await join.value()
            }
            caller.cancel()
            let result = await caller.value
            XCTAssertNil(result, "a cancelled caller keeps the base precedence: cancellation before completion")

            let uncancelled = await join.value()
            XCTAssertNotNil(uncancelled)
        }
    }
#endif
