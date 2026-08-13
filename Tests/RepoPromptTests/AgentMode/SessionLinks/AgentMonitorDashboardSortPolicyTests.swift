import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentMonitorDashboardSortPolicyTests: XCTestCase {
    private func row(
        _ name: String,
        status: AgentMonitorLinkStatus = .idle,
        activity: TimeInterval? = nil,
        triage: AgentMonitorTriageState = .active,
        targetID: UUID = UUID(),
        linkID: UUID = UUID()
    ) -> AgentMonitorPillProps.Outbound {
        AgentMonitorPillProps.Outbound(
            linkID: linkID,
            generation: 1,
            targetSessionID: targetID,
            displayName: name,
            providerDisplayName: nil,
            locationLabel: nil,
            status: status,
            lastActivityAt: activity.map(Date.init(timeIntervalSince1970:)),
            triageState: triage
        )
    }

    func testPreferenceRawValuesAreStableAndUnknownValuesDefaultToSmart() {
        XCTAssertEqual(
            AgentMonitorDashboardSortMode.preferenceKey,
            "agentMonitor.dashboard.sortMode"
        )
        XCTAssertEqual(AgentMonitorDashboardSortMode.smart.rawValue, "smart")
        XCTAssertEqual(AgentMonitorDashboardSortMode.recentActivity.rawValue, "recent_activity")
        XCTAssertEqual(AgentMonitorDashboardSortMode.name.rawValue, "name")
        XCTAssertEqual(AgentMonitorDashboardSortMode.resolved(preferenceRawValue: nil), .smart)
        XCTAssertEqual(AgentMonitorDashboardSortMode.resolved(preferenceRawValue: "future"), .smart)
    }

    func testSmartUsesStatusBucketsThenRecentActivityAndKeepsDoneLast() {
        let rows = [
            row("Done", status: .awaitingUser, activity: 999, triage: .done),
            row("Unavailable", status: .unavailable, activity: 400),
            row("Running", status: .running, activity: 300),
            row("Idle old", activity: 100),
            row("Waiting", status: .awaitingUser, activity: 50),
            row("Idle new", activity: 200)
        ]

        XCTAssertEqual(
            AgentMonitorDashboardSortPolicy.sorted(rows, mode: .smart).map(\.displayName),
            ["Waiting", "Idle new", "Idle old", "Running", "Unavailable", "Done"]
        )
    }

    func testRecentActivitySortsNewestFirstWithNilLastInsideEachTriagePartition() {
        let rows = [
            row("No activity"),
            row("Older", activity: 100),
            row("Done newest", activity: 999, triage: .done),
            row("Newest", activity: 200)
        ]

        XCTAssertEqual(
            AgentMonitorDashboardSortPolicy.sorted(rows, mode: .recentActivity).map(\.displayName),
            ["Newest", "Older", "No activity", "Done newest"]
        )
    }

    func testNameUsesFixedCaseDiacriticFoldingThenDeterministicIdentifiers() throws {
        let lowerTarget = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let higherTarget = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let rows = [
            row("Zulu", activity: 100),
            row("éclair", activity: 100),
            row("Eagle", activity: 100),
            row("same", activity: 100, targetID: higherTarget),
            row("SAME", activity: 100, targetID: lowerTarget)
        ]

        let sorted = AgentMonitorDashboardSortPolicy.sorted(rows, mode: .name)
        XCTAssertEqual(sorted.prefix(3).map(\.displayName), ["Eagle", "éclair", "SAME"])
        XCTAssertEqual(sorted.suffix(2).map(\.displayName), ["same", "Zulu"])
        XCTAssertEqual(sorted[2].targetSessionID, lowerTarget)
        XCTAssertEqual(sorted[3].targetSessionID, higherTarget)
    }
}
