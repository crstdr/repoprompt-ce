import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSidebarTapDiagnosticsTests: XCTestCase {
    override func tearDown() {
        AgentSidebarTapDiagnostics.recordForTests = false
        AgentSidebarTapDiagnostics.testLines = []
        super.tearDown()
    }

    func testRowTapLogsActivateWithTheLiveGestureResult() throws {
        let rowID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        var activated = false
        var seenGesture: AgentSidebarSelectionGesture?
        AgentSidebarTapDiagnostics.recordForTests = true

        AgentSidebarRowTap.handle(
            isInteractionEnabled: true,
            tapRowID: nil,
            tapSelectionCount: 4,
            tapWorkspaceMatched: false,
            onSelectionGesture: { gesture in
                seenGesture = gesture
                return AgentSidebarSelectionGestureResult(
                    disposition: .activate,
                    reason: "activate",
                    selectionCount: 0,
                    workspaceMatched: true,
                    rowID: rowID
                )
            },
            onActivate: { activated = true }
        )

        let flags = AgentSidebarTapModifierReader.currentFlags()
        XCTAssertEqual(seenGesture, AgentSidebarTapModifierReader.gesture(for: flags))
        XCTAssertTrue(activated)
        XCTAssertEqual(
            AgentSidebarTapDiagnostics.testLines,
            [
                "outcome=activate reason=activate flags=\(flags.rawValue) selection=0 workspaceMatched=true row=\(rowID.uuidString)"
            ]
        )
    }

    func testDisabledRowTapLogsAndDoesNotActivate() throws {
        let rowID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        var gestureCalls = 0
        var activated = false
        AgentSidebarTapDiagnostics.recordForTests = true

        AgentSidebarRowTap.handle(
            isInteractionEnabled: false,
            tapRowID: rowID,
            tapSelectionCount: 2,
            tapWorkspaceMatched: false,
            onSelectionGesture: { _ in
                gestureCalls += 1
                return .ignored
            },
            onActivate: { activated = true }
        )

        let flags = AgentSidebarTapModifierReader.currentFlags()
        XCTAssertEqual(gestureCalls, 0)
        XCTAssertFalse(activated)
        XCTAssertEqual(
            AgentSidebarTapDiagnostics.testLines,
            [
                "outcome=ignored reason=interaction-disabled flags=\(flags.rawValue) selection=2 workspaceMatched=false row=\(rowID.uuidString)"
            ]
        )
    }

    func testModifierReaderTreatsCommandAndShiftWithoutCheckingEventType() {
        XCTAssertEqual(AgentSidebarTapModifierReader.gesture(for: []), .primary)
        XCTAssertEqual(AgentSidebarTapModifierReader.gesture(for: [.command]), .toggle)
        XCTAssertEqual(AgentSidebarTapModifierReader.gesture(for: [.shift]), .range)
        XCTAssertEqual(AgentSidebarTapModifierReader.gesture(for: [.command, .shift]), .range)
        XCTAssertEqual(
            AgentSidebarTapModifierReader.gesture(for: [.command, .numericPad]),
            .toggle
        )
    }

    func testWorkspaceGateDistinguishesMissingAndMismatch() throws {
        let sidebarID = try XCTUnwrap(UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"))
        let otherID = try XCTUnwrap(UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"))

        XCTAssertEqual(
            AgentSidebarTapWorkspaceGate.evaluate(sidebarWorkspaceID: nil, activeWorkspaceID: sidebarID),
            .missingWorkspace
        )
        XCTAssertEqual(
            AgentSidebarTapWorkspaceGate.evaluate(sidebarWorkspaceID: nil, activeWorkspaceID: nil),
            .missingWorkspace
        )
        XCTAssertEqual(
            AgentSidebarTapWorkspaceGate.evaluate(sidebarWorkspaceID: sidebarID, activeWorkspaceID: nil),
            .workspaceMismatch
        )
        XCTAssertEqual(
            AgentSidebarTapWorkspaceGate.evaluate(sidebarWorkspaceID: sidebarID, activeWorkspaceID: otherID),
            .workspaceMismatch
        )
        XCTAssertEqual(
            AgentSidebarTapWorkspaceGate.evaluate(sidebarWorkspaceID: sidebarID, activeWorkspaceID: sidebarID),
            .matched
        )
    }
}
