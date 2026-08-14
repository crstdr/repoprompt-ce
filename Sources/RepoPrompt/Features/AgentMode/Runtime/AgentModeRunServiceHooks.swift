import Foundation
import RepoPromptDomainRuntime

// MARK: - Authority-classified run execution hooks

// `AgentModeRunService.Hooks` is the host-supplied callback surface used by the
// run service, the terminal commit barrier, and the provider runners. Each hook
// group below is classified by the authority it belongs to, so the reusable
// execution boundary stays explicit about ownership:
//
// - Canonical lifecycle/durable settlement stays owned by the domain layer
//   (`DomainAgentRunSessionStore`); `TerminalSettlementHooks` only adapts into
//   that authority and must remain exactly-once per run attempt ownership.
// - Presentation, binding-observation, queued-work recovery, and persistence
//   hooks are host projections. They must never become backend authority: a
//   headless host may implement them as no-ops without changing run semantics.
// - `AgentModeViewModel.TabSession` still appears in these signatures because
//   the app host is the only adopter today. The grouping is the contract seam;
//   neutralizing the session parameter is the provider-migration step (PR 3).

extension AgentModeRunService {
    /// Token/usage accounting projection for non-Codex turns.
    ///
    /// Authority: usage accounting (host-side projection of provider activity).
    struct UsageAccountingHooks {
        let estimateRuntimeTokens: (String) -> Int
        let addUserInputTokensToActiveNonCodexTurn: (Int, AgentModeViewModel.TabSession) -> Void
        let startNonCodexTurnAccountingIfNeeded: (AgentModeViewModel.TabSession, String) -> Void
        let finalizeNonCodexTurnUsage: (AgentModeViewModel.TabSession, Int?, Int?, Int?) -> Void
    }

    /// Attachment file lifecycle for one turn (reserve → consume → finalize).
    ///
    /// Authority: persistence/durable turn resources.
    struct AttachmentLifecycleHooks {
        let reserveAttachmentsForTurn: ([AgentImageAttachment], AgentModeViewModel.TabSession) -> UUID?
        let markAttachmentsConsumed: (AgentModeViewModel.TabSession, UUID?) -> Void
        let stageConsumedAttachmentFilesForDeferredCleanup: ([AgentImageAttachment], AgentModeViewModel.TabSession) -> Void
        let consumeDeferredAttachmentCleanup: (AgentModeViewModel.TabSession, Bool) -> Void
        let finalizeAttachmentsForTurn: (AgentModeViewModel.TabSession, UUID?, AgentModeViewModel.AttachmentTurnDisposition) -> Void
    }

    /// UI-only callbacks. Never authoritative for run lifecycle decisions.
    ///
    /// Authority: presentation projection.
    struct RunPresentationHooks {
        let setAgentRunActive: (UUID, Bool) -> Void
        let requestUIRefresh: (UUID, Bool) -> Void
        let notifyAgentTurnComplete: (AgentModeViewModel.TabSession) -> Void
    }

    /// Session binding/run-state observation invoked from the central run
    /// execution routing points. Not UI-only: alongside presentation binding
    /// updates, the app host also observes MCP-controlled session state from
    /// this callback, so it is classified as host binding observation rather
    /// than pure presentation.
    ///
    /// Authority: host binding/state observation projection. Never
    /// authoritative for run lifecycle decisions.
    struct RunBindingObservationHooks {
        let updateBindings: (AgentModeViewModel.TabSession) -> Void
    }

    /// Recovery of queued, undelivered user work when a run settles before
    /// delivery (restoring queued steering text back into the host composer).
    ///
    /// Authority: queued-work recovery projection.
    struct QueuedWorkRecoveryHooks {
        let restoreDraftText: (_ tabID: UUID, _ text: String, _ message: String, _ strategy: DraftRestorationStrategy) -> Void
    }

    /// Host persistence scheduling for session/tab state.
    ///
    /// Authority: persistence projection.
    struct RunPersistenceHooks {
        let scheduleSave: (UUID) -> Void
    }

    /// Transcript projection of provider stream events and terminal finalization.
    ///
    /// Authority: transcript projection.
    struct TranscriptProjectionHooks {
        let handleHeadlessStreamResult: (AIStreamResult, AgentModeViewModel.TabSession, UUID, UUID) async -> Void
        let finalizeStreamingItems: (AgentModeViewModel.TabSession) -> Void
        let finalizePendingToolCalls: (AgentModeViewModel.TabSession, AgentSessionRunState) -> Void
        let finalizePendingToolCallsWithUpperBound: (AgentModeViewModel.TabSession, AgentSessionRunState, Int?) -> Void
        let flushPendingAssistantDelta: (AgentModeViewModel.TabSession) -> Void
        let clearPendingAssistantDelta: (AgentModeViewModel.TabSession) -> Void
    }

