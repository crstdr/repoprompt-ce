import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

private actor AutoWakeCatalogAuthorityGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Bool, Never>] = []

    func requirement() async -> Bool {
        if !entered {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        if isOpen {
            return true
        }
        return await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }
}

/// Orchestration, identity, and provenance for the one automatic lane-update follow-up.
///
/// Deliberately driven through the same publication hook and claim seam the runtime bridge and every
/// provider family use, rather than by calling the coordinator's internals: what has to be true is
/// that a wake reserves exactly one turn, that the reservation is visible to other observers, and
/// that the acceptance boundary is the provider's own signal.
@MainActor
final class AgentSessionLinkAutoWakeTests: XCTestCase {
    private var retained: [AgentModeViewModel] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    // MARK: - Dispatch identity

    /// The wake ID survives a round trip through the opaque dispatch ID.
    ///
    /// This is what makes acceptance decidable from the claim alone: the provider hands back a claim,
    /// and the wake it settles is read out of that claim rather than out of whatever the session
    /// happens to hold at the time.
    func testAutoWakeDispatchIDRoundTripsItsWakeAndNothingElseClaimsToBeOne() {
        let wakeID = UUID()
        XCTAssertEqual(
            AgentSessionLinkPromptDispatchID.autoWake(wakeID: wakeID, localInputEpoch: 0).autoWakeID,
            wakeID
        )
        XCTAssertNotEqual(
            AgentSessionLinkPromptDispatchID.autoWake(wakeID: wakeID, localInputEpoch: 0),
            AgentSessionLinkPromptDispatchID.autoWake(wakeID: UUID(), localInputEpoch: 0)
        )
        for ordinary: AgentSessionLinkPromptDispatchID in [
            .claudeNativeSend(wakeID),
            .codexNativeSend(wakeID),
            .codexFallback(queueID: wakeID),
            .headlessRun(runID: wakeID),
            .acpPromptTurn(runAttemptID: wakeID),
            .acpActiveSteering(runAttemptID: wakeID),
            .waitingContinuation(waitID: wakeID)
        ] {
            XCTAssertNil(
                ordinary.autoWakeID,
                "an ordinary provider dispatch must never be mistaken for a wake"
            )
        }
        XCTAssertNil(AgentSessionLinkPromptDispatchID(rawValue: "lane.autowake:nope").autoWakeID)
    }

    /// A wake's claim is refused outright unless the lane batch it exists to deliver is present.
    ///
    /// The requirement is a property of the dispatch identity, not a caller-supplied flag, so it
    /// cannot be forgotten by one provider family and honoured by another. An ordinary dispatch in
    /// the same state is still allowed to carry membership alone.
    func testAWakeClaimRequiresTheLaneBatchWhileAnOrdinaryDispatchDoesNot() {
        let observerSessionID = UUID()
        let epoch = Self.epoch(observerSessionID: observerSessionID)
        let inventory = Self.inventory(observerSessionID: observerSessionID, revision: 1)

        let store = AgentSessionLinkOutboundPromptClaimStore()
        let ordinary = store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: nil,
            render: AgentSessionLinkPrompts.rendered
        )
        XCTAssertNotNil(ordinary, "membership alone is a perfectly good ordinary dispatch")
        XCTAssertNil(ordinary?.passive)

