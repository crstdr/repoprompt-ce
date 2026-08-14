import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class AgentSessionLinkPassiveStatusNoticeTests: XCTestCase {
    private typealias Reducer = AgentSessionLinkPassiveStatusNotices
    private typealias Status = Reducer.Status

    func testEveryLiveStatusEdgeHasTheSpecifiedDeterministicEffect() {
        struct Case {
            let from: Status
            let to: Status
            let expectedTransition: (Status, Status)?
        }

        let cases: [Case] = [
            Case(from: .idle, to: .idle, expectedTransition: nil),
            Case(from: .idle, to: .running, expectedTransition: nil),
            Case(from: .idle, to: .waiting, expectedTransition: (.idle, .waiting)),
            Case(from: .running, to: .idle, expectedTransition: (.running, .idle)),
            Case(from: .running, to: .running, expectedTransition: nil),
            Case(from: .running, to: .waiting, expectedTransition: (.running, .waiting)),
            Case(from: .waiting, to: .idle, expectedTransition: (.waiting, .idle)),
            Case(from: .waiting, to: .running, expectedTransition: nil),
            Case(from: .waiting, to: .waiting, expectedTransition: nil)
        ]

        for testCase in cases {
            var reducer = makeReducer()
            reducer.enable(samples: [sample(0, status: testCase.from)], linkSetRevision: 1)
            let baselineRevision = reducer.snapshot.queueRevision

            reducer.reconcile(
                samples: [sample(0, status: testCase.to)],
                linkSetRevision: 1,
                deliverable: true
            )

            let entries = reducer.snapshot.entries
            if let expected = testCase.expectedTransition {
                XCTAssertEqual(entries.count, 1, "\(testCase.from) -> \(testCase.to)")
                XCTAssertEqual(entries.first?.fromStatus, expected.0)
                XCTAssertEqual(entries.first?.toStatus, expected.1)
                XCTAssertGreaterThan(reducer.snapshot.queueRevision, baselineRevision)
            } else {
                XCTAssertTrue(entries.isEmpty, "\(testCase.from) -> \(testCase.to)")
                if testCase.from == testCase.to {
                    XCTAssertEqual(reducer.snapshot.queueRevision, baselineRevision)
                } else {
                    XCTAssertGreaterThan(reducer.snapshot.queueRevision, baselineRevision)
                }
            }
        }
    }

    func testEnableAndNewLinkAppearanceBaselineSilentlyAndNormalizeCapturedName() {
        var reducer = makeReducer()
        reducer.enable(
            samples: [sample(0, name: "  Build\n\tAPI  ", status: .running)],
            linkSetRevision: 1
        )
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)

        reducer.reconcile(
            samples: [
                sample(0, name: "ignored metadata change", status: .running),
                sample(1, status: .waiting)
            ],
            linkSetRevision: 2,
            deliverable: true
        )
        XCTAssertTrue(reducer.snapshot.entries.isEmpty, "A newly appearing link is a baseline")

        reducer.reconcile(
            samples: [
                sample(0, name: "  Build\n\tAPI  ", status: .idle),
                sample(1, status: .waiting)
            ],
            linkSetRevision: 2,
            deliverable: true
        )
        let entry = tryUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(entry.fromStatus, .running)
        XCTAssertEqual(entry.toStatus, .idle)
        XCTAssertFalse(entry.displayName?.contains("\n") ?? true)
        XCTAssertLessThanOrEqual(entry.displayName?.utf8.count ?? .max, 120)
    }

    func testCoalescingRetainsOnlyTheActualLatestActionableEdge() {
        var idleReducer = makeReducer()
        idleReducer.enable(samples: [sample(0, status: .idle)], linkSetRevision: 1)
        idleReducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        idleReducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        XCTAssertEqual(idleReducer.snapshot.entries.map(transition), ["waiting->idle"])

        var runningReducer = makeReducer()
        runningReducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        runningReducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        runningReducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        XCTAssertEqual(runningReducer.snapshot.entries.map(transition), ["waiting->idle"])
    }

    func testEnteringRunningClearsStaleCurrentStateAndLaterCompletionIsFresh() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .idle)], linkSetRevision: 1)
        reducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        let staleSequence = tryUnwrap(reducer.snapshot.entries.first).changeSequence

        reducer.reconcile(samples: [sample(0, status: .running)], linkSetRevision: 1, deliverable: true)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)

        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        let completion = tryUnwrap(reducer.snapshot.entries.first)
        XCTAssertEqual(transition(completion), "running->idle")
        XCTAssertGreaterThan(completion.changeSequence, staleSequence)
    }

    func testUnavailableRevocationAndEndpointReplacementDiscardStateAndRebaseline() {
        var reducer = makeReducer()
        reducer.enable(
            samples: [sample(0, status: .running), sample(1, status: .running)],
            linkSetRevision: 1
        )
        reducer.reconcile(
            samples: [sample(0, status: .idle), sample(1, status: .idle)],
            linkSetRevision: 1,
            deliverable: true
        )
        XCTAssertEqual(reducer.snapshot.entries.count, 2)

        reducer.reconcile(
            samples: [sample(0, status: .unavailable), sample(1, status: .idle)],
            linkSetRevision: 1,
            deliverable: true
        )
        XCTAssertEqual(reducer.snapshot.entries.map(\.targetSessionID), [sessionID(1)])

        reducer.reconcile(
            samples: [sample(0, status: .idle), sample(1, status: .idle)],
            linkSetRevision: 1,
            deliverable: true
        )
        XCTAssertEqual(reducer.snapshot.entries.map(\.targetSessionID), [sessionID(1)])

        reducer.reconcile(
            samples: [sample(0, status: .running, endpointGeneration: 99)],
            linkSetRevision: 2,
            deliverable: true
        )
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        reducer.reconcile(
            samples: [sample(0, status: .idle, endpointGeneration: 99)],
            linkSetRevision: 2,
            deliverable: true
        )
        XCTAssertEqual(reducer.snapshot.entries.map(transition), ["running->idle"])
    }

    func testTemporaryNondeliverabilityContinuouslyRebaselinesAndClearsBacklog() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        XCTAssertFalse(reducer.snapshot.entries.isEmpty)

        reducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: false)
        XCTAssertTrue(reducer.snapshot.isEnabled)
        XCTAssertFalse(reducer.snapshot.isDeliverable)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)

        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: false)
        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)

        reducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        XCTAssertEqual(reducer.snapshot.entries.map(transition), ["idle->waiting"])
    }

    func testPendingDetailsAreBoundedToTheSixteenMostRecentInDeterministicOrder() {
        var reducer = makeReducer()
        let baselines = (0 ..< 18).map { sample($0, status: .running) }
        reducer.enable(samples: baselines.reversed(), linkSetRevision: 1)
        reducer.reconcile(
            samples: (0 ..< 18).reversed().map { sample($0, status: .idle) },
            linkSetRevision: 1,
            deliverable: true
        )

        let snapshot = reducer.snapshot
        XCTAssertEqual(snapshot.entries.count, 16)
        XCTAssertEqual(snapshot.entries.map(\.targetSessionID), (2 ..< 18).map(sessionID))
        XCTAssertEqual(snapshot.entries.map(\.changeSequence), Array(3 ... 18).map(UInt64.init))
        XCTAssertEqual(reducer.overflowProduced, 2)
        XCTAssertEqual(reducer.overflowAcknowledged, 0)
        XCTAssertEqual(snapshot.unacknowledgedOverflowCount, 2)
        XCTAssertEqual(snapshot.overflowProduced, 2)
    }

    /// Overflow acknowledgement is a watermark, and a watermark has to be absolute.
    ///
    /// The displayed omitted count is a remainder: it shrinks as receipts land. A receipt echoing it
    /// would acknowledge only the newest cycle's shortfall, so every further cycle would strand more
    /// overflow and the envelope would keep reporting dropped changes that were already accounted for.
    /// Three cycles, because one is exactly the case a delta and a watermark agree on.
    func testRepeatedOverflowCyclesAreFullyAcknowledgedBySuccessiveReceipts() {
        var reducer = makeReducer()
        reducer.enable(samples: (0 ..< 18).map { sample($0, status: .running) }, linkSetRevision: 1)

        // Each pass moves all 18 targets across an actionable edge, so two of them always overflow
        // the sixteen-entry bound.
        for (cycle, status) in [Status.idle, .waiting, .idle].enumerated() {
            reducer.reconcile(
                samples: (0 ..< 18).map { sample($0, status: status) },
                linkSetRevision: 1,
                deliverable: true
            )
            let expectedProduced = UInt64((cycle + 1) * 2)
            let claimed = reducer.snapshot
            XCTAssertEqual(claimed.entries.count, 16, "cycle \(cycle)")
            XCTAssertEqual(claimed.overflowProduced, expectedProduced, "cycle \(cycle)")
            XCTAssertEqual(claimed.unacknowledgedOverflowCount, 2, "cycle \(cycle)")

            reducer.apply(Reducer.Receipt(snapshot: claimed))

            XCTAssertEqual(reducer.overflowAcknowledged, expectedProduced, "cycle \(cycle)")
            XCTAssertEqual(
                reducer.snapshot.unacknowledgedOverflowCount,
                0,
                "cycle \(cycle) left overflow permanently unacknowledgeable"
            )
            XCTAssertTrue(reducer.snapshot.entries.isEmpty, "cycle \(cycle)")
            XCTAssertFalse(reducer.snapshot.hasDeliverableContent, "cycle \(cycle)")
        }
    }

    /// Overflow with no surviving entry is still worth saying, and still has to be acknowledgeable.
    ///
    /// Reached whenever the queue drops changes and then loses every pending entry — here because all
    /// overseen targets stop being observable at once. Gating delivery on a nonempty entry list would
    /// leave the count owed for as long as the observer happened to see no further change.
    func testOverflowSurvivesLosingEveryEntryAndIsDeliverableOnItsOwn() {
        var reducer = overflowReducer()
        reducer.reconcile(
            samples: (0 ..< 18).map { sample($0, status: .unavailable) },
            linkSetRevision: 1,
            deliverable: true
        )

        let claimed = reducer.snapshot
        XCTAssertTrue(claimed.entries.isEmpty)
        XCTAssertEqual(claimed.unacknowledgedOverflowCount, 2)
        XCTAssertEqual(claimed.overflowProduced, 2)
        XCTAssertTrue(
            claimed.hasDeliverableContent,
            "an overflow-only snapshot is the only account the agent gets of what it missed"
        )

        reducer.apply(Reducer.Receipt(snapshot: claimed))

        XCTAssertEqual(reducer.overflowAcknowledged, 2)
        XCTAssertEqual(reducer.snapshot.unacknowledgedOverflowCount, 0)
        XCTAssertFalse(
            reducer.snapshot.hasDeliverableContent,
            "an acknowledged overflow-only batch must not be owed again"
        )
    }

    func testReceiptAcknowledgesOnlyDeliveredEntriesAndRenderedOverflow() {
        var reducer = overflowReducer()
        let claimed = reducer.snapshot
        let delivered = Array(claimed.entries.prefix(2))
        reducer.apply(Reducer.Receipt(
            snapshot: claimed,
            deliveredEntries: delivered,
            overflowProducedThrough: 1
        ))

        XCTAssertEqual(reducer.snapshot.entries.count, 14)
        XCTAssertEqual(reducer.snapshot.unacknowledgedOverflowCount, 1)
        XCTAssertEqual(reducer.snapshot.overflowProduced, 2)
        XCTAssertEqual(reducer.overflowAcknowledged, 1)
        XCTAssertEqual(reducer.lastAcceptedReceiptRevision, claimed.queueRevision)
        XCTAssertGreaterThan(reducer.snapshot.queueRevision, claimed.queueRevision)
    }

    func testInFlightReceiptPreservesNewerStatusAndOverflowProducedAfterClaim() {
        var reducer = overflowReducer()
        let claimed = reducer.snapshot
        let deliveredEntry = tryUnwrap(claimed.entries.first)

        var current = (0 ..< 18).map { sample($0, status: .idle) }
        current[0] = sample(0, status: .waiting)
        current[2] = sample(2, status: .running)
        reducer.reconcile(samples: current, linkSetRevision: 1, deliverable: true)
        current[2] = sample(2, status: .idle)
        reducer.reconcile(samples: current, linkSetRevision: 1, deliverable: true)
        XCTAssertGreaterThan(reducer.overflowProduced, claimed.unacknowledgedOverflowCount)

        reducer.apply(Reducer.Receipt(
            snapshot: claimed,
            deliveredEntries: [deliveredEntry],
            overflowProducedThrough: claimed.overflowProduced
        ))

        let currentEntry = tryUnwrap(reducer.snapshot.entries.first { $0.reference == deliveredEntry.reference })
        XCTAssertGreaterThan(currentEntry.changeSequence, deliveredEntry.changeSequence)
        XCTAssertEqual(transition(currentEntry), "running->idle")
        XCTAssertGreaterThan(reducer.snapshot.unacknowledgedOverflowCount, 0)
    }

    func testDuplicateAndOutOfOrderReceiptsAreMonotonicAndIdempotent() {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        let revisionOne = reducer.snapshot

        reducer.reconcile(samples: [sample(0, status: .waiting)], linkSetRevision: 1, deliverable: true)
        let revisionTwo = reducer.snapshot
        let receiptTwo = Reducer.Receipt(snapshot: revisionTwo)
        reducer.apply(receiptTwo)
        let afterNewestReceipt = reducer.snapshot
        XCTAssertTrue(afterNewestReceipt.entries.isEmpty)

        reducer.apply(Reducer.Receipt(snapshot: revisionOne))
        reducer.apply(receiptTwo)
        XCTAssertEqual(reducer.snapshot, afterNewestReceipt)
        XCTAssertEqual(reducer.lastAcceptedReceiptRevision, revisionTwo.queueRevision)
    }

    func testOldEpochReceiptDisableAndLastLinkRemovalCannotResurrectQueueState() throws {
        var reducer = makeReducer()
        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 1)
        reducer.reconcile(samples: [sample(0, status: .idle)], linkSetRevision: 1, deliverable: true)
        let claimed = reducer.snapshot

        try reducer.apply(Reducer.Receipt(
            queueEpoch: XCTUnwrap(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")),
            queueRevision: claimed.queueRevision,
            deliveredStatuses: claimed.entries.map(Reducer.DeliveredStatus.init),
            overflowProducedThrough: 0
        ))
        XCTAssertEqual(reducer.snapshot.entries.count, 1)

        reducer.disable(linkSetRevision: 1)
        XCTAssertFalse(reducer.snapshot.isEnabled)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        reducer.apply(Reducer.Receipt(snapshot: claimed))
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)

        reducer.enable(samples: [sample(0, status: .running)], linkSetRevision: 2)
        reducer.reconcile(samples: [], linkSetRevision: 3, deliverable: true)
        XCTAssertFalse(reducer.snapshot.isEnabled)
        XCTAssertFalse(reducer.snapshot.isDeliverable)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        XCTAssertEqual(reducer.snapshot.linkSetRevision, 3)
    }

    // MARK: - Fixtures

    private func makeReducer() -> Reducer {
        Reducer(
            observerEndpoint: endpoint(sessionID: observerSessionID, generation: 1),
            queueEpoch: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
    }

    private func overflowReducer() -> Reducer {
        var reducer = makeReducer()
        reducer.enable(
            samples: (0 ..< 18).map { sample($0, status: .running) },
            linkSetRevision: 1
        )
        reducer.reconcile(
            samples: (0 ..< 18).map { sample($0, status: .idle) },
            linkSetRevision: 1,
            deliverable: true
        )
        return reducer
    }

    private func sample(
        _ index: Int,
        name: String? = nil,
        status: Status,
        endpointGeneration: UInt64 = 1
    ) -> Reducer.Sample {
        let targetSessionID = sessionID(index)
        return Reducer.Sample(
            reference: DomainAgentSessionLinkReference(
                linkID: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!,
                generation: 1
            ),
            targetEndpoint: endpoint(sessionID: targetSessionID, generation: endpointGeneration),
            targetSessionID: targetSessionID,
            displayName: name ?? "Target \(index)",
            status: status
        )
    }

    private func endpoint(
        sessionID: UUID,
        generation: UInt64
    ) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: Int(generation),
            workspaceID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            tabID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            sessionID: sessionID,
            persistentBindingGeneration: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"),
            bindingTransitionGeneration: generation
        )
    }

    private var observerSessionID: UUID {
        UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
    }

    private func sessionID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    private func transition(_ entry: Reducer.PendingEntry) -> String {
        "\(entry.fromStatus.rawValue)->\(entry.toStatus.rawValue)"
    }

    private func tryUnwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T {
        guard let value else {
            XCTFail("Expected non-nil value", file: file, line: line)
            fatalError("Expected non-nil value")
        }
        return value
    }
}
