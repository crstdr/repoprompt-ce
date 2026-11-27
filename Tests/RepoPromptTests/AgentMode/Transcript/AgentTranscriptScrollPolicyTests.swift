import AppKit
import CoreGraphics
import Foundation
@testable import RepoPromptApp
import SwiftUI
import XCTest

final class AgentTranscriptActivationRepaintRemountPolicyTests: XCTestCase {
    func testEnteredHydratedLiveBottomActivationProducesRemountKey() {
        let tabID = UUID()
        let key = AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: AgentTranscriptRestoreSignal(tabID: UUID(), bindingsHydrated: true, presentationRevision: 1),
            newSignal: AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 7),
            currentTabID: tabID,
            rehydratePhase: .awaitingHydration(tabID: tabID, target: .liveBottom),
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 42
        )

        XCTAssertEqual(key, AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 7, layoutPassToken: 42))
    }

    func testDuplicateRevisionExceededLimitDetachedOrIdleActivationSuppressesRemount() {
        let tabID = UUID()
        let oldSignal = AgentTranscriptRestoreSignal(tabID: nil, bindingsHydrated: false, presentationRevision: 0)
        let newSignal = AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 3)
        let previousKey = AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 3, layoutPassToken: 1)

        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingLayout(tabID: tabID, presentationRevision: 3, target: .liveBottom),
            lastRemountKey: previousKey,
            remountCount: 0,
            layoutPassToken: 2
        ))
        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingLayout(tabID: tabID, presentationRevision: 3, target: .liveBottom),
            lastRemountKey: nil,
            remountCount: AgentTranscriptActivationRepaintRemountPolicy.maximumRemountsPerActivation,
            layoutPassToken: 2
        ))
        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingHydration(tabID: tabID, target: .detached(nil)),
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 0
        ))
        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .idle,
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 0
        ))
    }
}

