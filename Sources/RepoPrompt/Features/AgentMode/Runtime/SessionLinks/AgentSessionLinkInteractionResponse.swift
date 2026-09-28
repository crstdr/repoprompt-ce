import Foundation
import MCP
import RepoPromptDomainRuntime

// Value types for a managing observer inspecting and explicitly answering its target's current
// pending interaction through managed `agent_session_link` `poll`/`wait` and `respond`.
//
// Authority is layered and every layer is required:
// 1. the exact outbound grant carrying the user's `.manage` delegation (a management lease from
//    `authorizeTarget` plus live endpoint revalidation),
// 2. the same lease re-validated inside the authority as the final suspension point, so a
//    withdrawn delegation or revoked link applies nothing,
// 3. the target's exact current `interaction_id` (compare-and-set before and after that final
//    authority hop, with the submission made synchronously after the last check).
//
// Nothing here answers anything automatically. Provider permission auto-approval is a separate,
// independent opt-in that never reaches questions or elicitations.

/// Why a pending interaction can be inspected but only answered by the target's own user.
enum AgentSessionLinkInteractionManualOnlyReason: String, Equatable {
    /// Codex project-hook trust is persistent project state, not a one-request decision.
    case hookApproval = "hook_approval"
    /// App-owned worktree merge reviews mutate another worktree and stay with the local user.
    case worktreeMergeReview = "worktree_merge_review"
    /// A field marked secret (for example a credential) is never supplied by another session.
    case secretInput = "secret_input"
    /// A wait for the session's next instruction is not a prompt `respond` answers. A managing
    /// observer delivers that instruction with `steer` instead.
    case instructionPrompt = "instruction_prompt"
    /// Session-wide or policy-amending approvals widen authority beyond this one request.
    case persistentDecision = "persistent_decision"
    /// An ACP provider offered no genuine one-time allow option for this request.
    case noOneTimeAllowOption = "no_one_time_allow_option"
    /// The redacted interaction exceeds the hard single-target prompt disclosure limit.
    case tooLarge = "too_large"
}

/// What the observer sees for one target's current pending interaction.
struct AgentSessionLinkPendingInteractionInspection: Equatable {
    /// Redacted interaction, restricted to the options an observer may choose. `nil` when the
    /// target has no pending interaction.
    let interaction: AgentRunMCPSnapshot.Interaction?
    /// Non-nil when the pending interaction exists but only the target's user may answer it.
    let manualOnlyReason: AgentSessionLinkInteractionManualOnlyReason?

    static let none = AgentSessionLinkPendingInteractionInspection(interaction: nil, manualOnlyReason: nil)
    static let promptMaxBytes = 64 * 1024
    static let instructionWaitNote =
        "The session is waiting for its next instruction rather than asking a question. Give it that instruction with steer."

    /// The exact object measured for the hard disclosure cap and, if it fits, emitted on the wire.
    func projectedObject() -> [String: Value]? {
        guard let interaction else { return nil }
        var object = interaction.asObject()
        object["interaction_id"] = .string(interaction.id.uuidString)
        object["respondable"] = .bool(manualOnlyReason == nil)
        object["manual_only_reason"] = manualOnlyReason.map { .string($0.rawValue) } ?? .null
        if manualOnlyReason != nil {
            object["options"] = .array([])
        }
        if manualOnlyReason == .instructionPrompt {
            object["note"] = .string(Self.instructionWaitNote)
        }
        return object
    }

    var exceedsPromptLimit: Bool {
        guard let object = projectedObject() else { return false }
        guard let bytes = try? JSONEncoder().encode(Value.object(object)).count else { return true }
        return bytes > Self.promptMaxBytes
    }
}

/// One explicit answer an observer asked RepoPrompt to submit on the target's behalf.
struct AgentSessionLinkInteractionResponseRequest: Equatable {
    let interactionID: UUID
    let payload: AgentModeViewModel.MCPInteractionResponsePayload
}

/// Host-level result of one respond attempt. Every case except `.submitted` applied nothing.
enum AgentSessionLinkInteractionResponseOutcome: Equatable {
    case submitted(kind: AgentRunMCPSnapshot.Interaction.Kind, decision: String?)
    case noPendingInteraction
    case interactionMismatch(currentInteractionID: UUID)
    case manualOnly(AgentSessionLinkInteractionManualOnlyReason)
    /// The answer did not fit the interaction; the message says why. Nothing was applied.
    case invalid(String)
    /// The target endpoint, grant, or management delegation stopped holding before submission.
    case unavailable
}

/// Bridge-level result: endpoint availability plus whatever the host reported. Management itself is
/// proven by the lease before the bridge is called.
enum AgentSessionLinkInteractionDisposition: Equatable {
    case denied
    case shuttingDown
    case inspected(AgentSessionLinkPendingInteractionInspection)
    case responded(AgentSessionLinkInteractionResponseOutcome)
}
