import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionLinkStopTransactionTests: XCTestCase {
    private struct Fixture {
        let viewModel: AgentModeViewModel
        let tabID: UUID
        let session: AgentModeViewModel.TabSession
        let candidate: AgentSessionLinkEndpointCandidate
    }

    private var retainedFixtures: [(AgentModeViewModel, WorkspaceManagerViewModel)] = []

    override func tearDown() {
        retainedFixtures.removeAll()
        super.tearDown()
    }

    private func makeFixture() throws -> Fixture {
        let tabID = UUID()
        let files = WorkspaceFilesViewModel()
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keys),
            keyManager: keys, loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: files, apiSettingsViewModel: api, windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: files, promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Stop target", repoPaths: [], ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)], activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retainedFixtures.append((viewModel, manager))
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { _, _, _ in
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        }
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        let candidate = try XCTUnwrap(viewModel.agentSessionLinkCandidate(
            tabID: tabID, sessionID: sessionID, tabName: "Stop target", isWindowClosing: false
        ))
        return Fixture(viewModel: viewModel, tabID: tabID, session: session, candidate: candidate)
    }

    private func stop(
        _ fixture: Fixture,
        auditDeadlineSeconds: TimeInterval = 1,
        beforeCleanupTask: @escaping @MainActor () -> Void = {}
    ) async -> AgentSessionLinkStopTransactionOutcome {
        let observer = DomainAgentSessionLinkEndpointIdentity(
            windowID: 2, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(),
            persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
        )
        return await fixture.viewModel.agentSessionLinkPerformStop(
            to: fixture.candidate,
            request: AgentSessionLinkStopRequest(
                requestID: UUID(), linkID: UUID(), linkGeneration: 1,
                observerEndpoint: observer, observerDisplayName: "Overseer"
            ),
            liveness: { AgentSessionLinkSendLiveness(
                observerEndpointIsLive: true, targetEndpointIsLive: true,
                targetWindowIsClosing: false
            ) },
            queueHasCommittedDrain: { false },
            withdrawInbound: { true },
            commitAuthorization: { .committed },
            teardownDeadlineSeconds: 1,
            auditDeadlineSeconds: auditDeadlineSeconds,
            beforeCleanupTask: beforeCleanupTask
        )
    }

    func testIdleTargetRetainsNoopWithoutRowOrMutation() async throws {
        let fixture = try makeFixture()
        let before = fixture.session.items.count
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .notRunning)
        XCTAssertEqual(receipt.stopRequested, false)
        XCTAssertNil(receipt.targetItemID)
        XCTAssertEqual(fixture.session.items.count, before)
        XCTAssertEqual(fixture.session.runState, .idle)
    }

    func testPendingStartWithdrawsWithoutSyntheticTerminalRun() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .completed
        fixture.session.mcpFollowUpRunPending = true
        fixture.session.pendingInstructions = ["the user's queued instruction"]
        let beforeRevision = fixture.session.lastTerminalCommitRevision
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertFalse(fixture.session.mcpFollowUpRunPending)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        XCTAssertEqual(fixture.session.runState, .completed)
        XCTAssertEqual(fixture.session.lastTerminalCommitRevision, beforeRevision)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text == AgentChatItem.overseerRunStoppedText }), 1)
    }

    func testManagedPendingContentIsDroppedNotRestoredAsUserDraft() async throws {
        let fixture = try makeFixture()
        fixture.viewModel.storeDraftText(for: fixture.tabID, "the user's own draft")
        fixture.session.mcpFollowUpRunPending = true
        fixture.session.pendingInstructions = ["<managed_direction>overseer-only</managed_direction>"]
        fixture.session.pendingClaudeSteeringInstructions = [
            .init(
                id: UUID(), targetRunID: nil, targetRunAttemptID: nil,
                providerText: "overseer-only", attachments: [], taggedFileAttachments: [],
                draftText: "", optimisticUserItemID: nil, createdAt: Date()
            )
        ]
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "the user's own draft")
        XCTAssertFalse(fixture.viewModel.retrieveDraftText(for: fixture.tabID).contains("overseer-only"))
    }

    func testActiveRunUsesCancellationSpineAndAttributedFactRow() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "overseer-stop-test")
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertEqual(fixture.session.runState, .cancelled)
        XCTAssertTrue(receipt.teardownCompleted == true)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text == AgentChatItem.overseerRunStoppedText }), 1)
    }

    func testSuccessfulStopRetainsResultWhenAuditSaveFails() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "stop-save-failure")
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
            throw NSError(domain: "StopAuditFailure", code: 1)
        }
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertEqual(receipt.auditStatus, .failed)
        XCTAssertEqual(fixture.session.runState, .cancelled)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text == AgentChatItem.overseerRunStoppedText }), 1)
    }

    func testAuditDeadlineRetainsUnknownWithoutRepeatingCancellation() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "stop-save-timeout")
        let gate = AgentSessionLinkStopSignal<Void>()
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
            await gate.value()
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(UUID().uuidString).json")
        }
        let outcome = await stop(fixture, auditDeadlineSeconds: 0.05)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertEqual(receipt.auditStatus, .unknown)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text == AgentChatItem.overseerRunStoppedText }), 1)
        gate.finish(())
    }

    func testSecondUserStopForceRetiresUnclaimedTerminalGate() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "wedged-stop-gate")
        guard case .settled = await stop(fixture) else { return XCTFail("expected Stop receipt") }
        let binding = try XCTUnwrap(fixture.session.persistentSessionBindingIdentity)
        let wedgedID = UUID()
        XCTAssertTrue(fixture.session.stopState.claimManagedStop(id: wedgedID, binding: binding))
        fixture.session.stopState.markCleanupUnclaimedIfNeverStarted(id: wedgedID, binding: binding)
        XCTAssertTrue(fixture.session.stopState.isStopping(binding: binding))
        await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID)
        XCTAssertFalse(fixture.session.stopState.isStopping(binding: binding))
    }

    func testCleanupDeadlineNeverUnclaimsAnExecutingTeardown() throws {
        let fixture = try makeFixture()
        let binding = try XCTUnwrap(fixture.session.persistentSessionBindingIdentity)
        let stopID = UUID()
        XCTAssertTrue(fixture.session.stopState.claimManagedStop(id: stopID, binding: binding))
        fixture.session.stopState.markCleanupStarted(id: stopID, binding: binding)
        fixture.session.stopState.markCleanupUnclaimedIfNeverStarted(id: stopID, binding: binding)
        XCTAssertTrue(fixture.session.stopState.isStopping(binding: binding))
        XCTAssertFalse(fixture.session.stopState.forceRetireUnclaimedStop(binding: binding))
        XCTAssertTrue(fixture.session.stopState.releaseManagedStop(id: stopID, binding: binding))
    }

    func testNaturalCompletionBeforeTaskEntryIsNoopWithoutAttribution() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "natural-completion-race")
        let outcome = await stop(fixture, beforeCleanupTask: {
            fixture.session.runState = .completed
        })
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .notRunning)
        XCTAssertEqual(receipt.stopRequested, false)
        XCTAssertNil(receipt.targetItemID)
        XCTAssertTrue(fixture.session.items.allSatisfy { $0.text != AgentChatItem.overseerRunStoppedText })
    }

    func testPureAdmissionSelectsActiveWaitingAndPendingStart() {
        for waiting in [AgentSessionRunState.running, .waitingForUser, .waitingForQuestion, .waitingForApproval] {
            var snapshot = AgentSessionLinkDeliveryReadiness.Snapshot.ready
            snapshot.runStateIsActive = waiting.isActive
            snapshot.hasWaitingPrompt = waiting == .waitingForUser
            XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .activeRun)
        }
        var pending = AgentSessionLinkDeliveryReadiness.Snapshot.ready
        pending.mcpFollowUpRunPending = true
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(pending), .pendingStart)
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(.ready), .notRunning)
    }

    func testBusyAndLifecycleRefusalsTakePrecedence() {
        var snapshot = AgentSessionLinkDeliveryReadiness.Snapshot.ready
        snapshot.runStateIsActive = true
        snapshot.terminalCommitInProgress = true
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .blocked(.targetBusy))
        snapshot.terminalCommitInProgress = false
        snapshot.stopInProgress = true
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .blocked(.targetBusy))
        snapshot.stopInProgress = false
        snapshot.hasLoadedPersistedState = false
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .blocked(.targetLoading))
        snapshot.endpointMatchesGrant = false
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .blocked(.endpointInvalidated))
    }

    func testInteractionIsNotABlockerAndUnsentDraftIsNotInSnapshot() {
        var snapshot = AgentSessionLinkDeliveryReadiness.Snapshot.ready
        snapshot.runStateIsActive = true
        snapshot.hasPendingApproval = true
        snapshot.hasPendingAskUser = true
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .activeRun)
    }
}
