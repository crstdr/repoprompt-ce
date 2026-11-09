import CryptoKit
import Foundation
import RepoPromptDomainRuntime
import XCTest

final class CatalogPerfTests: XCTestCase {
    func testReceiptOverheadDiagnostic() {
        let perf = CatalogPerf()
        let receiver = UUID()
        let events = 100_000
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0 ..< events {
            perf.receipt(receiver: receiver, full: true)
            if index % 1000 == 999 { _ = perf.rotate() }
        }
        let eventNS = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(events)
        let bytes = Data(repeating: 42, count: 1_000_000)
        let hashes = 100
        var checksum: UInt8 = 0
        let hashStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< hashes {
            checksum &+= Array(SHA256.hash(data: bytes))[0]
        }
        let hashNS = Double(DispatchTime.now().uptimeNanoseconds - hashStart) / Double(hashes)
        print("CatalogPerf benchmark receipt_with_rotation_ns=\(eventNS) sha256_1mb_ns=\(hashNS) ratio=\(eventNS / hashNS) checksum=\(checksum)")
        XCTAssertLessThan(eventNS, hashNS, "diagnostic compares one receipt with one 1 MB hash")
    }

    func testPresentationCountsAndHeartbeatThresholdRotateTogether() throws {
        let perf = CatalogPerf()
        let visible = UUID(), hidden = UUID()
        perf.presentation(receiver: visible, visible: true, event: .build)
        perf.presentation(receiver: visible, visible: true, event: .apply)
        perf.presentation(receiver: hidden, visible: false, event: .deferred)
        perf.heartbeat(gapMS: 249.9, expectedMS: 10)
        perf.heartbeat(gapMS: 250, expectedMS: 10)
        perf.heartbeat(gapMS: 251, expectedMS: 10)
        let line = try XCTUnwrap(perf.rotate())
        for field in [
            "presentation_receivers_visible=1",
            "presentation_receivers_hidden=1",
            "presentation_builds_attempted=1",
            "presentation_applies=1",
            "presentation_deferrals=1",
            "heartbeat_gaps_ge250=2"
        ] {
            XCTAssertTrue(line.contains(field), field)
        }
        XCTAssertNil(perf.rotate())
    }

    func testQuietLongGapEmitsAndAnalyticsSeedMeasurementsRotate() throws {
        let perf = CatalogPerf()
        perf.heartbeat(gapMS: 250, expectedMS: 10)
        let quiet = try XCTUnwrap(perf.rotate())
        XCTAssertTrue(quiet.contains("activity=0 "), quiet)
        XCTAssertTrue(quiet.contains("heartbeat_gaps_ge250=1 "), quiet)
        XCTAssertNil(perf.rotate())
        perf.transcriptAnalyticsSeed(ms: 2, projections: 16)
        perf.transcriptAnalyticsSeed(ms: 3, projections: 32)
        let rotation = try XCTUnwrap(perf.rotateRecords())
        XCTAssertTrue(rotation.core.contains("activity=0 "), "Analytics alone must not count as catalog/presentation activity")
        let fields = Set(rotation.analyticsSeed.split(separator: " ").map(String.init))
        for field in [
            "analytics_seed_count=2 ",
            "analytics_seed_sum_ms=5.000 ",
            "analytics_seed_max_ms=3.000 ",
            "seed_projections=48 ",
            "seed_projections_max=32 "
        ] {
            XCTAssertTrue(fields.contains(field.trimmingCharacters(in: .whitespaces)), rotation.analyticsSeed)
        }
        XCTAssertNil(perf.rotate())
        perf.recordActivity()
        let reset = try XCTUnwrap(perf.rotate())
        XCTAssertTrue(reset.contains("analytics_seed_count=0 "), reset)
        XCTAssertTrue(reset.contains("seed_projections=0 "), reset)
    }