/// Pure scroll-policy contracts behind Agent Mode transcript auto-follow, detach and restore.
final class AgentTranscriptScrollPolicyTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func runtime(
        isPinnedToLiveBottom: Bool = true,
        isDetachedFromLiveBottom: Bool = false,
        isUserInteractingWithScroll: Bool = false,
        isInteractionBlocked: Bool = false,
        isRehydrateRestoreActive: Bool = false,
        isProgrammaticScrollInFlight: Bool = false,
        canScrollTowardLiveBottom: Bool = false,
        distanceToBottom: CGFloat = 0
    ) -> AgentTranscriptScrollRuntimeState {
        AgentTranscriptScrollRuntimeState(
            armingState: .armed,
            isPinnedToLiveBottom: isPinnedToLiveBottom,
            isDetachedFromLiveBottom: isDetachedFromLiveBottom,
            isUserInteractingWithScroll: isUserInteractingWithScroll,
            isInteractionBlocked: isInteractionBlocked,
            isRehydrateRestoreActive: isRehydrateRestoreActive,
            isProgrammaticScrollInFlight: isProgrammaticScrollInFlight,
            canScrollTowardHistory: true,
            canScrollTowardLiveBottom: canScrollTowardLiveBottom,
            distanceToBottom: distanceToBottom
        )
    }

    private func progress(visibleMinYFrom baseline: CGFloat, to current: CGFloat) -> AgentTranscriptViewportProgress {
        AgentTranscriptViewportProgress(
            baselineDistanceToBottom: 0,
            currentDistanceToBottom: 0,
            baselineVisibleMinY: baseline,
            currentVisibleMinY: current
        )
    }

    private func metrics(
        distanceToBottom: CGFloat = 0,
        visibleMinY: CGFloat = 0,
        contentHeight: CGFloat = 2000,
        viewportHeight: CGFloat = 600
    ) -> AgentTranscriptScrollMetrics {
        AgentTranscriptScrollMetrics(
            distanceToBottom: distanceToBottom,
            visibleMinY: visibleMinY,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight
        )
    }

    // MARK: - AgentTranscriptAutoFollowRearmPolicy

    func testDetachRequiresUserTowardHistoryGestureThatEscapesTheThreshold() {
        let interacting = runtime(isUserInteractingWithScroll: true)
        func shouldDetach(
            _ state: AgentTranscriptScrollRuntimeState,
            intent: DetachedManualScrollDirection = .towardHistory,
            escape: CGFloat,
            suppressGeometry: Bool = false
        ) -> Bool {
            AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottom(
                runtime: state,
                latestManualIntent: intent,
                progress: progress(visibleMinYFrom: 1400, to: 1400 - escape),
                minimumViewportEscapeDistance: 24,
                suppressGeometryDetach: suppressGeometry,
                suppressRepinGraceDetach: false
            )
        }

        XCTAssertTrue(shouldDetach(interacting, escape: 24))
        XCTAssertFalse(shouldDetach(interacting, escape: 23), "sub-threshold movement must not detach")
        XCTAssertFalse(shouldDetach(interacting, intent: .towardLiveBottom, escape: 200))
        XCTAssertFalse(shouldDetach(runtime(), escape: 200), "content growth without a gesture never detaches")
        XCTAssertFalse(shouldDetach(interacting, escape: 200, suppressGeometry: true))
    }

    func testIdleTransitionDetachHonorsArmingAndRestoreState() {
        func shouldDetach(
            _ state: AgentTranscriptScrollRuntimeState,
            armed: Bool = true,
            towardHistory: Bool = true
        ) -> Bool {
            AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottomAfterRunBecomesIdle(
                runtime: state,
                idleTransitionArmed: armed,
                hasTowardHistoryManualIntent: towardHistory,
                progress: progress(visibleMinYFrom: 900, to: 850),
                minimumEscapeDistance: 6
            )
        }

        XCTAssertTrue(shouldDetach(runtime()))
        XCTAssertFalse(shouldDetach(runtime(), armed: false))
        XCTAssertFalse(shouldDetach(runtime(), towardHistory: false))
        XCTAssertFalse(shouldDetach(runtime(isRehydrateRestoreActive: true)))
        XCTAssertFalse(shouldDetach(runtime(isPinnedToLiveBottom: false, isDetachedFromLiveBottom: true)))
    }

    func testDetachedViewportAtActualBottomForcesRepinOnlyWhenNothingElseMovesIt() {
        let detachedAtBottom = runtime(isPinnedToLiveBottom: false, isDetachedFromLiveBottom: true, distanceToBottom: 1)
        XCTAssertTrue(AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
            runtime: detachedAtBottom,
            actualBottomDistanceThreshold: 1
        ))
        XCTAssertFalse(AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
            runtime: runtime(isPinnedToLiveBottom: false, isDetachedFromLiveBottom: true, distanceToBottom: 2),
            actualBottomDistanceThreshold: 1
        ))
        XCTAssertFalse(AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
            runtime: runtime(
                isPinnedToLiveBottom: false,
                isDetachedFromLiveBottom: true,
                isProgrammaticScrollInFlight: true,
                distanceToBottom: 0
            ),
            actualBottomDistanceThreshold: 1
        ))
        XCTAssertFalse(AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
            runtime: runtime(
                isPinnedToLiveBottom: false,
                isDetachedFromLiveBottom: true,
                canScrollTowardLiveBottom: true,
                distanceToBottom: 0
            ),
            actualBottomDistanceThreshold: 1
        ))
    }

    // MARK: - AgentTranscriptScrollProgressPolicy / UserScrollIntentResolver

    func testManualScrollDistanceDeltaIgnoresRelayout() {
        let before = metrics(distanceToBottom: 100)
        XCTAssertEqual(
            AgentTranscriptScrollProgressPolicy.effectiveDistanceDeltaForManualScroll(
                oldMetrics: before,
                newMetrics: metrics(distanceToBottom: 160),
                layoutMutationThreshold: 2
            ),
            60
        )
        XCTAssertEqual(
            AgentTranscriptScrollProgressPolicy.effectiveDistanceDeltaForManualScroll(
                oldMetrics: before,
                newMetrics: metrics(distanceToBottom: 400, contentHeight: 2300),
                layoutMutationThreshold: 2
            ),
            0,
            "content growth must not read as a manual scroll toward history"
        )
        XCTAssertEqual(
            AgentTranscriptScrollProgressPolicy.effectiveDistanceDeltaForManualScroll(
                oldMetrics: before,
                newMetrics: metrics(distanceToBottom: 130, viewportHeight: 570),
                layoutMutationThreshold: 2
            ),
            0
        )
    }

    func testIntentResolverDirectionsAndPinnedDistanceGrowthGuard() {
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolve(distanceDelta: 24, visibleMinYDelta: 0, distanceThreshold: 24, visibleMinYThreshold: 12),
            .towardHistory
        )
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolve(distanceDelta: 0, visibleMinYDelta: 12, distanceThreshold: 24, visibleMinYThreshold: 12),
            .towardLiveBottom
        )
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolve(distanceDelta: 23, visibleMinYDelta: -11, distanceThreshold: 24, visibleMinYThreshold: 12),
            .unknown
        )
        // While pinned, distance growth alone (streaming content) is never upward intent.
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolvePinnedLiveBottomFollowIntent(
                distanceDelta: 500,
                visibleMinYDelta: 0,
                distanceThreshold: 24,
                visibleMinYThreshold: 12
            ),
            .unknown
        )
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolvePinnedLiveBottomFollowIntent(
                distanceDelta: 0,
                visibleMinYDelta: -12,
                distanceThreshold: 24,
                visibleMinYThreshold: 12
            ),
            .towardHistory
        )
        XCTAssertEqual(AgentTranscriptUserScrollIntentResolver.resolve(verticalVelocity: 0.5), .unknown)
        XCTAssertEqual(AgentTranscriptUserScrollIntentResolver.resolve(verticalVelocity: 3), .towardHistory)
        XCTAssertEqual(AgentTranscriptUserScrollIntentResolver.resolve(verticalVelocity: -3), .towardLiveBottom)
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolveFromCumulativeViewportMovement(visibleMinYDelta: -6, visibleMinYThreshold: 6),
            .towardHistory
        )
    }

    func testMeaningfulManualProgressUsesViewportOriginInTheIntendedDirection() {
        let movedUp = progress(visibleMinYFrom: 1000, to: 990)
        XCTAssertTrue(AgentTranscriptScrollProgressPolicy.hasMeaningfulManualProgress(
            direction: .towardHistory,
            progress: movedUp,
            distanceThreshold: 8,
            visibleMinYThreshold: 6
        ))
        XCTAssertFalse(AgentTranscriptScrollProgressPolicy.hasMeaningfulManualProgress(
            direction: .towardLiveBottom,
            progress: movedUp,
            distanceThreshold: 8,
            visibleMinYThreshold: 6
        ))
        XCTAssertTrue(AgentTranscriptScrollProgressPolicy.hasMeaningfulManualProgress(
            direction: .unknown,
            progress: movedUp,
            distanceThreshold: 8,
            visibleMinYThreshold: 6
        ))
        XCTAssertFalse(AgentTranscriptScrollProgressPolicy.hasTowardHistoryViewportEscape(
            progress: movedUp,
            visibleMinYThreshold: 0
        ), "a zero threshold disables escape detection")
    }

    // MARK: - AgentTranscriptRehydrateRestoreLayoutPolicy

    func testLiveBottomRestoreCompletesOnlyForTheCurrentLayoutPassAtTheBottom() {
        let tabID = UUID()
        let sampleKey = AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 4, layoutPassToken: 9)
        func canComplete(revision: Int = 4, token: UInt64 = 9, nearBottom: Bool = true) -> Bool {
            AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
                currentLayoutSampleKey: sampleKey,
                tabID: tabID,
                presentationRevision: revision,
                layoutPassToken: token,
                isNearBottom: nearBottom
            )
        }

        XCTAssertTrue(canComplete())
        XCTAssertFalse(canComplete(nearBottom: false))
        XCTAssertFalse(canComplete(revision: 5), "a newer presentation needs its own layout sample")
        XCTAssertFalse(canComplete(token: 10), "a stale layout pass must not complete the restore")
        XCTAssertFalse(AgentTranscriptRehydrateRestoreLayoutPolicy.hasValidLayoutSample(metrics(viewportHeight: 0)))
        XCTAssertTrue(AgentTranscriptRehydrateRestoreLayoutPolicy.hasValidLayoutSample(metrics(viewportHeight: 1)))
    }

    // MARK: - AgentTranscriptPinnedBottomProtectionPolicy

    func testPinnedBottomProtectionArmsOnlyForUndisturbedPinnedSettles() {
        XCTAssertTrue(AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
            runtime: runtime(distanceToBottom: 24),
            nearBottomThreshold: 24
        ))
        XCTAssertFalse(AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
            runtime: runtime(distanceToBottom: 25),
            nearBottomThreshold: 24
        ))
        XCTAssertFalse(AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
            runtime: runtime(isUserInteractingWithScroll: true),
            nearBottomThreshold: 24
        ))
        XCTAssertFalse(AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
            runtime: runtime(isInteractionBlocked: true),
            nearBottomThreshold: 24
        ))
        XCTAssertTrue(AgentTranscriptPinnedBottomProtectionPolicy.shouldRemainActiveAfterSmoothSendCompletion(
            runtime: runtime(distanceToBottom: 400)
        ))
        XCTAssertFalse(AgentTranscriptPinnedBottomProtectionPolicy.shouldRemainActiveAfterSmoothSendCompletion(
            runtime: runtime(isPinnedToLiveBottom: false, isDetachedFromLiveBottom: true)
        ))
        XCTAssertTrue(AgentTranscriptPinnedBottomProtectionPolicy.shouldPreserveLastResolvedScrollView(
            hasExistingScrollView: true,
            hasNewlyResolvedScrollView: false
        ))
        XCTAssertFalse(AgentTranscriptPinnedBottomProtectionPolicy.shouldPreserveLastResolvedScrollView(
            hasExistingScrollView: true,
            hasNewlyResolvedScrollView: true
        ))
    }

    // MARK: - AgentTranscriptBottomScrollOutcomeLayoutPolicy

    func testBottomScrollOutcomeWaitsForLayoutToGoQuiet() {
        let base = metrics()
        XCTAssertFalse(AgentTranscriptBottomScrollOutcomeLayoutPolicy.hasMaterialLayoutMutation(
            oldMetrics: base,
            newMetrics: metrics(distanceToBottom: 300, contentHeight: 2001.9),
            contentHeightThreshold: 2,
            viewportHeightThreshold: 2
        ), "offset-only movement is not a layout mutation")
        XCTAssertTrue(AgentTranscriptBottomScrollOutcomeLayoutPolicy.hasMaterialLayoutMutation(
            oldMetrics: base,
            newMetrics: metrics(contentHeight: 2002),
            contentHeightThreshold: 2,
            viewportHeightThreshold: 2
        ))
        XCTAssertTrue(AgentTranscriptBottomScrollOutcomeLayoutPolicy.hasMaterialLayoutMutation(
            oldMetrics: base,
            newMetrics: metrics(viewportHeight: 598),
            contentHeightThreshold: 2,
            viewportHeightThreshold: 2
        ))

        let mutationAt = referenceDate
        XCTAssertNil(AgentTranscriptBottomScrollOutcomeLayoutPolicy.remainingQuietDelay(
            lastLayoutMutationAt: nil,
            now: mutationAt,
            quietPeriod: 0.12
        ))
        let remaining = AgentTranscriptBottomScrollOutcomeLayoutPolicy.remainingQuietDelay(
            lastLayoutMutationAt: mutationAt,
            now: mutationAt.addingTimeInterval(0.05),
            quietPeriod: 0.12
        )
        XCTAssertEqual(try XCTUnwrap(remaining), 0.07, accuracy: 0.0001)
        XCTAssertNil(AgentTranscriptBottomScrollOutcomeLayoutPolicy.remainingQuietDelay(
            lastLayoutMutationAt: mutationAt,
            now: mutationAt.addingTimeInterval(0.13),
            quietPeriod: 0.12
        ))
    }

    // MARK: - AgentTranscriptIdleBoundaryProgressResolver

    func testIdleBoundaryProgressUsesActiveOrFreshCompletedSessionOnly() throws {
        let baseline = metrics(distanceToBottom: 0, visibleMinY: 1400)
        let active = AgentTranscriptUserScrollSession(
            startedAt: referenceDate,
            baselineMetrics: baseline,
            latestMetrics: metrics(distanceToBottom: 80, visibleMinY: 1320),
            latestIntent: .towardHistory,
            lastIntentAt: referenceDate,
            observedProgress: true
        )
        let fromActive = try XCTUnwrap(AgentTranscriptIdleBoundaryProgressResolver.resolve(
            activeSession: active,
            lastCompletedSession: nil,
            currentMetrics: metrics(distanceToBottom: 40, visibleMinY: 1360),
            now: referenceDate,
            freshnessWindow: 1.2
        ))
        XCTAssertTrue(fromActive.hasTowardHistoryManualIntent)
        // The furthest-from-bottom observation wins so a settling bounce cannot erase intent.
        XCTAssertEqual(fromActive.progress.currentDistanceToBottom, 80)
        XCTAssertEqual(fromActive.progress.currentVisibleMinY, 1320)

        let completed = AgentTranscriptCompletedUserScrollSession(
            startedAt: referenceDate,
            endedAt: referenceDate,
            baselineMetrics: baseline,
            finalMetrics: metrics(distanceToBottom: 60, visibleMinY: 1340),
            latestIntent: .towardLiveBottom,
            observedProgress: true
        )
        let fresh = try XCTUnwrap(AgentTranscriptIdleBoundaryProgressResolver.resolve(
            activeSession: nil,
            lastCompletedSession: completed,
            currentMetrics: metrics(distanceToBottom: 10, visibleMinY: 1390),
            now: referenceDate.addingTimeInterval(1.1),
            freshnessWindow: 1.2
        ))
        XCTAssertFalse(fresh.hasTowardHistoryManualIntent)
        XCTAssertEqual(fresh.progress.currentVisibleMinY, 1340)

        XCTAssertNil(AgentTranscriptIdleBoundaryProgressResolver.resolve(
            activeSession: nil,
            lastCompletedSession: completed,
            currentMetrics: baseline,
            now: referenceDate.addingTimeInterval(1.3),
            freshnessWindow: 1.2
        ), "stale completed gestures must not detach at the idle boundary")
    }

    // MARK: - AgentTranscriptManualDetachOverridePolicy

    func testManualDetachOverrideIsActiveStrictlyBeforeItsDeadline() {
        let until = referenceDate.addingTimeInterval(0.75)
        XCTAssertTrue(AgentTranscriptManualDetachOverridePolicy.isActive(until: until, now: referenceDate))
        XCTAssertFalse(AgentTranscriptManualDetachOverridePolicy.isActive(until: until, now: until))
        XCTAssertFalse(AgentTranscriptManualDetachOverridePolicy.isActive(until: nil, now: referenceDate))
        XCTAssertTrue(AgentTranscriptManualDetachOverridePolicy.shouldSuppressActualBottomRepin(until: until, now: referenceDate))
        XCTAssertTrue(AgentTranscriptManualDetachOverridePolicy.shouldSuppressDetachedRevisionImmediateRepin(until: until, now: referenceDate))
        XCTAssertFalse(AgentTranscriptManualDetachOverridePolicy.shouldSuppressGeometryRepin(until: until, now: until.addingTimeInterval(0.01)))
    }
}

