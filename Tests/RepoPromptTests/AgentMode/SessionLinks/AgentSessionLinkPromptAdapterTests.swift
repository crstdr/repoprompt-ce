import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

// MARK: - Shared support

/// Assertions shared by every adapter suite.
///
/// The whole point of these suites is that they inspect the string that actually crossed a provider
/// boundary — `startUserTurn`, `steerUserTurn`, `sendUserMessage`, `streamAgentMessage`,
/// `session/prompt`, or a resumed continuation — rather than a value a test handed to itself.
enum MonitorSupplementAssertions {
    static let openTag = "<\(AgentSessionLinkPrompts.envelopeTag) "

    static func fragmentCount(in text: String) -> Int {
        text.components(separatedBy: openTag).count - 1
    }

    /// Exactly one supplement, appended after the user-controlled content.
    static func assertCarriesExactlyOneSupplement(
        _ text: String,
        userContent: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(fragmentCount(in: text), 1, "expected exactly one supplement", file: file, line: line)
        XCTAssertTrue(text.contains(userContent), "user content must survive", file: file, line: line)
        let supplementStart = try? XCTUnwrap(text.range(of: openTag), file: file, line: line)
        let contentStart = try? XCTUnwrap(text.range(of: userContent), file: file, line: line)
        if let supplementStart, let contentStart {
            XCTAssertTrue(
                contentStart.lowerBound < supplementStart.lowerBound,
                "the supplement must be the final RepoPrompt envelope, after user content",
                file: file,
                line: line
            )
        }
    }

    static func assertCarriesNoSupplement(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(fragmentCount(in: text), 0, "expected no supplement", file: file, line: line)
    }

    /// The supplement must never become user-authored transcript or persisted queue state.
    @MainActor
    static func assertNotPersisted(
        in session: AgentModeViewModel.TabSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for item in session.items {
            XCTAssertFalse(
                item.text.contains(AgentSessionLinkPrompts.envelopeTag),
                "transcript row must never carry the supplement",
                file: file,
                line: line
            )
        }
        for instruction in session.pendingInstructions {
            XCTAssertFalse(instruction.contains(AgentSessionLinkPrompts.envelopeTag), file: file, line: line)
        }
        for instruction in session.pendingACPSteeringInstructions {
            XCTAssertFalse(
                instruction.providerText.contains(AgentSessionLinkPrompts.envelopeTag),
                file: file,
                line: line
            )
        }
        for entry in session.codexFallbackQueue {
            XCTAssertFalse(
                entry.providerText.contains(AgentSessionLinkPrompts.envelopeTag),
                "a queued entry must persist undecorated provider text",
                file: file,
                line: line
            )
        }
        XCTAssertFalse(
            session.codexPendingAuthRetryTurn?.text.contains(AgentSessionLinkPrompts.envelopeTag) ?? false,
            "the auth-retry buffer must persist undecorated provider text",
            file: file,
            line: line
        )
    }
}

/// Publishes a real inventory onto a live view model and advances membership like the bridge does.
///
/// Publication is addressed to the tab's exact live incarnation, exactly as the bridge addresses it,
/// so a suite cannot accidentally hand an inventory to a session UUID that no longer resolves.
@MainActor
struct MonitorInventoryPublisher {
    let viewModel: AgentModeViewModel
    let observerSessionID: UUID
    let tabID: UUID

    func publish(revision: UInt64, targetCount: Int) {
        guard let endpoint = viewModel.agentSessionLinkObserverEndpoint(tabID: tabID) else {
            let live = viewModel.sessions[tabID]?.activeAgentSessionID?.uuidString ?? "nil"
            let claimed = viewModel.workspaceManager?.workspaces
                .flatMap(\.composeTabs)
                .first { $0.id == tabID }?
                .activeAgentSessionID?.uuidString ?? "nil"
            let tabCount = viewModel.workspaceManager?.workspaces.flatMap(\.composeTabs).count ?? -1
            return XCTFail(
                """
                expected a resolvable oversight endpoint for the publishing tab \
                (liveSession=\(live) workspaceClaim=\(claimed) workspaceTabs=\(tabCount))
                """
            )
        }
        viewModel.agentSessionLinkPublishPromptInventory(
            AgentSessionLinkPromptInventory(
                observerSessionID: observerSessionID,
                linkSetRevision: revision,
                items: (0 ..< targetCount).map { index in
                    AgentSessionLinkPromptInventoryItem(
                        targetSessionID: UUID(
                            uuidString: String(format: "0000000%d-0000-0000-0000-00000000BEEF", index)
                        )!,
                        displayName: "Target \(index)",
                        capabilityNames: ["poll", "read", "send_when_idle", "wait"]
                    )
                }
            ),
            to: endpoint
        )
    }
}

