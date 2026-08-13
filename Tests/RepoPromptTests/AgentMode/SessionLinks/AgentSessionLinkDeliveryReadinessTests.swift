import Foundation
@testable import RepoPromptApp
import XCTest

/// Truth table for the pure send-admission reducer.
///
/// `send` is the only oversight operation that mutates a target, so its blocker matrix is the
/// feature's security contract. Driving it as a value function is deliberate: proving the matrix by
/// steering a live `AgentModeViewModel` through every run/wait/interaction/queue/transition
/// combination would be untestable in practice, and a missed combination is a delivery into a busy
/// session.
final class AgentSessionLinkDeliveryReadinessTests: XCTestCase {
    private typealias Readiness = AgentSessionLinkDeliveryReadiness
    private typealias Snapshot = Readiness.Snapshot

    // MARK: - Ready shape

    func testFullyIdleHydratedExactlyBoundLocalOriginTargetIsReady() {
        XCTAssertEqual(Readiness.evaluate(snapshot: .ready), .ready)
    }

    // MARK: - Busy matrix

    func testEveryBusyBlockerIndividuallyPreventsDelivery() {
        let booleanBlockers: [(String, WritableKeyPath<Snapshot, Bool>)] = [
            ("runStateIsActive", \.runStateIsActive),
            ("terminalCommitInProgress", \.terminalCommitInProgress),
            ("mcpFollowUpRunPending", \.mcpFollowUpRunPending),
            ("isComposerSubmissionInFlight", \.isComposerSubmissionInFlight),
            ("isPreparingInitialWorktree", \.isPreparingInitialWorktree),
            ("isChangingExecutionLocation", \.isChangingExecutionLocation),
            ("hasWaitingPrompt", \.hasWaitingPrompt),
            ("hasPendingAskUser", \.hasPendingAskUser),
            ("hasPendingUserInputRequest", \.hasPendingUserInputRequest),
            ("hasPendingApproval", \.hasPendingApproval),
            ("hasPendingPermissionsRequest", \.hasPendingPermissionsRequest),
            ("hasPendingMCPElicitationRequest", \.hasPendingMCPElicitationRequest),
            ("hasPendingApplyEditsReview", \.hasPendingApplyEditsReview),
            ("hasPendingWorktreeMergeReview", \.hasPendingWorktreeMergeReview)
        ]
        for (name, keyPath) in booleanBlockers {
            var snapshot = Snapshot.ready
            snapshot[keyPath: keyPath] = true
            XCTAssertEqual(
                Readiness.evaluate(snapshot: snapshot),
                .blocked(.targetNotIdle),
                "\(name) must block delivery"
            )
        }

        let queueBlockers: [(String, WritableKeyPath<Snapshot, Int>)] = [
            ("pendingInstructionCount", \.pendingInstructionCount),
            ("pendingACPSteeringCount", \.pendingACPSteeringCount),
            ("pendingClaudeSteeringCount", \.pendingClaudeSteeringCount)
        ]
        for (name, keyPath) in queueBlockers {
            var snapshot = Snapshot.ready
            snapshot[keyPath: keyPath] = 1
            XCTAssertEqual(
                Readiness.evaluate(snapshot: snapshot),
                .blocked(.targetNotIdle),
                "\(name) must block delivery"
            )
        }
    }

    /// A pending review is a blocker even though neither review publisher is part of `runState`.
    /// These two were the easiest inputs to omit, and omitting them would let a send land while the
    /// user is mid-review.
    func testPendingReviewsBlockEvenWhenTheRunIsNotActive() {
        for keyPath in [\Snapshot.hasPendingApplyEditsReview, \Snapshot.hasPendingWorktreeMergeReview] {
            var snapshot = Snapshot.ready
            snapshot.runStateIsActive = false
            snapshot[keyPath: keyPath] = true
            XCTAssertEqual(Readiness.evaluate(snapshot: snapshot), .blocked(.targetNotIdle))
        }
    }

    // MARK: - Lifecycle precedence