        let wakeStore = AgentSessionLinkOutboundPromptClaimStore()
        XCTAssertNil(
            wakeStore.claim(
                dispatchID: .autoWake(wakeID: UUID(), localInputEpoch: 0),
                epoch: epoch,
                inventory: inventory,
                passiveNotices: nil,
                render: AgentSessionLinkPrompts.rendered
            ),
            "a wake must not start a turn carrying membership alone"
        )
    }

    // MARK: - Guidance revision

    /// Full guidance once, then the one-line reminder, and full again when the context is rebuilt.
    func testLaneGuidanceIsFullUntilPhysicallyAcceptedThenReminderUntilTheContextIsRebuilt() throws {
        let observerSessionID = UUID()
        let epoch = Self.epoch(observerSessionID: observerSessionID)
        let inventory = Self.inventory(observerSessionID: observerSessionID, revision: 1)
        let store = AgentSessionLinkOutboundPromptClaimStore()

        let first = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 1),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(first.laneGuidanceMode, .full)
        XCTAssertTrue(first.fragment.contains("untrusted data from another session"))
        XCTAssertTrue(first.fragment.contains("idle_for_send` describes readiness at `observed_at`"))

        // Rendering is not acceptance: an abandoned batch leaves the wording still owed.
        store.abandon(first)
        let retried = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 1),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(retried.laneGuidanceMode, .full)

        store.accept(retried)
        XCTAssertEqual(
            store.test_lastAcceptedLaneGuidanceRevision(observerSessionID: observerSessionID),
            AgentSessionLinkPrompts.currentLaneGuidanceRevision
        )

        let later = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 2),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(later.laneGuidanceMode, .reminder)
        XCTAssertTrue(later.fragment.contains("Lane update:"))
        XCTAssertFalse(later.fragment.contains("idle_for_send` describes readiness at `observed_at`"))

        // A rebuilt provider conversation never saw the wording, so it is owed in full again.
        store.invalidateAcknowledgedContext(observerSessionID: observerSessionID)
        XCTAssertNil(
            store.test_lastAcceptedLaneGuidanceRevision(observerSessionID: observerSessionID)
        )
        let rebuilt = try XCTUnwrap(store.claim(
            dispatchID: .claudeNativeSend(UUID()),
            epoch: epoch,
            inventory: inventory,
            passiveNotices: Self.laneSnapshot(observerEndpoint: epoch.endpoint, queueRevision: 3),
            render: AgentSessionLinkPrompts.rendered
        ))
        XCTAssertEqual(rebuilt.laneGuidanceMode, .full)
    }

    // MARK: - Readiness and loop prevention

    /// A reserved wake makes the observer busy for every other observer's `send`.
    ///
    /// Without this the wake and an inbound delivery race for the same terminal boundary, and the
    /// loser is silently dropped.
    func testAReservedWakeMakesTheObserverUnsendable() {
        var snapshot = AgentSessionLinkDeliveryReadiness.Snapshot.ready
        XCTAssertEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot), .ready)
        snapshot.pendingOversightAutoWake = true
        XCTAssertEqual(
            AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot).blockReason,
            .targetNotIdle
        )
    }

    /// An auto-woken turn cannot originate further linked work until its own user speaks.
    ///
    /// The wire-stable reason is deliberately unchanged: broadening what can produce it is not a new
    /// refusal, and the observer's prompt guidance names that exact string.
    func testAutoWakeOriginBlocksOnwardSendUnderTheExistingWireReason() {
        var snapshot = AgentSessionLinkDeliveryReadiness.Snapshot.ready
        snapshot.observerTurnOrigin = .laneUpdateAutoWake(wakeID: UUID())
        let decision = AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot)
        XCTAssertEqual(decision.blockReason, .crossSessionReplyRequiresUserInstruction)
        XCTAssertEqual(
            decision.blockReason?.rawValue,
            "cross_session_reply_requires_user_instruction"
        )
        XCTAssertTrue(AgentSessionLinkTurnOrigin.localUser.requiresNewLocalUserInstruction == false)
        for blocked: AgentSessionLinkTurnOrigin in [
            .crossSessionMessage(sourceSessionID: UUID()),
            .laneUpdateAutoWake(wakeID: UUID())
        ] {
            XCTAssertTrue(blocked.requiresNewLocalUserInstruction)
        }
    }

    // MARK: - Provenance

    /// The visible row is keyed by the wake, stamped at physical acceptance, and says nothing about
    /// which sessions changed.
    func testLaneUpdateSystemRowIsKeyedByWakeAndCarriesNoTargetDetail() {
        let wakeID = UUID()
        let acceptedAt = Date(timeIntervalSince1970: 1234)
        let row = AgentChatItem.laneUpdateAutoWake(wakeID: wakeID, acceptedAt: acceptedAt)
        XCTAssertEqual(row.id, wakeID, "duplicate acceptance callbacks dedupe by identity")
        XCTAssertEqual(row.timestamp, acceptedAt)
        XCTAssertEqual(row.kind, .system, "RepoPrompt started this turn and must not claim authorship")
        XCTAssertTrue(row.text.hasPrefix("[lane-update]"))
        for forbidden in [wakeID.uuidString, "preview", "session_id", "/Users/"] {
            XCTAssertFalse(row.text.contains(forbidden))
        }
    }

    // MARK: - Coordinator

    /// Enabling is what arms the wake, and the reservation is visible where readiness is computed.
    ///
    /// Driven through `agentSessionLinkPublishPassiveStatusNotices` — the same endpoint-addressed
    /// hook the bridge publishes through — so this exercises the real scheduling gate rather than a
    /// test-only entry point.
    func testDeliverableContentReservesExactlyOneWakeOnlyWhenTheSettingIsOn() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)

        // Setting off: content is collected and delivered naturally, but nothing is reserved.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNil(fixture.session.pendingOversightAutoWake)

        fixture.session.autoWakeOnOversightUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2)
        let reserved = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
        XCTAssertEqual(reserved.queueRevision, 2)

        // A newer revision raises the high-water mark of the one attempt rather than starting a
        // second: an observer reserves at most one automatic follow-up.
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 3)
        let absorbed = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
        XCTAssertEqual(absorbed.wakeID, reserved.wakeID)
        XCTAssertEqual(absorbed.queueRevision, 3)
    }

    func testReadyCatalogTransitionRedrivesOneOwedWakeWithoutAnotherNotice() async throws {
        let fixture = try makeFixture(catalogReady: false)
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        fixture.session.runState = .running

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNil(
            fixture.session.pendingOversightAutoWake,
            "the passive publication remains owed while its current run catalog is unready"
        )

        let projection = try publishCatalogProjection(fixture, revision: 1, hasAgentSessionLink: true)
        try await AsyncTestWait.waitUntil("the ready transition to re-drive the owed wake") {
            await MainActor.run {
                fixture.session.pendingOversightAutoWake?.phase == .awaitingSettlement
            }
        }
        let reserved = try XCTUnwrap(fixture.session.pendingOversightAutoWake)

        // Replaying the same ready projection is not a second transition and must not reserve another
        // wake. No passive status publication occurs after the one above.
        fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(
            projection,
            to: reserved.observerEndpoint
        )
        XCTAssertEqual(fixture.session.pendingOversightAutoWake?.wakeID, reserved.wakeID)
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .settingDisabled
        )
    }

    func testBusyWakeAwaitsOneCancellableObservationSubscription() async throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        fixture.session.runState = .running

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        let parked = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
        XCTAssertEqual(parked.phase, .awaitingSettlement)
        XCTAssertNotNil(parked.task, "busy reevaluation must own the awaited readiness subscription")
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: parked.observerEndpoint,
            reason: .settingDisabled
        )
        XCTAssertTrue(parked.task?.isCancelled == true)
    }

    func testQueueSideCompetitionCannotEraseDispatchingWakeIdentity() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
        reserved.task?.cancel()
        fixture.session.pendingOversightAutoWake = AgentSessionLinkAutoWakeAttempt(
            wakeID: reserved.wakeID,
            observerEndpoint: reserved.observerEndpoint,
            queueEpoch: reserved.queueEpoch,
            localInputEpoch: reserved.localInputEpoch,
            queueRevision: reserved.queueRevision,
            wakeFingerprint: reserved.wakeFingerprint,
            attemptedFingerprint: reserved.wakeFingerprint,
            humanRearmEpochs: reserved.humanRearmEpochs,
            physicalOutcome: .ambiguous,
            phase: .dispatching,
            task: nil
        )

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, targetIndices: [])

        XCTAssertEqual(fixture.session.pendingOversightAutoWake?.wakeID, reserved.wakeID)
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: .autoWake(
                wakeID: reserved.wakeID,
                localInputEpoch: reserved.localInputEpoch
            )
        )
        XCTAssertNil(fixture.session.pendingOversightAutoWake)
        XCTAssertEqual(
            fixture.session.suppressedOversightWakeFingerprint,
            reserved.wakeFingerprint
        )
    }

    /// A non-local origin can never arm a wake, so oversight cycles cannot chain.
    func testANonLocalOriginNeverArmsAWake() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        fixture.session.agentSessionLinkTurnOrigin = .laneUpdateAutoWake(wakeID: UUID())

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNil(fixture.session.pendingOversightAutoWake)

        // Only accepted local-user input re-arms it.
        fixture.session.agentSessionLinkTurnOrigin = .localUser
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2)
        XCTAssertNotNil(fixture.session.pendingOversightAutoWake)
    }

    func testFreshSelectedTargetLocalEpochBypassesObserverFenceWithoutRetroactiveWake() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.agentSessionLinkTurnOrigin = .laneUpdateAutoWake(wakeID: UUID())

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetLocalInputEpoch: 5,
            targetTurnIsLocalUser: true,
            selectedTargetIndices: [0]
        )
        XCTAssertNil(fixture.session.pendingOversightAutoWake, "activation baselines existing target work")

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10,
            targetLocalInputEpoch: 6,
            targetTurnIsLocalUser: true,
            selectedTargetIndices: [0]
        )
        XCTAssertEqual(fixture.session.pendingOversightAutoWake?.humanRearmEpochs.count, 1)
    }

    func testCrossSessionTargetEpochCannotRearmAndFailedAttemptDoesNotConsumeLocalEpoch() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.agentSessionLinkTurnOrigin = .laneUpdateAutoWake(wakeID: UUID())
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetLocalInputEpoch: 4,
            targetTurnIsLocalUser: false,
            selectedTargetIndices: [0]
        )
        XCTAssertNil(fixture.session.pendingOversightAutoWake)

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10,
            targetLocalInputEpoch: 5,
            targetTurnIsLocalUser: true,
            selectedTargetIndices: [0]
        )
        let first = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: first.observerEndpoint,
            reason: .requiredClaimUnavailable
        )
        XCTAssertTrue(fixture.session.agentSessionLinkConsumedTargetLocalEpochs.values.allSatisfy { $0 < 5 })

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 3,
            edgeSequenceOffset: 20,
            targetLocalInputEpoch: 5,
            targetTurnIsLocalUser: true,
            selectedTargetIndices: [0]
        )
        XCTAssertNotNil(fixture.session.pendingOversightAutoWake)
    }

    /// The publication that *activates* a lane carries no entries, so it is the only chance to
    /// baseline that lane's target epoch without spending it.
    ///
    /// Regression: baselining from the lane's first *update* instead consumed the very epoch that
    /// update was caused by, so the first direct human turn in a freshly linked or freshly selected
    /// target could never re-arm a fenced observer.
    func testActivationPublicationBaselinesLaneEpochSoTheFirstHumanTurnStillRearms() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.agentSessionLinkTurnOrigin = .laneUpdateAutoWake(wakeID: UUID())

        // Activation: the lane is live and its target has already taken local input, but no status
        // edge has been queued for it yet.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            targetLocalInputEpoch: 5,
            targetTurnIsLocalUser: true,
            selectedTargetIndices: [0]
        )
        XCTAssertEqual(
            fixture.session.agentSessionLinkConsumedTargetLocalEpochs[Self.laneReference(0)],
            5,
            "work that predates the lane must be baselined by the entry-less activation publication"
        )
        XCTAssertNil(fixture.session.pendingOversightAutoWake)

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10,
            targetLocalInputEpoch: 6,
            targetTurnIsLocalUser: true,
            selectedTargetIndices: [0]
        )
        XCTAssertEqual(
            fixture.session.pendingOversightAutoWake?.humanRearmEpochs[Self.laneReference(0)],
            6,
            "the first direct human turn after activation is fresh and may re-arm the observer"
        )
    }

    /// Master off plus an unselected lane is the combination that must stay silent, and selecting
    /// that same lane is what makes its next update wake-eligible.
    func testMasterOffLeavesAnUnselectedLaneSilentUntilThatLaneIsSelected() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        XCTAssertFalse(fixture.session.autoWakeOnOversightUpdates)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [])
        XCTAssertNil(
            fixture.session.pendingOversightAutoWake,
            "an unselected lane must not reserve a turn while the master switch is off"
        )

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10,
            selectedTargetIndices: [0]
        )
        XCTAssertNotNil(
            fixture.session.pendingOversightAutoWake,
            "a granular selection is sufficient on its own"
        )
    }

    /// Overflow is a whole-queue count, never attributed to the lane that produced it.
    ///
    /// Regression: "some lane is selected" was enough for overflow to reserve a wake, so dropped
    /// edges belonging to an excluded target started an autonomous turn — the selected lane's only
    /// contribution being that it existed.
    func testOverflowFromAnUnselectedLaneCannotWakeMerelyBecauseAnotherLaneIsSelected() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        XCTAssertFalse(fixture.session.autoWakeOnOversightUpdates)

        // No entries at all, so the unattributed overflow is the only thing that could trigger a
        // wake — and one of the two live lanes is excluded from Auto-wake.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            overflow: 2,
            selectedTargetIndices: [0]
        )

        XCTAssertNil(
            fixture.session.pendingOversightAutoWake,
            "overflow that may have come from an excluded lane must not reserve a turn"
        )
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "refusing to wake is not discarding the queue: the overflow stays owed to a natural turn"
        )
    }

    /// The conservative rule is not "overflow never wakes": once every live lane is selected, the
    /// dropped edges provably belong to lanes the user opted in to.
    ///
    /// Scheduling and the acceptance fence must apply the identical predicate, so an attempt admitted
    /// under "every lane selected" stops qualifying the moment one of them is excluded.
    func testOverflowWakesOnlyWhenEveryLiveLaneIsSelectedAndTheFenceAppliesTheSameRule() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0, 1],
            overflow: 2,
            selectedTargetIndices: [0, 1]
        )
        let reserved = try XCTUnwrap(
            fixture.session.pendingOversightAutoWake,
            "overflow across a fully selected lane set is wake-eligible"
        )

        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.pendingOversightAutoWake = preparing
        fixture.session.agentSessionLinkAutoWakeTargetSessionIDs = [Self.targetID(0)]

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(
                wakeID: reserved.wakeID,
                localInputEpoch: reserved.localInputEpoch
            )
        ))
        XCTAssertNil(fixture.session.pendingOversightAutoWake)

        // Master-on satisfies the rule by construction, so the whole-observer case keeps waking on
        // overflow alone even while the granular set is a strict subset.
        fixture.session.autoWakeOnOversightUpdates = true
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [],
            laneIndices: [0, 1],
            overflow: 2,
            selectedTargetIndices: [0]
        )
        XCTAssertNotNil(fixture.session.pendingOversightAutoWake)
    }

    /// Selection is live session state; the lane flag in a published snapshot is only the projection
    /// of it that publication froze, and the two disagree for exactly as long as a refresh takes.
    ///
    /// Regression: the acceptance fence read that projection, so a lane the user deselected while a
    /// wake was already preparing could still cross the provider transport boundary and start a turn
    /// nobody asked for.
    func testDeselectingALaneRefusesItsWakeAtTheAcceptanceFenceBeforeAnyRepublication() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [0])
        let reserved = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.pendingOversightAutoWake = preparing

        // Deselected with no republication: the snapshot the fence used to consult still reports the
        // lane as selected, so only a live read can refuse this.
        fixture.session.agentSessionLinkAutoWakeTargetSessionIDs = []
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID]?
                .autoWakeLanes.map(\.isEffectivelySelected),
            [true],
            "precondition: the published projection has not caught up with the deselection"
        )

        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(
                wakeID: reserved.wakeID,
                localInputEpoch: reserved.localInputEpoch
            )
        ))
        XCTAssertNil(fixture.session.pendingOversightAutoWake)
        XCTAssertNil(
            fixture.session.suppressedOversightWakeFingerprint,
            "a refusal before the transport boundary suppresses nothing"
        )
    }

    /// The same live selection is what makes the mutation itself retract an attempt, rather than
    /// leaving a deselected lane's wake alive until something else happens to re-evaluate it.
    func testDeselectingALaneRetractsAScheduledWakeSynchronously() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1, selectedTargetIndices: [0])
        XCTAssertNotNil(fixture.session.pendingOversightAutoWake)

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs([], for: endpoint))

        XCTAssertNil(fixture.session.pendingOversightAutoWake)
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "deselecting stops scheduling; it does not discard the queue"
        )
    }

    /// Selecting a lane baselines the target work that predates the selection — and nothing else.
    ///
    /// Regression: the baseline was taken from the first snapshot published *after* the selection, so
    /// a target-local instruction that arrived in between was consumed as pre-selection work and the
    /// first direct human turn under the new selection could never re-arm a fenced observer.
    func testSelectingALaneBaselinesAtTheSelectionRatherThanAtTheNextPublication() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.agentSessionLinkTurnOrigin = .laneUpdateAutoWake(wakeID: UUID())

        // The lane is live and unselected, and its target has already taken local input.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [],
            laneIndices: [0],
            targetLocalInputEpoch: 5,
            targetTurnIsLocalUser: true,
            selectedTargetIndices: []
        )
        XCTAssertNil(fixture.session.pendingOversightAutoWake)

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs(
            [Self.targetID(0)],
            for: endpoint
        ))
        XCTAssertEqual(
            fixture.session.agentSessionLinkConsumedTargetLocalEpochs[Self.laneReference(0)],
            5,
            "the selection itself baselines the target work that predates it"
        )

        // The target's own user sends the first instruction after the selection, and the projection
        // catches up with the selection and that instruction in the same publication.
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            edgeSequenceOffset: 10,
            targetLocalInputEpoch: 6,
            targetTurnIsLocalUser: true,
            selectedTargetIndices: [0]
        )
        XCTAssertEqual(
            fixture.session.pendingOversightAutoWake?.humanRearmEpochs[Self.laneReference(0)],
            6,
            "the first human turn after a selection must still re-arm the fenced observer"
        )
    }

    /// Drives the real waiting-instruction continuation from suspension through lane acceptance.
    /// The returned origin, user-activity timestamp, transcript authorship, and anti-chain fence are
    /// the observable contract that distinguishes this from an ordinary user answer.
    func testWaitingContinuationPreservesSystemOriginWithoutUserAttribution() async throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        let priorUserActivity = Date(timeIntervalSince1970: 123)
        fixture.session.lastUserMessageAt = priorUserActivity
        fixture.session.activeNonCodexTurnTokenAccumulator = .init()
        let userRowsBefore = fixture.session.items.count(where: { $0.kind == .user })

        let waiting = Task { @MainActor in
            try await fixture.viewModel.waitForNextUserInstruction(
                tabID: fixture.tabID,
                prompt: "What next?",
                timeoutSeconds: 5
            )
        }
        for _ in 0 ..< 20 where fixture.session.instructionContinuation == nil {
            await Task.yield()
        }
        XCTAssertNotNil(fixture.session.instructionContinuation)

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let response = try await waiting.value
        guard case let .laneUpdateAutoWake(wakeID) = response.origin else {
            return XCTFail("expected the waiting continuation to preserve lane-update origin")
        }

        XCTAssertEqual(fixture.session.lastUserMessageAt, priorUserActivity)
        XCTAssertEqual(fixture.session.items.count(where: { $0.kind == .user }), userRowsBefore)
        XCTAssertEqual(fixture.session.agentSessionLinkTurnOrigin, .laneUpdateAutoWake(wakeID: wakeID))
        XCTAssertEqual(fixture.session.items.count(where: { $0.id == wakeID && $0.kind == .system }), 1)
        XCTAssertNil(fixture.session.instructionContinuation)
        XCTAssertEqual(fixture.session.runState, .running)
        XCTAssertEqual(
            fixture.session.activeNonCodexTurnTokenAccumulator?.estimatedUserInputTokens,
            0
        )
        XCTAssertGreaterThan(
            fixture.session.activeNonCodexTurnTokenAccumulator?.estimatedToolInputTokens ?? 0,
            0,
            "system-origin continuation text still consumes provider context"
        )
    }

    func testCodexWaitingAutoWakeReadinessSupersessionSettlesAttemptWithoutDispatch() async throws {
        #if DEBUG
            let fixture = try makeFixture()
            fixture.session.selectedAgent = .codexExec
            let authorityGate = AutoWakeCatalogAuthorityGate()
            fixture.viewModel.test_agentSessionLinkHasActiveOutboundLink = { _ in
                await authorityGate.requirement()
            }
            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            fixture.session.codexController = controller
            try publishInventory(fixture, revision: 1)
            fixture.session.autoWakeOnOversightUpdates = true

            let waiting = Task { @MainActor in
                try await fixture.viewModel.waitForNextUserInstruction(
                    tabID: fixture.tabID,
                    timeoutSeconds: 10
                )
            }
            try await AsyncTestWait.waitUntil("the auto-wake continuation to install") {
                await MainActor.run { fixture.session.instructionContinuation != nil }
            }
            let runID = try XCTUnwrap(fixture.session.runID)
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                fixture.viewModel,
                tabID: fixture.tabID
            )
            fixture.viewModel.test_agentSessionLinkCurrentRunCatalogRouteToken = { routeToken, tabID in
                routeToken.runID == runID
                    && routeToken.observerEndpoint == endpoint
                    && tabID == fixture.tabID
            }
            let itemCount = fixture.session.items.count

            try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
            let attempt = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
            await authorityGate.waitUntilEntered()
            let routeToken = AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            )
            let unready = await ServerNetworkManager.shared.debugPublishRunCatalogObservation(
                routeToken: routeToken,
                hasAgentSessionLink: nil
            )
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(unready, to: endpoint)
            await authorityGate.open()
            try await AsyncTestWait.waitUntil("the auto-wake catalog waiter to register") {
                await ServerNetworkManager.shared.debugHasRunCatalogState(for: runID)
            }
            await ServerNetworkManager.shared.cleanupRunRoutingState(
                for: runID,
                windowID: endpoint.windowID
            )

            try await AsyncTestWait.waitUntil("the superseded auto-wake attempt to settle") {
                await MainActor.run { fixture.session.pendingOversightAutoWake == nil }
            }
            XCTAssertNotNil(fixture.session.instructionContinuation)
            XCTAssertEqual(fixture.session.items.count, itemCount)
            XCTAssertFalse(
                fixture.session.items.contains { $0.id == attempt.wakeID },
                "no provider-accepted auto-wake row may be written"
            )
            fixture.session.instructionContinuation?.resume(throwing: CancellationError())
            fixture.session.instructionContinuation = nil
            _ = try? await waiting.value
            withExtendedLifetime(controller) {}
        #else
            throw XCTSkip("Catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    /// Natural delivery that clears the queue cancels the reservation, with no provider call and no
    /// transcript row.
    func testNaturalDeliveryCancelsAPendingWakeWithoutAProvenanceRow() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNotNil(fixture.session.pendingOversightAutoWake)

        let itemsBefore = fixture.session.items.count
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, targetIndices: [])
        XCTAssertNil(fixture.session.pendingOversightAutoWake)
        XCTAssertEqual(fixture.session.items.count, itemsBefore, "a cancelled wake writes no row")
    }

    /// Turning the setting off releases an unaccepted reservation but never clears the lane queue:
    /// the content stays owed to a natural future turn.
    func testTurningTheSettingOffReleasesTheReservationAndLeavesTheQueueOwed() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNotNil(fixture.session.pendingOversightAutoWake)

        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        XCTAssertTrue(
            fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(false, for: endpoint)
        )
        XCTAssertNil(fixture.session.pendingOversightAutoWake)
        XCTAssertFalse(fixture.session.autoWakeOnOversightUpdates)
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "turning off scheduling is not discarding the queue"
        )
    }

    func testExplicitOffOnCycleClearsFailureSuppressionWithoutRearmingANonLocalOrigin() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let fingerprint = Self.laneSnapshot(
            observerEndpoint: endpoint,
            queueRevision: 1
        ).wakeEligibilityFingerprint
        fixture.session.autoWakeOnOversightUpdates = true
        fixture.session.agentSessionLinkTurnOrigin = .laneUpdateAutoWake(wakeID: UUID())
        fixture.session.suppressedOversightWakeFingerprint = fingerprint

        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(false, for: endpoint))
        XCTAssertTrue(fixture.viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(true, for: endpoint))

        XCTAssertNil(fixture.session.suppressedOversightWakeFingerprint)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        XCTAssertNil(
            fixture.session.pendingOversightAutoWake,
            "off/on is failure recovery, not a bypass around the anti-chain fence"
        )
    }

    /// Accepting a wake's claim records the origin, writes exactly one row, and is idempotent.
    ///
    /// Acceptance is keyed on the claim's own dispatch identity, so this is the same path every
    /// provider family reaches through its existing physical-acceptance signal.
    func testAcceptedWakeRecordsOriginAndExactlyOneSystemRowIdempotently() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let wakeID = try XCTUnwrap(fixture.session.pendingOversightAutoWake).wakeID

        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: wakeID, localInputEpoch: 0)
        ))
        XCTAssertNotNil(claim.passive, "a wake claim always carries the batch it exists for")

        let itemsBefore = fixture.session.items.count
        let nextSequenceIndex = fixture.session.nextSequenceIndex
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)

        XCTAssertEqual(
            fixture.session.agentSessionLinkTurnOrigin,
            .laneUpdateAutoWake(wakeID: wakeID)
        )
        XCTAssertNil(fixture.session.pendingOversightAutoWake)
        let appended = fixture.session.items.suffix(from: itemsBefore)
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended.first?.id, wakeID)
        XCTAssertEqual(appended.first?.kind, .system)
        XCTAssertEqual(appended.first?.sequenceIndex, nextSequenceIndex)
        XCTAssertFalse(
            fixture.session.items.contains { $0.kind == .user && $0.id == wakeID },
            "a wake never impersonates the user"
        )

        // Duplicate acceptance callbacks are idempotent by wake ID.
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertEqual(fixture.session.items.count(where: { $0.id == wakeID }), 1)
    }

    func testAcceptedCoalescedWakeConsumesEveryRepresentedHumanEpochAtomically() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.agentSessionLinkTurnOrigin = .laneUpdateAutoWake(wakeID: UUID())
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 1,
            targetIndices: [0, 1],
            targetLocalInputEpoch: 5,
            targetTurnIsLocalUser: true,
            selectedTargetIndices: [0, 1]
        )
        XCTAssertNil(fixture.session.pendingOversightAutoWake)
        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [0, 1],
            edgeSequenceOffset: 10,
            targetLocalInputEpoch: 6,
            targetTurnIsLocalUser: true,
            selectedTargetIndices: [0, 1]
        )
        let attempt = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
        XCTAssertEqual(attempt.humanRearmEpochs.count, 2)
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(wakeID: attempt.wakeID, localInputEpoch: attempt.localInputEpoch)
        ))
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertEqual(
            Set(fixture.session.agentSessionLinkConsumedTargetLocalEpochs.values),
            [6]
        )
        XCTAssertEqual(fixture.session.agentSessionLinkConsumedTargetLocalEpochs.count, 2)
    }

    func testLateAndDuplicateAcceptanceCannotOverwriteNewerLocalUserOrigin() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
        reserved.task?.cancel()
        fixture.session.pendingOversightAutoWake = AgentSessionLinkAutoWakeAttempt(
            wakeID: reserved.wakeID,
            observerEndpoint: reserved.observerEndpoint,
            queueEpoch: reserved.queueEpoch,
            localInputEpoch: reserved.localInputEpoch,
            queueRevision: reserved.queueRevision,
            wakeFingerprint: reserved.wakeFingerprint,
            attemptedFingerprint: reserved.wakeFingerprint,
            humanRearmEpochs: reserved.humanRearmEpochs,
            physicalOutcome: .ambiguous,
            phase: .dispatching,
            task: nil
        )
        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .autoWake(
                wakeID: reserved.wakeID,
                localInputEpoch: reserved.localInputEpoch
            )
        ))

        fixture.session.agentSessionLinkLocalInputEpoch &+= 1
        fixture.session.agentSessionLinkTurnOrigin = .localUser
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertEqual(fixture.session.agentSessionLinkTurnOrigin, .localUser)
        XCTAssertEqual(fixture.session.items.count(where: { $0.id == reserved.wakeID }), 1)

        fixture.session.agentSessionLinkTurnOrigin = .localUser
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)
        XCTAssertEqual(fixture.session.agentSessionLinkTurnOrigin, .localUser)
        XCTAssertEqual(fixture.session.items.count(where: { $0.id == reserved.wakeID }), 1)
    }

    func testAmbiguousFailureSuppressesOnlyThePhysicallyAttemptedFingerprint() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
        reserved.task?.cancel()
        var dispatching = reserved
        dispatching.phase = .dispatching
        dispatching.attemptedFingerprint = reserved.wakeFingerprint
        dispatching.physicalOutcome = .ambiguous
        fixture.session.pendingOversightAutoWake = dispatching

        try publishLane(
            fixture,
            linkSetRevision: 1,
            queueRevision: 2,
            targetIndices: [1],
            edgeSequenceOffset: 10
        )
        let newerFingerprint = try XCTUnwrap(fixture.session.pendingOversightAutoWake).wakeFingerprint
        XCTAssertNotEqual(newerFingerprint, reserved.wakeFingerprint)

        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchFailure(
            for: fixture.session,
            dispatchID: .autoWake(
                wakeID: reserved.wakeID,
                localInputEpoch: reserved.localInputEpoch
            )
        )
        XCTAssertEqual(fixture.session.suppressedOversightWakeFingerprint, reserved.wakeFingerprint)
        XCTAssertNotEqual(fixture.session.suppressedOversightWakeFingerprint, newerFingerprint)
        XCTAssertEqual(
            fixture.session.agentSessionLinkTurnOrigin,
            .laneUpdateAutoWake(wakeID: reserved.wakeID)
        )
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "ambiguous delivery must leave the lane receipt unacknowledged"
        )
    }

    func testNaturalReceiptCompetitionBeforeProviderBoundaryFailsClosedAndReleasesIdentity() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
        reserved.task?.cancel()
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = nil
        fixture.session.pendingOversightAutoWake = preparing

        try publishLane(fixture, linkSetRevision: 1, queueRevision: 2, targetIndices: [])
        XCTAssertEqual(fixture.session.pendingOversightAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session,
            dispatchID: .autoWake(
                wakeID: reserved.wakeID,
                localInputEpoch: reserved.localInputEpoch
            )
        ))
        XCTAssertNil(fixture.session.pendingOversightAutoWake)
        XCTAssertNil(fixture.session.suppressedOversightWakeFingerprint)
        XCTAssertEqual(fixture.session.agentSessionLinkTurnOrigin, .localUser)
    }

    func testPreparingCancellationKeepsFinalizerAndSettlesWithoutConsumingLane() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        fixture.session.autoWakeOnOversightUpdates = true
        fixture.session.runState = .running
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)
        let reserved = try XCTUnwrap(fixture.session.pendingOversightAutoWake)
        reserved.task?.cancel()
        let finalizer = Task { @MainActor in }
        var preparing = reserved
        preparing.phase = .preparingDispatch
        preparing.task = finalizer
        fixture.session.pendingOversightAutoWake = preparing
        let itemCount = fixture.session.items.count

        fixture.viewModel.cancelAgentSessionLinkAutoWake(
            for: reserved.observerEndpoint,
            reason: .settingDisabled
        )

        XCTAssertEqual(fixture.session.pendingOversightAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertFalse(finalizer.isCancelled, "preparing cancellation must not cancel its only finalizer")

        let dispatchID = AgentSessionLinkPromptDispatchID.codexNativeSend(UUID())
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(
            for: fixture.session,
            dispatchID: dispatchID
        )
        fixture.viewModel.agentSessionLinkRecordPhysicalDispatchNotAttempted(
            for: fixture.session,
            dispatchID: dispatchID
        )

        XCTAssertNil(fixture.session.pendingOversightAutoWake)
        XCTAssertEqual(fixture.session.items.count, itemCount, "a pre-call cancellation writes no provider error or provenance row")
        XCTAssertNil(fixture.session.suppressedOversightWakeFingerprint)
        XCTAssertEqual(fixture.session.agentSessionLinkTurnOrigin, .localUser)
        XCTAssertNotNil(
            fixture.viewModel.agentSessionLinkPassiveNoticesBySessionID[fixture.sessionID],
            "the unaccepted lane batch remains owed"
        )

        fixture.session.runState = .idle
        let readiness = AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(
            session: fixture.session,
            endpointMatchesGrant: true,
            isClosing: false,
            observerTurnOrigin: fixture.session.agentSessionLinkTurnOrigin
        )
        XCTAssertEqual(AgentSessionLinkDeliveryReadiness.evaluate(snapshot: readiness), .ready)
    }

    /// An ordinary turn that happens to carry a lane batch is not a wake.
    ///
    /// It acknowledges the queue exactly as before, but it must not claim lane-update origin and must
    /// not write a provenance row for a turn the user started.
    func testAnOrdinaryDispatchCarryingALaneBatchIsNotTreatedAsAWake() throws {
        let fixture = try makeFixture()
        try publishInventory(fixture, revision: 1)
        try publishLane(fixture, linkSetRevision: 1, queueRevision: 1)

        let claim = try XCTUnwrap(fixture.viewModel.agentSessionLinkPromptClaim(
            for: fixture.session,
            dispatchID: .claudeNativeSend(UUID())
        ))
        XCTAssertNotNil(claim.passive)
        let itemsBefore = fixture.session.items.count
        fixture.viewModel.acceptAgentSessionLinkPromptClaim(claim)

        XCTAssertEqual(fixture.session.agentSessionLinkTurnOrigin, .localUser)
        XCTAssertEqual(fixture.session.items.count, itemsBefore)
    }

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let sessionID: UUID
        let tabID: UUID
        /// Retained: the view model holds its workspace manager weakly.
        let workspaceManager: WorkspaceManagerViewModel
    }

    private func makeFixture(catalogReady: Bool = true) throws -> Fixture {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Oversee auto-wake seam"
        )
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        session.installRunID(UUID())
        let sessionID = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        let fixture = Fixture(
            viewModel: viewModel,
            session: session,
            sessionID: sessionID,
            tabID: tabID,
            workspaceManager: workspaceManager
        )
        if catalogReady {
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(viewModel, tabID: tabID)
            let runID = try XCTUnwrap(session.runID)
            viewModel.agentSessionLinkPublishRunCatalogProjection(
                AgentSessionLinkRunCatalogProjection(
                    runID: runID,
                    routeToken: AgentSessionLinkRunCatalogRouteToken(
                        runID: runID,
                        observerEndpoint: endpoint,
                        connectionID: UUID(),
                        routingAuthorityGeneration: 1,
                        connectionLifecycleGeneration: 1
                    ),
                    projectionRevision: 1,
                    hasAgentSessionLink: true
                ),
                to: endpoint
            )
        }
        return fixture
    }

    private func publishInventory(_ fixture: Fixture, revision: UInt64) throws {
        try fixture.viewModel.agentSessionLinkPublishPromptInventory(
            Self.inventory(observerSessionID: fixture.sessionID, revision: revision),
            to: AgentSessionLinkEndpointTestSupport.endpoint(
                fixture.viewModel,
                tabID: fixture.tabID
            )
        )
    }

    @discardableResult
    private func publishCatalogProjection(
        _ fixture: Fixture,
        revision: UInt64,
        hasAgentSessionLink: Bool
    ) throws -> AgentSessionLinkRunCatalogProjection {
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        let runID = try XCTUnwrap(fixture.session.runID)
        let projection = AgentSessionLinkRunCatalogProjection(
            runID: runID,
            routeToken: AgentSessionLinkRunCatalogRouteToken(
                runID: runID,
                observerEndpoint: endpoint,
                connectionID: UUID(),
                routingAuthorityGeneration: 1,
                connectionLifecycleGeneration: 1
            ),
            projectionRevision: revision,
            hasAgentSessionLink: hasAgentSessionLink
        )
        fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(projection, to: endpoint)
        return projection
    }

    private func publishLane(
        _ fixture: Fixture,
        linkSetRevision: UInt64,
        queueRevision: UInt64,
        targetIndices: [Int] = [0],
        laneIndices: [Int]? = nil,
        edgeSequenceOffset: UInt64 = 0,
        targetLocalInputEpoch: UInt64 = 0,
        targetTurnIsLocalUser: Bool = false,
        overflow: UInt64 = 0,
        selectedTargetIndices: Set<Int>? = nil
    ) throws {
        let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
            fixture.viewModel,
            tabID: fixture.tabID
        )
        if let selectedTargetIndices {
            // Selection is live session state; the lane flag is only the projection of it that this
            // publication froze. Writing both keeps a fixture from advertising a selection the
            // coordinator's live fence would (correctly) refuse.
            fixture.session.agentSessionLinkAutoWakeTargetSessionIDs = Set(
                selectedTargetIndices.map(Self.targetID)
            )
        }
        let effectiveSelectedIndices = Set((laneIndices ?? targetIndices).filter {
            fixture.session.autoWakeOnOversightUpdates
                || fixture.session.agentSessionLinkAutoWakeTargetSessionIDs.contains(Self.targetID($0))
        })
        fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(
            Self.laneSnapshot(
                observerEndpoint: endpoint,
                linkSetRevision: linkSetRevision,
                queueRevision: queueRevision,
                targetIndices: targetIndices,
                laneIndices: laneIndices,
                edgeSequenceOffset: edgeSequenceOffset,
                targetLocalInputEpoch: targetLocalInputEpoch,
                targetTurnIsLocalUser: targetTurnIsLocalUser,
                overflow: overflow,
                selectedTargetIndices: effectiveSelectedIndices
            ),
            to: endpoint
        )
    }

    // MARK: - Values

    private static func targetID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "0000000%d-0000-0000-0000-000000005501", index))!
    }

    private static func inventory(
        observerSessionID: UUID,
        revision: UInt64
    ) -> AgentSessionLinkPromptInventory {
        AgentSessionLinkPromptInventory(
            observerSessionID: observerSessionID,
            linkSetRevision: revision,
            items: [0, 1].map { index in
                AgentSessionLinkPromptInventoryItem(
                    targetSessionID: targetID(index),
                    displayName: index == 0 ? "Build API" : "Review API",
                    capabilityNames: ["poll", "read", "send_when_idle", "wait"]
                )
            }
        )
    }

    private static func epoch(observerSessionID: UUID) -> AgentSessionLinkPromptEpoch {
        AgentSessionLinkPromptEpoch(
            endpoint: DomainAgentSessionLinkEndpointIdentity(
                windowID: 1,
                workspaceID: UUID(),
                tabID: UUID(),
                sessionID: observerSessionID,
                persistentBindingGeneration: UUID(),
                bindingTransitionGeneration: 1
            ),
            allowsSupplement: true
        )
    }

    static func laneReference(_ index: Int) -> DomainAgentSessionLinkReference {
        DomainAgentSessionLinkReference(
            linkID: UUID(uuidString: String(format: "0000000F-0000-0000-0000-%012d", index + 1))!,
            generation: 1
        )
    }

    private static func laneTargetEndpoint(_ index: Int) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: 2,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: targetID(index),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        )
    }

    /// `laneIndices` defaults to the entry set, but is separable so a test can reproduce the
    /// activation publication: lanes exist and carry a target epoch while no status edge has been
    /// queued for them yet.
    private static func laneSnapshot(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        linkSetRevision: UInt64 = 1,
        queueRevision: UInt64 = 1,
        targetIndices: [Int] = [0],
        laneIndices: [Int]? = nil,
        edgeSequenceOffset: UInt64 = 0,
        targetLocalInputEpoch: UInt64 = 0,
        targetTurnIsLocalUser: Bool = false,
        overflow: UInt64 = 0,
        selectedTargetIndices: Set<Int>? = nil
    ) -> AgentSessionLinkPassiveStatusNotices.Snapshot {
        let entries = targetIndices.map { index in
            AgentSessionLinkPassiveStatusNotices.PendingEntry(
                reference: laneReference(index),
                targetEndpoint: laneTargetEndpoint(index),
                targetSessionID: targetID(index),
                displayName: "Build API",
                fromStatus: .running,
                toStatus: .idle,
                observedAt: Date(timeIntervalSince1970: 0),
                idleForSend: true,
                latestVisibleAssistantPreview: "Done.",
                changeSequence: UInt64(index + 1) + edgeSequenceOffset
            )
        }
        return AgentSessionLinkPassiveStatusNotices.Snapshot(
            observerEndpoint: observerEndpoint,
            queueEpoch: UUID(uuidString: "0000000F-0000-0000-0000-000000005501")!,
            queueRevision: queueRevision,
            linkSetRevision: linkSetRevision,
            isEnabled: true,
            isDeliverable: true,
            entries: entries,
            unacknowledgedOverflowCount: overflow,
            overflowProduced: overflow,
            autoWakeLanes: (laneIndices ?? targetIndices).map { index in
                AgentSessionLinkPassiveStatusNotices.AutoWakeLane(
                    reference: laneReference(index),
                    targetEndpoint: laneTargetEndpoint(index),
                    targetSessionID: targetID(index),
                    targetLocalInputEpoch: targetLocalInputEpoch,
                    targetTurnIsLocalUser: targetTurnIsLocalUser,
                    isEffectivelySelected: selectedTargetIndices?.contains(index) ?? true
                )
            }
        )
    }
}