// MARK: - Codex adapters

/// Codex dispatch adapters, driven through the real `CodexAgentModeCoordinator`.
///
/// Every assertion reads the text the fake controller actually received, so a regression that stops
/// composing, composes at the wrong point, or double-composes is caught at the provider boundary.
@MainActor
final class AgentSessionLinkCodexPromptAdapterTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let coordinator: CodexAgentModeCoordinator
        let controller: MonitorFakeCodexController
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let tabID: UUID
        let inventory: MonitorInventoryPublisher
        let authRecovery: MonitorStubCodexAuthRecovery
        /// Retained: the view model holds its workspace manager weakly.
        let workspaceManager: WorkspaceManagerViewModel
    }

    private func makeFixture() throws -> Fixture {
        let controller = MonitorFakeCodexController()
        let authRecovery = MonitorStubCodexAuthRecovery()
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true },
            testCodexAuthRecovery: authRecovery
        )
        retained.append(viewModel)
        // The supplement is scoped to an exact incarnation, so the tab needs a real workspace
        // binding rather than a bare `session(for:)` tab.
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Oversee Codex adapters"
        )
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        return Fixture(
            viewModel: viewModel,
            coordinator: viewModel.test_codexCoordinator,
            controller: controller,
            session: session,
            sessionID: sessionID,
            tabID: tabID,
            inventory: MonitorInventoryPublisher(
                viewModel: viewModel,
                observerSessionID: sessionID,
                tabID: tabID
            ),
            authRecovery: authRecovery,
            workspaceManager: workspaceManager
        )
    }

    // MARK: Start

    func testInitialStartCarriesExactlyOneSupplementThenGoesQuiet() async throws {
        let fixture = try makeFixture()
        fixture.inventory.publish(revision: 1, targetCount: 2)
        fixture.session.beginRunAttempt(source: "test.codex.start")

        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "first turn",
            attachments: []
        )

        let first = try XCTUnwrap(fixture.controller.startedTurns.first)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(first, userContent: "first turn")
        XCTAssertTrue(
            first.contains("mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__agent_session_link"),
            "Codex sessions must see the namespace-qualified tool reference"
        )

        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.start.second")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "second turn",
            attachments: []
        )

        let second = try XCTUnwrap(fixture.controller.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesNoSupplement(second)
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    func testMembershipChangeReopensTheSupplementOnTheNextStart() async throws {
        let fixture = try makeFixture()
        fixture.inventory.publish(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.rev1")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "turn one",
            attachments: []
        )

        fixture.inventory.publish(revision: 2, targetCount: 2)
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.rev2")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "turn two",
            attachments: []
        )

        let second = try XCTUnwrap(fixture.controller.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(second, userContent: "turn two")
        XCTAssertTrue(second.contains("count=\"2\""))
    }

    func testLastLinkRevocationDeliversOneClosingNoticeThenSilence() async throws {
        let fixture = try makeFixture()
        fixture.inventory.publish(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.linked")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "linked turn",
            attachments: []
        )

        fixture.inventory.publish(revision: 2, targetCount: 0)
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.revoked")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "after revoke",
            attachments: []
        )
        let closing = try XCTUnwrap(fixture.controller.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(closing, userContent: "after revoke")
        XCTAssertTrue(closing.contains("status=\"ended\""))

        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.after-revoked")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "silent turn",
            attachments: []
        )
        try MonitorSupplementAssertions.assertCarriesNoSupplement(
            XCTUnwrap(fixture.controller.startedTurns.last)
        )
    }

    // MARK: Steer

    func testSteerDispatchCarriesTheSupplement() async throws {
        let fixture = try makeFixture()
        fixture.inventory.publish(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.steer.seed")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "seed turn",
            attachments: []
        )
        // The seed consumed revision 1; a membership change makes the steer owe a fresh supplement.
        fixture.inventory.publish(revision: 2, targetCount: 1)

        // Reach a steerable state the same way the runtime does: the provider reports the turn it
        // started, which installs the authoritative turn identity `codexTurnDispatchPlan` requires.
        fixture.controller.markActiveTurn(id: "turn-1")
        await fixture.coordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "turn-1"),
            session: fixture.session,
            sourceController: fixture.controller
        )
        XCTAssertEqual(
            fixture.session.codexAuthoritativeActiveTurn?.turnID,
            "turn-1",
            "the next send must resolve to a steer, not another start"
        )
        XCTAssertTrue(fixture.session.runState.isActive)

        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "steered instruction",
            attachments: []
        )

        let steered = try XCTUnwrap(fixture.controller.steeredTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            steered,
            userContent: "steered instruction"
        )
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    // MARK: Queued fallback

    func testQueuedFallbackComposesAtDrainTimeWithCurrentMembership() async throws {
        let fixture = try makeFixture()
        fixture.inventory.publish(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.fallback.seed")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "seed turn",
            attachments: []
        )
        await fixture.coordinator.test_handleCodexNativeEvent(
            .turnStarted(turnID: "turn-1"),
            session: fixture.session,
            sourceController: fixture.controller
        )

        // The provider rejects the steer with "no active turn", which is exactly how a turn lands in
        // the fallback queue. Membership changes while it sits there.
        fixture.controller.steerFailure = .noActiveTurn(
            CodexAppServerClient.RequestFailure(
                method: "turn/steer",
                code: nil,
                message: "no active turn",
                data: nil
            )
        )
        let outcome = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "queued instruction",
            attachments: []
        )
        guard case .queuedFallback = outcome else {
            return XCTFail("expected the steer rejection to queue a fallback, got \(outcome)")
        }
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)

        fixture.controller.steerFailure = nil
        fixture.inventory.publish(revision: 2, targetCount: 3)

        // The pump drains the head once the thread reports idle.
        //
        // Both the wait and the selection below are anchored with `hasPrefix`, not `contains`: the
        // supplement is always appended *after* the provider text, so a dispatch of this entry is
        // exactly a turn that starts with it. A substring match instead reads the guidance prose,
        // which itself talks about "draining a queued instruction" — so the *seed* turn's supplement
        // satisfied it, the wait returned before the queue had drained at all, and the assertions
        // then ran against the seed turn (one supplement, but ahead of "queued instruction" in the
        // guidance text, and at the enqueue-time revision). Whether the drain happened to land first
        // decided whether the suite passed, which is what made this read as a timing flake.
        try await AsyncTestWait.waitUntil("the queued Codex fallback entry to dispatch", timeout: 5) {
            await MainActor.run {
                fixture.controller.startedTurns.contains { $0.hasPrefix("queued instruction") }
            }
        }

        let dispatched = try XCTUnwrap(
            fixture.controller.startedTurns.last { $0.hasPrefix("queued instruction") }
        )
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            dispatched,
            userContent: "queued instruction"
        )
        XCTAssertTrue(
            dispatched.contains("count=\"3\""),
            "a queued entry must render membership at drain time, not at enqueue time"
        )
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    // MARK: Managed-auth recovery replay

    func testAuthRecoveryReplayPreservesTheAlreadyAcknowledgedSupplement() async throws {
        let fixture = try makeFixture()
        fixture.inventory.publish(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.auth")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "auth turn",
            attachments: []
        )
        let original = try XCTUnwrap(fixture.controller.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(original, userContent: "auth turn")

        // The provider accepted the dispatch, then failed it with an auth-classified error. Managed
        // recovery replays the same turn; without the acknowledged claim it would ship bare text and
        // the revision would be lost forever, because no later turn owes it again.
        await fixture.coordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "stream error: unexpected status 401 Unauthorized from api.openai.com/v1/responses",
                willRetry: false,
                threadID: nil,
                turnID: nil,
                itemID: nil
            )),
            session: fixture.session,
            sourceController: fixture.controller
        )

        let didRefresh = await fixture.authRecovery.didRefresh
        XCTAssertTrue(didRefresh, "the recovery path must have run")
        XCTAssertEqual(fixture.controller.startedTurns.count, 2, "the turn must have been replayed")
        let replay = try XCTUnwrap(fixture.controller.startedTurns.last)
        XCTAssertEqual(replay, original, "the replay must be byte-identical to the accepted dispatch")
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(replay, userContent: "auth turn")
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    func testAuthRecoveryReplayViaServerRequestIssuePreservesTheSupplement() async throws {
        let fixture = try makeFixture()
        fixture.inventory.publish(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.auth.issue")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "issue turn",
            attachments: []
        )
        let original = try XCTUnwrap(fixture.controller.startedTurns.last)

        await fixture.coordinator.test_handleCodexNativeEvent(
            .serverRequestIssue(.init(
                requestID: .string("req-1"),
                method: "account/chatgptAuthTokens/refresh",
                kind: .authTokensRefreshFailed,
                message: "account/chatgptAuthTokens/refresh failed"
            )),
            session: fixture.session,
            sourceController: fixture.controller
        )

        let didRefresh = await fixture.authRecovery.didRefresh
        XCTAssertTrue(didRefresh)
        XCTAssertEqual(fixture.controller.startedTurns.count, 2)
        XCTAssertEqual(try XCTUnwrap(fixture.controller.startedTurns.last), original)
        try MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            XCTUnwrap(fixture.controller.startedTurns.last),
            userContent: "issue turn"
        )
    }

    func testAuthRecoveryReplayShipsCurrentMembershipWhenLinksChangedMidRecovery() async throws {
        let fixture = try makeFixture()
        fixture.inventory.publish(revision: 1, targetCount: 1)
        fixture.session.beginRunAttempt(source: "test.codex.auth.churn")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "churn turn",
            attachments: []
        )
        XCTAssertTrue(try XCTUnwrap(fixture.controller.startedTurns.last).contains("count=\"1\""))

        // A monitor is added while the failed turn is being recovered.
        fixture.inventory.publish(revision: 2, targetCount: 3)
        await fixture.coordinator.test_handleCodexNativeEvent(
            .errorNotification(.init(
                message: "external auth is active",
                willRetry: false,
                threadID: nil,
                turnID: nil,
                itemID: nil
            )),
            session: fixture.session,
            sourceController: fixture.controller
        )

        let replay = try XCTUnwrap(fixture.controller.startedTurns.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(replay, userContent: "churn turn")
        XCTAssertTrue(replay.contains("count=\"3\""), "the replay must ship the current membership")

        // Revision 2 is now acknowledged, so an ordinary later turn is quiet.
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "test.codex.auth.after")
        _ = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "later turn",
            attachments: []
        )
        try MonitorSupplementAssertions.assertCarriesNoSupplement(
            XCTUnwrap(fixture.controller.startedTurns.last)
        )
    }
}

