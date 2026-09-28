import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionLinkLaneBoardTests: XCTestCase {
    private func candidate(tabID: UUID, isClosing: Bool = false) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: 1,
            workspaceID: UUID(),
            tabID: tabID,
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            isTopLevel: true,
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: isClosing,
            isMCPControlled: false,
            isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true,
            displayName: "Worker",
            providerDisplayName: "Codex CLI",
            locationLabel: nil
        )
    }

    private func snapshot(
        for session: AgentModeViewModel.TabSession,
        candidate: AgentSessionLinkEndpointCandidate,
        subagentCounts: (running: Int, finished: Int) = (0, 0)
    ) -> DomainAgentSessionObservationSnapshot {
        AgentModeViewModel.observationSnapshot(
            for: session,
            candidate: candidate,
            subagentCounts: subagentCounts
        )
    }

    func testRunOutcomeKeepsTerminalStatesDistinctWhileLinkStatusStaysIdle() {
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        let target = candidate(tabID: tabID)
        let states: [(AgentSessionRunState, DomainAgentSessionLaneBoard.RunOutcome)] = [
            (.idle, .none),
            (.running, .running),
            (.waitingForUser, .awaitingUser),
            (.completed, .completed),
            (.cancelled, .cancelled),
            (.failed, .failed)
        ]
        for (runState, outcome) in states {
            session.runState = runState
            let observed = snapshot(for: session, candidate: target)
            XCTAssertEqual(observed.board.runOutcome, outcome)
            if runState.isActive {
                XCTAssertNotEqual(observed.status, .idle)
            } else {
                XCTAssertEqual(observed.status, .idle)
            }
        }
    }

    func testFailureReasonUsesOnlyStampedTerminalClassification() {
        XCTAssertEqual(
            AgentModeViewModel.laneFailureReason(for: .failed, stamped: .timeout),
            .timeout
        )
        XCTAssertEqual(
            AgentModeViewModel.laneFailureReason(for: .failed, stamped: .processCrash),
            .processCrash
        )
        XCTAssertNil(AgentModeViewModel.laneFailureReason(for: .failed, stamped: nil))
        XCTAssertNil(AgentModeViewModel.laneFailureReason(for: .completed, stamped: .agentError))
        XCTAssertNil(AgentModeViewModel.laneFailureReason(for: .running, stamped: .agentError))
        XCTAssertEqual(AgentModeViewModel.laneFailureReason(for: .cancelled, stamped: nil), .cancelled)

        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.runState = .cancelled
        XCTAssertEqual(snapshot(for: session, candidate: candidate(tabID: tabID)).board.failureReason, .cancelled)
    }

    func testEveryNamedReadinessConditionProducesItsOwnBlocker() {
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        let target = candidate(tabID: tabID)
        let baseline = AgentModeViewModel.sendReadinessInputs(session: session, candidate: target, status: .idle)
        XCTAssertTrue(AgentModeViewModel.sendBlockers(baseline).isEmpty)

        typealias Inputs = AgentModeViewModel.SendReadinessInputs
        let cases: [(String, WritableKeyPath<Inputs, Bool>, Bool)] = [
            ("run_state_active", \.runStateIsActive, true),
            ("persisted_state_not_loaded", \.hasLoadedPersistedState, false),
            ("binding_transition_in_progress", \.bindingTransitionInProgress, true),
            ("terminal_commit_in_progress", \.terminalCommitInProgress, true),
            ("mcp_follow_up_run_pending", \.mcpFollowUpRunPending, true),
            ("composer_submission_in_flight", \.isComposerSubmissionInFlight, true),
            ("preparing_initial_worktree", \.isPreparingInitialWorktree, true),
            ("changing_execution_location", \.isChangingExecutionLocation, true),
            ("pending_instructions", \.hasPendingInstructions, true),
            ("pending_acp_steering_instructions", \.hasPendingACPSteeringInstructions, true),
            ("pending_claude_steering_instructions", \.hasPendingClaudeSteeringInstructions, true),
            ("pending_auto_wake", \.hasPendingAutoWake, true),
            ("candidate_closing", \.isCandidateClosing, true)
        ]
        for (expected, keyPath, blockedValue) in cases {
            var input = baseline
            input[keyPath: keyPath] = blockedValue
            XCTAssertEqual(AgentModeViewModel.sendBlockers(input).map(\.rawValue), [expected])
        }
        var nonIdle = baseline
        nonIdle.status = .awaitingUser
        XCTAssertEqual(AgentModeViewModel.sendBlockers(nonIdle).map(\.rawValue), ["status_not_idle"])
    }

    func testPublishedBlockersAndIdleForSendShareTheSameEvaluation() {
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        let target = candidate(tabID: tabID)

        let ready = snapshot(for: session, candidate: target)
        XCTAssertTrue(ready.idleForSend)
        XCTAssertTrue(ready.board.sendBlockers.isEmpty)
        XCTAssertEqual(ready.board.subagentRunning, 0)
        XCTAssertEqual(ready.board.subagentFinished, 0)

        session.pendingInstructions = ["queued"]
        let queued = snapshot(for: session, candidate: target, subagentCounts: (running: 1, finished: 2))
        XCTAssertFalse(queued.idleForSend)
        XCTAssertEqual(queued.board.sendBlockers, ["pending_instructions"])
        XCTAssertEqual(queued.board.subagentRunning, 1)
        XCTAssertEqual(queued.board.subagentFinished, 2)

        session.runState = .running
        let running = snapshot(for: session, candidate: target)
        XCTAssertFalse(running.idleForSend)
        XCTAssertEqual(
            running.board.sendBlockers,
            ["pending_instructions", "run_state_active", "status_not_idle"]
        )
    }
}
