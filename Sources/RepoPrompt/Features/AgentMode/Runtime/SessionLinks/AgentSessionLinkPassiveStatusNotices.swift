import Foundation
import RepoPromptDomainRuntime

/// Observer-local, process-memory coalescing for passive target status notices.
///
/// This reducer owns no authority and performs no delivery. Callers reconcile authoritative samples,
/// publish `snapshot`, and apply only receipts produced by an accepted provider dispatch.
struct AgentSessionLinkPassiveStatusNotices {
    static let maximumPendingTargetCount = 16

    enum Status: String, CaseIterable, Hashable {
        case idle
        case running
        case waiting
        case unavailable
    }

    struct AutoWakeLane: Hashable {
        let reference: DomainAgentSessionLinkReference
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let targetSessionID: UUID
        /// The observer's Auto-wake selection for this lane **as of publication**.
        ///
        /// A projection, not the authority: selection is live session state the user can flip at any
        /// time, and this snapshot is republished only on the next authoritative refresh. The
        /// auto-wake coordinator therefore reads the session's own selection rather than this flag —
        /// scheduling or accepting a wake on a value this stale is what let a deselected lane start a
        /// turn.
        let isEffectivelySelected: Bool
    }

    struct Sample: Hashable {
        let reference: DomainAgentSessionLinkReference
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let targetSessionID: UUID
        let displayName: String?
        let status: Status
        /// The target's readiness at this observation. A point-in-time fact, never a reservation.
        ///
        /// Forced false unless the sample is idle: a running or waiting target is not sendable, and
        /// letting an upstream projection assert otherwise would put a claim in the prompt that the
        /// send admission matrix would immediately refuse.
        let idleForSend: Bool
        let idleSince: Date?
        let waitingOn: DomainAgentSessionWaitingOn?
        let latestVisibleAssistantPreview: String?

        init(
            reference: DomainAgentSessionLinkReference,
            targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
            targetSessionID: UUID,
            displayName: String?,
            status: Status,
            idleForSend: Bool = false,
            idleSince: Date? = nil,
            waitingOn: DomainAgentSessionWaitingOn? = nil,
            latestVisibleAssistantPreview: String? = nil
        ) {
            self.reference = reference
            self.targetEndpoint = targetEndpoint
            self.targetSessionID = targetSessionID
            self.displayName = DomainAgentSessionLinkTextBudget.normalized(
                displayName,
                maxBytes: DomainAgentSessionLinkTextBudget.displayNameMaxBytes
            )
            self.status = status
            self.idleForSend = status == .idle && idleForSend
            self.idleSince = status == .idle ? idleSince : nil
            self.waitingOn = waitingOn
            self.latestVisibleAssistantPreview = DomainAgentSessionLinkTextBudget.normalized(
                latestVisibleAssistantPreview,
                maxBytes: DomainAgentSessionLinkTextBudget.assistantPreviewMaxBytes
            )
        }
    }

    struct PendingEntry: Hashable {
        let reference: DomainAgentSessionLinkReference
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let targetSessionID: UUID
        let displayName: String?
        /// First status of the still-pending interval, never overwritten by a later edge.
        let fromStatus: Status
        /// Status at the newest authoritative observation.
        let toStatus: Status
        /// When this reducer processed the newest sample represented by the line.
        ///
        /// Deliberately the reducer's own clock rather than the target's `lastActivityAt`: the agent
        /// is being told when RepoPrompt observed the status/readiness metadata it is about to use.
        /// A same-status metadata refresh updates this time without changing `edgeSequence`.
        let observedAt: Date
        let idleForSend: Bool
        let idleSince: Date?
        let waitingOn: DomainAgentSessionWaitingOn?
        let latestVisibleAssistantPreview: String?
        let changeSequence: UInt64
        /// Identity of the *status edge* that created or last advanced this entry.
        ///
        /// Distinct from `changeSequence`, which also advances for a metadata-only refresh. This one
        /// moves only when a status transition creates or advances the interval, so it answers the
        /// question failure suppression actually asks: "is this the same occurrence I already failed
        /// to deliver, or a genuinely new one that happens to have the same shape?"
        ///
        /// Without it, an acknowledged `running → idle` followed later by an independent
        /// `running → idle` for the same target produces a byte-identical structural fingerprint
        /// inside one queue epoch, and a single failed attempt would suppress every future identical
        /// transition for the life of the link.
        let edgeSequence: UInt64

