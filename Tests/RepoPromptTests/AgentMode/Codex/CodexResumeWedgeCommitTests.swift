import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class CodexResumeWedgeCommitTests: XCTestCase {
    private static let oldThreadID = "old-committed-thread"
    private static let oldRolloutPath = "/tmp/old-committed-rollout.jsonl"
    private static let missingRolloutMessage =
        "failed to resolve rollout path /tmp/old-committed-rollout.jsonl: file does not exist"

    @MainActor
    private struct Fixture {
        let viewModel: AgentModeViewModel
        let workspaceManager: WorkspaceManagerViewModel
        let session: AgentTabSession
        let factory: WedgeControllerFactory

        var coordinator: CodexAgentModeCoordinator {
            viewModel.test_codexCoordinator
        }
    }

    private func makeFixture(
        _ plans: [[WedgeFakeCodexController.Response]],
        mcpServerEnabler: @escaping @MainActor @Sendable () async -> Bool = { true },
        routeOwnerValidator: @escaping CodexAgentModeCoordinator.CodexRouteOwnerValidator = { _, _, _, _ in true }
    ) -> Fixture {
        let factory = WedgeControllerFactory(plans: plans)
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.temporaryDirectory.path,
            shouldManageCodexTooling: true,
            codexControllerFactory: { runID, _, _, _, _, _ in factory.make(runID: runID) },
            mcpServerEnabler: mcpServerEnabler,
            testCodexLeaseRoutingTimeoutMs: 5000,
            testCodexRouteOwnerValidator: routeOwnerValidator
        )
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Codex resume wedge test"
        )
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .codexExec
        session.hasLoadedPersistedState = true
        session.codexConversationID = Self.oldThreadID
        session.codexRolloutPath = Self.oldRolloutPath
        session.providerCleanupHandle = ProviderConversationCleanupHandle(
            provider: AgentProviderKind.codexExec.rawValue,
            conversationID: Self.oldThreadID,
            rolloutPath: Self.oldRolloutPath
        )
        session.codexNeedsReconnect = true
        session.runState = .running
        session.beginRunAttempt(source: "codex-resume-wedge-test")
        return Fixture(
            viewModel: viewModel,
            workspaceManager: workspaceManager,
            session: session,
            factory: factory
        )
    }

    func testRequiredRepoPromptDiscoveryFailureIsVisibleAndTerminatesBeforeDispatch() async throws {
        for resuming in [false, true] {
            let fixture = makeFixture([[.discoveryFailure]])
            if !resuming {
                fixture.session.codexConversationID = nil
                fixture.session.codexRolloutPath = nil
                fixture.session.providerCleanupHandle = nil
            }
            var sendFinished = false
            let send = Task {
                let result = await fixture.coordinator.sendCodexNativeMessage(
                    session: fixture.session,
                    text: "continue",
                    attachments: []
                )
                sendFinished = true
                return result
            }
            defer { send.cancel() }
            try await AsyncTestWait.waitUntil("discovery failure terminates", timeout: 4) {
                sendFinished
            }
            guard case .failed = await send.value else {
                return XCTFail("Discovery failure must reject the send")
            }
            let errors = fixture.session.items.filter { $0.kind == .error }
            XCTAssertEqual(errors.count, 1)
            let message = try XCTUnwrap(errors.first).text
            XCTAssertTrue(message.contains("RepoPromptCE"))
            XCTAssertTrue(message.contains("required MCP servers failed to initialize"))
            XCTAssertTrue(message.contains("Tool catalog not ready. Please retry."))
            XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
            XCTAssertEqual(fixture.factory.controllers.count, 1)
            XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        }
    }

    func testColdCompactionAfterRouteRevocationInstallsPolicyBeforeDiscovery() async throws {
        let fixture = makeFixture([
            [.success(Self.oldThreadID)],
            [.policyRequiredResume],
            [.policyRequiredResume]
        ])
        addTeardownBlock { @MainActor in
            let runID = fixture.session.runID
            await fixture.coordinator.shutdownCodexSession(fixture.session)
            if let runID,
               let clientName = AgentProviderKind.codexExec.mcpClientNameHint
            {
                await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                    for: clientName,
                    windowID: 1,
                    runID: runID
                )
            }
        }
        let failedStart = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        addTeardownBlock {
            failedStart.cancel()
            await failedStart.value
        }
        try await waitForPendingStart(fixture)
        let revokedRunID = try XCTUnwrap(fixture.session.runID)
        await MCPRoutingWaiter.shared.notifyFailed(runID: revokedRunID)
        await failedStart.value
        let oldPolicyRemains = await hasPendingPolicy(for: revokedRunID)
        XCTAssertFalse(oldPolicyRemains)
        XCTAssertNil(fixture.session.codexController)
        assertOldTuple(fixture.session)

        fixture.session.runState = .idle
        let compact = Task {
            await fixture.coordinator.startOversightCompaction(
                session: fixture.session,
                expectedThreadID: Self.oldThreadID,
                isStillAdmissible: { true }
            )
        }
        addTeardownBlock {
            compact.cancel()
            _ = await compact.value
        }
        try await waitForPendingStart(fixture)
        let controller = try XCTUnwrap(fixture.factory.controllers.last)
        XCTAssertEqual(fixture.factory.controllers.count, 2)
        XCTAssertEqual(controller.receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(controller.startedTurnCount, 0)
        XCTAssertEqual(controller.compactCount, 0, "Compaction must wait for owned routing")
        XCTAssertEqual(fixture.session.runState, .idle, "Resume must not manufacture an active model turn")
        let compactRunID = try XCTUnwrap(fixture.session.runID)
        XCTAssertNotEqual(compactRunID, revokedRunID)
        await MCPRoutingWaiter.shared.notifyRouted(runID: compactRunID)
        let outcome = await compact.value
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(controller.compactCount, 1)
        XCTAssertEqual(controller.startedTurnCount, 0)
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })

        if let ownership = fixture.session.activeRunOwnership {
            _ = fixture.session.endRunAttempt(ifCurrent: ownership, source: "fake-compact-completed")
        }
        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "send-after-cold-compact")
        let send = Task {
            await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session, text: "continue", attachments: []
            )
        }
        addTeardownBlock {
            send.cancel()
            _ = await send.value
        }
        // Synthetic routing left no live app connection, so the ordinary send must rebind.
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.factory.controllers.count, 3)
        let sendController = try XCTUnwrap(fixture.factory.controllers.last)
        XCTAssertEqual(sendController.receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(sendController.startedTurnCount, 0)
        try await MCPRoutingWaiter.shared.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
        let sendOutcome = await send.value
        XCTAssertTrue(sendOutcome.didSend)
        XCTAssertEqual(sendController.startedTurnCount, 1)
        XCTAssertEqual(sendController.compactCount, 0)
        assertOldTuple(fixture.session)
    }

    /// Routing is synthetic; assert pending-policy cleanup rather than live socket admission.
    func testColdResumeFailureAfterRoutedCleansOnlyItsOwnedStartup() async throws {
        for superseded in [false, true] {
            let gate = TestReleaseFence(name: "routed compact resume failure")
            let fixture = makeFixture([[.routedThenResumeFailure(gate)]])
            fixture.session.runState = .idle
            addTeardownBlock { @MainActor in
                let runID = fixture.session.runID
                await fixture.coordinator.shutdownCodexSession(fixture.session)
                if let runID, let clientName = AgentProviderKind.codexExec.mcpClientNameHint {
                    await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                        for: clientName, windowID: 1, runID: runID
                    )
                    await MCPRoutingWaiter.shared.cleanup(runID: runID)
                }
            }
            let compact = Task {
                await fixture.coordinator.startOversightCompaction(
                    session: fixture.session,
                    expectedThreadID: Self.oldThreadID,
                    isStillAdmissible: { true }
                )
            }
            addTeardownBlock {
                compact.cancel()
                gate.release()
                _ = await compact.value
            }
            let entered = await gate.waitUntilEntered(timeout: 4)
            XCTAssertTrue(entered)
            let controller = try XCTUnwrap(fixture.factory.controllers.first)
            let runID = try XCTUnwrap(fixture.session.runID)
            let successor = WedgeFakeCodexController(runID: runID, responses: [])
            if superseded {
                fixture.session.beginRunAttempt(source: "compact-successor")
                fixture.session.codexController = successor
                try await ServerNetworkManager.shared.installClientConnectionPolicy(
                    for: XCTUnwrap(AgentProviderKind.codexExec.mcpClientNameHint),
                    windowID: 1, restrictedTools: [], tabID: fixture.session.tabID,
                    runID: runID, purpose: .agentModeRun, requiresExpectedAgentPID: true
                )
            }
            let attemptBeforeFailure = fixture.session.activeRunAttemptID
            let itemsBeforeFailure = fixture.session.items.count
            gate.release()
            let outcome = await compact.value
            try await AsyncTestWait.waitUntil("failed compact controller retired", timeout: 4) {
                controller.shutdownCount == 1
            }
            let pendingPolicyRemains = await hasPendingPolicy(for: runID)
            XCTAssertEqual(pendingPolicyRemains, superseded)
            if superseded {
                XCTAssertEqual(fixture.session.codexController.map(ObjectIdentifier.init), ObjectIdentifier(successor))
                XCTAssertEqual(successor.shutdownCount, 0)
                XCTAssertEqual(fixture.session.items.count, itemsBeforeFailure)
            } else {
                XCTAssertNil(fixture.session.codexController)
            }
            XCTAssertEqual(fixture.factory.controllers.count, 1)
            XCTAssertEqual(controller.receivedExistingIDs, [Self.oldThreadID])
            XCTAssertEqual(outcome, .notStarted)
            XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
            XCTAssertEqual(controller.startedTurnCount, 0)
            XCTAssertEqual(controller.compactCount, 0)
            XCTAssertEqual(fixture.session.runState, .idle)
            XCTAssertEqual(fixture.session.activeRunAttemptID, attemptBeforeFailure)
            assertOldTuple(fixture.session)
        }
    }

    func testAcquisitionFailureRetiresPreparedColdCompactController() async throws {
        let fixture = makeFixture([[]], mcpServerEnabler: { false })
        fixture.session.runState = .idle
        addTeardownBlock { @MainActor in
            await fixture.coordinator.shutdownCodexSession(fixture.session)
        }
        let outcome = await fixture.coordinator.startOversightCompaction(
            session: fixture.session, expectedThreadID: Self.oldThreadID, isStillAdmissible: { true }
        )
        let controller = try XCTUnwrap(fixture.factory.controllers.first)
        XCTAssertEqual(outcome, .notStarted)
        XCTAssertNil(fixture.session.codexController, "Failed provisioning must not strand the prepared idle controller")
        XCTAssertEqual(controller.shutdownCount, 1)
        XCTAssertEqual(controller.startedTurnCount, 0)
        XCTAssertEqual(controller.compactCount, 0)
        XCTAssertTrue(controller.receivedExistingIDs.isEmpty)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        assertOldTuple(fixture.session)
    }

    func testRoutingQualificationSupersessionPreservesSameRunPolicy() async throws {
        let gate = TestReleaseFence(name: "cold compact route-owner validation")
        let fixture = makeFixture([[.policyRequiredResume]], routeOwnerValidator: { _, _, _, _ in
            await gate.enterAndWait()
            return true
        })
        fixture.session.runState = .idle
        let compact = Task {
            await fixture.coordinator.startOversightCompaction(
                session: fixture.session, expectedThreadID: Self.oldThreadID, isStillAdmissible: { true }
            )
        }
        addTeardownBlock { @MainActor in
            compact.cancel()
            gate.release()
            _ = await compact.value
            let runID = fixture.session.runID
            await fixture.coordinator.shutdownCodexSession(fixture.session)
            if let runID, let clientName = AgentProviderKind.codexExec.mcpClientNameHint {
                await ServerNetworkManager.shared.revokeClientConnectionPolicy(for: clientName, windowID: 1, runID: runID)
                await MCPRoutingWaiter.shared.cleanup(runID: runID)
            }
        }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        let entered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        let original = try XCTUnwrap(fixture.factory.controllers.first)
        let successor = WedgeFakeCodexController(runID: runID, responses: [])
        fixture.session.beginRunAttempt(source: "cold compact route successor")
        fixture.session.codexController = successor
        try await ServerNetworkManager.shared.installClientConnectionPolicy(
            for: XCTUnwrap(AgentProviderKind.codexExec.mcpClientNameHint), windowID: 1,
            restrictedTools: [], tabID: fixture.session.tabID, runID: runID,
            purpose: .agentModeRun, requiresExpectedAgentPID: true
        )
        await MCPRoutingWaiter.shared.cleanup(runID: runID)
        await MCPRoutingWaiter.register(runID: runID)
        await MCPRoutingWaiter.notifyRouted(runID: runID)
        let successorAttempt = fixture.session.activeRunAttemptID
        let successorItems = fixture.session.items.count
        gate.release()
        let outcome = await compact.value
        let policyRemains = await hasPendingPolicy(for: runID)
        XCTAssertEqual(outcome, .notStarted)
        XCTAssertTrue(policyRemains, "A stale compact routing callback must not revoke the successor's policy")
        XCTAssertEqual(fixture.session.codexController.map(ObjectIdentifier.init), ObjectIdentifier(successor))
        XCTAssertEqual(successor.shutdownCount, 0)
        let routingOutcome = await MCPRoutingWaiter.currentTerminalOutcome(runID: runID)
        XCTAssertEqual(routingOutcome, .routed)
        XCTAssertEqual(fixture.session.activeRunAttemptID, successorAttempt)
        XCTAssertEqual(fixture.session.items.count, successorItems)
        try await AsyncTestWait.waitUntil("superseded controller retired", timeout: 4) { original.shutdownCount == 1 }
        XCTAssertEqual(original.compactCount, 0)
        XCTAssertEqual(original.startedTurnCount, 0)
        assertOldTuple(fixture.session)
    }

    private func waitForPendingStart(_ fixture: Fixture) async throws {
        try await AsyncTestWait.waitUntil("Codex start staged", timeout: 4) {
            fixture.coordinator.test_hasPendingCodexStart(for: fixture.session)
        }
    }

    private func assertOldTuple(_ session: AgentTabSession, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(session.codexConversationID, Self.oldThreadID, file: file, line: line)
        XCTAssertEqual(session.codexRolloutPath, Self.oldRolloutPath, file: file, line: line)
        XCTAssertEqual(session.providerCleanupHandle?.conversationID, Self.oldThreadID, file: file, line: line)
        XCTAssertEqual(session.providerCleanupHandle?.rolloutPath, Self.oldRolloutPath, file: file, line: line)
    }

    func testTwoResumeTimeoutsThenFreshRoutingFailureRetainsPersistedTupleAndLaterSend() async throws {
        let fixture = makeFixture([
            [.timeout],
            [.timeout],
            [.success("failed-fresh-thread")],
            [.success("later-fresh-thread")]
        ])
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 1)
        assertOldTuple(fixture.session)

        let second = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { second.cancel() }
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 2)
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
        let failedRunID = try XCTUnwrap(fixture.session.runID)
        await MCPRoutingWaiter.shared.notifyFailed(runID: failedRunID)
        await second.value

        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
        XCTAssertEqual(fixture.factory.controllers[2].startedTurnCount, 0)

        var saved: AgentSession?
        fixture.viewModel.test_setAgentSessionSaver { agentSession, _, _ in
            saved = agentSession
            return FileManager.default.temporaryDirectory.appendingPathComponent("codex-wedge-\(UUID().uuidString).json")
        }
        await fixture.viewModel.flushSave(for: fixture.session.tabID)
        XCTAssertEqual(saved?.codexConversationID, Self.oldThreadID)
        XCTAssertEqual(saved?.codexRolloutPath, Self.oldRolloutPath)
        XCTAssertEqual(saved?.providerCleanupHandle?.conversationID, Self.oldThreadID)

        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "codex-resume-wedge-later-send")
        let later = Task {
            await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session,
                text: "continue",
                attachments: []
            )
        }
        defer { later.cancel() }
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.factory.controllers[3].receivedExistingIDs, [nil])
        assertOldTuple(fixture.session)
        try await MCPRoutingWaiter.shared.notifyFailed(runID: XCTUnwrap(fixture.session.runID))
        _ = await later.value
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertEqual(fixture.factory.controllers[2].startedTurnCount, 0)
        XCTAssertEqual(fixture.factory.controllers[3].startedTurnCount, 0)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
    }

    func testRoutingSuccessCommitsFreshFallbackExactlyOnce() async throws {
        let fixture = makeFixture([[.missingRollout, .success("ready-fresh-thread")]])
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
        try await MCPRoutingWaiter.shared.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
        await startup.value

        XCTAssertEqual(fixture.session.codexConversationID, "ready-fresh-thread")
        XCTAssertNil(fixture.session.codexRolloutPath, "a pre-turn fresh thread may not have a rollout yet")
        XCTAssertEqual(fixture.session.providerCleanupHandle?.conversationID, "ready-fresh-thread")
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertEqual(fixture.session.codexResumeTimeoutState.consecutiveTimeouts, 0)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text.contains("Started a fresh thread") }), 1)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))

        fixture.session.runState = .idle
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID, nil])
        XCTAssertEqual(fixture.session.items.count(where: { $0.text.contains("Started a fresh thread") }), 1)
    }

    func testSecondCallerCannotBypassUnpublishedStartup() async throws {
        let gate = TestReleaseFence(name: "first Codex start response")
        let fixture = makeFixture([[.suspendedSuccess("claimed-thread", gate)]])
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer {
            gate.release()
            startup.cancel()
        }
        let entered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(entered)
        await fixture.coordinator.ensureCodexNativeSession(session: fixture.session)
        let secondSend = await fixture.coordinator.sendCodexNativeMessage(
            session: fixture.session,
            text: "duplicate",
            attachments: []
        )
        if case .preDispatchRejected = secondSend {} else {
            XCTFail("a second send must be rejected before turn dispatch")
        }
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        assertOldTuple(fixture.session)

        gate.release()
        try await waitForPendingStart(fixture)
        try await MCPRoutingWaiter.shared.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
        await startup.value
        XCTAssertEqual(fixture.session.codexConversationID, "claimed-thread")
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    func testCancellationAndSuccessorCannotPublishStagedThread() async throws {
        let cancelled = makeFixture([[.success("cancelled-fresh")]])
        let cancelledTask = Task { await cancelled.coordinator.ensureCodexNativeSession(session: cancelled.session) }
        try await waitForPendingStart(cancelled)
        cancelledTask.cancel()
        await cancelledTask.value
        assertOldTuple(cancelled.session)
        XCTAssertFalse(cancelled.coordinator.test_hasPendingCodexStart(for: cancelled.session))
        XCTAssertFalse(cancelled.session.items.contains { $0.text.contains("Started a fresh thread") })

        let successor = makeFixture([[.success("stale-fresh")]])
        let staleTask = Task { await successor.coordinator.ensureCodexNativeSession(session: successor.session) }
        defer { staleTask.cancel() }
        try await waitForPendingStart(successor)
        let staleRunID = try XCTUnwrap(successor.session.runID)
        successor.session.installRunID(UUID())
        await MCPRoutingWaiter.shared.notifyRouted(runID: staleRunID)
        await staleTask.value
        assertOldTuple(successor.session)
        XCTAssertFalse(successor.coordinator.test_hasPendingCodexStart(for: successor.session))
        XCTAssertFalse(successor.session.items.contains { $0.text.contains("Started a fresh thread") })
        XCTAssertEqual(successor.factory.controllers[0].startedTurnCount, 0)
    }

    func testInheritedRoutedOutcomeCannotCommitWithoutCurrentControllerRoute() async throws {
        let fixture = makeFixture(
            [[.success("unrouted-fresh-thread")]],
            routeOwnerValidator: { _, _, _, _ in false }
        )
        fixture.session.codexNativeStartupDisposition = .resumed
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        let policyWasInstalled = await hasPendingPolicy(for: runID)
        XCTAssertTrue(policyWasInstalled)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value

        assertOldTuple(fixture.session)
        let policyWasCleared = await hasPendingPolicy(for: runID)
        XCTAssertFalse(policyWasCleared)
        XCTAssertNil(fixture.session.codexNativeStartupDisposition)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertFalse(fixture.session.codexNeedsReconnect)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
    }

    func testCancellationDuringRouteOwnerCheckCleansPolicyAndUncommittedController() async throws {
        let gate = TestReleaseFence(name: "Codex route owner check")
        let fixture = makeFixture(
            [[.success("cancelled-owner-thread")]],
            routeOwnerValidator: { _, _, _, _ in
                await gate.enterAndWait()
                return true
            }
        )
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer {
            gate.release()
            startup.cancel()
        }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        let ownerCheckEntered = await gate.waitUntilEntered(timeout: 4)
        XCTAssertTrue(ownerCheckEntered)
        startup.cancel()
        gate.release()
        await startup.value

        assertOldTuple(fixture.session)
        let policyWasCleared = await hasPendingPolicy(for: runID)
        XCTAssertFalse(policyWasCleared)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    private func selfCompactOwner(
        for fixture: Fixture
    ) throws -> AgentSelfCompactOwner {
        let session = fixture.session
        if session.runID == nil { session.installRunID(UUID()) }
        _ = try XCTUnwrap(fixture.viewModel.test_ensureSessionBoundToTab(session))
        let binding = try XCTUnwrap(session.persistentSessionBindingIdentity)
        return try AgentSelfCompactOwner(
            windowID: 1,
            workspaceID: XCTUnwrap(fixture.workspaceManager.activeWorkspace?.id),
            tabID: session.tabID,
            sessionID: binding.sessionID,
            persistentBindingGeneration: binding.generation,
            bindingTransitionGeneration: session.bindingTransitionGeneration,
            runID: XCTUnwrap(session.runID),
            runAttemptID: XCTUnwrap(session.activeRunAttemptID)
        )
    }

    private func armSelfCompact(
        for fixture: Fixture,
        phase: AgentSelfCompactAttempt.Phase
    ) throws -> UUID {
        var state = AgentSelfCompactState()
        _ = try state.reserve(
            note: "continue on the original thread",
            idempotencyKey: "codex-wedge-self-compact",
            owner: selfCompactOwner(for: fixture)
        )
        state.active?.admittedSupport = .codex
        state.active?.phase = phase
        state.active?.compactProviderConversation = Self.oldThreadID
        fixture.session.selfCompactState = state
        return try XCTUnwrap(state.active?.id)
    }

    func testSelfCompactMissingRolloutDoesNotStartFreshThreadOrStrandAttempt() async throws {
        let fixture = makeFixture([[.missingRollout, .success("forbidden-fresh-thread")]])
        fixture.session.runState = .idle
        let requestID = try armSelfCompact(for: fixture, phase: .scheduled)
        let owner = try XCTUnwrap(fixture.session.selfCompactState.active?.owner)
        let scheduler = AgentSelfCompactTerminalScheduler(
            load: { fixture.session.selfCompactState },
            store: { fixture.session.selfCompactState = $0 },
            isCurrentOwner: { _ in true },
            hasActiveTools: { _ in false },
            support: { .codex },
            dispatch: { id, _, admissible in
                let result = await fixture.coordinator.startOversightCompaction(
                    session: fixture.session,
                    expectedThreadID: Self.oldThreadID,
                    selfCompactDispatchID: .init(requestID: id, stage: .compact),
                    isStillAdmissible: admissible
                )
                return result == .started
            }
        )
        scheduler.terminalSettled(
            runID: owner.runID,
            runAttemptID: owner.runAttemptID,
            terminalState: .completed,
            publication: .accepted(successorEpoch: nil),
            successorClaimed: false,
            teardownSettled: { true }
        )
        try await AsyncTestWait.waitUntil("self-compact resume failure settled", timeout: 4) {
            fixture.session.selfCompactState.latest?.requestID == requestID
        }
        XCTAssertNil(fixture.session.selfCompactState.active)
        XCTAssertEqual(fixture.session.selfCompactState.latest?.outcome, .failed)
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
    }

    func testContinuationNoteMissingRolloutParksWithoutFreshThreadFallback() async throws {
        let fixture = makeFixture([[.missingRollout, .success("forbidden-fresh-thread")]])
        fixture.session.runState = .idle
        let requestID = try armSelfCompact(for: fixture, phase: .dispatchingCompact)
        let owner = try XCTUnwrap(fixture.session.selfCompactState.active?.owner)
        fixture.session.selfCompactState.active?.compactTurnSucceeded = true
        let completion = AgentSelfCompactNativeCompletionCoordinator(
            load: { fixture.session.selfCompactState },
            store: { fixture.session.selfCompactState = $0 },
            isCurrentOwner: { _ in true },
            dispatchNote: { id, admissible in
                guard admissible() else { return false }
                fixture.session.selfCompactState.active?.phase = .dispatchingNote
                let outcome = await fixture.coordinator.sendCodexNativeMessage(
                    session: fixture.session,
                    text: AgentSelfCompactNoteEnvelope.frame("continue on the original thread"),
                    attachments: [],
                    selfCompactDispatchID: .init(requestID: id, stage: .note)
                )
                return outcome.didSend
            }
        )
        defer { completion.cancelRuntimeWork() }
        XCTAssertTrue(completion.bindCompact(
            .init(requestID: requestID, stage: .compact),
            runID: owner.runID,
            runAttemptID: owner.runAttemptID
        ))
        completion.compactTurnSettled(
            revision: AgentRunTerminalCommitRevision(
                commitID: UUID(),
                ownership: AgentRunOwnership(
                    attemptID: owner.runAttemptID,
                    binding: AgentRunBindingIdentity(tabID: owner.tabID, persistentSessionID: owner.sessionID)
                ),
                terminalState: .completed,
                failureReason: nil,
                expectedRunID: owner.runID,
                sourceItemsRevision: 0,
                assistantDeltaFlushGeneration: 0,
                providerDrainGeneration: 0,
                mcpPublicationEnvelope: nil,
                successorKind: nil,
                providerSuccessorID: nil
            ),
            publication: .accepted(successorEpoch: nil),
            teardownSettled: { true }
        )
        try await AsyncTestWait.waitUntil("continuation note parked after resume failure", timeout: 4) {
            fixture.session.selfCompactState.active?.phase == .parked
        }
        XCTAssertEqual(
            fixture.session.selfCompactState.parkedNote?.frame,
            AgentSelfCompactNoteEnvelope.frame("continue on the original thread")
        )
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        assertOldTuple(fixture.session)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
    }

    func testContinuationNoteWaitsForRoutedResumeThenStartsOnOriginalThread() async throws {
        let fixture = makeFixture([[.success(Self.oldThreadID)]])
        fixture.session.runState = .idle
        let requestID = try armSelfCompact(for: fixture, phase: .dispatchingNote)
        let note = AgentSelfCompactNoteEnvelope.frame("continue on the original thread")
        let send = Task {
            await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session,
                text: note,
                attachments: [],
                selfCompactDispatchID: .init(requestID: requestID, stage: .note)
            )
        }
        defer { send.cancel() }
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        assertOldTuple(fixture.session)
        try await MCPRoutingWaiter.shared.notifyRouted(runID: XCTUnwrap(fixture.session.runID))
        let outcome = await send.value
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(fixture.factory.controllers.count, 1)
        XCTAssertEqual(fixture.factory.controllers[0].receivedExistingIDs, [Self.oldThreadID])
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 1)
        XCTAssertEqual(fixture.session.selfCompactState.latest?.outcome, .noteAccepted)
        XCTAssertEqual(fixture.session.codexConversationID, Self.oldThreadID)
        XCTAssertFalse(fixture.session.items.contains { $0.text.contains("Started a fresh thread") })
    }

    private func hasPendingPolicy(for runID: UUID) async -> Bool {
        guard let clientName = AgentProviderKind.codexExec.mcpClientNameHint else { return false }
        let policies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: clientName)
        return policies.contains { $0.runID == runID }
    }

    func testAlreadyInstalledPolicyRecoveryStillStagesUntilRouting() async throws {
        let fixture = makeFixture([[.success("event-recovery-thread")]])
        let startup = Task {
            await fixture.coordinator.ensureCodexNativeSession(
                session: fixture.session,
                policyAlreadyInstalled: true,
                preserveExistingRunID: true
            )
        }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        assertOldTuple(fixture.session)
        try await MCPRoutingWaiter.shared.notifyFailed(runID: XCTUnwrap(fixture.session.runID))
        await startup.value
        assertOldTuple(fixture.session)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    func testSameRunAttemptDriftRetiresOnlyUncommittedControllerBeforeLaterSend() async throws {
        let fixture = makeFixture([
            [.success("drifted-fresh-thread")],
            [.success("later-fresh-thread")]
        ])
        fixture.session.appendItem(.system("Earlier Codex history", sequenceIndex: fixture.session.nextSequenceIndex))
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        fixture.session.beginRunAttempt(source: "same-run-successor")
        XCTAssertEqual(fixture.session.runID, runID)
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value

        assertOldTuple(fixture.session)
        XCTAssertNil(fixture.session.codexController)
        XCTAssertFalse(fixture.coordinator.test_hasPendingCodexStart(for: fixture.session))
        try await AsyncTestWait.waitUntil("uncommitted Codex controller retired", timeout: 4) {
            fixture.factory.controllers[0].shutdownCount == 1
        }
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)

        fixture.session.runState = .idle
        fixture.session.beginRunAttempt(source: "later-send")
        let later = Task {
            await fixture.coordinator.sendCodexNativeMessage(
                session: fixture.session,
                text: "continue",
                attachments: []
            )
        }
        defer { later.cancel() }
        try await waitForPendingStart(fixture)
        XCTAssertEqual(fixture.factory.controllers[1].receivedExistingIDs, [Self.oldThreadID])
        try await MCPRoutingWaiter.shared.notifyFailed(runID: XCTUnwrap(fixture.session.runID))
        _ = await later.value
        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
        XCTAssertEqual(fixture.factory.controllers[1].startedTurnCount, 0)
    }

    func testAttemptDriftDoesNotRetireSuccessorController() async throws {
        let fixture = makeFixture([[.success("stale-fresh-thread")]])
        let startup = Task { await fixture.coordinator.ensureCodexNativeSession(session: fixture.session) }
        defer { startup.cancel() }
        try await waitForPendingStart(fixture)
        let runID = try XCTUnwrap(fixture.session.runID)
        fixture.session.beginRunAttempt(source: "successor-controller")
        let successor = WedgeFakeCodexController(runID: runID, responses: [])
        fixture.session.codexController = successor
        await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
        await startup.value

        assertOldTuple(fixture.session)
        XCTAssertEqual(fixture.session.codexController.map(ObjectIdentifier.init), ObjectIdentifier(successor))
        XCTAssertEqual(successor.shutdownCount, 0)
        XCTAssertEqual(fixture.factory.controllers[0].startedTurnCount, 0)
    }

    func testResolveRolloutPathClassifierIsNarrow() {
        let ref = CodexNativeSessionController.SessionRef(
            conversationID: Self.oldThreadID,
            rolloutPath: Self.oldRolloutPath,
            model: nil,
            reasoningEffort: nil
        )
        let classifier: (CodexNativeSessionController.SessionRef?, String) -> Bool = { reference, message in
            CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
                existingRef: reference,
                errorDescription: message
            )
        }
        XCTAssertTrue(classifier(ref, Self.missingRolloutMessage))
        XCTAssertTrue(classifier(ref, "  FAILED TO RESOLVE ROLLOUT PATH /tmp/old-committed-rollout.jsonl: FILE DOES NOT EXIST.  "))
        XCTAssertFalse(classifier(ref, "failed to resolve rollout path /tmp/other-rollout.jsonl: file does not exist"))
        let mixedCaseRef = CodexNativeSessionController.SessionRef(
            conversationID: Self.oldThreadID,
            rolloutPath: "/tmp/CaseSensitive.jsonl",
            model: nil,
            reasoningEffort: nil
        )
        XCTAssertTrue(classifier(mixedCaseRef, "failed to resolve rollout path /tmp/CaseSensitive.jsonl: file does not exist"))
        XCTAssertFalse(classifier(mixedCaseRef, "failed to resolve rollout path /tmp/casesensitive.jsonl: file does not exist"))
        XCTAssertTrue(classifier(
            .init(conversationID: Self.oldThreadID, rolloutPath: nil, model: nil, reasoningEffort: nil),
            "failed to resolve rollout path /tmp/other-rollout.jsonl: file does not exist"
        ))
        XCTAssertTrue(classifier(ref, "no rollout found for thread id old-committed-thread"))
        XCTAssertFalse(classifier(nil, Self.missingRolloutMessage))
        XCTAssertFalse(classifier(ref, "failed to resolve workspace path /tmp/x: file does not exist"))
        XCTAssertFalse(classifier(ref, "failed to resolve rollout path /tmp/x: permission denied"))
        XCTAssertFalse(classifier(ref, "warning: failed to resolve rollout path /tmp/x: file does not exist"))
        XCTAssertFalse(classifier(ref, "failed to resolve rollout path /tmp/x: file does not exist; check permissions"))
        XCTAssertTrue(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "thread/resume",
            code: -32600,
            message: Self.missingRolloutMessage
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "thread/resume",
            code: -32600,
            message: "failed to resolve rollout path /tmp/other-rollout.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: mixedCaseRef,
            method: "thread/resume",
            code: -32600,
            message: "failed to resolve rollout path /tmp/casesensitive.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: mixedCaseRef,
            method: "config/read",
            code: -32600,
            message: "failed to resolve rollout path /tmp/CaseSensitive.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: mixedCaseRef,
            method: "config/read",
            code: -32600,
            message: "failed to resolve rollout path /tmp/casesensitive.jsonl: file does not exist"
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "config/read",
            code: -32600,
            message: Self.missingRolloutMessage
        ))
        XCTAssertFalse(CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
            existingRef: ref,
            method: "thread/resume",
            code: -32602,
            message: Self.missingRolloutMessage
        ))
    }
}