final class TranscriptScrollAnchorModelTests: XCTestCase {
    private let turnA = UUID()
    private let turnB = UUID()
    private let viewportHeight: CGFloat = 400

    /// Rows stacked top to bottom with no gaps. Each spec is (blockID, turnID, height).
    private func layout(_ specs: [(String, UUID?, CGFloat)]) -> TranscriptScrollAnchorLayout {
        var y: CGFloat = 0
        var rows: [TranscriptScrollAnchorRowFrame] = []
        for (blockID, turnID, height) in specs {
            rows.append(.init(blockID: blockID, turnID: turnID, minY: y, height: height))
            y += height
        }
        return TranscriptScrollAnchorLayout(rows: rows, contentHeight: y, viewportHeight: viewportHeight)
    }

    /// 10 rows x 200pt = 2000pt content, max clip origin 1600.
    private var baseSpecs: [(String, UUID?, CGFloat)] {
        (0 ..< 10).map { index in ("b\(index)", index < 5 ? turnA : turnB, 200) }
    }

    // MARK: - Transitions and threshold

    func testUserScrollWithinFollowThresholdFollowsAndBeyondItReadsTopVisibleRow() {
        let base = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()

        model.userDidScroll(clipOriginY: base.maxClipOriginY - 24, layout: base)
        XCTAssertEqual(model.mode, .following, "exactly at the 24pt threshold still follows")

        model.userDidScroll(clipOriginY: base.maxClipOriginY - 25, layout: base)
        // clip origin 1575 sits inside b7 (1400..<1600): its top is 175pt above the viewport.
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b7", offsetFromViewportTop: -175))

        model.userDidScroll(clipOriginY: base.maxClipOriginY, layout: base)
        XCTAssertTrue(model.isFollowing, "scrolling back to the bottom re-follows")
    }

    // MARK: - Compensation math

    func testHeightChangeAboveAnchorShiftsClipOriginByTheDelta() {
        let old = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 900, layout: old) // inside b4, offset -100

        var grown = baseSpecs
        grown[1].2 = 350 // b1 (above the anchor) grows by 150
        let adjustment = model.layoutDidChange(from: old, to: layout(grown), clipOriginY: 900)

