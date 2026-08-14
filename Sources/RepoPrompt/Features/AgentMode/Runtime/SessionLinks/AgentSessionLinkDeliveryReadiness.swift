import Foundation

// MARK: - Turn origin

/// Explicit logical origin of a session's current (or most recent) turn.
///
/// This is recorded at every acceptance point rather than inferred from the transcript. Inferring it
/// from "the last user row" would be wrong in both directions: a queued local instruction is accepted
/// long before its row becomes the last one, and an attributed cross-session row stays the last user
/// row for the whole run even after the local user has steered.
enum AgentSessionLinkTurnOrigin: Equatable {
    /// A local user instruction was the most recent accepted input for this session.
    case localUser
    /// The most recent accepted input arrived across an oversight link, and no local user instruction
    /// has been accepted since.
    case crossSessionMessage(sourceSessionID: UUID)
    /// The most recent accepted input was RepoPrompt's own lane-update follow-up, and no local user
    /// instruction has been accepted since.
    case laneUpdateAutoWake(wakeID: UUID)
    /// The session was restored from disk having last accepted an automatic input, and no local user
    /// instruction has been accepted since.
    ///
    /// The wake ID and source session UUID of the pre-relaunch turn are ephemeral process identities
    /// that mean nothing after a restart, so the fence is reconstructed as the *predicate* it exists
    /// to enforce rather than as a fabricated identity. Without this case the fence silently reset to
    /// `.localUser` on every relaunch, and a saved-on observer could start a second autonomous turn
    /// with no intervening local instruction — exactly the chain the guard exists to forbid.
    case restoredAutomatic

    /// Whether this origin bars the session from *originating* further linked work.
    ///
    /// True for every non-local origin, and that is the whole cycle bound: an oversight loop can
    /// produce at most one automatic turn per locally initiated origin epoch, because neither an
    /// incoming cross-session message nor an auto-wake can send onward or wake again. `poll`, `wait`,
    /// and `read` keep their ordinary authority — only origination is fenced.
    var requiresNewLocalUserInstruction: Bool {
        switch self {
        case .localUser: false
        case .crossSessionMessage, .laneUpdateAutoWake, .restoredAutomatic: true
        }
    }

    /// The durable projection of this origin: one Boolean, which is all a later launch can act on.
    ///
    /// Restoring it as `.restoredAutomatic` reconstructs the fence exactly; restoring `false` as
    /// `.localUser` preserves the documented behaviour that a saved-on observer may wake on its first
    /// new post-baseline transition.
    var persistedRequiresLocalUserInstruction: Bool {
        requiresNewLocalUserInstruction
    }

    /// Rebuilds the fence for a session hydrated from disk.
    static func restored(requiresLocalUserInstruction: Bool) -> AgentSessionLinkTurnOrigin {
        requiresLocalUserInstruction ? .restoredAutomatic : .localUser
    }
}

// MARK: - Readiness

/// Pure admission decision for an attributed cross-session send.
///
/// Deliberately a free function over a value snapshot: the full blocker matrix is the security
/// contract of `send`, and it must be provable by a truth table rather than by driving a live
/// `AgentModeViewModel` through every combination of run, wait, interaction, queue, and transition
/// state. The target's MainActor assembles the snapshot immediately before claiming submission, and
/// the same snapshot is re-evaluated after the authorization commit hop.
enum AgentSessionLinkDeliveryReadiness {
    /// Every verified blocker, plus the caller's logical turn origin.
    ///
    /// Field-for-field this mirrors live `TabSession` state; nothing is derived here so a future
    /// blocker cannot be silently dropped by an intermediate projection.
    struct Snapshot: Equatable {
        // Target identity/lifecycle
        var hasLoadedPersistedState: Bool
        var bindingTransitionInProgress: Bool
        var isClosing: Bool
        var endpointMatchesGrant: Bool

        // Target run state
        var runStateIsActive: Bool
        var terminalCommitInProgress: Bool
        var mcpFollowUpRunPending: Bool
        var isComposerSubmissionInFlight: Bool
        var isPreparingInitialWorktree: Bool
        var isChangingExecutionLocation: Bool

