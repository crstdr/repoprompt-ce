import Foundation

/// Process-local cumulative proof. Unknown is represented by nil, never saturated fresh facts.
struct AgentRunQuietFacts: Equatable, Hashable {
    let settledThrough: UInt64
    let ordinaryThrough: UInt64

    init?(settledThrough: UInt64, ordinaryThrough: UInt64) {
        guard ordinaryThrough <= settledThrough else { return nil }
        self.settledThrough = settledThrough
        self.ordinaryThrough = ordinaryThrough
    }

    static let zero = AgentRunQuietFacts(settledThrough: 0, ordinaryThrough: 0)!
}

/// Owned by one live source binding. The existing lifecycle facade remains the attempt authority;
/// this value never looks up a session, repairs history, publishes, persists, or starts work.
@MainActor
struct AgentRunQuietLedger {
    struct Seal: Equatable {
        let ownership: AgentRunOwnership
        let isQuiet: Bool
        let facts: AgentRunQuietFacts?
    }

    private struct Attempt {
        let owner: AgentRunOwnership
        let serial: UInt64?
        let startKey: Int
        let provider: AgentSessionLinkPromptProviderContext
        let openingFacts: AgentRunQuietFacts?
        var routineWakeID: UUID?
        var hasOccurrence = false
        var rangeIsComplete = true
        var seal: Seal?
    }

    private var attempt: Attempt?
    private var lastEndedOwner: AgentRunOwnership?
    private(set) var facts: AgentRunQuietFacts?
    private(set) var hostMarkerIDs: Set<UUID> = []
    private(set) var hiddenSourceIDs: Set<UUID> = []

    /// Nonzero initial facts are useful for deterministic exhaustion tests, not restoration.
    init(initialFacts: AgentRunQuietFacts = .zero) {
        facts = initialFacts
    }

    func isOpen(owner: AgentRunOwnership) -> Bool {
        attempt?.owner == owner && attempt?.seal == nil
    }

    /// Only the authoritative begin funnel calls this. Re-entry cannot clear accepted occurrences.
    mutating func begin(owner: AgentRunOwnership, startKey: Int, provider: AgentSessionLinkPromptProviderContext) {
        guard attempt?.owner != owner, lastEndedOwner != owner else { return }
        if let previous = attempt, previous.seal == nil { advance(quiet: false) }
        let serial = facts.flatMap { value -> UInt64? in
            let (next, overflow) = value.settledThrough.addingReportingOverflow(1)
            return overflow ? nil : next
        }
        if serial == nil { facts = nil }
        attempt = Attempt(owner: owner, serial: serial, startKey: startKey, provider: provider, openingFacts: facts)
    }

    /// Qualification (idleFollowUp, no attention, first physical acquisition, no replay) belongs to
    /// the winning physical fence. Non-routine/replayed dispatch must noteOccurrence instead.
    mutating func markRoutineWake(owner: AgentRunOwnership, wakeID: UUID) {
        guard isOpen(owner: owner) else { return }
        if let marked = attempt?.routineWakeID, marked != wakeID {
            attempt?.hasOccurrence = true
        } else {
            attempt?.routineWakeID = wakeID
        }
    }

    mutating func noteOccurrence(owner: AgentRunOwnership) {
        guard isOpen(owner: owner) else { return }
        attempt?.hasOccurrence = true
    }

    mutating func invalidateRange(owner: AgentRunOwnership) {
        guard isOpen(owner: owner) else { return }
        attempt?.rangeIsComplete = false
    }

