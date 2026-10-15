import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentQuietCheckInLifecycleTests: XCTestCase {
    private func fixture(_ agent: AgentProviderKind = .claudeCode) -> (AgentSessionLinkRunnerHarness, AgentTabSession, AgentRunOwnership, UUID) {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, replayTranscript: true)
        let session = harness.makeSession(agent: agent)
        let runID = UUID()
        session.runLifecycle.installRunID(runID)
        session.runState = .running
        let owner = session.beginRunAttempt(source: "quiet-replay")
        // Test-only physical origin. Production marking deliberately does not arrive until C3.
        session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
        return (harness, session, owner, runID)
    }

    @discardableResult
    private func commit(
        _ harness: AgentSessionLinkRunnerHarness,
        _ session: AgentTabSession,
        _ owner: AgentRunOwnership,
        normal: Bool = true,
        successor: AgentRunTerminalCommitBarrier.ProviderSuccessor? = nil,
        prepare: @escaping () -> Void = {}
    ) async -> AgentRunTerminalCommitRevision? {
        await AgentRunTerminalCommitBarrier().commit(.init(
            binding: harness.hooks.bindTerminalSession(session), ownership: owner, expectedRunID: session.runID,
            terminalState: .completed, source: "quiet-replay", attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: false, supportsFollowUp: true, providerSuccessor: successor,
            notifyTurnComplete: true, classifiesQuietCheckIn: normal,
            prepareProviderState: { prepare()
                return nil
            }
        ))
    }

    func testRealBarrierSealsBeforeTeardownAndStatusFlipsBeforeEndWithoutSuppressingNotification() async {
        let (h, s, owner, _) = fixture()
        var completed = 0
        h.onTurnComplete = { completed += 1 }
        var preparingFacts: AgentRunQuietFacts?
        var idleFacts: AgentRunQuietFacts?
        var teardownFacts: AgentRunQuietFacts?
        s.onRunStateChanged = { session in idleFacts = session.quietRunFacts(capturedState: session.runState) }
        s.installRunAttemptTerminalResources(ownership: owner) { _ in
            teardownFacts = s.quietLedger.facts
            return nil
        }
        let revision = await commit(h, s, owner, prepare: { preparingFacts = s.quietRunFacts(capturedState: .running) })
        XCTAssertNotNil(revision)
        XCTAssertEqual(preparingFacts, .zero)
        XCTAssertEqual(idleFacts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 0))
        XCTAssertEqual(teardownFacts, idleFacts)
        XCTAssertEqual(completed, 1)
        XCTAssertNil(s.activeRunOwnership)
        XCTAssertEqual(s.quietLedger.hiddenSourceIDs.count, 1)
        XCTAssertFalse(s.endRunAttempt(ifCurrent: owner, source: "duplicate"))
        XCTAssertEqual(s.quietLedger.facts, idleFacts)
    }

    func testSecondBarrierGuardRejectsOwnerLostDuringFinalization() async {
        let (h, s, owner, _) = fixture()
        var item = AgentChatItem.assistant("[ack]")
        item.isStreaming = true
        s.appendItem(item)
        s.onSourceItemsChanged = { session, _ in _ = session.endCurrentRunAttempt(source: "finalization-owner-loss") }
        let result = await commit(h, s, owner)
        XCTAssertNil(result)
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
        XCTAssertTrue(s.quietLedger.hiddenSourceIDs.isEmpty)
    }

    func testDefaultFalseAndBothSuccessorKindsRemainOrdinary() async {
        for variant in 0 ..< 3 {
            let (h, s, owner, _) = fixture()
            if variant == 1 { s.pendingInstructions.append(AgentRunPendingInstruction(providerText: "follow up", localDraftText: "follow up")) }
            let successor: AgentRunTerminalCommitBarrier.ProviderSuccessor? = variant == 2
                ? .init(id: UUID(), transitionKind: .relatedFollowUp, consumeAfterPublication: { _, _ in true }) : nil
            _ = await commit(h, s, owner, normal: variant != 0, successor: successor)
            XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
            XCTAssertTrue(s.quietLedger.hiddenSourceIDs.isEmpty)
        }
    }

    func testBothAcceptedProgressAPIsLatchAndStaleSignalsDoNot() async throws {
        for acceptedAPI in [false, true] {
            let (h, s, owner, _) = fixture()
            let stale = AgentRunOwnership(binding: owner.binding)
            _ = s.recordRunProgress(ownership: stale, kind: .toolActivity, stage: .running)
            XCTAssertNotNil(s.quietLedger.candidateStartKey(owner: owner))
            if acceptedAPI {
                let live = try XCTUnwrap(s.runLifecycle.liveness)
                _ = s.acceptRunProgress(.init(
                    ownership: owner,
                    sequence: live.lastAcceptedSequence + 1,
                    timestampUptimeNanoseconds: live.lastSignalUptimeNanoseconds + 1,
                    kind: .interaction,
                    stage: .waitingForInteraction,
                    retryIntent: .none
                ))
            } else {
                _ = s.recordRunProgress(ownership: owner, kind: .toolActivity, stage: .running)
            }
            XCTAssertNil(s.quietLedger.candidateStartKey(owner: owner))
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1)
        }
    }

    func testCentralEndMissingBeginAbandonAndBindingRetirementUseExistingAuthority() {
        let (_, s, first, _) = fixture()
        let next = s.beginRunAttempt(source: "abandon")
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
        XCTAssertFalse(s.endRunAttempt(ifCurrent: first, source: "stale"))
        s.quietLedger = AgentRunQuietLedger() // Simulates a missing begin hook, not restoration.
        XCTAssertTrue(s.endRunAttempt(ifCurrent: next, source: "known-untracked-end"))
        XCTAssertFalse(s.endCurrentRunAttempt(source: "duplicate"))
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
        let old = s.beginRunAttempt(source: "old-binding")
        _ = s.beginPersistentBindingTransition()
        XCTAssertTrue(s.endRunAttempt(ifCurrent: old, source: "retired-binding"))
        XCTAssertEqual(s.quietLedger.facts, .zero, "Retired old ownership cannot advance the replacement source")
    }

    func testAcceptedPreSealTaskCannotBecomeQuietAfterWithdrawalAndPostSealCannotReopen() async {
        for managed in [false, true] {
            let (h, s, owner, _) = fixture()
            let attribution = managed ? AgentCrossSessionAttribution(sourceSessionID: UUID(), sourceName: "Observer", linkID: UUID()) : nil
            s.appendItem(.user("task", crossSessionAttribution: attribution))
            _ = s.removeItem(at: 0)
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1)
            let sealed = s.quietLedger.facts
            s.noteAcceptedTaskInput()
            XCTAssertEqual(s.quietLedger.facts, sealed)
        }
        let (h, s, owner, _) = fixture()
        _ = await commit(h, s, owner)
        let hidden = s.quietLedger.hiddenSourceIDs
        s.appendItem(.user("later task"))
        XCTAssertEqual(s.quietLedger.hiddenSourceIDs, hidden)
        let successor = s.beginRunAttempt(source: "accepted-successor")
        XCTAssertTrue(s.endRunAttempt(ifCurrent: successor, source: "ordinary-successor"))
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 2))
    }

    func testFinalizationIsIdentityPreservingButOpaqueRetentionRekeyAndReloadFailOpen() async {
        for variant in 0 ..< 5 {
            let (h, s, owner, _) = fixture()
            var row = AgentChatItem.assistant("[ack]")
            row.isStreaming = true
            s.appendItem(row)
            switch variant {
            case 0: h.host.finalizeStreamingItems(in: s)
            case 1: s.setItemsSilentlyForRetentionCompaction(s.items)
            case 2: s.replaceItem(at: 0, with: .assistant("[ack]", sequenceIndex: 0))
            case 3: s.setItemsSilently(s.items, reason: .persistedSessionHydration)
            default: _ = s.removeItem(at: 0)
            }
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, variant == 0 ? 0 : 1)
        }
    }

    func testOlderRowRekeyedAcrossAttemptBoundaryInvalidatesWithoutRangeScan() async {
        let (h, s, owner, _) = fixture()
        s.appendItem(.assistant("[ack]"))
        _ = await commit(h, s, owner)
        let next = s.beginRunAttempt(source: "rekey-boundary")
        s.quietLedger.markRoutineWake(owner: next, wakeID: UUID())
        XCTAssertNotNil(s.quietLedger.candidateStartKey(owner: next))
        s.mutateItem(at: 0) { $0.sequenceIndex = s.nextSequenceIndex }
        XCTAssertNil(s.quietLedger.candidateStartKey(owner: next))
        s.appendItem(.assistant("[ack]"))
        _ = await commit(h, s, next)
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 2))
    }

    func testClearAndFreshAttemptRangesDoNotRequireAllocatorRepairOrCounterReset() async {
        let (h, s, owner, _) = fixture()
        s.appendItem(.assistant("[ack]"))
        s.setItemsSilently([], reason: .clearedChat)
        s.nextSequenceIndex = 0 // The existing clear writer, under the same source binding.
        _ = await commit(h, s, owner)
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 1, ordinaryThrough: 1))
        let next = s.beginRunAttempt(source: "after-clear")
        s.quietLedger.markRoutineWake(owner: next, wakeID: UUID())
        s.appendItem(.assistant("[ack]"))
        _ = await commit(h, s, next)
        XCTAssertEqual(s.quietLedger.facts, AgentRunQuietFacts(settledThrough: 2, ordinaryThrough: 1))
    }

    func testRawClaudeFinishedMessagesReplacementAndSilenceReachAcceptedVMAndBarrier() async {
        let cases: [([String], Bool)] = [
            ([#"{"type":"system","subtype":"init"}"#, #"{"type":"result","result":"[ack]"}"#], true),
            ([
                #"{"type":"assistant","message":{"id":"one","content":[{"type":"text","text":"prose"}]}}"#,
                #"{"type":"result","result":"[ack]"}"#
            ], true),
            ([
                #"{"type":"assistant","message":{"id":"one","content":[{"type":"text","text":"prose"}]}}"#,
                #"{"type":"assistant","message":{"id":"two","content":[{"type":"text","text":"[ack]"}]}}"#,
                #"{"type":"result","result":"[ack]"}"#
            ], false),
            ([#"{"type":"system","subtype":"init"}"#, #"{"type":"result","subtype":"success"}"#], true)
        ]
        for (wire, quiet) in cases {
            let (h, s, owner, runID) = fixture()
            var translator = ClaudeSDKNDJSONTranslator()
            let events = wire.flatMap { translator.parseNDJSONLine(Data($0.utf8)) }.map { NativeAgentRuntimeEvent.stream($0) }
            let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: h.host.claudeCoordinator, hooks: h.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
            await runner.testConsumeQuietEvents(events, session: s, runID: runID, owner: owner)
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, quiet ? 0 : 1, "\(wire)")
        }
    }

    func testClaudeControllerCodecPreservesNeutralSilenceAndHiddenOrUnknownActivity() async {
        for (wire, quiet) in [
            (#"{"type":"system","subtype":"init"}"#, true),
            (#"{"type":"system","subtype":"task_started","task_id":"background"}"#, false),
            (#"{"type":"system","subtype":"task_notification"}"#, false),
            (#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use"}}}"#, false),
            (#"{"type":"stream_event","event":{"type":"future_event"}}"#, false),
            (#"{"type":"assistant","message":{"content":[{"type":"text","text":"prose"}]}}"#, false),
            (#"{"type":"future_activity"}"#, false),
            (#"{"type":"control_request","request_id":"unknown","request":{"subtype":"future_request"}}"#, false),
            (#"{"type":"control_request","request_id":"permission","request":{"subtype":"can_use_tool","tool_name":"mcp__RepoPrompt__get_file_tree","input":{}}}"#, false),
            (#"{"type":"result","result":"[ack]"}"#, false),
            ("malformed provider line", false)
        ] {
            let (h, s, owner, runID) = fixture()
            let controller = ClaudeNativeProcessSessionController(
                runID: runID, tabID: s.tabID, windowID: -1, workspacePath: nil,
                config: .agentMode(commandName: "/usr/bin/false")
            )
            await controller.test_installConfigurationTransport(write: { _ in })
            let stream = await controller.events
            let turnID = await controller.test_beginTurnTracking()
            s.claudeExpectedTurnIDs.insert(turnID)
            await controller.test_receiveConfigurationResponseLine(Data(wire.utf8))
            if !wire.contains(#""type":"result""#) {
                await controller.test_receiveConfigurationResponseLine(Data(#"{"type":"result","subtype":"success","result":"[ack]"}"#.utf8))
            }
            await controller.shutdown()
            var events: [NativeAgentRuntimeEvent] = []
            for await event in stream {
                events.append(event)
            }
            let runner = ClaudeIntegratedAgentModeRunner(claudeCoordinator: h.host.claudeCoordinator, hooks: h.hooks, terminalCommitBarrier: AgentRunTerminalCommitBarrier())
            let completed = await runner.testConsumeQuietEvents(events, session: s, runID: runID, owner: owner)
            XCTAssertTrue(completed, "The real runner accepted its expected normal completion")
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, quiet ? 0 : 1, wire)
        }
    }

    func testSemanticIngressBeforeSuppressionAndStaleCallbackCannotPoisonCurrentOwner() async {
        for type in ["tool_call", "tool_result", "tool_progress", "auth_status", "task_progress", "error", "system", "unclassified"] {
            let (h, s, owner, runID) = fixture()
            await h.host.test_handleStreamResult(.init(type: type, text: "semantic activity", toolName: "read_file"), session: s, runID: runID, runAttemptID: UUID())
            XCTAssertNotNil(s.quietLedger.candidateStartKey(owner: owner))
            await h.host.test_handleStreamResult(.init(type: type, text: "semantic activity", toolName: "read_file"), session: s, runID: runID, runAttemptID: owner.attemptID)
            XCTAssertNil(s.quietLedger.candidateStartKey(owner: owner), type)
            _ = await commit(h, s, owner)
            XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1)
        }
    }

    func testNaturalIngressDoesNotTraverseRangeUntilPositivelyRoutineTerminalCandidate() {
        var ledger = AgentRunQuietLedger()
        let owner = AgentRunOwnership(binding: AgentRunBindingIdentity(tabID: UUID(), persistentSessionID: nil))
        ledger.begin(owner: owner, startKey: 0, provider: .codexExec)
        var visits = 0
        let rows = (0 ..< 10000).lazy.map { index in
            visits += 1
            return AgentChatItem.thinking("thinking", sequenceIndex: index)
        }
        _ = ledger.settle(
            owner: owner,
            terminalState: .completed,
            classifiesQuietCheckIn: true,
            endKey: 9999,
            rangeIsComplete: true,
            rows: rows
        )
        XCTAssertEqual(visits, 0, "Unmarked natural attempt never traverses even a supplied lazy range")
    }
}

extension AgentQuietCheckInLifecycleTests {
    func testACPApprovalCancellationAndBothWaitingStatesKeepAcceptedInteraction() async {
        let (h, s, owner, runID) = fixture(.codexExec)
        let runner = ACPIntegratedAgentModeRunner(
            hooks: h.hooks,
            terminalCommitBarrier: AgentRunTerminalCommitBarrier(),
            toolTrackingHooks: .noOp,
            providerFactory: { _, _ in nil },
            controllerFactory: { provider, request in try ACPAgentSessionController(provider: provider, runRequest: request) }
        )
        let approval = AgentApprovalRequest(
            requestID: .acp("approval"),
            method: "session/request_permission",
            kind: .commandExecution,
            threadID: "current",
            turnID: "current",
            itemID: "tool"
        )
        await runner.testConsumeQuietEvents([.approvalRequested(approval), .approvalCancelled(approval.requestID)], session: s, runID: runID, owner: owner)
        XCTAssertNil(s.pendingApproval)
        XCTAssertNil(s.quietLedger.candidateStartKey(owner: owner), "Typed interaction survives cancellation without a tool row")
        XCTAssertTrue(s.items.isEmpty)
        _ = await commit(h, s, owner)
        XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1)
        for state in [AgentSessionRunState.waitingForApproval, .waitingForQuestion] {
            let (_, waiting, waitingOwner, _) = fixture()
            waiting.runState = state
            waiting.runState = .running
            XCTAssertNil(waiting.quietLedger.candidateStartKey(owner: waitingOwner))
        }
    }

    func testDevinRawUnknownPlanEchoAndControllerForeignLoadFencesRemainDisabledTogether() async throws {
        for providerID in [ACPProviderID.devin, .openCode] {
            for (method, update) in [
                ("session/update", [String: Any]()), ("session/update", ["sessionUpdate": 7]),
                ("session/update", ["sessionUpdate": "future_activity"]), ("session/update", ["sessionUpdate": "plan"]),
                ("session/update", ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "own or foreign fragment"]]),
                ("future/method", [:])
            ] {
                for variant in 0 ..< 4 {
                    let provider = AgentSessionLinkCapturingACPProvider(providerID: providerID, commandPath: "/usr/bin/false")
                    provider.usesDefaultNormalizer = true
                    let request = ACPRunRequest(
                        agentKind: providerID == .devin ? .devin : .openCode,
                        modelString: nil,
                        workspacePath: nil,
                        resumeSessionID: nil,
                        attachments: [],
                        taskLabelKind: nil
                    )
                    let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
                    let params: [String: Any] = variant == 3 ? ["sessionId": "current", "update": "malformed"]
                        : ["sessionId": variant == 1 ? "foreign" : "current", "update": update]
                    let events = await controller.test_replayQuietNotifications([(method, params)], sessionID: "current", loadReplay: variant == 2)
                    let expectedCount = providerID == .devin && variant != 1 && variant != 2 ? 1 : 0
                    XCTAssertEqual(events.count, expectedCount, "\(providerID) \(method) \(variant)")
                    let (h, s, owner, runID) = fixture(providerID == .devin ? .devin : .openCode)
                    let runner = ACPIntegratedAgentModeRunner(
                        hooks: h.hooks,
                        terminalCommitBarrier: AgentRunTerminalCommitBarrier(),
                        toolTrackingHooks: .noOp,
                        providerFactory: { _, _ in nil },
                        controllerFactory: { provider, request in try ACPAgentSessionController(provider: provider, runRequest: request) }
                    )
                    let sequenceBefore = s.runLifecycle.liveness?.lastAcceptedSequence ?? 0
                    await runner.testConsumeQuietEvents(events, session: s, runID: runID, owner: owner)
                    XCTAssertEqual(s.runLifecycle.liveness?.lastAcceptedSequence, sequenceBefore + 1 + UInt64(expectedCount))
                    XCTAssertTrue(s.items.isEmpty, "Uncertainty uses existing non-rendering stream, never a UI row")
                    _ = await commit(h, s, owner)
                    XCTAssertEqual(s.quietLedger.facts?.ordinaryThrough, 1)
                }
            }
        }
        XCTAssertFalse(AgentQuietCheckInClassifier.supports(.devin), "One shared predicate keeps future copy and classification disabled together")
    }
}