        // Target queues
        var pendingInstructionCount: Int
        var pendingACPSteeringCount: Int
        var pendingClaudeSteeringCount: Int
        /// This session has already reserved its one automatic lane-update follow-up.
        ///
        /// Source-compatible default `false`. A reservation is work the session is committed to, so
        /// another observer must not `send` into it any more than into an active run — otherwise the
        /// wake and the send race for the same terminal boundary.
        var pendingOversightAutoWake: Bool = false

        // Target interactions. Waiting states are never ready: answering one would be a different
        // capability than sending a new instruction, and `send` never gains it.
        var hasWaitingPrompt: Bool
        var hasPendingAskUser: Bool
        var hasPendingUserInputRequest: Bool
        var hasPendingApproval: Bool
        var hasPendingPermissionsRequest: Bool
        var hasPendingMCPElicitationRequest: Bool
        var hasPendingApplyEditsReview: Bool
        var hasPendingWorktreeMergeReview: Bool

        /// Caller
        var observerTurnOrigin: AgentSessionLinkTurnOrigin

        init(
            hasLoadedPersistedState: Bool,
            bindingTransitionInProgress: Bool,
            isClosing: Bool,
            endpointMatchesGrant: Bool,
            runStateIsActive: Bool,
            terminalCommitInProgress: Bool,
            mcpFollowUpRunPending: Bool,
            isComposerSubmissionInFlight: Bool,
            isPreparingInitialWorktree: Bool,
            isChangingExecutionLocation: Bool,
            pendingInstructionCount: Int,
            pendingACPSteeringCount: Int,
            pendingClaudeSteeringCount: Int,
            pendingOversightAutoWake: Bool = false,
            hasWaitingPrompt: Bool,
            hasPendingAskUser: Bool,
            hasPendingUserInputRequest: Bool,
            hasPendingApproval: Bool,
            hasPendingPermissionsRequest: Bool,
            hasPendingMCPElicitationRequest: Bool,
            hasPendingApplyEditsReview: Bool,
            hasPendingWorktreeMergeReview: Bool,
            observerTurnOrigin: AgentSessionLinkTurnOrigin
        ) {
            self.hasLoadedPersistedState = hasLoadedPersistedState
            self.bindingTransitionInProgress = bindingTransitionInProgress
            self.isClosing = isClosing
            self.endpointMatchesGrant = endpointMatchesGrant
            self.runStateIsActive = runStateIsActive
            self.terminalCommitInProgress = terminalCommitInProgress
            self.mcpFollowUpRunPending = mcpFollowUpRunPending
            self.isComposerSubmissionInFlight = isComposerSubmissionInFlight
            self.isPreparingInitialWorktree = isPreparingInitialWorktree
            self.isChangingExecutionLocation = isChangingExecutionLocation
            self.pendingInstructionCount = pendingInstructionCount
            self.pendingACPSteeringCount = pendingACPSteeringCount
            self.pendingClaudeSteeringCount = pendingClaudeSteeringCount
            self.pendingOversightAutoWake = pendingOversightAutoWake
            self.hasWaitingPrompt = hasWaitingPrompt
            self.hasPendingAskUser = hasPendingAskUser
            self.hasPendingUserInputRequest = hasPendingUserInputRequest
            self.hasPendingApproval = hasPendingApproval
            self.hasPendingPermissionsRequest = hasPendingPermissionsRequest
            self.hasPendingMCPElicitationRequest = hasPendingMCPElicitationRequest
            self.hasPendingApplyEditsReview = hasPendingApplyEditsReview
            self.hasPendingWorktreeMergeReview = hasPendingWorktreeMergeReview
            self.observerTurnOrigin = observerTurnOrigin
        }

        /// A fully idle, hydrated, exactly-bound target with a local-origin caller.
        ///
        /// Only used to build test cases and as documentation of the ready shape; production always
        /// assembles from live state.
        static let ready = Snapshot(
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: false,
            endpointMatchesGrant: true,
            runStateIsActive: false,
            terminalCommitInProgress: false,
            mcpFollowUpRunPending: false,
            isComposerSubmissionInFlight: false,
            isPreparingInitialWorktree: false,
            isChangingExecutionLocation: false,
            pendingInstructionCount: 0,
            pendingACPSteeringCount: 0,
            pendingClaudeSteeringCount: 0,
            pendingOversightAutoWake: false,
            hasWaitingPrompt: false,
            hasPendingAskUser: false,
            hasPendingUserInputRequest: false,
            hasPendingApproval: false,
            hasPendingPermissionsRequest: false,
            hasPendingMCPElicitationRequest: false,
            hasPendingApplyEditsReview: false,
            hasPendingWorktreeMergeReview: false,
            observerTurnOrigin: .localUser
        )
    }