    func testBusyRotationKeepsCoreWriterFieldsWithinRecordBudget() throws {
        let perf = CatalogPerf()
        let receivers = (0 ..< 35).map { _ in UUID() }
        // Model a busy 35-owner interval, including all writer and presentation counters.
        for index in 0 ..< 350 {
            let receiver = receivers[index % receivers.count]
            perf.receipt(receiver: receiver, full: true)
            perf.application(elapsedMS: 8.125, full: true)
            perf.canonicalDecode(bytesHashed: 1_048_576, cacheHit: index % 35 != 0)
            for event: CatalogPerf.PresentationEvent in [.build, .apply, .deferred, .catchUp] {
                perf.presentation(receiver: receiver, visible: index % 35 < 2, event: event)
            }
            perf.transcriptAnalyticsSeed(ms: 16.125, projections: 32)
            perf.heartbeat(gapMS: 25, expectedMS: 10)
            if index.isMultiple(of: 35) {
                perf.publication(.workingStateCommitted)
                perf.publication(.savedDocumentCommitted)
                perf.publication(.operationDeduplicated)
                perf.documentHash(bytes: 2_097_152)
                perf.writerPreparation(ms: 1.125, bytes: 1_048_576, onMainThread: true)
                perf.writerPersistence(ms: 0.375, onMainThread: true)
            }
        }
        perf.heartbeat(gapMS: 1250, expectedMS: 10)
        let rotation = try XCTUnwrap(perf.rotateRecords())
        XCTAssertEqual(rotation.records.count, 2)
        XCTAssertFalse(rotation.core.contains("analytics_seed"))
        XCTAssertFalse(rotation.analyticsSeed.contains("write_count"))
        for field in [
            "prep_count=10 ",
            "prep_sum_ms=11.250 ",
            "prep_max_ms=1.125 ",
            "prep_max_bytes=1048576 ",
            "prep_main_thread=10 ",
            "write_count=10 ",
            "write_sum_ms=3.750 ",
            "write_max_ms=0.375 "
        ] {
            XCTAssertTrue(rotation.core.contains(field), field)
        }
        XCTAssertTrue(rotation.core.hasSuffix("write_main_thread=10"))
        XCTAssertTrue(rotation.analyticsSeed.contains("analytics_seed_count=350 "))
        XCTAssertTrue(rotation.analyticsSeed.hasSuffix("seed_projections_max=32"))
        // Reserve 64 bytes for encoding/envelope and elapsed-window-width headroom.
        // This is a conservative budget model, not an assertion about Apple's buffer layout.
        let reservedBytes = 64
        for record in rotation.records {
            XCTAssertLessThanOrEqual(record.utf8.count + reservedBytes, 1024)
        }
        XCTAssertGreaterThan(
            rotation.records.joined(separator: " ").utf8.count,
            1024,
            "The busy fixture must exercise the merged-record overflow risk"
        )
        print("CATALOG_RECORD_BUDGET core_utf8=\(rotation.core.utf8.count) analytics_utf8=\(rotation.analyticsSeed.utf8.count) reserved=64 limit=1024")
        XCTAssertNil(perf.rotateRecords(), "Both records must come from one rotation/reset")
    }

    func testTranscriptOnlyWindowDoesNotEmitLegacyRecords() throws {
        let perf = CatalogPerf()
        perf.transcriptMutationCadence(gapMS: nil)
        perf.transcriptRequestSettled(.coalesced)
        let rotation = try XCTUnwrap(perf.rotateRecords())
        let transcript = try XCTUnwrap(rotation.transcriptDerivation)
        XCTAssertEqual(rotation.records, [transcript])
        XCTAssertTrue(transcript.hasPrefix("transcript_derivation "))
        XCTAssertNil(perf.rotateRecords())
    }

