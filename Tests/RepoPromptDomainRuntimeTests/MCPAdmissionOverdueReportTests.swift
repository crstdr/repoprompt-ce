import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

private func context(
    _ tool: String,
    _ connection: String,
    run: String? = nil
) -> MCPDomainToolResourceAdmissionController.WaitContext {
    .init(tool: tool, connection: connection, run: run)
}

final class MCPAdmissionOverdueReportTests: XCTestCase {
    private typealias Controller = MCPDomainToolResourceAdmissionController

    private static let interval = Duration.milliseconds(60)

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) {
            lock.withLock { lines.append(line) }
        }

        var all: [String] {
            lock.withLock { lines }
        }
    }

    private struct Timeout: Error, CustomStringConvertible {
        let description: String
    }

    private func makeController(
        _ reports: Reports,
        limit: Int = 1,
        threshold: Duration = .milliseconds(30),
        interval: Duration = MCPAdmissionOverdueReportTests.interval
    ) -> Controller {
        Controller(
            limit: limit,
            overdueThreshold: threshold,
            overdueRepeatInterval: interval,
            overdueReport: { reports.append($0) }
        )
    }

    private func waitUntil(_ description: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Timeout(description: "timed out: \(description())") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForWaiters(_ controller: Controller, _ resource: Controller.Resource, count: Int) async throws {
        try await waitUntil("\(count) queued waiter(s)") { controller.waiterCount(for: resource) == count }
    }

    private func waitForReports(_ reports: Reports, where predicate: @escaping (String) -> Bool) async throws {
        try await waitUntil("a matching report in \(reports.all)") { reports.all.contains(where: predicate) }
    }

    /// Call after the wait has ended and the cancel has returned. The flag is set before the timer is
    /// cancelled, so at most one report that was already in flight can still land; any further line means
    /// the timer kept running. Independent of scheduling delays.
    private func assertSilent(_ reports: Reports, file: StaticString = #filePath, line: UInt = #line) async throws {
        let atCancel = reports.all.count
        try await Task.sleep(for: Self.interval * 4)
        XCTAssertLessThanOrEqual(reports.all.count, atCancel + 1, "\(reports.all)", file: file, line: line)
    }

    func testOverdueWaiterNamesHolderAndRepeatsEveryIntervalUntilRelease() async throws {
        let reports = Reports()
        let controller = makeController(reports)
        let holder = try await controller.acquire(.window(3), context: context("file_actions", "aaaaaaaa", run: "bbbbbbbb"))
        let waiter = Task { try await controller.acquire(.window(3), context: context("apply_edits", "cccccccc")) }

        try await waitUntil("two reports") { reports.all.count >= 2 }
        for line in reports.all.prefix(2) {
            XCTAssertTrue(line.contains("event=admission"), line)
            XCTAssertTrue(line.contains("resource=window:3"), line)
            XCTAssertTrue(line.contains("waiter_tool=apply_edits waiter_conn=cccccccc waiter_run=-"), line)
            XCTAssertTrue(line.contains("holders=1 active=1"), line)
            XCTAssertTrue(
                line.contains("holder0_tool=file_actions holder0_conn=aaaaaaaa holder0_run=bbbbbbbb"),
                line
            )
        }

        holder.release()
        let granted = try await waiter.value
        XCTAssertEqual(controller.activeCount(for: .window(3)), 1)
        try await assertSilent(reports)
        granted.release()
        XCTAssertEqual(controller.activeCount(for: .window(3)), 0)
    }

    func testUntrackedHolderStillReportsTheWaiter() async throws {
        let reports = Reports()
        let controller = makeController(reports)
        let holder = try await controller.acquire(.window(2))
        let waiter = Task { try await controller.acquire(.window(2), context: context("file_actions", "dddddddd")) }

        try await waitForReports(reports) { $0.contains("holders=untracked active=1") && $0.contains("waiter_tool=file_actions") }

        holder.release()
        try await waiter.value.release()
    }

    func testMixedTrackedAndUntrackedHoldersAreCounted() async throws {
        let reports = Reports()
        let controller = makeController(reports, limit: 2)
        let untracked = try await controller.acquire(.window(1))
        let tracked = try await controller.acquire(.window(1), context: context("prompt", "aaaaaaaa"))
        let waiter = Task { try await controller.acquire(.window(1), context: context("apply_edits", "bbbbbbbb")) }

        try await waitForReports(reports) {
            $0.contains("holders=1 active=2 untracked_holders=1") && $0.contains("holder0_tool=prompt")
        }

        untracked.release()
        let granted = try await waiter.value
        granted.release()
        tracked.release()
    }

    func testEveryStuckWaiterIsNamed() async throws {
        let reports = Reports()
        let controller = makeController(reports)
        let holder = try await controller.acquire(.window(1), context: context("prompt", "aaaaaaaa"))
        let first = Task { try await controller.acquire(.window(1), context: context("apply_edits", "bbbbbbbb")) }
        try await waitForWaiters(controller, .window(1), count: 1)
        let second = Task { try await controller.acquire(.window(1), context: context("file_actions", "cccccccc")) }
        try await waitForWaiters(controller, .window(1), count: 2)

        try await waitForReports(reports) { $0.contains("waiter_tool=apply_edits") && $0.contains("holder0_tool=prompt") }
        try await waitForReports(reports) { $0.contains("waiter_tool=file_actions") && $0.contains("holder0_tool=prompt") }

        holder.release()
        let firstLease = try await first.value
        firstLease.release()
        try await second.value.release()
    }

    func testCancelledAndClosedWaitersStopReporting() async throws {
        // Cancelled before the first report.
        let early = Reports()
        let earlyController = makeController(early, threshold: .seconds(3600))
        let earlyHolder = try await earlyController.acquire(.window(1), context: context("prompt", "aaaaaaaa"))
        let earlyWaiter = Task { try await earlyController.acquire(.window(1), context: context("apply_edits", "bbbbbbbb")) }
        try await waitForWaiters(earlyController, .window(1), count: 1)
        earlyWaiter.cancel()
        _ = try? await earlyWaiter.value
        XCTAssertEqual(earlyController.waiterCount(for: .window(1)), 0)
        XCTAssertTrue(early.all.isEmpty, "\(early.all)")
        earlyHolder.release()

        // Cancelled after reporting.
        let late = Reports()
        let lateController = makeController(late)
        let lateHolder = try await lateController.acquire(.window(1), context: context("prompt", "aaaaaaaa"))
        let lateWaiter = Task { try await lateController.acquire(.window(1), context: context("apply_edits", "bbbbbbbb")) }
        try await waitUntil("a report") { !late.all.isEmpty }
        lateWaiter.cancel()
        _ = try? await lateWaiter.value
        try await assertSilent(late)
        lateHolder.release()

        // Closed after reporting.
        let closed = Reports()
        let closedController = makeController(closed)
        let closedHolder = try await closedController.acquire(.window(1), context: context("prompt", "aaaaaaaa"))
        let closedWaiter = Task { try await closedController.acquire(.window(1), context: context("apply_edits", "bbbbbbbb")) }
        try await waitUntil("a report") { !closed.all.isEmpty }
        closedController.close()
        _ = try? await closedWaiter.value
        try await assertSilent(closed)
        closedHolder.release()
    }

    func testHandoffReportsTheNewHolder() async throws {
        let reports = Reports()
        let controller = makeController(reports)
        let first = try await controller.acquire(.window(1), context: context("prompt", "aaaaaaaa"))
        let second = Task { try await controller.acquire(.window(1), context: context("file_actions", "bbbbbbbb")) }
        try await waitForWaiters(controller, .window(1), count: 1)
        let third = Task { try await controller.acquire(.window(1), context: context("apply_edits", "cccccccc")) }
        try await waitForWaiters(controller, .window(1), count: 2)

        try await waitForReports(reports) { $0.contains("waiter_tool=apply_edits") && $0.contains("holder0_tool=prompt") }

        first.release()
        let secondLease = try await second.value
        // Only a hand-off can make a report name `file_actions` as the holder.
        try await waitForReports(reports) {
            $0.contains("waiter_tool=apply_edits") && $0.contains("holders=1 active=1") && $0.contains("holder0_tool=file_actions")
        }

        for line in reports.all {
            let age = try XCTUnwrap(line.range(of: "holder0_age_ms=").map { line[$0.upperBound...].prefix { $0.isNumber || $0 == "-" } })
            XCTAssertGreaterThanOrEqual(Int(age) ?? -1, 0, line)
        }

        secondLease.release()
        let thirdLease = try await third.value
        try await assertSilent(reports)
        thirdLease.release()
    }

    func testUncontendedAndContextFreeAcquisitionsNeverReport() async throws {
        let reports = Reports()
        let controller = makeController(reports, threshold: .milliseconds(20))
        let lease = try await controller.acquire(.appWide, context: context("prompt", "dddddddd"))
        lease.release()
        let untracked = try await controller.acquire(.appWide)
        let waiter = Task { try await controller.acquire(.appWide) }
        try await waitForWaiters(controller, .appWide, count: 1)
        try await Task.sleep(for: .milliseconds(150))
        untracked.release()
        try await waiter.value.release()
        XCTAssertTrue(reports.all.isEmpty, "\(reports.all)")
    }
}
