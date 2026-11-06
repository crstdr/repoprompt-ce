import Foundation
import OSLog

/// Low-volume, always-on route-refusal diagnostics, called by the auto-wake evaluator.
/// Uses a random in-memory oversight-value token, closed predicates and phases; no session IDs or content.
/// Missing release logs do not prove a reservation survives whole-state replacement or teardown.
enum AgentSessionLinkAutoWakeDiagnostics {
    struct ObserverCorrelationID {
        fileprivate let value = UUID()
    }

    enum GatePredicate: String {
        case hasLoadedPersistedState, bindingTransitionInProgress, terminalCommitInProgress
        case mcpFollowUpRunPending, selfCompactBlocksNotificationWake, isComposerSubmissionInFlight
        case isPreparingInitialWorktree, isChangingExecutionLocation, pendingInstructions
        case pendingACPSteeringInstructions, pendingClaudeSteeringInstructions, isSettlingACPBackgroundCompaction
        case pendingAskUser, pendingUserInputRequest, pendingApproval, pendingPermissionsRequest
        case pendingMCPElicitationRequest, pendingApplyEditsReview, pendingWorktreeMergeReview
        case runStateIsActive, waitingForUserWithoutContinuation
    }

    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "AutoWake")

    private static func phaseName(_ phase: AgentSessionLinkAutoWakeAttempt.Phase) -> String {
        switch phase {
        case .scheduled: "scheduled"
        case .awaitingSettlement: "awaitingSettlement"
        case .preparingDispatch: "preparingDispatch"
        case .cancelledBeforeDispatch: "cancelledBeforeDispatch"
        case .dispatching: "dispatching"
        }
    }

    static func routeRefused(observer: ObserverCorrelationID, predicate: GatePredicate, phase: AgentSessionLinkAutoWakeAttempt.Phase) {
        logger.notice("route_refused observer=\(observer.value.uuidString, privacy: .public) predicate=\(predicate.rawValue, privacy: .public) phase=\(phaseName(phase), privacy: .public)")
    }

    static func reservationChanged(observer: ObserverCorrelationID, from: AgentSessionLinkAutoWakeAttempt.Phase?, to: AgentSessionLinkAutoWakeAttempt.Phase?) {
        guard from != to else { return }
        let previous = from.map(phaseName) ?? "none"
        let next = to.map(phaseName) ?? "none"
        logger.notice("reservation_phase observer=\(observer.value.uuidString, privacy: .public) from=\(previous, privacy: .public) to=\(next, privacy: .public)")
    }
}