        /// Explicit rather than memberwise so the enriched fields can default.
        ///
        /// The reducer always supplies all of them; the defaults exist so a caller that only cares
        /// about the transition — a renderer fixture, say — does not have to invent a timestamp and a
        /// readiness bit to state one. `edgeSequence` defaults to `changeSequence` because a freshly
        /// stated entry has had exactly one edge and no refresh.
        init(
            reference: DomainAgentSessionLinkReference,
            targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
            targetSessionID: UUID,
            displayName: String?,
            fromStatus: Status,
            toStatus: Status,
            observedAt: Date = Date(),
            idleForSend: Bool = false,
            idleSince: Date? = nil,
            waitingOn: DomainAgentSessionWaitingOn? = nil,
            latestVisibleAssistantPreview: String? = nil,
            changeSequence: UInt64,
            edgeSequence: UInt64? = nil
        ) {
            self.edgeSequence = edgeSequence ?? changeSequence
            self.reference = reference
            self.targetEndpoint = targetEndpoint
            self.targetSessionID = targetSessionID
            self.displayName = displayName
            self.fromStatus = fromStatus
            self.toStatus = toStatus
            self.observedAt = observedAt
            self.idleForSend = idleForSend
            self.idleSince = idleSince
            self.waitingOn = waitingOn
            self.latestVisibleAssistantPreview = latestVisibleAssistantPreview
            self.changeSequence = changeSequence
        }

        fileprivate func refreshed(
            from sample: Sample,
            observedAt: Date,
            changeSequence: UInt64
        ) -> PendingEntry {
            PendingEntry(
                reference: reference,
                targetEndpoint: targetEndpoint,
                targetSessionID: targetSessionID,
                displayName: sample.displayName,
                fromStatus: fromStatus,
                toStatus: toStatus,
                observedAt: observedAt,
                idleForSend: sample.idleForSend,
                idleSince: sample.idleSince,
                waitingOn: sample.waitingOn,
                latestVisibleAssistantPreview: sample.latestVisibleAssistantPreview,
                changeSequence: changeSequence,
                // Preserve only edge occurrence; refreshed readiness uses the new sample time above.
                edgeSequence: edgeSequence
            )
        }

        fileprivate func hasSameFinalMetadata(as sample: Sample) -> Bool {
            displayName == sample.displayName
                && idleForSend == sample.idleForSend
                && idleSince == sample.idleSince
                && waitingOn == sample.waitingOn
                && latestVisibleAssistantPreview == sample.latestVisibleAssistantPreview
        }
    }

    /// The structural shape a failed auto-wake attempt is suppressed against.
    ///
    /// Deliberately excludes name, preview, timestamp, readiness, sequence, and queue revision: a
    /// metadata refresh improves the payload a future dispatch would carry, but re-attempting a
    /// provider call that already failed for the same set of edges would be a failure loop. A
    /// structurally new edge, a new link generation, or newly produced overflow is a different
    /// notice and may re-arm exactly one attempt.
    ///
    /// It deliberately *includes* `edgeSequence`, which is the difference between "the same failed
    /// notice, refreshed" and "this target did the same thing again". Excluding it made suppression
    /// permanent: once a `running → idle` failed, every later `running → idle` for that link inside
    /// the same queue epoch hashed identically and stayed suppressed for the life of the link.
    struct WakeEligibilityFingerprint: Hashable {
        struct Edge: Hashable {
            let reference: DomainAgentSessionLinkReference
            let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
            let fromStatus: Status
            let toStatus: Status
            /// Occurrence identity of this exact transition. Stable across metadata refreshes,
            /// strictly advancing for a genuinely new transition.
            let edgeSequence: UInt64
        }

        let queueEpoch: UUID
        let edges: [Edge]
        let overflowProduced: UInt64
    }

