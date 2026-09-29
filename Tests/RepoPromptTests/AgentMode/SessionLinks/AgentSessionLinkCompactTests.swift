import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Live-view-model coverage for the overseer `compact` transaction.
///
/// Compaction reuses the send contract — the same readiness gate, composer claim, commit fence, and
/// durable-before-dispatch ordering — and differs only in what it records and dispatches: an
/// attributed `.system` request row and a RepoPrompt-constructed native command instead of a user
/// row and an envelope.
@MainActor
final class AgentSessionLinkCompactTransactionTests: XCTestCase {
    private struct Fixture {
        let viewModel: AgentModeViewModel
        let manager: WorkspaceManagerViewModel
        let tabID: UUID
        let session: AgentModeViewModel.TabSession
        let candidate: AgentSessionLinkEndpointCandidate
        let events: LiveSendEventLog
        let claude: CompactRecordingNativeController
        let codexRecorder: LifecycleRecorder
        let driftHook: AgentSessionLinkSendTransactionLiveTests.LiveSendDriftHook
    }

    private var retainedViewModels: [AgentModeViewModel] = []

    override func tearDown() {
        retainedViewModels.removeAll()
        super.tearDown()
    }

    private func makeFixture(
        agent: AgentProviderKind = .claudeCode,
        providerConversation: Bool = true,
        shouldManageCodexTooling: Bool = false,
        codexResumeGate: TestReleaseFence? = nil,
        saverBehavior: LiveSendEventLog.SaverBehavior = .succeed
    ) throws -> Fixture {
        let events = LiveSendEventLog()
        let driftHook = AgentSessionLinkSendTransactionLiveTests.LiveSendDriftHook()
        let claude = CompactRecordingNativeController()
        let codexRecorder = LifecycleRecorder()
        let tabID = UUID()
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Overseer compaction",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)],
            activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace

        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            shouldManageCodexTooling: shouldManageCodexTooling,
            codexControllerFactory: { _, _, _, _, _, _ in
                events.record(.providerControllerCreated)
                return LifecycleNoopCodexController(recorder: codexRecorder, resumeGate: codexResumeGate)
            },
            claudeControllerFactory: { _, _, _, _ in
                events.record(.providerControllerCreated)
                return claude
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retainedViewModels.append(viewModel)
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { agentSession, _, _ in
            let saveIndex = events.recordSave(items: agentSession.toLiveItems())
            if saveIndex == 0 { driftHook.duringDeliveryFlush?() }
            switch saverBehavior {
            case .succeed:
                break
            case .fail:
                throw LiveSendEventLog.SaveFailure()
            case .failFirst:
                if saveIndex == 0 { throw LiveSendEventLog.SaveFailure() }
            }
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        }

        let session = viewModel.session(for: tabID)
        session.selectedAgent = agent
        session.hasLoadedPersistedState = true
        if providerConversation {
            session.providerSessionID = "provider-conversation"
            session.codexConversationID = "codex-thread"
        }
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        let candidate = try XCTUnwrap(viewModel.agentSessionLinkCandidate(
            tabID: tabID,
            sessionID: sessionID,
            tabName: "Build API",
            isWindowClosing: false
        ))
        return Fixture(
            viewModel: viewModel,
            manager: manager,
            tabID: tabID,
            session: session,
            candidate: candidate,
            events: events,
            claude: claude,
            codexRecorder: codexRecorder,
            driftHook: driftHook
        )
    }

    private static let observerEndpoint = DomainAgentSessionLinkEndpointIdentity(
        windowID: 2,
        workspaceID: UUID(),
        tabID: UUID(),
        sessionID: UUID(),
        persistentBindingGeneration: UUID(),
        bindingTransitionGeneration: 1
    )

    private static let liveLiveness = AgentSessionLinkSendLiveness(
        observerEndpointIsLive: true,
        targetEndpointIsLive: true,
        targetWindowIsClosing: false
    )

    private let request = AgentSessionLinkCompactRequest(
        linkID: UUID(),
        linkGeneration: 1,
        observerEndpoint: AgentSessionLinkCompactTransactionTests.observerEndpoint,
        observerDisplayName: "Planning"
    )

    private func compact(
        _ fixture: Fixture,
        liveness: @escaping AgentSessionLinkSendLivenessProbe = { liveLiveness },
        commit: @escaping @MainActor () async -> AgentSessionLinkSendCommitOutcome = { .committed }
    ) async -> AgentSessionLinkSendTransactionOutcome {
        await fixture.viewModel.agentSessionLinkPerformCompact(
            to: fixture.candidate,
            request: request,
            liveness: liveness,
            commitAuthorization: commit
        )
    }

    // MARK: - Support

    func testOnlyClaudeCodeAndCodexWithAProviderConversationAreSupported() async throws {
        for agent in AgentProviderKind.allCases {
            let fixture = try makeFixture(agent: agent)
            let expected: AgentSessionLinkCompactSupport = switch agent {
            case .claudeCode: .claudeCode
            case .codexExec: .codex
            case .devin, .grokBuild, .antigravity:
                // A remembered ACP conversation with no live session yet is retryable, not
                // incapable: one ordinary turn brings the provider session and its command
                // advertisement up.
                .noProviderSession
            default: .notSupported
            }
            let support = await fixture.viewModel.agentSessionLinkCompactSupport(for: fixture.session)
            XCTAssertEqual(support, expected, "\(agent)")
        }
        for agent in [AgentProviderKind.claudeCode, .codexExec] {
            let fixture = try makeFixture(agent: agent, providerConversation: false)
            let support = await fixture.viewModel.agentSessionLinkCompactSupport(for: fixture.session)
            XCTAssertEqual(
                support,
                .noProviderSession,
                "\(agent) with nothing to compact"
            )
        }
    }

    // MARK: - Claude Code

    func testClaudeCompactionRecordsAnAttributedSystemRowThenSendsTheBareNativeCommand() async throws {
        let fixture = try makeFixture()
        let before = fixture.session.items.count

        let outcome = await compact(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected an accepted compaction, got \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .runStarted)
        XCTAssertFalse(
            delivery.compactionRunsInBackground,
            "Claude compacts inside the turn it was sent on; there is no background work to cancel"
        )
        XCTAssertEqual(fixture.session.items.count, before + 1)
        let row = try XCTUnwrap(fixture.session.items.last)
        XCTAssertEqual(row.id, delivery.targetItemID)
        XCTAssertEqual(row.kind, .system, "RepoPrompt issued the command, not the target's user")
        XCTAssertEqual(row.text, AgentChatItem.overseerCompactionRequestText)
        XCTAssertEqual(row.crossSessionAttribution?.sourceSessionID, request.observerSessionID)
        XCTAssertEqual(row.crossSessionAttribution?.sourceName, "Planning")
        XCTAssertTrue(fixture.session.items.allSatisfy { $0.kind != .user }, "No /compact user row is fabricated")
        XCTAssertTrue(fixture.events.savedItemsContainAttributedRow(id: row.id))
        XCTAssertTrue(fixture.events.saveHappenedBeforeProviderStart())
        // The run is started through the ordinary pipeline; the exact provider bytes are pinned by
        // `AgentSessionLinkCompactClaudeDispatchTests`, which drives the raw lane directly.
        XCTAssertEqual(fixture.session.runState, .running)
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt, "The composer claim is released")
    }