    /// Why a send was refused. These are wire-stable: the observer's prompt guidance names them.
    enum BlockReason: String, CaseIterable, Equatable {
        /// The exact endpoint incarnation is gone or no longer matches the grant.
        case endpointInvalidated = "endpoint_invalidated"
        /// Retryable: the target has not finished hydrating or is rebinding.
        case targetLoading = "target_loading"
        /// The target is running, waiting, has a pending interaction, or has queued work.
        case targetNotIdle = "target_not_idle"
        /// The caller's turn was started by something other than its own user — an incoming
        /// cross-session message, or RepoPrompt's own lane-update follow-up.
        ///
        /// The case name and its wire-stable raw value are deliberately unchanged: the observer's
        /// prompt guidance names this string, and broadening what can produce it is not a new refusal.
        case crossSessionReplyRequiresUserInstruction = "cross_session_reply_requires_user_instruction"

        var message: String {
            switch self {
            case .endpointInvalidated:
                "The overseen session is no longer available at the exact endpoint this link was granted for."
            case .targetLoading:
                "The overseen session is still loading. Poll it and try again."
            case .targetNotIdle:
                "The overseen session is not ready to accept a message. Wait for it with "
                    + "until: \"sendable\" and send when a snapshot reports idle_for_send: true; "
                    + "until: \"idle\" is satisfied by targets this call still refuses."
            case .crossSessionReplyRequiresUserInstruction:
                "This turn was not started by your own user — it came from an incoming cross-session "
                    + "message or an automatic status update. Wait for a new instruction from your own "
                    + "user before sending onward."
            }
        }
    }

    enum Decision: Equatable {
        case ready
        case blocked(BlockReason)

        var isReady: Bool {
            self == .ready
        }

        var blockReason: BlockReason? {
            guard case let .blocked(reason) = self else { return nil }
            return reason
        }
    }

    /// Evaluates the full matrix in fixed precedence order.
    ///
    /// Order matters for the caller's next action, not just for the message: an invalidated endpoint
    /// must never be reported as retryable, and the loop guard is checked last so a caller that is
    /// *also* blocked by a busy target learns the retryable reason rather than the permanent one.
    static func evaluate(snapshot: Snapshot) -> Decision {
        if !snapshot.endpointMatchesGrant || snapshot.isClosing {
            return .blocked(.endpointInvalidated)
        }
        if !snapshot.hasLoadedPersistedState || snapshot.bindingTransitionInProgress {
            return .blocked(.targetLoading)
        }
        if isTargetBusy(snapshot) {
            return .blocked(.targetNotIdle)
        }
        if snapshot.observerTurnOrigin.requiresNewLocalUserInstruction {
            return .blocked(.crossSessionReplyRequiresUserInstruction)
        }
        return .ready
    }

    /// Every non-lifecycle blocker. Completed, cancelled, and failed prior runs are *not* blockers:
    /// a terminal run in a still-live session is idle and remains sendable.
    private static func isTargetBusy(_ snapshot: Snapshot) -> Bool {
        snapshot.runStateIsActive
            || snapshot.terminalCommitInProgress
            || snapshot.mcpFollowUpRunPending
            || snapshot.isComposerSubmissionInFlight
            || snapshot.isPreparingInitialWorktree
            || snapshot.isChangingExecutionLocation
            || snapshot.pendingInstructionCount > 0
            || snapshot.pendingACPSteeringCount > 0
            || snapshot.pendingClaudeSteeringCount > 0
            || snapshot.pendingOversightAutoWake
            || snapshot.hasWaitingPrompt
            || snapshot.hasPendingAskUser
            || snapshot.hasPendingUserInputRequest
            || snapshot.hasPendingApproval
            || snapshot.hasPendingPermissionsRequest
            || snapshot.hasPendingMCPElicitationRequest
            || snapshot.hasPendingApplyEditsReview
            || snapshot.hasPendingWorktreeMergeReview
    }
}