        XCTAssertEqual(adjustment, .setClipOrigin(1050))
        XCTAssertEqual(adjustment.delta(from: 900), 150)
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b4", offsetFromViewportTop: -100))
    }

    func testHeightChangeBelowAnchorLeavesReadingViewportAlone() {
        let old = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 900, layout: old)

        var grown = baseSpecs
        grown[8].2 = 600
        XCTAssertEqual(model.layoutDidChange(from: old, to: layout(grown), clipOriginY: 900), .none)
    }

    func testAppendWhileReadingDoesNotMoveAndAppendWhileFollowingPinsToNewBottom() {
        let old = layout(baseSpecs)
        let appended = layout(baseSpecs + [("b10", turnB, 300)])

        var reading = TranscriptScrollAnchorModel()
        reading.userDidScroll(clipOriginY: 600, layout: old)
        XCTAssertEqual(reading.didAppend(from: old, to: appended, clipOriginY: 600), .none)
        XCTAssertFalse(reading.isFollowing)

        var following = TranscriptScrollAnchorModel()
        XCTAssertEqual(
            following.didAppend(from: old, to: appended, clipOriginY: old.maxClipOriginY),
            .setClipOrigin(appended.maxClipOriginY)
        )
    }

    func testStreamingGrowthDoesNotMoveReaderButPinsFollower() {
        var streamingSpecs = baseSpecs
        let old = layout(streamingSpecs)
        streamingSpecs[9].2 = 640 // the last (streaming) row grows by 440
        let grown = layout(streamingSpecs)

        var reader = TranscriptScrollAnchorModel()
        reader.userDidScroll(clipOriginY: 1000, layout: old)
        XCTAssertEqual(reader.streamingDidGrow(from: old, to: grown, clipOriginY: 1000), .none)

        // Anchored just above the streaming row: nothing above the anchor changed, so no move.
        var nearStreamingRow = TranscriptScrollAnchorModel()
        nearStreamingRow.userDidScroll(clipOriginY: 1500, layout: old)
        XCTAssertEqual(nearStreamingRow.mode, .reading(anchorBlockID: "b7", offsetFromViewportTop: -100))
        XCTAssertEqual(nearStreamingRow.streamingDidGrow(from: old, to: grown, clipOriginY: 1500), .none)

        var follower = TranscriptScrollAnchorModel()
        XCTAssertEqual(
            follower.streamingDidGrow(from: old, to: grown, clipOriginY: old.maxClipOriginY),
            .setClipOrigin(grown.maxClipOriginY)
        )
    }

    func testWidthChangeKeepsTheSameFractionOfTheAnchorRowAtViewportTop() {
        let old = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 850, layout: old) // a quarter into b4 (800..<1000)

        // Narrower viewport: every row reflows to 1.5x height.
        let narrow = layout(baseSpecs.map { ($0.0, $0.1, $0.2 * 1.5) })
        let adjustment = model.widthDidChange(from: old, to: narrow, clipOriginY: 850)

        // b4 now spans 1200..<1500; a quarter into it (75pt) keeps the same reading position.
        XCTAssertEqual(adjustment, .setClipOrigin(1275))
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b4", offsetFromViewportTop: -75))
    }

    func testWidthChangeKeepsNonNegativeOffsetsUnscaled() {
        let old = layout(baseSpecs)
        let narrow = layout(baseSpecs.map { ($0.0, $0.1, $0.2 * 1.5) }) // b4 moves to 1200..<1500

        // Anchor row top exactly at the viewport top: stays exactly at the top.
        var atTop = TranscriptScrollAnchorModel(mode: .reading(anchorBlockID: "b4", offsetFromViewportTop: 0))
        XCTAssertEqual(atTop.widthDidChange(from: old, to: narrow, clipOriginY: 800), .setClipOrigin(1200))
        XCTAssertEqual(atTop.mode, .reading(anchorBlockID: "b4", offsetFromViewportTop: 0))

        // Anchor row top below the viewport top: the gap above it is kept in points, not scaled.
        var belowTop = TranscriptScrollAnchorModel(mode: .reading(anchorBlockID: "b4", offsetFromViewportTop: 30))
        XCTAssertEqual(belowTop.widthDidChange(from: old, to: narrow, clipOriginY: 770), .setClipOrigin(1170))
        XCTAssertEqual(belowTop.mode, .reading(anchorBlockID: "b4", offsetFromViewportTop: 30))
    }

    func testAnchorTargetBeyondShrunkContentIsClampedAndKeepsReading() {
        let old = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 1500, layout: old) // inside b7, offset -100

        // Rows below the anchor disappear, so the anchor's preferred position is past the new end.
        let shrunk = layout(Array(baseSpecs.prefix(8)))
        let adjustment = model.layoutDidChange(from: old, to: shrunk, clipOriginY: 1500)

        XCTAssertEqual(adjustment, .setClipOrigin(shrunk.maxClipOriginY))
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b7", offsetFromViewportTop: 200))

        // Appending below the anchor must not recover the old, now-unreachable offset.
        let appended = layout(Array(baseSpecs.prefix(9)))
        XCTAssertEqual(model.didAppend(from: shrunk, to: appended, clipOriginY: shrunk.maxClipOriginY), .none)
        XCTAssertFalse(model.isFollowing)
    }

    func testClampedFallbackAnchorKeepsItsActualOffsetWhenContentAppends() {
        let old = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 1500, layout: old) // inside b7, turn B

        // The lost anchor falls back to b6, but its former viewport offset cannot be kept.
        let shrunk = layout(Array(baseSpecs.prefix(7)))
        XCTAssertEqual(
            model.layoutDidChange(from: old, to: shrunk, clipOriginY: 1500),
            .setClipOrigin(shrunk.maxClipOriginY)
        )
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b6", offsetFromViewportTop: 200))

        let appended = layout(Array(baseSpecs.prefix(7)) + [("new", turnB, 200)])
        XCTAssertEqual(model.didAppend(from: shrunk, to: appended, clipOriginY: shrunk.maxClipOriginY), .none)
        XCTAssertFalse(model.isFollowing)
    }

    func testFoldAndUnfoldAboveAnchorRoundTripsToTheOriginalClipOrigin() {
        let expanded = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 1210, layout: expanded) // inside b6

        var foldedSpecs = baseSpecs
        foldedSpecs[2].2 = 40 // b2 folds from 200 to 40
        let folded = layout(foldedSpecs)

        let foldAdjustment = model.layoutDidChange(from: expanded, to: folded, clipOriginY: 1210)
        XCTAssertEqual(foldAdjustment, .setClipOrigin(1050))
        let unfoldAdjustment = model.layoutDidChange(from: folded, to: expanded, clipOriginY: 1050)
        XCTAssertEqual(unfoldAdjustment, .setClipOrigin(1210))
    }

    // MARK: - Anchor fallback

    func testRemovedAnchorFallsBackToNearestSurvivingRowInSameTurn() {
        var specs = baseSpecs
        specs[2].2 = 100 // b2: 400..<500, b3: 500..<700, b4: 700..<900
        let old = layout(specs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 650, layout: old) // inside b3 (turn A)

        // b3 disappears (e.g. merged away); turn A still has b2 (100 away) and b4 (200 away).
        let new = layout(specs.filter { $0.0 != "b3" })
        let adjustment = model.layoutDidChange(from: old, to: new, clipOriginY: 650)

        // b2 was 250pt above the viewport top and stays exactly there.
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b2", offsetFromViewportTop: -250))
        XCTAssertEqual(adjustment, .none)

        // The fallback row is entirely above the viewport (height 100, offset -250), so
        // width reflow must preserve its offset in points rather than scale a fraction.
        var reflowedSpecs = specs.filter { $0.0 != "b3" }
        reflowedSpecs[2].2 = 200
        XCTAssertEqual(model.widthDidChange(from: new, to: layout(reflowedSpecs), clipOriginY: 650), .none)
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b2", offsetFromViewportTop: -250))
    }

    func testRemovedTurnKeepsViewportAndReadsFromNewTopVisibleRow() {
        let old = layout(baseSpecs)
        let withoutTurnA = layout(baseSpecs.filter { $0.1 != turnA }) // b5...b9 now at 0..<1000

        // Clip origin still valid in the new content: nothing moves, reading continues from b6.
        var inRange = TranscriptScrollAnchorModel()
        inRange.userDidScroll(clipOriginY: 250, layout: old) // inside b1 (turn A)
        XCTAssertEqual(inRange.layoutDidChange(from: old, to: withoutTurnA, clipOriginY: 250), .none)
        XCTAssertEqual(inRange.mode, .reading(anchorBlockID: "b6", offsetFromViewportTop: -50))

        // Clip origin past the new end: clamped, never thrown to following.
        let withoutTurnB = layout(baseSpecs.filter { $0.1 != turnB }) // b0...b4 at 0..<1000
        var pastEnd = TranscriptScrollAnchorModel()
        pastEnd.userDidScroll(clipOriginY: 1500, layout: old) // inside b7 (turn B)
        XCTAssertEqual(
            pastEnd.layoutDidChange(from: old, to: withoutTurnB, clipOriginY: 1500),
            .setClipOrigin(withoutTurnB.maxClipOriginY)
        )
        XCTAssertEqual(pastEnd.mode, .reading(anchorBlockID: "b3", offsetFromViewportTop: 0))
    }

    func testRemovedAnchorWithoutTurnKeepsViewportInsteadOfUsingSiblings() {
        var specs = baseSpecs
        specs[3].1 = nil // b3 (600..<800) has no turn
        let old = layout(specs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 650, layout: old)

        let new = layout(specs.filter { $0.0 != "b3" }) // b4 slides up to 600..<800
        XCTAssertEqual(model.layoutDidChange(from: old, to: new, clipOriginY: 650), .none)
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b4", offsetFromViewportTop: -50))
    }

    // MARK: - Explicit jumps

    func testJumpsToTopBlockAndBottom() {
        let base = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()

        XCTAssertEqual(model.jump(to: .top, layout: base, clipOriginY: 1600), .setClipOrigin(0))
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b0", offsetFromViewportTop: 0))

        XCTAssertEqual(model.jump(to: .block("b5"), layout: base, clipOriginY: 0), .setClipOrigin(1000))
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b5", offsetFromViewportTop: 0))

        // A block whose top cannot reach the viewport top lands at the bottom and follows.
        XCTAssertEqual(model.jump(to: .block("b9"), layout: base, clipOriginY: 1000), .setClipOrigin(base.maxClipOriginY))
        XCTAssertTrue(model.isFollowing)

        XCTAssertEqual(model.jump(to: .block("missing"), layout: base, clipOriginY: base.maxClipOriginY), .none)

        model.userDidScroll(clipOriginY: 200, layout: base)
        XCTAssertEqual(model.jump(to: .bottom, layout: base, clipOriginY: 200), .setClipOrigin(base.maxClipOriginY))
        XCTAssertTrue(model.isFollowing)
    }

    // MARK: - Persistence

    /// Persisted reading positions must keep decoding after refactors: renaming a mode case, an
    /// associated-value label or a stored property would silently drop saved positions.
    func testPersistedJSONShapeIsStable() throws {
        let readingJSON = #"{"followThreshold":32,"mode":{"reading":{"anchorBlockID":"turn-3:conclusion","offsetFromViewportTop":-42.5}}}"#
        let followingJSON = #"{"followThreshold":24,"mode":{"following":{}}}"#

        let reading = try JSONDecoder().decode(TranscriptScrollAnchorModel.self, from: Data(readingJSON.utf8))
        XCTAssertEqual(reading.mode, .reading(anchorBlockID: "turn-3:conclusion", offsetFromViewportTop: -42.5))
        XCTAssertEqual(reading.followThreshold, 32)
        let following = try JSONDecoder().decode(TranscriptScrollAnchorModel.self, from: Data(followingJSON.utf8))
        XCTAssertTrue(following.isFollowing)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try String(decoding: encoder.encode(reading), as: UTF8.self), readingJSON)
        XCTAssertEqual(try String(decoding: encoder.encode(following), as: UTF8.self), followingJSON)
    }
}

