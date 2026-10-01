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
    // MARK: - Mark glyphs (Fb iconography, approved 2026-09-30)

    /// Overseer role mark: a filled eye in this session's own group colour.
    static let overseerMarkIcon = "eye.fill"
    /// Overseen role mark: an eye outline in the (first) overseer's group colour.
    static let overseenMarkIcon = "eye"
    /// Both roles at once: the eye takes the row's own group colour, the ring its first
    /// overseer's.
    static let dualRoleMarkIcon = "eye.circle.fill"
    /// Grey affordance on rows with no role, and the icon for the context-menu oversight entries.
    /// An eye only ever means a role, so the management affordance uses a different glyph.
    static let manageOversightIcon = "person.2.badge.gearshape"

    // MARK: - Row mark tooltip (VoiceOver reads the same text)

    /// Renders at most three names, then a compact remainder: `A, B, C +2 more`.
    static func truncatedNameList(_ names: [String]) -> String {
        let head = names.prefix(3).joined(separator: ", ")
        let remainder = names.count - 3
        guard remainder > 0 else { return head }
        return "\(head) +\(remainder) more"
    }

    /// The mark's single combined line (approved 2026-09-30):
    /// `Overseeing: A, B, C +N more · Overseen by: D, E · Created by: F`, with segments omitted
    /// when empty. When the creator is the row's only overseer, the last two segments collapse to
    /// `Created and overseen by: F`. Empty only when the row has no role and no provenance — callers
    /// only invoke this for rows that render a mark.
    static func oversightMarkTooltip(
        overseeingNames: [String],
        overseenByNames: [String],
        creator: String?,
        creatorIsSoleOverseer: Bool
    ) -> String {
        var segments: [String] = []
        if !overseeingNames.isEmpty {
            segments.append("Overseeing: \(truncatedNameList(overseeingNames))")
        }
        if creatorIsSoleOverseer, let creator {
            segments.append("Created and overseen by: \(creator)")
        } else {
            if !overseenByNames.isEmpty {
                segments.append("Overseen by: \(truncatedNameList(overseenByNames))")
            }
            if let creator {
                segments.append("Created by: \(creator)")
            }
        }
        return segments.joined(separator: " · ")
    }

    /// Stashed-row provenance: the creator-navigation button's label. Stashed lanes have no live
    /// role, so this is the only place their origin still surfaces outside the menus.
    static func createdByTooltip(creator: String) -> String {
        "Created by: \(creator)"
    }

    /// Hover affordance on rows that currently have no oversight role.
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
    /// Disabled header lines atop the oversight menus and the Session-ID sheet — one plain
    /// line about what the popup does. PLACEHOLDER copy reusing approved phrases until
    /// Cristian approves the final strings (PR #32).
    static let overseeByMenuHeader = "Oversee by"
    static let overseeMenuHeader = "Make overseer of"
    static let sessionIDSheetHeader = "Session ID…"

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
