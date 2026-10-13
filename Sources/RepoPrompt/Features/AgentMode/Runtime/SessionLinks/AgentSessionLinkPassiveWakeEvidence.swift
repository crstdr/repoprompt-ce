import Foundation

/// Admission-only evidence, never part of an authority snapshot, prompt, cursor, or receipt.
/// A token names an exact attempt/binding/turn, not a provider's reusable process run ID.
enum AgentSessionLinkPassiveWakeEvidence: Hashable {
    case unknown
    case open(AgentRunOwnership)
    case silent(AgentRunOwnership)
    case ordinary(AgentRunOwnership)

    var ownership: AgentRunOwnership? {
        switch self {
        case .unknown: nil
        case let .open(owner), let .silent(owner), let .ordinary(owner): owner
        }
    }

    var isPassive: Bool {
        switch self {
        case .open, .silent: true
        case .unknown, .ordinary: false
        }
    }

    /// Padding the contract actually permits: ASCII whitespace only. Foundation's broader
    /// `whitespacesAndNewlines` trims invisible format scalars like U+200B, which would let
    /// `ack\u{200B}` pass as the exact token — strict is safer.
    private static let quietPadding = CharacterSet(charactersIn: " \t\n\r\u{0B}\u{0C}")

    /// The one reply a routine wake may end with and still finish quietly: the token `ack`,
    /// case-insensitive, permitting surrounding whitespace and at most one trailing full stop.
    static func isQuietRoutineReply(_ text: String) -> Bool {
        var token = text.trimmingCharacters(in: quietPadding)
        if token.hasSuffix(".") { token.removeLast() }
        return token.lowercased() == "ack"
    }

    /// Whether reply text observed so far can still resolve to the exact quiet form once the turn
    /// settles: trimmed, it must be a prefix of `ack.`. Anything else is vetoed at once, just as it
    /// was before the quiet reply existed — a visible non-`ack` reply never waits for settlement.
    static func replyTextCanStillBecomeQuiet(_ merged: String) -> Bool {
        "ack.".hasPrefix(merged.trimmingCharacters(in: quietPadding).lowercased())
    }

    /// Bound on retained reply text — a deliberate eligibility line, not just a memory bound:
    /// a reply padded past this can spell the token yet still wakes observers.
    static let maxQuietReplyUTF8 = 256
}

/// One current/recent segment per tab, owned solely by AgentTabSession. The native run-start
/// owner binds the explicit reserved wake ID before its first running publication. Preparation
/// retains the prior settled proof; successors, restore, and unknown origins cannot inherit it.
struct AgentSessionLinkPassiveWakeSegment {
    let wakeID: UUID
    let ownership: AgentRunOwnership
    var acquired = false
    var accepted = false
    var vetoed = false
    /// Reply fragments streamed since the last completed message; an authoritative full message
    /// supersedes exactly this prefix, while a blank completion seals it into completed text.
    var replyPendingText = ""
    /// Authoritative complete reply texts joined in order (Claude `final_content`, Codex
    /// `assistantCompleted`). A turn can hold several completed messages; the newline boundary
    /// keeps `"a"` + `"ck"` classifying as two messages instead of merging into `ack`.
    var replyCompletedText = ""

    /// What this turn has visibly replied so far: every completed message plus fragments streamed
    /// after the last one, or the accumulated stream when no authoritative text has arrived.
    var replyText: String {
        var text = replyCompletedText
        if !replyPendingText.isEmpty, !text.isEmpty { text += "\n" }
        return text + replyPendingText
    }

    /// Appends one authoritative complete reply, preserving the message boundary.
    mutating func appendReplyCompletion(_ text: String) {
        if !replyCompletedText.isEmpty { replyCompletedText += "\n" }
        replyCompletedText += text
        replyPendingText = ""
    }
}

@MainActor
extension AgentTabSession {
    var supportsPassiveWakeEvidence: Bool {
        selectedAgent == .codexExec || selectedAgent == .claudeCode || selectedAgent == .devin
    }

    /// Pure bounded classifier. The existing terminal barrier owns drain and publication facts.
    var passiveWakeEvidence: AgentSessionLinkPassiveWakeEvidence {
        if let segment = passiveWakeSegment,
           passiveWakeBindingMatches(segment.ownership), segment.vetoed { return .ordinary(segment.ownership) }
        guard supportsPassiveWakeEvidence else { return .unknown }
        guard let segment = passiveWakeSegment, passiveWakeBindingMatches(segment.ownership) else {
            let owner = activeRunOwnership ?? lastTerminalCommitRevision?.ownership
            return owner.flatMap { passiveWakeBindingMatches($0) ? .ordinary($0) : nil } ?? .unknown
        }
        let owner = segment.ownership
        if let revision = lastTerminalCommitRevision, revision.ownership == owner {
            guard revision.terminalState == .completed, runState == .completed, segment.acquired else { return .ordinary(owner) }
            if terminalCommitInProgress { return .open(owner) }
            guard case .accepted = lastTerminalPublicationResult else { return .ordinary(owner) }
            let replyText = segment.replyText
            guard !AgentDisplayableText.hasDisplayableBody(replyText)
                || AgentSessionLinkPassiveWakeEvidence.isQuietRoutineReply(replyText)
            else { return .ordinary(owner) }
            // Native completion may precede its truthful accepted-send receipt.
            return segment.accepted ? .silent(owner) : .open(owner)
        }
        return activeRunOwnership == owner ? .open(owner) : .ordinary(owner)
    }