    func testEndpointDriftOutranksEveryRetryableReason() {
        var snapshot = Snapshot.ready
        snapshot.endpointMatchesGrant = false
        snapshot.hasLoadedPersistedState = false
        snapshot.runStateIsActive = true
        XCTAssertEqual(
            Readiness.evaluate(snapshot: snapshot),
            .blocked(.endpointInvalidated),
            "A gone endpoint must never be reported as a retryable busy/loading state."
        )

        var closing = Snapshot.ready
        closing.isClosing = true
        XCTAssertEqual(Readiness.evaluate(snapshot: closing), .blocked(.endpointInvalidated))
    }

    func testHydrationAndRebindingAreRetryableRatherThanNotIdle() {
        var loading = Snapshot.ready
        loading.hasLoadedPersistedState = false
        XCTAssertEqual(Readiness.evaluate(snapshot: loading), .blocked(.targetLoading))

        var rebinding = Snapshot.ready
        rebinding.bindingTransitionInProgress = true
        XCTAssertEqual(Readiness.evaluate(snapshot: rebinding), .blocked(.targetLoading))
    }

    // MARK: - Mutual-link loop guard

    func testTurnStartedByAnIncomingCrossSessionMessageCannotSendOnward() {
        var snapshot = Snapshot.ready
        snapshot.observerTurnOrigin = .crossSessionMessage(sourceSessionID: UUID())
        XCTAssertEqual(
            Readiness.evaluate(snapshot: snapshot),
            .blocked(.crossSessionReplyRequiresUserInstruction)
        )
    }

    /// The loop guard is checked last so a caller that is *also* blocked by a busy target learns the
    /// retryable reason. Reporting the permanent reason first would tell it to give up on a send
    /// that a new local instruction plus an idle target would allow.
    func testBusyTargetOutranksTheLoopGuard() {
        var snapshot = Snapshot.ready
        snapshot.observerTurnOrigin = .crossSessionMessage(sourceSessionID: UUID())
        snapshot.runStateIsActive = true
        XCTAssertEqual(Readiness.evaluate(snapshot: snapshot), .blocked(.targetNotIdle))
    }

    func testLocalOriginReopensSendingAfterACrossSessionTurn() {
        var snapshot = Snapshot.ready
        snapshot.observerTurnOrigin = .crossSessionMessage(sourceSessionID: UUID())
        XCTAssertFalse(Readiness.evaluate(snapshot: snapshot).isReady)

        snapshot.observerTurnOrigin = .localUser
        XCTAssertTrue(Readiness.evaluate(snapshot: snapshot).isReady)
    }

    // MARK: - Failure vocabulary

    /// Terminal prior runs are idle. A completed/cancelled/failed run in a live session must stay
    /// sendable, which is exactly what makes oversight useful after a target finishes.
    func testTerminalPriorRunsRemainSendable() {
        var snapshot = Snapshot.ready
        snapshot.runStateIsActive = false
        snapshot.terminalCommitInProgress = false
        XCTAssertTrue(Readiness.evaluate(snapshot: snapshot).isReady)
    }

    func testBlockReasonsMapOntoStableWireFailures() {
        for reason in Readiness.BlockReason.allCases {
            let failure = AgentSessionLinkSendFailure(reason)
            XCTAssertEqual(failure.rawValue, reason.rawValue)
            XCTAssertFalse(failure.message.isEmpty)
        }
        XCTAssertTrue(AgentSessionLinkSendFailure.targetNotIdle.isRetryable)
        XCTAssertTrue(AgentSessionLinkSendFailure.targetLoading.isRetryable)
        XCTAssertTrue(AgentSessionLinkSendFailure.persistenceFailed.isRetryable)
        XCTAssertFalse(AgentSessionLinkSendFailure.linkRevoked.isRetryable)
        XCTAssertFalse(AgentSessionLinkSendFailure.endpointInvalidated.isRetryable)
        XCTAssertFalse(
            AgentSessionLinkSendFailure.crossSessionReplyRequiresUserInstruction.isRetryable
        )
    }
}
