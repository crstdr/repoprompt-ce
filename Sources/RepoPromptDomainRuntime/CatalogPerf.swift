import Foundation
import os

/// Process-wide, bounded measurements; no workspace data or identifiers are logged.
package final class CatalogPerf: @unchecked Sendable {
    package static let shared = CatalogPerf()
    private static let logger = Logger(subsystem: "com.pvncher.repoprompt.ce", category: "CatalogPerf")
    private let lock = NSLock()
    #if DEBUG
        private var suppressAutomaticEmission = false
        private var emissionObservers: [UUID: @Sendable (WindowRecords?) -> Void] = [:]

        package final class EmissionObservation: Sendable {
            private let owner: CatalogPerf
            private let id: UUID

            fileprivate init(owner: CatalogPerf, id: UUID) {
                self.owner = owner
                self.id = id
            }

            package func cancel() {
                owner.removeEmissionObserver(id)
            }

            deinit { cancel() }
        }

        /// Observes completed emission rotations. The lease unregisters on cancellation or release.
        package func observeEmissionsForTesting(
            _ observer: @escaping @Sendable (WindowRecords?) -> Void
        ) -> EmissionObservation {
            let id = UUID()
            lock.lock()
            emissionObservers[id] = observer
            lock.unlock()
            return EmissionObservation(owner: self, id: id)
        }

        private func removeEmissionObserver(_ id: UUID) {
            lock.lock()
            emissionObservers.removeValue(forKey: id)
            lock.unlock()
        }

        package func setSuppressAutomaticEmissionForTesting(_ suppress: Bool) {
            lock.lock()
            suppressAutomaticEmission = suppress
            lock.unlock()
        }
    #endif
    private var attribution = CatalogAttributionWindow()
    private var activity = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds
    private var heartbeatSampleMS: Double = 0
    private var maxLatenessMS: Double = 0
    private var gapsOver16 = 0
    private var gapsOver100 = 0
    private var gapsAtLeast250 = 0
    private var presentationReceivers: [UUID: Bool] = [:]
    private var presentationCounts: [PresentationEvent: Int] = [:]

    package enum PresentationEvent: String, Sendable {
        case build, apply, deferred, catchUp
    }

    /// Receiver counts describe participants in this log window, not all open NSWindows.
    package func presentation(receiver: UUID, visible: Bool, event: PresentationEvent) {
        lock.lock()
        activity += 1
        presentationReceivers[receiver] = visible
        presentationCounts[event, default: 0] += 1
        lock.unlock()
    }

    private var receivers: [UUID: Int] = [:]
    private var fullReceipts = 0
    private var metadataReceipts = 0
    private var applications = 0
    private var fullReconciliations = 0
    private var applicationSumMS: Double = 0
    private var applicationMaxMS: Double = 0
    private var publications: [String: Int] = [:]
    private var canonicalDecodes = 0
    private var decodeHits = 0
    private var decodeBytesHashed = 0
    private var documentBytesHashed = 0
    private var preparation = Timing()
    private var persistence = Timing()
    private var analyticsSeed = Timing()
    private var seedProjections = 0
    private var seedProjectionsMax = 0

    private struct Timing {
        var count = 0
        var sumMS: Double = 0
        var maxMS: Double = 0
        var maxBytes = 0
        var mainThreadCount = 0

        mutating func record(ms: Double, bytes: Int, onMainThread: Bool) {
            count += 1
            sumMS += ms
            maxMS = max(maxMS, ms)
            maxBytes = max(maxBytes, bytes)
            if onMainThread { mainThreadCount += 1 }
        }
    }

    package init() {}

    package func recordActivity() {
        lock.lock()
        activity += 1
        lock.unlock()
    }

    package func receipt(receiver: UUID, full: Bool) {
        lock.lock()
        activity += 1
        if full {
            fullReceipts += 1
            receivers[receiver, default: 0] += 1
        } else {
            metadataReceipts += 1
            receivers[receiver, default: 0] += 0
        }
        lock.unlock()
    }

    package func application(elapsedMS: Double, full: Bool) {
        lock.lock()
        activity += 1
        applications += 1
        if full { fullReconciliations += 1 }
        applicationSumMS += elapsedMS
        applicationMaxMS = max(applicationMaxMS, elapsedMS)
        attribution.phase(.application, elapsedMS: elapsedMS)
        lock.unlock()
    }

    package func saveSource(_ source: CatalogSaveSourceCategory) {
        lock.lock()
        attribution.source(source)
        lock.unlock()
    }

    package func metadataGateFailure(_ reason: CatalogMetadataGateFailure) {
        lock.lock()
        attribution.failure(reason)
        lock.unlock()
    }

    package func receiverPhase(_ phase: CatalogReceiverPhase, elapsedMS: Double) {
        lock.lock()
        attribution.phase(phase, elapsedMS: elapsedMS)
        lock.unlock()
    }

    package func eventPair(_ outcome: CatalogEventPairOutcome) {
        lock.lock()
        attribution.pair(outcome)
        lock.unlock()
    }

    package func publication(_ kind: DomainWorkspaceEventKind) {
        lock.lock()
        activity += 1
        publications[kind.rawValue, default: 0] += 1
        lock.unlock()
    }

    package func canonicalDecode(bytesHashed: Int, cacheHit: Bool) {
        lock.lock()
        activity += 1
        decodeBytesHashed += bytesHashed
        if cacheHit { decodeHits += 1 } else { canonicalDecodes += 1 }
        lock.unlock()
    }

    package func documentHash(bytes: Int) {
        lock.lock()
        activity += 1
        documentBytesHashed += bytes
        lock.unlock()
    }

    package func writerPreparation(ms: Double, bytes: Int, onMainThread: Bool) {
        lock.lock()
        activity += 1
        preparation.record(ms: ms, bytes: bytes, onMainThread: onMainThread)
        lock.unlock()
    }

    package func writerPersistence(ms: Double, onMainThread: Bool) {
        lock.lock()
        activity += 1
        persistence.record(ms: ms, bytes: 0, onMainThread: onMainThread)
        lock.unlock()
    }

    /// Measures elapsed time from analytics collection through synchronous seed finalization.
    package func transcriptAnalyticsSeed(ms: Double, projections: Int) {
        lock.lock()
        analyticsSeed.record(ms: ms, bytes: 0, onMainThread: Thread.isMainThread)
        seedProjections += projections
        seedProjectionsMax = max(seedProjectionsMax, projections)
        lock.unlock()
    }

    package func heartbeat(gapMS: Double, expectedMS: Double) {
        lock.lock()
        heartbeatSampleMS += gapMS
        maxLatenessMS = max(maxLatenessMS, max(0, gapMS - expectedMS))
        if gapMS > 16 { gapsOver16 += 1 }
        if gapMS > 100 { gapsOver100 += 1 }
        if gapMS >= 250 { gapsAtLeast250 += 1 }
        lock.unlock()
    }

    package struct WindowRecords: Sendable {
        package let core: String
        package let analyticsSeed: String

        package var records: [String] {
            [core, analyticsSeed]
        }
    }

    /// Compatibility view of core/analytics; emission also includes optional attribution.
    package func rotate() -> String? {
        rotateRecords()?.records.joined(separator: " ")
    }

    /// A sample can straddle a rotation boundary; splitting one observation is acceptable.
    package func rotateRecords() -> WindowRecords? {
        rotateEmissionRecords().records
    }

    /// One boundary for both records; attribution alone never forces an ordinary core line.
    package func rotateEmissionRecords() -> (records: WindowRecords?, attribution: String?) {
        lock.lock()
        let attributionWindow = attribution
        attribution = CatalogAttributionWindow()
        let now = DispatchTime.now().uptimeNanoseconds
        let durationMS = Double(now - windowStart) / 1_000_000
        let activity = activity, sampleMS = heartbeatSampleMS, maxLate = maxLatenessMS
        let over16 = gapsOver16, over100 = gapsOver100, receivers = receivers
        let over250 = gapsAtLeast250, displayReceivers = presentationReceivers, displayCounts = presentationCounts
        let full = fullReceipts, metadata = metadataReceipts, applications = applications
        let reconciliations = fullReconciliations, appSum = applicationSumMS, appMax = applicationMaxMS
        let publications = publications, decodes = canonicalDecodes, hits = decodeHits
        let decodeBytes = decodeBytesHashed, documentBytes = documentBytesHashed
        let prep = preparation, write = persistence, analytics = analyticsSeed
        let projections = seedProjections, projectionsMax = seedProjectionsMax
        windowStart = now
        self.activity = 0
        heartbeatSampleMS = 0
        maxLatenessMS = 0
        gapsOver16 = 0
        gapsOver100 = 0
        gapsAtLeast250 = 0
        presentationReceivers = [:]
        presentationCounts = [:]
        self.receivers = [:]
        fullReceipts = 0
        metadataReceipts = 0
        self.applications = 0
        fullReconciliations = 0
        applicationSumMS = 0
        applicationMaxMS = 0
        self.publications = [:]
        canonicalDecodes = 0
        decodeHits = 0
        decodeBytesHashed = 0
        documentBytesHashed = 0
        preparation = Timing()
        persistence = Timing()
        analyticsSeed = Timing()
        seedProjections = 0
        seedProjectionsMax = 0
        lock.unlock()
        // Ordinary idle windows stay silent. A >=250ms heartbeat gap reports independently of
        // catalog/presentation activity.
        let detail = attributionWindow.record()
        guard activity > 0 || analytics.count > 0 || over250 > 0 else { return (nil, detail) }
        func ms(_ value: Double) -> String {
            String(format: "%.3f", value)
        }
        let publicationSummary = publications.keys.sorted().map { "\($0):\(publications[$0] ?? 0)" }.joined(separator: ",")
        let catalog = "activity=\(activity) window_ms=\(ms(durationMS)) heartbeat_sample_ms=\(ms(sampleMS)) heartbeat_max_late_ms=\(ms(maxLate)) heartbeat_gaps_gt16=\(over16) heartbeat_gaps_gt100=\(over100) receivers=\(receivers.count) receipts_full=\(full) receipts_metadata=\(metadata) receivers_full=\(receivers.values.count(where: { $0 > 0 })) receiver_full_max=\(receivers.values.max() ?? 0) applications_attempted=\(applications) reconciliations_full_attempted=\(reconciliations) application_sum_ms=\(ms(appSum)) application_max_ms=\(ms(appMax))"
        let writer = "prep_count=\(prep.count) prep_sum_ms=\(ms(prep.sumMS)) prep_max_ms=\(ms(prep.maxMS)) prep_max_bytes=\(prep.maxBytes) prep_main_thread=\(prep.mainThreadCount) write_count=\(write.count) write_sum_ms=\(ms(write.sumMS)) write_max_ms=\(ms(write.maxMS)) write_main_thread=\(write.mainThreadCount)"
        let display = "presentation_receivers_visible=\(displayReceivers.values.count(where: { $0 })) presentation_receivers_hidden=\(displayReceivers.values.count(where: { !$0 })) presentation_builds_attempted=\(displayCounts[.build, default: 0]) presentation_applies=\(displayCounts[.apply, default: 0]) presentation_deferrals=\(displayCounts[.deferred, default: 0]) presentation_catchups=\(displayCounts[.catchUp, default: 0]) heartbeat_gaps_ge250=\(over250)"
        let transcript = "analytics_seed_count=\(analytics.count) analytics_seed_sum_ms=\(ms(analytics.sumMS)) analytics_seed_max_ms=\(ms(analytics.maxMS)) analytics_seed_main_thread=\(analytics.mainThreadCount) seed_projections=\(projections) seed_projections_max=\(projectionsMax)"
        let core = "\(catalog) \(display) publications=\(publicationSummary.isEmpty ? "-" : publicationSummary) canonical_decodes=\(decodes) decode_cache_hits=\(hits) decode_bytes_hashed=\(decodeBytes) document_bytes_hashed=\(documentBytes) \(writer)"
        return (WindowRecords(core: core, analyticsSeed: transcript), detail)
    }

    package func emitWindow() {
        #if DEBUG
            lock.lock()
            let suppressed = suppressAutomaticEmission
            lock.unlock()
            if suppressed { return }
        #endif
        let emission = rotateEmissionRecords()
        let rotation = emission.records
        if let rotation {
            for record in rotation.records {
                Self.logger.notice("\(record, privacy: .public)")
            }
        }
        if let detail = emission.attribution {
            Self.logger.notice("\(detail, privacy: .public)")
        }
        #if DEBUG
            lock.lock()
            let observers = Array(emissionObservers.values)
            lock.unlock()
            for observer in observers {
                observer(rotation)
            }
        #endif
    }
}