    func testProviderControlOptionsSkipEveryUserAugmentationAndOnlyClaudeCodeDispatchesThem() {
        let command = AgentProviderControlCommand.compact(
            expectedBinding: AgentPersistentSessionBindingIdentity(tabID: UUID(), sessionID: UUID()),
            expectedProviderConversation: "conversation"
        )
        let options = AgentDirectRunStartOptions.providerControl(command)
        XCTAssertTrue(options.skipsUserAugmentation)
        XCTAssertTrue(options.ignoresPendingHandoff, "A compaction never spends the target's staged handoff")
        XCTAssertFalse(options.isLaneUpdate)
        XCTAssertEqual(command.providerText, "/compact", "Fixed text: the conversation binding never reaches the provider")
        for agent in AgentProviderKind.allCases {
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = agent
            XCTAssertEqual(
                AgentModeRunService.dispatchesProviderControlCommand(command, for: session),
                agent == .claudeCode,
                "\(agent) without a live advertising ACP session"
            )
        }
    }

    func testAFailedLastRunIsAdmittedBecauseThatIsWhenCompactionIsNeeded() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .failed

        let outcome = await compact(fixture)

        guard case .delivered = outcome else {
            return XCTFail("A target whose last turn failed is idle and must be admissible: \(outcome)")
        }
    }

    func testBusyWaitingOrInteractionTargetsAreRefusedWithoutMutation() async throws {
        for runState: AgentSessionRunState in [.running, .waitingForUser, .waitingForApproval, .waitingForQuestion] {
            let fixture = try makeFixture()
            fixture.session.runState = runState
            let before = fixture.session.items.count

            let outcome = await compact(fixture)

            XCTAssertEqual(outcome, .blocked(.targetNotIdle), "\(runState)")
            XCTAssertEqual(fixture.session.items.count, before, "\(runState)")
            XCTAssertFalse(fixture.events.contains(.save), "\(runState)")
        }
    }

    func testUnsupportedOrConversationlessTargetsAreRefusedBeforeAnythingIsRecorded() async throws {
        for (agent, conversation, expected) in [
            (AgentProviderKind.claudeCodeGLM, true, AgentSessionLinkSendFailure.notSupported),
            // A stored Devin conversation with no live provider session (e.g. right after a
            // relaunch) is retryable: it is not yet knowable whether the provider compacts.
            (.devin, true, .noProviderSession),
            (.claudeCode, false, .noProviderSession),
            (.codexExec, false, .noProviderSession)
        ] {
            let fixture = try makeFixture(agent: agent, providerConversation: conversation)
            let before = fixture.session.items.count

            let outcome = await compact(fixture)

            XCTAssertEqual(outcome, .blocked(expected), "\(agent)")
            XCTAssertEqual(fixture.session.items.count, before, "\(agent)")
            XCTAssertFalse(fixture.events.contains(.save), "\(agent)")
            XCTAssertFalse(fixture.events.contains(.providerControllerCreated), "\(agent)")
        }
    }

    func testLosingTheCommitFenceRecordsAndDispatchesNothing() async throws {
        let fixture = try makeFixture()
        let before = fixture.session.items.count

        let outcome = await compact(fixture, commit: { .linkRevoked })

        XCTAssertEqual(outcome, .blocked(.linkRevoked))
        XCTAssertEqual(fixture.session.items.count, before)
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt, "The composer claim is released")
        let sent = await fixture.claude.sentMessages
        XCTAssertTrue(sent.isEmpty)
    }

    func testAFailedDurableWriteRollsTheRequestRowBack() async throws {
        let fixture = try makeFixture(saverBehavior: .failFirst)
        let before = fixture.session.items.count

        let outcome = await compact(fixture)

        XCTAssertEqual(outcome, .blocked(.persistenceFailed))
        XCTAssertEqual(fixture.session.items.count, before)
        let sent = await fixture.claude.sentMessages
        XCTAssertTrue(sent.isEmpty)
    }

    func testDriftAfterTheDurableRecordWithholdsDispatch() async throws {
        let fixture = try makeFixture()
        var observerIsLive = true
        fixture.driftHook.duringDeliveryFlush = { observerIsLive = false }

        let outcome = await compact(fixture, liveness: {
            AgentSessionLinkSendLiveness(
                observerEndpointIsLive: observerIsLive,
                targetEndpointIsLive: true,
                targetWindowIsClosing: false
            )
        })

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("The durable request stays recorded: \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .persisted)
        let sent = await fixture.claude.sentMessages
        XCTAssertTrue(sent.isEmpty, "A target that became busy must not receive the command")
    }

    func testCompactionLeavesTheTargetsWaitingOnDeclarationAlone() async throws {
        let fixture = try makeFixture()
        let declaration = try XCTUnwrap(
            DomainAgentSessionWaitingOn(summary: "CI artifact", declaredAt: Date(timeIntervalSince1970: 50))
        )
        fixture.session.oversight.waitingOn = declaration

        guard case .delivered = await compact(fixture) else { return XCTFail("Expected an accepted compaction") }

        XCTAssertEqual(
            fixture.session.oversight.waitingOn,
            declaration,
            "Compaction resolves no dependency, so it must not retire the target's declaration"
        )
    }

    func testTheAttributedRequestRowNeverRevealsItsObserverToTranscriptReaders() {
        let row = AgentChatItem.overseerCompactionRequest(attribution: request.attribution, sequenceIndex: 3)
        for reader in [request.observerSessionID, UUID(), nil] {
            XCTAssertNil(
                AgentSessionLinkTranscriptSanitizer.crossSessionOrigin(for: row, readerSessionID: reader),
                "A system row carries no cross-session origin for any reader"
            )
        }
        XCTAssertEqual(row.text, AgentChatItem.overseerCompactionRequestText, "Replay sees only the fixed text")
    }

    // MARK: - Codex

    /// A failed Codex compaction start unwinds queued fallback follow-ups, which belong to the
    /// target's own user, so an overseer compaction is refused while any exist.
    func testCodexCompactionIsRefusedWhileTheTargetUsersFallbackFollowUpsAreQueued() async throws {
        let fixture = try makeFixture(agent: .codexExec)
        fixture.session.codexFallbackQueue = [AgentTabSession.CodexFallbackQueueEntry(
            id: UUID(),
            providerText: "queued follow-up",
            images: [],
            taggedFileAttachments: [],
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            attachmentReservationID: nil,
            optimisticUserItemID: nil,
            draftText: "queued follow-up",
            origin: .manual,
            fallbackReason: .staleAuthoritativeIdentity,
            originThreadID: "codex-thread",
            originControllerInstanceID: ObjectIdentifier(fixture.viewModel),
            originControllerGeneration: fixture.session.codexControllerGeneration,
            originRunID: UUID(),
            originRunAttemptID: UUID(),
            blockingTurn: nil,
            state: .queued
        )]
        let before = fixture.session.items.count

        let outcome = await compact(fixture)

        XCTAssertEqual(outcome, .blocked(.targetNotIdle))
        XCTAssertEqual(fixture.session.items.count, before)
        XCTAssertEqual(fixture.session.codexFallbackQueue.count, 1, "The user's queued follow-up survives")
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:compact"))
    }

    /// A resume that lands on any other thread (a fresh-thread fallback included) must not be
    /// compacted: the conversation the overseer meant is no longer the one attached.
    func testCodexCompactionIsWithheldWhenResumeLandsOnADifferentThread() async throws {
        let fixture = try makeFixture(agent: .codexExec)
        // The stub controller always resumes into its own "lifecycle" thread.
        fixture.session.codexConversationID = "a-thread-that-will-not-come-back"

        let outcome = await compact(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("The durable request stays recorded: \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .persisted, "Nothing was sent to the provider")
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:compact"))
    }

    func testIdleManagedCodexCompactionResumesExactThreadWithoutTurnBootstrap() async throws {
        let fixture = try makeFixture(agent: .codexExec, shouldManageCodexTooling: true)
        fixture.session.codexConversationID = "lifecycle"
        XCTAssertNil(fixture.session.codexController, "Exercise idle controller restoration")

        let outcome = await compact(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected an accepted Codex compaction, got \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .runStarted)
        XCTAssertEqual(fixture.codexRecorder.events.count(where: { $0 == "codex:compact" }), 1)
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:send"))
        XCTAssertEqual(fixture.session.codexConversationID, "lifecycle")
    }

    func testCancellationDuringCodexResumeWithholdsCompactionAfterExactThreadReturns() async throws {
        let gate = TestReleaseFence(name: "compact Codex resume")
        let fixture = try makeFixture(agent: .codexExec, shouldManageCodexTooling: true, codexResumeGate: gate)
        fixture.session.codexConversationID = "lifecycle"
        let operation = Task { await compact(fixture) }
        defer {
            operation.cancel()
            gate.release()
        }
        guard await gate.waitUntilEntered() else { return }
        XCTAssertEqual(fixture.session.items.last?.text, AgentChatItem.overseerCompactionRequestText)

        operation.cancel()
        gate.release()
        let outcome = await operation.value

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("The durable request survives cancellation: \(outcome)")
        }
        XCTAssertEqual(fixture.session.codexConversationID, "lifecycle")
        XCTAssertEqual(fixture.session.codexController?.hasActiveThread, true, "Resume still completed")
        XCTAssertEqual(delivery.deliveryState, .persisted, "The cancelled caller must not dispatch")
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:compact"))
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:send"))
        XCTAssertNil(fixture.session.codexPendingTurnKind)
        XCTAssertFalse(fixture.session.isComposerSubmissionInFlight, "The claim is released")
    }

    func testWorkspaceChangeDuringCodexResumeWithholdsCompactionAfterExactThreadReturns() async throws {
        let gate = TestReleaseFence(name: "compact Codex resume")
        let fixture = try makeFixture(agent: .codexExec, shouldManageCodexTooling: true, codexResumeGate: gate)
        fixture.session.codexConversationID = "lifecycle"
        let operation = Task { await compact(fixture) }
        defer {
            operation.cancel()
            gate.release()
        }
        guard await gate.waitUntilEntered() else { return }

        fixture.manager.activeWorkspace = nil
        gate.release()
        let outcome = await operation.value

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("The durable request survives workspace drift: \(outcome)")
        }
        XCTAssertEqual(fixture.session.codexConversationID, "lifecycle")
        XCTAssertEqual(fixture.session.codexController?.hasActiveThread, true, "Resume still completed")
        XCTAssertEqual(delivery.deliveryState, .persisted)
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:compact"))
        XCTAssertNil(fixture.session.codexPendingTurnKind)
        XCTAssertFalse(fixture.session.isComposerSubmissionInFlight, "The claim is released")
    }

    func testCodexCompactionStartsNativeThreadCompactionAndNeverSendsAMessage() async throws {
        let fixture = try makeFixture(agent: .codexExec)
        // The thread the stub controller resumes into, so preparation keeps the admitted thread.
        fixture.session.codexConversationID = "lifecycle"

        let outcome = await compact(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected an accepted Codex compaction, got \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .runStarted)
        XCTAssertEqual(fixture.codexRecorder.events.count(where: { $0 == "codex:compact" }), 1)
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:send"))
        XCTAssertEqual(fixture.session.codexPendingTurnKind, .compact)
        XCTAssertEqual(fixture.session.items.last?.text, AgentChatItem.overseerCompactionRequestText)
    }
}