    private func passiveWakeBindingMatches(_ owner: AgentRunOwnership) -> Bool {
        owner.binding.tabID == tabID
            && owner.binding.persistentSessionID == activeAgentSessionID
            && owner.binding.persistentBindingGeneration == persistentSessionBindingIdentity?.generation
            && owner.binding.bindingTransitionGeneration == bindingTransitionGeneration
    }

    func bindPassiveWakeEvidence(to owner: AgentRunOwnership, wakeID: UUID?) {
        guard supportsPassiveWakeEvidence, let wakeID,
              passiveWakeSegment?.wakeID != wakeID,
              let wake = oversight.pendingAutoWake, wake.wakeID == wakeID,
              wake.admissionBasis == .routineStatusOrOverflow,
              wake.phase == .preparingDispatch || wake.phase == .dispatching
        else {
            passiveWakeSegment = nil
            return
        }
        passiveWakeSegment = .init(wakeID: wakeID, ownership: owner)
    }

    func acquirePassiveWakeEvidence(wakeID: UUID, hasAttention: Bool) {
        guard var segment = passiveWakeSegment, segment.wakeID == wakeID,
              segment.ownership == activeRunOwnership else { return }
        segment.acquired = true
        segment.vetoed = segment.vetoed || hasAttention
        passiveWakeSegment = segment
        passiveWakeEvidenceChanged.send(())
    }

    func acceptPassiveWakeEvidence(wakeID: UUID) {
        guard var segment = passiveWakeSegment, segment.wakeID == wakeID,
              passiveWakeBindingMatches(segment.ownership), segment.acquired,
              activeRunOwnership == segment.ownership || lastTerminalCommitRevision?.ownership == segment.ownership,
              !segment.accepted else { return }
        segment.accepted = true
        passiveWakeSegment = segment
        passiveWakeEvidenceChanged.send(())
    }

    /// Occurrence evidence is recorded before normalization, row deduplication, or tool hiding.
    func notePassiveWakeActivity() {
        guard var segment = passiveWakeSegment, !segment.vetoed else { return }
        segment.vetoed = true
        passiveWakeSegment = segment
        passiveWakeEvidenceChanged.send(())
    }

    /// `authoritative` marks a provider's complete reply text (Claude `final_content`, Codex
    /// `assistantCompleted`), which supersedes the streamed prefix rather than appending to it.
    /// Anything already vetoed stays vetoed; text is kept only while it can still resolve to the
    /// exact quiet reply and is classified once, from the merged text, at terminal settlement.
    /// Every byte is accumulated — including whitespace between visible runs — so that `"a"+" "+"ck"`
    /// classifies as `a ck`, never `ack`; a fragment that is nothing but invisible format/control
    /// scalars still counts as no visible reply, matching `hasDisplayableBody` at classification.
    /// Every authoritative completion event is a message boundary — including an empty or absent
    /// body: a completion with no displayable body seals the streamed prefix into completed text
    /// rather than erasing or ignoring it, so a blank `final_content` cannot leave `"ac"` fuseable
    /// with a later `ack`. With nothing streamed since the last completion it is a no-op: the
    /// blank message carries no bytes and needs no separator.
    /// Validation always inspects the post-update `replyText` — the exact text the terminal
    /// classifier sees — so the separator inserted when a delta reopens pending text, and growth
    /// from sealing, both count against the eligibility limit.
    func notePassiveWakeAssistantText(_ text: String?, authoritative: Bool = false) {
        guard var segment = passiveWakeSegment, !segment.vetoed else { return }
        if authoritative {
            if let text, AgentDisplayableText.hasDisplayableBody(text) {
                segment.appendReplyCompletion(text)
            } else {
                guard !segment.replyPendingText.isEmpty else { return }
                segment.appendReplyCompletion(segment.replyPendingText)
            }
        } else {
            guard let text, !text.isEmpty else { return }
            segment.replyPendingText += text
        }
        let candidate = segment.replyText
        guard candidate.utf8.count <= AgentSessionLinkPassiveWakeEvidence.maxQuietReplyUTF8,
              !AgentDisplayableText.hasDisplayableBody(candidate)
              || AgentSessionLinkPassiveWakeEvidence.replyTextCanStillBecomeQuiet(candidate)
        else {
            notePassiveWakeActivity()
            return
        }
        passiveWakeSegment = segment
    }

    /// Genuine terminal teardown may clear the process ID before a late native acceptance.
    var passiveWakeHasSettledTerminalProof: Bool {
        guard let owner = passiveWakeSegment?.ownership, passiveWakeBindingMatches(owner),
              let revision = lastTerminalCommitRevision, revision.ownership == owner,
              revision.terminalState == .completed, !terminalCommitInProgress,
              case .accepted = lastTerminalPublicationResult else { return false }
        return true
    }

    func notePassiveWakeInput() {
        guard let segment = passiveWakeSegment else { return }
        // Input after settlement does not retroactively reclassify the old queued contribution.
        // Its immutable proof lives only until the next attempt, just like the terminal revision.
        if lastTerminalCommitRevision?.ownership == segment.ownership, !terminalCommitInProgress { return }
        notePassiveWakeActivity()
    }

    func invalidatePassiveWakeEvidence() {
        notePassiveWakeActivity()
    }
}
