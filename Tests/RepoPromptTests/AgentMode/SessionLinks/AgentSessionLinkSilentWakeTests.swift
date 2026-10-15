import Foundation
import os
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

    func testNativeClaudeDelayedAbandonmentDoesNotEndPreparingSuccessor() async throws {
        try await assertDelayedClaudeAbandonment(successorRefuses: false)
    }

    func testNativeClaudeDelayedAbandonmentSettlesAfterSuccessorRefuses() async throws {
        try await assertDelayedClaudeAbandonment(successorRefuses: true)
    }

    private func assertDelayedClaudeAbandonment(successorRefuses: Bool) async throws {
        let fixture = try await makeNativeWakeFixture(agent: .claudeCode)
        let session = fixture.session
        let runnerGate = TestReleaseFence(name: "runner held before abandonment")
        let bGate = TestReleaseFence(name: "B definitive refusal")
        let cGate = TestReleaseFence(name: "C preparing")
        defer {
            runnerGate.release()
            bGate.release()
            cGate.release()
            session.agentTask?.cancel()
            session.claudeSteeringFlushTask?.cancel()
            fixture.bridge.freezeForTermination()
            withExtendedLifetime((fixture.workspace, fixture.observerWorkspace)) {}
        }
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, sessionLinkHost: fixture.vm)
        var sentinel = false
        harness.onNativeStreamResult = { result, _, _, _ in
            if result.text == "hold" { await runnerGate.enterAndWait() }
            if result.text == "sentinel" { sentinel = true }
        }
        let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: fixture.vm.test_claudeCoordinator, hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
        await runner.startRun(tabID: fixture.tabID, session: session, initialUserMessage: "", initialMessageForRun: "", attachments: [], makeLease: { harness.makeLease(runID: $0, tabID: fixture.tabID) })
        try await AsyncTestWait.waitUntil("A accepted") { !session.claudeExpectedTurnIDs.isEmpty }
        let turnA = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
        await fixture.claude.setSteeringConfigurationGate(bGate, fail: true)
        XCTAssertEqual(fixture.vm.submitUserTurn(text: "B unsent", tabID: fixture.tabID), .submitted)
        let bEntered = await bGate.waitUntilEntered(timeout: 3)
        XCTAssertTrue(bEntered)
        await fixture.claude.emit(.turnCompleted(turnID: turnA, status: .completed))
        try await AsyncTestWait.waitUntil("A consumed") { session.claudeExpectedTurnIDs.isEmpty }
        await fixture.claude.emit(.stream(.init(type: "status", text: "hold")))
        let held = await runnerGate.waitUntilEntered(timeout: 3)
        XCTAssertTrue(held)
        bGate.release()
        try await AsyncTestWait.waitUntil("B restored and flush released") { session.claudeSteeringFlushTask == nil }
        XCTAssertEqual(fixture.vm.retrieveDraftText(for: fixture.tabID), "B unsent")
        await fixture.claude.setSteeringConfigurationGate(cGate, fail: successorRefuses)
        XCTAssertEqual(fixture.vm.submitUserTurn(text: "C successor", tabID: fixture.tabID), .submitted)
        let cEntered = await cGate.waitUntilEntered(timeout: 3)
        XCTAssertTrue(cEntered)
        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertTrue(session.claudeExpectedTurnIDs.isEmpty)
        await fixture.claude.emit(.stream(.init(type: "status", text: "sentinel")))
        runnerGate.release()
        try await AsyncTestWait.waitUntil("abandonment processed") { sentinel || !session.runState.isActive }
        XCTAssertEqual(session.runState, .running, "B's stale abandonment must not terminalize C during preparation")
        XCTAssertNil(session.lastTerminalCommitRevision)
        cGate.release()
        guard session.runState == .running else { return }
        if successorRefuses {
            try await AsyncTestWait.waitUntil("C refusal releases retained A") { !session.runState.isActive }
            XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .completed)
            let sends = await fixture.claude.sentCount
            XCTAssertEqual(sends, 1)
            XCTAssertEqual(fixture.vm.retrieveDraftText(for: fixture.tabID).components(separatedBy: "C successor").count - 1, 1)
            return
        }
        try await AsyncTestWait.waitUntil("C accepted") { !session.claudeExpectedTurnIDs.isEmpty }
        let turnC = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
        await fixture.claude.emit(.turnCompleted(turnID: turnC, status: .failed))
        try await AsyncTestWait.waitUntil("C settles") { !session.runState.isActive }
        XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .failed)
    }

    func testNativeClaudePostWriteBindingSupersessionDoesNotRestoreOrAbandon() async throws {
        let fixture = try await makeNativeWakeFixture(agent: .claudeCode)
        let session = fixture.session
        let preparing = TestReleaseFence(name: "B preparation")
        let written = TestReleaseFence(name: "B written before receipt")
        defer {
            preparing.release()
            written.release()
            session.agentTask?.cancel()
            session.claudeSteeringFlushTask?.cancel()
            fixture.bridge.freezeForTermination()
            withExtendedLifetime((fixture.workspace, fixture.observerWorkspace)) {}
        }
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, sessionLinkHost: fixture.vm)
        let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: fixture.vm.test_claudeCoordinator, hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
        await runner.startRun(tabID: fixture.tabID, session: session, initialUserMessage: "", initialMessageForRun: "", attachments: [], makeLease: { harness.makeLease(runID: $0, tabID: fixture.tabID) })
        try await AsyncTestWait.waitUntil("A accepted") { !session.claudeExpectedTurnIDs.isEmpty }
        let turnA = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
        let ownership = try XCTUnwrap(session.activeRunOwnership)
        let runID = try XCTUnwrap(session.runID)
        await fixture.claude.setSteeringConfigurationGate(preparing, fail: false)
        await fixture.claude.setSendCompletionGate(written)
        XCTAssertEqual(fixture.vm.submitUserTurn(text: "B already written", tabID: fixture.tabID), .submitted)
        let preparingEntered = await preparing.waitUntilEntered(timeout: 3)
        XCTAssertTrue(preparingEntered)
        await fixture.claude.emit(.turnCompleted(turnID: turnA, status: .completed))
        try await AsyncTestWait.waitUntil("A consumed") { session.claudeExpectedTurnIDs.isEmpty }
        var abandonedIDs: Set<UUID> = []
        let sink = try XCTUnwrap(session.claudeSteeringAbandonment)
        session.claudeSteeringAbandonment = (sink.attemptID, { ids in abandonedIDs.formUnion(ids)
            sink.notify(ids) }, sink.probe)
        preparing.release()
        let writeEntered = await written.waitUntilEntered(timeout: 3)
        XCTAssertTrue(writeEntered)
        let sends = await fixture.claude.sentCount
        XCTAssertEqual(sends, 2, "B crossed the provider write boundary")
        _ = session.beginPersistentBindingTransition()
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertEqual(session.runID, runID)
        XCTAssertTrue(session.claudeController === fixture.claude)
        XCTAssertFalse(fixture.vm.test_claudeCoordinator.runAttemptIsCurrent(ownership, runID: runID, for: session))
        written.release()
        try await AsyncTestWait.waitUntil("superseded send disposition") { session.claudeSteeringFlushTask == nil }
        XCTAssertTrue(abandonedIDs.isEmpty, "A post-write supersession cannot publish definitive no-write")
        XCTAssertEqual(fixture.vm.retrieveDraftText(for: fixture.tabID), "", "Do not restore a written turn into a changed binding")
    }

    func testNativeClaudeFailedUnsentSteerSettlesConsumedCompletionAndAdmitsWake() async throws {
        try await assertClaudeSteeringSettlement(failsBeforeWrite: true)
    }

    func testNativeClaudeSuccessfulSteerKeepsSuccessorUntilItsOwnResult() async throws {
        try await assertClaudeSteeringSettlement(failsBeforeWrite: false)
    }

    func testNativeClaudeRecoveryDrainsEventsReceivedDuringIdleRead() async throws {
        try await assertClaudeSteeringSettlement(failsBeforeWrite: false, uncertainWrite: true, probeIngress: true)
    }

    func testNativeClaudeUncertainUnsentSuccessorRecoversOnWakeRefusal() async throws {
        try await assertClaudeSteeringSettlement(failsBeforeWrite: false, uncertainWrite: true)
    }

    func testNativeClaudeNoWriteAbandonmentBeforeACompletionKeepsExactOutcome() async throws {
        try await assertClaudeSteeringSettlement(failsBeforeWrite: true, completionAfterFailure: true)
    }

    func testNativeClaudeSupersededConfigurationRestoresDraftAndSettlesA() async throws {
        try await assertClaudeSteeringSettlement(failsBeforeWrite: false, supersededBeforeWrite: true)
    }

    func testNativeClaudeStartupRuntimeFailureIsNotDiscardedByStreamReset() async throws {
        let controller = MonitorFakeNativeController()
        await controller.setStartupEvent(.runtimeInit(.init(sessionID: "startup-session", tools: [], mcpServerStatuses: [MCPIntegrationHelper.repoPromptMCPServerName: "failed"], initializeResponse: nil)))
        let vm = AgentModeViewModel(testWindowID: 1, testWorkspacePath: FileManager.default.temporaryDirectory.path, shouldManageCodexTooling: false, codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }, claudeControllerFactory: { _, _, _, _ in controller }, connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in }, mcpServerEnabler: { true })
        let tabID = UUID()
        let workspace = AgentSessionLinkEndpointTestSupport.installWorkspace(on: vm, tabID: tabID, name: "Startup stream")
        let session = vm.session(for: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .claudeCode
        _ = try XCTUnwrap(vm.test_ensureSessionBoundToTab(session))
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, sessionLinkHost: vm)
        let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: vm.test_claudeCoordinator, hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
        defer { session.agentTask?.cancel()
            withExtendedLifetime(workspace) {}
        }
        await runner.startRun(tabID: tabID, session: session, initialUserMessage: "Start", initialMessageForRun: "Start", attachments: [], makeLease: { harness.makeLease(runID: $0, tabID: tabID) })
        try await AsyncTestWait.waitUntil("buffered runtime initialization failure") { session.runState == .failed }
        XCTAssertTrue(session.items.contains { $0.kind == .error && $0.text.contains("RepoPrompt MCP failed to initialize") })
        await vm.test_claudeCoordinator.shutdownClaudeSession(session)
    }

    private enum ClaudeRecoveryBlocker { case turnInFlight, sendInFlight, codex }

    func testNativeClaudeRecoveryRefusesBusyTurnSendAndCodex() async throws {
        for blocker: ClaudeRecoveryBlocker in [.turnInFlight, .sendInFlight, .codex] {
            try await assertClaudeSteeringSettlement(failsBeforeWrite: false, uncertainWrite: true, recoveryBlocker: blocker)
        }
    }

    private func assertClaudeSteeringSettlement(failsBeforeWrite: Bool, uncertainWrite: Bool = false, recoveryBlocker: ClaudeRecoveryBlocker? = nil, completionAfterFailure: Bool = false, supersededBeforeWrite: Bool = false, probeIngress: Bool = false) async throws {
        let fixture = try await makeNativeWakeFixture(agent: .claudeCode)
        let vm = fixture.vm
        let session = fixture.session
        let gate = TestReleaseFence(name: "steering pre-write configuration")
        let idleRead = TestReleaseFence(name: "provider idle read")
        var ingressHandled = false
        defer {
            idleRead.release()
            gate.release()
            session.agentTask?.cancel()
            session.claudeSteeringFlushTask?.cancel()
            fixture.bridge.freezeForTermination()
            withExtendedLifetime((fixture.workspace, fixture.observerWorkspace)) {}
        }
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, sessionLinkHost: vm)
        let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: vm.test_claudeCoordinator, hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
        await runner.startRun(tabID: fixture.tabID, session: session, initialUserMessage: "", initialMessageForRun: "", attachments: [], makeLease: { harness.makeLease(runID: $0, tabID: fixture.tabID) })
        try await AsyncTestWait.waitUntil("initial Claude turn accepted") { !session.claudeExpectedTurnIDs.isEmpty }
        let ownership = try XCTUnwrap(session.activeRunOwnership)
        let runID = try XCTUnwrap(session.runID)
        let turnA = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
        await fixture.claude.setSteeringConfigurationGate(gate, fail: failsBeforeWrite)
        await fixture.claude.setFailSendAfterRecord(uncertainWrite)
        XCTAssertEqual(vm.submitUserTurn(text: "Unsent correction", tabID: fixture.tabID), .submitted)
        let entered = await gate.waitUntilEntered(timeout: 3)
        XCTAssertTrue(entered)
        XCTAssertTrue(session.claudeSupersedingProtectedTurnIDs.contains(turnA))
        if !completionAfterFailure {
            await fixture.claude.emit(.turnCompleted(turnID: turnA, status: .completed))
            try await AsyncTestWait.waitUntil("protected A completion consumed") { !session.claudeExpectedTurnIDs.contains(turnA) }
        }
        XCTAssertEqual(session.runState, .running, "A cannot terminate the promised successor")
        if supersededBeforeWrite {
            session.selectedModelRaw = session.selectedModelRaw == "claude-opus-4-6" ? "claude-sonnet-4-5-20250929" : "claude-opus-4-6"
        }
        gate.release()
        try await AsyncTestWait.waitUntil("failed steer restored") { session.claudeSteeringFlushTask == nil }
        if completionAfterFailure { await fixture.claude.emit(.turnCompleted(turnID: turnA, status: .completed)) }
        let sent = await fixture.claude.sentCount
        if failsBeforeWrite || supersededBeforeWrite {
            XCTAssertEqual(vm.retrieveDraftText(for: fixture.tabID), "Unsent correction", "The accepted but unsent draft is restored exactly once")
            XCTAssertEqual(sent, 1, "B never reached the provider write boundary")
        } else if !uncertainWrite {
            XCTAssertEqual(sent, 2)
            XCTAssertEqual(session.runState, .running, "The real successor still owns the live attempt")
            XCTAssertNil(session.lastTerminalCommitRevision)
            let turnB = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
            await fixture.claude.emit(.turnCompleted(turnID: turnB, status: .completed))
        }
        if uncertainWrite {
            XCTAssertEqual(sent, 2, "Transport acceptance is uncertain; do not replay A as success")
            XCTAssertEqual(session.runState, .running)
            XCTAssertNil(session.lastTerminalCommitRevision)
            if let recoveryBlocker {
                var processedSentinel = false
                harness.onNativeStreamResult = { _, _, _, _ in processedSentinel = true }
                let sendGate = TestReleaseFence(name: "recovery exclusion send")
                var sending: Task<ClaudeAgentModeCoordinator.NativeSendOutcome, Never>?
                switch recoveryBlocker {
                case .turnInFlight:
                    await fixture.claude.setTurnInFlight(true)
                case .sendInFlight:
                    await fixture.claude.setSteeringConfigurationGate(sendGate, fail: true)
                    sending = Task {
                        await vm.test_claudeCoordinator.sendClaudeNativeMessage(session: session, text: "Held send", attachments: [], intent: .runAttempt(ownership: ownership, runID: runID), allowsCatalogRouteControllerRecovery: false)
                    }
                    let entered = await sendGate.waitUntilEntered(timeout: 3)
                    XCTAssertTrue(entered)
                case .codex:
                    session.selectedAgent = .codexExec
                }
                vm.requestClaudeStaleActiveProbe(for: session)
                await fixture.claude.emit(.stream(.init(type: "status", text: nil)))
                try await AsyncTestWait.waitUntil("recovery exclusion probe processed") { processedSentinel }
                XCTAssertEqual(session.runState, .running)
                XCTAssertNil(session.lastTerminalCommitRevision)
                session.selectedAgent = .claudeCode
                await fixture.claude.setTurnInFlight(false)
                sendGate.release()
                _ = await sending?.value
            }
            harness.onTerminalPublication = { _, targetSession in
                // Observe recovery without starting an uncontrolled VM-owned successor run.
                targetSession.oversight.pendingAutoWake?.task?.cancel()
            }
            if probeIngress {
                harness.onNativeStreamResult = { result, _, _, _ in
                    if result.text == "final provider output" { ingressHandled = true }
                }
                await fixture.claude.setActiveReadGate(idleRead)
                vm.requestClaudeStaleActiveProbe(for: session)
                let entered = await idleRead.waitUntilEntered(timeout: 3)
                XCTAssertTrue(entered)
                await fixture.claude.emit(.stream(.init(type: "text", text: "final provider output")))
                await fixture.claude.emit(.error("final provider error"))
                // Let the production forwarder enqueue both values while the probe is suspended.
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                idleRead.release()
            }
            publishClaudeSuccessorWake(fixture)
        }
        do {
            try await AsyncTestWait.waitUntil("consumed terminal settles after definitive no-write", timeout: 2) { !session.runState.isActive }
        } catch {
            XCTFail("Known A completion was lost after B failed before write: \(error)")
        }
        if probeIngress {
            XCTAssertTrue(ingressHandled, "Recovery must not discard already-received output")
            XCTAssertTrue(session.items.contains { $0.kind == .error && $0.text == "final provider error" }, "Buffered provider errors must reach the runner")
        }
        XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, ownership)
        XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, uncertainWrite ? .failed : .completed)
        XCTAssertNil(session.activeRunOwnership)
        if !uncertainWrite {
            publishClaudeSuccessorWake(fixture)
            XCTAssertNotNil(session.oversight.pendingAutoWake, "Queued oversight content can reserve after settlement without Stop")
        }
        session.oversight.pendingAutoWake?.task?.cancel()
        let shutdowns = await fixture.claude.shutdownCount
        XCTAssertEqual(shutdowns, 0, "Settlement must preserve the retained controller")
        if uncertainWrite {
            XCTAssertEqual(vm.retrieveDraftText(for: fixture.tabID), "Unsent correction")
            let recovered = session.lastTerminalCommitRevision
            vm.requestClaudeStaleActiveProbe(for: session)
            XCTAssertEqual(session.lastTerminalCommitRevision, recovered, "Recovery is once per exact ownership")
            await fixture.claude.setFailSendAfterRecord(false)
            let nextGate = TestReleaseFence(name: "next retained-process turn")
            nextGate.release()
            await fixture.claude.setSteeringConfigurationGate(nextGate, fail: false)
            await runner.startRun(tabID: fixture.tabID, session: session, initialUserMessage: "Continue", initialMessageForRun: "Continue", attachments: [], makeLease: { harness.makeLease(runID: $0, tabID: fixture.tabID) })
            try await AsyncTestWait.waitUntil("retained controller accepts next turn") { !session.claudeExpectedTurnIDs.isEmpty }
            let nextTurn = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
            await fixture.claude.emit(.turnCompleted(turnID: nextTurn, status: .completed))
            try await AsyncTestWait.waitUntil("retained controller completes next turn") { session.runState == .completed }
            XCTAssertNotEqual(session.lastTerminalCommitRevision?.ownership, ownership)
        }
        await vm.test_claudeCoordinator.shutdownClaudeSession(session)
    }

    private func publishClaudeSuccessorWake(_ fixture: NativeWakeFixture) {
        let queue = AgentSessionLinkPassiveStatusNotices.Snapshot(
            observerEndpoint: fixture.endpoint, queueEpoch: fixture.queue.queueEpoch,
            queueRevision: 2, linkSetRevision: 1, isEnabled: true, isDeliverable: true,
            entries: [.init(
                reference: fixture.reference,
                targetEndpoint: fixture.observer.domainEndpoint,
                targetSessionID: fixture.observer.sessionID,
                displayName: "Peer",
                fromStatus: .idle,
                toStatus: .running,
                changeSequence: 2
            )],
            unacknowledgedOverflowCount: 0, overflowProduced: 0, autoWakeLanes: fixture.queue.autoWakeLanes
        )
        fixture.vm.agentSessionLinkPublishPassiveStatusNotices(queue, to: fixture.endpoint)
    }

    func testNativeClaudeSilentRoutineCompletionDoesNotAdmitObserverButToolOnlyDoes() async throws {
        try await assertNativeWake(.silent, expectedAdmission: false, agent: .claudeCode)
        try await assertNativeWake(.toolOnly, expectedAdmission: true, agent: .claudeCode)
    }

    func testNativeTwoAgentEchoRingStopsAtFirstSilentTurn() async throws {
        try await assertNativeRing(toolOnly: false, horizon: 7, expectedCalls: 5)
        try await assertNativeRing(toolOnly: false, horizon: 6, expectedCalls: 4, usefulReplyCount: 3)
    }

    func testNativeTwoAgentToolOnlyRingKeepsAllSixCalls() async throws {
        try await assertNativeRing(toolOnly: true, horizon: 6, expectedCalls: 6)
    }

    func testNativeTwoAgentEchoRingStopsAtAckTurn() async throws {
        // A bare `ack` ends the ring whichever peer answers it.
        try await assertNativeRing(toolOnly: false, horizon: 7, expectedCalls: 5, quietReply: "ack")
        try await assertNativeRing(toolOnly: false, horizon: 7, expectedCalls: 6, usefulReplyCount: 5, quietReply: "ack")
    }

    func testNativeTwoAgentEchoRingTreatsNonExactAckAsOrdinary() async throws {
        try await assertNativeRing(toolOnly: false, horizon: 6, expectedCalls: 6, quietReply: "ack, nothing needed")
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

    func testNativePriorRunCommandOutputVetoesAnOtherwiseSilentSuccessor() async throws {
        try await assertNativeWake(.priorToolLateOutput, expectedAdmission: true)
    }

    func testNativeExactAckReplyFinishesQuietly() async throws {
        try await assertNativeWake(.ack, expectedAdmission: false)
        try await assertNativeWake(.ackPadded, expectedAdmission: false)
        try await assertNativeWake(.ackFragmented, expectedAdmission: false)
        try await assertNativeWake(.ackSettled, expectedAdmission: false)
        // A blank completion after an exact `ack` seals the message and stays quiet.
        try await assertNativeWake(.ackThenBlankCompletion, expectedAdmission: false)
        try await assertNativeWake(.ack, expectedAdmission: false, agent: .claudeCode)
        try await assertNativeWake(.ackSettled, expectedAdmission: false, agent: .claudeCode)
    }

    func testNativeNonExactAckRepliesKeepWaking() async throws {
        try await assertNativeWake(.ackNonExact, expectedAdmission: true)
        try await assertNativeWake(.ackWord, expectedAdmission: true)
        try await assertNativeWake(.ackPrefix, expectedAdmission: true)
        try await assertNativeWake(.ackThenTool, expectedAdmission: true)
        // Whitespace is part of the reply: "a" + " " + "ck" renders "a ck", not `ack`.
        try await assertNativeWake(.ackSpaced, expectedAdmission: true)
        // An invisible format scalar is not whitespace: "ack\u{200B}" is not the exact token.
        try await assertNativeWake(.ackInvisibleSuffix, expectedAdmission: true)
        // A second completed message must not supersede the first: "ac" + "ack" is not `ack`.
        try await assertNativeWake(.ackTwoCompletions, expectedAdmission: true)
        // Message boundaries are real: two completions "a" + "ck" are two messages, not `ack`.
        try await assertNativeWake(.ackSplitCompletions, expectedAdmission: true)
        // A whitespace-only completion seals but does not erase: the streamed "ac" survives as its
        // own message, so a later `ack` completion cannot fuse with it into the quiet token.
        try await assertNativeWake(.ackBlankCompletion, expectedAdmission: true)
        try await assertNativeWake(.ackBlankThenAck, expectedAdmission: true)
        // A non-quiet streamed prefix vetoes once and stays vetoed even when the authoritative
        // completion replaces it — an inconsistent stream fails loud rather than quiet.
        try await assertNativeWake(.ackNoisyPrefix, expectedAdmission: true)
        // An empty completion is still a message boundary: "ac" + "" + "ack" seals the prefix as
        // its own message, so the turn's reply is "ac\nack", not `ack`.
        try await assertNativeWake(.ackEmptyCompletionBoundary, expectedAdmission: true)
        // The same boundary holds for an absent body (Claude `final_content` with nil text).
        try await assertNativeWake(.ackNilCompletionBoundary, expectedAdmission: true, agent: .claudeCode)
        // A delta after a sealed completion reopens pending text under the boundary: `ack` + ""
        // + "." renders "ack\n." — one separator shy of the exact token, so it stays ordinary.
        try await assertNativeWake(.ackEmptyCompletionTrailing, expectedAdmission: true)
        // The 256-byte eligibility line is deliberate: a padded `ack` beyond it fails loud.
        try await assertNativeWake(.ackOversized, expectedAdmission: true)
        // The separator inserted when a delta reopens pending text counts against the line:
        // `ack` + 252 trailing spaces is exactly 256 bytes and quiet; one more is ordinary.
        try await assertNativeWake(.ackSealedPaddedAtCap, expectedAdmission: false)
        try await assertNativeWake(.ackSealedPaddedOverCap, expectedAdmission: true)
        // A surfaced question is a wake-worthy event on every provider: Codex `requestUserInput`
        // (auto-approve skipped for a non-MCP question) and Claude `approvalRequest` veto alike.
        try await assertNativeWake(.ackQuestion, expectedAdmission: true)
        try await assertNativeWake(.ackQuestion, expectedAdmission: true, agent: .claudeCode)
        try await assertNativeWake(.ackNonExact, expectedAdmission: true, agent: .claudeCode)
        try await assertNativeWake(.ackTwoCompletions, expectedAdmission: true, agent: .claudeCode)
        try await assertNativeWake(.ackSplitCompletions, expectedAdmission: true, agent: .claudeCode)
        try await assertNativeWake(.ackEmptyCompletionBoundary, expectedAdmission: true, agent: .claudeCode)
        try await assertNativeWake(.ackEmptyCompletionTrailing, expectedAdmission: true, agent: .claudeCode)
        try await assertNativeWake(.ackOversized, expectedAdmission: true, agent: .claudeCode)
    }

    /// Periodic, attention, and manual wakes keep `ack` ordinary: they bind no evidence segment and
    /// their dispatch never teaches the quiet reply, so the bare token still wakes the observer.
    func testNativeAckOnNonRoutineWakesStaysOrdinary() async throws {
        try await assertNonRoutineAckWake(name: "periodic") { fixture in
            fixture.session.oversight.periodicIdleWakeEnabled = true
            fixture.vm.agentSessionLinkPeriodicObserverIsLive = { _ in true }
            return .periodic
        }
        try await assertNonRoutineAckWake(name: "attention") { fixture in
            .purposefulAttention(.init(
                queueEpoch: fixture.queue.queueEpoch,
                reference: fixture.reference,
                attentionSequence: 1
            ))
        }
        try await assertNonRoutineAckWake(name: "manual") { _ in .manual }
    }

    /// Devin rides the ACP runner's existing shared seams — run-start binding, the physical-
    /// acquisition fence, the shared stream switch, the accepted-send signal, and the shared
    /// terminal barrier — so a bare `ack` finishes quietly with no Devin-specific evidence state.
    func testDevinRoutineWakeAckTurnFinishesQuietlyThroughSharedSeams() async throws {
        let fixture = try await makeNativeWakeFixture(agent: .devin)
        defer {
            fixture.bridge.freezeForTermination()
            withExtendedLifetime((fixture.workspace, fixture.observerWorkspace)) {}
        }
        let session = fixture.session
        let vm = fixture.vm
        let wakeID = fixture.wake.wakeID
        let claim = try XCTUnwrap(vm.agentSessionLinkPromptClaim(for: session, dispatchID: .autoWake(wakeID: wakeID)))
        XCTAssertTrue(claim.fragment.contains("reply exactly `ack`"), "ACP routine wake teaches the quiet reply")
        let ownership = session.beginRunAttempt(source: "acp", passiveWakeID: wakeID)
        XCTAssertEqual(session.passiveWakeSegment?.wakeID, wakeID, "ACP run start binds the same evidence segment")
        XCTAssertTrue(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .autoWake(wakeID: wakeID)))
        XCTAssertEqual(session.passiveWakeSegment?.acquired, true)
        // Physical dispatch is what the runner reports as live; publish that running sample before
        // the terminal seam so the observer queue records the running→idle edge like a real turn.
        session.runState = .running
        await settleNativeObservations(fixture.bridge)
        let runID = try XCTUnwrap(session.runID)
        await vm.test_handleStreamResult(.init(type: "content", text: "ack"), session: session, runID: runID, runAttemptID: ownership.attemptID)
        vm.acceptAgentSessionLinkDispatch(session: session, context: .init(session: session, dispatchID: .autoWake(wakeID: wakeID)), claim: claim)
        XCTAssertEqual(session.passiveWakeSegment?.accepted, true)
        await vm.test_publishNaturalCompletion(session)
        XCTAssertEqual(session.passiveWakeEvidence, .silent(ownership))
        try await assertObserverAdmission(fixture, expectedAdmission: false)
    }

    /// The same seams veto a Devin turn that answers `ack` after a tool call — quiet requires no
    /// tool activity, and a bare token riding one wakes the observer exactly like a real reply.
    func testDevinRoutineWakeAckAfterToolCallStaysOrdinary() async throws {
        let fixture = try await makeNativeWakeFixture(agent: .devin)
        defer {
            fixture.bridge.freezeForTermination()
            withExtendedLifetime((fixture.workspace, fixture.observerWorkspace)) {}
        }
        let session = fixture.session
        let vm = fixture.vm
        let wakeID = fixture.wake.wakeID
        let claim = try XCTUnwrap(vm.agentSessionLinkPromptClaim(for: session, dispatchID: .autoWake(wakeID: wakeID)))
        let ownership = session.beginRunAttempt(source: "acp", passiveWakeID: wakeID)
        XCTAssertTrue(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .autoWake(wakeID: wakeID)))
        session.runState = .running
        await settleNativeObservations(fixture.bridge)
        let runID = try XCTUnwrap(session.runID)
        await vm.test_handleStreamResult(.init(type: "tool_call", text: nil, toolName: "poll", toolArgsJSON: "{}"), session: session, runID: runID, runAttemptID: ownership.attemptID)
        await vm.test_handleStreamResult(.init(type: "content", text: "ack"), session: session, runID: runID, runAttemptID: ownership.attemptID)
        vm.acceptAgentSessionLinkDispatch(session: session, context: .init(session: session, dispatchID: .autoWake(wakeID: wakeID)), claim: claim)
        await vm.test_publishNaturalCompletion(session)
        XCTAssertEqual(session.passiveWakeEvidence, .ordinary(ownership), "Tool activity vetoes quiet even when the reply is exact")
        try await assertObserverAdmission(fixture, expectedAdmission: true)
    }

    private func assertNonRoutineAckWake(
        name: String,
        basis: (NativeWakeFixture) -> AgentSessionLinkWakeAdmissionDecision.Basis
    ) async throws {
        let fixture = try await makeNativeWakeFixture(agent: .codexExec)
        defer {
            fixture.bridge.freezeForTermination()
            withExtendedLifetime((fixture.workspace, fixture.observerWorkspace)) {}
        }
        var attempt = try XCTUnwrap(fixture.session.oversight.pendingAutoWake)
        attempt.admissionBasis = basis(fixture)
        fixture.session.oversight.pendingAutoWake = attempt
        let outcome = fixture.vm.agentSessionLinkPromptClaimOutcome(for: fixture.session, dispatchID: .autoWake(wakeID: attempt.wakeID))
        XCTAssertFalse(
            outcome.claim?.fragment.contains("reply exactly `ack`") ?? false,
            "\(name) wake must not teach the quiet reply"
        )
        _ = fixture.session.beginRunAttempt(source: "test.ack.\(name)", passiveWakeID: attempt.wakeID)
        XCTAssertNil(fixture.session.passiveWakeSegment, "\(name) wake binds no quiet-evidence segment")
        let coordinator = fixture.vm.test_codexCoordinator
        let sent = await coordinator.sendCodexNativeMessage(session: fixture.session, text: "", attachments: [])
        XCTAssertEqual(sent, .sent)
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "nonroutine-\(name)"), session: fixture.session, sourceController: fixture.controller)
        // Publish the mid-turn running sample before completion, or the observer's reducer only ever
        // sees idle→idle and the edge the admission check needs is never recorded.
        await settleNativeObservations(fixture.bridge)
        await coordinator.test_handleCodexNativeEvent(.assistantDelta("ack"), session: fixture.session, sourceController: fixture.controller)
        await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "nonroutine-\(name)", status: .completed, failure: nil), session: fixture.session, sourceController: fixture.controller)
        await fixture.session.agentTask?.value
        XCTAssertEqual(fixture.session.lastTerminalPublicationResult, .accepted(successorEpoch: nil))
        XCTAssertFalse(fixture.session.passiveWakeEvidence.isPassive, "\(name) wake keeps `ack` ordinary")
        try await assertObserverAdmission(fixture, expectedAdmission: true)
    }

    private struct NativeRingPeer {
        let vm: AgentModeViewModel
        let session: AgentTabSession
        let candidate: AgentSessionLinkEndpointCandidate
        let workspace: WorkspaceManagerViewModel
        let codex: MonitorFakeCodexController
        let codexDispatches: MonitorCodexDispatchRecorder
        let claude: MonitorFakeNativeController
        let claudeParser: ClaudeNativeProcessSessionController?
        let claudeWrites: OSAllocatedUnfairLock<Int>
        let harness: AgentSessionLinkRunnerHarness
    }

    private func makeNativeRingPeer(agent: AgentProviderKind, windowID: Int) async throws -> NativeRingPeer {
        let tabID = UUID()
        let runID = UUID()
        let claudeWrites = OSAllocatedUnfairLock(initialState: 0)
        let claudeParser: ClaudeNativeProcessSessionController? = agent == .claudeCode
            ? .init(
                runID: runID,
                tabID: tabID,
                windowID: windowID,
                workspacePath: nil,
                config: .discovery(commandName: "/usr/bin/false")
            ) : nil
        if let claudeParser {
            await claudeParser.test_installConfigurationTransport { _ in claudeWrites.withLock { $0 += 1 } }
        }
        let dispatches = MonitorCodexDispatchRecorder()
        let codex = MonitorFakeCodexController(dispatches: dispatches)
        let claude = MonitorFakeNativeController()
        let vm = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            shouldManageCodexTooling: false,
            codexControllerFactory: { _, _, _, _, _, _ in codex },
            claudeControllerFactory: { _, _, _, _ in
                if let claudeParser { return claudeParser }
                return claude
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let workspace = AgentSessionLinkEndpointTestSupport.installWorkspace(on: vm, tabID: tabID, name: "Native ring")
        let session = vm.session(for: tabID)
        session.selectedAgent = agent
        session.hasLoadedPersistedState = true
        session.installRunID(runID)
        let sessionID = try XCTUnwrap(vm.test_ensureSessionBoundToTab(session))
        let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(tabID: tabID, sessionID: sessionID, tabName: "Ring peer", isWindowClosing: false))
        vm.test_initializeRunService()
        if agent == .codexExec {
            await vm.test_codexCoordinator.ensureCodexNativeSession(session: session)
        } else {
            let warm = session.beginRunAttempt(source: "test.ring.warm")
            let ready = try await vm.test_claudeCoordinator.ensureClaudeNativeSession(session: session, intent: .runAttempt(ownership: warm, runID: XCTUnwrap(session.runID)))
            XCTAssertEqual(ready, .ready)
            _ = session.endRunAttempt(ifCurrent: warm, source: "test.ring.warm")
        }
        let route = try AgentSessionLinkRunCatalogRouteToken(runID: XCTUnwrap(session.runID), observerEndpoint: candidate.domainEndpoint, connectionID: UUID(), routingAuthorityGeneration: 1, connectionLifecycleGeneration: 1)
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
        return NativeRingPeer(vm: vm, session: session, candidate: candidate, workspace: workspace, codex: codex, codexDispatches: dispatches, claude: claude, claudeParser: claudeParser, claudeWrites: claudeWrites, harness: harness)
    }

    private func settleNativeObservations(_ bridge: AgentSessionLinkRuntimeBridge) async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await bridge.test_settleTargetPublications()
        await bridge.test_settleProjections()
    }

    /// `quietReply` is what a turn past `usefulReplyCount` visibly answers — "ack" ends the ring
    /// quietly, while a non-exact string keeps waking the peer exactly like a real reply.
    private func assertNativeRing(toolOnly: Bool, horizon: Int, expectedCalls: Int, usefulReplyCount: Int = 4, quietReply: String? = nil) async throws {
        let first = try await makeNativeRingPeer(agent: .codexExec, windowID: 1)
        let second = try await makeNativeRingPeer(agent: .claudeCode, windowID: 2)
        let host = FakeEndpointHost()
        host.candidates = [first.candidate, second.candidate]
        host.observationViewModels = [first.candidate.sessionID: first.vm, second.candidate.sessionID: second.vm]
        host.forwardsNativeQueues = true
        host.autoWakeTargetsByEndpoint = [first.candidate.domainEndpoint: [second.candidate.sessionID], second.candidate.domainEndpoint: [first.candidate.sessionID]]
        let bridge = AgentSessionLinkRuntimeBridge(authority: makeAuthority(), host: host, toolAdvertisementInvalidator: { _ in })
        defer { bridge.freezeForTermination()
            withExtendedLifetime([first.workspace, second.workspace]) {}
        }
        guard case .added = await bridge.addMonitorLink(observerSessionID: first.candidate.sessionID, rawTargetSessionID: second.candidate.sessionID.uuidString),
              case .added = await bridge.addMonitorLink(observerSessionID: second.candidate.sessionID, rawTargetSessionID: first.candidate.sessionID.uuidString)
        else {
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
                } else if index <= usefulReplyCount {
                    await peer.vm.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta("Useful \(index)"), session: session, sourceController: peer.codex)
                } else if let quietReply {
                    await peer.vm.test_codexCoordinator.test_handleCodexNativeEvent(.assistantDelta(quietReply), session: session, sourceController: peer.codex)
                }
                await peer.vm.test_codexCoordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "ring-\(index)", status: .completed, failure: nil), session: session, sourceController: peer.codex)
            } else {
                let parser = try XCTUnwrap(peer.claudeParser)
                let providerSessionID = await parser.currentSessionRef().sessionID
                let replyText = index <= usefulReplyCount ? "Useful \(index)" : quietReply
                if toolOnly || replyText != nil {
                    let content: [String: Any] = toolOnly
                        ? ["type": "tool_use", "id": UUID().uuidString, "name": "mcp__RepoPromptCE__poll", "input": [:]]
                        : ["type": "text", "text": replyText!]
                    let assistant: [String: Any] = [
                        "type": "assistant",
                        "session_id": providerSessionID ?? "application-proof-session",
                        "message": ["role": "assistant", "content": [content]]
                    ]
                    try await parser.test_handleConfigurationStdoutChunk(JSONSerialization.data(withJSONObject: assistant) + Data([10]))
                }
                // Empty successful result travels through the real controller decoder/translator,
                // native turn FIFO and runner, not an invented terminal event.
                let result: [String: Any] = ["type": "result", "subtype": "success", "session_id": providerSessionID ?? "application-proof-session", "result": "", "is_error": false]
                try await parser.test_handleConfigurationStdoutChunk(JSONSerialization.data(withJSONObject: result) + Data([10]))
                await session.agentTask?.value
            }
            XCTAssertEqual(session.lastTerminalPublicationResult, .accepted(successorEpoch: nil))
            await settleNativeObservations(bridge)
        }
        let claudeCalls = second.claudeWrites.withLock { $0 }
        XCTAssertEqual(first.codexDispatches.startedTurns.count + claudeCalls, expectedCalls, "Count physical native invocations, not admission/helper calls")
        XCTAssertEqual(first.session.items.count(where: { $0.kind == .assistant }) + second.session.items.count(where: { $0.kind == .assistant }), toolOnly ? 0 : (quietReply == nil ? usefulReplyCount : expectedCalls), "Visible quiet replies still produce assistant rows; silent turns do not")
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
        case rowlessInput, bulkReplacement, controllerReplacement, lateUnownedOutput, lateToolOutput, rejectedPublication, acceptedPublication, unknownStream, transientStreams, priorToolLateOutput
        case ack, ackPadded, ackFragmented, ackSettled, ackNonExact, ackWord, ackPrefix, ackThenTool
        case ackSpaced, ackInvisibleSuffix, ackTwoCompletions, ackNoisyPrefix, ackSplitCompletions, ackBlankCompletion
        case ackBlankThenAck, ackThenBlankCompletion
        case ackEmptyCompletionBoundary, ackEmptyCompletionTrailing, ackNilCompletionBoundary
        case ackOversized, ackSealedPaddedAtCap, ackSealedPaddedOverCap, ackQuestion

        /// Visible reply fragments for the exact-`ack` family; nil for every earlier scenario.
        var ackReplyFragments: [String]? {
            switch self {
            case .ack: ["ack"]
            case .ackPadded: ["  ACK.  "]
            case .ackFragmented: ["ac", "k"]
            case .ackSettled, .ackBlankCompletion, .ackBlankThenAck: ["ac"] // a completion may supersede the prefix
            case .ackEmptyCompletionBoundary, .ackNilCompletionBoundary: ["ac"]
            case .ackThenBlankCompletion, .ackEmptyCompletionTrailing: ["ack"]
            case .ackNonExact: ["ack, nothing needed"]
            case .ackWord: ["acknowledged"]
            case .ackPrefix: ["ac"]
            case .ackThenTool: ["ack"]
            case .ackSpaced: ["a", " ", "ck"]
            case .ackInvisibleSuffix: ["ack\u{200B}"]
            case .ackOversized: [String(repeating: " ", count: 260) + "ack"]
            case .ackTwoCompletions, .ackSplitCompletions: nil
            case .ackNoisyPrefix: ["hello"]
            default: nil
            }
        }

        /// Authoritative completions emitted after any fragments, in order; nil = none.
        /// A nil element is only expressible for providers whose completion payload is
        /// optional (Claude `final_content`); Codex substitutes "" — same blank-boundary path.
        var ackCompletions: [String?]? {
            switch self {
            case .ackSettled, .ackNoisyPrefix: ["ack"]
            case .ackTwoCompletions: ["ac", "ack"]
            case .ackSplitCompletions: ["a", "ck"]
            case .ackBlankCompletion: ["  "]
            case .ackBlankThenAck: ["  ", "ack"]
            case .ackThenBlankCompletion, .ackEmptyCompletionTrailing: [""]
            case .ackEmptyCompletionBoundary: ["", "ack"]
            case .ackNilCompletionBoundary: [nil, "ack"]
            case .ackSealedPaddedAtCap, .ackSealedPaddedOverCap: ["ack"]
            default: nil
            }
        }

        /// Fragments streamed after the last completion — a delta reopens pending text under a
        /// newline boundary, so `ack` + blank completion + `.` must classify as `ack\n.`, and the
        /// separator counts against the 256-byte eligibility line: `ack` + 253 trailing spaces is
        /// 257 bytes, over the line.
        var ackTrailingFragments: [String]? {
            switch self {
            case .ackEmptyCompletionTrailing: ["."]
            case .ackSealedPaddedAtCap: [String(repeating: " ", count: 252)]
            case .ackSealedPaddedOverCap: [String(repeating: " ", count: 253)]
            default: nil
            }
        }
    }

    /// Everything the wake suites share: one monitored session with a published status edge, an
    /// observer behind a real bridge, and a routine wake already prepared for dispatch.
    private struct NativeWakeFixture {
        let vm: AgentModeViewModel
        let tabID: UUID
        let session: AgentTabSession
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        let observerVM: AgentModeViewModel
        let observerSession: AgentTabSession
        let observer: AgentSessionLinkEndpointCandidate
        let host: FakeEndpointHost
        let bridge: AgentSessionLinkRuntimeBridge
        let queue: AgentSessionLinkPassiveStatusNotices.Snapshot
        let reference: DomainAgentSessionLinkReference
        let controller: MonitorFakeCodexController
        let claude: MonitorFakeNativeController
        let dispatches: MonitorCodexDispatchRecorder
        let wake: AgentSessionLinkAutoWakeAttempt
        let workspace: WorkspaceManagerViewModel
        let observerWorkspace: WorkspaceManagerViewModel
    }

    private func makeNativeWakeFixture(agent: AgentProviderKind) async throws -> NativeWakeFixture {
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

        guard case .added = await bridge.addMonitorLink(observerSessionID: observer.sessionID, rawTargetSessionID: sessionID.uuidString) else {
            XCTFail("Reverse observation must be established")
            throw CancellationError()
        }

        vm.test_initializeRunService()
        if agent == .codexExec {
            await vm.test_codexCoordinator.ensureCodexNativeSession(session: session)
        } else if agent == .claudeCode {
            let warm = session.beginRunAttempt(source: "test.warm.native")
            let ready = try await vm.test_claudeCoordinator.ensureClaudeNativeSession(session: session, intent: .runAttempt(ownership: warm, runID: XCTUnwrap(session.runID)))
            XCTAssertEqual(ready, .ready)
            _ = session.endRunAttempt(ifCurrent: warm, source: "test.warm.native")
        }
        let route = try AgentSessionLinkRunCatalogRouteToken(runID: XCTUnwrap(session.runID), observerEndpoint: endpoint, connectionID: UUID(), routingAuthorityGeneration: 1, connectionLifecycleGeneration: 1)
        vm.test_agentSessionLinkHasActiveOutboundLink = { _ in true }
        vm.test_agentSessionLinkAuthoritativeRunCatalogRouteToken = { _, _, _ in route }
        vm.test_agentSessionLinkCurrentRunCatalogRouteToken = { _, _ in true }
        vm.agentSessionLinkPublishRunCatalogProjection(.init(runID: route.runID, routeToken: route, projectionRevision: 1, hasAgentSessionLink: true, hasAnyActiveLink: true), to: endpoint)
        vm.agentSessionLinkPublishPromptInventory(.init(observerSessionID: sessionID, linkSetRevision: 1, items: [.init(targetSessionID: observer.sessionID, displayName: "Peer", capabilityNames: ["poll", "read"])]), to: endpoint)
        let reference = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
        let queue = AgentSessionLinkPassiveStatusNotices.Snapshot(
            observerEndpoint: endpoint,
            queueEpoch: UUID(),
            queueRevision: 1,
            linkSetRevision: 1,
            isEnabled: true,
            isDeliverable: true,
            entries: [.init(reference: reference, targetEndpoint: observer.domainEndpoint, targetSessionID: observer.sessionID, displayName: "Peer", fromStatus: .running, toStatus: .idle, changeSequence: 1)],
            unacknowledgedOverflowCount: 0,
            overflowProduced: 0,
            autoWakeLanes: [.init(reference: reference, targetEndpoint: observer.domainEndpoint, targetSessionID: observer.sessionID, isEffectivelySelected: true)]
        )
        session.oversight.autoWakeOnUpdates = true
        // Hold reservation until the caller supplies the deterministic native transport.
        vm.agentSessionLinkPublishPassiveStatusNotices(queue, to: endpoint)
        let wake = try XCTUnwrap(session.oversight.pendingAutoWake)
        wake.task?.cancel()
        session.runState = .idle
        _ = try XCTUnwrap(vm.agentSessionLinkPrepareAutoWakeDispatch(wakeID: wake.wakeID, endpoint: endpoint))
        return NativeWakeFixture(
            vm: vm, tabID: tabID, session: session, endpoint: endpoint,
            observerVM: observerVM, observerSession: observerSession, observer: observer,
            host: host, bridge: bridge, queue: queue, reference: reference,
            controller: controller, claude: claude, dispatches: dispatches, wake: wake,
            workspace: workspace, observerWorkspace: observerWorkspace
        )
    }

    /// The observer-side tail every wake fixture shares: settle the bridge, deliver the published
    /// notices to the observer, and check whether it was actually reserved.
    private func assertObserverAdmission(_ fixture: NativeWakeFixture, expectedAdmission: Bool) async throws {
        // Drain @Published's scheduled observation before the serial authority chain.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await fixture.bridge.test_settleTargetPublications()
        await fixture.bridge.test_settleProjections()
        let notices = try XCTUnwrap(fixture.host.publishedPassiveNoticesByEndpoint[fixture.observer.domainEndpoint])
        XCTAssertEqual(notices.entries.count, 1, "Suppression must not erase delivery")
        try fixture.observerVM.agentSessionLinkPublishPromptInventory(XCTUnwrap(fixture.host.publishedInventoriesByEndpoint[fixture.observer.domainEndpoint]), to: fixture.observer.domainEndpoint)
        fixture.observerVM.agentSessionLinkPublishPassiveStatusNotices(notices, to: fixture.observer.domainEndpoint)
        fixture.observerSession.oversight.pendingAutoWake?.task?.cancel()
        XCTAssertEqual(fixture.observerSession.oversight.pendingAutoWake != nil, expectedAdmission)
    }

    private func assertNativeWake(_ scenario: NativeWakeScenario, expectedAdmission: Bool, agent: AgentProviderKind = .codexExec) async throws {
        let lateInvocation = UUID()
        let toolOnly = scenario == .toolOnly || scenario == .lateToolOutput || scenario == .priorToolLateOutput
        let hasSuccessor = [NativeWakeScenario.debtReceipt, .debtReceiptOmitted, .failureSuccessUnpaid, .failureSuccessPaid, .silentSuccessorPrepared, .priorToolLateOutput].contains(scenario)
        let failsFirst = [.failure, .failureSuccessUnpaid, .failureSuccessPaid].contains(scenario)
        let fixture = try await makeNativeWakeFixture(agent: agent)
        defer {
            fixture.bridge.freezeForTermination()
            withExtendedLifetime((fixture.workspace, fixture.observerWorkspace)) {}
        }
        let vm = fixture.vm
        let tabID = fixture.tabID
        let session = fixture.session
        let endpoint = fixture.endpoint
        let observerVM = fixture.observerVM
        let observerSession = fixture.observerSession
        let observer = fixture.observer
        let host = fixture.host
        let bridge = fixture.bridge
        let queue = fixture.queue
        let reference = fixture.reference
        let controller = fixture.controller
        let claude = fixture.claude
        let dispatches = fixture.dispatches
        let wake = fixture.wake
        let coordinator = vm.test_codexCoordinator
        if scenario == .ack || scenario == .ackSettled {
            // The routine wake's own dispatch teaches the one-token quiet reply; every other basis
            // omits it (covered by testNativeAckOnNonRoutineWakesStaysOrdinary).
            let routineClaim = try XCTUnwrap(vm.agentSessionLinkPromptClaim(for: session, dispatchID: .autoWake(wakeID: wake.wakeID)))
            XCTAssertTrue(routineClaim.fragment.contains("reply exactly `ack`"), "Routine status wake teaches the exact quiet reply")
        }
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
                let tool = [NativeWakeScenario.lateToolOutput, .priorToolLateOutput].contains(scenario) ? "bash" : "mcp__RepoPromptCE__poll"
                await coordinator.test_handleCodexNativeEvent(.toolCall(name: tool, invocationID: lateInvocation, argsJSON: "{}"), session: session, sourceController: controller)
                if scenario == .lateToolOutput || scenario == .priorToolLateOutput {
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
        if let replyFragments = scenario.ackReplyFragments {
            for fragment in replyFragments {
                if agent == .codexExec {
                    await coordinator.test_handleCodexNativeEvent(.assistantDelta(fragment), session: session, sourceController: controller)
                } else {
                    await claude.emit(.stream(.init(type: "content", text: fragment)))
                }
            }
        }
        if let completions = scenario.ackCompletions {
            for (index, text) in completions.enumerated() {
                if agent == .codexExec {
                    await coordinator.test_handleCodexNativeEvent(.assistantCompleted(.init(scope: .init(turnID: "native-turn", itemID: "m-\(index)"), text: text ?? "")), session: session, sourceController: controller)
                } else {
                    await claude.emit(.stream(.init(type: "final_content", text: text)))
                }
            }
        }
        if let trailing = scenario.ackTrailingFragments {
            for fragment in trailing {
                if agent == .codexExec {
                    await coordinator.test_handleCodexNativeEvent(.assistantDelta(fragment), session: session, sourceController: controller)
                } else {
                    await claude.emit(.stream(.init(type: "content", text: fragment)))
                }
            }
        }
        if scenario == .ackQuestion {
            if agent == .codexExec {
                await coordinator.test_handleCodexNativeEvent(.requestUserInput(.init(
                    requestID: .int(77),
                    method: "item/tool/requestUserInput",
                    threadID: "thread",
                    turnID: "native-turn",
                    itemID: "question-1",
                    questions: [.init(
                        id: "mode", header: "Mode", question: "Which mode?",
                        isOther: true, isSecret: false,
                        options: [.init(label: "Fast", description: ""), .init(label: "Safe", description: "")]
                    )]
                )), session: session, sourceController: controller)
            } else {
                await claude.emit(.approvalRequest(.init(
                    requestID: .claudeControl("req-1"),
                    method: "permission",
                    kind: .commandExecution,
                    threadID: "thread",
                    turnID: "native-turn",
                    itemID: "question-1"
                )))
            }
        }
        if scenario == .ackThenTool {
            if agent == .codexExec {
                await coordinator.test_handleCodexNativeEvent(.toolCall(name: "mcp__RepoPromptCE__poll", invocationID: UUID(), argsJSON: "{}"), session: session, sourceController: controller)
            } else {
                await claude.emit(.stream(.init(type: "tool_call", text: nil, toolName: "mcp__RepoPromptCE__poll", toolArgsJSON: "{}")))
            }
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
                try observerVM.agentSessionLinkPublishPromptInventory(XCTUnwrap(host.publishedInventoriesByEndpoint[observer.domainEndpoint]), to: observer.domainEndpoint)
                observerVM.agentSessionLinkPublishPassiveStatusNotices(pending, to: observer.domainEndpoint)
                XCTAssertNil(observerSession.oversight.pendingAutoWake, "Canonical hold cannot reserve an observer")
                // Model an already-preparing observer at the same public occurrence. The real
                // physical fence must re-read the now-published pending passive contribution.
                let witness = AgentSessionLinkAutoWakeAttempt(
                    wakeID: UUID(),
                    observerEndpoint: observer.domainEndpoint,
                    queueEpoch: pending.queueEpoch,
                    queueRevision: pending.queueRevision,
                    wakeFingerprint: pending.wakeEligibilityFingerprint,
                    admissionBasis: .routineStatusOrOverflow,
                    attemptedFingerprint: nil,
                    physicalOutcome: .notAttempted,
                    phase: .preparingDispatch,
                    task: nil
                )
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
                    && (
                        ($0.toolResultJSON?.contains("AcceptedLate") ?? false)
                            || (session.ephemeralToolResultPayloadByItemID[$0.id]?.contains("AcceptedLate") ?? false)
                    )
                }
            }
            XCTAssertGreaterThan(session.sourceItemsRevision, revision, "Late native update must actually be accepted, not merely attempted")
            XCTAssertEqual(session.passiveWakeEvidence, evidence, "This exact segment's earlier tool ingress already vetoed silence")
        }
        if let acceptanceGate {
            try observerVM.agentSessionLinkPublishPromptInventory(XCTUnwrap(host.publishedInventoriesByEndpoint[observer.domainEndpoint]), to: observer.domainEndpoint)
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
        let firstOwner = session.lastTerminalCommitRevision?.ownership
        if hasSuccessor {
            await settleNativeObservations(bridge)
            let predecessor = try XCTUnwrap(host.publishedPassiveNoticesByEndpoint[observer.domainEndpoint])
            XCTAssertEqual(predecessor.entries.count, 1)
            let successorQueue = AgentSessionLinkPassiveStatusNotices.Snapshot(
                observerEndpoint: endpoint,
                queueEpoch: queue.queueEpoch,
                queueRevision: 2,
                linkSetRevision: 1,
                isEnabled: true,
                isDeliverable: true,
                entries: [.init(reference: reference, targetEndpoint: observer.domainEndpoint, targetSessionID: observer.sessionID, displayName: "Peer", fromStatus: .running, toStatus: .idle, changeSequence: 2)],
                unacknowledgedOverflowCount: 0,
                overflowProduced: 0,
                autoWakeLanes: queue.autoWakeLanes
            )
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
            if scenario != .failureSuccessUnpaid, scenario != .silentSuccessorPrepared {
                bridge.applyPassiveMonitorNoticeReceipt(.init(snapshot: predecessor, deliveredEntries: scenario == .debtReceiptOmitted ? [] : nil), observerEndpoint: observer.domainEndpoint)
            }
            await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "silent-successor", status: .completed, failure: nil), session: session, sourceController: controller)
            XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .completed)
            XCTAssertEqual(session.lastTerminalPublicationResult, .accepted(successorEpoch: nil))
        }
        if scenario == .priorToolLateOutput {
            await settleNativeObservations(bridge)
            let successorOwner = try XCTUnwrap(session.lastTerminalCommitRevision?.ownership)
            XCTAssertNotEqual(successorOwner, firstOwner)
            XCTAssertEqual(session.passiveWakeEvidence, .silent(successorOwner))
            let quiet = try XCTUnwrap(host.publishedPassiveNoticesByEndpoint[observer.domainEndpoint])
            XCTAssertEqual(quiet.routineNonAdmittingReferences.count, 1, "Predecessor receipt leaves only silent successor")
            let revision = session.sourceItemsRevision
            await coordinator.test_handleCodexNativeEvent(.commandExecutionRunning(.init(invocationID: lateInvocation, processID: nil, appendedOutput: "PriorRunLate")), session: session, sourceController: controller)
            try await AsyncTestWait.waitUntil("prior-run correlated output materialized") {
                session.items.contains { $0.toolInvocationID == lateInvocation
                    && (
                        ($0.toolResultJSON?.contains("PriorRunLate") ?? false)
                            || (session.ephemeralToolResultPayloadByItemID[$0.id]?.contains("PriorRunLate") ?? false)
                    )
                }
            }
            XCTAssertGreaterThan(session.sourceItemsRevision, revision)
            XCTAssertEqual(session.passiveWakeEvidence, .ordinary(successorOwner), "Accepted inactive output vetoes the current segment even for an earlier identity")
        }
        if scenario == .teardown || scenario == .restore {
            let runID = try XCTUnwrap(session.runID)
            XCTAssertTrue(session.clearRunID(ifCurrent: runID))
            if scenario == .restore { session.installRunID(UUID())
                session.replaceItems(session.items)
            }
            session.noteMonitorObservationInputsChanged()
        }
        // Drain @Published's scheduled observation before the serial authority chain.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await bridge.test_settleTargetPublications()
        await bridge.test_settleProjections()
        let notices = try XCTUnwrap(host.publishedPassiveNoticesByEndpoint[observer.domainEndpoint])
        XCTAssertEqual(notices.entries.count, 1, "Suppression must not erase delivery")
        try observerVM.agentSessionLinkPublishPromptInventory(XCTUnwrap(host.publishedInventoriesByEndpoint[observer.domainEndpoint]), to: observer.domainEndpoint)
        observerVM.agentSessionLinkPublishPassiveStatusNotices(notices, to: observer.domainEndpoint)
        observerSession.oversight.pendingAutoWake?.task?.cancel()
        XCTAssertEqual(observerSession.oversight.pendingAutoWake != nil, expectedAdmission, "Native scenario: \(scenario)")
        if agent == .codexExec { await coordinator.shutdownCodexSession(session) } else { await vm.test_claudeCoordinator.shutdownClaudeSession(session) }
    }
}