    func testTranscriptDerivationBucketsAndRotationBudget() throws {
        let perf = CatalogPerf()
        perf.transcriptMutationCadence(gapMS: nil)
        for gap in [0.0, 16, 33, 100, 250, 1000] {
            perf.transcriptMutationCadence(gapMS: gap)
        }
        for outcome: CatalogPerf.TranscriptRequestDisposition in [.coalesced, .executed, .dropped] {
            perf.transcriptRequestSettled(outcome)
        }
        for (size, duration) in [(0, 1.0), (100, 4), (500, 16), (2000, 100), (5000, 500)] {
            perf.transcriptBuilder(ms: duration, retainedRows: size, path: .automatic)
        }
        let rotation = try XCTUnwrap(perf.rotateRecords())
        let record = try XCTUnwrap(rotation.transcriptDerivation)
        XCTAssertTrue(record.contains("requests=3 first=1 gaps=1,1,1,1,1,1 coalesced_executed_dropped=1,1,1"), record)
        XCTAssertTrue(record.contains("automatic_by_size=1,1,1,1,0,0,0,0/1,4,4,0,1,0,0,0/1,16,16,0,0,1,0,0/1,100,100,0,0,0,1,0/1,500,500,0,0,0,0,1 builds_by_path=5,621,500,1,1,1,1,1"), record)
        XCTAssertFalse(record.contains("activity="))
        XCTAssertLessThanOrEqual(record.utf8.count + 64, 1024)
        XCTAssertNil(perf.rotateRecords())
    }