    struct Snapshot: Hashable {
        let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
        let queueEpoch: UUID
        let queueRevision: UInt64
        let linkSetRevision: UInt64
        let isEnabled: Bool
        let isDeliverable: Bool
        let entries: [PendingEntry]
        /// What the envelope shows the agent: how many dropped changes are still unaccounted for.
        ///
        /// A *delta*, and therefore never an acknowledgement value. It falls back to zero as receipts
        /// land, so a receipt echoing it would acknowledge less overflow on every cycle than the queue
        /// has actually produced, and the shortfall would compound.
        let unacknowledgedOverflowCount: UInt64
        /// What a receipt acknowledges: the producer-side absolute count of dropped changes at the
        /// moment this snapshot was taken.
        ///
        /// Monotonic for the life of the epoch, so acknowledging it is idempotent, order-independent,
        /// and safe to compare against overflow produced after the claim was reserved.
        let overflowProduced: UInt64
        let autoWakeLanes: [AutoWakeLane]

        init(
            observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
            queueEpoch: UUID,
            queueRevision: UInt64,
            linkSetRevision: UInt64,
            isEnabled: Bool,
            isDeliverable: Bool,
            entries: [PendingEntry],
            unacknowledgedOverflowCount: UInt64,
            overflowProduced: UInt64,
            autoWakeLanes: [AutoWakeLane] = []
        ) {
            self.observerEndpoint = observerEndpoint
            self.queueEpoch = queueEpoch
            self.queueRevision = queueRevision
            self.linkSetRevision = linkSetRevision
            self.isEnabled = isEnabled
            self.isDeliverable = isDeliverable
            self.entries = entries
            self.unacknowledgedOverflowCount = unacknowledgedOverflowCount
            self.overflowProduced = overflowProduced
            self.autoWakeLanes = autoWakeLanes
        }

        /// The lanes this snapshot was published believing were selected, keyed for lookup.
        ///
        /// Reporting only. Scheduling and acceptance must resolve selection against the live session
        /// instead; see `isEffectivelySelected`.
        ///
        /// Built by reduction rather than `Dictionary(uniqueKeysWithValues:)` so a duplicated
        /// reference degrades to a last-wins lookup instead of trapping on the main actor.
        var effectivelySelectedAutoWakeLanesByReference: [DomainAgentSessionLinkReference: AutoWakeLane] {
            autoWakeLanes.reduce(into: [:]) { lanes, lane in
                guard lane.isEffectivelySelected else { return }
                lanes[lane.reference] = lane
            }
        }

        /// Whether this snapshot has anything worth putting in front of the agent.
        ///
        /// Overflow alone qualifies: "changes happened that you will never see the detail of" is the
        /// one honest thing the queue can say once it has dropped entries, and withholding it until
        /// some unrelated entry arrives would leave the count permanently unacknowledged.
        var hasDeliverableContent: Bool {
            !entries.isEmpty || unacknowledgedOverflowCount > 0
        }

        /// Structural identity of what this snapshot would ask a provider to be woken for.
        var wakeEligibilityFingerprint: WakeEligibilityFingerprint {
            WakeEligibilityFingerprint(
                queueEpoch: queueEpoch,
                edges: entries.map {
                    WakeEligibilityFingerprint.Edge(
                        reference: $0.reference,
                        targetEndpoint: $0.targetEndpoint,
                        fromStatus: $0.fromStatus,
                        toStatus: $0.toStatus,
                        edgeSequence: $0.edgeSequence
                    )
                },
                overflowProduced: overflowProduced
            )
        }
    }

    struct DeliveredStatus: Hashable {
        let reference: DomainAgentSessionLinkReference
        let toStatus: Status
        let changeSequence: UInt64

        init(entry: PendingEntry) {
            reference = entry.reference
            toStatus = entry.toStatus
            changeSequence = entry.changeSequence
        }
    }

    struct Receipt: Hashable {
        let queueEpoch: UUID
        let queueRevision: UInt64
        let deliveredStatuses: [DeliveredStatus]
        /// The absolute `overflowProduced` watermark the delivered envelope accounted for.
        ///
        /// Absolute rather than incremental so a duplicate, delayed, or out-of-order receipt can only
        /// ever re-state a position the queue has already passed.
        let overflowProducedThrough: UInt64

        init(
            queueEpoch: UUID,
            queueRevision: UInt64,
            deliveredStatuses: [DeliveredStatus],
            overflowProducedThrough: UInt64
        ) {
            self.queueEpoch = queueEpoch
            self.queueRevision = queueRevision
            self.deliveredStatuses = deliveredStatuses
            self.overflowProducedThrough = overflowProducedThrough
        }

