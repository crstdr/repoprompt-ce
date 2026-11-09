import Foundation

package enum CatalogSaveSourceCategory: String, CaseIterable, Sendable {
    case pollSave = "poll_save"
    case lifecycleAdmissionSave = "lifecycle_admission_save"
    case organizerEdit = "organizer_edit"
    case other
}

package enum CatalogMetadataGateFailure: String, CaseIterable, Sendable {
    case noAcceptedGeneration = "no_accepted_generation"
    case baselineGenerationMismatch = "baseline_generation_mismatch"
    case requiresFullReconciliation = "requires_full_reconciliation"
    case membershipMismatch = "membership_mismatch"
    case digestMismatch = "digest_mismatch"
    case adoptionWitnessMismatch = "adoption_witness_mismatch"
    case unavailableMembershipMismatch = "unavailable_membership_mismatch"
}

package enum CatalogReceiverPhase: String, CaseIterable, Sendable {
    case hash = "receiver_hash"
    case decode = "receiver_decode"
    case application = "catalog_apply"
    case carrierPublication = "carrier_publication"
}

package enum CatalogEventPairOutcome: String, CaseIterable, Sendable {
    case sameDigest = "pair_same_digest"
    case differentDigest = "pair_different_digest"
    case savedWithoutWorking = "saved_without_working"
}

/// Actor-owned provenance of the last working event before a saved event, not a disk comparison.
package struct CatalogEventPairTracker: Sendable {
    private var workingDigests: [UUID: String] = [:]

    package init() {}

    package mutating func observe(
        kind: DomainWorkspaceEventKind, workspaceID: UUID, digest: String?
    ) -> CatalogEventPairOutcome? {
        switch kind {
        case .workingStateCommitted:
            workingDigests[workspaceID] = digest
        case .savedDocumentCommitted:
            let previous = workingDigests.removeValue(forKey: workspaceID)
            guard let previous else { return .savedWithoutWorking }
            guard let digest else { return nil }
            return previous == digest ? .sameDigest : .differentDigest
        case .workspaceDeleted:
            workingDigests.removeValue(forKey: workspaceID)
        default:
            break
        }
        return nil
    }
}

/// Fixed cardinality only. CatalogPerf's lock owns this value and rotates it with the core record.
struct CatalogAttributionWindow {
    private struct Timing {
        var count = 0
        var sumMS: Double = 0
        var maxMS: Double = 0
    }

    private var sources: [CatalogSaveSourceCategory: Int] = [:]
    private var failures: [CatalogMetadataGateFailure: Int] = [:]
    private var phases: [CatalogReceiverPhase: Timing] = [:]
    private var pairs: [CatalogEventPairOutcome: Int] = [:]

    mutating func source(_ source: CatalogSaveSourceCategory) { sources[source, default: 0] += 1 }
    mutating func failure(_ reason: CatalogMetadataGateFailure) { failures[reason, default: 0] += 1 }
    mutating func pair(_ outcome: CatalogEventPairOutcome) { pairs[outcome, default: 0] += 1 }

    mutating func phase(_ phase: CatalogReceiverPhase, elapsedMS: Double) {
        // Timing inputs are diagnostic, never authority. Bound formatting even after clock/test faults.
        let elapsed = elapsedMS.isFinite ? min(600_000, max(0, elapsedMS)) : 0
        phases[phase, default: Timing()].count += 1
        phases[phase, default: Timing()].sumMS += elapsed
        phases[phase, default: Timing()].maxMS = max(phases[phase]?.maxMS ?? 0, elapsed)
    }

    func record() -> String? {
        guard !sources.isEmpty || !failures.isEmpty || !phases.isEmpty || !pairs.isEmpty else { return nil }
        // Saturate only the log representation; cardinality and numeric width stay bounded even
        // when observations accumulate without a heartbeat lease. Core counters are unaffected.
        func count(_ value: Int) -> String { String(min(9_999_999, value)) }
        func ms(_ value: Double) -> String { String(format: "%.3f", min(9_999_999.999, value)) }
        var fields = ["catalog_detail=1"]
        for source in CatalogSaveSourceCategory.allCases {
            fields.append("source_\(source.rawValue)=\(count(sources[source, default: 0]))")
        }
        for failure in CatalogMetadataGateFailure.allCases {
            fields.append("gate_\(failure.rawValue)=\(count(failures[failure, default: 0]))")
        }
        for phase in CatalogReceiverPhase.allCases {
            let timing = phases[phase] ?? Timing()
            fields.append("\(phase.rawValue)_count=\(count(timing.count))")
            fields.append("\(phase.rawValue)_sum_ms=\(ms(timing.sumMS))")
            fields.append("\(phase.rawValue)_max_ms=\(ms(timing.maxMS))")
        }
        for pair in CatalogEventPairOutcome.allCases {
            fields.append("\(pair.rawValue)=\(count(pairs[pair, default: 0]))")
        }
        return fields.joined(separator: " ")
    }
}
