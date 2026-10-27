import CryptoKit
import Foundation
import OSLog

/// Low-volume, always-on decision diagnostics for self-compaction settlement.
/// Accepts only closed enums, booleans, and hashed identifiers: no note text, prompts,
/// provider text, error strings, paths, or project names. Emitted only for an active or
/// correlated self-compact request, never per poll.
enum AgentSelfCompactDiagnostics {
    enum Event: String, Equatable {
        case settle = "selfcompact-settle"
        case compactAttempt = "selfcompact-compact-attempt"
        case runCancel = "selfcompact-run-cancel"
    }

    // MARK: - Settle vocabularies

    enum SettleOutcome: String, Equatable {
        case cancelled
        case failed
        case completionUnverified = "completion_unverified"
        case compactDispatched = "compact_dispatched"
    }

    /// One value per scheduler settle branch.
    enum SettleCause: String, Equatable {
        case publicationStale = "publication_stale"
        case successorEpochCommitted = "successor_epoch_committed"
        case successorClaimed = "successor_claimed"
        case originNotCompleted = "origin_not_completed"
        case ownerLost = "owner_lost"
        case rejectedPublicationTimeout = "rejected_publication_timeout"
        case drainTimeout = "drain_timeout"
        case supportChanged = "support_changed"
        case dispatchNotStarted = "dispatch_not_started"
        case compactDispatchStarted = "compact_dispatch_started"
        case acceptedLocalInput = "accepted_local_input"
    }

    enum PublicationKind: String, Equatable {
        case accepted
        case acceptedSuccessorEpoch = "accepted_successor_epoch"
        case stale
        case rejected
    }

    /// Bounded map of the store/publisher rejection strings; free text never reaches the log.
    enum PublicationRejection: String, Equatable {
        case viewModelDeallocated = "view_model_deallocated"
        case missingTerminalPublicationEnvelope = "missing_terminal_publication_envelope"
        case activationReplaced = "activation_replaced"
        case missingSuccessorEpoch = "missing_successor_epoch"
        case sessionOrActivationMismatch = "session_or_activation_mismatch"
        case staleActivation = "stale_activation"
        case unknownEpoch = "unknown_epoch"
        case differentCommitAlreadyPublished = "different_commit_already_published"
        case other

        init(rawReason: String) {
            self = Self(rawValue: rawReason) ?? .other
        }
    }

    /// Every refusal branch of the native compact dispatch path.
    enum CompactDispatchBlocker: Equatable {
        case ownerMissing
        case stillAdmissibleLost
        case submitTargetUnavailable
        case targetRouteMismatch
        case targetSessionMismatch
        case composerClaimRefused
        case composerClaimLost
        case queuedProviderWork
        case workspaceMismatch
        case viewModelDeallocated
        case readiness(AgentSessionLinkDeliveryReadiness.BlockReason)
        case readinessRecheck(AgentSessionLinkDeliveryReadiness.BlockReason)
        case saveFailed
        case nativeNotStarted
        case nativeStartFailed
        case unknown

        var rawValue: String {
            switch self {
            case .ownerMissing: "owner_missing"
            case .stillAdmissibleLost: "still_admissible_lost"
            case .submitTargetUnavailable: "submit_target_unavailable"
            case .targetRouteMismatch: "target_route_mismatch"
            case .targetSessionMismatch: "target_session_mismatch"
            case .composerClaimRefused: "composer_claim_refused"
            case .composerClaimLost: "composer_claim_lost"
            case .queuedProviderWork: "queued_provider_work"
            case .workspaceMismatch: "workspace_mismatch"
            case .viewModelDeallocated: "view_model_deallocated"
            case let .readiness(reason): "readiness_\(reason.rawValue)"
            case let .readinessRecheck(reason): "readiness_recheck_\(reason.rawValue)"
            case .saveFailed: "save_failed"
            case .nativeNotStarted: "native_not_started"
            case .nativeStartFailed: "native_start_failed"
            case .unknown: "unknown"
            }
        }
    }

    /// Result the scheduler's dispatch closure returns; refusal carries the named blocker.
    enum CompactDispatchOutcome: Equatable {
        case started
        case refused(CompactDispatchBlocker)

        var didStart: Bool {
            self == .started
        }

        var blocker: CompactDispatchBlocker? {
            guard case let .refused(blocker) = self else { return nil }
            return blocker
        }
    }

