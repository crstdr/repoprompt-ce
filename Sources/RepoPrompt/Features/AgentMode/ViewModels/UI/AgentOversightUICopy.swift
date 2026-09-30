import Foundation

/// Single owner of user-visible copy for the unified sidebar oversight UI.
///
/// Scope: the row relationship marks, the shared lane menu ("Oversee by"), the inverse
/// "Make overseer of" / "Oversee" menu, the Session-ID sheets, and the link confirmation
/// dialog. Existing dashboard/pill copy (`AgentMonitorPillModels`, resolver `uiMessage`
/// strings, persistence copy) stays in its current owners and is only referenced from here.
///
/// Session names, UUIDs, counts, and locations are data interpolated into these templates;
/// templates never decide authority — every action still revalidates exact endpoints through
/// `AgentSessionLinkRuntimeBridge`.
enum AgentOversightUICopy {
    /// Shared glyph for every overseen/management affordance: the persistent overseen mark,
    /// the provenance mark on an overseer-created lane, and the grey hover affordance.
    static let relationshipMarkIcon = "rectangle.connected.to.line.below"

    /// Purple eye mark meaning "this session oversees others". Non-clickable.
    static let overseerIcon = "eye.fill"

    // MARK: - Row mark tooltips (VoiceOver reads the same text)

    /// Renders at most three names, then a compact remainder: `A, B, C +2 more`.
    static func truncatedNameList(_ names: [String]) -> String {
        let head = names.prefix(3).joined(separator: ", ")
        let remainder = names.count - 3
        guard remainder > 0 else { return head }
        return "\(head) +\(remainder) more"
    }

    static func overseeingTooltip(targetNames: [String]) -> String {
        "Overseeing: \(truncatedNameList(targetNames))"
    }

    static func overseenByTooltip(observerNames: [String]) -> String {
        "Overseen by: \(truncatedNameList(observerNames))"
    }

    /// Created lane whose only active overseer is still its creator.
    static func createdAndOverseenTooltip(creator: String) -> String {
        "Created and overseen by: \(creator)"
    }

    /// Created lane with active inbound oversight beyond (or instead of) its creator.
    static func createdByOverseenByTooltip(creator: String, observerNames: [String]) -> String {
        "Created by: \(creator); overseen by: \(truncatedNameList(observerNames))"
    }

    /// Created lane whose inbound links are all gone. Provenance only.
    static func createdByUnlinkedTooltip(creator: String) -> String {
        "Created by: \(creator) (unlinked)"
    }

    /// Hover affordance on rows that currently have no inbound oversight.
    static let manageOversightTooltip = "Manage oversight"

    // MARK: - Menus

    static let overseeByTitle = "Oversee by"
    /// Inverse submenu title while the clicked row oversees nothing yet.
    static let makeOverseerOfTitle = "Make overseer of"
    /// Inverse submenu title once the clicked row already oversees at least one session.
    static let overseeTitle = "Oversee"
    static let sessionIDMenuItem = "Session ID…"
    static let noEligibleOverseers = "No eligible overseers"
    static let noSessionsToOversee = "No sessions to oversee"

    static func openLabel(_ displayName: String) -> String {
        "Open \"\(displayName)\""
    }

    static func openCreatorLabel(_ creator: String) -> String {
        "Open creator \"\(creator)\""
    }

    /// VoiceOver action name for a checked (linked) menu item: selecting it unlinks.
    static func unlinkAccessibilityLabel(_ displayName: String) -> String {
        "Unlink \"\(displayName)\""
    }

    /// VoiceOver value of the Oversee menu (approved: "Overseeing {N}; {M} available").
    static func overseeMenuAccessibilityValue(
        overseeingCount: Int,
        availableCount: Int
    ) -> String {
        "Overseeing \(overseeingCount); \(availableCount) available"
    }

    /// VoiceOver value of the Oversee-by menu — mirrors the approved Oversee value.
    /// TODO(copy-approval): derived phrasing, pending sign-off.
    static func overseeByMenuAccessibilityValue(
        overseenByCount: Int,
        availableCount: Int
    ) -> String {
        "Overseen by \(overseenByCount); \(availableCount) available"
    }

    /// Unified capitalization for every "Copy Session ID" surface.
    static let copySessionIDTitle = "Copy Session ID"

    /// Disabled placeholder shown in the Oversee-by menu when the row's exact target
    /// endpoint exists but cannot currently accept a new inbound link.
    static func unavailableReasonItem(_ reason: String) -> String {
        reason
    }

    // MARK: - Session-ID sheet

    /// Outbound sheet (the row picks what it oversees): the row is `{observer}`.
    static func sessionIDSheetTitle(observer: String) -> String {
        "Choose a session for \"\(observer)\" to oversee"
    }

    /// Inbound sheet (the row picks who oversees it): the row is `{session}`.
    static func inboundSessionIDSheetTitle(session: String) -> String {
        "Choose an overseer for \"\(session)\""
    }

    static let sessionIDFieldPlaceholder = "Session ID"
    static let sessionIDFieldAccessibilityLabel = "Session ID to oversee"
    /// Approved VoiceOver label for the inbound (choose-an-overseer) field.
    static let overseerSessionIDFieldAccessibilityLabel = "Overseer Session ID"
    static let pasteFromClipboard = "Paste from Clipboard"
    static let pasteFromClipboardHint = "Pastes a copied session ID"
    static let overseeSessionButton = "Oversee session"
    /// Inbound submit: the pasted session becomes an overseer of this row.
    static let addOverseerButton = "Add overseer"
    static let cancelButton = "Cancel"

    // MARK: - Confirmation dialog

    static func confirmationTitle(observer: String, target: String) -> String {
        "Allow \"\(observer)\" to oversee \"\(target)\"?"
    }

    static func confirmationBody(observer: String, target: String) -> String {
        """
        “\(observer)” will be able to:
         • read \(target)’s status and conversation
         • send it instructions, steer it and stop its current run
         • answer its questions and one-time approval requests
         • compact its context, and be woken up by its updates

        You can unlink anytime.
        """
    }

    static let confirmationAllowButton = "Allow oversight"
    static let confirmationCancelButton = "Cancel"
    static let confirmationSuppressionCheckbox = "Don’t ask again"

    /// Shown when the endpoints or menu options captured before a confirm/submit no longer
    /// resolve — the sole stale-state error for every oversight surface.
    static let staleSelectionMessage = "Sessions changed. Please choose again."

    /// Approved fallback when no resolver is wired (unreachable in the current wiring).
    static let oversightUnavailableMessage = "Oversight is unavailable right now."
}
