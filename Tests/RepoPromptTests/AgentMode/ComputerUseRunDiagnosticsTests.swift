import Foundation
import MCP
import RepoPromptShared
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class ComputerUseRunDiagnosticsTests: XCTestCase {
    func testEveryReasonIsFirstWinsAndExactlyOnce() {
        for reason in ComputerUseRunDiagnostic.Reason.allCases {
            ComputerUseRunDiagnostic.beginCaptureForTesting()
            let diagnostic = ComputerUseRunDiagnostic(backend: .app, operation: "start", invocationID: nil, interested: true, tags: [], keyCount: 0)
            ComputerUseRunDiagnostic.scope.withValue(diagnostic) {
                _ = ComputerUseRunDiagnostic.record(reason, false)
                _ = ComputerUseRunDiagnostic.record(.argument_keys, false)
                diagnostic.finish(success: false)
                _ = ComputerUseRunDiagnostic.record(.argument_type, false)
                diagnostic.finish(success: true)
            }
            let lines = ComputerUseRunDiagnostic.endCaptureForTesting()
            XCTAssertEqual(lines.count, 1)
            XCTAssertTrue(lines.first?.contains("reason=\(reason.rawValue) ") == true)
        }
    }

    func testArgumentOutcomesDoNotLogPayloadOrUnknownKeys() throws {
        let marker = "PRIVATE_MARKER_/Users/person/gpt-model/grant"
        let cases: [(String, [String: Value], String)] = [
            ("start", ["computer_use": .bool(true), "session_name": .string(marker), marker: .string(marker)], "argument_keys"),
            ("start", ["computer_use": .string(marker)], "argument_type"),
            ("wait", ["computer_use": .bool(true)], "argument_operation")
        ]
        for (op, args, reason) in cases {
            let id = UUID()
            let diagnostic = ComputerUseRunDiagnostic(backend: .app, operation: op, invocationID: id, interested: true, tags: AgentRunMCPToolService.computerUseDiagnosticTags(args), keyCount: args.count)
            ComputerUseRunDiagnostic.beginCaptureForTesting()
            try ComputerUseRunDiagnostic.scope.withValue(diagnostic) {
                XCTAssertThrowsError(try AgentRunMCPToolService.computerUseRequested(args: args, operation: op))
                diagnostic.finish(success: false)
            }
            let lines = ComputerUseRunDiagnostic.endCaptureForTesting()
            XCTAssertEqual(lines.count, 1)
            let line = lines.joined()
            XCTAssertTrue(line.contains("outcome=invalid_argument reason=\(reason)"))
            if reason == "argument_keys" {
                XCTAssertTrue(line.contains("session_name:S unknown_keys=1"))
            }
            XCTAssertFalse(line.contains(marker))
            XCTAssertFalse(line.contains(id.uuidString))
        }
    }

    func testProvisionalFailureDoesNotBecomeSuccessfulSteerRefusal() {
        ComputerUseRunDiagnostic.beginCaptureForTesting()
        let diagnostic = ComputerUseRunDiagnostic(backend: .app, operation: "steer", invocationID: nil, interested: false, tags: [], keyCount: 0)
        ComputerUseRunDiagnostic.scope.withValue(diagnostic) {
            let _: Int? = ComputerUseRunDiagnostic.probe {
                throw MCPError.invalidParams(ComputerUseRunDiagnostic.record(.capture_context, "PRIVATE_ERROR"))
            }
            diagnostic.finish(success: true)
        }
        let lines = ComputerUseRunDiagnostic.endCaptureForTesting()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("outcome=ok reason=none") == true)
        XCTAssertTrue(lines.first?.contains("degraded=capture_context") == true)
        XCTAssertFalse(lines.joined().contains("PRIVATE_ERROR"))
    }
}
