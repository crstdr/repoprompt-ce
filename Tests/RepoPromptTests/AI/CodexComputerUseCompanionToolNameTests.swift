import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class CodexComputerUseCompanionToolNameTests: XCTestCase {
    private func makeController() -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePaths: .uniform(nil)
        )
    }

    private func emittedToolCallName(server: String, tool: String) async -> String? {
        let controller = makeController()
        await controller.test_installThreadState(
            threadID: "thread-1",
            authoritativeTurnID: "turn-1",
            routingTurnID: "turn-1"
        )
        var events = controller.events.makeAsyncIterator()
        await controller.test_handleNotification(
            method: "codex/event/mcp_tool_call_begin",
            params: [
                "turn_id": .string("turn-1"),
                "msg": .object([
                    "call_id": .string("call-1"),
                    "invocation": .object([
                        "server": .string(server),
                        "tool": .string(tool),
                        "arguments": .object(["x": .number(10)])
                    ])
                ])
            ]
        )
        guard case let .toolCall(name, _, _) = await events.next() else {
            await controller.shutdown()
            return nil
        }
        await controller.shutdown()
        return name
    }

    func testCompanionServerToolCallEmitsQualifiedName() async {
        // Real Codex parse path: mcp_tool_call_begin with the reserved companion
        // server must keep its provenance so transcript clustering can recognize it.
        let name = await emittedToolCallName(server: "computer-use", tool: "click")
        XCTAssertEqual(name, "mcp__computer-use__click")
    }

    func testForeignServerToolCallKeepsBareName() async {
        let name = await emittedToolCallName(server: "other-server", tool: "click")
        XCTAssertEqual(name, "click")
    }

    func testCompanionToolNameIdentityForms() {
        XCTAssertTrue(MCPIntegrationHelper.isComputerUseCompanionToolName("mcp__computer-use__click"))
        // normalizedToolNameForComparison rewrites `-` to `_`; tolerate that form.
        XCTAssertTrue(MCPIntegrationHelper.isComputerUseCompanionToolName("mcp__computer_use__click"))
        XCTAssertEqual(
            MCPIntegrationHelper.computerUseCompanionToolName("mcp__computer-use__press_key"),
            "press_key"
        )
        XCTAssertFalse(MCPIntegrationHelper.isComputerUseCompanionToolName("mcp__other__click"))
        XCTAssertFalse(MCPIntegrationHelper.isComputerUseCompanionToolName("click"))
        XCTAssertFalse(MCPIntegrationHelper.isComputerUseCompanionToolName("mcp__computer-use__"))
        XCTAssertFalse(MCPIntegrationHelper.isComputerUseCompanionToolName(nil))
    }
}
