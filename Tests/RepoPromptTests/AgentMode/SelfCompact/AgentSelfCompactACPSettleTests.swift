@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSelfCompactACPSettleTests: XCTestCase {
    private let note = "alpha\nβeta"

    func testInstantReturnAndVouchedDropAreShapeChecksOnly() {
        XCTAssertTrue(AgentSelfCompactInstantReturn.isInstantReturn(elapsed: .zero, assistantOrToolRowCount: 0))
        XCTAssertTrue(AgentSelfCompactInstantReturn.isInstantReturn(
            elapsed: .milliseconds(1999), assistantOrToolRowCount: 0
        ))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isInstantReturn(
            elapsed: .seconds(2), assistantOrToolRowCount: 0
        ))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isInstantReturn(
            elapsed: .seconds(-1), assistantOrToolRowCount: 0
        ))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isInstantReturn(elapsed: nil, assistantOrToolRowCount: 0))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isInstantReturn(elapsed: .zero, assistantOrToolRowCount: nil))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isInstantReturn(elapsed: .zero, assistantOrToolRowCount: 1))

        XCTAssertTrue(AgentSelfCompactInstantReturn.isVouchedDrop(before: 100, current: 99))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isVouchedDrop(before: 100, current: 100))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isVouchedDrop(before: 100, current: 101))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isVouchedDrop(before: nil, current: 1))
        XCTAssertFalse(AgentSelfCompactInstantReturn.isVouchedDrop(before: 100, current: nil))
    }

    func testInstantEmptyTurnEntersNinetySecondSettleAndTimeoutParksUnverified() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator)
        fake.advance(.milliseconds(50))
        fake.settle(coordinator, rows: 0, vouch: nil)
        await drain()
        XCTAssertEqual(fake.state.active?.phase, .acpSettling)
        XCTAssertNil(fake.state.status?.outcome)
        XCTAssertNil(fake.state.status?.completionVerified)
        XCTAssertTrue(fake.state.blocksOverseerDelivery)
        XCTAssertTrue(fake.state.blocksAutomaticWake)
        XCTAssertTrue(fake.slept.contains(.seconds(90)))
        XCTAssertEqual(fake.dispatchCount, 0)

        await fake.finish()
        let frame = AgentSelfCompactNoteEnvelope.frame(note)
        XCTAssertEqual(fake.state.active?.phase, .parked)
        XCTAssertEqual(fake.state.active?.acpCompletionUnverified, true)
        XCTAssertEqual(fake.state.parkedNote?.frame, frame)
        XCTAssertEqual(fake.state.status?.outcome, .completionUnverified)
        XCTAssertEqual(fake.state.status?.completionVerified, false)
        XCTAssertEqual(fake.state.status?.noteDelivery, .parked)
        XCTAssertEqual(fake.state.status?.recoveryNote, note)
        XCTAssertFalse(fake.state.blocksOverseerDelivery)
        XCTAssertTrue(fake.state.blocksAutomaticWake)
        XCTAssertEqual(fake.dispatchCount, 0)
        XCTAssertEqual(fake.providerBoundTexts, [])
    }

    func testVouchedDropDuringHoldSendsTheFramedNoteOnce() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator, tokensBefore: 100)
        fake.advance(.milliseconds(20))
        fake.settle(coordinator, rows: 0, vouch: nil)
        XCTAssertEqual(fake.state.active?.phase, .acpSettling)

        coordinator.noteVouchedContextCount(40)
        await drain()
        XCTAssertEqual(fake.dispatchCount, 1)
        XCTAssertEqual(fake.providerBoundTexts, [AgentSelfCompactNoteEnvelope.frame(note)])
        XCTAssertEqual(fake.state.latest?.outcome, .noteAccepted)
        XCTAssertEqual(fake.state.latest?.completionVerified, true)
        XCTAssertEqual(fake.state.latest?.noteDelivery, .accepted)
        XCTAssertNil(fake.state.active)

        coordinator.noteVouchedContextCount(1)
        await fake.finish()
        XCTAssertEqual(fake.dispatchCount, 1)
    }

    func testVouchedDropAlreadyPresentSkipsTheHold() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator, tokensBefore: 100)
        fake.advance(.milliseconds(20))
        fake.settle(coordinator, rows: 0, vouch: 99)
        await drain()
        XCTAssertEqual(fake.dispatchCount, 1)
        XCTAssertEqual(fake.providerBoundTexts, [AgentSelfCompactNoteEnvelope.frame(note)])
        XCTAssertFalse(fake.slept.contains(.seconds(90)))
        XCTAssertEqual(fake.state.latest?.completionVerified, true)
        await fake.finish()
    }

    func testEqualOrHigherVouchDoesNotLeaveTheHold() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator, tokensBefore: 100)
        fake.advance(.milliseconds(10))
        fake.settle(coordinator, rows: 0, vouch: nil)
        coordinator.noteVouchedContextCount(100)
        coordinator.noteVouchedContextCount(150)
        coordinator.noteVouchedContextCount(nil)
        XCTAssertEqual(fake.state.active?.phase, .acpSettling)
        XCTAssertEqual(fake.dispatchCount, 0)
        await fake.finish()
        XCTAssertEqual(fake.state.active?.phase, .parked)
        XCTAssertEqual(fake.state.active?.acpCompletionUnverified, true)
        XCTAssertEqual(fake.dispatchCount, 0)
    }

    func testCompletedTurnWithoutInstantShapeParksUnverifiedImmediately() async {
        let cases: [(Duration, Int?)] = [
            (.seconds(2), 0),
            (.milliseconds(1999), 1),
            (.milliseconds(10), nil),
            (.seconds(-1), 0)
        ]
        for (elapsed, rows) in cases {
            let fake = Fake()
            let coordinator = fake.coordinator()
            fake.bind(coordinator, tokensBefore: 100)
            fake.advance(elapsed)
            fake.settle(coordinator, rows: rows, vouch: 100)
            await drain()
            XCTAssertEqual(fake.state.active?.phase, .parked, "elapsed \(elapsed) rows \(String(describing: rows))")
            XCTAssertEqual(fake.state.active?.acpCompletionUnverified, true)
            XCTAssertFalse(fake.slept.contains(.seconds(90)))
            XCTAssertEqual(fake.dispatchCount, 0)
            XCTAssertNotEqual(fake.state.status?.completionVerified, true)
            XCTAssertEqual(fake.state.status?.outcome, .completionUnverified)
            await fake.finish()
        }
    }

    func testMissingBindInstantIsNotVerified() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        let id = fake.arm(tokensBefore: 80)
        fake.state.active?.compactRunID = fake.compactRunID
        fake.state.active?.compactRunAttemptID = fake.compactAttemptID
        _ = id
        fake.settle(coordinator, rows: 0, vouch: nil)
        XCTAssertEqual(fake.state.active?.phase, .parked)
        XCTAssertEqual(fake.state.active?.acpCompletionUnverified, true)
        XCTAssertEqual(fake.dispatchCount, 0)
        XCTAssertFalse(fake.state.latest?.completionVerified == true)
        await fake.finish()
    }

    func testLateVouchOrCompletionAfterTimeoutDoesNotSend() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator, tokensBefore: 100)
        fake.advance(.milliseconds(5))
        fake.settle(coordinator, rows: 0, vouch: nil)
        await fake.finish()
        XCTAssertEqual(fake.state.active?.phase, .parked)
        coordinator.noteVouchedContextCount(1)
        fake.settle(coordinator, rows: 0, vouch: 1)
        await drain()
        XCTAssertEqual(fake.dispatchCount, 0)
        XCTAssertEqual(fake.state.active?.phase, .parked)
        XCTAssertEqual(fake.state.active?.acpCompletionUnverified, true)
    }

    func testSupersedeDuringHoldParksWithoutUnverifiedAndCanCarryTheNote() async throws {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator)
        fake.advance(.milliseconds(5))
        fake.settle(coordinator, rows: 0, vouch: nil)
        coordinator.supersedeForOrdinaryInput()
        XCTAssertEqual(fake.state.active?.phase, .parked)
        XCTAssertNil(fake.state.active?.acpCompletionUnverified)
        XCTAssertEqual(fake.dispatchCount, 0)
        let parked = try XCTUnwrap(fake.state.parkedNote)
        XCTAssertEqual(parked.frame, AgentSelfCompactNoteEnvelope.frame(note))
        XCTAssertTrue(fake.state.noteWillAttempt(parked.dispatchID))
        XCTAssertTrue(fake.state.noteAccepted(parked.dispatchID))
        XCTAssertEqual(fake.state.latest?.outcome, .noteAccepted)
        XCTAssertEqual(fake.state.latest?.noteDelivery, .prepended)
        XCTAssertEqual(fake.state.latest?.completionVerified, false)
        XCTAssertEqual(fake.dispatchCount, 0)
        await fake.finish()
    }

    func testOrdinarySendAfterUnverifiedParkCarriesTheFrameAndStaysUnverified() async throws {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator)
        fake.advance(.seconds(3))
        fake.settle(coordinator, rows: 2, vouch: nil)
        let parked = try XCTUnwrap(fake.state.parkedNote)
        XCTAssertTrue(fake.state.noteWillAttempt(parked.dispatchID))
        XCTAssertTrue(fake.state.noteAccepted(parked.dispatchID))
        XCTAssertEqual(fake.state.latest?.outcome, .completionUnverified)
        XCTAssertEqual(fake.state.latest?.noteDelivery, .prepended)
        XCTAssertEqual(fake.state.latest?.completionVerified, false)
        XCTAssertEqual(fake.state.latest?.recoveryNote, note)
        XCTAssertEqual(fake.dispatchCount, 0)
        await fake.finish()
    }

    func testFailedOrCancelledACPTurnDoesNotSendOrPark() async {
        for status in [AgentSessionRunState.failed, .cancelled] {
            let fake = Fake()
            let coordinator = fake.coordinator()
            fake.bind(coordinator)
            fake.advance(.milliseconds(1))
            fake.settle(coordinator, status: status, rows: 0, vouch: 1)
            XCTAssertNil(fake.state.active)
            XCTAssertEqual(fake.state.latest?.outcome, .failed)
            XCTAssertEqual(fake.state.latest?.noteDelivery, .notSent)
            XCTAssertEqual(fake.state.latest?.completionVerified, false)
            XCTAssertEqual(fake.dispatchCount, 0)
            await fake.finish()
        }
    }

    func testStalePublicationAndSuccessorDoNotManufactureAPrompt() async {
        let stale = Fake()
        let staleCoordinator = stale.coordinator()
        stale.bind(staleCoordinator)
        stale.settle(staleCoordinator, publication: .stale)
        XCTAssertNil(stale.state.active)
        XCTAssertEqual(stale.state.latest?.outcome, .completionUnverified)
        XCTAssertEqual(stale.state.latest?.noteDelivery, .notSent)
        XCTAssertEqual(stale.dispatchCount, 0)
        await stale.finish()

        let successor = Fake()
        let successorCoordinator = successor.coordinator()
        successor.bind(successorCoordinator)
        successor.settle(successorCoordinator, rows: 0, vouch: 1, successor: .steering)
        XCTAssertEqual(successor.state.active?.phase, .parked)
        XCTAssertNil(successor.state.active?.acpCompletionUnverified)
        XCTAssertEqual(successor.dispatchCount, 0)
        await successor.finish()
    }

    func testCancelDuringHoldDoesNotParkOrDispatchWhenTheSleeperResumes() async {
        let fake = Fake()
        let coordinator = fake.coordinator()
        fake.bind(coordinator)
        fake.advance(.milliseconds(5))
        fake.settle(coordinator, rows: 0, vouch: nil)
        coordinator.cancelRuntimeWork()
        await fake.finish()
        XCTAssertEqual(fake.state.active?.phase, .acpSettling)
        XCTAssertNil(fake.state.active?.acpCompletionUnverified)
        XCTAssertEqual(fake.dispatchCount, 0)
        XCTAssertNil(fake.state.latest)
    }

    func testEveryRestoredPhaseIsRecoveryRequired() {
        for phase in AgentSelfCompactAttempt.Phase.allCases {
            var state = AgentSelfCompactState()
            _ = state.reserve(note: note, idempotencyKey: "key-\(phase.rawValue)")
            state.active?.phase = phase
            state.active?.acpCompletionUnverified = true
            XCTAssertTrue(state.reconcileColdLaunch(), phase.rawValue)
            XCTAssertNil(state.active)
            XCTAssertEqual(state.latest?.outcome, .recoveryRequired)
            XCTAssertEqual(state.latest?.completionVerified, false)
            XCTAssertEqual(state.latest?.recoveryNote, note)
            XCTAssertFalse(state.blocksOverseerDelivery)
            XCTAssertFalse(state.blocksAutomaticWake)
        }
    }

    func testParkedPrefixCarriesTheFrameOnceAndExactNoteIsUnmodified() throws {
        let session = AgentTabSession(tabID: UUID())
        var state = AgentSelfCompactState()
        _ = state.reserve(note: note, idempotencyKey: "carry")
        state.active?.phase = .parked
        state.active?.acpCompletionUnverified = true
        session.selfCompactState = state

        let ordinary = AgentSelfCompactParkedPrefix.prepare("next turn", session: session)
        let frame = AgentSelfCompactNoteEnvelope.frame(note)
        XCTAssertEqual(ordinary.text, frame + "\n\nnext turn")
        XCTAssertFalse(ordinary.exactNote)
        let dispatchID = try XCTUnwrap(ordinary.dispatchID)
        XCTAssertTrue(AgentSelfCompactParkedPrefix.markAttempted(dispatchID, session: session))
        XCTAssertTrue(AgentSelfCompactParkedPrefix.markAccepted(dispatchID, session: session))
        XCTAssertEqual(session.selfCompactState.latest?.outcome, .completionUnverified)
        XCTAssertEqual(session.selfCompactState.latest?.noteDelivery, .prepended)
        XCTAssertEqual(session.selfCompactState.latest?.completionVerified, false)
        XCTAssertTrue(session.items.contains { $0.kind == .system && !$0.text.contains(note) && !$0.text.contains("<note>") })

        var exactState = AgentSelfCompactState()
        _ = exactState.reserve(note: note, idempotencyKey: "exact")
        exactState.active?.phase = .dispatchingNote
        session.selfCompactState = exactState
        let exact = AgentSelfCompactParkedPrefix.prepare(frame, session: session)
        XCTAssertTrue(exact.exactNote)
        XCTAssertEqual(exact.text, frame)
    }

    func testEightKilobyteNoteSurvivesRepeatedInstantReturnsInsideTheWallBudget() async {
        let body = String(repeating: "n", count: 8190) + "\nZ"
        XCTAssertEqual(body.utf8.count, 8192)
        let frame = AgentSelfCompactNoteEnvelope.frame(body)
        let started = ContinuousClock.now
        for index in 0 ..< 16 {
            let fake = Fake()
            let coordinator = fake.coordinator()
            fake.bind(coordinator, note: body, tokensBefore: 500)
            fake.advance(.milliseconds(25))
            fake.settle(coordinator, rows: 0, vouch: nil)
            await drain()
            XCTAssertEqual(fake.state.active?.phase, .acpSettling)
            XCTAssertTrue(fake.slept.contains(.seconds(90)))
            await fake.finish()
            XCTAssertEqual(fake.state.parkedNote?.frame, frame)
            XCTAssertEqual(fake.dispatchCount, 0)
            XCTAssertEqual(fake.state.status?.outcome, .completionUnverified)
            XCTAssertEqual(fake.state.status?.completionVerified, false)
            let same = fake.state.reserve(note: body, idempotencyKey: "key", owner: fake.owner)
            guard case .duplicate = same else {
                XCTFail("iteration \(index) expected duplicate, got \(same)")
                return
            }
            XCTAssertEqual(
                fake.state.reserve(note: body, idempotencyKey: "other-key", owner: fake.owner),
                .alreadyPending
            )
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(8))
    }

    private func drain() async {
        for _ in 0 ..< 30 {
            await Task.yield()
        }
    }

    @MainActor private final class Fake {
        var state = AgentSelfCompactState()
        var dispatchCount = 0
        var providerBoundTexts: [String] = []
        var pendingSleeps: [CheckedContinuation<Void, Never>] = []
        var slept: [Duration] = []
        var instant = ContinuousClock.now
        let owner = AgentSelfCompactOwner(
            windowID: 1, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(),
            persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1,
            runID: UUID(), runAttemptID: UUID()
        )
        let compactRunID = UUID()
        let compactAttemptID = UUID()

        func arm(note: String = "alpha\nβeta", tokensBefore: Int? = 100) -> UUID {
            _ = state.reserve(note: note, idempotencyKey: "key", owner: owner)
            state.active?.admittedSupport = .acpAdvertisedCommand
            state.active?.phase = .dispatchingCompact
            state.active?.usedTokensBeforeCompact = tokensBefore
            return state.active!.id
        }

        func coordinator() -> AgentSelfCompactNativeCompletionCoordinator {
            AgentSelfCompactNativeCompletionCoordinator(
                load: { self.state },
                store: { self.state = $0 },
                isCurrentOwner: { _ in true },
                dispatchNote: { requestID, admissible in
                    guard admissible(), let note = self.state.active?.note else { return false }
                    self.dispatchCount += 1
                    self.providerBoundTexts.append(AgentSelfCompactNoteEnvelope.frame(note))
                    self.state.active?.phase = .dispatchingNote
                    let dispatchID = AgentSelfCompactionDispatchID(requestID: requestID, stage: .note)
                    XCTAssertTrue(self.state.noteWillAttempt(dispatchID))
                    XCTAssertTrue(self.state.noteAccepted(dispatchID))
                    return true
                },
                sleep: { duration in
                    self.slept.append(duration)
                    await withCheckedContinuation { continuation in
                        self.pendingSleeps.append(continuation)
                    }
                },
                now: { self.instant }
            )
        }

        func bind(
            _ coordinator: AgentSelfCompactNativeCompletionCoordinator,
            note: String = "alpha\nβeta",
            tokensBefore: Int? = 100
        ) {
            let id = arm(note: note, tokensBefore: tokensBefore)
            XCTAssertTrue(coordinator.bindCompact(
                .init(requestID: id, stage: .compact),
                runID: compactRunID,
                runAttemptID: compactAttemptID
            ))
        }

        func advance(_ duration: Duration) {
            instant = instant.advanced(by: duration)
        }

        func settle(
            _ coordinator: AgentSelfCompactNativeCompletionCoordinator,
            status: AgentSessionRunState = .completed,
            rows: Int? = 0,
            vouch: Int? = nil,
            successor: AgentRunEpochTransitionKind? = nil,
            publication: AgentRunTerminalPublicationResult = .accepted(successorEpoch: nil)
        ) {
            coordinator.compactTurnSettled(
                revision: AgentRunTerminalCommitRevision(
                    commitID: UUID(),
                    ownership: AgentRunOwnership(
                        attemptID: compactAttemptID,
                        binding: AgentRunBindingIdentity(tabID: owner.tabID, persistentSessionID: owner.sessionID)
                    ),
                    terminalState: status,
                    failureReason: nil,
                    expectedRunID: compactRunID,
                    sourceItemsRevision: 0,
                    assistantDeltaFlushGeneration: 0,
                    providerDrainGeneration: 0,
                    mcpPublicationEnvelope: nil,
                    successorKind: successor,
                    providerSuccessorID: nil
                ),
                publication: publication,
                teardownSettled: { true },
                assistantOrToolRowCount: rows,
                vouchedTokenCount: vouch
            )
        }

        func finish() async {
            for _ in 0 ..< 30 {
                await Task.yield()
            }
            let sleepers = pendingSleeps
            pendingSleeps.removeAll()
            sleepers.forEach { $0.resume() }
            for _ in 0 ..< 30 {
                await Task.yield()
            }
        }
    }
}
