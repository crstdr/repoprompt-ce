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
        for field in ["presentation_receivers_visible=1", "presentation_receivers_hidden=1",
                      "presentation_builds_attempted=1", "presentation_applies=1",
                      "presentation_deferrals=1", "heartbeat_gaps_ge250=2"] {
            XCTAssertTrue(line.contains(field), field)
        }
        XCTAssertNil(perf.rotate())
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