        init(
            snapshot: Snapshot,
            deliveredEntries: [PendingEntry]? = nil,
            overflowProducedThrough: UInt64? = nil
        ) {
            self.init(
                queueEpoch: snapshot.queueEpoch,
                queueRevision: snapshot.queueRevision,
                deliveredStatuses: (deliveredEntries ?? snapshot.entries).map(DeliveredStatus.init),
                overflowProducedThrough: overflowProducedThrough ?? snapshot.overflowProduced
            )
        }
    }

    private struct Observation: Hashable {
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let targetSessionID: UUID
        var status: Status

        init(sample: Sample) {
            targetEndpoint = sample.targetEndpoint
            targetSessionID = sample.targetSessionID
            status = sample.status
        }
    }

    let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    let queueEpoch: UUID

    private(set) var isEnabled = false
    private(set) var isDeliverable = false
    private(set) var linkSetRevision: UInt64 = 0
    private(set) var queueRevision: UInt64 = 0
    private(set) var lastAcceptedReceiptRevision: UInt64 = 0
    private(set) var overflowProduced: UInt64 = 0
    private(set) var overflowAcknowledged: UInt64 = 0
    /// Current Auto-wake membership for this observer, held on the reducer rather than applied at
    /// each publish.
    ///
    /// Every published snapshot is an input to the Auto-wake acceptance fence, including the one a
    /// receipt produces. Decorating only the authoritative pass would let a receipt publish a
    /// lane-less snapshot, which the fence would read as "no lane is selected any more" and use to
    /// retract a live attempt and reset every consumed-epoch watermark.
    private(set) var autoWakeLanes: [AutoWakeLane] = []

    private var nextChangeSequence: UInt64 = 0
    private var lastObservedStatus: [DomainAgentSessionLinkReference: Observation] = [:]
    private var pendingByReference: [DomainAgentSessionLinkReference: PendingEntry] = [:]

    init(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        queueEpoch: UUID = UUID()
    ) {
        self.observerEndpoint = observerEndpoint
        self.queueEpoch = queueEpoch
    }

    var snapshot: Snapshot {
        Snapshot(
            observerEndpoint: observerEndpoint,
            queueEpoch: queueEpoch,
            queueRevision: queueRevision,
            linkSetRevision: linkSetRevision,
            isEnabled: isEnabled,
            isDeliverable: isEnabled && isDeliverable,
            entries: orderedPendingEntries,
            unacknowledgedOverflowCount: overflowProduced - overflowAcknowledged,
            overflowProduced: overflowProduced,
            autoWakeLanes: autoWakeLanes
        )
    }

    /// Replaces the Auto-wake membership carried by every subsequent snapshot of this reducer.
    mutating func setAutoWakeLanes(_ lanes: [AutoWakeLane]) {
        autoWakeLanes = lanes
    }

    /// Starts collecting and silently baselines the current authoritative target states.
    ///
    /// `isEnabled` is an internal "this exact endpoint currently has collectable direct links"
    /// invariant, not a user preference: collection is an always-on property of a live, eligible
    /// direct oversight relationship.
    mutating func enable(
        samples: [Sample],
        linkSetRevision: UInt64,
        deliverable: Bool = true,
        observedAt: Date = Date()
    ) {
        guard !samples.isEmpty else {
            invalidateLastLink(linkSetRevision: linkSetRevision)
            return
        }

        if isEnabled {
            reconcile(
                samples: samples,
                linkSetRevision: linkSetRevision,
                deliverable: deliverable,
                observedAt: observedAt
            )
            return
        }

        isEnabled = true
        isDeliverable = deliverable
        self.linkSetRevision = linkSetRevision
        pendingByReference.removeAll()
        lastObservedStatus = baselines(from: samples)
        advanceQueueRevision()
    }

    /// Disables delivery immediately and discards all observer-local queue state.
    mutating func disable(linkSetRevision: UInt64) {
        let changed = isEnabled
            || isDeliverable
            || self.linkSetRevision != linkSetRevision
            || !lastObservedStatus.isEmpty
            || !pendingByReference.isEmpty
            || overflowProduced != overflowAcknowledged

        isEnabled = false
        isDeliverable = false
        self.linkSetRevision = linkSetRevision
        lastObservedStatus.removeAll()
        pendingByReference.removeAll()
        overflowAcknowledged = overflowProduced

        if changed {
            advanceQueueRevision()
        }
    }