    struct SettleDetails: Equatable {
        var publication: PublicationKind?
        var publicationRejection: PublicationRejection?
        var blocker: CompactDispatchBlocker?
        var supportNow: AgentSessionLinkCompactSupport?
        var toolsActive: Bool?
        var teardownPending: Bool?
        var didStart: Bool?
    }

    // MARK: - Compact attempt vocabularies

    enum CompactAttemptPhase: String, Equatable {
        case bound
        case bootstrapFailed = "bootstrap_failed"
    }

    /// The exact `Lease.acquire` bailout is not reachable without new state; what the
    /// runner can read synchronously is the task's own cancellation flag.
    enum AcquireBailout: String, Equatable {
        case taskCancelled = "task_cancelled"
        case unknown
    }

    // MARK: - Run cancellation vocabularies

    /// One value per `cancelRun` call site.
    enum RunCancelCaller: String, Equatable {
        case executionLocationChange = "execution_location_change"
        case provisionalTargetDetach = "provisional_target_detach"
        case controlContextShutdown = "control_context_shutdown"
        case composeTabTeardown = "compose_tab_teardown"
        case localStop = "local_stop"
        case managedSessionLinkStop = "managed_session_link_stop"
        case renderTargetStop = "render_target_stop"
        case instructionWaitTimeout = "instruction_wait_timeout"
        case unspecified
    }

    enum RunCancelAction: String, Equatable {
        case admissionRefused = "admission_refused"
        case terminalReturn = "terminal_return"
        case cancelActiveTask = "cancel_active_task"
    }

    enum RunCancelOrigin: String, Equatable {
        case explicitStop = "explicit_stop"
        case internalLifecycle = "internal_lifecycle"
    }

    // MARK: - Record

    struct Record: Equatable {
        let event: Event
        var request: String = "nil"
        var tab: String = "nil"
        var run: String = "nil"
        var originAttempt: String?
        var compactAttempt: String?
        var phase: String?
        var outcome: String?
        var cause: String?
        var blocker: String?
        var publication: String?
        var publicationReason: String?
        var support: String?
        var supportNow: String?
        var toolsActive: Bool?
        var teardownPending: Bool?
        var didStart: Bool?
        var bailout: String?
        var attemptCurrent: Bool?
        var caller: String?
        var intent: String?
        var origin: String?
        var action: String?
        var capturedAttempt: String?
        var currentAttempt: String?
        var taskPresent: Bool?
        var taskIsCancelled: Bool?

        var renderedLine: String {
            var fields = [
                "event=\(event.rawValue)",
                "request=\(request)",
                "tab=\(tab)",
                "run=\(run)"
            ]
            if let originAttempt { fields.append("origin_attempt=\(originAttempt)") }
            if let compactAttempt { fields.append("compact_attempt=\(compactAttempt)") }
            if let phase { fields.append("phase=\(phase)") }
            if let outcome { fields.append("outcome=\(outcome)") }
            if let cause { fields.append("cause=\(cause)") }
            if let blocker { fields.append("blocker=\(blocker)") }
            if let publication { fields.append("publication=\(publication)") }
            if let publicationReason { fields.append("publication_reason=\(publicationReason)") }
            if let support { fields.append("support=\(support)") }
            if let supportNow { fields.append("support_now=\(supportNow)") }
            if let toolsActive { fields.append("tools_active=\(toolsActive)") }
            if let teardownPending { fields.append("teardown_pending=\(teardownPending)") }
            if let didStart { fields.append("did_start=\(didStart)") }
            if let bailout { fields.append("bailout=\(bailout)") }
            if let attemptCurrent { fields.append("attempt_current=\(attemptCurrent)") }
            if let caller { fields.append("caller=\(caller)") }
            if let intent { fields.append("intent=\(intent)") }
            if let origin { fields.append("origin=\(origin)") }
            if let action { fields.append("action=\(action)") }
            if let capturedAttempt { fields.append("captured_attempt=\(capturedAttempt)") }
            if let currentAttempt { fields.append("current_attempt=\(currentAttempt)") }
            if let taskPresent { fields.append("task_present=\(taskPresent)") }
            if let taskIsCancelled { fields.append("task_is_cancelled=\(taskIsCancelled)") }
            return fields.joined(separator: " ")
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoPrompt",
        category: "AgentSelfCompact"
    )

