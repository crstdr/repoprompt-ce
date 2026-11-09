import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPAdmissionOverdueReportTests: XCTestCase {
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    func testOverdueWaiterReportsHolderOncePerIntervalAndStopsAfterRelease() async throws {
        let reports = Reports()
        let controller = MCPDomainToolResourceAdmissionController(
            limit: 1,
            overdueThreshold: .milliseconds(30),
            overdueRepeatInterval: .seconds(60),
            overdueReport: { reports.append($0) }
        )
        let holder = try await controller.acquire(
            .window(3),
            context: .init(tool: "file_actions", connection: "aaaaaaaa", run: "bbbbbbbb")
        )
        let waiter = Task {
            try await controller.acquire(
                .window(3),
                context: .init(tool: "apply_edits", connection: "cccccccc", run: nil)
            )
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while reports.all.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let line = try XCTUnwrap(reports.all.first)
        XCTAssertTrue(line.contains("event=admission"), line)
        XCTAssertTrue(line.contains("resource=window:3"), line)
        XCTAssertTrue(line.contains("waiter_tool=apply_edits waiter_conn=cccccccc waiter_run=-"), line)
        XCTAssertTrue(line.contains("holder0_tool=file_actions holder0_conn=aaaaaaaa holder0_run=bbbbbbbb holder0_phase=unknown"), line)

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

    func testUncontendedAndContextFreeAcquisitionsNeverReport() async throws {
        let reports = Reports()
        let controller = MCPDomainToolResourceAdmissionController(
            limit: 1,
            overdueThreshold: .milliseconds(20),
            overdueReport: { reports.append($0) }
        )
        let lease = try await controller.acquire(.appWide, context: .init(tool: "prompt", connection: "dddddddd", run: nil))
        lease.release()
        let untracked = try await controller.acquire(.appWide)
        let waiter = Task { try await controller.acquire(.appWide) }
        try await Task.sleep(for: .milliseconds(100))
        untracked.release()
        try await waiter.value.release()
        XCTAssertTrue(reports.all.isEmpty, "\(reports.all)")
    }
}