#if DEBUG
    /// Stress-harness reading telemetry: position shifts while reading and frame-interval percentiles.
    final class AgentChatStressReadingTelemetryTests: XCTestCase {
        private let steadyReading = AgentChatStressReadingPositionTracker.Context(
            isDetachedReading: true,
            hasUserScrollInput: false,
            isProgrammaticScrollInFlight: false
        )

        func testShiftIsCountedOnlyForSteadyReadingMovementBeyondOnePoint() {
            var tracker = AgentChatStressReadingPositionTracker()
            tracker.refreshAnchor(
                frames: [
                    "above": CGRect(x: 0, y: -300, width: 10, height: 200), // fully above the viewport
                    "top": CGRect(x: 0, y: -40, width: 10, height: 200),
                    "next": CGRect(x: 0, y: 172, width: 10, height: 200)
                ],
                context: steadyReading
            )
            XCTAssertEqual(tracker.anchorBlockID, "top")

            XCTAssertNil(tracker.recordFrame(blockID: "next", minY: 400, context: steadyReading), "non-anchor rows are ignored")
            XCTAssertNil(tracker.recordFrame(blockID: "top", minY: -39.5, context: steadyReading), "sub-point jitter is ignored")
            XCTAssertEqual(tracker.recordFrame(blockID: "top", minY: 80, context: steadyReading), 119.5)

            var userScrolling = steadyReading
            userScrolling.hasUserScrollInput = true
            XCTAssertNil(tracker.recordFrame(blockID: "top", minY: 300, context: userScrolling), "user scrolling rebaselines")
            var following = steadyReading
            following.isDetachedReading = false
            XCTAssertNil(tracker.recordFrame(blockID: "top", minY: 10, context: following))

            XCTAssertEqual(tracker.positionShiftWhileReadingCount, 1)
            XCTAssertEqual(tracker.maxPositionShiftWhileReading, 119.5)
        }

        func testAnchorIsKeptWhileSteadyReadingAndReselectedOtherwise() {
            var tracker = AgentChatStressReadingPositionTracker()
            let frames: [String: CGRect] = [
                "a": CGRect(x: 0, y: -10, width: 10, height: 100),
                "b": CGRect(x: 0, y: 90, width: 10, height: 100)
            ]
            tracker.refreshAnchor(frames: frames, context: steadyReading)
            XCTAssertEqual(tracker.anchorBlockID, "a")

            // Content shifted so "b" is now topmost; steady reading keeps measuring "a".
            let shifted: [String: CGRect] = [
                "a": CGRect(x: 0, y: 200, width: 10, height: 100),
                "b": CGRect(x: 0, y: -50, width: 10, height: 100)
            ]
            tracker.refreshAnchor(frames: shifted, context: steadyReading)
            XCTAssertEqual(tracker.anchorBlockID, "a")

            var userScrolling = steadyReading
            userScrolling.hasUserScrollInput = true
            tracker.refreshAnchor(frames: shifted, context: userScrolling)
            XCTAssertEqual(tracker.anchorBlockID, "b")
            XCTAssertEqual(tracker.anchorMinY, -50)
        }

        @MainActor
        func testProbeWindowTransitionBreaksFrameSequenceWithoutDiscardingSamples() throws {
            let sampler = AgentChatStressFrameIntervalSampler()
            let probe = AgentChatStressFrameProbeNSView(sampler: sampler)
            sampler.setCollecting(true)
            sampler.recordDisplayFrame(timestamp: 1)
            sampler.recordDisplayFrame(timestamp: 1.016)
            let referenceDate = Date(timeIntervalSince1970: 100)
            XCTAssertEqual(sampler.currentSummary(now: referenceDate)?.sampleCount, 1)

            // Exercise the window lifecycle hook without opening a window. Collection stays on,
            // but the first frame after the probe's hiatus establishes a fresh baseline.
            probe.viewDidMoveToWindow()
            sampler.recordDisplayFrame(timestamp: 31)
            sampler.recordDisplayFrame(timestamp: 31.016)
            let summary = try XCTUnwrap(sampler.currentSummary(now: referenceDate.addingTimeInterval(1)))
            XCTAssertTrue(sampler.isCollecting)
            XCTAssertEqual(summary.sampleCount, 2)
            XCTAssertEqual(summary.p99MS, 16, accuracy: 0.001)
        }

        func testFrameIntervalPercentilesUseNearestRankOverTheRingBuffer() throws {
            var recorder = AgentChatStressFrameIntervalRecorder(capacity: 100)
            var timestamp: CFTimeInterval = 10
            recorder.recordFrame(at: timestamp) // baseline only
            for index in 1 ... 100 {
                timestamp += Double(index) / 1000 // intervals 1ms...100ms
                recorder.recordFrame(at: timestamp)
            }
            let summary = try XCTUnwrap(recorder.summary())
            XCTAssertEqual(summary.sampleCount, 100)
            XCTAssertEqual(summary.p50MS, 50, accuracy: 0.001)
            XCTAssertEqual(summary.p95MS, 95, accuracy: 0.001)
            XCTAssertEqual(summary.p99MS, 99, accuracy: 0.001)

            // A pause in collection must not be recorded as one huge frame.
            recorder.breakSequence()
            recorder.recordFrame(at: timestamp + 30)
            XCTAssertEqual(recorder.sampleCount, 100)

            // Ring buffer: 100 further 16ms frames evict every earlier interval.
            timestamp += 30
            for _ in 0 ..< 100 {
                timestamp += 0.016
                recorder.recordFrame(at: timestamp)
            }
            let steady = try XCTUnwrap(recorder.summary())
            XCTAssertEqual(steady.sampleCount, 100)
            XCTAssertEqual(steady.p99MS, 16, accuracy: 0.01)
        }
    }
