import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

@MainActor
final class CodexComputerUseWorkflowTests: XCTestCase {
    override func tearDown() {
        CodexComputerUseWorkflow.setEnabledForTesting(nil)
        super.tearDown()
    }

    func testDefaultsOptInAndDisable() throws {
        let name = "computer-use-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(CodexComputerUseWorkflow.isEnabled(defaults: defaults))
        CodexComputerUseWorkflow.setEnabled(true, defaults: defaults)
        XCTAssertTrue(CodexComputerUseWorkflow.isEnabled(defaults: defaults))
        CodexComputerUseWorkflow.setEnabled(false, defaults: defaults)
        XCTAssertFalse(CodexComputerUseWorkflow.isEnabled(defaults: defaults))
    }

    func testOwnedCompanionOverridesAndFailClosedOrdinaryTurns() throws {
        let key = "mcp_servers.\(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "computer-use"))"
        let saved = MCPIntegrationHelper.CodexServerEntry(rawName: "computer-use", normalizedName: "computer-use", cliPathComponent: MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "computer-use"))
        for (enabled, path) in [(false, Optional("/fake/SkyComputerUseClient")), (true, nil), (true, Optional("/fake/SkyComputerUseClient"))] {
            let overrides = CodexNativeSessionController.appServerMCPServerOverrides(serverEntries: [saved], enabledMCPServerNames: ["computer-use"], suppressThirdPartyMCPServers: false, computerUseEnabled: enabled, computerUseClientPath: path)
            XCTAssertEqual(overrides["\(key).enabled"] as? Bool, false)
            XCTAssertNil(overrides[key])
        }
        let active = CodexNativeSessionController.appServerMCPServerOverrides(serverEntries: [], enabledMCPServerNames: ["computer-use"], suppressThirdPartyMCPServers: true, computerUseEnabled: true, computerUseClientPath: "/fake/SkyComputerUseClient")
        let server = try XCTUnwrap(active[key] as? [String: Any])
        XCTAssertEqual(Set(server.keys), ["command", "args", "enabled"])
        XCTAssertEqual(server["command"] as? String, "/fake/SkyComputerUseClient")
        XCTAssertEqual(server["args"] as? [String], ["mcp"])
        XCTAssertEqual(server["enabled"] as? Bool, true)
        XCTAssertNil(active["\(key).enabled"])
        let ready = CodexNativeSessionController.defaultAppServerConfigOverrides(computerUseEnabled: true, computerUseClientPath: "/fake/SkyComputerUseClient", serverEntries: [])
        XCTAssertEqual(ready["features.computer_use"] as? Bool, true)
        XCTAssertEqual(ready["approval_policy"] as? String, "on-request")
        XCTAssertEqual(ready["approvals_reviewer"] as? String, "user")
        let unavailable = CodexNativeSessionController.defaultAppServerConfigOverrides(computerUseEnabled: true, computerUseClientPath: nil, serverEntries: [])
        XCTAssertEqual(unavailable["features.computer_use"] as? Bool, false)
    }

    func testControllerUsesUserReviewWithoutElevatingSandbox() async throws {
        for (enabled, path, expected) in [(true, Optional("/fake/SkyComputerUseClient"), CodexAgentToolPreferences.ApprovalPolicy.onRequest), (false, Optional("/fake/SkyComputerUseClient"), .never)] {
            let options = CodexNativeSessionController.Options.agentModeDefault(approvalPolicyProvider: { .never }, sandboxModeProvider: { .readOnly }, approvalReviewerProvider: { .autoReview }, computerUseEnabledProvider: { enabled }, computerUseClientPathProvider: { path }, mcpServerEntriesProvider: { [] })
            let controller = makeController(options: options)
            let policy = try await controller.test_computerUseApprovalPolicy()
            XCTAssertEqual(policy.0, expected)
            XCTAssertEqual(policy.1, expected == .onRequest ? .user : .autoReview)
            XCTAssertEqual(options.sandboxModeProvider(), .readOnly)
            await controller.shutdown()
        }
    }

    func testElicitationUnderNeverFullAccessIsEmittedNotAutoaccepted() async {
        for server in ["computer-use", "RepoPromptCE"] {
            let controller = makeController(options: .agentModeDefault(approvalPolicyProvider: { .never }, sandboxModeProvider: { .dangerFullAccess }, computerUseEnabledProvider: { true }, computerUseClientPathProvider: { "/fake/SkyComputerUseClient" }, mcpServerEntriesProvider: { [] }))
            var events = controller.events.makeAsyncIterator()
            await controller.test_handleServerRequest(method: "mcpServer/elicitation/request", params: ["serverName": .string(server), "threadId": .string("thread"), "turnId": .string("turn"), "message": .string("Allow computer interaction?"), "requestedSchema": .object(["type": .string("object"), "properties": .object([:])])])
            guard case let .mcpElicitationRequest(request) = await events.next() else {
                XCTFail("Expected a surfaced elicitation, not an automatic response")
                await controller.shutdown()
                continue
            }
            XCTAssertEqual(request.serverName, server)
            XCTAssertEqual(request.requestID, .int(42))
            await controller.shutdown()
        }
    }

    func testPermissionRequestIsSurfacedAndCannotBeRememberedOrSurviveTeardown() async {
        let controller = makeController(options: .agentModeDefault(approvalPolicyProvider: { .never }, sandboxModeProvider: { .dangerFullAccess }, computerUseEnabledProvider: { true }, computerUseClientPathProvider: { "/fake/SkyComputerUseClient" }, mcpServerEntriesProvider: { [] }))
        var events = controller.events.makeAsyncIterator()
        await controller.test_handleServerRequest(method: "item/permissions/requestApproval", params: ["threadId": .string("thread"), "turnId": .string("turn"), "itemId": .string("permission-item"), "cwd": .string("/tmp"), "reason": .string("Allow computer interaction?"), "permissions": .object(["network": .object(["enabled": .bool(true)])])])
        guard case let .permissionsRequest(request) = await events.next() else {
            XCTFail("Permission requests must reach the one-shot user UI")
            await controller.shutdown()
            return
        }
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.codexController = controller
        session.codexControllerFeatureState = .init(computerUseEnabled: true, goalSupportEnabled: false, reasoningSummariesEnabled: false, memoriesEnabled: false, capabilities: .disabled)
        session.pendingPermissionsRequest = request
        let coordinator = makeCoordinator()
        coordinator.submitPermissionsDecision(session: session, request: request, decision: .acceptForSession)
        XCTAssertEqual(session.pendingPermissionsRequest?.id, request.id, "Remembered approval must not be submitted")
        coordinator.test_clearComputerUseAfterTurn(session: session)
        XCTAssertNil(session.pendingPermissionsRequest)
        XCTAssertNil(session.codexController)
        XCTAssertNil(session.codexControllerFeatureState)
    }

    func testAdmissionExcludesLifetimeMCPChildAndLinkedSessions() async {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let coordinator = makeCoordinator()
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        func stage() {
            session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        }
        stage()
        let admitted = await coordinator.test_computerUseForNextTurn(session: session)
        XCTAssertTrue(admitted)
        session.parentSessionID = UUID()
        stage()
        let child = await coordinator.test_computerUseForNextTurn(session: session)
        XCTAssertFalse(child)
        session.parentSessionID = nil
        session.isMCPOriginated = true
        stage()
        let originated = await coordinator.test_computerUseForNextTurn(session: session)
        XCTAssertFalse(originated)
        session.isMCPOriginated = false
        session.mcpControlActivationGeneration = 1
        stage()
        let releasedControl = await coordinator.test_computerUseForNextTurn(session: session)
        XCTAssertFalse(releasedControl)
        session.mcpControlActivationGeneration = 0
        stage()
        let linked = await makeCoordinator(linked: { _ in true }).test_computerUseForNextTurn(session: session)
        XCTAssertFalse(linked)
        XCTAssertNil(session.pendingCodexComputerUseActivation)
    }

    func testAdmissionRechecksControlAndOptInAfterSuspension() async {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        for disableSetting in [false, true] {
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .codexExec
            session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
            let coordinator = makeCoordinator(linked: { session in
                if disableSetting { CodexComputerUseWorkflow.setEnabledForTesting(false) }
                else { session.mcpControlActivationGeneration = 1 }
                await Task.yield()
                return false
            })
            let admitted = await coordinator.test_computerUseForNextTurn(session: session)
            XCTAssertFalse(admitted)
            XCTAssertNil(session.pendingCodexComputerUseActivation)
        }
    }

    func testMissingCompanionAndOrdinaryTurnNeverAdmit() async {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        let ordinary = await makeCoordinator().test_computerUseForNextTurn(session: session)
        XCTAssertFalse(ordinary)
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        let missing = await makeCoordinator(ready: false).test_computerUseForNextTurn(session: session)
        XCTAssertFalse(missing)
        XCTAssertNil(session.pendingCodexComputerUseActivation)
    }

    func testReservedCollisionFailsClosedWithoutMutatingSavedDefinition() async throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        let admitted = await makeCoordinator(collision: true).test_computerUseForNextTurn(session: session)
        XCTAssertFalse(admitted)
        XCTAssertNil(session.pendingCodexComputerUseActivation)
        let saved: [String: Any] = ["command": "/user/custom", "env": ["TOKEN": "not-a-secret-fixture"], "tools": ["click": ["approval_mode": "approve"]]]
        let effective: [String: Any] = ["config": ["mcp_servers": ["computer-use": saved]]]
        XCTAssertThrowsError(try CodexNativeSessionController.validateComputerUseConfiguration(effective))
        XCTAssertEqual((effective["config"] as? NSDictionary)?["mcp_servers"] as? NSDictionary, ["computer-use": saved] as NSDictionary)
        XCTAssertNoThrow(try CodexNativeSessionController.validateComputerUseConfiguration(["config": [:]]))
        XCTAssertThrowsError(try CodexNativeSessionController.validateComputerUseConfiguration([:]))
    }

    func testProcessLaunchNeverCreatesTransportlessDisabledEntry() throws {
        XCTAssertEqual(try CodexAppServerClient.computerUseProcessConfigArgs(computerUseEnabled: false, serverEntries: []), [])
        let active = try CodexAppServerClient.computerUseProcessConfigArgs(computerUseEnabled: true, serverEntries: [])
        XCTAssertEqual(active, ["-c", "approval_policy=\"on-request\"", "-c", "approvals_reviewer=\"user\""])
        let saved = MCPIntegrationHelper.CodexServerEntry(rawName: "computer-use", normalizedName: "computer-use", cliPathComponent: "computer-use")
        XCTAssertEqual(try CodexAppServerClient.computerUseProcessConfigArgs(computerUseEnabled: false, serverEntries: [saved]), ["-c", "mcp_servers.computer-use.enabled=false"])
        XCTAssertThrowsError(try CodexAppServerClient.computerUseProcessConfigArgs(computerUseEnabled: true, serverEntries: [saved]))
        let ordinary = CodexNativeSessionController.appServerMCPServerOverrides(serverEntries: [], enabledMCPServerNames: [], suppressThirdPartyMCPServers: false, computerUseEnabled: false, computerUseClientPath: nil)
        XCTAssertFalse(ordinary.keys.contains { $0.contains("computer-use") })
    }

    private func makeController(options: CodexNativeSessionController.Options, requestExecutor: (@Sendable (String, [String: Any]?, TimeInterval?) async throws -> [String: Any])? = nil) -> CodexNativeSessionController {
        CodexNativeSessionController(client: CodexAppServerClient(), runID: UUID(), tabID: UUID(), windowID: 1, workspacePaths: .uniform(nil), options: options, requestExecutor: requestExecutor)
    }

    func testEffectiveLayerSuppressionAndCollisionAtControllerBoundary() async throws {
        for enabled in [false, true] {
            let controller = makeController(options: .agentModeDefault(computerUseEnabledProvider: { enabled }, computerUseClientPathProvider: { "/fake/SkyComputerUseClient" }, mcpServerEntriesProvider: { [] }), requestExecutor: { method, params, _ in
                XCTAssertEqual(method, "config/read")
                XCTAssertEqual(params?["includeLayers"] as? Bool, false)
                // No owned-file entry: this represents trusted project/managed configuration.
                return ["config": ["mcp_servers": ["computer-use": ["command": "/configured/client", "enabled": true]]]]
            })
            do {
                let config = try await controller.test_computerUseStartupConfig()
                XCTAssertFalse(enabled, "Active scope must reject effective collisions")
                XCTAssertEqual(config["mcp_servers.computer-use.enabled"] as? Bool, false)
                XCTAssertNil(config["mcp_servers.computer-use"])
                XCTAssertEqual(config["features.computer_use"] as? Bool, false)
            } catch {
                XCTAssertTrue(enabled, "Ordinary scope disables existing transport, not fails")
                XCTAssertTrue(error.localizedDescription.contains("computer-use"))
            }
            await controller.shutdown()
        }
        let absent = makeController(options: .agentModeDefault(mcpServerEntriesProvider: { [] }), requestExecutor: { _, _, _ in ["config": [:]] })
        let config = try await absent.test_computerUseStartupConfig()
        XCTAssertFalse(config.keys.contains { $0.contains("computer-use") })
        await absent.shutdown()
    }

    func testReadinessCannotEnableCompanionAfterPermissivePolicyDecision() async throws {
        var pathReads = 0
        let options = CodexNativeSessionController.Options.agentModeDefault(approvalPolicyProvider: { .never }, sandboxModeProvider: { .dangerFullAccess }, approvalReviewerProvider: { .autoReview }, computerUseEnabledProvider: { true }, computerUseClientPathProvider: {
            pathReads += 1
            return pathReads == 1 ? nil : "/fake/SkyComputerUseClient"
        }, mcpServerEntriesProvider: { [] })
        let controller = makeController(options: options, requestExecutor: { _, _, _ in ["config": [:]] })
        do {
            _ = try await controller.test_computerUseStartupConfig()
            XCTFail("Missing readiness must abort, never downgrade scope")
        } catch {
            XCTAssertEqual(pathReads, 1)
        }
        let policy = try await controller.test_computerUseApprovalPolicy()
        XCTAssertEqual(policy.0, .onRequest)
        XCTAssertEqual(policy.1, .user)
        let config = try await controller.test_computerUseStartupConfig()
        XCTAssertEqual((config["mcp_servers.computer-use"] as? [String: Any])?["command"] as? String, "/fake/SkyComputerUseClient")
        await controller.shutdown()

        var acceptedReads = 0
        let frozen = makeController(options: .agentModeDefault(computerUseEnabledProvider: { true }, computerUseClientPathProvider: {
            acceptedReads += 1
            return acceptedReads == 1 ? "/accepted/SkyComputerUseClient" : nil
        }, mcpServerEntriesProvider: { [] }), requestExecutor: { _, _, _ in ["config": [:]] })
        let frozenConfig = try await frozen.test_computerUseStartupConfig()
        XCTAssertEqual((frozenConfig["mcp_servers.computer-use"] as? [String: Any])?["command"] as? String, "/accepted/SkyComputerUseClient")
        XCTAssertEqual(frozenConfig["approval_policy"] as? String, "on-request")
        await frozen.shutdown()
    }

    func testRejectedExplicitTurnDoesNotStartOrdinaryController() async {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        await makeCoordinator(linked: nil).ensureCodexNativeSession(session: session)
        XCTAssertEqual(session.runState, .failed)
        XCTAssertNil(session.codexController)
        XCTAssertEqual(session.items.last?.kind, .error)
    }

    func testFinishClearsActivationAndRetiresCompanionController() {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        session.codexController = makeController(options: .agentModeDefault())
        session.codexControllerFeatureState = .init(computerUseEnabled: true, goalSupportEnabled: false, reasoningSummariesEnabled: false, memoriesEnabled: false, capabilities: .disabled)
        makeCoordinator().test_clearComputerUseAfterTurn(session: session)
        XCTAssertNil(session.pendingCodexComputerUseActivation)
        XCTAssertNil(session.codexController)
        XCTAssertNil(session.codexControllerFeatureState)
        XCTAssertTrue(session.codexNeedsReconnect)
    }

    func testMissingNativeEndpointFailsClosedWithoutTestInjection() async {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
        let admitted = await makeCoordinator(linked: nil).test_computerUseForNextTurn(session: session)
        XCTAssertFalse(admitted)
        XCTAssertNil(session.pendingCodexComputerUseActivation)
    }

    private func makeCoordinator(ready: Bool = true, collision: Bool = false, linked: ((AgentTabSession) async -> Bool)? = { _ in false }) -> CodexAgentModeCoordinator {
        CodexAgentModeCoordinator(windowID: 1, runtimeWorkspacePathsProvider: { _ in .uniform(nil) }, codexControllerFactory: { _, _, _, _, _, _, _, _ in fatalError("Admission tests must not launch a controller") }, connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in }, shouldManageCodexTooling: false, computerUseCompanionReady: { ready }, computerUseReservedEntryExists: { collision }, computerUseHasActiveLink: linked, codexHookApprovalSettings: GlobalSettingsStore.shared)
    }
}
