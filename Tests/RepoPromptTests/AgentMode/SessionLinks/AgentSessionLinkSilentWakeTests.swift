import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

/// Native transport fakes drive the existing bridge/reducer/coordinator; no paid provider or app launch.
@MainActor
extension AgentSessionLinkRuntimeBridgeTests {
    func testNativeCodexSilentRoutineCompletionDoesNotAdmitObserverButToolOnlyDoes() async throws {
        try await assertNativeWake(.silent, expectedAdmission: false)
        try await assertNativeWake(.toolOnly, expectedAdmission: true)
    }

    func testNativeCodexHumanInputAndVisibleOutputKeepRoutineWake() async throws {
        try await assertNativeWake(.human, expectedAdmission: true)
        try await assertNativeWake(.visible, expectedAdmission: true)
    }

    func testNativeCodexAttentionAndFailureKeepWake() async throws {
        try await assertNativeWake(.attention, expectedAdmission: true)
        try await assertNativeWake(.failure, expectedAdmission: true)
    }

    func testNativeCodexTeardownKeepsProofButRestoreFailsOpen() async throws {
        try await assertNativeWake(.teardown, expectedAdmission: false)
        try await assertNativeWake(.restore, expectedAdmission: true)
    }

    func testNativeCodexTerminalBeforeAcceptanceDefersThenFinishesQuietly() async throws {
        try await assertNativeWake(.terminalBeforeAcceptance, expectedAdmission: false)
    }

    func testNativeClaudeSilentRoutineCompletionDoesNotAdmitObserverButToolOnlyDoes() async throws {
        try await assertNativeWake(.silent, expectedAdmission: false, agent: .claudeCode)
        try await assertNativeWake(.toolOnly, expectedAdmission: true, agent: .claudeCode)
    }

    func testNativeTwoAgentEchoRingStopsAtFirstSilentTurn() async throws {
        try await assertNativeRing(toolOnly: false, horizon: 7, expectedCalls: 5)
    }

    func testNativeTwoAgentToolOnlyRingKeepsAllSixCalls() async throws {
        try await assertNativeRing(toolOnly: true, horizon: 6, expectedCalls: 6)
    }

    func testNativeRowlessUserInputAndBulkReplacementFailOpen() async throws {
        try await assertNativeWake(.rowlessInput, expectedAdmission: true)
        try await assertNativeWake(.bulkReplacement, expectedAdmission: true)
    }

    func testNativeRuntimeReplacementFailsOpenButLateUnownedOutputIsRejected() async throws {
        try await assertNativeWake(.controllerReplacement, expectedAdmission: true)
        try await assertNativeWake(.lateUnownedOutput, expectedAdmission: false)
        try await assertNativeWake(.lateToolOutput, expectedAdmission: true)
    }

    func testNativeRejectedTerminalPublicationResolvesPendingQuietEdgeOrdinary() async throws {
        try await assertNativeWake(.rejectedPublication, expectedAdmission: true)
    }

    func testNativeClaudeUnknownStreamFailsOpenButKnownTransientEventsStayQuiet() async throws {
        try await assertNativeWake(.unknownStream, expectedAdmission: true, agent: .claudeCode)
        try await assertNativeWake(.transientStreams, expectedAdmission: false, agent: .claudeCode)
    }

    func testNativeCanonicalPublicationHoldDoesNotReserveOrCrossObserverFence() async throws {
        try await assertNativeWake(.acceptedPublication, expectedAdmission: false)
    }

    private struct NativeRingPeer {
        let vm: AgentModeViewModel
        let session: AgentTabSession
        let candidate: AgentSessionLinkEndpointCandidate
        let workspace: WorkspaceManagerViewModel
        let codex: MonitorFakeCodexController
        let codexDispatches: MonitorCodexDispatchRecorder
        let claude: MonitorFakeNativeController
        let harness: AgentSessionLinkRunnerHarness
    }