#endif

@MainActor
final class AgentTranscriptBottomRevealTests: XCTestCase {
    func testProgrammaticScrollDoesNotSettleUntilDeferredCompletion() async {
        let gate = ProgrammaticScrollGate()
        let ready = expectation(description: "Request admitted")
        let settled = expectation(description: "Final action settled")
        var complete: (() -> Void)?
        gate.schedule(after: 0, settleAfter: 0, onSettled: { settled.fulfill() }, deferredAction: {
            complete = $0
            ready.fulfill()
        })
        await fulfillment(of: [ready], timeout: 1)
        XCTAssertTrue(gate.isInFlight)
        complete?()
        complete?()
        await fulfillment(of: [settled], timeout: 1)
        XCTAssertFalse(gate.isInFlight)
    }

    func testCancelledCompletionCannotSettleReplacement() async {
        let gate = ProgrammaticScrollGate()
        let admitted = expectation(description: "First request admitted")
        var stale: (() -> Void)?
        var staleSettlements = 0
        gate.schedule(after: 0, settleAfter: 0, onSettled: { staleSettlements += 1 }, deferredAction: {
            stale = $0
            admitted.fulfill()
        })
        await fulfillment(of: [admitted], timeout: 1)
        gate.cancel()
        XCTAssertFalse(gate.isInFlight)
        stale?()
        let replacement = expectation(description: "Replacement settled")
        gate.schedule(after: 0, settleAfter: 0, onSettled: { replacement.fulfill() }, deferredAction: { finish in
            stale?()
            finish()
        })
        await fulfillment(of: [replacement], timeout: 1)
        XCTAssertEqual(staleSettlements, 0)
        XCTAssertFalse(gate.isInFlight)
    }

    func testBlockerDismissedRevealRejectsRevisionAdvanceBeforeEitherMove() {
        let dismissed = AgentTranscriptScrollIntent.bottom(animated: false, reason: .blockerDismissed)
        let fence = TranscriptBottomRevealRevisionFence(revision: 10, allowsRevisionMismatch: dismissed.allowsRevisionMismatch)
        XCTAssertTrue(fence.permits(10))
        XCTAssertFalse(fence.permits(11))

        let streaming = AgentTranscriptScrollIntent.bottom(animated: false, reason: .transcriptChangeWhilePinned)
        let followingFence = TranscriptBottomRevealRevisionFence(revision: 10, allowsRevisionMismatch: streaming.allowsRevisionMismatch)
        XCTAssertTrue(followingFence.permits(11))
    }

    func testFrameMustIntersectCurrentViewport() {
        let requestID = UUID()
        let viewport = CGSize(width: 620, height: 470)
        for frame in [CGRect.zero, CGRect(x: 0, y: 471, width: 100, height: 20), CGRect(x: 621, y: 0, width: 30, height: 20)] {
            XCTAssertFalse(TranscriptBottomRevealFrame(requestID: requestID, presentationRevision: 0, frame: frame).isVisible(in: viewport))
        }
        XCTAssertTrue(TranscriptBottomRevealFrame(requestID: requestID, presentationRevision: 0, frame: CGRect(x: 0, y: 465, width: 90, height: 20)).isVisible(in: viewport))
    }

    func testHostedBottomRevealAndDetachedUpdatesAtBothSizes() async throws {
        for count in [1200, 3000] {
            try await checkHostedReveal(initialCount: count)
        }
    }