// MARK: - Claude native, headless, and continuation adapters

/// Non-Codex dispatch adapters driven through the real runners.
@MainActor
final class AgentSessionLinkNativeAndHeadlessPromptAdapterTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let tabID: UUID
        let inventory: MonitorInventoryPublisher
        /// Retained: the view model holds its workspace manager weakly.
        let workspaceManager: WorkspaceManagerViewModel
    }

    private func makeFixture(
        agent: AgentProviderKind,
        claudeController: MonitorFakeNativeController? = nil
    ) throws -> Fixture {
        let tabID = UUID()
        // A real run resolves its workspace before it reaches a provider, so the runner-level suites
        // need the same live workspace wiring the cross-session send suite uses.
        let workspaceFiles = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: workspaceFiles,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: workspaceFiles,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Oversee prompt adapters",
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
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            claudeControllerFactory: claudeController.map { controller in
                { _, _, _, _ in controller }
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { _, _, _ in
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(UUID().uuidString).json")
        }
        let session = viewModel.session(for: tabID)
        session.selectedAgent = agent
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        return Fixture(
            viewModel: viewModel,
            session: session,
            sessionID: sessionID,
            tabID: tabID,
            inventory: MonitorInventoryPublisher(
                viewModel: viewModel,
                observerSessionID: sessionID,
                tabID: tabID
            ),
            workspaceManager: manager
        )
    }

    // MARK: Claude native

    func testClaudeNativeSendCarriesExactlyOneSupplementThenGoesQuiet() async throws {
        let controller = MonitorFakeNativeController()
        let fixture = try makeFixture(agent: .claudeCode, claudeController: controller)
        fixture.inventory.publish(revision: 1, targetCount: 2)
        fixture.session.claudeController = controller

        _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: fixture.session,
            text: "claude turn",
            attachments: []
        )

        let sent = await controller.sentMessages
        let first = try XCTUnwrap(sent.first)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(first, userContent: "claude turn")
        XCTAssertTrue(
            first.contains("mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__agent_session_link"),
            "Claude-compatible runtimes resolve RepoPrompt tools by their server-qualified name"
        )
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)

        _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: fixture.session,
            text: "second turn",
            attachments: []
        )
        let after = await controller.sentMessages
        try MonitorSupplementAssertions.assertCarriesNoSupplement(XCTUnwrap(after.last))
    }

    func testClaudeNativeRevocationDeliversOneClosingNotice() async throws {
        let controller = MonitorFakeNativeController()
        let fixture = try makeFixture(agent: .claudeCode, claudeController: controller)
        fixture.inventory.publish(revision: 1, targetCount: 1)
        fixture.session.claudeController = controller
        _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: fixture.session,
            text: "linked",
            attachments: []
        )

        fixture.inventory.publish(revision: 2, targetCount: 0)
        _ = await fixture.viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: fixture.session,
            text: "after revoke",
            attachments: []
        )

        let sent = await controller.sentMessages
        let closing = try XCTUnwrap(sent.last)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(closing, userContent: "after revoke")
        XCTAssertTrue(closing.contains("status=\"ended\""))
    }

    // MARK: Waiting-instruction continuations

    func testQueuedContinuationComposesAtDrainTimeWithCurrentMembership() async throws {
        let fixture = try makeFixture(agent: .claudeCode)
        // The instruction was queued before any monitor existed; membership is read at drain time.
        fixture.session.pendingInstructions = ["queued instruction"]
        fixture.inventory.publish(revision: 1, targetCount: 2)

        let response = try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID)

        let text = try XCTUnwrap(response.text)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            text,
            userContent: "queued instruction"
        )
        XCTAssertTrue(text.contains("count=\"2\""))
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)
    }

    func testResumedContinuationCarriesExactlyOneSupplementAndConsumesItOnce() async throws {
        let fixture = try makeFixture(agent: .claudeCode)
        fixture.inventory.publish(revision: 1, targetCount: 1)

        let waiting = Task { @MainActor in
            try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID)
        }
        try await AsyncTestWait.waitUntil("the waiting continuation to install") {
            await MainActor.run { fixture.session.instructionContinuation != nil }
        }

        _ = fixture.viewModel.submitUserTurn(text: "resumed instruction")

        let response = try await waiting.value
        let text = try XCTUnwrap(response.text)
        MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(
            text,
            userContent: "resumed instruction"
        )
        MonitorSupplementAssertions.assertNotPersisted(in: fixture.session)

        // The revision is consumed: a later queued continuation at the same membership is quiet.
        fixture.session.runState = .idle
        fixture.session.pendingInstructions = ["later instruction"]
        let later = try await fixture.viewModel.waitForNextUserInstruction(tabID: fixture.tabID)
        try MonitorSupplementAssertions.assertCarriesNoSupplement(XCTUnwrap(later.text))
    }
}