    func testTranscriptInstrumentationOverheadDiagnostic() {
        let perf = CatalogPerf()
        let iterations = 100_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< iterations {
            perf.transcriptMutationCadence(gapMS: 10)
            perf.transcriptRequestSettled(.coalesced)
            perf.transcriptBuilder(ms: 2, retainedRows: 100, path: .automatic)
        }
        let ns = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations)
        print("TRANSCRIPT_DIAGNOSTIC three_recordings_ns=\(ns)")
    }

    func testTranscriptPathDistributionsAndSettledRequestsReconcile() throws {
        let perf = CatalogPerf()
        let paths: [CatalogPerf.TranscriptBuilderPath] = [.automatic, .catchUp, .save, .terminal, .other]
        for (index, path) in paths.enumerated() {
            perf.transcriptBuilder(ms: Double(index + 1), retainedRows: 0, path: path)
        }
        for outcome: CatalogPerf.TranscriptRequestDisposition in [.coalesced, .executed, .dropped, .dropped] {
            perf.transcriptRequestSettled(outcome)
        }
        let line = try XCTUnwrap(perf.rotateRecords()?.transcriptDerivation)
        XCTAssertTrue(line.contains("requests=4 "), line)
        XCTAssertTrue(line.contains("coalesced_executed_dropped=1,1,2"), line)
        XCTAssertTrue(line.contains("builds_by_path=1,1,1,1,0,0,0,0/1,2,2,1,0,0,0,0/1,3,3,1,0,0,0,0/1,4,4,0,1,0,0,0/1,5,5,0,1,0,0,0"), line)
    }

    #if DEBUG
        func testEmissionObservationsAreScopedAndInstanceLocal() throws {
            let perf = CatalogPerf(), other = CatalogPerf()
            let firstCapture = CatalogPerfEmissionCapture(), secondCapture = CatalogPerfEmissionCapture()
            let otherCapture = CatalogPerfEmissionCapture()
            var first: CatalogPerf.EmissionObservation? = perf.observeEmissionsForTesting { firstCapture.receive($0) }
            let second = perf.observeEmissionsForTesting { secondCapture.receive($0) }
            let otherObservation = other.observeEmissionsForTesting { otherCapture.receive($0) }
            defer { second.cancel()
                otherObservation.cancel()
            }
            perf.writerPersistence(ms: 2, onMainThread: true)
            perf.transcriptAnalyticsSeed(ms: 3, projections: 32)
            withExtendedLifetime(first) { perf.emitWindow() }
            let rotation = try XCTUnwrap(firstCapture.values.compactMap(\.self).first)
            XCTAssertEqual(rotation.records, secondCapture.values.compactMap(\.self).first?.records)
            XCTAssertTrue(rotation.core.contains("activity=1 "))
            XCTAssertTrue(rotation.core.hasSuffix("write_main_thread=1"))
            XCTAssertTrue(rotation.analyticsSeed.contains("analytics_seed_count=1 "))
            XCTAssertNil(perf.rotateRecords(), "emitWindow must rotate once for the entire record pair")
            XCTAssertTrue(otherCapture.values.isEmpty)
            first = nil // Release unregisters this observer while the second remains active.
            perf.recordActivity()
            perf.emitWindow()
            XCTAssertEqual(firstCapture.values.count, 1)
            XCTAssertEqual(secondCapture.values.count, 2)
            second.cancel()
            perf.recordActivity()
            perf.emitWindow()
            XCTAssertEqual(secondCapture.values.count, 2)
            other.emitWindow()
            XCTAssertEqual(otherCapture.values.count, 1)
            XCTAssertNil(otherCapture.values[0], "Observe a real quiet rotation even when it emits no records")
        }
    #endif

    func testPrewarmAttributionIsAbsentWhenUnusedAndDoesNotForceCoreEmission() throws {
        let perf = CatalogPerf()
        perf.receiverPhase(.hash, elapsedMS: 1)
        let off = try XCTUnwrap(perf.rotateEmissionRecords().attribution)
        XCTAssertFalse(off.contains("prewarm"))
        perf.prewarm(.started)
        perf.receiverPhase(.prewarmDecode, elapsedMS: 2)
        let on = perf.rotateEmissionRecords()
        XCTAssertNil(on.records)
        XCTAssertTrue(try XCTUnwrap(on.attribution).contains("prewarm_started=1"))
        XCTAssertNil(perf.rotateEmissionRecords().attribution)
    }

    func testAttributionIsIndependentBoundedAndResetsWithCore() throws {
        let perf = CatalogPerf()
        for _ in 0 ..< 350 {
            for source in CatalogSaveSourceCategory.allCases { perf.saveSource(source) }
            for failure in CatalogMetadataGateFailure.allCases { perf.metadataGateFailure(failure) }
            for phase in CatalogReceiverPhase.allCases where phase != .application {
                perf.receiverPhase(phase, elapsedMS: 8.125)
            }
            perf.application(elapsedMS: 8.125, full: true)
            for pair in CatalogEventPairOutcome.allCases { perf.eventPair(pair) }
            for outcome in CatalogPrewarmOutcome.allCases { perf.prewarm(outcome) }
        }
        let emitted = perf.rotateEmissionRecords()
        let core = try XCTUnwrap(emitted.records)
        let detail = try XCTUnwrap(emitted.attribution)
        XCTAssertEqual(core.records.count, 2)
        XCTAssertTrue(core.core.hasPrefix("activity=350 "))
        XCTAssertTrue(core.core.contains("application_sum_ms=2843.750 "))
        XCTAssertFalse(core.core.contains("catalog_detail"))
        XCTAssertFalse(detail.contains("activity="))
        for field in ["source_poll_save=350", "gate_digest_mismatch=350", "pair_same_digest=350"] {
            XCTAssertTrue(detail.split(separator: " ").contains(Substring(field)), detail)
        }
        for phase in CatalogReceiverPhase.allCases {
            XCTAssertTrue(detail.contains("\(phase.rawValue)_count=350 "), detail)
            XCTAssertTrue(detail.contains("\(phase.rawValue)_sum_ms=2843.750 "), detail)
            XCTAssertTrue(detail.contains("\(phase.rawValue)_max_ms=8.125"), detail)
        }
        // Fixed allowlists and numeric values only: no identities, digests, paths or content.
        XCTAssertNil(detail.range(of: #"[^a-z0-9_= .]"#, options: .regularExpression))
        // Includes the fixed prewarm outcome and two timing distributions.
        XCTAssertLessThanOrEqual(detail.utf8.count + 64, 1536)
        XCTAssertNil(perf.rotateEmissionRecords().attribution)
        XCTAssertNil(perf.rotateRecords())

        perf.saveSource(.other)
        let companionOnly = perf.rotateEmissionRecords()
        XCTAssertNil(companionOnly.records, "New counters must not force an ordinary core line")
        XCTAssertNotNil(companionOnly.attribution)
        XCTAssertNil(perf.rotateEmissionRecords().attribution)
    }

    func testEventPairsUseLastWorkingEventAndDropDeletedLineage() {
        var tracker = CatalogEventPairTracker()
        let workspace = UUID(), other = UUID()
        XCTAssertNil(tracker.observe(kind: .workingStateCommitted, workspaceID: workspace, digest: "first"))
        XCTAssertNil(tracker.observe(kind: .workingStateCommitted, workspaceID: workspace, digest: "latest"))
        XCTAssertNil(tracker.observe(kind: .operationDeduplicated, workspaceID: workspace, digest: "ignored"))
        XCTAssertEqual(tracker.observe(kind: .savedDocumentCommitted, workspaceID: workspace, digest: "latest"), .sameDigest)
        XCTAssertEqual(tracker.observe(kind: .savedDocumentCommitted, workspaceID: workspace, digest: "latest"), .savedWithoutWorking)
        _ = tracker.observe(kind: .workingStateCommitted, workspaceID: workspace, digest: "first")
        _ = tracker.observe(kind: .workingStateCommitted, workspaceID: other, digest: "other")
        XCTAssertEqual(tracker.observe(kind: .savedDocumentCommitted, workspaceID: workspace, digest: "second"), .differentDigest)
        _ = tracker.observe(kind: .workspaceDeleted, workspaceID: other, digest: nil)
        XCTAssertEqual(tracker.observe(kind: .savedDocumentCommitted, workspaceID: other, digest: "other"), .savedWithoutWorking)
    }

    func testAttributionAndDerivationCompanionsCoexistWithoutLegacyActivity() throws {
        let perf = CatalogPerf()
        perf.saveSource(.pollSave)
        perf.transcriptRequestSettled(.executed)
        let both = perf.rotateEmissionRecords()
        let records = try XCTUnwrap(both.records)
        XCTAssertEqual(records.records.count, 1)
        XCTAssertTrue(records.records[0].hasPrefix("transcript_derivation v=1 "))
        XCTAssertFalse(records.records.contains { $0.contains("activity=") || $0.contains("analytics_seed_count=") })
        let detail = try XCTUnwrap(both.attribution)
        XCTAssertTrue(detail.contains("source_poll_save=1 "))
        XCTAssertFalse(detail.contains("activity="))
        let empty = perf.rotateEmissionRecords()
        XCTAssertNil(empty.records)
        XCTAssertNil(empty.attribution)
        perf.transcriptRequestSettled(.coalesced)
        let derivationOnly = perf.rotateEmissionRecords()
        XCTAssertEqual(derivationOnly.records?.records.count, 1)
        XCTAssertNil(derivationOnly.attribution)
    }

    func testIdleWindowEmitsNothing() {
        let perf = CatalogPerf()
        perf.heartbeat(gapMS: 120, expectedMS: 10)
        XCTAssertNil(perf.rotate())
        perf.recordActivity()
        let line = perf.rotate()
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("heartbeat_gaps_gt100=0") == true)
        XCTAssertNil(perf.rotate())
    }
}

#if DEBUG
    private final class CatalogPerfEmissionCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [CatalogPerf.WindowRecords?] = []

        func receive(_ rotation: CatalogPerf.WindowRecords?) {
            lock.lock()
            captured.append(rotation)
            lock.unlock()
        }

        var values: [CatalogPerf.WindowRecords?] {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }
    }
#endif
