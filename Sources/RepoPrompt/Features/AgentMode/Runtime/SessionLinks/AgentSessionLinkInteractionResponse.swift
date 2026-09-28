import Foundation
import MCP
import RepoPromptDomainRuntime

// Value types for observer-local pending-interaction inspection through `poll`/`wait` and explicit
// answers through `respond`. These paths have distinct authority checks:
// 1. `poll`/`wait` obtain exact observation leases via `authorizeTargets`; before inspecting any
//    prompt, `managedObservationTargetsIfValid` proves current Manage for the whole batch, and the
//    bridge rechecks live endpoints. Restricted grants receive no prompt body.
// 2. `respond` obtains a Manage-authorized mutation lease via `authorizeTarget`, then revalidates
//    that exact lease and both live endpoints at the final authority hop before submission.
// 3. `respond` also compares the target's current `interaction_id` before and after that hop, and
//    submits synchronously after the last check. Revocation or endpoint drift applies nothing.
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
    /// The target endpoint or exact grant failed its final live Manage proof before submission.
    case unavailable
}

/// Bridge-level result: endpoint availability plus whatever the host reported. Management itself is
/// proven by the lease before the bridge is called.
enum AgentSessionLinkInteractionDisposition: Equatable {
    case denied
    case shuttingDown
    case responded(AgentSessionLinkInteractionResponseOutcome)
}