// MARK: - Non-Codex fakes

actor MonitorFakeNativeController: NativeAgentRuntimeControlling {
    private(set) var sentMessages: [String] = []
    private var stream: AsyncStream<NativeAgentRuntimeEvent>?
    private var continuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation?

    var sentCount: Int {
        sentMessages.count
    }

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        false
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        if let stream { return stream }
        let created = AsyncStream<NativeAgentRuntimeEvent> { continuation in
            self.continuation = continuation
        }
        stream = created
        return created
    }

    func ensureEventsStreamReady() async {}
    func resetEventsStreamForNewRun() async {}

    func startOrResume(
        existingSessionID: String?,
        model _: String?,
        effortLevel _: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride _: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: existingSessionID ?? "monitor-native-session")
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "monitor-native-session")
    }

    func applyModelAndEffort(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws {}

    func sendUserMessage(_ text: String) async throws -> UUID {
        sentMessages.append(text)
        return UUID()
    }

    func interruptTurn(reason _: String) async -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() async {
        continuation?.finish()
    }

    func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) async {}
}

// MARK: - Codex fakes

final class MonitorFakeCodexController: CodexSessionControllerPassiveStubDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    private var steered: [String] = []
    private var activeTurnID: String?
    private var threadStarted = false
    /// When set, `steerUserTurn` throws it instead of accepting, which is how the runtime lands in
    /// the queued-fallback path.
    var steerFailure: CodexTurnSteerError?
    private let continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation
    private let stream: AsyncStream<CodexNativeSessionController.Event>

    init() {
        var storedContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation!
        stream = AsyncStream { storedContinuation = $0 }
        continuation = storedContinuation
    }

    var startedTurns: [String] {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var steeredTurns: [String] {
        lock.lock()
        defer { lock.unlock() }
        return steered
    }

    func markActiveTurn(id: String) {
        lock.lock()
        activeTurnID = id
        lock.unlock()
    }

    /// False until `startOrResume` runs, exactly like the real controller.
    ///
    /// A fake that reports an active thread from construction makes `ensureCodexNativeSession`
    /// short-circuit, so the session never receives a conversation ID and can never reach a steerable
    /// authoritative turn.
    var hasActiveThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return threadStarted
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        stream
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        lock.lock()
        threadStarted = true
        lock.unlock()
        return CodexNativeSessionController.SessionRef(
            conversationID: "monitor-thread",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func startUserTurn(
        text: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        lock.lock()
        started.append(text)
        lock.unlock()
        return CodexTurnStartReceipt(provisionalSubmissionID: "sub-\(started.count)")
    }

    func steerUserTurn(
        text: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        if let steerFailure { throw steerFailure }
        lock.lock()
        steered.append(text)
        lock.unlock()
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    /// Always reports an idle thread so the queued-fallback pump can claim its head.
    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "monitor-thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
        expectedCurrentTurnID _: String,
        acceptedDispatchTurnID _: String
    ) async -> Bool {
        true
    }

    func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: activeTurnID ?? "turn")
    }

    func pendingTurnFailure(turnID _: String?) async -> CodexNativeSessionController.TurnFailure? {
        nil
    }

    func acknowledgePendingTurnFailure(
        turnID _: String?,
        failure _: CodexNativeSessionController.TurnFailure
    ) async {}

    func shutdown() async {
        continuation.finish()
    }
}

actor MonitorStubCodexAuthRecovery: CodexManagedAuthRecovering {
    private(set) var didRefresh = false

    func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
        didRefresh = true
        return .recovered(account: nil)
    }

    func managedAccountSnapshot() async -> CodexManagedAccount? {
        nil
    }

    func startManagedChatgptLogin(
        openURL _: @MainActor @escaping @Sendable (URL) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        .failed(message: "unused")
    }

    func startManagedChatgptDeviceCodeLogin(
        presentDeviceCode _: @MainActor @escaping @Sendable (CodexManagedChatgptDeviceCode, Bool) -> Void
    ) async -> CodexManagedChatgptLoginResult {
        .failed(message: "unused")
    }

    func logoutManagedAccount() async -> CodexManagedAuthLogoutResult {
        .signedOut
    }
}