    /// Synchronous terminal-barrier operation. Default false until each native ingress is qualified.
    /// The caller has already passed its second exact ownership/drain guard; there is no await here.
    @discardableResult
    mutating func settle(
        owner: AgentRunOwnership,
        terminalState: AgentSessionRunState,
        classifiesQuietCheckIn: Bool = false,
        hasSuccessor: Bool = false,
        endKey: Int,
        rangeIsComplete: Bool = false,
        rows: some Collection<AgentChatItem>
    ) -> Seal? {
        guard let current = attempt, current.owner == owner else { return nil }
        if let seal = current.seal { return seal }
        var quiet = false
        if facts != nil, current.serial != nil,
           classifiesQuietCheckIn, terminalState == .completed, !hasSuccessor,
           !current.hasOccurrence, current.rangeIsComplete,
           AgentQuietCheckInClassifier.supports(current.provider),
           let wakeID = current.routineWakeID,
           case let .quiet(hiddenIDs) = AgentQuietCheckInClassifier.classify(
               rows: rows,
               startKey: current.startKey,
               endKey: endKey,
               rangeIsComplete: rangeIsComplete,
               routineWakeID: wakeID,
               hostMarkerIDs: hostMarkerIDs
           )
        {
            quiet = true
            hiddenSourceIDs.formUnion(hiddenIDs)
        }
        advance(quiet: quiet)
        let seal = Seal(ownership: owner, isQuiet: quiet, facts: facts)
        attempt?.seal = seal
        return seal
    }

    /// Call from the successful central lifecycle end with its captured authoritative owner.
    /// That proof is required even with a missing ledger begin; a stale end is not a known end.
    /// No unbounded ended-attempt journal is needed because the lifecycle rejects old ownership.
    @discardableResult
    mutating func end(owner: AgentRunOwnership, authoritativeOwner: AgentRunOwnership?) -> Bool {
        guard authoritativeOwner == owner, lastEndedOwner != owner else { return false }
        if let current = attempt {
            guard current.owner == owner else { return false }
            if current.seal == nil { advance(quiet: false) }
        } else {
            advance(quiet: false)
        }
        attempt = nil
        lastEndedOwner = owner
        return true
    }

    /// Status, not ownership release, selects the cutoff during synchronous terminal handoff.
    func sourceFacts(owner: AgentRunOwnership?, capturedState: AgentSessionRunState) -> AgentRunQuietFacts? {
        if let current = attempt, capturedState.isActive {
            guard current.owner == owner else { return nil }
            return current.openingFacts
        }
        return facts
    }

    /// Only the endpoint/readiness-fenced captured acceptance registers canonical host provenance.
    @discardableResult
    mutating func registerHostMarker(_ row: AgentChatItem) -> Bool {
        guard row.kind == .system, row.text == AgentLaneUpdateDisplayAttribution.canonicalSystemText else { return false }
        return hostMarkerIDs.insert(row.id).inserted
    }

    /// Mutation owner proves these materialized source rows AND retained source anchors retired.
    /// Pass only actual retired row/anchor IDs, never absent IDs found by scanning this projection.
    /// Absence from a working suffix, claim store or pending-wake slot is not retirement proof.
    mutating func retireSourceIDs(_ ids: Set<UUID>) {
        hiddenSourceIDs.subtract(ids)
        hostMarkerIDs.subtract(ids)
    }

    /// Producer settlement proves no admissible callback (including queued MainActor work) remains.
    mutating func retireUnmaterializedWake(_ wakeID: UUID) {
        guard !hostMarkerIDs.contains(wakeID) else { return }
        hiddenSourceIDs.remove(wakeID)
    }

    /// Reload lost verdict proof: rows reappear. A surviving binding must NOT reset its counters.
    mutating func discardSourceProof() {
        hiddenSourceIDs.removeAll()
        hostMarkerIDs.removeAll()
        if attempt?.seal == nil { attempt?.rangeIsComplete = false }
    }

    private mutating func advance(quiet: Bool) {
        guard let previous = facts else { return }
        let (next, overflow) = previous.settledThrough.addingReportingOverflow(1)
        guard !overflow else {
            facts = nil
            return
        }
        facts = AgentRunQuietFacts(settledThrough: next, ordinaryThrough: quiet ? previous.ordinaryThrough : next)
    }
}
