import Foundation
import OSLog

/// Bounded, always-on attribution at the quiet-check-in and auto-wake owners.
/// Closed phases and numeric proof only; correlation IDs are process-salted before logging.
/// No payload text, durable identity, diagnostic history, or admission authority.
enum AgentSessionLinkAutoWakeDiagnostics {
    enum GatePredicate: String {
        case hasLoadedPersistedState, bindingTransitionInProgress, terminalCommitInProgress
        case mcpFollowUpRunPending, selfCompactBlocksNotificationWake, isComposerSubmissionInFlight
        case isPreparingInitialWorktree, isChangingExecutionLocation, pendingInstructions
        case pendingACPSteeringInstructions, pendingClaudeSteeringInstructions, isSettlingACPBackgroundCompaction
        case pendingAskUser, pendingUserInputRequest, pendingApproval, pendingPermissionsRequest
        case pendingMCPElicitationRequest, pendingApplyEditsReview, pendingWorktreeMergeReview
        case runStateIsActive, waitingForUserWithoutContinuation
    }

    enum SealOutcome: String {
        case quiet, unknownFacts, unqualified, terminalNotCompleted, successor, occurrence
        case invalidatedRange, unsupportedProvider, nonRoutineWake, sourceRangeOrReply
        case unsealedEnd, supersededUnsealedAttempt
    }

    enum PairingOutcome: String {
        case paired, missingChain, missingFrame, missingObservation, chainReplaced
        case endpointMismatch, scheduledFrameChanged, pairedFrameChanged, statusMismatch, observationMismatch
    }

    enum RoutineBasis: String {
        case statusEdge, ordinaryCoverage, manual
    }

    enum Event: Equatable {
        case seal(source: UUID, attempt: UUID, outcome: SealOutcome, facts: AgentRunQuietFacts?, occurrence: Bool)
        case pairing(observer: UUID, source: UUID, outcome: PairingOutcome, facts: AgentRunQuietFacts?)
        case admission(observer: UUID, source: UUID, wake: UUID, basis: RoutineBasis, facts: AgentRunQuietFacts?, cutoff: UInt64?, delivered: UInt64?)
        case cancellation(observer: UUID, wake: UUID, phase: AgentSessionLinkAutoWakeAttempt.Phase, reason: AgentSessionLinkAutoWakeCancellationReason)
    }

    #if DEBUG
        /// Task-scoped capture exercises the real emit sites without replacing the production logger.
        @TaskLocal static var testObserver: (@Sendable (Event) -> Void)?
    #endif

    private static let correlationSalt = UUID()

    /// Explicit salt stays random even when SWIFT_DETERMINISTIC_HASHING is enabled.
    private static func correlation(_ id: UUID) -> String {
        var hasher = Hasher()
        hasher.combine(correlationSalt)
        hasher.combine(id)
        return String(UInt(bitPattern: hasher.finalize()), radix: 16)
    }

    private static func number(_ value: UInt64?) -> String {
        value.map(String.init) ?? "unknown"
    }

    static func record(_ event: Event) {
        switch event {
        case let .seal(source, attempt, outcome, facts, occurrence):
            logger.notice("quiet_seal source=\(correlation(source), privacy: .public) attempt=\(correlation(attempt), privacy: .public) outcome=\(outcome.rawValue, privacy: .public) occurrence=\(occurrence, privacy: .public) settled=\(number(facts?.settledThrough), privacy: .public) ordinary=\(number(facts?.ordinaryThrough), privacy: .public)")
        case let .pairing(observer, source, outcome, facts):
            logger.notice("facts_pairing observer=\(correlation(observer), privacy: .public) source=\(correlation(source), privacy: .public) outcome=\(outcome.rawValue, privacy: .public) settled=\(number(facts?.settledThrough), privacy: .public) ordinary=\(number(facts?.ordinaryThrough), privacy: .public)")
        case let .admission(observer, source, wake, basis, facts, cutoff, delivered):
            logger.notice("rendered_basis observer=\(correlation(observer), privacy: .public) source=\(correlation(source), privacy: .public) wake=\(correlation(wake), privacy: .public) basis=\(basis.rawValue, privacy: .public) settled=\(number(facts?.settledThrough), privacy: .public) ordinary=\(number(facts?.ordinaryThrough), privacy: .public) cutoff=\(number(cutoff), privacy: .public) delivered=\(number(delivered), privacy: .public)")
        case let .cancellation(observer, wake, phase, reason):
            logger.notice("wake_cancelled observer=\(correlation(observer), privacy: .public) wake=\(correlation(wake), privacy: .public) phase=\(String(describing: phase), privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        }
        #if DEBUG
            testObserver?(event)
        #endif
    }

    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "AutoWake")

    static func routeRefused(predicate: GatePredicate, phase: AgentSessionLinkAutoWakeAttempt.Phase) {
        logger.notice("route_refused predicate=\(predicate.rawValue, privacy: .public) phase=\(String(describing: phase), privacy: .public)")
    }
}