    /// Provider-facing input assembly (messages, handoff payloads).
    ///
    /// Authority: provider capability inputs.
    struct ProviderInputAssemblyHooks {
        let buildHeadlessAgentMessage: (AgentModeViewModel.TabSession, String, UUID, [AgentImageAttachment]) -> AgentMessage
        /// Augment queued steering text with skill context, tagged files, and attachment rendering before submit.
        let augmentUserMessageForProviderSend: (
            _ text: String,
            _ attachments: [AgentImageAttachment],
            _ taggedFileAttachments: [AgentTaggedFileAttachment],
            _ session: AgentModeViewModel.TabSession?
        ) async -> String
        /// Stages a transcript handoff for fresh-session resume recovery.
        let stageResumeRecoveryHandoffIfNeeded: (_ session: AgentModeViewModel.TabSession) async -> Void
        /// Prepends a staged handoff payload to provider-facing text.
        let prependPendingHandoffIfNeeded: (_ text: String, _ session: AgentModeViewModel.TabSession) -> String
        /// Records whether a staged handoff payload was accepted by the provider send attempt.
        let recordPendingHandoffSendOutcome: (_ session: AgentModeViewModel.TabSession, _ didSend: Bool) -> Void
        /// Reserves the cross-window oversight supplement owed to one logical outbound dispatch.
        ///
        /// Runners call this immediately before the physical provider send, never at enqueue time: a
        /// queued or requeued turn must render the membership revision that is current when it
        /// actually dispatches.
        ///
        /// One claim can carry membership context, a coalesced passive target-status batch, or both.
        /// Runners deliberately cannot tell which: the claim is opaque here, there is no
        /// status-specific API, and the passive half never starts, wakes, or schedules a turn — it
        /// only rides along with a dispatch the runner was already making.
        let claimAgentSessionLinkPrompt: (
            AgentModeViewModel.TabSession,
            AgentSessionLinkPromptDispatchID
        ) -> AgentSessionLinkOutboundPromptClaim?
        /// Acknowledges a claim at the provider's acceptance signal. Consuming is exactly-once; a
        /// failed or unknown-outcome attempt simply never calls this and leaves the claim pending.
        ///
        /// Whichever components the claim carried are settled by their own owners behind this one
        /// call, so a runner never has to know a passive batch was involved.
        let acceptAgentSessionLinkPrompt: (AgentSessionLinkOutboundPromptClaim) -> Void

        /// Attaches the cross-window oversight supplement to an already-built provider message.
        ///
        /// Applied after history, handoff, attachment, workflow, and file-map composition, so the
        /// supplement is always the final RepoPrompt envelope in the user-message channel and never
        /// displaces user-controlled content. `AgentMessage.systemPrompt` is untouched: resumed ACP
        /// and headless providers deliberately omit it, and the base instructions are not a valid
        /// channel for changing inventory or for target status that changes between turns.
        func decoratedAgentMessage(
            _ message: AgentMessage,
            session: AgentModeViewModel.TabSession,
            dispatchID: AgentSessionLinkPromptDispatchID
        ) -> (message: AgentMessage, claim: AgentSessionLinkOutboundPromptClaim?) {
            let claim = claimAgentSessionLinkPrompt(session, dispatchID)
            return (AgentSessionLinkPromptComposer.decorated(message, with: claim), claim)
        }
    }

    /// Cancellation of pending approvals/questions/reviews when a run settles.
    ///
    /// Authority: approval/interaction brokerage.
    struct RunInteractionHooks {
        let cancelPendingQuestion: (AgentModeViewModel.TabSession) -> Void
        let cancelPendingApproval: (AgentModeViewModel.TabSession) -> Void
        let cancelPendingApplyEditsReview: (AgentModeViewModel.TabSession, String) -> Void
        let cancelPendingWorktreeMergeReview: (AgentModeViewModel.TabSession, String) -> Void
    }

    /// Adapter into the canonical durable terminal settlement authority
    /// (`DomainAgentRunSessionStore` behind the host's publication surface).
    ///
    /// Authority: canonical lifecycle command/event adaptation. The terminal
    /// commit barrier drives these exactly once per settled run attempt.
    struct TerminalSettlementHooks {
        let prepareTerminalPublication: (AgentModeViewModel.TabSession) -> Void
        let makeTerminalPublicationEnvelope: (
            AgentModeViewModel.TabSession,
            AgentRunOwnership,
            AgentSessionRunState,
            UUID?,
            DomainAgentRunSnapshot.FailureReason?
        ) -> AgentRunTerminalPublicationEnvelope?
        let publishTerminalCommit: (
            AgentModeViewModel.TabSession,
            AgentRunTerminalCommitRevision,
            AgentRunEpochTransitionKind?
        ) async -> AgentRunTerminalPublicationResult
    }

    /// Continuation of a settled or steered run (follow-up starts, MCP wakes).
    ///
    /// Authority: lifecycle command issuance back into the host.
    struct RunContinuationHooks {
        let startFollowUpRun: (UUID, String) -> Void
        /// Wakes MCP waiters once a steering instruction has actually been delivered to the provider.
        let signalMCPInstructionDelivered: (_ session: AgentModeViewModel.TabSession) async -> Void
    }

    /// Composite host callback surface for run execution, grouped by authority.
    struct Hooks {
        let usage: UsageAccountingHooks
        let attachments: AttachmentLifecycleHooks
        let presentation: RunPresentationHooks
        let bindingObservation: RunBindingObservationHooks
        let queuedWorkRecovery: QueuedWorkRecoveryHooks
        let persistence: RunPersistenceHooks
        let transcript: TranscriptProjectionHooks
        let providerInput: ProviderInputAssemblyHooks
        let interactions: RunInteractionHooks
        let terminalSettlement: TerminalSettlementHooks
        let continuation: RunContinuationHooks
    }
}