    private func makeNativeRingPeer(agent: AgentProviderKind, windowID: Int) async throws -> NativeRingPeer {
        let dispatches = MonitorCodexDispatchRecorder()
        let codex = MonitorFakeCodexController(dispatches: dispatches)
        let claude = MonitorFakeNativeController()
        let vm = AgentModeViewModel(testWindowID: windowID, testWorkspacePath: FileManager.default.temporaryDirectory.path,
            shouldManageCodexTooling: false, codexControllerFactory: { _, _, _, _, _, _ in codex },
            claudeControllerFactory: { _, _, _, _ in claude },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in }, mcpServerEnabler: { true })
        let tabID = UUID()
        let workspace = AgentSessionLinkEndpointTestSupport.installWorkspace(on: vm, tabID: tabID, name: "Native ring")
        let session = vm.session(for: tabID)
        session.selectedAgent = agent
        session.hasLoadedPersistedState = true
        session.installRunID(UUID())
        let sessionID = try XCTUnwrap(vm.test_ensureSessionBoundToTab(session))
        let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(tabID: tabID, sessionID: sessionID, tabName: "Ring peer", isWindowClosing: false))
        vm.test_initializeRunService()
        if agent == .codexExec {
            await vm.test_codexCoordinator.ensureCodexNativeSession(session: session)
        } else {
            let warm = session.beginRunAttempt(source: "test.ring.warm")
            let ready = await vm.test_claudeCoordinator.ensureClaudeNativeSession(session: session, intent: .runAttempt(ownership: warm, runID: try XCTUnwrap(session.runID)))
            XCTAssertEqual(ready, .ready)
            _ = session.endRunAttempt(ifCurrent: warm, source: "test.ring.warm")
        }
        let route = AgentSessionLinkRunCatalogRouteToken(runID: try XCTUnwrap(session.runID), observerEndpoint: candidate.domainEndpoint, connectionID: UUID(), routingAuthorityGeneration: 1, connectionLifecycleGeneration: 1)
        vm.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
        vm.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in route }
        vm.test_agentSessionLinkCurrentRunCatalogRouteToken = { _, _ in true }
        vm.agentSessionLinkPublishRunCatalogProjection(.init(runID: route.runID, routeToken: route, projectionRevision: 1, hasAgentSessionLink: true, hasAnyActiveLink: true), to: candidate.domainEndpoint)
        session.oversight.autoWakeOnUpdates = true
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, sessionLinkHost: vm)
        harness.nativeTranscriptHost = vm
        harness.onNativeStreamResult = { result, session, runID, attemptID in
            await vm.test_handleStreamResult(result, session: session, runID: runID, runAttemptID: attemptID)
        }
        return NativeRingPeer(vm: vm, session: session, candidate: candidate, workspace: workspace, codex: codex, codexDispatches: dispatches, claude: claude, harness: harness)
    }

    private func settleNativeObservations(_ bridge: AgentSessionLinkRuntimeBridge) async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await bridge.test_settleTargetPublications()
        await bridge.test_settleProjections()
    }

    private func assertNativeRing(toolOnly: Bool, horizon: Int, expectedCalls: Int) async throws {
        let first = try await makeNativeRingPeer(agent: .codexExec, windowID: 1)
        let second = try await makeNativeRingPeer(agent: .claudeCode, windowID: 2)
        let host = FakeEndpointHost()
        host.candidates = [first.candidate, second.candidate]
        host.observationViewModels = [first.candidate.sessionID: first.vm, second.candidate.sessionID: second.vm]
        host.forwardsNativeQueues = true
        host.autoWakeTargetsByEndpoint = [first.candidate.domainEndpoint: [second.candidate.sessionID], second.candidate.domainEndpoint: [first.candidate.sessionID]]
        let bridge = AgentSessionLinkRuntimeBridge(authority: makeAuthority(), host: host, toolAdvertisementInvalidator: { _ in })
        defer { bridge.freezeForTermination(); withExtendedLifetime([first.workspace, second.workspace]) {} }
        guard case .added = await bridge.addMonitorLink(observerSessionID: first.candidate.sessionID, rawTargetSessionID: second.candidate.sessionID.uuidString),
              case .added = await bridge.addMonitorLink(observerSessionID: second.candidate.sessionID, rawTargetSessionID: first.candidate.sessionID.uuidString) else {
            return XCTFail("Two direct grants must establish the ring")
        }
        for index in 1 ... horizon {
            let peer = index.isMultiple(of: 2) ? second : first
            let session = peer.session
            var receipt: AgentSessionLinkPassiveStatusNotices.Receipt?
            if index > 1 {
                guard let wake = session.oversight.pendingAutoWake else { break }
                wake.task?.cancel()
                let claim = try XCTUnwrap(peer.vm.agentSessionLinkPromptClaim(for: session, dispatchID: .autoWake(wakeID: wake.wakeID)))
                receipt = claim.passive?.receipt
                _ = try XCTUnwrap(peer.vm.agentSessionLinkPrepareAutoWakeDispatch(wakeID: wake.wakeID, endpoint: peer.candidate.domainEndpoint))
            }
            let text = index == 1 ? "Initial task" : ""
            if session.selectedAgent == .codexExec {
                _ = session.beginRunAttempt(source: "test.ring.turn", passiveWakeID: session.oversight.pendingAutoWake?.wakeID)
                let sent = await peer.vm.test_codexCoordinator.sendCodexNativeMessage(session: session, text: text, attachments: [])
                XCTAssertEqual(sent, .sent)
                await peer.vm.test_codexCoordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "ring-\(index)"), session: session, sourceController: peer.codex)
            } else {
                let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: peer.vm.test_claudeCoordinator, hooks: peer.harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
                await runner.startRun(tabID: session.tabID, session: session, initialUserMessage: text, initialMessageForRun: text, attachments: [], makeLease: { peer.harness.makeLease(runID: $0, tabID: session.tabID) }, passiveWakeID: session.oversight.pendingAutoWake?.wakeID)
                try await AsyncTestWait.waitUntil("ring Claude accepted turn") { !session.claudeExpectedTurnIDs.isEmpty }
            }
            if let receipt { bridge.applyPassiveMonitorNoticeReceipt(receipt, observerEndpoint: peer.candidate.domainEndpoint) }
            await settleNativeObservations(bridge)
            if session.selectedAgent == .codexExec {
                if toolOnly {
                    await peer.vm.test_codexCoordinator.test_handleCodexNativeEvent(.toolCall(name: "mcp__RepoPromptCE__poll", invocationID: UUID(), argsJSON: "{}"), session: session, sourceController: peer.codex)
                } else if index <= 4 {
                    await peer.vm.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("Useful \(index)"), session: session, sourceController: peer.codex)
                }
                await peer.vm.test_codexCoordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "ring-\(index)", status: .completed, failure: nil), session: session, sourceController: peer.codex)
            } else {
                if toolOnly {
                    await peer.claude.emit(.stream(.init(type: "tool_call", text: nil, toolName: "mcp__RepoPromptCE__poll", toolArgsJSON: "{}")))
                } else if index <= 4 {
                    await peer.claude.emit(.stream(.init(type: "content", text: "Useful \(index)")))
                }
                await peer.claude.emit(.turnCompleted(turnID: try XCTUnwrap(session.claudeExpectedTurnIDs.first), status: .completed))
                await session.agentTask?.value
            }
            XCTAssertEqual(session.lastTerminalPublicationResult, .accepted(successorEpoch: nil))
            await settleNativeObservations(bridge)
        }
        let claudeCalls = await second.claude.sentCount
        XCTAssertEqual(first.codexDispatches.startedTurns.count + claudeCalls, expectedCalls, "Count physical native invocations, not admission/helper calls")
        XCTAssertEqual(first.session.items.count(where: { $0.kind == .assistant }) + second.session.items.count(where: { $0.kind == .assistant }), toolOnly ? 0 : 4)
        await first.vm.test_codexCoordinator.shutdownCodexSession(first.session)
        await second.vm.test_claudeCoordinator.shutdownClaudeSession(second.session)
    }

    func testNativeUsefulDebtReceiptWhileSilentSuccessorRunsPaysOnlyPredecessor() async throws {
        try await assertNativeWake(.debtReceipt, expectedAdmission: false)
        try await assertNativeWake(.debtReceiptOmitted, expectedAdmission: true)
    }

    func testNativeFailureThenSilentSuccessKeepsUnreceiptedFailureDebt() async throws {
        try await assertNativeWake(.failureSuccessUnpaid, expectedAdmission: true)
        try await assertNativeWake(.failureSuccessPaid, expectedAdmission: false)
    }

    func testNativeSilentPreparationCannotMakeOlderSilentDebtOrdinary() async throws {
        try await assertNativeWake(.silentSuccessorPrepared, expectedAdmission: false)
    }

    private enum NativeWakeScenario {
        case silent, toolOnly, human, visible, attention, failure, teardown, restore, terminalBeforeAcceptance
        case debtReceipt, debtReceiptOmitted, failureSuccessUnpaid, failureSuccessPaid, silentSuccessorPrepared
        case rowlessInput, bulkReplacement, controllerReplacement, lateUnownedOutput, lateToolOutput, rejectedPublication, acceptedPublication, unknownStream, transientStreams
    }

    private func assertNativeWake(_ scenario: NativeWakeScenario, expectedAdmission: Bool, agent: AgentProviderKind = .codexExec) async throws {
        let lateInvocation = UUID()
        let toolOnly = scenario == .toolOnly || scenario == .lateToolOutput
        let hasSuccessor = [NativeWakeScenario.debtReceipt, .debtReceiptOmitted, .failureSuccessUnpaid, .failureSuccessPaid, .silentSuccessorPrepared].contains(scenario)
        let failsFirst = [.failure, .failureSuccessUnpaid, .failureSuccessPaid].contains(scenario)
        let dispatches = MonitorCodexDispatchRecorder()
        let controller = MonitorFakeCodexController(dispatches: dispatches)
        let claude = MonitorFakeNativeController()
        let vm = AgentModeViewModel(
            testWindowID: 1, testWorkspacePath: FileManager.default.temporaryDirectory.path,
            shouldManageCodexTooling: false,
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            claudeControllerFactory: { _, _, _, _ in claude },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let tabID = UUID()
        let workspace = AgentSessionLinkEndpointTestSupport.installWorkspace(on: vm, tabID: tabID, name: "Native wake")
        defer { withExtendedLifetime(workspace) {} }
        let session = vm.session(for: tabID)
        session.selectedAgent = agent
        session.hasLoadedPersistedState = true
        session.installRunID(UUID())
        let sessionID = try XCTUnwrap(vm.test_ensureSessionBoundToTab(session))
        let target = try XCTUnwrap(vm.agentSessionLinkCandidate(tabID: tabID, sessionID: sessionID, tabName: "Native target", isWindowClosing: false))
        let endpoint = target.domainEndpoint
        let observerVM = AgentModeViewModel(testWindowID: 2, testWorkspacePath: FileManager.default.temporaryDirectory.path, shouldManageCodexTooling: false, codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) })
        let observerTab = UUID()
        let observerWorkspace = AgentSessionLinkEndpointTestSupport.installWorkspace(on: observerVM, tabID: observerTab, name: "Observer")
        defer { withExtendedLifetime(observerWorkspace) {} }
        let observerSession = observerVM.session(for: observerTab)
        observerSession.selectedAgent = .openCode
        observerSession.hasLoadedPersistedState = true
        observerSession.oversight.autoWakeOnUpdates = true
        let observerID = try XCTUnwrap(observerVM.test_ensureSessionBoundToTab(observerSession))
        let observer = try XCTUnwrap(observerVM.agentSessionLinkCandidate(tabID: observerTab, sessionID: observerID, tabName: "Observer", isWindowClosing: false))
        let host = FakeEndpointHost()
        host.candidates = [observer, target]
        host.observationViewModels[sessionID] = vm
        let bridge = AgentSessionLinkRuntimeBridge(authority: makeAuthority(), host: host, toolAdvertisementInvalidator: { _ in })
        defer { bridge.freezeForTermination() }

        guard case .added = await bridge.addMonitorLink(observerSessionID: observer.sessionID, rawTargetSessionID: sessionID.uuidString) else {
            return XCTFail("Reverse observation must be established")
        }

        vm.test_initializeRunService()
        if agent == .codexExec {
            await vm.test_codexCoordinator.ensureCodexNativeSession(session: session)
        } else {
            let warm = session.beginRunAttempt(source: "test.warm.native")
            let ready = await vm.test_claudeCoordinator.ensureClaudeNativeSession(session: session, intent: .runAttempt(ownership: warm, runID: try XCTUnwrap(session.runID)))
            XCTAssertEqual(ready, .ready)
            _ = session.endRunAttempt(ifCurrent: warm, source: "test.warm.native")
        }
        let route = AgentSessionLinkRunCatalogRouteToken(runID: try XCTUnwrap(session.runID), observerEndpoint: endpoint, connectionID: UUID(), routingAuthorityGeneration: 1, connectionLifecycleGeneration: 1)
        vm.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
        vm.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in route }
        vm.test_agentSessionLinkCurrentRunCatalogRouteToken = { _, _ in true }
        vm.agentSessionLinkPublishRunCatalogProjection(.init(runID: route.runID, routeToken: route, projectionRevision: 1, hasAgentSessionLink: true, hasAnyActiveLink: true), to: endpoint)
        vm.agentSessionLinkPublishPromptInventory(.init(observerSessionID: sessionID, linkSetRevision: 1, items: [.init(targetSessionID: observer.sessionID, displayName: "Peer", capabilityNames: ["poll", "read"])]), to: endpoint)
        let reference = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
        let queue = AgentSessionLinkPassiveStatusNotices.Snapshot(observerEndpoint: endpoint, queueEpoch: UUID(), queueRevision: 1, linkSetRevision: 1, isEnabled: true, isDeliverable: true,
            entries: [.init(reference: reference, targetEndpoint: observer.domainEndpoint, targetSessionID: observer.sessionID, displayName: "Peer", fromStatus: .running, toStatus: .idle, changeSequence: 1)], unacknowledgedOverflowCount: 0, overflowProduced: 0,
            autoWakeLanes: [.init(reference: reference, targetEndpoint: observer.domainEndpoint, targetSessionID: observer.sessionID, isEffectivelySelected: true)])
        session.oversight.autoWakeOnUpdates = true
        // Hold reservation until this test supplies the deterministic native transport.
        vm.agentSessionLinkPublishPassiveStatusNotices(queue, to: endpoint)
        let wake = try XCTUnwrap(session.oversight.pendingAutoWake)
        wake.task?.cancel()
        session.runState = .idle
        _ = try XCTUnwrap(vm.agentSessionLinkPrepareAutoWakeDispatch(wakeID: wake.wakeID, endpoint: endpoint))
        let coordinator = vm.test_codexCoordinator
        let acceptanceGate = scenario == .terminalBeforeAcceptance ? TestReleaseFence(name: "native receipt") : nil
        defer { acceptanceGate?.release() }
        let publicationGate = scenario == .rejectedPublication || scenario == .acceptedPublication ? TestReleaseFence(name: "terminal publication") : nil
        defer { publicationGate?.release() }
        if let publicationGate {
            vm.test_setTerminalPublicationOverride { revision, successorKind, targetSession in
                await publicationGate.enterAndWait()
                if scenario == .rejectedPublication { return .rejected(reason: "fixture rejection") }
                vm.test_setTerminalPublicationOverride(nil)
                return await vm.test_publishTerminalCommit(revision, successorKind: successorKind, for: targetSession)
            }
        }
        var send: Task<CodexAgentModeCoordinator.NativeSendOutcome, Never>?
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, sessionLinkHost: vm)
        harness.nativeTranscriptHost = vm
        harness.onNativeStreamResult = { result, session, runID, attemptID in
            await vm.test_handleStreamResult(result, session: session, runID: runID, runAttemptID: attemptID)
        }
        if agent == .codexExec {
            _ = session.beginRunAttempt(source: "test.native.routine", passiveWakeID: session.oversight.pendingAutoWake?.wakeID)
            controller.setSendGate(acceptanceGate)
            let producer = Task { await coordinator.sendCodexNativeMessage(session: session, text: "", attachments: []) }
            send = producer
            if let acceptanceGate {
                let entered = await acceptanceGate.waitUntilEntered(timeout: 3)
                XCTAssertTrue(entered)
            } else {
                let outcome = await producer.value
                XCTAssertEqual(outcome, .sent)
                XCTAssertNil(session.oversight.pendingAutoWake, "Native acceptance consumes the wake")
            }
            XCTAssertEqual(dispatches.startedTurns.count, 1)
            await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "native-turn"), session: session, sourceController: controller)
        } else {
            let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: vm.test_claudeCoordinator, hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
            await runner.startRun(tabID: tabID, session: session, initialUserMessage: "", initialMessageForRun: "", attachments: [], makeLease: { harness.makeLease(runID: $0, tabID: tabID) }, passiveWakeID: session.oversight.pendingAutoWake?.wakeID)
            try await AsyncTestWait.waitUntil("native Claude accepted turn") { !session.claudeExpectedTurnIDs.isEmpty }
            let sent = await claude.sentCount
            XCTAssertEqual(sent, 1)
            XCTAssertEqual(session.passiveWakeSegment?.vetoed, false, "Warm accepted native send has no activity yet")
            XCTAssertNil(session.oversight.pendingAutoWake)
        }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await bridge.test_settleTargetPublications()
        await bridge.test_settleProjections()
        if toolOnly {
            if agent == .codexExec {
                let tool = scenario == .lateToolOutput ? "bash" : "mcp__RepoPromptCE__poll"
                await coordinator.test_handleCodexNativeEvent(.toolCall(name: tool, invocationID: lateInvocation, argsJSON: "{}"), session: session, sourceController: controller)
                if scenario == .lateToolOutput {
                    await coordinator.test_handleCodexNativeEvent(.toolResult(name: "bash", invocationID: lateInvocation, argsJSON: "{}", resultJSON: #"{"status":"failed","exit_code":1,"output":"Early"}"#, isError: true), session: session, sourceController: controller)
                    XCTAssertTrue(session.items.contains { $0.toolInvocationID == lateInvocation && $0.kind == .toolResult })
                    XCTAssertEqual(session.passiveWakeSegment?.vetoed, true, "Correlated identity was created during this exact segment")
                }
            } else {
                await claude.emit(.stream(.init(type: "tool_call", text: nil, toolName: "mcp__RepoPromptCE__poll", toolArgsJSON: "{}")))
            }
        }
        if scenario == .unknownStream { await claude.emit(.stream(.init(type: "unclassified-control", text: nil))) }
        if scenario == .transientStreams {
            for type in ["reasoning", "status", "usage", "session_state_changed", "task_progress", "message_stop", AIStreamResult.lifecycleType] {
                await claude.emit(.stream(.init(type: type, text: nil)))
            }
            await claude.emit(.stream(.init(type: "system", text: "Agent completed")))
        }
        if scenario == .visible || scenario == .debtReceipt || scenario == .debtReceiptOmitted {
            await coordinator.test_handleCodexNativeEvent(.assistantDelta("Done"), session: session, sourceController: controller)
        }
        if scenario == .human {
            XCTAssertEqual(vm.submitUserTurn(text: "User correction", tabID: tabID), .submitted)
            try await AsyncTestWait.waitUntil("native correction reaches transport") { !controller.steeredTurns.isEmpty }
            XCTAssertTrue(controller.steeredTurns.last?.contains("User correction") == true)
        }
        if scenario == .rowlessInput {
            let before = session.items.count(where: { $0.kind == .user })
            let waiting = Task { @MainActor in
                try await withCheckedThrowingContinuation { session.instructionContinuation = $0 }
            }
            try await AsyncTestWait.waitUntil("rowless instruction continuation") { session.instructionContinuation != nil }
            XCTAssertTrue(vm.resumeWaitingInstructionContinuation(session: session, providerText: "Correction", claim: nil, origin: .user))
            _ = try await waiting.value
            XCTAssertEqual(session.items.count(where: { $0.kind == .user }), before)
        }
        if scenario == .bulkReplacement {
            let row = AgentChatItem.system("Host repair", sequenceIndex: session.nextSequenceIndex)
            session.replaceItems([row, row])
            XCTAssertEqual(session.items.count, 1, "Existing bulk replacement deduplicates repeated IDs without an evidence baseline dictionary")
        }
        if scenario == .attention {
            let attention = await bridge.requestAttention(targetEndpoint: endpoint, observerSessionID: observer.sessionID)
            XCTAssertEqual(attention, .accepted(hasWaitingOn: false))
        }
        if agent == .codexExec {
            let terminal = Task { @MainActor in
                await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "native-turn", status: failsFirst ? .failed : .completed, failure: nil), session: session, sourceController: controller)
            }
            if let publicationGate {
                let entered = await publicationGate.waitUntilEntered(timeout: 3)
                XCTAssertTrue(entered)
                await settleNativeObservations(bridge)
                let pending = try XCTUnwrap(host.publishedPassiveNoticesByEndpoint[observer.domainEndpoint])
                XCTAssertEqual(pending.routineNonAdmittingReferences.count, 1)
                let edgeSequence = pending.entries.first?.edgeSequence
                observerVM.agentSessionLinkPublishPromptInventory(try XCTUnwrap(host.publishedInventoriesByEndpoint[observer.domainEndpoint]), to: observer.domainEndpoint)
                observerVM.agentSessionLinkPublishPassiveStatusNotices(pending, to: observer.domainEndpoint)
                XCTAssertNil(observerSession.oversight.pendingAutoWake, "Canonical hold cannot reserve an observer")
                // Model an already-preparing observer at the same public occurrence. The real
                // physical fence must re-read the now-published pending passive contribution.
                let witness = AgentSessionLinkAutoWakeAttempt(wakeID: UUID(), observerEndpoint: observer.domainEndpoint,
                    queueEpoch: pending.queueEpoch, queueRevision: pending.queueRevision, wakeFingerprint: pending.wakeEligibilityFingerprint,
                    admissionBasis: .routineStatusOrOverflow, attemptedFingerprint: nil, physicalOutcome: .notAttempted, phase: .preparingDispatch, task: nil)
                observerSession.oversight.pendingAutoWake = witness
                _ = try XCTUnwrap(observerVM.agentSessionLinkPromptClaim(for: observerSession, dispatchID: .autoWake(wakeID: witness.wakeID)))
                XCTAssertFalse(observerVM.agentSessionLinkAcquirePhysicalDispatch(for: observerSession, dispatchID: .autoWake(wakeID: witness.wakeID)))
                XCTAssertNil(observerSession.oversight.pendingAutoWake)
                publicationGate.release()
                await terminal.value
                await settleNativeObservations(bridge)
                let resolved = try XCTUnwrap(host.publishedPassiveNoticesByEndpoint[observer.domainEndpoint])
                XCTAssertEqual(resolved.routineNonAdmittingReferences.isEmpty, scenario == .rejectedPublication)
                XCTAssertEqual(resolved.entries.first?.edgeSequence, edgeSequence, "Settlement must not fabricate a status edge; ordinary readiness refresh keeps its existing revision behavior")
            } else {
                await terminal.value
            }
        } else {
            let turnID = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
            await claude.emit(.turnCompleted(turnID: turnID, status: failsFirst ? .failed : .completed))
            await session.agentTask?.value
        }
        XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, failsFirst ? .failed : .completed)
        XCTAssertEqual(session.lastTerminalPublicationResult, scenario == .rejectedPublication ? .rejected(reason: "fixture rejection") : .accepted(successorEpoch: nil))
        if scenario == .controllerReplacement { session.codexController = MonitorFakeCodexController(dispatches: MonitorCodexDispatchRecorder()) }
        if scenario == .lateUnownedOutput {
            let revision = session.sourceItemsRevision
            await coordinator.test_handleCodexNativeEvent(.assistantDelta("Late stale text"), session: session, sourceController: controller)
            await coordinator.test_handleCodexNativeEvent(.toolCall(name: "poll", invocationID: UUID(), argsJSON: "{}"), session: session, sourceController: controller)
            await coordinator.test_handleCodexNativeEvent(.commandExecutionRunning(.init(invocationID: UUID(), processID: "unknown", appendedOutput: "Late")), session: session, sourceController: controller)
            XCTAssertEqual(session.sourceItemsRevision, revision, "Inactive unowned output must remain rejected at native ingress")
        }
        if scenario == .lateToolOutput {
            let evidence = session.passiveWakeEvidence
            let revision = session.sourceItemsRevision
            await coordinator.test_handleCodexNativeEvent(.commandExecutionRunning(.init(invocationID: lateInvocation, processID: nil, appendedOutput: "AcceptedLate")), session: session, sourceController: controller)
            try await AsyncTestWait.waitUntil("correlated late command output materialized") {
                session.items.contains { $0.toolInvocationID == lateInvocation
                        && (($0.toolResultJSON?.contains("AcceptedLate") ?? false)
                            || (session.ephemeralToolResultPayloadByItemID[$0.id]?.contains("AcceptedLate") ?? false)) }
            }
            XCTAssertGreaterThan(session.sourceItemsRevision, revision, "Late native update must actually be accepted, not merely attempted")
            XCTAssertEqual(session.passiveWakeEvidence, evidence, "This exact segment's earlier tool ingress already vetoed silence")
        }
        if let acceptanceGate {
            observerVM.agentSessionLinkPublishPromptInventory(try XCTUnwrap(host.publishedInventoriesByEndpoint[observer.domainEndpoint]), to: observer.domainEndpoint)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            await bridge.test_settleTargetPublications()
            await bridge.test_settleProjections()
            let provisional = try XCTUnwrap(host.publishedPassiveNoticesByEndpoint[observer.domainEndpoint])
            observerVM.agentSessionLinkPublishPassiveStatusNotices(provisional, to: observer.domainEndpoint)
            observerSession.oversight.pendingAutoWake?.task?.cancel()
            XCTAssertNil(observerSession.oversight.pendingAutoWake, "Exact unresolved terminal contribution must not reserve while native acceptance is held")
            acceptanceGate.release()
            let producer = try XCTUnwrap(send)
            let outcome = await producer.value
            XCTAssertEqual(outcome, .sent)
        }
        if hasSuccessor {
            await settleNativeObservations(bridge)
            let predecessor = try XCTUnwrap(host.publishedPassiveNoticesByEndpoint[observer.domainEndpoint])
            XCTAssertEqual(predecessor.entries.count, 1)
            let successorQueue = AgentSessionLinkPassiveStatusNotices.Snapshot(observerEndpoint: endpoint, queueEpoch: queue.queueEpoch, queueRevision: 2, linkSetRevision: 1, isEnabled: true, isDeliverable: true,
                entries: [.init(reference: reference, targetEndpoint: observer.domainEndpoint, targetSessionID: observer.sessionID, displayName: "Peer", fromStatus: .running, toStatus: .idle, changeSequence: 2)], unacknowledgedOverflowCount: 0, overflowProduced: 0, autoWakeLanes: queue.autoWakeLanes)
            vm.agentSessionLinkPublishPassiveStatusNotices(successorQueue, to: endpoint)
            let successorWake = try XCTUnwrap(session.oversight.pendingAutoWake)
            successorWake.task?.cancel()
            session.runState = failsFirst ? .failed : .completed
            _ = try XCTUnwrap(vm.agentSessionLinkPrepareAutoWakeDispatch(wakeID: successorWake.wakeID, endpoint: endpoint))
            if scenario == .silentSuccessorPrepared {
                await settleNativeObservations(bridge)
                let preparing = try XCTUnwrap(host.publishedPassiveNoticesByEndpoint[observer.domainEndpoint])
                XCTAssertEqual(preparing.routineNonAdmittingReferences.count, 1, "Host preparation is not a new useful run")
            }
            _ = session.beginRunAttempt(source: "test.native.silent-successor", passiveWakeID: session.oversight.pendingAutoWake?.wakeID)
            let sent = await coordinator.sendCodexNativeMessage(session: session, text: "", attachments: [])
            XCTAssertEqual(sent, .sent)
            XCTAssertEqual(dispatches.startedTurns.count, 2)
            await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "silent-successor"), session: session, sourceController: controller)
            await settleNativeObservations(bridge)
            if scenario != .failureSuccessUnpaid && scenario != .silentSuccessorPrepared {
                bridge.applyPassiveMonitorNoticeReceipt(.init(snapshot: predecessor, deliveredEntries: scenario == .debtReceiptOmitted ? [] : nil), observerEndpoint: observer.domainEndpoint)
            }
            await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "silent-successor", status: .completed, failure: nil), session: session, sourceController: controller)
            XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .completed)
            XCTAssertEqual(session.lastTerminalPublicationResult, .accepted(successorEpoch: nil))
        }
        if scenario == .teardown || scenario == .restore {
            let runID = try XCTUnwrap(session.runID)
            XCTAssertTrue(session.clearRunID(ifCurrent: runID))
            if scenario == .restore { session.installRunID(UUID()); session.replaceItems(session.items) }
            session.noteMonitorObservationInputsChanged()
        }
        // Drain @Published's scheduled observation before the serial authority chain.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await bridge.test_settleTargetPublications()
        await bridge.test_settleProjections()
        let notices = try XCTUnwrap(host.publishedPassiveNoticesByEndpoint[observer.domainEndpoint])
        XCTAssertEqual(notices.entries.count, 1, "Suppression must not erase delivery")
        observerVM.agentSessionLinkPublishPromptInventory(try XCTUnwrap(host.publishedInventoriesByEndpoint[observer.domainEndpoint]), to: observer.domainEndpoint)
        observerVM.agentSessionLinkPublishPassiveStatusNotices(notices, to: observer.domainEndpoint)
        observerSession.oversight.pendingAutoWake?.task?.cancel()
        XCTAssertEqual(observerSession.oversight.pendingAutoWake != nil, expectedAdmission, "Native scenario: \(scenario)")
        if agent == .codexExec { await coordinator.shutdownCodexSession(session) } else { await vm.test_claudeCoordinator.shutdownClaudeSession(session) }
    }

}
