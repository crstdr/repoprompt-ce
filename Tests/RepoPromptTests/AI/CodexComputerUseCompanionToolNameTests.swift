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

    private func emittedToolCallName(
        serverFields: [String: CodexJSONValue],
        tool: String
    ) async -> String? {
        let controller = makeController()
        await controller.test_installThreadState(
            threadID: "thread-1",
            authoritativeTurnID: "turn-1",
            routingTurnID: "turn-1"
        )
        var invocation: [String: CodexJSONValue] = serverFields
        invocation["tool"] = .string(tool)
        invocation["arguments"] = .object(["x": .number(10)])
        await controller.test_handleNotification(
            method: "codex/event/mcp_tool_call_begin",
            params: [
                "turn_id": .string("turn-1"),
                "msg": .object([
                    "call_id": .string("call-1"),
                    "invocation": .object(invocation)
                ])
            ]
        )
        // Bounded wait: a regression in event emission must fail, not hang the suite.
        let stream = controller.events
        let event = await withTaskGroup(of: CodexNativeSessionController.Event?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await controller.shutdown()
        guard case let .toolCall(name, _, _, _) = event else { return nil }
        return name
    }

    func testCompanionServerToolCallEmitsQualifiedName() async {
        // Real Codex parse path: mcp_tool_call_begin with the reserved companion
        // server must keep its provenance so transcript clustering can recognize it.
        let name = await emittedToolCallName(serverFields: ["server": .string("computer-use")], tool: "click")
        XCTAssertEqual(name, "mcp__computer-use__click")
    }

    func testForeignServerToolCallKeepsBareName() async {
        let name = await emittedToolCallName(serverFields: ["server": .string("other-server")], tool: "click")
        XCTAssertEqual(name, "click")
    }

    func testCompanionActionResemblingShellKeepsProvenance() async {
        // Server attestation outranks the generic "shell" -> "bash" alias.
        let name = await emittedToolCallName(serverFields: ["server": .string("computer-use")], tool: "shell")
        XCTAssertEqual(name, "mcp__computer-use__shell")
    }

    func testForeignServerWithCompanionLookingNameFailsClosed() async {
        // A foreign-attested payload carrying a spoofed companion prefix never groups.
        let name = await emittedToolCallName(
            serverFields: ["server": .string("other-server")],
            tool: "mcp__computer-use__click"
        )
        XCTAssertEqual(name, "click")
    }

    func testMissingAttestationWithCompanionLookingNameFailsClosed() async {
        // No server fields at all: the claimed prefix is stripped rather than trusted.
        let name = await emittedToolCallName(serverFields: [:], tool: "mcp__computer-use__click")
        XCTAssertEqual(name, "click")
    }

    func testConflictingServerAliasesFailClosed() async {
        let name = await emittedToolCallName(
            serverFields: ["server": .string("computer-use"), "mcp_server": .string("other-server")],
            tool: "click"
        )
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
        XCTAssertFalse(MCPIntegrationHelper.isComputerUseCompanionToolName("functions.mcp__computer-use__click"))
        XCTAssertFalse(MCPIntegrationHelper.isComputerUseCompanionToolName(nil))
    }
}