    func testHeldFrameFallsBackAtDeadlineAndOnlySettlesOnce() async throws {
        _ = NSApplication.shared
        let feed = Feed(restoredEntries: [])
        let pane = MountedPane(feed: feed)
        defer { pane.close() }
        feed.count = 1200
        try await waitForLayout([pane]) { feed.visibleFrameCount > 0 }
        feed.holdWitness = true
        let started = ContinuousClock.now
        feed.command = .bottom(UUID())
        try await waitForLayout([pane]) { feed.heldWitness != nil }
        XCTAssertTrue(feed.gate.isInFlight)
        XCTAssertEqual(feed.completed, 0)
        try await waitForLayout([pane]) { feed.settled == 1 }
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), Reveal.deadline)
        try XCTUnwrap(feed.heldWitness)()
        XCTAssertEqual(feed.completed, 1)
        XCTAssertFalse(feed.gate.isInFlight)
        XCTAssertNil(feed.requestID)
        let scroll = try XCTUnwrap(Self.scrollView(in: pane.host))
        let doc = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(doc.frame.height - scroll.documentVisibleRect.maxY, 16, accuracy: 2)
    }

    func testRevealPolicyRejectsStaleScopeAndRetargetsWithoutRestartingDeadline() {
        var reveal = Reveal(scope: 1, entryID: 10, revisionFence: .init(revision: 4, allowsRevisionMismatch: true))
        let oldWitness = reveal.witnessID
        let id = reveal.id
        XCTAssertTrue(reveal.retarget(scope: 1, entryID: 11))
        XCTAssertEqual(reveal.id, id)
        XCTAssertEqual(reveal.action(for: .reveal(oldWitness), scope: 1, entryID: 11, revision: 5, canScroll: true), .ignore)
        XCTAssertEqual(reveal.action(for: .deadline(id), scope: 2, entryID: 11, revision: 5, canScroll: true), .cancel)
        XCTAssertEqual(reveal.action(for: .deadline(id), scope: 1, entryID: 11, revision: 5, canScroll: false), .cancel)
        XCTAssertEqual(reveal.action(for: .deadline(id), scope: 1, entryID: 11, revision: 5, canScroll: true), .finish)
        let tail = TranscriptBottomRevealFrame(requestID: reveal.witnessID, presentationRevision: 5, frame: CGRect(x: 0, y: -10, width: 20, height: 20))
        XCTAssertEqual(reveal.action(for: .tail(tail), scope: 1, entryID: 11, revision: 5, canScroll: true), .finish)
    }

    func testScrollAwayCancelsHostedRevealBeforeLateWitness() async throws {
        try await checkInterruptedReveal(remount: false)
    }

    func testRemountCancelsHostedRevealBeforeLateWitness() async throws {
        try await checkInterruptedReveal(remount: true)
    }

    private func checkInterruptedReveal(remount: Bool) async throws {
        _ = NSApplication.shared
        let feed = Feed(restoredEntries: [])
        let pane = MountedPane(feed: feed)
        defer { pane.close() }
        feed.count = 1200
        try await waitForLayout([pane]) { feed.visibleFrameCount > 0 }
        feed.holdWitness = true
        feed.command = .bottom(UUID())
        try await waitForLayout([pane]) { feed.heldWitness != nil }
        XCTAssertTrue(feed.gate.isInFlight)
        let late = try XCTUnwrap(feed.heldWitness)
        feed.heldWitness = nil

        let before = try XCTUnwrap(Self.scrollView(in: pane.host))
        if remount {
            feed.mount += 1
        } else {
            let clip = before.contentView
            clip.scroll(to: CGPoint(x: clip.bounds.minX, y: clip.bounds.minY - 700))
            before.reflectScrolledClipView(clip)
            // An unordered AppKit host does not deliver a SwiftUI user scroll phase.
            // Send the interruption at the same admission/cancellation seam.
            feed.command = .idle
        }
        try await waitForLayout([pane]) {
            !feed.gate.isInFlight && (!remount || Self.scrollView(in: pane.host) !== before)
        }
        let active = try XCTUnwrap(Self.scrollView(in: pane.host))
        // The lazy stack can correct its estimated document extent after a native scroll.
        // Sample the settled clip, not the provisional offset from the cancellation pass.
        var stablePasses = 0
        var origin = active.documentVisibleRect.minY
        try await waitForLayout([pane]) {
            let next = active.documentVisibleRect.minY
            stablePasses = abs(next - origin) < 1 ? stablePasses + 1 : 0
            origin = next
            return stablePasses == 3
        }
        let document = try XCTUnwrap(active.documentView)
        // The sentinel lands at the 16-point padding. Leave a clear gap to detect a jump,
        // without assuming the estimated document's extent survives the native scroll.
        XCTAssertGreaterThan(document.frame.height - active.documentVisibleRect.maxY, 32)
        late()
        for _ in 0 ..< 3 {
            pane.host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(12))
        }
        XCTAssertEqual(active.documentVisibleRect.minY, origin, accuracy: 1)
        XCTAssertNil(feed.requestID)
        XCTAssertFalse(feed.gate.isInFlight)
        XCTAssertEqual(feed.completed, 0)
        XCTAssertEqual(feed.settled, 0)
    }

    func testRestoredCompactedTranscriptWithResidentChatContexts() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let items: [AgentChatItem] = (2940 ..< 3000).flatMap { turn in
            [
                .user("Request \(turn)", sequenceIndex: 2 * turn),
                .assistant("Conclusion \(turn)", sequenceIndex: 2 * turn + 1)
            ]
        }
        let archived = (0 ..< 2940).map { turn in
            let time = Date(timeIntervalSince1970: Double(turn))
            return AgentTranscriptTurn(
                retentionTier: .archived,
                summary: .init(
                    requestText: "Request \(turn)", conclusionText: "Conclusion \(turn)",
                    compactConclusionText: nil, middleSummaryText: nil, toolCount: 0,
                    notableToolNames: [], keyPaths: [], compactedActivityCount: 1, hadWarning: false, hadError: false
                ),
                terminalState: .completed, startedAt: time, lastActivityAt: time, completedAt: time
            )
        }
        // Restore a saved compacted prefix, rather than benchmarking initial compaction of 3,000 full turns.
        var compacted = AgentTranscriptIO.buildTranscript(from: items, terminalState: .completed)
        compacted.turns.insert(contentsOf: archived, at: 0)
        compacted.compactionFrontier = try .init(frozenPrefixTurnCount: archived.count, lastFrozenTurnID: XCTUnwrap(archived.last?.id))
        let restored = try JSONDecoder().decode(AgentTranscript.self, from: JSONEncoder().encode(compacted))
        XCTAssertEqual(restored.turns.count, 3000)
        XCTAssertTrue(restored.turns.contains { $0.retentionTier != .full })

        _ = NSApplication.shared
        // Retain 300 sessions while the selected transcript in each hidden window is laid out.
        let contexts = (0 ..< 35).map { context in
            stride(from: context, to: 300, by: 35).map { _ in AgentModeViewModel.TabSession(tabID: UUID()) }
        }
        XCTAssertEqual(contexts.flatMap(\.self).count, 300)
        let built = AgentSessionTranscriptBuilder.buildTranscriptPresentation(
            from: restored, sourceItems: AgentTranscriptIO.workingSourceItems(from: restored),
            selectedAgent: .codexExec, previousPerformanceSnapshot: .empty,
            isCompressedHistoryRevealed: true, isColdLoad: true
        )
        let entries = AgentTranscriptRenderEntries(blocks: built.projection.archivedBlocks + built.projection.workingBlocks).entries
        XCTAssertFalse(entries.isEmpty)
        let panes = contexts.indices.map { index in
            MountedPane(feed: Feed(restoredEntries: index == 0 ? entries : []))
        }
        defer { panes.forEach { $0.close() } }
        for (index, pane) in panes.enumerated() {
            pane.feed.count = index == 0 ? entries.count : 10 + index
        }
        try await waitForLayout(panes) { panes.allSatisfy { $0.feed.visibleFrameCount > 0 } }
        for pane in panes {
            pane.feed.command = .bottom(UUID())
        }
        try await waitForLayout(panes) { panes.allSatisfy { $0.feed.settled == 1 } }
        for pane in panes {
            XCTAssertGreaterThan(pane.feed.visibleFrameCount, 0)
            XCTAssertFalse(pane.feed.gate.isInFlight)
            XCTAssertFalse(pane.window.isVisible)
        }
        let streamingStarted = clock.now
        for wave in 1 ... 8 {
            for pane in panes {
                pane.feed.revision += 1
                if wave.isMultiple(of: 2) { pane.feed.count += 1 }
                pane.feed.command = .bottom(UUID())
            }
            try await waitForLayout(panes) { panes.allSatisfy { $0.feed.settled == wave + 1 } }
        }
        print("Transcript streaming host measurement: 280 requests in \(streamingStarted.duration(to: clock.now))")
        withExtendedLifetime(contexts) {}
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(60))
    }

    private typealias Reveal = TranscriptBottomReveal<Int, Int>
    private nonisolated static let viewport = CGSize(width: 620, height: 470)

    private func checkHostedReveal(
        initialCount: Int, restoredEntries: [AgentTranscriptRenderEntries.Entry] = [], checkDetached: Bool = true
    ) async throws {
        _ = NSApplication.shared
        let feed = Feed(restoredEntries: restoredEntries)
        let host = NSHostingView(rootView: Pane(feed: feed))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.viewport), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        func layout() async throws {
            for _ in 0 ..< 6 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(12))
            }
        }

        try await layout()
        feed.count = initialCount
        try await layout()
        let scroll = try XCTUnwrap(Self.scrollView(in: host))
        for step in 0 ..< 3 {
            if step > 0 {
                feed.command = .top
                try await layout()
                feed.count += 1
            }
            feed.revision = step + 1
            feed.command = .bottom(UUID())
            for _ in 0 ..< 4 {
                try await layout()
                if feed.completed == step + 1 { break }
            }
            XCTAssertEqual(feed.completed, step + 1, "Final row did not get a frame: \(initialCount), step \(step)")
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertEqual(document.frame.height - scroll.documentVisibleRect.maxY, 16, accuracy: 2)
            XCTAssertGreaterThan(feed.visibleFrameCount, 0)
        }

        XCTAssertFalse(window.isVisible)
        guard checkDetached else { return }
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: clip.bounds.minY - 700))
        scroll.reflectScrolledClipView(clip)
        try await layout()
        let viewport = CGRect(origin: .zero, size: Self.viewport)
        let anchor = try XCTUnwrap(feed.frames.filter { $0.value.intersects(viewport) }.min { $0.value.minY < $1.value.minY })
        for i in 0 ..< 8 {
            feed.revision += 1
            if i.isMultiple(of: 2) { feed.count += 1 }
            try await layout()
            let current = try XCTUnwrap(feed.frames[anchor.key])
            XCTAssertEqual(current.minY, anchor.value.minY, accuracy: 1)
        }
        XCTAssertEqual(feed.completed, 3)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    private final class MountedPane {
        let feed: Feed
        let host: NSHostingView<Pane>
        let window: NSWindow

        init(feed: Feed) {
            self.feed = feed
            host = NSHostingView(rootView: Pane(feed: feed))
            window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }

        func close() {
            feed.cancelReveal()
            feed.heldWitness = nil
            window.contentView = nil
            window.close()
        }
    }

    private func waitForLayout(_ panes: [MountedPane], until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            panes.forEach { $0.host.layoutSubtreeIfNeeded() }
            if ready() { return }
            try await Task.sleep(for: .milliseconds(12))
        } while ContinuousClock.now < deadline
        XCTFail("Hosted transcript did not reach the expected layout or request state")
        throw CocoaError(.userCancelled)
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private enum Command: Equatable {
        case idle
        case top
        case bottom(UUID)
    }

    @MainActor
    private final class Feed: ObservableObject {
        let restoredEntries: [AgentTranscriptRenderEntries.Entry]

        init(restoredEntries: [AgentTranscriptRenderEntries.Entry]) {
            self.restoredEntries = restoredEntries
        }

        func mountedID(at index: Int) -> AnyHashable {
            guard restoredEntries.indices.contains(index) else { return AnyHashable(index) }
            let entry = restoredEntries[index]
            return entry.isFirstInBlock ? AnyHashable(entry.block.id) : AnyHashable(entry.id)
        }

        func label(at index: Int) -> String {
            guard restoredEntries.indices.contains(index) else { return String(index) }
            let entry = restoredEntries[index]
            return entry.item?.text ?? entry.block.id
        }

        @Published var count = 0
        @Published var revision = 0
        @Published var command = Command.idle
        @Published var mount = 0
        @Published var pending: Reveal?
        var requestID: UUID? {
            pending?.witnessID
        }

        let gate = ProgrammaticScrollGate()
        var finish: (() -> Void)?
        var holdWitness = false
        var heldWitness: (() -> Void)?
        var completed = 0
        var settled = 0

        func cancelReveal() {
            gate.cancel()
            pending = nil
            finish = nil
        }

        var frames: [Int: CGRect] = [:]
        var visibleFrameCount: Int {
            frames.values.count(where: { $0.intersects(CGRect(origin: .zero, size: AgentTranscriptBottomRevealTests.viewport)) })
        }
    }

    private enum FramesKey: PreferenceKey {
        static var defaultValue: [Int: CGRect] {
            [:]
        }

        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, last in last })
        }
    }

    private struct Pane: View {
        @ObservedObject var feed: Feed

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Color.clear.frame(height: 1).id("top")
                            ForEach(0 ..< feed.count, id: \.self) { index in
                                Text(feed.label(at: index))
                                    .frame(height: CGFloat(32 + ((index * 37 + (index >= feed.count - 3 ? feed.revision * 31 : 0)) % 170)))
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: FramesKey.self, value: [index: geometry.frame(in: .named(TranscriptBottomRevealFrameKey.coordinateSpace))])
                                        }
                                    }
                                    .modifier(TranscriptBottomRevealWitness(
                                        requestID: index == feed.count - 1 ? feed.requestID : nil,
                                        presentationRevision: index == feed.count - 1 ? feed.revision : 0
                                    ))
                                    .id(feed.mountedID(at: index))
                            }
                        }
                        VStack(spacing: 12) {
                            Text("Running")
                            Color.clear.frame(height: 1).id(SwiftUITranscriptScrollDriver.bottomTargetID)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: AgentTranscriptBottomRevealTests.viewport.height, alignment: .topLeading)
                }
                .id(feed.mount)
                .coordinateSpace(name: TranscriptBottomRevealFrameKey.coordinateSpace)
                .onChange(of: feed.mount) { _, _ in feed.cancelReveal() }
                .onPreferenceChange(FramesKey.self) { feed.frames = $0 }
                .onPreferenceChange(TranscriptBottomRevealFrameKey.self) { frame in
                    guard let frame, frame.requestID == feed.requestID, frame.isVisible(in: AgentTranscriptBottomRevealTests.viewport) else { return }
                    let complete = { apply(.row(frame, viewport: AgentTranscriptBottomRevealTests.viewport), proxy: proxy) }
                    if feed.holdWitness {
                        feed.heldWitness = feed.heldWitness ?? complete
                    } else {
                        complete()
                    }
                }
                .task(id: feed.pending?.witnessID) { [id = feed.pending?.witnessID] in
                    guard let id else { return }
                    do { try await Task.sleep(for: Reveal.revealDelay) } catch { return }
                    apply(.reveal(id), proxy: proxy)
                }
                .task(id: feed.pending?.id) { [id = feed.pending?.id] in
                    guard let id else { return }
                    do { try await Task.sleep(for: Reveal.deadline) } catch { return }
                    apply(.deadline(id), proxy: proxy)
                }
                .onChange(of: feed.command) { _, command in
                    switch command {
                    case .idle: feed.cancelReveal()
                    case .top:
                        feed.cancelReveal()
                        proxy.scrollTo("top", anchor: .top)
                    case let .bottom(id):
                        feed.cancelReveal()
                        feed.gate.schedule(after: 0, settleAfter: 0, onSettled: { feed.settled += 1 }, deferredAction: { finish in
                            feed.finish = finish
                            feed.pending = Reveal(
                                id: id, scope: feed.mount, entryID: feed.count - 1,
                                revisionFence: .init(revision: feed.revision, allowsRevisionMismatch: true)
                            )
                        })
                    }
                }
            }
            .frame(width: AgentTranscriptBottomRevealTests.viewport.width, height: AgentTranscriptBottomRevealTests.viewport.height)
        }

        private func apply(_ event: Reveal.Event, proxy: ScrollViewProxy) {
            guard let pending = feed.pending else { return }
            let driver = SwiftUITranscriptScrollDriver(proxy: proxy)
            switch pending.action(for: event, scope: feed.mount, entryID: feed.count - 1, revision: feed.revision, canScroll: feed.gate.isInFlight) {
            case .ignore: break
            case .cancel: feed.cancelReveal()
            case .reveal: driver.revealBottomEntry(id: feed.mountedID(at: pending.entryID))
            case .finish:
                feed.pending = nil
                driver.scrollToBottom(animated: false)
                feed.completed += 1
                let finish = feed.finish
                feed.finish = nil
                finish?()
            }
        }
    }
}