/// The raw provider-command lane of the Claude coordinator, driven directly.
@MainActor
final class AgentSessionLinkCompactClaudeDispatchTests: XCTestCase {
    private var retained: [AnyObject] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    private func makeViewModel(
        controller: MonitorFakeNativeController
    ) throws -> (AgentModeViewModel, AgentModeViewModel.TabSession, MonitorInventoryPublisher, UUID) {
        let tabID = UUID()
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Raw command lane",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)],
            activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) },
            claudeControllerFactory: { _, _, _, _ in controller },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        retained.append(manager)
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { _, _, _ in
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        }
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        session.claudeController = controller
        let inventory = MonitorInventoryPublisher(viewModel: viewModel, observerSessionID: sessionID, tabID: tabID)
        return (viewModel, session, inventory, tabID)
    }

    private func intent(for session: AgentModeViewModel.TabSession) throws -> ClaudeAgentModeCoordinator.NativeSessionIntent {
        if session.runID == nil { session.installRunID(UUID()) }
        let runID = try XCTUnwrap(session.runID)
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.compact.raw")
        return .runAttempt(ownership: ownership, runID: runID)
    }

    func testRawCommandSendsExactlyTheNativeTextAndLeavesTheOversightSupplementOwed() async throws {
        let controller = MonitorFakeNativeController()
        let (viewModel, session, inventory, _) = try makeViewModel(controller: controller)
        // The fake controller's live conversation, so preparation keeps the same conversation.
        session.providerSessionID = "monitor-native-session"
        inventory.publish(revision: 1, targetCount: 1)
        let runIntent = try intent(for: session)
        let binding = try XCTUnwrap(session.persistentSessionBindingIdentity)

        let outcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "/compact",
            attachments: [],
            intent: runIntent,
            allowsCatalogRouteControllerRecovery: false,
            providerControlCommand: .compact(
                expectedBinding: binding,
                expectedProviderConversation: "monitor-native-session"
            )
        )

        XCTAssertEqual(outcome, .sent)
        let sent = await controller.sentMessages
        XCTAssertEqual(sent, ["/compact"])

        // The supplement this turn skipped is still owed to the next ordinary turn.
        _ = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "next turn",
            attachments: [],
            intent: runIntent,
            allowsCatalogRouteControllerRecovery: false
        )
        let after = await controller.sentMessages
        try MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(XCTUnwrap(after.last), userContent: "next turn")
    }

    /// A failed resume falls back to a fresh provider conversation. There is then nothing to compact,
    /// so the command must not run against the empty conversation.
    func testRawCommandFailsClosedWhenTheConversationCannotBeResumed() async throws {
        let controller = MonitorFakeNativeController()
        await controller.setRejectResume(true)
        let (viewModel, session, _, _) = try makeViewModel(controller: controller)
        session.providerSessionID = "conversation-to-compact"
        let runIntent = try intent(for: session)
        let binding = try XCTUnwrap(session.persistentSessionBindingIdentity)

        let outcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "/compact",
            attachments: [],
            intent: runIntent,
            allowsCatalogRouteControllerRecovery: false,
            providerControlCommand: .compact(
                expectedBinding: binding,
                expectedProviderConversation: "conversation-to-compact"
            )
        )

        guard case .failed = outcome else { return XCTFail("Expected a fail-closed refusal, got \(outcome)") }
        let sent = await controller.sentMessages
        XCTAssertTrue(sent.isEmpty, "Nothing may run against a conversation the command was not for")
    }

    /// Run preparation can suspend after the admitting transaction's last fence. A rebind in that
    /// window may keep the provider conversation, so the command is bound to the exact binding too.
    func testRawCommandFailsClosedAfterARebindThatKeepsTheProviderConversation() async throws {
        let controller = MonitorFakeNativeController()
        let (viewModel, session, _, _) = try makeViewModel(controller: controller)
        session.providerSessionID = "monitor-native-session"
        let admittedBinding = try XCTUnwrap(session.persistentSessionBindingIdentity)
        let runIntent = try intent(for: session)
        // Rebound to the same session UUID: a new binding identity, same provider conversation.
        session.installPersistentSessionBinding(
            AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: admittedBinding.sessionID)
        )

        let outcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "/compact",
            attachments: [],
            intent: runIntent,
            allowsCatalogRouteControllerRecovery: false,
            providerControlCommand: .compact(
                expectedBinding: admittedBinding,
                expectedProviderConversation: "monitor-native-session"
            )
        )

        XCTAssertNotEqual(outcome, .sent, "A rebound session must never receive the command")
        let sent = await controller.sentMessages
        XCTAssertTrue(sent.isEmpty)
    }

    func testRawCommandFailsClosedInsteadOfInterruptingAnInFlightTurn() async throws {
        let controller = MonitorFakeNativeController()
        await controller.setTurnInFlight(true)
        let (viewModel, session, _, _) = try makeViewModel(controller: controller)
        session.providerSessionID = "monitor-native-session"
        let runIntent = try intent(for: session)
        let binding = try XCTUnwrap(session.persistentSessionBindingIdentity)

        let outcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "/compact",
            attachments: [],
            intent: runIntent,
            allowsCatalogRouteControllerRecovery: false,
            providerControlCommand: .compact(
                expectedBinding: binding,
                expectedProviderConversation: "monitor-native-session"
            )
        )

        guard case let .failed(message) = outcome else {
            return XCTFail("Expected a fail-closed refusal, got \(outcome)")
        }
        XCTAssertTrue(message.contains("still in flight"), message)
        let sent = await controller.sentMessages
        XCTAssertTrue(sent.isEmpty)
    }
}

/// A native runtime stub with an active session that records every provider-bound message.
actor CompactRecordingNativeController: NativeAgentRuntimeControlling {
    private(set) var sentMessages: [String] = []
    private let stream: AsyncStream<NativeAgentRuntimeEvent>

    init() {
        stream = AsyncStream { $0.finish() }
    }

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        false
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        stream
    }

    func ensureEventsStreamReady() {}
    func resetEventsStreamForNewRun() {}

    func startOrResume(
        existingSessionID: String?,
        model _: String?,
        effortLevel _: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride _: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: existingSessionID ?? "compact-recording")
    }

    func currentSessionRef() -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "compact-recording")
    }

    func applyModelAndEffort(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws {}

    func sendUserMessage(_ text: String) async throws -> UUID {
        sentMessages.append(text)
        return UUID()
    }

    func interruptTurn(reason _: String) -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() {}
    func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) {}
}