private final class WedgeControllerFactory {
    private var plans: [[WedgeFakeCodexController.Response]]
    private(set) var controllers: [WedgeFakeCodexController] = []

    init(plans: [[WedgeFakeCodexController.Response]]) {
        self.plans = plans
    }

    func make(runID: UUID) -> WedgeFakeCodexController {
        let controller = WedgeFakeCodexController(
            runID: runID,
            responses: plans.isEmpty ? [] : plans.removeFirst()
        )
        controllers.append(controller)
        return controller
    }
}

private final class WedgeFakeCodexController: CodexSessionControllerPassiveStubDefaults, @unchecked Sendable {
    enum Response {
        case timeout
        case discoveryFailure
        case policyRequiredResume
        case routedThenResumeFailure(TestReleaseFence)
        case missingRollout
        case suspendedSuccess(String, TestReleaseFence)
        case success(String)
    }

    let runID: UUID
    private let lock = NSLock()
    private var responses: [Response]
    private var existingIDs: [String?] = []
    private var active = false
    private var turnCount = 0
    private var compactions = 0
    private var shutdowns = 0
    private let continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation
    let events: AsyncStream<CodexNativeSessionController.Event>

    init(runID: UUID, responses: [Response]) {
        self.runID = runID
        self.responses = responses
        var storedContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation!
        events = AsyncStream { storedContinuation = $0 }
        continuation = storedContinuation
    }

