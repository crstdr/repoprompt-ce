import Foundation
import os

/// Process-wide, bounded measurements; no workspace data or identifiers are logged.
package final class CatalogPerf: @unchecked Sendable {
    package static let shared = CatalogPerf()
    private static let logger = Logger(subsystem: "com.pvncher.repoprompt.ce", category: "CatalogPerf")
    private let lock = NSLock()
    #if DEBUG
        private var suppressAutomaticEmission = false

        package func setSuppressAutomaticEmissionForTesting(_ suppress: Bool) {
            lock.lock()
            suppressAutomaticEmission = suppress
            lock.unlock()
        }
    #endif
    private var activity = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds
    private var heartbeatSampleMS: Double = 0
    private var maxLatenessMS: Double = 0
    private var gapsOver16 = 0
    private var gapsOver100 = 0
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

    package func heartbeat(gapMS: Double, expectedMS: Double) {
        lock.lock()
        heartbeatSampleMS += gapMS
        maxLatenessMS = max(maxLatenessMS, max(0, gapMS - expectedMS))
        if gapMS > 16 { gapsOver16 += 1 }
        if gapMS > 100 { gapsOver100 += 1 }
        lock.unlock()
    }

    /// A sample can straddle a rotation boundary; splitting one observation is acceptable.
    package func rotate() -> String? {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let durationMS = Double(now - windowStart) / 1_000_000
        let activity = activity, sampleMS = heartbeatSampleMS, maxLate = maxLatenessMS
        let over16 = gapsOver16, over100 = gapsOver100, receivers = receivers
        let full = fullReceipts, metadata = metadataReceipts, applications = applications
        let reconciliations = fullReconciliations, appSum = applicationSumMS, appMax = applicationMaxMS
        let publications = publications, decodes = canonicalDecodes, hits = decodeHits
        let decodeBytes = decodeBytesHashed, documentBytes = documentBytesHashed
        let prep = preparation, write = persistence
        windowStart = now
        self.activity = 0
        heartbeatSampleMS = 0
        maxLatenessMS = 0
        gapsOver16 = 0
        gapsOver100 = 0
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
        lock.unlock()
        guard activity > 0 else { return nil }
        func ms(_ value: Double) -> String {
            String(format: "%.3f", value)
        }
        let publicationSummary = publications.keys.sorted().map { "\($0):\(publications[$0] ?? 0)" }.joined(separator: ",")
        let catalog = "activity=\(activity) window_ms=\(ms(durationMS)) heartbeat_sample_ms=\(ms(sampleMS)) heartbeat_max_late_ms=\(ms(maxLate)) heartbeat_gaps_gt16=\(over16) heartbeat_gaps_gt100=\(over100) receivers=\(receivers.count) receipts_full=\(full) receipts_metadata=\(metadata) receivers_full=\(receivers.values.count(where: { $0 > 0 })) receiver_full_max=\(receivers.values.max() ?? 0) applications_attempted=\(applications) reconciliations_full_attempted=\(reconciliations) application_sum_ms=\(ms(appSum)) application_max_ms=\(ms(appMax))"
        let writer = "prep_count=\(prep.count) prep_sum_ms=\(ms(prep.sumMS)) prep_max_ms=\(ms(prep.maxMS)) prep_max_bytes=\(prep.maxBytes) prep_main_thread=\(prep.mainThreadCount) write_count=\(write.count) write_sum_ms=\(ms(write.sumMS)) write_max_ms=\(ms(write.maxMS)) write_main_thread=\(write.mainThreadCount)"
        return "\(catalog) publications=\(publicationSummary.isEmpty ? "-" : publicationSummary) canonical_decodes=\(decodes) decode_cache_hits=\(hits) decode_bytes_hashed=\(decodeBytes) document_bytes_hashed=\(documentBytes) \(writer)"
    }

    package func emitWindow() {
        #if DEBUG
            lock.lock()
            let suppressed = suppressAutomaticEmission
            lock.unlock()
            if suppressed { return }
        #endif
        if let line = rotate() {
            Self.logger.notice("\(line, privacy: .public)")
        }
    }
}
