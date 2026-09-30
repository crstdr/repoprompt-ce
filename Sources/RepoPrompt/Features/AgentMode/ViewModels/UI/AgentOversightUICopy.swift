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

    /// Unified capitalization for every "Copy Session ID" surface.
    static let copySessionIDTitle = "Copy Session ID"

    /// Disabled placeholder shown in the Oversee-by menu when the row's exact target
    /// endpoint exists but cannot currently accept a new inbound link.
    static func unavailableReasonItem(_ reason: String) -> String {
        reason
    }

    // MARK: - Session-ID sheet

    /// One approved template names the row by its role — `{target}` on the inbound sheet
    /// (the session picking who oversees it) and `{observer}` on the outbound sheet — which is the
    /// same literal string carrying the row's display name either way.
    static func sessionIDSheetTitle(rowName: String) -> String {
        "Choose a session for \"\(rowName)\" to oversee"
    }

    static let sessionIDFieldPlaceholder = "Session ID"
    static let sessionIDFieldAccessibilityLabel = "Session ID to oversee"
    // TODO(copy-approval): inbound field label — not in the approved copy set.
    static let overseerSessionIDFieldAccessibilityLabel = "Overseer Session ID"
    static let pasteFromClipboard = "Paste from Clipboard"
    static let pasteFromClipboardHint = "Pastes a copied session ID"
    static let overseeSessionButton = "Oversee session"
    static let cancelButton = "Cancel"

    // TODO(copy-approval): neutral already-linked message for the inbound resolver.
    // The shared resolver's `.alreadyMonitoring` message reads "You're already
    // overseeing this session.", which is wrong when the pasted session is the observer.
    static let alreadyLinkedInDirection = "These sessions are already linked in this direction."

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

    /// Shown when the exact endpoints captured before the dialog no longer resolve.
    static let confirmationStaleSelection =
        "The selected sessions changed. Choose them again before creating oversight."

    // TODO(copy-approval): generic fallback when no resolver is wired — not in the approved
    // copy set. Unreachable when the Session-ID item is wired with resolvers.
    static let oversightUnavailableMessage = "Oversight is unavailable right now."
}
