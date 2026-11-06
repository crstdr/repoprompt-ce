import Foundation
import MCP
import RepoPromptDomainRuntime
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class ComputerUseChildRoutingTests: XCTestCase {
    private let start: [String: Any] = ["op": "start", "computer_use": true, "message": "Inspect the fake desktop", "detach": true, "_rawJSON": true]

    private struct ExistingTools: MCPAppToolProviding {
        let group: MCPAppToolGroup = .agentControl
        let tools: [RepoPromptApp.Tool]
        func buildTools() -> [RepoPromptApp.Tool] {
            tools
        }
    }

    @MainActor
    private final class RouteFixture {
        let transport: PersistentMCPTestEndpoint
        let base: PersistentMCPTestFixture
        let parent: AgentTabSession
        let visible: AgentTabSession
        let runID = UUID()
        var submissions = 0
        var startEntries = 0
        var armEntries = 0
        var catalog: MCPAppToolCatalogRegistration?
        var beforeAdmission: (() async throws -> Void)?
        var beforeMetadata: (() async -> Void)?
        var beforeAuthorization: (() async -> Void)?
        var beforeStartDispatch: (() async -> Void)?
        var beforeSteerDispatch: (() async -> Void)?
        var vm: AgentModeViewModel {
            window.agentModeViewModel
        }

        var server: MCPServerViewModel {
            window.mcpServer
        }

        var manager: ServerNetworkManager {
            base.networkManager
        }

        let window: WindowState

        init(_ base: PersistentMCPTestFixture, provider: AgentProviderKind, realSteer: Bool, realStarter: Bool, window: WindowState) async throws {
            self.base = base
            self.window = window
            transport = try base.endpointA()
            let workspace = try XCTUnwrap(window.workspaceManager.workspaces.first { $0.id == base.contextA.workspaceID })
            _ = await window.workspaceManager.switchWorkspace(to: workspace, saveState: false)
            let vm = window.agentModeViewModel
            parent = vm.session(for: base.contextA.tabID)
            parent.selectedAgent = provider
            parent.hasLoadedPersistedState = true
            _ = try XCTUnwrap(vm.test_installPersistentSessionBinding(sessionID: UUID(), on: parent, updateWorkspaceMetadata: true))
            parent.recordRestorationAuthoritative(.persistedPayloadApplied)
            parent.installRunID(runID)
            parent.computerUseParentGrant = UUID()
            let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == base.contextA.workspaceID })
            let visibleID = UUID()
            window.workspaceManager.workspaces[index].composeTabs.append(.init(id: visibleID, name: "Visible, not calling"))
            visible = vm.session(for: visibleID)
            visible.selectedAgent = provider
            visible.hasLoadedPersistedState = true
            _ = try XCTUnwrap(vm.test_installPersistentSessionBinding(sessionID: UUID(), on: visible, updateWorkspaceMetadata: true))
            visible.recordRestorationAuthoritative(.persistedPayloadApplied)
            await window.promptManager.switchComposeTab(visibleID)
            XCTAssertEqual(window.promptManager.activeComposeTabID, visibleID)
            window.apiSettingsViewModel.isCodexConnected = true // Fake availability; callbacks never start a provider.
            var currentWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            currentWorkspace.isEphemeral = false
            window.workspaceManager.workspaces[index] = currentWorkspace
            let authority = DomainWorkspaceAuthorityClient(store: AppDomainRuntimeComposition.shared.runtime.workspaceStore, windowID: window.windowID)
            let created = try await authority.create(currentWorkspace, fileURL: window.workspaceManager.workspaceFileURL(for: currentWorkspace))
            XCTAssertEqual(created.disposition, .applied, created.diagnostic ?? "")
            if realStarter {
                // The DEBUG VM omits production sidebar bootstrap; establish the real fast index.
                _ = try await AgentSessionDataService.shared.indexedAgentSessionMetadataRecords(for: currentWorkspace)
                let children = try await AgentSessionDataService.shared.computerUseChildIDs(for: XCTUnwrap(parent.activeAgentSessionID), workspace: currentWorkspace)
                XCTAssertEqual(children, [])
            }
            let enabled = await server.setWindowToolsEnabled(true, publishesRequestChange: false)
            XCTAssertTrue(enabled)
            var service = AgentRunMCPToolService(
                toolName: "agent_run",
                captureRequestMetadata: { [self] in
                    await beforeMetadata?()
                    return await server.captureRequestMetadata()
                },
                requireTargetWindow: { window },
                resolveRequestedTabID: { _ in nil },
                resolveSpawnParentSourceTabID: { [self] in await server.resolveSpawnParentSourceTabIDForAgentSessionCreation(metadata: $0) },
                validateSpawnRouting: { [self] in try await server.validateAgentRunStartRouting(metadata: $0, resolvedSourceTabID: $1) },
                resolveSpawnParentSessionID: { [self] metadata, window in
                    await beforeAuthorization?()
                    return await server.resolveSpawnParentSessionID(metadata: metadata, targetWindow: window)
                },
                resolveSpawnParentSessionIDFromSourceTabID: { $1.agentModeViewModel.mcpSpawnParentSessionID(sourceTabID: $0) },
                withHeartbeat: { _, _, _, _, operation in try await operation() },
                startRun: { [self] target, message, metadata, vm, agent, model, effort, label, workflow, expectedParent, source, routed, expiry in
                    startEntries += 1
                    let child = try XCTUnwrap(vm.sessions[target.tabID])
                    XCTAssertEqual(child.parentSessionID, expectedParent)
                    if realStarter {
                        return try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                            target: target, message: message, metadata: metadata, agentModeVM: vm,
                            agentRaw: agent, modelRaw: model, reasoningEffortRaw: effort, taskLabelKind: label,
                            workflow: workflow, expectedParentSessionID: expectedParent, oracleReviewSource: source,
                            preserveRoutedInitialEffort: routed,
                            dispatchInstruction: { [self] id, _, text, workflow, vm in
                                let proof = try XCTUnwrap(child.computerUseChildProof)
                                XCTAssertTrue(proof.instructionDispatchEntered)
                                try await beforeAdmission?()
                                window.apiSettingsViewModel.isCodexConnected = true // Fake availability after real configuration probes.
                                let delivery = try await vm.mcpDispatchInstruction(
                                    sessionID: id, text: text, allowStartingRun: true, workflow: workflow,
                                    preserveRoutedInitialEffort: routed, computerUseProof: proof
                                )
                                submissions += 1
                                return delivery
                            }, startExpiry: expiry
                        )
                    }
                    if child.isComputerUseChild {
                        XCTAssertEqual(expectedParent, parent.activeAgentSessionID)
                        XCTAssertEqual(child.selectedAgent, .codexExec)
                        XCTAssertEqual(child.selectedModelRaw, "gpt-6.1-sol")
                        XCTAssertEqual(child.selectedReasoningEffortRaw, "high")
                        let proof = try XCTUnwrap(child.computerUseChildProof)
                        try await beforeAdmission?()
                        try proof.withInstructionSubmission(child) { submissions += 1 }
                    } else {
                        submissions += 1
                    }
                    return .init(snapshot: snapshot(child), delivery: .startedRun)
                }
            )
            service.resolveOracleReviewLaunchSource = { [self] metadata, window in
                let snapshot = try await server.resolveAgentRunOracleReviewLaunchSnapshot(metadata: metadata, targetWindow: window)
                return .init(snapshot: snapshot, source: .unavailable(.init(
                    delegationID: UUID(), sourceTabID: snapshot.tabID, workspaceID: snapshot.workspaceID,
                    sourceAgentSessionID: snapshot.sourceAgentSessionID, sourceAgentRunID: snapshot.routedRunID,
                    reason: .sourceCaptureFailed("Test-owned transport fixture")
                )))
            }
            service.testComputerUseConfiguration = { .init(enabled: true, modelID: "codexExec:gpt-6.1-sol-high", modelAvailable: true) }
            if !realStarter { service.testArmComputerUseChild = { [self] _, _ in armEntries += 1 } }
            service.testBeforeProviderDispatch = { [self] in await beforeStartDispatch?() }
            service.testBeforeSteerDispatch = { [self] in await beforeSteerDispatch?() }
            if !realSteer {
                service.testDispatchSteerInstruction = { [self] id, _, _, vm in
                    let child = try XCTUnwrap(vm.mcpControlledSession(sessionID: id))
                    try await beforeAdmission?()
                    if child.isComputerUseChild {
                        let proof = try XCTUnwrap(child.computerUseChildProof)
                        try proof.withInstructionSubmission(child) { submissions += 1 }
                    } else {
                        submissions += 1
                    }
                    return .startedRun
                }
            }
            let installedService = service
            let windowID = window.windowID
            let denied = ComputerUseChildProof.denied
            let binder = MCPAppToolBinder(windowID: windowID) { [window] name, _, args, implementation in
                let context = try MCPInvocationContextBridge.require(toolName: name, expectedWindowID: windowID)
                let serverIdentity = await MainActor.run { ObjectIdentifier(window.mcpServer) }
                guard await ServerNetworkManager.shared.validateToolInvocationContext(
                    context, expectedWindowID: windowID, expectedServerViewModelIdentity: serverIdentity
                ) else { throw MCPError.invalidParams(denied) }
                return try await implementation(.init(toolName: name, windowID: windowID, context: context), args)
            }
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "agent_run"))
            let originalTools = await server.windowMCPTools
            let catalog = MCPAppToolCatalogRegistration(
                windowID: window.windowID, providers: [ExistingTools(tools: originalTools.filter { $0.name != "agent_run" })],
                sharedBindings: [.init(definition: definition) { args in try await installedService.execute(args: args) }],
                runtime: binder
            )
            self.catalog = catalog
            await AppDomainRuntimeComposition.shared.unregister(base.contextA.catalogService)
            await AppDomainRuntimeComposition.shared.unregister(server.windowMCPToolCatalogService)
            _ = try await AppDomainRuntimeComposition.shared.register(catalog)
        }

        func installRoute(replacement: Bool = false) async throws {
            let previous = await manager.cachedModelRunRoute(connectionID: transport.connectionID)
            await manager.installClientConnectionPolicy(
                for: transport.clientName, windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true,
                reason: "CU transport regression", ttl: 60, tabID: parent.tabID,
                runID: runID, additionalTools: nil, purpose: .agentModeRun,
                taskLabelKind: nil, allowsAgentExternalControlTools: false
            )
            if replacement {
                let current = await manager.cachedModelRunRoute(connectionID: transport.connectionID)
                XCTAssertEqual(current?.runID, runID)
                XCTAssertNotEqual(current?.routingAuthorityGeneration, previous?.routingAuthorityGeneration)
                return
            }
            let applied = await manager.debugApplyPendingPolicy(
                clientName: transport.clientName, connectionID: transport.connectionID,
                clientPid: nil, bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: "cu-transport-\(runID)", pidGateTimeout: 0.25, requireRunRouting: true
            )
            XCTAssertEqual(applied.outcome, "applied")
            _ = try await manager.debugListToolNames(for: transport.connectionID)
            let route = await manager.cachedModelRunRoute(connectionID: transport.connectionID)
            XCTAssertEqual(route?.runID, runID)
        }

        func snapshot(_ child: AgentTabSession) -> AgentRunMCPSnapshot {
            .init(
                sessionID: child.activeAgentSessionID!, tabID: child.tabID, sessionName: "Fake CU",
                agentRaw: child.selectedAgent.rawValue, agentDisplayName: "Fake", modelRaw: child.selectedModelRaw,
                reasoningEffortRaw: child.selectedReasoningEffortRaw, status: .completed, statusText: "Fake submission",
                latestAssistantPreview: nil, interaction: nil, transcriptItemCount: 0, updatedAt: Date(),
                parentSessionID: child.parentSessionID, failureReason: nil, worktreeBindings: [], activeWorktreeMerges: []
            )
        }

        func controlledChild(computerUse: Bool = true, parentID: UUID? = nil) async throws -> AgentTabSession {
            let target = try await vm.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Idle child",
                parentSessionID: parentID ?? parent.activeAgentSessionID, inheritWorktreeBindings: false,
                expectedWorkspaceID: base.contextA.workspaceID
            )
            let child = vm.session(for: target.tabID)
            let id = try XCTUnwrap(target.sessionID)
            let control = try await vm.mcpActivateControlContext(
                forTabID: target.tabID, sessionID: id, originatingConnectionID: transport.connectionID,
                creationHandle: target.creationHandle
            )
            try await vm.mcpConfigureSession(
                tabID: target.tabID, agentRaw: "codexExec", modelRaw: "gpt-6.1-sol", reasoningEffortRaw: "high",
                expectedControlContext: control, creationHandle: target.creationHandle
            )
            child.selectedAgent = .codexExec
            child.selectedModelRaw = "gpt-6.1-sol"
            child.selectedReasoningEffortRaw = "high"
            child.purpose = computerUse ? "computerUse" : nil
            child.hasLoadedPersistedState = true
            let committed = await vm.commitConfiguredSessionCreation(target: target)
            XCTAssertTrue(committed)
            vm.mcpAcceptSessionTarget(target)
            return child
        }

        func revoke() async {
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
        }

        func finish() async {
            beforeAdmission = nil
            beforeMetadata = nil
            beforeAuthorization = nil
            beforeStartDispatch = nil
            beforeSteerDispatch = nil
            if let catalog { await AppDomainRuntimeComposition.shared.unregister(catalog) }
            catalog = nil
            await AppDomainRuntimeComposition.shared.runtime.domainHost.debugSetBeforeProviderActivationForTesting(nil)
            if let proof = ComputerUseChildProof.holder {
                proof.retire()
                await proof.producerSettled()?.value
            }
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
            vm.test_providerSwitchStart = nil
            vm.test_afterConfiguredCreationAcknowledgement = nil
            for session in vm.sessions.values {
                session.saveDebounceTask?.cancel()
            }
            let authority = DomainWorkspaceAuthorityClient(store: AppDomainRuntimeComposition.shared.runtime.workspaceStore, windowID: window.windowID)
            _ = await authority.delete(workspaceID: base.contextA.workspaceID, expectedCatalogRevision: nil, expectedWorkspaceRevision: nil)
        }
    }

    private func withRoute(provider: AgentProviderKind = .claudeCode, install: Bool = true, realSteer: Bool = false, realStarter: Bool = false, _ body: (RouteFixture) async throws -> Void) async throws {
        try await MCPSharedServerTestLease.shared.withLease { lease in
            let base = try await PersistentMCPTestFixture.make(lease: lease, domainRuntime: AppDomainRuntimeComposition.shared.runtime)
            var route: RouteFixture?
            var fakeWindow: WindowState?
            @MainActor func finishWindow() async {
                guard let fakeWindow else { return }
                WindowStatesManager.shared.unregisterWindowState(fakeWindow)
                await fakeWindow.tearDown()
            }
            do {
                if realStarter {
                    let factory = WedgeControllerFactory(plans: [[.success("child-thread")]])
                    let window = WindowState(agentModeViewModelFactory: { id, prompt, manager, server in
                        let vm = AgentModeViewModel(
                            testWindowID: id, shouldManageCodexTooling: false,
                            codexControllerFactory: { runID, _, _, _, _, _ in factory.make(runID: runID) },
                            codexControllerFactoryWithComputerUse: { runID, _, _, _, _, _, enabled, _ in factory.make(runID: runID, computerUseEnabled: enabled) },
                            testMCPServer: server, testWorkspaceFileContextStore: prompt.workspaceFileContextStore,
                            testCodexComputerUseRuntimePreflight: { nil }, testCodexComputerUseCompanionReady: { true },
                            testCodexComputerUseReservedEntryExists: { false }
                        )
                        vm.promptManager = prompt
                        vm.workspaceManager = manager
                        return vm
                    }, contextBuilderProviderFactory: { _, _, _, _ in AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1) }, domainRuntime: AppDomainRuntimeComposition.shared.runtime)
                    fakeWindow = window
                    WindowStatesManager.shared.registerWindowState(window)
                    await window.workspaceManager.awaitInitialized()
                    try window.workspaceManager.workspaces.append(XCTUnwrap(base.contextA.window.workspaceManager.workspaces.first { $0.id == base.contextA.workspaceID }))
                }
                let fixture = try await RouteFixture(base, provider: provider, realSteer: realSteer, realStarter: realStarter, window: fakeWindow ?? base.contextA.window)
                route = fixture
                if install { try await fixture.installRoute() }
                try await body(fixture)
                await fixture.finish()
                await finishWindow()
                await base.cleanup()
                try await base.assertCleanedUp()
            } catch {
                await route?.finish()
                await finishWindow()
                await base.cleanup()
                throw error
            }
        }
    }

    func testIdleSteerRejectsRevokedRouteBeforeArming() async throws {
        try await withRoute { f in
            let child = try await f.controlledChild()
            var revoked = false
            f.beforeMetadata = {
                await f.manager.setEnabled(false)
                await f.manager.setEnabled(true)
                revoked = true
            }
            let response = try await f.transport.callTool(name: "agent_run", arguments: [
                "op": "steer", "session_id": child.activeAgentSessionID!.uuidString,
                "message": "Do not arm a revoked fake task", "wait": false, "_rawJSON": true
            ])
            XCTAssertTrue(revoked)
            XCTAssertTrue(response.rawJSON.contains(ComputerUseChildProof.denied), response.rawJSON)
            XCTAssertEqual(f.armEntries, 0)
            XCTAssertEqual(f.submissions, 0)
            XCTAssertNil(child.computerUseChildProof)
            XCTAssertNil(ComputerUseChildProof.holder)
        }
    }

    func testUnauthorizedSteerDoesNotDiscloseComputerUseDesignation() async throws {
        try await withRoute { f in
            let previousFullAccess = OverseerGlobalAutoApprove.isEnabled
            defer { OverseerGlobalAutoApprove.isEnabled = previousFullAccess }
            OverseerGlobalAutoApprove.isEnabled = { false }
            f.parent.computerUseParentGrant = nil
            let child = try await f.controlledChild(computerUse: false, parentID: f.visible.activeAgentSessionID)
            let id = try XCTUnwrap(child.activeAgentSessionID)
            var ordinaryResult: NSDictionary?
            for computerUse in [false, true] {
                child.purpose = computerUse ? "computerUse" : nil
                let response = try await f.transport.callTool(name: "agent_run", arguments: [
                    "op": "steer", "session_id": id.uuidString,
                    "message": "Unauthorized fake steer", "wait": false, "_rawJSON": true
                ])
                XCTAssertTrue(response.rawJSON.contains("not available to this caller's scope"), response.rawJSON)
                XCTAssertFalse(response.rawJSON.contains(ComputerUseChildProof.denied), response.rawJSON)
                let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.rawJSON.utf8)) as? [String: Any])
                let result = try XCTUnwrap(envelope["result"] as? NSDictionary)
                if computerUse { XCTAssertEqual(result, ordinaryResult) }
                else { ordinaryResult = result }
            }
            XCTAssertEqual(f.submissions, 0)
            XCTAssertNil(child.computerUseChildProof)
            XCTAssertNil(ComputerUseChildProof.holder)
        }
    }

    func testNetworkIdleComputerUseSteerAcceptsOneFakeNativeTurn() async throws {
        try await withRoute(realSteer: true, realStarter: true) { f in
            let child = try await f.controlledChild()
            let id = try XCTUnwrap(child.activeAgentSessionID)
            let message = "Network idle CU steer accepted exactly once"
            f.beforeSteerDispatch = { f.window.apiSettingsViewModel.isCodexConnected = true }
            let response = try await f.transport.callTool(name: "agent_run", arguments: [
                "op": "steer", "session_id": id.uuidString,
                "message": message, "wait": false, "_rawJSON": true
            ])
            XCTAssertFalse(response.rawJSON.contains("\"isError\":true"), response.rawJSON)
            try await AsyncTestWait.waitUntil("Network steer reaches fake native controller", timeout: 8) {
                (child.codexController as? WedgeFakeCodexController)?.startedTurnCount == 1
            }
            let controller = try XCTUnwrap(child.codexController as? WedgeFakeCodexController)
            XCTAssertEqual(controller.startedTurnCount, 1)
            XCTAssertEqual(controller.startedTexts.count, 1)
            XCTAssertTrue(controller.startedTexts[0].contains(message))
            await f.vm.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "network-steer-turn"), session: child, sourceController: controller)
            await f.vm.test_codexCoordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "network-steer-turn", status: .completed), session: child, sourceController: controller)
            try await AsyncTestWait.waitUntil("Completed network steer retires", timeout: 8) {
                ComputerUseChildProof.holder == nil && controller.shutdownCount == 1
            }
        }
    }

    func testIdleSteerCannotBorrowGrantReplacementDuringMetadataOrAuthorization() async throws {
        for phase in ["metadata", "authorization", "becomesCU"] {
            try await withRoute { f in
                let child = try await f.controlledChild(computerUse: phase != "becomesCU")
                let originalGrant = try XCTUnwrap(f.parent.computerUseParentGrant)
                var suspended = false
                let change: @MainActor () async -> Void = {
                    suspended = true
                    f.parent.computerUseParentGrant = nil
                    await Task.yield()
                    f.parent.computerUseParentGrant = UUID()
                    if phase == "becomesCU" { child.purpose = "computerUse" }
                }
                if phase == "authorization" { f.beforeAuthorization = change }
                else { f.beforeMetadata = change }
                let response = try await f.transport.callTool(name: "agent_run", arguments: [
                    "op": "steer", "session_id": child.activeAgentSessionID!.uuidString,
                    "message": "Do not borrow the replacement grant", "wait": false, "_rawJSON": true
                ])
                XCTAssertTrue(suspended, phase)
                XCTAssertNotEqual(f.parent.computerUseParentGrant, originalGrant)
                XCTAssertTrue(response.rawJSON.contains(ComputerUseChildProof.denied), "\(phase): \(response.rawJSON)")
                XCTAssertEqual(f.submissions, 0)
                XCTAssertNil(child.computerUseChildProof)
                XCTAssertNil(ComputerUseChildProof.holder)
            }
        }
    }

    func testRealStarterRollsBackPersistedUnsubmittedChildAndAllowsRetry() async throws {
        for phase in ["acknowledgement", "dispatch"] {
            for replacement in [false, true] {
                try await withRoute(realStarter: true) { f in
                    var failedChild: AgentTabSession?
                    var failedChildID: UUID?
                    var acknowledged = false
                    var invalidated = false
                    let mutate: @MainActor () async throws -> Void = {
                        invalidated = true
                        if replacement { try await f.installRoute(replacement: true) }
                        else { await f.revoke() }
                    }
                    f.vm.test_afterConfiguredCreationAcknowledgement = { handle in
                        guard handle.session.isComputerUseChild else { return }
                        failedChild = handle.session
                        failedChildID = handle.bindingToken.bindingIdentity.sessionID
                        acknowledged = true
                        do {
                            let workspace = try XCTUnwrap(f.window.workspaceManager.activeWorkspace)
                            let saved = try await AgentSessionDataService.shared.loadAgentSession(id: handle.bindingToken.bindingIdentity.sessionID, for: workspace)
                            XCTAssertEqual(saved?.purpose, "computerUse", "Must cross real configured persistence")
                            XCTAssertEqual(f.vm.test_outstandingProvisionalMCPSessionTargetCount, 1)
                            if phase == "acknowledgement" { try await mutate() }
                        } catch { XCTFail("Configured acknowledgement: \(error)") }
                    }
                    if phase == "dispatch" {
                        f.beforeAdmission = {
                            XCTAssertTrue(try XCTUnwrap(failedChild?.computerUseChildProof).instructionDispatchEntered)
                            try await mutate()
                        }
                    }
                    let response = try await f.transport.callTool(name: "agent_run", arguments: start)
                    XCTAssertEqual(f.startEntries, 1, response.rawJSON)
                    XCTAssertTrue(acknowledged, response.rawJSON)
                    XCTAssertTrue(invalidated)
                    XCTAssertTrue(response.rawJSON.contains(ComputerUseChildProof.denied), "\(phase)/\(replacement): \(response.rawJSON)")
                    XCTAssertEqual(f.submissions, 0)
                    let child = try XCTUnwrap(failedChild)
                    let childID = try XCTUnwrap(failedChildID)
                    try await AsyncTestWait.waitUntil("Persisted CU rollback", timeout: 8) {
                        f.vm.test_outstandingProvisionalMCPSessionTargetCount == 0
                            && f.vm.test_pendingMCPSessionTargetDiscardCount == 0 && ComputerUseChildProof.holder == nil
                    }
                    XCTAssertNil(child.codexController)
                    XCTAssertNil(f.vm.sessions[child.tabID])
                    XCTAssertNil(f.vm.sessionIndex[childID])
                    let workspace = try XCTUnwrap(f.window.workspaceManager.activeWorkspace)
                    XCTAssertFalse(workspace.composeTabs.contains { $0.id == child.tabID || $0.activeAgentSessionID == childID })
                    let saved = try await AgentSessionDataService.shared.loadAgentSession(id: childID, for: workspace)
                    XCTAssertNil(saved)
                    let children = try await AgentSessionDataService.shared.computerUseChildIDs(for: XCTUnwrap(f.parent.activeAgentSessionID), workspace: workspace)
                    XCTAssertEqual(children, [])
                    f.vm.test_afterConfiguredCreationAcknowledgement = nil
                    f.beforeAdmission = nil
                    await f.revoke()
                    f.server.removeTabContext(forConnectionID: f.transport.connectionID, clientName: f.transport.clientName, windowID: f.window.windowID, runID: f.runID)
                    try await f.installRoute()
                    let retry = try await f.transport.callTool(name: "agent_run", arguments: start)
                    XCTAssertFalse(retry.rawJSON.contains("\"isError\":true"), retry.rawJSON)
                    XCTAssertEqual(f.submissions, 1)
                    XCTAssertEqual(f.startEntries, 2)
                    let retryChild = try XCTUnwrap(ComputerUseChildProof.holder?.child)
                    try await AsyncTestWait.waitUntil("Retry reaches fake native controller", timeout: 8) {
                        (retryChild.codexController as? WedgeFakeCodexController)?.startedTurnCount == 1
                    }
                    let controller = try XCTUnwrap(retryChild.codexController as? WedgeFakeCodexController)
                    await f.vm.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "rollback-retry-turn"), session: retryChild, sourceController: controller)
                    await f.vm.test_codexCoordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "rollback-retry-turn", status: .completed), session: retryChild, sourceController: controller)
                    try await AsyncTestWait.waitUntil("Successful retry retires before fixture teardown", timeout: 8) {
                        ComputerUseChildProof.holder == nil && controller.shutdownCount == 1
                    }
                }
            }
        }
    }

    func testDisabledAfterOrdinaryAdmissionCannotIssueComputerUseCandidate() async throws {
        try await withRoute { f in
            var disabled = false
            let token = await f.manager.registerToolEventObserver(for: f.runID, observer: .init(
                onCalled: { _, name, _ in
                    guard name == "agent_run" else { return }
                    await f.manager.setEnabled(false)
                    await MainActor.run { disabled = true }
                }, onCompleted: nil
            ))
            func restore() async {
                await f.manager.unregisterToolEventObserver(for: f.runID, token: token)
                await f.manager.setEnabled(true)
            }
            do {
                let response = try await f.transport.callTool(name: "agent_run", arguments: start)
                XCTAssertTrue(disabled)
                let route = await f.manager.cachedModelRunRoute(connectionID: f.transport.connectionID)
                XCTAssertEqual(route?.runID, f.runID, "Disabling does not retire the installed route")
                XCTAssertTrue(response.rawJSON.contains(ComputerUseChildProof.denied), response.rawJSON)
                XCTAssertEqual(f.startEntries, 0)
                XCTAssertEqual(f.submissions, 0)
                await restore()
            } catch {
                await restore()
                throw error
            }
        }
    }

    func testIdleSteerForwardsCapturedProofAcrossSuspension() async throws {
        try await withRoute(realSteer: true) { f in
            let child = try await f.controlledChild()
            let id = try XCTUnwrap(child.activeAgentSessionID)
            var original: ComputerUseChildProof?
            var replacement: ComputerUseChildProof?
            var providerStarts = 0
            f.vm.test_providerSwitchStart = { _, _, _ in providerStarts += 1 }
            f.beforeSteerDispatch = {
                await Task.yield()
                do {
                    let captured = try XCTUnwrap(child.computerUseChildProof)
                    original = captured
                    captured.child = nil
                    captured.producerSettled()
                    let successor = try ComputerUseChildProof.capture(owner: f.vm, configuration: {
                        .init(enabled: true, modelID: "codexExec:gpt-6.1-sol-high", modelAvailable: true)
                    })
                    try successor.reserve()
                    successor.child = child
                    child.computerUseChildProof = successor
                    XCTAssertTrue(successor.permits(child), "Substitution must be otherwise admissible")
                    replacement = successor
                } catch { XCTFail("Proof substitution failed: \(error)") }
            }
            let response = try await f.transport.callTool(name: "agent_run", arguments: [
                "op": "steer", "session_id": id.uuidString, "message": "Fake exact proof", "wait": false, "_rawJSON": true
            ])
            let captured = try XCTUnwrap(original)
            let successor = try XCTUnwrap(replacement)
            XCTAssertTrue(response.rawJSON.contains(ComputerUseChildProof.denied), response.rawJSON)
            XCTAssertFalse(captured.instructionDispatchEntered)
            XCTAssertFalse(successor.instructionDispatchEntered, "A mutable-proof reread would enter the successor")
            XCTAssertEqual(providerStarts, 0)
            // Positive control: the same real dispatch path admits the supplied successor far
            // enough to mark submission. The existing provider-start override prevents launch.
            _ = try? await f.vm.mcpDispatchInstruction(sessionID: id, text: "Fake control", allowStartingRun: true, computerUseProof: successor)
            XCTAssertTrue(successor.instructionDispatchEntered)
        }
    }

    func testNetworkStartRejectsExplicitForeignContexts() async throws {
        for scope in ["window", "workspace", "tab"] {
            try await withRoute { f in
                var arguments = start
                if scope == "window" { arguments["_windowID"] = f.base.contextB.window.windowID }
                else if scope == "workspace" { arguments["_tabID"] = f.base.contextB.tabID.uuidString }
                else { arguments["_tabID"] = f.visible.tabID.uuidString }
                let response = try await f.transport.callTool(name: "agent_run", arguments: arguments)
                XCTAssertTrue(response.rawJSON.contains("\"isError\":true"), "\(scope): \(response.rawJSON)")
                XCTAssertEqual(f.startEntries, 0)
                XCTAssertEqual(f.submissions, 0)
                XCTAssertFalse(f.vm.sessions.values.contains(where: \.isComputerUseChild))
            }
        }
    }

    func testNetworkStartRechecksParentIdentityAndGrantAfterSuspension() async throws {
        for change in ["binding", "run", "grant"] {
            try await withRoute { f in
                f.beforeAdmission = {
                    if change == "binding" {
                        _ = try XCTUnwrap(f.vm.test_installPersistentSessionBinding(sessionID: UUID(), on: f.parent))
                    } else if change == "run" { f.parent.installRunID(UUID()) }
                    else { f.parent.computerUseParentGrant = nil }
                }
                let response = try await f.transport.callTool(name: "agent_run", arguments: start)
                XCTAssertEqual(f.startEntries, 1, "Mutation must run after the original capture")
                XCTAssertTrue(response.rawJSON.contains(ComputerUseChildProof.denied), "\(change): \(response.rawJSON)")
                XCTAssertEqual(f.submissions, 0)
                try await AsyncTestWait.waitUntil("Stale parent rollback", timeout: 5) {
                    f.vm.test_outstandingProvisionalMCPSessionTargetCount == 0 && ComputerUseChildProof.holder == nil
                }
                XCTAssertFalse(f.vm.sessions.values.contains(where: \.isComputerUseChild))
            }
        }
    }

    func testNetworkComputerUseStartPreservesCallingParent() async throws {
        for provider in [AgentProviderKind.claudeCode, .cursor] {
            try await withRoute(provider: provider) { f in
                let response = try await f.transport.callTool(name: "agent_run", arguments: start)
                XCTAssertFalse(response.rawJSON.contains("\"isError\":true"), response.rawJSON)
                XCTAssertTrue(response.rawJSON.contains("completed"), response.rawJSON)
                XCTAssertEqual(f.submissions, 1)
                XCTAssertEqual(f.startEntries, 1)
                XCTAssertNil(f.visible.computerUseParentGrant)
                XCTAssertFalse(f.vm.sessions.values.contains { $0.parentSessionID == f.visible.activeAgentSessionID })
                XCTAssertEqual(f.vm.test_outstandingProvisionalMCPSessionTargetCount, 0)
            }
        }
    }

    func testNetworkStartCannotBorrowVisibleGrant() async throws {
        for visibleGranted in [false, true] {
            try await withRoute { f in
                f.parent.computerUseParentGrant = nil
                f.visible.computerUseParentGrant = visibleGranted ? UUID() : nil
                let response = try await f.transport.callTool(name: "agent_run", arguments: start)
                XCTAssertTrue(response.rawJSON.contains(ComputerUseChildProof.denied), response.rawJSON)
                XCTAssertEqual(f.submissions, 0)
                XCTAssertEqual(f.startEntries, 0)
                XCTAssertFalse(f.vm.sessions.values.contains(where: \.isComputerUseChild))
            }
        }
    }

    func testNetworkStartRefusesAbsentUncommittedRevokedAndReplacedRoutes() async throws {
        for mutation in ["absent", "uncommitted", "revoked", "replaced"] {
            try await withRoute(install: mutation != "absent") { f in
                if mutation == "uncommitted" {
                    await f.manager.debugSupersedePendingPolicyApplicationOwnership(connectionID: f.transport.connectionID, runID: f.runID)
                } else if mutation == "revoked" {
                    await f.revoke()
                } else if mutation == "replaced" {
                    f.server.connectionIDByRunID[f.runID] = UUID()
                }
                let response = try await f.transport.callTool(name: "agent_run", arguments: start)
                XCTAssertTrue(response.rawJSON.contains("\"isError\":true"), "\(mutation): \(response.rawJSON)")
                XCTAssertEqual(f.submissions, 0, mutation)
                XCTAssertEqual(f.startEntries, 0, mutation)
                XCTAssertFalse(f.vm.sessions.values.contains(where: \.isComputerUseChild), mutation)
            }
        }
    }

    func testNetworkStartFencesRevocationAndReplacementAcrossAwaits() async throws {
        for phase in ["entry", "setup", "submission"] {
            for replacement in [false, true] {
                try await withRoute { f in
                    var mutationApplied = false
                    let mutate: @MainActor () async throws -> Void = {
                        mutationApplied = true
                        if replacement { try await f.installRoute(replacement: true) }
                        else { await f.revoke() }
                    }
                    if phase == "entry" {
                        await AppDomainRuntimeComposition.shared.runtime.domainHost.debugSetBeforeProviderActivationForTesting { _, tool, _ in
                            if tool == "agent_run" { try? await mutate() }
                        }
                    } else if phase == "setup" {
                        f.beforeStartDispatch = { try? await mutate() }
                    } else {
                        f.beforeAdmission = mutate
                    }
                    let response = try await f.transport.callTool(name: "agent_run", arguments: start)
                    XCTAssertTrue(response.rawJSON.contains(ComputerUseChildProof.denied), "\(phase)/\(replacement): \(response.rawJSON)")
                    XCTAssertEqual(f.submissions, 0)
                    XCTAssertTrue(mutationApplied, phase)
                    try await AsyncTestWait.waitUntil("CU rollback", timeout: 5) {
                        f.vm.test_outstandingProvisionalMCPSessionTargetCount == 0 && ComputerUseChildProof.holder == nil
                    }
                    XCTAssertFalse(f.vm.sessions.values.contains(where: \.isComputerUseChild))
                    let workspace = try XCTUnwrap(f.window.workspaceManager.activeWorkspace)
                    let children = try await AgentSessionDataService.shared.computerUseChildIDs(for: XCTUnwrap(f.parent.activeAgentSessionID), workspace: workspace)
                    XCTAssertEqual(children, [])
                }
            }
        }
    }

    func testAlreadyControlledIdleChildSteerUsesExactParent() async throws {
        for mutation in ["none", "wrongParent", "grantRevoked", "routeRevoked", "routeReplaced"] {
            try await withRoute { f in
                let previousFullAccess = OverseerGlobalAutoApprove.isEnabled
                defer { OverseerGlobalAutoApprove.isEnabled = previousFullAccess }
                OverseerGlobalAutoApprove.isEnabled = { mutation == "wrongParent" }
                let child = try await f.controlledChild(parentID: mutation == "wrongParent" ? f.visible.activeAgentSessionID : nil)
                if mutation == "wrongParent" {
                    try await AgentSessionTargetOperationGuard.require(
                        operation: .runSteer, caller: .agentSession(XCTUnwrap(f.parent.activeAgentSessionID)),
                        sessionID: XCTUnwrap(child.activeAgentSessionID), reference: nil,
                        agentModeVM: f.vm, workspace: f.window.workspaceManager.activeWorkspace
                    )
                }
                if mutation == "grantRevoked" {
                    let workspace = try XCTUnwrap(f.window.workspaceManager.activeWorkspace)
                    let saved = try await AgentSessionDataService.shared.loadAgentSession(id: XCTUnwrap(child.activeAgentSessionID), for: workspace)
                    XCTAssertEqual(saved?.purpose, "computerUse")
                    XCTAssertNil(child.computerUseChildProof, "Saved purpose must not reconstruct an operation proof")
                    f.parent.computerUseParentGrant = nil
                }
                if mutation == "routeRevoked" || mutation == "routeReplaced" {
                    f.beforeAdmission = {
                        if mutation == "routeReplaced" { try await f.installRoute(replacement: true) }
                        else { await f.revoke() }
                    }
                }
                let response = try await f.transport.callTool(name: "agent_run", arguments: [
                    "op": "steer", "session_id": child.activeAgentSessionID!.uuidString,
                    "message": "Inspect another fake window", "wait": false, "_rawJSON": true
                ])
                XCTAssertEqual(f.submissions, mutation == "none" ? 1 : 0, "\(mutation): \(response.rawJSON)")
                if mutation == "none" { XCTAssertFalse(response.rawJSON.contains("\"isError\":true"), response.rawJSON) }
                else { XCTAssertTrue(response.rawJSON.contains(ComputerUseChildProof.denied), response.rawJSON) }
            }
        }
    }

    func testOrdinaryStartAndSteerNeedNoComputerUseCandidate() async throws {
        for install in [false, true] {
            try await withRoute(install: install) { f in
                f.parent.computerUseParentGrant = nil
                let routing: [String: Any] = install ? [:] : ["_windowID": f.window.windowID]
                let response = try await f.transport.callTool(name: "agent_run", arguments: [
                    "op": "start", "model_id": "codexExec:gpt-6.1-sol-high", "message": "Ordinary fake task", "inherit_worktree": false, "detach": true, "_rawJSON": true
                ].merging(routing) { _, new in new })
                XCTAssertFalse(response.rawJSON.contains("\"isError\":true"), response.rawJSON)
                XCTAssertEqual(f.submissions, 1)
                let child = try await f.controlledChild(computerUse: false)
                if install { f.beforeAdmission = { await f.revoke() } }
                let steered = try await f.transport.callTool(name: "agent_run", arguments: [
                    "op": "steer", "session_id": child.activeAgentSessionID!.uuidString,
                    "message": "Ordinary fake followup", "wait": false, "_rawJSON": true
                ].merging(routing) { _, new in new })
                XCTAssertFalse(steered.rawJSON.contains("\"isError\":true"), steered.rawJSON)
                XCTAssertEqual(f.submissions, 2)
            }
        }
    }
}
