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

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    private func makeController(
        _ reports: Reports,
        threshold: Duration = .milliseconds(30),
        interval: Duration = .seconds(60)
    ) -> Controller {
        Controller(
            limit: 1,
            overdueThreshold: threshold,
            overdueRepeatInterval: interval,
            overdueReport: { reports.append($0) }
        )
    }

    private func waitForReports(_ reports: Reports, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while reports.all.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(reports.all.count, count, "\(reports.all)")
    }

    func testOverdueWaiterReportsHolderOncePerIntervalAndStopsAfterRelease() async throws {
        let reports = Reports()
        let controller = makeController(reports)
        let holder = try await controller.acquire(.window(3), context: context("file_actions", "aaaaaaaa", run: "bbbbbbbb"))
        let waiter = Task { try await controller.acquire(.window(3), context: context("apply_edits", "cccccccc")) }

        try await waitForReports(reports, count: 1)
        let line = try XCTUnwrap(reports.all.first)
        XCTAssertTrue(line.contains("event=admission"), line)
        XCTAssertTrue(line.contains("resource=window:3"), line)
        XCTAssertTrue(line.contains("waiter_tool=apply_edits waiter_conn=cccccccc waiter_run=-"), line)
        XCTAssertTrue(line.contains("holders=1 active=1"), line)
        XCTAssertTrue(
            line.contains("holder0_tool=file_actions holder0_conn=aaaaaaaa holder0_run=bbbbbbbb holder0_phase=unknown"),
            line
        )

        // The holder was reported, so a longer wait does not repeat the line within the interval.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reports.all.count, 1)

        holder.release()
        let granted = try await waiter.value
        XCTAssertEqual(controller.activeCount(for: .window(3)), 1)
        granted.release()
        XCTAssertEqual(controller.activeCount(for: .window(3)), 0)
        XCTAssertEqual(reports.all.count, 1)
    }

    func testRepeatedReportsContinueWhileWaitingAndStopAfterRelease() async throws {
        let reports = Reports()
        let controller = makeController(reports, interval: .milliseconds(40))
        let holder = try await controller.acquire(.window(1), context: context("prompt", "aaaaaaaa"))
        let waiter = Task { try await controller.acquire(.window(1), context: context("apply_edits", "cccccccc")) }

        try await waitForReports(reports, count: 2)
        holder.release()
        let granted = try await waiter.value
        let countAtRelease = reports.all.count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reports.all.count, countAtRelease, "no report after the wait ended")
        granted.release()
    }

    func testUntrackedHolderStillReportsTheWaiter() async throws {
        let reports = Reports()
        let controller = makeController(reports)
        let holder = try await controller.acquire(.window(2))
        let waiter = Task { try await controller.acquire(.window(2), context: context("file_actions", "dddddddd")) }

        try await waitForReports(reports, count: 1)
        let line = try XCTUnwrap(reports.all.first)
        XCTAssertTrue(line.contains("holders=untracked active=1"), line)
        XCTAssertTrue(line.contains("waiter_tool=file_actions"), line)

        holder.release()
        try await waiter.value.release()
    }

    func testCancelledAndClosedWaitersStopReporting() async throws {
        // Cancelled before the first report.
        let early = Reports()
        let earlyController = makeController(early, threshold: .milliseconds(200), interval: .milliseconds(40))
        let earlyHolder = try await earlyController.acquire(.window(1), context: context("prompt", "aaaaaaaa"))
        let earlyWaiter = Task { try await earlyController.acquire(.window(1), context: context("apply_edits", "bbbbbbbb")) }
        try await Task.sleep(for: .milliseconds(30))
        earlyWaiter.cancel()
        _ = try? await earlyWaiter.value
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(early.all.isEmpty, "\(early.all)")
        earlyHolder.release()

        // Cancelled after reporting.
        let late = Reports()
        let lateController = makeController(late, interval: .milliseconds(40))
        let lateHolder = try await lateController.acquire(.window(1), context: context("prompt", "aaaaaaaa"))
        let lateWaiter = Task { try await lateController.acquire(.window(1), context: context("apply_edits", "bbbbbbbb")) }
        try await waitForReports(late, count: 1)
        lateWaiter.cancel()
        _ = try? await lateWaiter.value
        let countAfterCancel = late.all.count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(late.all.count, countAfterCancel)
        lateHolder.release()

        // Closed after reporting.
        let closed = Reports()
        let closedController = makeController(closed, interval: .milliseconds(40))
        let closedHolder = try await closedController.acquire(.window(1), context: context("prompt", "aaaaaaaa"))
        let closedWaiter = Task { try await closedController.acquire(.window(1), context: context("apply_edits", "bbbbbbbb")) }
        try await waitForReports(closed, count: 1)
        closedController.close()
        _ = try? await closedWaiter.value
        let countAfterClose = closed.all.count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(closed.all.count, countAfterClose)
        closedHolder.release()
    }

    func testHandoffReportsOnlyTheNewHolder() async throws {
        let reports = Reports()
        let controller = makeController(reports, interval: .milliseconds(40))
        let first = try await controller.acquire(.window(1), context: context("prompt", "aaaaaaaa"))
        let second = Task { try await controller.acquire(.window(1), context: context("file_actions", "bbbbbbbb")) }
        try await Task.sleep(for: .milliseconds(10))
        let third = Task { try await controller.acquire(.window(1), context: context("apply_edits", "cccccccc")) }

        try await waitForReports(reports, count: 1)
        XCTAssertTrue(reports.all.allSatisfy { $0.contains("holder0_tool=prompt") }, "\(reports.all)")

        first.release()
        let secondLease = try await second.value
        let handoffIndex = reports.all.count
        try await waitForReports(reports, count: handoffIndex + 1)
        let afterHandoff = Array(reports.all.dropFirst(handoffIndex))
        XCTAssertTrue(
            afterHandoff.allSatisfy { $0.contains("holder0_tool=file_actions") && !$0.contains("holder0_tool=prompt") },
            "\(afterHandoff)"
        )

        secondLease.release()
        try await third.value.release()
    }

    func testUncontendedAndContextFreeAcquisitionsNeverReport() async throws {
        let reports = Reports()
        let controller = makeController(reports, threshold: .milliseconds(20))
        let lease = try await controller.acquire(.appWide, context: context("prompt", "dddddddd"))
        lease.release()
        let untracked = try await controller.acquire(.appWide)
        let waiter = Task { try await controller.acquire(.appWide) }
        try await Task.sleep(for: .milliseconds(100))
        untracked.release()
        try await waiter.value.release()
        XCTAssertTrue(reports.all.isEmpty, "\(reports.all)")
    }
}
