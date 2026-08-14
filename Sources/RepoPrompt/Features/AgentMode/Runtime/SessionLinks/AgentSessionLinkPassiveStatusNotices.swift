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

    struct Sample: Hashable {
        let reference: DomainAgentSessionLinkReference
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let targetSessionID: UUID
        let displayName: String?
        let status: Status

        init(
            reference: DomainAgentSessionLinkReference,
            targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
            targetSessionID: UUID,
            displayName: String?,
            status: Status
        ) {
            self.reference = reference
            self.targetEndpoint = targetEndpoint
            self.targetSessionID = targetSessionID
            self.displayName = DomainAgentSessionLinkTextBudget.normalized(
                displayName,
                maxBytes: DomainAgentSessionLinkTextBudget.displayNameMaxBytes
            )
            self.status = status
        }
    }

    struct PendingEntry: Hashable {
        let reference: DomainAgentSessionLinkReference
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let targetSessionID: UUID
        let displayName: String?
        let fromStatus: Status
        let toStatus: Status
        let changeSequence: UInt64
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

        /// Whether this snapshot has anything worth putting in front of the agent.
        ///
        /// Overflow alone qualifies: "changes happened that you will never see the detail of" is the
        /// one honest thing the queue can say once it has dropped entries, and withholding it until
        /// some unrelated entry arrives would leave the count permanently unacknowledged.
        var hasDeliverableContent: Bool {
            !entries.isEmpty || unacknowledgedOverflowCount > 0
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
            overflowProduced: overflowProduced
        )
    }

    /// Enables passive notices and silently baselines the current authoritative target states.
    mutating func enable(
        samples: [Sample],
        linkSetRevision: UInt64,
        deliverable: Bool = true
    ) {
        guard !samples.isEmpty else {
            invalidateLastLink(linkSetRevision: linkSetRevision)
            return
        }

        if isEnabled {
            reconcile(
                samples: samples,
                linkSetRevision: linkSetRevision,
                deliverable: deliverable
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
        deliverable: Bool
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

            guard observation.status != sample.status else { continue }

            let precedingStatus = observation.status
            observation.status = sample.status
            lastObservedStatus[sample.reference] = observation
            changed = true

            if isActionableTransition(from: precedingStatus, to: sample.status) {
                nextChangeSequence += 1
                pendingByReference[sample.reference] = PendingEntry(
                    reference: sample.reference,
                    targetEndpoint: sample.targetEndpoint,
                    targetSessionID: sample.targetSessionID,
                    displayName: sample.displayName,
                    fromStatus: precedingStatus,
                    toStatus: sample.status,
                    changeSequence: nextChangeSequence
                )
            } else if pendingByReference[sample.reference]?.toStatus != sample.status {
                pendingByReference.removeValue(forKey: sample.reference)
            }
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
