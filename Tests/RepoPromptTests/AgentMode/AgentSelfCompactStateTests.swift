import CryptoKit
@testable import RepoPromptApp
import XCTest

final class AgentSelfCompactStateTests: XCTestCase {
    func testNotePolicyIsByteBoundedAndPreservesBody() {
        let exact = String(repeating: "x", count: 8192)
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: exact), .valid(byteCount: 8192))
        XCTAssertEqual(
            AgentSessionSelfCompactNotePolicy.validation(of: exact + "x"),
            .tooLong(byteCount: 8193, maximum: 8192)
        )
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: " \t\r\n "), .empty)
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: "a\u{0000}b"), .invalidScalar)
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: "a\u{0085}b"), .invalidScalar)
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: "a\t\r\nb"), .valid(byteCount: 5))
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: String(repeating: "😀", count: 2048)), .valid(byteCount: 8192))

        let body = "  /compact\r\nKeep  two spaces\t😀  "
        let expected = SHA256.hash(data: Data(("agent_self.compact/v1\n" + body).utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.digest(of: body), expected)
        XCTAssertNotEqual(AgentSessionSelfCompactNotePolicy.digest(of: body), AgentSessionSelfCompactNotePolicy.digest(of: body.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func testActiveAndLatestIdempotencyHorizon() throws {
        var state = AgentSelfCompactState()
        let first = try XCTUnwrap(state.reserve(note: "first", idempotencyKey: "same").scheduledAttempt)
        XCTAssertEqual(state.reserve(note: "first", idempotencyKey: "same"), .duplicate(first.id))
        XCTAssertEqual(state.reserve(note: "changed", idempotencyKey: "same"), .conflict)
        XCTAssertEqual(state.reserve(note: "second", idempotencyKey: "other"), .alreadyPending)
        state.settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
        XCTAssertNil(state.active)
        XCTAssertEqual(state.reserve(note: "first", idempotencyKey: "same"), .duplicate(first.id))
        XCTAssertEqual(state.reserve(note: "changed", idempotencyKey: "same"), .conflict)
        let second = try XCTUnwrap(state.reserve(note: "second", idempotencyKey: "other").scheduledAttempt)
        XCTAssertNotEqual(second.id, first.id)
        state.settle(.failed, noteDelivery: .notSent, completionVerified: false)
        // The contract intentionally retains only the active and latest keys.
        XCTAssertNotNil(state.reserve(note: "first", idempotencyKey: "same").scheduledAttempt)
    }

    func testColdDecodeConvertsEveryRestoredPhaseIncludingParkedToNonExecutingRecovery() throws {
        for phase in AgentSelfCompactAttempt.Phase.allCases {
            var session = AgentSession(name: "Cold", autoEditEnabled: true)
            var state = AgentSelfCompactState()
            let attempt = try XCTUnwrap(state.reserve(note: "verbatim\n  note", idempotencyKey: "key").scheduledAttempt)
            state.active?.phase = phase
            if phase == .dispatchingNote { state.active?.noteDispatchStarted = true }
            session.selfCompactState = state
            let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
            XCTAssertNil(restored.selfCompactState?.active, "\(phase)")
            XCTAssertEqual(restored.selfCompactState?.latest?.outcome, .recoveryRequired, "\(phase)")
            XCTAssertEqual(restored.selfCompactState?.latest?.requestID, attempt.id, "\(phase)")
            XCTAssertEqual(restored.selfCompactState?.status?.recoveryNote, "verbatim\n  note", "\(phase)")
            let expectedDelivery: AgentSelfCompactSettlement.NoteDelivery = switch phase {
            case .parked: .parked
            case .dispatchingNote: .deliveryUnknown
            default: .notSent
            }
            XCTAssertEqual(restored.selfCompactState?.status?.noteDelivery, expectedDelivery, "\(phase)")
            XCTAssertTrue(restored.selfCompactNeedsRecoveryRewrite, "\(phase)")
        }
    }

    func testColdRestoreDistinguishesPreparedNoteFromTransportAttempt() throws {
        var session = AgentSession(name: "Prepared", autoEditEnabled: true)
        var state = AgentSelfCompactState()
        _ = state.reserve(note: "recover", idempotencyKey: "prepared")
        state.active?.phase = .dispatchingNote
        state.active?.noteDispatchStarted = false
        session.selfCompactState = state
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.selfCompactState?.latest?.noteDelivery, .notSent)
        XCTAssertEqual(restored.selfCompactState?.latest?.recoveryNote, "recover")
    }

    func testMalformedOptionalRecordsDoNotDiscardSession() throws {
        let base = try JSONEncoder().encode(AgentSession(name: "Still here", autoEditEnabled: true))
        for malformed in [
            "{\"unknown\":true}",
            "{\"version\":99,\"active\":{}}",
            "{\"version\":1,\"active\":{\"note\":42,\"phase\":\"scheduled\"}}",
            "{\"version\":1,\"active\":{\"note\":\"\(String(repeating: "x", count: 8193))\",\"phase\":\"parked\"}}"
        ] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: base) as? [String: Any])
            object["selfCompactState"] = try JSONSerialization.jsonObject(with: Data(malformed.utf8))
            let restored = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(restored.name, "Still here")
            XCTAssertNil(restored.selfCompactState?.active)
            XCTAssertTrue(restored.selfCompactPersistenceWarning)
            XCTAssertEqual(restored.selfCompactState?.latest?.outcome, .recoveryRequired)
        }
    }

    func testColdRestorePreservesUnknownNoteDeliveryWithoutRetry() throws {
        var session = AgentSession(name: "Ambiguous", autoEditEnabled: true)
        var state = AgentSelfCompactState()
        let attempt = try XCTUnwrap(state.reserve(note: "exact body", idempotencyKey: "same").scheduledAttempt)
        state.active?.phase = .dispatchingNote
        state.active?.noteDispatchStarted = true
        session.selfCompactState = state

        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertNil(restored.selfCompactState?.active)
        XCTAssertEqual(restored.selfCompactState?.latest?.outcome, .recoveryRequired)
        XCTAssertEqual(restored.selfCompactState?.latest?.noteDelivery, .deliveryUnknown)
        XCTAssertEqual(restored.selfCompactState?.latest?.recoveryNote, "exact body")
        var retry = try XCTUnwrap(restored.selfCompactState)
        XCTAssertEqual(retry.reserve(note: "exact body", idempotencyKey: "same"), .duplicate(attempt.id))
    }

    func testMalformedRecordIsBackedUpBeforeRepair() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-compact-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = AgentSession(name: "Preserve source", autoEditEnabled: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object["selfCompactState"] = ["version": 99, "note": "original recovery bytes"]
        let original = try JSONSerialization.data(withJSONObject: object)
        let fileURL = directory.appendingPathComponent("AgentSession-\(session.id.uuidString).json")
        try original.write(to: fileURL)

        let loaded = try await AgentSessionDataService().loadAgentSession(from: fileURL)
        XCTAssertEqual(loaded.name, "Preserve source")
        XCTAssertTrue(loaded.selfCompactPersistenceWarning)
        XCTAssertEqual(loaded.selfCompactState?.latest?.outcome, .recoveryRequired)
        let backupDirectory = directory.appendingPathComponent(".self-compact-recovery")
        let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        let repaired = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
        XCTAssertFalse(repaired.selfCompactPersistenceWarning)
        XCTAssertEqual(repaired.selfCompactState?.latest?.outcome, .recoveryRequired)
    }

    func testRepeatedMaximumSizeRetryHasBoundedCost() throws {
        let note = String(repeating: "😀", count: 2048)
        var state = AgentSelfCompactState()
        let first = try XCTUnwrap(state.reserve(note: note, idempotencyKey: "retry").scheduledAttempt)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0 ..< 1000 {
            XCTAssertEqual(state.reserve(note: note, idempotencyKey: "retry"), .duplicate(first.id))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
        XCTAssertEqual(state.active?.note, note)
    }
}

private extension AgentSelfCompactState.Reservation {
    var scheduledAttempt: AgentSelfCompactAttempt? {
        if case let .scheduled(attempt) = self { return attempt }
        return nil
    }
}