    /// Reconciles one full authoritative target sample set.
    ///
    /// New references and references returning from `unavailable` are baselined. When delivery is
    /// temporarily unavailable, all current targets are continuously rebaselined and no history is
    /// accumulated.
    mutating func reconcile(
        samples: [Sample],
        linkSetRevision: UInt64,
        deliverable: Bool,
        observedAt: Date = Date()
    ) {
        guard isEnabled else {
            if self.linkSetRevision != linkSetRevision {
                self.linkSetRevision = linkSetRevision
                advanceQueueRevision()
            }
            return
        }
        guard !samples.isEmpty else {
            invalidateLastLink(linkSetRevision: linkSetRevision)
            return
        }

        if !deliverable || !isDeliverable {
            let newBaselines = baselines(from: samples)
            let changed = self.linkSetRevision != linkSetRevision
                || isDeliverable != deliverable
                || lastObservedStatus != newBaselines
                || !pendingByReference.isEmpty
                || overflowProduced != overflowAcknowledged
            self.linkSetRevision = linkSetRevision
            isDeliverable = deliverable
            lastObservedStatus = newBaselines
            pendingByReference.removeAll()
            overflowAcknowledged = overflowProduced
            if changed {
                advanceQueueRevision()
            }
            return
        }

        var changed = self.linkSetRevision != linkSetRevision
        self.linkSetRevision = linkSetRevision

        let currentByReference = samplesByReference(samples)
        let currentReferences = Set(currentByReference.keys)
        let removedReferences = Set(lastObservedStatus.keys).subtracting(currentReferences)
            .union(Set(pendingByReference.keys).subtracting(currentReferences))
        if !removedReferences.isEmpty {
            changed = true
            for reference in removedReferences {
                lastObservedStatus.removeValue(forKey: reference)
                pendingByReference.removeValue(forKey: reference)
            }
        }

        for sample in sortedSamples(currentByReference.values) {
            if sample.status == .unavailable {
                if lastObservedStatus.removeValue(forKey: sample.reference) != nil {
                    changed = true
                }
                if pendingByReference.removeValue(forKey: sample.reference) != nil {
                    changed = true
                }
                continue
            }

            guard var observation = lastObservedStatus[sample.reference] else {
                lastObservedStatus[sample.reference] = Observation(sample: sample)
                changed = true
                continue
            }

            guard observation.targetEndpoint == sample.targetEndpoint,
                  observation.targetSessionID == sample.targetSessionID
            else {
                lastObservedStatus[sample.reference] = Observation(sample: sample)
                pendingByReference.removeValue(forKey: sample.reference)
                changed = true
                continue
            }

            guard observation.status != sample.status else {
                // Same status: the pending edge is unchanged, but the metadata a reader would triage
                // from may have settled after it. Refresh it in place — preserving the edge and its
                // timestamp — and advance the sequence so a receipt rendered before the refresh can
                // no longer clear it.
                guard let entry = pendingByReference[sample.reference],
                      !entry.hasSameFinalMetadata(as: sample)
                else { continue }
                nextChangeSequence += 1
                pendingByReference[sample.reference] = entry.refreshed(
                    from: sample,
                    observedAt: observedAt,
                    changeSequence: nextChangeSequence
                )
                changed = true
                continue
            }

            let precedingStatus = observation.status
            observation.status = sample.status
            lastObservedStatus[sample.reference] = observation
            changed = true

            // First-to-final coalescing: the origin of the still-pending interval outlives every
            // intermediate edge, so `running → waiting → idle` is delivered as `running → idle`
            // rather than losing the fact that the target had been working.
            let originStatus = pendingByReference[sample.reference]?.fromStatus ?? precedingStatus
            guard originStatus != sample.status,
                  isActionableTransition(from: originStatus, to: sample.status)
            else {
                // Net reversion, or a net edge that was never worth a turn.
                pendingByReference.removeValue(forKey: sample.reference)
                continue
            }

            nextChangeSequence += 1
            pendingByReference[sample.reference] = PendingEntry(
                reference: sample.reference,
                targetEndpoint: sample.targetEndpoint,
                targetSessionID: sample.targetSessionID,
                displayName: sample.displayName,
                fromStatus: originStatus,
                toStatus: sample.status,
                observedAt: observedAt,
                idleForSend: sample.idleForSend,
                idleSince: sample.idleSince,
                waitingOn: sample.waitingOn,
                latestVisibleAssistantPreview: sample.latestVisibleAssistantPreview,
                changeSequence: nextChangeSequence,
                // A status edge, so this *is* a new occurrence: the wake fingerprint must not compare
                // equal to the one a previous, already-settled edge of the same shape produced.
                edgeSequence: nextChangeSequence
            )
        }

        let overflowCount = enforcePendingBound()
        if overflowCount > 0 {
            overflowProduced += UInt64(overflowCount)
            changed = true
        }

        if changed {
            advanceQueueRevision()
        }
    }

