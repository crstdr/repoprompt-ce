import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionLinkACPSteerTests: XCTestCase {
    private struct Fixture {
        let viewModel: AgentModeViewModel
        let manager: WorkspaceManagerViewModel
        let session: AgentModeViewModel.TabSession
        let candidate: AgentSessionLinkEndpointCandidate
        let controller: ACPAgentSessionController
        let provider: AgentSessionLinkCapturingACPProvider
        let directory: URL
    }

    private var fixtures: [Fixture] = []

    override func tearDown() async throws {
        for fixture in fixtures {
            await fixture.controller.shutdown()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func makeFixture(failPromptsContaining: String? = nil) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedACPSteer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = try AgentSessionLinkACPServerScript.write(to: directory)
        var environment: [String: String] = [:]
        if let failPromptsContaining {
            environment["ACP_FAIL_PROMPTS_CONTAINING"] = failPromptsContaining
        }
        let provider = AgentSessionLinkCapturingACPProvider(
            providerID: .openCode, commandPath: script.path, environment: environment
        )
        let request = ACPRunRequest(
            agentKind: .openCode, modelString: nil, workspacePath: directory.path,
            resumeSessionID: nil, attachments: [], taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        _ = try await controller.bootstrap()

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
            name: "ACP steer target", repoPaths: [], ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)], activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: directory.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { _, _, _ in
            directory.appendingPathComponent("\(UUID().uuidString).json")
        }
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .openCode
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        let candidate = try XCTUnwrap(viewModel.agentSessionLinkCandidate(
            tabID: tabID, sessionID: sessionID, tabName: "ACP steer target", isWindowClosing: false
        ))
        session.providerSessionID = "monitor-acp-session"
        session.acpController = controller
        session.runState = .running
        session.installRunID(UUID())
        _ = session.beginRunAttempt(source: "managed-acp-steer-test")
        let fixture = Fixture(
            viewModel: viewModel, manager: manager, session: session, candidate: candidate,
            controller: controller, provider: provider, directory: directory
        )
        fixtures.append(fixture)
        return fixture
    }

    private static let observer = DomainAgentSessionLinkEndpointIdentity(
        windowID: 2, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(),
        persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
    )

    private static let liveness = AgentSessionLinkSendLiveness(
        observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false
    )

    private func request(_ text: String) -> AgentSessionLinkSendRequest {
        AgentSessionLinkSendRequest(
            linkID: UUID(), linkGeneration: 1, observerEndpoint: Self.observer,
            observerDisplayName: "Overseer", message: text, workflow: nil
        )
    }

    private func steer(_ fixture: Fixture, request: AgentSessionLinkSendRequest) async
        -> AgentSessionLinkSendTransactionOutcome
    {
        await fixture.viewModel.agentSessionLinkPerformSteer(
            to: fixture.candidate, request: request,
            liveness: { Self.liveness }, commitAuthorization: { .committed }
        )
    }

    func testRunningACPManagedSteerDeliversFramedPrompt() async throws {
        let fixture = try await makeFixture()
        let message = request("Keep the parser fix & skip the rest.")
        let outcome = await steer(fixture, request: message)
        guard case let .delivered(delivery) = outcome else { return XCTFail("Expected delivery: \(outcome)") }
        XCTAssertEqual(delivery.deliveryState, .steered)
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: message.observerSessionID, sourceName: message.observerDisplayName,
            linkID: message.linkID, linkGeneration: message.linkGeneration,
            message: message.message, framing: .management
        )
        XCTAssertTrue(fixture.provider.promptedMessages.last?.userMessage.contains(envelope) == true)
        let row = try XCTUnwrap(fixture.session.items.first(where: { $0.id == delivery.targetItemID }))
        XCTAssertEqual(row.text, message.message)
        XCTAssertEqual(row.dispatchedProviderText, envelope)
        XCTAssertEqual(row.crossSessionAttribution, message.attribution)
    }

    func testRefusedACPFlushQueuesExactEnvelopeAndSettles() async throws {
        let fixture = try await makeFixture(failPromptsContaining: "REFUSE_THIS_STEER")
        let message = request("REFUSE_THIS_STEER")
        let outcome = await steer(fixture, request: message)
        guard case let .delivered(delivery) = outcome else { return XCTFail("Expected queued follow-up: \(outcome)") }
        XCTAssertEqual(delivery.deliveryState, .queuedFollowUp)
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: message.observerSessionID, sourceName: message.observerDisplayName,
            linkID: message.linkID, linkGeneration: message.linkGeneration,
            message: message.message, framing: .management
        )
        XCTAssertEqual(fixture.session.pendingInstructions.first, envelope)
    }

    func testMixedLocalAndManagedBatchSettlesManagedOnly() async throws {
        let fixture = try await makeFixture()
        let local = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: "local direction", interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "local direction",
            optimisticUserItemID: nil, createdAt: Date()
        )
        fixture.session.pendingACPSteeringInstructions.append(local)
        let outcome = await steer(fixture, request: request("managed direction"))
        guard case let .delivered(delivery) = outcome else { return XCTFail("Expected delivery: \(outcome)") }
        XCTAssertEqual(delivery.deliveryState, .steered)
        let sent = try XCTUnwrap(fixture.provider.promptedMessages.last?.userMessage)
        XCTAssertTrue(sent.contains("local direction"))
        XCTAssertTrue(sent.contains("managed direction"))
        XCTAssertTrue(fixture.session.pendingACPSteeringInstructions.isEmpty)
    }

    func testStaleRunRequeuesManagedSteerExactlyOnce() async throws {
        let fixture = try await makeFixture()
        let message = request("direction for the original run")
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: message.observerSessionID, sourceName: message.observerDisplayName,
            linkID: message.linkID, linkGeneration: message.linkGeneration,
            message: message.message, framing: .management
        )
        let sink = AgentSessionLinkManagedSteerSink()
        XCTAssertTrue(fixture.viewModel.submitAgentSessionLinkManagedSteer(
            tabID: fixture.session.tabID,
            session: fixture.session,
            displayText: message.message,
            turn: AgentSessionLinkManagedTurn(
                candidate: fixture.candidate, providerText: envelope,
                attribution: message.attribution, sink: sink
            ),
            route: .acpQueued
        ))
        fixture.session.installRunID(UUID())
        let settled = await sink.awaitOutcome(timeoutSeconds: 2)
        XCTAssertEqual(settled, .delivered(.queuedFollowUp))
        sink.resolve(.notAccepted(message: "late duplicate"))
        XCTAssertEqual(sink.outcome, .delivered(.queuedFollowUp))
        XCTAssertEqual(fixture.session.pendingInstructions.first, envelope)
    }

    func testCancelWipesManagedQueueWithoutRestoringItsDraft() async throws {
        let fixture = try await makeFixture()
        let message = request("managed queue entry")
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: message.observerSessionID, sourceName: message.observerDisplayName,
            linkID: message.linkID, linkGeneration: message.linkGeneration,
            message: message.message, framing: .management
        )
        let row = AgentChatItem.user(
            message.message, sequenceIndex: fixture.session.nextSequenceIndex,
            crossSessionAttribution: message.attribution, dispatchedProviderText: envelope
        )
        fixture.session.appendItem(row)
        let sink = AgentSessionLinkManagedSteerSink()
        sink.noteAppended(itemID: row.id)
        fixture.session.pendingACPSteeringInstructions.append(.init(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: envelope, interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "",
            optimisticUserItemID: row.id, createdAt: Date(),
            managed: .init(
                sink: sink, attributedItemID: row.id,
                candidate: fixture.candidate, attribution: message.attribution
            )
        ))
        await fixture.viewModel.cancelAgentRun(tabID: fixture.session.tabID)
        guard case .notAccepted = sink.outcome else { return XCTFail("Queue wipe left a managed sink pending") }
        XCTAssertFalse(fixture.session.items.contains(where: { $0.id == row.id }))
        XCTAssertTrue(fixture.session.pendingACPSteeringInstructions.isEmpty)
    }

    func testInterruptedAttributedReplayUsesExactStoredProviderBytes() async throws {
        let fixture = try await makeFixture()
        let attribution = request("x").attribution
        let exact = "  <cross_session_message delegation=\"user_delegated_management\">\n\u{00E9}&amp;\n</cross_session_message>  "
        let prior = AgentChatItem.user(
            "raw overseer words", sequenceIndex: fixture.session.nextSequenceIndex,
            crossSessionAttribution: attribution, dispatchedProviderText: exact
        )
        fixture.session.appendItem(prior)
        let next = AgentChatItem.user("new steer", sequenceIndex: fixture.session.nextSequenceIndex)
        XCTAssertEqual(
            fixture.viewModel.interruptedACPProviderText(for: fixture.session, before: next), exact
        )
        let restored = AgentChatItemPersist(from: prior).toItem()
        XCTAssertEqual(restored.dispatchedProviderText, exact)
    }

    func testLegacyAttributedReplayDropsAndLocalReplayRemains() async throws {
        let fixture = try await makeFixture()
        let attribution = request("x").attribution
        fixture.session.appendItem(.user(
            "legacy overseer words", sequenceIndex: fixture.session.nextSequenceIndex,
            crossSessionAttribution: attribution
        ))
        let next = AgentChatItem.user("new steer", sequenceIndex: fixture.session.nextSequenceIndex)
        XCTAssertNil(fixture.viewModel.interruptedACPProviderText(for: fixture.session, before: next))
        fixture.session.appendItem(.user("local message", sequenceIndex: fixture.session.nextSequenceIndex))
        let afterLocal = AgentChatItem.user("another steer", sequenceIndex: fixture.session.nextSequenceIndex)
        XCTAssertNotNil(fixture.viewModel.interruptedACPProviderText(for: fixture.session, before: afterLocal))
    }

    func testCompactionSettleWindowBlocksManagedSteerButNotLocalRunState() async throws {
        let fixture = try await makeFixture()
        let now = Date()
        fixture.session.beginACPCompactSettling(
            providerSessionID: "monitor-acp-session", controller: fixture.controller,
            now: now, settleSeconds: 90, scheduleDeadline: false
        )
        XCTAssertTrue(fixture.session.isACPCompactSettling(now: now.addingTimeInterval(89)))
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkSteerAdmission(for: fixture.session, liveness: Self.liveness),
            .blocked(.compactionSettling)
        )
        XCTAssertEqual(fixture.session.runState, .running, "Only managed admission is gated")
        XCTAssertFalse(fixture.session.isACPCompactSettling(now: now.addingTimeInterval(90)))
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkSteerAdmission(for: fixture.session, liveness: Self.liveness),
            .steer(.acpQueued)
        )
    }

    func testLocalSteerRemainsUngatedDuringCompactSettling() async throws {
        let fixture = try await makeFixture()
        fixture.session.beginACPCompactSettling(
            providerSessionID: "monitor-acp-session", controller: fixture.controller,
            settleSeconds: 90, scheduleDeadline: false
        )
        guard case .submitted = fixture.viewModel.submitUserTurn(text: "local user direction") else {
            return XCTFail("The lane user's own steer must not be blocked by managed settling")
        }
        XCTAssertTrue(fixture.session.items.contains(where: {
            $0.kind == .user && $0.text == "local user direction"
        }))
    }

    func testLocalSendRemainsUngatedDuringCompactSettling() async throws {
        let fixture = try await makeFixture()
        fixture.session.runState = .idle
        fixture.session.beginACPCompactSettling(
            providerSessionID: "monitor-acp-session", controller: fixture.controller,
            settleSeconds: 90, scheduleDeadline: false
        )
        guard case .submitted = fixture.viewModel.submitUserTurn(text: "local user follow-up") else {
            return XCTFail("The lane user's own send must not be blocked by managed settling")
        }
        XCTAssertTrue(fixture.session.items.contains(where: {
            $0.kind == .user && $0.text == "local user follow-up"
        }))
        await fixture.viewModel.cancelAgentRun(tabID: fixture.session.tabID)
    }

    func testValidOccupancyVouchAndIdentityChangeClearSettling() async throws {
        let fixture = try await makeFixture()
        fixture.session.contextUsageSnapshot = ContextUsageSnapshot(
            used: 40, window: 100, confidence: .exact,
            source: .acpUsageEvent, compactedAt: nil
        )
        fixture.session.beginACPCompactSettling(
            providerSessionID: "monitor-acp-session", controller: fixture.controller,
            settleSeconds: 90, scheduleDeadline: false
        )
        fixture.session.noteLiveContextUsageReport(
            contextUsedTokens: 40, promptTokens: nil, modelContextWindow: 100
        )
        XCTAssertTrue(fixture.session.isACPCompactSettling(), "An unchanged occupancy does not prove compaction")
        fixture.session.contextUsageSnapshot = ContextUsageSnapshot(
            used: 25, window: 100, confidence: .exact,
            source: .acpUsageEvent, compactedAt: nil
        )
        fixture.session.noteLiveContextUsageReport(
            contextUsedTokens: 25, promptTokens: nil, modelContextWindow: 100
        )
        XCTAssertFalse(fixture.session.isACPCompactSettling())
        fixture.session.beginACPCompactSettling(
            providerSessionID: "monitor-acp-session", controller: fixture.controller,
            settleSeconds: 90, scheduleDeadline: false
        )
        fixture.session.providerSessionID = "new-provider-session"
        XCTAssertFalse(fixture.session.isACPCompactSettling())
    }

    func testExistingRoutesAndUnavailableStateStayUnchanged() async throws {
        let fixture = try await makeFixture()
        XCTAssertEqual(fixture.viewModel.agentSessionLinkManagedSteerRoute(for: fixture.session), .acpQueued)
        fixture.session.acpController = nil
        XCTAssertNil(fixture.viewModel.agentSessionLinkManagedSteerRoute(for: fixture.session))
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkSteerAdmission(for: fixture.session, liveness: Self.liveness),
            .blocked(.steerUnavailable)
        )
        fixture.session.selectedAgent = .claudeCode
        XCTAssertEqual(fixture.viewModel.agentSessionLinkManagedSteerRoute(for: fixture.session), .claudeInterrupt)
        fixture.session.selectedAgent = .codexExec
        XCTAssertEqual(fixture.viewModel.agentSessionLinkManagedSteerRoute(for: fixture.session), .codex)
    }
}