    /// One bounded record at a settle decision; never input to the decision.
    static func settle(
        attempt: AgentSelfCompactAttempt,
        outcome: SettleOutcome,
        cause: SettleCause,
        details: SettleDetails = SettleDetails()
    ) {
        let record = Record(
            event: .settle,
            request: hashedID(attempt.id),
            tab: hashedID(attempt.owner?.tabID),
            run: hashedID(attempt.owner?.runID),
            originAttempt: hashedID(attempt.owner?.runAttemptID),
            compactAttempt: hashedID(attempt.compactRunAttemptID),
            phase: attempt.phase.rawValue,
            outcome: outcome.rawValue,
            cause: cause.rawValue,
            blocker: details.blocker?.rawValue,
            publication: details.publication?.rawValue,
            publicationReason: details.publicationRejection?.rawValue,
            support: attempt.admittedSupport.map(supportName),
            supportNow: details.supportNow.map(supportName),
            toolsActive: details.toolsActive,
            teardownPending: details.teardownPending,
            didStart: details.didStart
        )
        emit(record)
    }

    /// Emitted once after the compact attempt binds, and once if its bootstrap fails.
    static func compactAttempt(
        attempt: AgentSelfCompactAttempt?,
        requestID: UUID,
        runID: UUID,
        compactAttemptID: UUID,
        phase: CompactAttemptPhase,
        bailout: AcquireBailout?,
        taskIsCancelled: Bool,
        attemptCurrent: Bool?
    ) {
        let record = Record(
            event: .compactAttempt,
            request: hashedID(requestID),
            tab: hashedID(attempt?.owner?.tabID),
            run: hashedID(runID),
            originAttempt: hashedID(attempt?.owner?.runAttemptID),
            compactAttempt: hashedID(compactAttemptID),
            phase: phase.rawValue,
            bailout: bailout?.rawValue,
            attemptCurrent: attemptCurrent,
            taskIsCancelled: taskIsCancelled
        )
        emit(record)
    }

    /// Emitted at most once per `cancelRun` call while a self-compact request is active.
    static func runCancel(
        attempt: AgentSelfCompactAttempt,
        caller: RunCancelCaller,
        intent: String,
        origin: RunCancelOrigin,
        action: RunCancelAction,
        capturedAttempt: UUID?,
        currentAttempt: UUID?,
        taskPresent: Bool,
        taskIsCancelled: Bool
    ) {
        let record = Record(
            event: .runCancel,
            request: hashedID(attempt.id),
            tab: hashedID(attempt.owner?.tabID),
            run: hashedID(attempt.owner?.runID),
            originAttempt: hashedID(attempt.owner?.runAttemptID),
            compactAttempt: hashedID(attempt.compactRunAttemptID),
            phase: attempt.phase.rawValue,
            caller: caller.rawValue,
            intent: intent,
            origin: origin.rawValue,
            action: action.rawValue,
            capturedAttempt: capturedAttempt.map(hashedID(_:)),
            currentAttempt: currentAttempt.map(hashedID(_:)),
            taskPresent: taskPresent,
            taskIsCancelled: taskIsCancelled
        )
        emit(record)
    }

    private static func supportName(_ support: AgentSessionLinkCompactSupport) -> String {
        switch support {
        case .codex: "codex"
        case .claudeCode: "claude_code"
        case .acpAdvertisedCommand: "acp_advertised_command"
        case .notSupported: "not_supported"
        case .noProviderSession: "no_provider_session"
        }
    }

    private static func emit(_ record: Record) {
        logger.notice("\(record.renderedLine, privacy: .public)")
        #if DEBUG
            testCapture.append(record)
        #endif
    }

    private static func hashedID(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        let digest = SHA256.hash(data: Data(id.uuidString.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func hashedID(_ id: UUID) -> String {
        hashedID(Optional(id))
    }

    #if DEBUG
        private final class TestCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var isCapturing = false
            private var records: [Record] = []

            func begin() {
                lock.lock()
                records.removeAll(keepingCapacity: true)
                isCapturing = true
                lock.unlock()
            }

            func append(_ record: Record) {
                lock.lock()
                if isCapturing {
                    records.append(record)
                }
                lock.unlock()
            }

            func end() -> [Record] {
                lock.lock()
                defer { lock.unlock() }
                isCapturing = false
                return records
            }
        }

        private static let testCapture = TestCapture()

        static func beginCaptureForTesting() {
            testCapture.begin()
        }

        static func endCaptureForTesting() -> [Record] {
            testCapture.end()
        }
    #endif
}