    /// Applies an accepted provider receipt monotonically within this reducer's queue epoch.
    mutating func apply(_ receipt: Receipt) {
        guard receipt.queueEpoch == queueEpoch,
              receipt.queueRevision > lastAcceptedReceiptRevision,
              receipt.queueRevision <= queueRevision
        else { return }

        lastAcceptedReceiptRevision = receipt.queueRevision

        for delivered in receipt.deliveredStatuses {
            guard let current = pendingByReference[delivered.reference],
                  current.toStatus == delivered.toStatus,
                  current.changeSequence <= delivered.changeSequence
            else { continue }
            pendingByReference.removeValue(forKey: delivered.reference)
        }

        overflowAcknowledged = max(
            overflowAcknowledged,
            min(receipt.overflowProducedThrough, overflowProduced)
        )
        advanceQueueRevision()
    }

    private var orderedPendingEntries: [PendingEntry] {
        pendingByReference.values.sorted(by: Self.entryPrecedes)
    }

    private mutating func invalidateLastLink(linkSetRevision: UInt64) {
        disable(linkSetRevision: linkSetRevision)
    }

    private mutating func advanceQueueRevision() {
        queueRevision += 1
    }

    private func baselines(from samples: [Sample]) -> [DomainAgentSessionLinkReference: Observation] {
        var result: [DomainAgentSessionLinkReference: Observation] = [:]
        for sample in sortedSamples(samples) where sample.status != .unavailable {
            result[sample.reference] = Observation(sample: sample)
        }
        return result
    }

    private func samplesByReference(
        _ samples: [Sample]
    ) -> [DomainAgentSessionLinkReference: Sample] {
        var result: [DomainAgentSessionLinkReference: Sample] = [:]
        for sample in sortedSamples(samples) {
            result[sample.reference] = sample
        }
        return result
    }

    private func sortedSamples(_ samples: some Sequence<Sample>) -> [Sample] {
        samples.sorted {
            let leftTarget = $0.targetSessionID.uuidString
            let rightTarget = $1.targetSessionID.uuidString
            if leftTarget != rightTarget {
                return leftTarget < rightTarget
            }
            let leftLink = $0.reference.linkID.uuidString
            let rightLink = $1.reference.linkID.uuidString
            if leftLink != rightLink {
                return leftLink < rightLink
            }
            if $0.reference.generation != $1.reference.generation {
                return $0.reference.generation < $1.reference.generation
            }
            return $0.status.rawValue < $1.status.rawValue
        }
    }

    private func isActionableTransition(from: Status, to: Status) -> Bool {
        (from == .running && to == .idle)
            || (to == .waiting && from != .unavailable)
            || (from == .waiting && to == .idle)
    }

    private mutating func enforcePendingBound() -> Int {
        let overflowCount = max(0, pendingByReference.count - Self.maximumPendingTargetCount)
        guard overflowCount > 0 else { return 0 }
        for entry in orderedPendingEntries.prefix(overflowCount) {
            pendingByReference.removeValue(forKey: entry.reference)
        }
        return overflowCount
    }

    private static func entryPrecedes(_ lhs: PendingEntry, _ rhs: PendingEntry) -> Bool {
        if lhs.changeSequence != rhs.changeSequence {
            return lhs.changeSequence < rhs.changeSequence
        }
        return lhs.targetSessionID.uuidString < rhs.targetSessionID.uuidString
    }
}
