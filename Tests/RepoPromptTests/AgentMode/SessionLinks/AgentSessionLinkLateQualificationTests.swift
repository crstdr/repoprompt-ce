import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

#if DEBUG
    @MainActor
    final class AgentSessionLinkLateQualificationTests: XCTestCase {
        func testClaudeRunnerUsesOnlyCatalogReturnedBeforePhysicalInput() async throws {
            try await exerciseRunner(.claudeCode)
        }

        func testCodexReconnectUsesOnlyCatalogReturnedBeforePhysicalInput() async throws {
            try await exerciseRunner(.codexExec)
        }

        func testQualificationLogCost() throws {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "quiet-qualification", "Opt-in qualification diagnostic cost")
            let tabID = UUID()
            var samples: [Double] = []
            for ordinal in 0 ..< 1100 {
                let start = ContinuousClock.now
                let logged = AgentSessionLinkCatalogDiagnostics.quietQualification(
                    tabID: tabID, reserved: false, candidate: true, routingGeneration: 42,
                    definition: .exact, serverProof: true, ordinary: false, qualified: true
                )
                let duration = start.duration(to: .now)
                try XCTSkipUnless(logged, "Notice logging disabled: no enabled-path cost sample")
                if ordinal >= 100 {
                    samples.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
                }
            }
            samples.sort()
            print("QUIET_QUALIFICATION_LOG_COST count=\(samples.count) median_ms=\(samples[500]) p95_ms=\(samples[949]) max_ms=\(samples[999])")
        }

        private func exerciseRunner(_ kind: AgentProviderKind) async throws {
            // These are the two sides of the physical-input boundary, not provider permutations.
            for beforeSend in [true, false] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseRunner(kind, catalogBeforeSend: beforeSend)
                }
            }
        }

        private func exerciseRunner(_ kind: AgentProviderKind, catalogBeforeSend: Bool) async throws {
            let manager = ServerNetworkManager.shared
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let window = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
            let windowID = window.windowID
            WindowStatesManager.shared.registerWindowState(window)
            WindowStatesManager.shared.attachAgentSessionLinkBridge()
            let registration = try await AppDomainRuntimeComposition.shared.register(window.mcpServer.windowMCPToolCatalogService)
            let vm = window.agentModeViewModel
            let wasClaudeConnected = window.apiSettingsViewModel.isClaudeCodeConnected
            let wasCodexConnected = window.apiSettingsViewModel.isCodexConnected
            let bridge = AgentSessionLinkRuntimeBridge.shared
            let provider = HeldDiscoveryProvider()
            let clientName = kind == .codexExec ? AgentProviderKind.codexMCPClientID : AgentProviderKind.claudeMCPClientID
            let runID = UUID()
            let observerTab = UUID()
            let targetTab = UUID()
            var transport: PersistentMCPTestEndpoint?
            var grant: DomainAgentSessionLinkReference?
            var session: AgentTabSession?
            var native: ClaudeNativeProcessSessionController?
            let codex = MonitorFakeCodexController(dispatches: MonitorCodexDispatchRecorder(), processID: getpid())
            let frames = WrittenFrames()
            let cleanup: @MainActor () async -> Void = {
                session?.oversight.autoWakeOnUpdates = false
                session?.agentTask?.cancel()
                session?.codexEventTask?.cancel()
                if let native { await native.shutdown() }
                await codex.shutdown()
                await session?.agentTask?.value
                await provider.shutdown()
                await manager.debugSetReturnedCatalogToolsForTesting(nil)
                if let grant { await bridge.revokeLink(linkID: grant.linkID, generation: grant.generation) }
                if let transport {
                    transport.client.close()
                    await transport.connectionManager.stop()
                    await manager.debugRemoveConnection(transport.connectionID)
                }
                await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
                await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
                window.apiSettingsViewModel.isClaudeCodeConnected = wasClaudeConnected
                window.apiSettingsViewModel.isCodexConnected = wasCodexConnected
                await window.tearDown()
                await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            do {
                await window.workspaceManager.awaitInitialized()
                var workspace = WorkspaceModel(name: "Late catalog qualification", repoPaths: [])
                workspace.isEphemeral = true
                workspace.composeTabs = [
                    ComposeTabState(id: observerTab, name: "Observer", activeAgentSessionID: UUID()),
                    ComposeTabState(id: targetTab, name: "Target", activeAgentSessionID: UUID())
                ]
                workspace.activeComposeTabID = observerTab
                for tab in workspace.composeTabs {
                    let payload = try AgentSession(id: XCTUnwrap(tab.activeAgentSessionID), workspaceID: workspace.id, composeTabID: tab.id, name: tab.name, agentKind: kind.rawValue, autoWakeOnOversightUpdates: false)
                    _ = try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace)
                }
                window.workspaceManager.workspaces.append(workspace)
                let switched = await window.workspaceManager.switchWorkspace(to: workspace, saveState: false)
                XCTAssertTrue(switched.didSwitch)
                window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: false)
                let observer = await vm.ensureSessionReady(tabID: observerTab, reconnectActiveProviders: false)
                session = observer
                let target = await vm.ensureSessionReady(tabID: targetTab, reconnectActiveProviders: false)
                observer.installRunID(runID)
                observer.appendItem(.user("ordinary baseline", sequenceIndex: observer.nextSequenceIndex))
                observer.appendItem(.assistant("ordinary conclusion", sequenceIndex: observer.nextSequenceIndex))
                observer.runState = .completed
                vm.refreshDerivedTranscriptState(for: observer, publishActivePresentation: false)
                let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(vm, tabID: observerTab)
                guard case .added = try await bridge.addMonitorLink(observerSessionID: endpoint.sessionID, rawTargetSessionID: XCTUnwrap(target.activeAgentSessionID).uuidString) else {
                    throw CancellationError()
                }
                let links = await AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority.links(forObserver: endpoint.sessionID)
                let link = try XCTUnwrap(links.items.first)
                grant = .init(linkID: link.linkID, generation: link.generation)
                // The initial actual tools/list proves only the oversight family. There is no
                // preloaded self_noop definition and no injected projection or route token.
                await manager.debugSetReturnedCatalogToolsForTesting { tools, _ in tools.filter { $0.name != MCPWindowToolName.selfNoop } }
                await manager.installClientConnectionPolicy(for: clientName, windowID: windowID, restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true, reason: "late-catalog fixture", ttl: 60, tabID: observerTab, runID: runID, additionalTools: nil, purpose: .agentModeRun, taskLabelKind: nil, allowsAgentExternalControlTools: false)
                await manager.setEnabled(true)
                let initial = try await PersistentMCPTestEndpoint.make(label: "late-catalog-initial", networkManager: manager, clientName: clientName, requiredToolNames: [MCPWindowToolName.agentSessionLink])
                transport = initial
                await provider.attach(initial)
                _ = try await provider.listTools()
                XCTAssertFalse(vm.selfNoopHintIsCurrent(for: observer))
                observer.isPreparingInitialWorktree = true
                observer.oversight.autoWakeOnUpdates = true
                target.installRunID(UUID())
                _ = target.beginRunAttempt(source: "late-catalog ordinary cause")
                target.runState = .running
                target.appendItem(.assistant("ordinary cause", sequenceIndex: target.nextSequenceIndex))
                await vm.test_finishQuietFeasibilityRun(target)
                await bridge.test_settleTargetPublications()
                await bridge.test_refreshStatus(sessionIDs: [endpoint.sessionID])
                let attempt = try XCTUnwrap(observer.oversight.pendingAutoWake)
                attempt.task?.cancel()
                await attempt.task?.value
                let dispatchID = AgentSessionLinkPromptDispatchID.autoWake(wakeID: attempt.wakeID)
                let early = try XCTUnwrap(vm.agentSessionLinkPromptClaim(for: observer, dispatchID: dispatchID))
                XCTAssertFalse(early.routineQuietCheckIn)
                observer.isPreparingInitialWorktree = false
                XCTAssertNotNil(vm.agentSessionLinkPrepareAutoWakeDispatch(wakeID: attempt.wakeID, endpoint: endpoint))
                // Keep the production policy installer. Only process/PID admission is replaced
                // with this test process's real socket client after that policy has been installed.
                vm.test_initializeRunService(mcpServerEnabler: { true }, expectedPIDPolicyArmer: { spec in
                    guard let name = spec.clientName else { return false }
                    await manager.registerExpectedAgentPID(getpid(), for: name, runID: spec.runID)
                    let armed = await manager.requireExpectedAgentPIDForPendingPolicy(for: name, runID: spec.runID, windowID: spec.windowID)
                    guard armed else { return false }
                    if catalogBeforeSend { await manager.debugSetReturnedCatalogToolsForTesting(nil) }
                    do {
                        let next = try await PersistentMCPTestEndpoint.make(label: "late-catalog-current-policy", networkManager: manager, clientName: name, useProductionAgentAdmission: true, requiredToolNames: [MCPWindowToolName.agentSessionLink])
                        await provider.attach(next)
                        _ = try await provider.listTools()
                        try await Self.assertReturnedDeclaration(runID: spec.runID, expected: catalogBeforeSend)
                        let committed = await manager.isRunRouteAuthoritativelyCommitted(runID: spec.runID, windowID: spec.windowID, tabID: spec.tabID, expectedAgentPID: getpid())
                        await manager.clearExpectedAgentPID(getpid(), for: name, runID: spec.runID)
                        return committed
                    } catch {
                        XCTFail("Actual startup catalog failed: \(error)")
                        await manager.clearExpectedAgentPID(getpid(), for: name, runID: spec.runID)
                        return false
                    }
                })
                if kind == .claudeCode {
                    window.apiSettingsViewModel.isClaudeCodeConnected = true
                    let controller = ClaudeNativeProcessSessionController(runID: runID, tabID: observerTab, windowID: windowID, workspacePath: nil, config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard))
                    native = controller
                    await controller.test_installConfigurationTransport(initialized: false, controlRequest: { _ in ["session_id": "late-catalog-claude"] }, write: { frames.append($0) })
                    observer.claudeController = controller
                    let binding = vm.providerBindingService
                    let runtime = ClaudeControllerLaunchPolicy.resolve(permissionMode: binding.runtimePermission(for: kind, profile: observer.permissionProfile).claudePermissionMode, profile: observer.permissionProfile, defaults: binding.preferences.defaults, securePermissions: binding.preferences.securePermissions)
                    let permission = ClaudeAgentToolPreferences.resolvePermissionMode(requestedMode: runtime.permissionMode ?? observer.permissionProfile.claudePermissionMode, agentKind: kind, selectedModelRaw: observer.selectedModelRaw, unsupportedAutoFallback: .autoApproveEdits)
                    try vm.test_claudeCoordinator.test_setControllerLaunchSettings(.init(runtimeVariant: .standard, workspacePath: vm.effectiveWorkspacePath(for: observer), permissionMode: permission.effectiveMode, allowNativeBashTool: runtime.allowNativeBashTool, mcpStrictMode: runtime.mcpStrictMode), for: observer)
                } else {
                    window.apiSettingsViewModel.isCodexConnected = true
                    observer.codexController = codex
                    observer.codexNeedsReconnect = true
                    observer.codexControllerPermissionProfile = observer.permissionProfile
                    observer.codexControllerTaskLabelKind = observer.mcpControlContext?.taskLabelKind
                    observer.codexControllerWorkspacePaths = try vm.codexRuntimeWorkspacePaths(for: observer)
                    observer.codexControllerFeatureState = .init(computerUseEnabled: false, goalSupportEnabled: CodexGoalSupport.isEnabled, reasoningSummariesEnabled: CodexReasoningSummaries.isEnabled, memoriesEnabled: CodexMemories.isEnabled, capabilities: vm.providerBindingService.codexCapabilitiesForLaunch(isMCPRelated: observer.isMCPRelated))
                    codex.setStartOrResumeHook {
                        await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                        let armed = await manager.requireExpectedAgentPIDForPendingPolicy(for: clientName, runID: runID, windowID: windowID)
                        if catalogBeforeSend { await manager.debugSetReturnedCatalogToolsForTesting(nil) }
                        do {
                            XCTAssertTrue(armed)
                            let next = try await PersistentMCPTestEndpoint.make(label: "late-catalog-codex-startup", networkManager: manager, clientName: clientName, useProductionAgentAdmission: true, requiredToolNames: [MCPWindowToolName.agentSessionLink])
                            await provider.attach(next)
                            _ = try await provider.listTools()
                            try await Self.assertReturnedDeclaration(runID: runID, expected: catalogBeforeSend)
                        } catch {
                            XCTFail("Actual Codex startup socket failed: \(error)")
                        }
                        await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                    }
                }
                let outcome = AgentRunStartOutcomeRecorder()
                await vm.startAgentRun(tabID: observerTab, initialMessage: "", directStartOptions: .laneUpdate(wakeID: attempt.wakeID), startOutcome: outcome)
                XCTAssertEqual(outcome.outcome, .accepted)
                try await AsyncTestWait.waitUntil("one real runner physical input") { kind == .claudeCode ? !frames.userMessages.isEmpty : !codex.startedTurns.isEmpty }
                let sent = kind == .claudeCode ? frames.userMessages : codex.startedTurns
                XCTAssertEqual(sent.count, 1)
                XCTAssertEqual(try XCTUnwrap(sent.first).contains("Nothing needed? Call self_noop."), catalogBeforeSend)
                let owner = try XCTUnwrap(observer.activeRunOwnership)
                XCTAssertEqual(observer.quietLedger.routineWakeID(owner: owner) == attempt.wakeID, catalogBeforeSend)
                XCTAssertEqual(observer.quietLedger.hasOrdinaryOccurrence(owner: owner), !catalogBeforeSend)
                if !catalogBeforeSend {
                    await manager.debugSetReturnedCatalogToolsForTesting(nil)
                    let afterSendTools = try await provider.listTools()
                    XCTAssertTrue(afterSendTools.contains(MCPWindowToolName.selfNoop))
                    XCTAssertNil(observer.quietLedger.routineWakeID(owner: owner), "Post-send evidence never upgrades the attempt")
                    XCTAssertTrue(observer.quietLedger.hasOrdinaryOccurrence(owner: owner))
                }
                // Both providers acknowledge the original debt, not a newly selected batch.
                await bridge.test_settleTargetPublications()
                await bridge.test_refreshStatus(sessionIDs: [endpoint.sessionID])
                let remaining = vm.agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID]
                XCTAssertFalse(remaining?.entries.contains { $0.isRoutineWakeEligible } ?? false)
                XCTAssertTrue(observer.liveItemIDs.contains(attempt.wakeID))
                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        }

        private static func assertReturnedDeclaration(runID: UUID, expected: Bool) async throws {
            let manager = ServerNetworkManager.shared
            let observed = await manager.debugRunCatalogProjection(for: runID)
            let projection = try XCTUnwrap(observed)
            let route = try XCTUnwrap(projection.routeToken)
            let returned = await manager.hasCurrentReturnedTool(AgentModeViewModel.selfNoopCatalogDefinition, routeToken: route, projectionRevision: projection.projectionRevision)
            XCTAssertEqual(returned, expected, "The real startup socket, not a supplied readiness result, establishes support")
        }

        private final class WrittenFrames: @unchecked Sendable {
            private let lock = NSLock()
            private var frames: [Data] = []
            func append(_ data: Data) {
                lock.withLock { frames.append(data) }
            }

            var userMessages: [String] {
                lock.withLock { frames }.compactMap { data in
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["type"] as? String == "user", let message = object["message"] as? [String: Any] else { return nil }
                    let content = message["content"] as? [[String: Any]]
                    return content?.compactMap { $0["text"] as? String }.joined()
                }
            }
        }
    }
#endif