final class CodexChromePluginProvisioningTests: XCTestCase {
    func testPromotesOnlyChromeCacheAndIsIdempotent() throws {
        try withHomes { staging, destination in
            let manifest = try self.makeInstallation(in: staging)
            let config = Data("[plugins.\"chrome@openai-bundled\"]\nenabled = true\n".utf8)
            try config.write(to: staging.appendingPathComponent("config.toml"))
            let other = staging.appendingPathComponent("plugins/cache/openai-bundled/documents")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

            try CodexChromePluginProvisioning.promote(stagingHome: staging, destinationHome: destination)
            try CodexChromePluginProvisioning.promote(stagingHome: staging, destinationHome: destination)

            let installedManifest = destination.appendingPathComponent("plugins/cache/openai-bundled/chrome/1.0/.codex-plugin/plugin.json")
            XCTAssertEqual(try Data(contentsOf: installedManifest), try Data(contentsOf: manifest))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("plugins/cache/openai-bundled/documents").path))
        }
    }

    func testMissingOrDifferentCacheFailsClosed() throws {
        try withHomes { staging, destination in
            XCTAssertThrowsError(try CodexChromePluginProvisioning.promote(stagingHome: staging, destinationHome: destination))
            let manifest = try self.makeInstallation(in: staging)
            let existing = try self.makeInstallation(in: destination)
            try Data("{\"name\":\"chrome\",\"version\":\"different\"}".utf8).write(to: existing)
            XCTAssertThrowsError(try CodexChromePluginProvisioning.promote(stagingHome: staging, destinationHome: destination))
            XCTAssertNotEqual(try Data(contentsOf: manifest), try Data(contentsOf: existing))
        }
    }

    func testStagingInstallerDoesNotPublishItsConfig() throws {
        try withHomes { fixture, destination in
            let marketplace = fixture.appendingPathComponent("bundled")
            try FileManager.default.createDirectory(at: marketplace, withIntermediateDirectories: true)
            try CodexChromePluginProvisioning.stageAndPromote(marketplace: marketplace, destinationHome: destination) { staging in
                let configURL = staging.appendingPathComponent("config.toml")
                XCTAssertTrue(try String(contentsOf: configURL, encoding: .utf8).contains("[marketplaces.openai-bundled]"))
                _ = try self.makeInstallation(in: staging)
                try Data("enabled = true".utf8).write(to: configURL)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("plugins/cache/openai-bundled/chrome/1.0").path))
        }
    }

    func testChromeAndNodeRequireArmedDirectApprovedInstalledRoute() {
        let config: [String: Any] = [
            "mcp_servers": ["node_repl": ["command": "/fixture/node_repl"]],
            "plugins": ["documents@openai-bundled": ["enabled": true], "other@marketplace": ["enabled": true]]
        ]
        let overrides = CodexChromePluginProvisioning.threadOverrides(config: config, armedDirect: true, approved: true, installed: true)
        XCTAssertEqual(overrides[CodexChromePluginProvisioning.disabledPluginKey] as? Bool, true)
        XCTAssertEqual(overrides["plugins.\"documents@openai-bundled\".enabled"] as? Bool, false)
        XCTAssertEqual(overrides["plugins.\"other@marketplace\".enabled"] as? Bool, false)
        XCTAssertEqual(overrides["plugins._default.enabled"] as? Bool, false)
        XCTAssertEqual(overrides["mcp_servers.node_repl.enabled"] as? Bool, true)
        XCTAssertEqual(overrides["mcp_servers.node_repl.env.BROWSER_USE_AVAILABLE_BACKENDS"] as? String, "chrome")
        XCTAssertEqual(overrides["mcp_servers.node_repl.default_tools_approval_mode"] as? String, "prompt")
        XCTAssertTrue(CodexChromePluginProvisioning.threadOverrides(config: config, armedDirect: false, approved: true, installed: true).isEmpty)
        XCTAssertTrue(CodexChromePluginProvisioning.threadOverrides(config: config, armedDirect: true, approved: false, installed: true).isEmpty)
        XCTAssertTrue(CodexChromePluginProvisioning.threadOverrides(config: config, armedDirect: true, approved: true, installed: false).isEmpty)
        XCTAssertTrue(CodexChromePluginProvisioning.threadOverrides(config: [:], armedDirect: true, approved: true, installed: true).isEmpty)
    }

    private func makeInstallation(in home: URL) throws -> URL {
        let directory = home.appendingPathComponent("plugins/cache/openai-bundled/chrome/1.0/.codex-plugin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("plugin.json")
        try Data("{\"name\":\"chrome\",\"version\":\"1.0\"}".utf8).write(to: manifest)
        return manifest
    }

    private func withHomes(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = root.appendingPathComponent("staging")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try body(staging, destination)
    }
}