    var hasActiveThread: Bool {
        lock.withLock { active }
    }

    var receivedExistingIDs: [String?] {
        lock.withLock { existingIDs }
    }

    var startedTurnCount: Int {
        lock.withLock { turnCount }
    }

    var compactCount: Int {
        lock.withLock { compactions }
    }

    var shutdownCount: Int {
        lock.withLock { shutdowns }
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        let response = lock.withLock { () -> Response? in
            existingIDs.append(existing?.conversationID)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        switch response {
        case .timeout:
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: nil,
                message: "Request timed out after 120.0s",
                data: nil
            ))
        case .discoveryFailure:
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: existing == nil ? "thread/start" : "thread/resume",
                code: -32603,
                message: "Failed to initialize session: required MCP servers failed to initialize: RepoPromptCE: Tool catalog not ready. Please retry.",
                data: nil
            ))
        case let .routedThenResumeFailure(gate):
            await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
            await gate.enterAndWait()
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: -32603,
                message: "Non-timeout resume failure after routing",
                data: nil
            ))
        case .policyRequiredResume:
            guard let clientName = AgentProviderKind.codexExec.mcpClientNameHint else {
                throw CodexAppServerClient.ClientError.invalidResponse
            }
            let policies = await ServerNetworkManager.shared.debugPendingPolicySnapshot(for: clientName)
            guard policies.contains(where: { $0.runID == runID && $0.purpose == .agentModeRun }),
                  let existing
            else { throw CodexAppServerClient.ClientError.invalidResponse }
            lock.withLock { active = true }
            return existing
        case .missingRollout:
            throw CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: -32600,
                message: "failed to resolve rollout path /tmp/old-committed-rollout.jsonl: file does not exist",
                data: nil
            ))
        case let .suspendedSuccess(threadID, gate):
            await gate.enterAndWait()
            lock.withLock { active = true }
            return CodexNativeSessionController.SessionRef(
                conversationID: threadID,
                rolloutPath: nil,
                model: model,
                reasoningEffort: reasoningEffort
            )
        case let .success(threadID):
            lock.withLock { active = true }
            return CodexNativeSessionController.SessionRef(
                conversationID: threadID,
                rolloutPath: nil,
                model: model,
                reasoningEffort: reasoningEffort
            )
        case nil:
            throw CodexAppServerClient.ClientError.invalidResponse
        }
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        let count = lock.withLock { () -> Int in
            turnCount += 1
            return turnCount
        }
        return CodexTurnStartReceipt(provisionalSubmissionID: "fake-turn-\(count)")
    }

    func compactThread() async throws {
        lock.withLock { compactions += 1 }
    }

    func shutdown() async {
        lock.withLock {
            active = false
            shutdowns += 1
        }
        continuation.finish()
    }
}
