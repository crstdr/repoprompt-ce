import Foundation
import os
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

/// Native transport fakes drive the existing bridge/reducer/coordinator; no paid provider or app launch.
@MainActor
extension AgentSessionLinkRuntimeBridgeTests {
    func testNativeClaudeDelayedAbandonmentDoesNotEndPreparingSuccessor() async throws {
        try await assertDelayedClaudeAbandonment(successorRefuses: false)
    }

    func testNativeClaudeDelayedAbandonmentSettlesAfterSuccessorRefuses() async throws {
        try await assertDelayedClaudeAbandonment(successorRefuses: true)
    }

    func testNativeClaudeDelayedAbandonmentDoesNotSettleUncertainSuccessor() async throws {
        try await assertDelayedClaudeAbandonment(successorRefuses: false, successorUncertain: true)
    }

    func testNativeClaudeRetainedCompletionRechecksAfterNonFlushSendDrains() async throws {
        try await assertDelayedClaudeAbandonment(successorRefuses: false, nonFlushSend: true)
    }

    func testNativeClaudeLaterAcceptedCompletionOutlivesEarlierUncertainty() async throws {
        try await assertDelayedClaudeAbandonment(successorRefuses: false, successorUncertain: true, laterAcceptedCompletion: true)
    }

    private func assertDelayedClaudeAbandonment(successorRefuses: Bool, successorUncertain: Bool = false, nonFlushSend: Bool = false, laterAcceptedCompletion: Bool = false) async throws {
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
        await fixture.claude.setSteeringConfigurationGate(cGate, fail: successorRefuses || nonFlushSend)
        var externalSend: Task<ClaudeAgentModeCoordinator.NativeSendOutcome, Never>?
        if nonFlushSend {
            let owner = try XCTUnwrap(session.activeRunOwnership)
            let runID = try XCTUnwrap(session.runID)
            externalSend = Task {
                await fixture.vm.test_claudeCoordinator.sendClaudeNativeMessage(session: session, text: "Other send", attachments: [], intent: .runAttempt(ownership: owner, runID: runID), allowsCatalogRouteControllerRecovery: false)
            }
        } else {
            XCTAssertEqual(fixture.vm.submitUserTurn(text: "C successor", tabID: fixture.tabID), .submitted)
        }
        let cEntered = await cGate.waitUntilEntered(timeout: 3)
        XCTAssertTrue(cEntered)
        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertTrue(session.claudeExpectedTurnIDs.isEmpty)
        await fixture.claude.emit(.stream(.init(type: "status", text: "sentinel")))
        runnerGate.release()
        try await AsyncTestWait.waitUntil("abandonment processed") { sentinel || !session.runState.isActive }
        XCTAssertEqual(session.runState, .running, "B's stale abandonment must not terminalize C during preparation")
        XCTAssertNil(session.lastTerminalCommitRevision)
        await fixture.claude.setFailSendAfterRecord(successorUncertain)
        cGate.release()
        guard session.runState == .running else { return }
        if nonFlushSend {
            _ = await externalSend?.value
            try await AsyncTestWait.waitUntil("non-flush work drains and retained A settles") { !session.runState.isActive }
            XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .completed)
            return
        }
        if successorUncertain {
            try await AsyncTestWait.waitUntil("C uncertain send released") { session.claudeSteeringFlushTask == nil }
            sentinel = false
            await fixture.claude.emit(.stream(.init(type: "status", text: "sentinel")))
            try await AsyncTestWait.waitUntil("quiescent notification consumed") { sentinel || !session.runState.isActive }
            XCTAssertEqual(session.runState, .running, "An older no-write cannot prove a later send was unwritten")
            XCTAssertNil(session.lastTerminalCommitRevision)
            if laterAcceptedCompletion {
                await fixture.claude.setFailSendAfterRecord(false)
                XCTAssertEqual(fixture.vm.submitUserTurn(text: "Later accepted turn", tabID: fixture.tabID), .submitted)
                try await AsyncTestWait.waitUntil("later turn accepted") { !session.claudeExpectedTurnIDs.isEmpty && session.claudeSteeringFlushTask == nil }
                let laterTurn = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
                let refused = TestReleaseFence(name: "later definitive refusal")
                defer { refused.release() }
                await fixture.claude.setSteeringConfigurationGate(refused, fail: true)
                XCTAssertEqual(fixture.vm.submitUserTurn(text: "Later refused steer", tabID: fixture.tabID), .submitted)
                let entered = await refused.waitUntilEntered(timeout: 3)
                XCTAssertTrue(entered)
                await fixture.claude.emit(.turnCompleted(turnID: laterTurn, status: .completed))
                try await AsyncTestWait.waitUntil("later authoritative terminal consumed") { session.claudeExpectedTurnIDs.isEmpty }
                refused.release()
                do {
                    try await AsyncTestWait.waitUntil("later known completion commits", timeout: 2) { !session.runState.isActive }
                } catch { XCTFail("Earlier uncertainty stranded a later authoritative completion") }
                XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .completed)
            }
            return
        }
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
            sink.notify(ids) }, sink.probe, sink.uncertainWrite)
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

    func testNativeClaudePostWriteSupersessionReportsWriteDisposition() async throws {
        for throwsAfterWrite in [false, true] {
            let fixture = try await makeNativeWakeFixture(agent: .claudeCode)
            let session = fixture.session
            let written = TestReleaseFence(name: "post-write disposition")
            defer { written.release()
                fixture.bridge.freezeForTermination()
                withExtendedLifetime((fixture.workspace, fixture.observerWorkspace)) {}
            }
            session.runState = .running
            let owner = session.beginRunAttempt(source: "test.post-write-disposition")
            let runID = try XCTUnwrap(session.runID)
            await fixture.claude.setSendCompletionGate(written)
            await fixture.claude.setFailSendAfterRecord(throwsAfterWrite)
            let sending = Task {
                await fixture.vm.test_claudeCoordinator.sendClaudeNativeMessage(session: session, text: "Written", attachments: [], intent: .runAttempt(ownership: owner, runID: runID), allowsCatalogRouteControllerRecovery: false)
            }
            let entered = await written.waitUntilEntered(timeout: 3)
            XCTAssertTrue(entered)
            _ = session.beginPersistentBindingTransition()
            written.release()
            let outcome = await sending.value
            XCTAssertEqual(outcome, .supersededAfterWriteAttempt)
            let count = await fixture.claude.sentCount
            XCTAssertEqual(count, 1)
            await fixture.vm.test_claudeCoordinator.shutdownClaudeSession(session)
        }
    }

    func testNativeClaudeCancelledOldMCPWaitCannotRestoreReplacementQueue() async throws {
        var releaseOld: CheckedContinuation<Void, Never>?
        let newWait = TestReleaseFence(name: "replacement MCP wait")
        var calls = 0
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, awaitNoActiveMCPTools: { _ in
            calls += 1
            if calls == 1 {
                // Model an asynchronous dependency that acknowledges cancellation late.
                await withCheckedContinuation { releaseOld = $0 }
            } else { await newWait.enterAndWait() }
            throw CancellationError()
        })
        let session = harness.host.session(for: UUID())
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        session.installRunID(UUID())
        session.runState = .running
        let oldOwner = session.beginRunAttempt(source: "test.old-flush")
        func instruction(_ text: String, owner: AgentRunOwnership) -> AgentTabSession.ClaudeSteeringInstruction {
            .init(id: UUID(), targetRunID: session.runID, targetRunAttemptID: owner.attemptID, providerText: text, attachments: [], taggedFileAttachments: [], draftText: text, optimisticUserItemID: nil, createdAt: Date())
        }
        defer { releaseOld?.resume()
            newWait.release()
            session.claudeSteeringFlushTask?.cancel()
        }
        session.pendingClaudeSteeringInstructions = [instruction("Old unsent", owner: oldOwner)]
        _ = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
        try await AsyncTestWait.waitUntil("old MCP wait entered") { releaseOld != nil }
        let oldTask = try XCTUnwrap(session.claudeSteeringFlushTask)
        harness.service.withdrawQueuedWorkForManagedStop(tabID: session.tabID, session: session)
        _ = session.endRunAttempt(ifCurrent: oldOwner, source: "test.replaced")
        let newOwner = session.beginRunAttempt(source: "test.new-flush")
        let replacement = instruction("Replacement unsent", owner: newOwner)
        session.pendingClaudeSteeringInstructions = [replacement]
        _ = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
        let newEntered = await newWait.waitUntilEntered(timeout: 3)
        XCTAssertTrue(newEntered)
        let newFlush = try XCTUnwrap(session.claudeSteeringFlushID)
        releaseOld?.resume()
        releaseOld = nil
        await oldTask.value
        XCTAssertEqual(session.pendingClaudeSteeringInstructions.map(\.id), [replacement.id], "Old cancelled wait cannot remove a replacement attempt's draft")
        XCTAssertEqual(session.claudeSteeringFlushID, newFlush)
        XCTAssertNotNil(session.claudeSteeringFlushTask)
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
        _ = try installRestoredFixtureBinding(session, in: vm)
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

    func testNativeClaudeStaleActiveRecoveryKeepsEmptyAndAckWakeOrdinary() async throws {
        for reply in ["", "[ack]"] {
            let fixture = try await makeNativeWakeFixture(agent: .claudeCode)
            let session = fixture.session
            addTeardownBlock { @MainActor in await fixture.vm.test_claudeCoordinator.shutdownClaudeSession(session) }
            let initialFacts = try XCTUnwrap(session.quietLedger.facts)
            let claim = try XCTUnwrap(fixture.vm.agentSessionLinkPromptClaim(for: session, dispatchID: .autoWake(wakeID: fixture.wake.wakeID)))
            XCTAssertFalse(claim.routineQuietCheckIn, "A route without the returned self_noop definition starts ordinary")
            defer {
                session.agentTask?.cancel()
                fixture.bridge.freezeForTermination()
                withExtendedLifetime((fixture.workspace, fixture.observerWorkspace)) {}
            }
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, sessionLinkHost: fixture.vm)
            harness.nativeTranscriptHost = fixture.vm
            var replyConsumed = false
            harness.onNativeStreamResult = { result, session, runID, attemptID in
                await fixture.vm.test_handleStreamResult(result, session: session, runID: runID, runAttemptID: attemptID)
                if result.type == "final_content", result.text == reply,
                   session === fixture.session, runID == session.runID, attemptID == session.activeRunAttemptID
                { replyConsumed = true }
            }
            harness.onTerminalPublication = { _, target in target.oversight.pendingAutoWake?.task?.cancel() }
            let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: fixture.vm.test_claudeCoordinator, hooks: harness.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
            await runner.startRun(tabID: fixture.tabID, session: session, initialUserMessage: "", initialMessageForRun: "", attachments: [], makeLease: { harness.makeLease(runID: $0, tabID: fixture.tabID) })
            try await AsyncTestWait.waitUntil("routine Claude attempt accepted") { !session.claudeExpectedTurnIDs.isEmpty && session.claudeSteeringAbandonment != nil }
            let owner = try XCTUnwrap(session.activeRunOwnership)
            XCTAssertNil(session.quietLedger.candidateStartKey(owner: owner), "Missing exact catalog evidence keeps this routine wake ordinary")
            let wakeRows = session.quietLedger.hostMarkerIDs
            XCTAssertFalse(wakeRows.isEmpty)
            await fixture.claude.emit(.stream(.init(type: "final_content", text: reply)))
            try await AsyncTestWait.waitUntil("empty or ACK reply consumed") { replyConsumed }
            XCTAssertNil(session.quietLedger.candidateStartKey(owner: owner), "Neither silence nor an undeclared reply creates quiet eligibility")
            // Model the stale-active state at the probe boundary: no outstanding completion
            // and a live idle provider. Recovery must keep this ordinary wake visible.
            session.claudeExpectedTurnIDs.removeAll()
            await fixture.claude.setTurnInFlight(false)
            XCTAssertTrue(try ClaudeIntegratedAgentModeRunner.staleActiveRecoveryFencesAreClear(session: session, coordinator: fixture.vm.test_claudeCoordinator, ownership: owner, runID: XCTUnwrap(session.runID)))
            XCTAssertNil(session.quietLedger.candidateStartKey(owner: owner), "The stale boundary cannot invent a declaration")
            publishClaudeSuccessorWake(fixture)
            try await AsyncTestWait.waitUntil("refused wake recovers stale-active attempt") { session.runState == .failed }
            XCTAssertTrue(session.items.contains { $0.kind == .error && $0.text == "Claude Code stopped reporting this run's outcome, so RepoPrompt closed it as failed. The conversation is intact; send a message to continue." }, "The specific stale-active recovery branch must have committed")
            XCTAssertNotNil(session.claudeController, "Recovery retains the live controller")
            XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, owner)
            XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .failed, "Recovery cannot fabricate successful completion")
            XCTAssertEqual(session.quietLedger.facts, .init(settledThrough: initialFacts.settledThrough + 1, ordinaryThrough: initialFacts.settledThrough + 1), reply)
            XCTAssertTrue(wakeRows.isDisjoint(with: session.quietLedger.hiddenSourceIDs), "Recovery must keep wake provenance visible")
            XCTAssertTrue(wakeRows.isSubset(of: session.liveItemIDs))
            XCTAssertGreaterThan(session.transcriptCanonicalVisibleRowCount, 0)
        }
    }

    func testNativeCodexLateIngressAndBulkReplacementKeepIndependentContracts() async throws {
        let fixture = try await makeNativeWakeFixture(agent: .codexExec)
        let session = fixture.session
        defer {
            fixture.bridge.freezeForTermination()
            withExtendedLifetime((fixture.workspace, fixture.observerWorkspace)) {}
        }
        let coordinator = fixture.vm.test_codexCoordinator
        addTeardownBlock { @MainActor in await coordinator.shutdownCodexSession(session) }
        _ = session.beginRunAttempt(source: "test.native.late-ingress")
        let outcome = await coordinator.sendCodexNativeMessage(session: session, text: "", attachments: [])
        XCTAssertEqual(outcome, .sent)
        await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: "late-ingress"), session: session, sourceController: fixture.controller)
        let invocation = UUID()
        await coordinator.test_handleCodexNativeEvent(.toolCall(name: "bash", invocationID: invocation, argsJSON: "{}"), session: session, sourceController: fixture.controller)
        await coordinator.test_handleCodexNativeEvent(.toolResult(name: "bash", invocationID: invocation, argsJSON: "{}", resultJSON: #"{"status":"failed","exit_code":1,"output":"Early"}"#, isError: true), session: session, sourceController: fixture.controller)
        await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: "late-ingress", status: .completed, failure: nil), session: session, sourceController: fixture.controller)
        XCTAssertFalse(session.runState.isActive)
        let revision = session.sourceItemsRevision
        let unownedPoll = UUID()
        let unownedOutput = "UnownedCommandSentinel"
        await coordinator.test_handleCodexNativeEvent(.assistantDelta("Late stale text"), session: session, sourceController: fixture.controller)
        await coordinator.test_handleCodexNativeEvent(.toolCall(name: "poll", invocationID: unownedPoll, argsJSON: "{}"), session: session, sourceController: fixture.controller)
        await coordinator.test_handleCodexNativeEvent(.commandExecutionRunning(.init(invocationID: UUID(), processID: "unknown", appendedOutput: unownedOutput)), session: session, sourceController: fixture.controller)
        XCTAssertEqual(session.sourceItemsRevision, revision, "Inactive unowned output remains rejected at native ingress")
        await coordinator.test_handleCodexNativeEvent(.commandExecutionRunning(.init(invocationID: invocation, processID: nil, appendedOutput: "AcceptedLate")), session: session, sourceController: fixture.controller)
        try await AsyncTestWait.waitUntil("correlated late command output materialized") {
            session.items.contains { $0.toolInvocationID == invocation && (($0.toolResultJSON?.contains("AcceptedLate") ?? false) || (session.ephemeralToolResultPayloadByItemID[$0.id]?.contains("AcceptedLate") ?? false)) }
        }
        XCTAssertGreaterThan(session.sourceItemsRevision, revision, "Correlated late output must actually be retained")
        XCTAssertFalse(session.items.contains { $0.text.contains("Late stale text") || $0.toolInvocationID == unownedPoll }, "Unowned ingress must remain absent after the accepted-output synchronization point")
        XCTAssertFalse(session.items.contains { ($0.toolResultJSON ?? "").contains(unownedOutput) })
        XCTAssertFalse(session.ephemeralToolResultPayloadByItemID.values.contains { $0.contains(unownedOutput) })
        let row = AgentChatItem.system("Host repair", sequenceIndex: session.nextSequenceIndex)
        session.replaceItems([row, row])
        XCTAssertEqual(session.items.map(\.id), [row.id], "Bulk replacement deduplicates repeated item IDs")
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
                fromStatus: .running,
                toStatus: .idle,
                changeSequence: 2
            )],
            unacknowledgedOverflowCount: 0, overflowProduced: 0, autoWakeLanes: fixture.queue.autoWakeLanes
        )
        fixture.vm.agentSessionLinkPublishPassiveStatusNotices(queue, to: fixture.endpoint)
    }

    private func settleNativeObservations(_ bridge: AgentSessionLinkRuntimeBridge) async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await bridge.test_settleTargetPublications()
        await bridge.test_settleProjections()
    }

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
        let sessionID = try installRestoredFixtureBinding(session, in: vm)
        let target = try XCTUnwrap(vm.agentSessionLinkCandidate(tabID: tabID, sessionID: sessionID, tabName: "Native target", isWindowClosing: false))
        let endpoint = target.domainEndpoint
        let observerVM = AgentModeViewModel(testWindowID: 2, testWorkspacePath: FileManager.default.temporaryDirectory.path, shouldManageCodexTooling: false, codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) })
        let observerTab = UUID()
        let observerWorkspace = AgentSessionLinkEndpointTestSupport.installWorkspace(on: observerVM, tabID: observerTab, name: "Observer")
        let observerSession = observerVM.session(for: observerTab)
        observerSession.selectedAgent = .openCode
        observerSession.hasLoadedPersistedState = true
        observerSession.oversight.autoWakeOnUpdates = true
        let observerID = try installRestoredFixtureBinding(observerSession, in: observerVM)
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
}
