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
}

@MainActor
extension AgentTabSession {
    var supportsPassiveWakeEvidence: Bool {
        selectedAgent == .codexExec || selectedAgent == .claudeCode
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

    func notePassiveWakeAssistantText(_ text: String?) {
        guard passiveWakeSegment?.vetoed == false,
              let text, AgentDisplayableText.hasDisplayableBody(text) else { return }
        notePassiveWakeActivity()
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
