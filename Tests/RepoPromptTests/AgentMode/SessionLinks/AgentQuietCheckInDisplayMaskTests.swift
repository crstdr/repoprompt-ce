import Combine
import CryptoKit
import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentQuietCheckInDisplayMaskTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1)

    private func projection(
        _ rows: [AgentChatItem],
        tier: AgentTranscriptRetentionTier = .condensed,
        turnID: UUID = UUID(),
        spanID: UUID = UUID(),
        conclusionID: UUID? = nil,
        summary: AgentTranscriptTurnSummary? = nil
    ) -> AgentTranscriptProjection {
        let span = AgentTranscriptProviderResponseSpan(
            id: spanID,
            lifecycle: .completed,
            startedAt: date,
            completedAt: date,
            activities: rows.map { AgentTranscriptActivity(from: $0, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: $0)) }
        )
        let turn = AgentTranscriptTurn(
            id: turnID,
            responseSpans: [span],
            conclusionActivityID: conclusionID,
            retentionTier: tier,
            summary: summary,
            terminalState: .completed,
            startedAt: date,
            completedAt: date
        )
        return AgentTranscriptProjectionBuilder.build(from: AgentTranscript(turns: [turn]))
    }

    private func presentation(_ projection: AgentTranscriptProjection) -> AgentTranscriptPresentationSnapshot {
        .init(
            revision: 7,
            visibleBlocks: projection.workingBlocks,
            workingBlocks: projection.workingBlocks,
            visibleRows: projection.workingRows,
            workingRows: projection.workingRows,
            rowAnchorIndex: projection.rowAnchorIndex,
            anchorBlockIndex: projection.anchorBlockIndex
        )
    }

    func testCondensedSameMaskNowPreservesDistinctSourceKindsAndNarrationWithoutRawRows() throws {
        let turnID = UUID(), spanID = UUID(), firstID = UUID(), quietID = UUID()
        let assignments: [(AgentChatItemKind, AgentChatItemKind)] = [(.assistant, .thinking), (.thinking, .assistant)]
        var originalNormalBlock: AgentTranscriptRenderBlock?
        for (firstKind, quietKind) in assignments {
            let rows = [
                AgentChatItem(id: firstID, timestamp: date, kind: firstKind, text: "[ack]", sequenceIndex: 0),
                AgentChatItem(id: quietID, timestamp: date, kind: quietKind, text: "[ack]", sequenceIndex: 1)
            ]
            let base = projection(rows, turnID: turnID, spanID: spanID)
            let before = try XCTUnwrap(base.workingBlocks.first)
            XCTAssertTrue(before.rows.isEmpty)
            XCTAssertTrue(before.groupedHistory?.sections.isEmpty == true)
            var normal = before
            normal.displaySummaryInputs = []
            if let originalNormalBlock { XCTAssertEqual(normal, originalNormalBlock, "Original same-input A/B counterexample") }
            originalNormalBlock = normal
            let masked = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: base.workingBlocks, hiddenSourceIDs: [quietID])
            let block = try XCTUnwrap(masked.presentation.visibleBlocks.first)
            let summary = try XCTUnwrap(block.groupedHistory?.summary)
            XCTAssertEqual(summary.hiddenAssistantCount, firstKind == .assistant ? 1 : 0)
            XCTAssertEqual(summary.hiddenProgressCount, firstKind == .thinking ? 1 : 0)
            XCTAssertEqual(summary.toolSummary?.shortNarration, "[ack]")
            XCTAssertEqual(block.activityIDs, [firstID])
            XCTAssertEqual(block.anchorActivityID, firstID)
            XCTAssertNil(masked.presentation.rowAnchorIndex[quietID])
            XCTAssertEqual(masked.archivedBlocks, masked.presentation.visibleBlocks)
            XCTAssertEqual(base.workingBlocks.first?.activityIDs, [firstID, quietID], "Canonical/base projection was not changed")
            XCTAssertEqual(masked.presentation.revision, 7)
        }
    }

    func testCondensedRebuildPreservesLastBlankThinkingNarrationPolicy() throws {
        let older = AgentChatItem.thinking("older ordinary thought", sequenceIndex: 0)
        let blank = AgentChatItem.thinking(" \n", sequenceIndex: 1)
        let quiet = AgentChatItem.assistant("[ack]", sequenceIndex: 2)
        let base = projection([older, blank, quiet])
        let surviving = projection([older, blank])
        XCTAssertNil(surviving.workingBlocks.first?.groupedHistory?.summary.toolSummary?.shortNarration)
        let result = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: [], hiddenSourceIDs: [quiet.id])
        let summary = try XCTUnwrap(result.presentation.visibleBlocks.first?.groupedHistory?.summary)
        XCTAssertNil(summary.toolSummary?.shortNarration, "Rebuild uses the existing LAST thinking row, not an older nonblank thought")
        XCTAssertEqual(summary.hiddenProgressCount, 2)
    }

    func testHiddenAnchorCannotDropOrdinarySiblingAndEmptyGroupShellsDisappear() {
        let first = AgentChatItem(kind: .thinking, text: "quiet", sequenceIndex: 0)
        let ordinary = AgentChatItem(kind: .assistant, text: "ordinary", sequenceIndex: 1)
        let base = projection([first, ordinary])
        let masked = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: [], hiddenSourceIDs: [first.id])
        XCTAssertEqual(masked.presentation.visibleBlocks.count, 1)
        XCTAssertEqual(masked.presentation.visibleBlocks.first?.anchorActivityID, ordinary.id)
        XCTAssertEqual(masked.presentation.visibleBlocks.first?.groupedHistory?.summary.toolSummary?.shortNarration, "ordinary")
        let empty = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: base.workingBlocks, hiddenSourceIDs: [first.id, ordinary.id])
        XCTAssertTrue(empty.presentation.visibleBlocks.isEmpty)
        XCTAssertTrue(empty.presentation.workingBlocks.isEmpty)
        XCTAssertTrue(empty.archivedBlocks.isEmpty)
        XCTAssertTrue(empty.presentation.rowAnchorIndex.isEmpty)
        XCTAssertTrue(empty.presentation.anchorBlockIndex.isEmpty)
        XCTAssertFalse(empty.presentation.archivedHistoryState.hasArchivedHistory)
    }

    func testSyntheticConclusionUsesOriginalSourceAnchorInBlocksFlatRowsAndBothIndexes() throws {
        let sourceID = UUID(), turnID = UUID()
        let summary = AgentTranscriptTurnSummary(
            requestText: nil,
            conclusionText: "[ack]",
            compactConclusionText: "[ack]",
            middleSummaryText: nil,
            toolCount: 0,
            notableToolNames: [],
            keyPaths: [],
            compactedActivityCount: 0,
            hadWarning: false,
            hadError: false
        )
        let base = projection([], tier: .archived, turnID: turnID, conclusionID: sourceID, summary: summary)
        let row = try XCTUnwrap(base.archivedRows.first)
        XCTAssertNotEqual(row.id, sourceID)
        let snapshot = AgentTranscriptPresentationSnapshot(
            revision: 9,
            visibleBlocks: base.archivedBlocks,
            workingBlocks: base.archivedBlocks,
            visibleRows: base.archivedRows,
            workingRows: base.archivedRows,
            rowAnchorIndex: base.rowAnchorIndex,
            anchorBlockIndex: base.anchorBlockIndex
        )
        let masked = AgentTranscriptProjectionBuilder.maskForLocalDisplay(snapshot, archivedBlocks: base.archivedBlocks, hiddenSourceIDs: [sourceID])
        XCTAssertTrue(masked.presentation.visibleBlocks.isEmpty)
        XCTAssertTrue(masked.presentation.visibleRows.isEmpty)
        XCTAssertTrue(masked.presentation.workingRows.isEmpty)
        XCTAssertTrue(masked.presentation.rowAnchorIndex.isEmpty)
        XCTAssertTrue(masked.presentation.anchorBlockIndex.isEmpty)
        XCTAssertTrue(masked.archivedBlocks.isEmpty)
        XCTAssertEqual(base.archivedRows.first?.text, "[ack]", "Raw archived source remains visible to canonical readers")
    }

    func testNarrationOwnsBoundedSanitizedUnicodeCopyAndDoesNotPinSourceBody() throws {
        let text = String(repeating: "👩🏽‍💻", count: 20000)
        let row = AgentChatItem(kind: .thinking, text: text, sequenceIndex: 0)
        let base = projection([row])
        let narration = try XCTUnwrap(base.workingBlocks.first?.displaySummaryInputs.first?.rows.first?.narration)
        XCTAssertEqual(narration.count, 121)
        XCTAssertGreaterThan(narration.utf8.count, 121, "The character policy is not a byte cap")
        XCTAssertEqual(narration, String(text.prefix(120)) + "…")
        var source = text
        var retained = narration
        source.withUTF8 { sourceBytes in
            retained.withUTF8 { retainedBytes in XCTAssertNotEqual(sourceBytes.baseAddress, retainedBytes.baseAddress) }
        }
        print("QUIET_C5_NARRATION bytes=\(narration.utf8.count) characters=\(narration.count) sourceBytes=\(text.utf8.count)")
        // Exact old sanitizer→120-character formatter, including NUL-induced grapheme joins.
        let boundaries = [
            "", "  ", String(repeating: "\0", count: 500),
            String(repeating: "a", count: 120), String(repeating: "a", count: 121),
            String(repeating: "a", count: 122) + "\0\u{0301}",
            String(repeating: "e\0\u{0301}", count: 180),
            String(repeating: "\0", count: 200) + String(repeating: "x", count: 200),
            " \n" + String(repeating: "👩🏽‍💻\0🇬🇧", count: 150) + " \n",
            String(repeating: "a", count: 119) + "e\0\u{0301}" + String(repeating: "z", count: 200)
        ]
        for body in boundaries {
            let sanitized = body.trimmingCharacters(in: .whitespacesAndNewlines).sanitizedForDisplay
            let expected: String? = sanitized.isEmpty ? nil : sanitized.count > 120 ? String(sanitized.prefix(120)) + "…" : sanitized
            let built = projection([AgentChatItem.thinking(body)])
            let actual = built.workingBlocks.flatMap(\.displaySummaryInputs).flatMap(\.rows).first?.narration
            XCTAssertEqual(actual, expected, "Prefix optimization must not invent a new truncation/sanitization policy")
        }
    }

    func testOldToolHeavyCondensedCacheRetainsOnlySummaryMetadataAfterRealCanonicalTrim() throws {
        var source: AgentTranscript? = AgentTranscript(turns: (0 ..< 8).map { _ in AgentQuietCheckInReplay.toolHeavyTurn(date: date) })
        let old = try AgentTranscriptProjectionBuilder.buildWithCaches(from: XCTUnwrap(source), protection: .none, turnCaches: [:])
        let compacted = try AgentTranscriptCompactor.compact(XCTUnwrap(source))
        source = nil
        XCTAssertTrue(compacted.allActivities.isEmpty)
        let inputs = old.updatedTurnCaches.values.flatMap(\.workingBlocks).flatMap(\.displaySummaryInputs)
        let rows = inputs.flatMap(\.rows)
        XCTAssertEqual(rows.count, 400)
        let narrationBytes = rows.reduce(0) { $0 + ($1.narration?.utf8.count ?? 0) }
        XCTAssertEqual(narrationBytes, 16 * (120 + "…".utf8.count))
        XCTAssertTrue(rows.allSatisfy { ($0.narration?.count ?? 0) <= 121 })
        let masked = AgentTranscriptProjectionBuilder.maskForLocalDisplay(
            presentation(old.projection),
            archivedBlocks: [],
            hiddenSourceIDs: Set(rows.filter { $0.kind == .thinking }.map(\.id))
        )
        XCTAssertTrue(masked.presentation.visibleBlocks.allSatisfy { $0.groupedHistory?.summary.hiddenToolCardCount == 24 })
        XCTAssertTrue(masked.presentation.visibleBlocks.allSatisfy { $0.groupedHistory?.summary.toolSummary?.shortNarration == String(String(repeating: "ordinary explanation ", count: 800).prefix(120)) + "…" })
        let replacement = AgentTranscriptProjectionBuilder.buildWithCaches(from: compacted, protection: .none, turnCaches: old.updatedTurnCaches)
        XCTAssertTrue(replacement.projection.workingBlocks.flatMap(\.displaySummaryInputs).isEmpty)
        let blockIDBytes = inputs.reduce(0) { $0 + $1.blockID.utf8.count }
        let identityArrayBytes = inputs.reduce(0) { $0 + $1.activityIDs.count * MemoryLayout<UUID>.stride }
        let valueElementBytes = inputs.count * MemoryLayout<AgentTranscriptDisplaySummaryInput>.stride + rows.count * MemoryLayout<AgentTranscriptDisplaySummaryInput.Row>.stride
        print("QUIET_C5_SUMMARY_RETENTION turns=8 tools=192 inputBlocks=\(inputs.count) inputRows=\(rows.count) narrationUTF8Bytes=\(narrationBytes) blockIDUTF8Bytes=\(blockIDBytes) activityIDElementBytes=\(identityArrayBytes) valueElementBytes=\(valueElementBytes) retainedRawPayloadBytes=0 postTrimCanonicalActivities=0 replacementInputRows=0")
    }

    func testMixedFullFrozenSummaryRebuildPreservesToolsAndOrdinaryNarration() throws {
        let turnID = UUID(), spanID = UUID()
        let ordinary = AgentChatItem.assistant("ordinary explanation", sequenceIndex: 0)
        let quiet = AgentChatItem.thinking("quiet private thought", sequenceIndex: 1)
        var rows = [ordinary, quiet]
        for index in 0 ..< 20 {
            rows.append(.init(kind: .toolResult, text: "source \(index)", toolName: "read_file", toolInvocationID: UUID(), toolResultJSON: "{}", sequenceIndex: rows.count))
        }
        let span = AgentTranscriptProviderResponseSpan(id: spanID, lifecycle: .completed, startedAt: date, completedAt: date, activities: rows.map { .init(from: $0, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: $0)) })
        let turn = AgentTranscriptTurn(id: turnID, responseSpans: [span], retentionTier: .full, terminalState: .completed, startedAt: date, completedAt: date)
        let frozen = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: .init(turns: [turn]))
        XCTAssertNotNil(frozen.turns.first?.responseSpans.first?.fullRenderGroupedHistoryCache)
        let base = AgentTranscriptProjectionBuilder.build(from: frozen)
        let normal = try XCTUnwrap(base.workingBlocks.first(where: { $0.kind == .groupedHistory }))
        XCTAssertFalse(try XCTUnwrap(normal.groupedHistory).sections.isEmpty)
        XCTAssertTrue(normal.displaySummaryInputs.isEmpty, "Full materialization reuses existing sections, not duplicate raw children")
        let result = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: base.workingBlocks, hiddenSourceIDs: [quiet.id])
        let group = try XCTUnwrap(result.presentation.visibleBlocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory)
        XCTAssertEqual(group.summary.hiddenProgressCount, 0)
        XCTAssertEqual(group.summary.hiddenAssistantCount, 1)
        XCTAssertEqual(group.summary.hiddenToolCardCount, normal.groupedHistory?.summary.hiddenToolCardCount)
        XCTAssertEqual(group.summary.toolSummary?.shortNarration, "ordinary explanation")
        XCTAssertFalse(group.sections.flatMap(\.childBlocks).flatMap(\.rows).contains(where: { $0.id == quiet.id }))
        XCTAssertEqual(base.workingBlocks.first(where: { $0.kind == .groupedHistory }), normal)
        XCTAssertEqual(result.archivedBlocks, result.presentation.visibleBlocks)
    }

    private func liveFixture() throws -> (AgentSessionLinkRunnerHarness, WorkspaceManagerViewModel, AgentTabSession) {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, replayTranscript: true)
        let tabID = UUID()
        let manager = AgentSessionLinkEndpointTestSupport.installWorkspace(on: harness.host, tabID: tabID, name: "Quiet display fixture")
        let session = harness.host.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        _ = try XCTUnwrap(harness.host.test_installPersistentSessionBinding(sessionID: UUID(), on: session, updateWorkspaceMetadata: true))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        session.installRunID(UUID())
        return (harness, manager, session)
    }

    func testSameRevisionHydrationRefreshesMaskedAndEmptyDisplayAndRestoreSignalWithoutGetterWork() async throws {
        for hasMask in [false, true] {
            let (h, manager, session) = try liveFixture()
            defer { withExtendedLifetime(manager) {} }
            let ordinary = AgentChatItem.assistant("ordinary context")
            session.appendItem(ordinary)
            var quietRowID: UUID?
            if hasMask {
                session.runState = .running
                let owner = session.beginRunAttempt(source: "quiet-display-hydration")
                session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
                let ack = AgentChatItem.assistant("[ack]")
                quietRowID = ack.id
                session.appendItem(ack)
                let revision = await AgentRunTerminalCommitBarrier().commit(.init(
                    binding: h.hooks.bindTerminalSession(session), ownership: owner, expectedRunID: session.runID,
                    terminalState: .completed, source: "quiet-display-hydration", attachmentDisposition: .deleteFiles,
                    finalizeNonCodexUsage: false, supportsFollowUp: false, notifyTurnComplete: false, classifiesQuietCheckIn: true
                ))
                XCTAssertNotNil(revision)
                XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(ack.id))
            }
            session.clearCurrentBindingHydration()
            h.host.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
            _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
            h.host.syncTranscriptUIState()
            let before = h.host.ui.transcript.snapshot
            let warm = try XCTUnwrap(session.quietTranscriptDisplayCache)
            XCTAssertFalse(before.isHydrated)
            XCTAssertFalse(warm.result.presentation.bindingsHydrated)
            XCTAssertNil(warm.result.presentation.hydratedPersistentBinding)
            XCTAssertNil(warm.result.presentation.hydratedBindingTransitionGeneration)
            let hidden = session.quietLedger.hiddenSourceIDs
            XCTAssertEqual(hidden.isEmpty, !hasMask)
            let baseRevision = h.host.activeTranscriptPresentation.revision
            let maskRevision = session.quietLedger.displayMaskRevision

            // The only transition is the existing hydration setter: no presentation republish.
            h.host.test_setActiveSessionBindingsAreHydrated(true)
            let after = h.host.ui.transcript.snapshot
            XCTAssertTrue(after.isHydrated)
            XCTAssertEqual(after.presentationRevision, baseRevision)
            XCTAssertEqual(after.displayMaskRevision, maskRevision)
            XCTAssertTrue(after.presentation.bindingsHydrated, "mask=\(hasMask): cache must expose hydration at the same revision")
            XCTAssertEqual(after.presentation.hydratedPersistentBinding, session.authoritativeHydratedBinding)
            XCTAssertEqual(after.presentation.hydratedBindingTransitionGeneration, session.authoritativeHydratedBindingTransitionGeneration)
            XCTAssertEqual(session.quietLedger.hiddenSourceIDs, hidden)
            XCTAssertTrue(after.presentation.visibleRows.contains(where: { $0.id == ordinary.id }))
            if let quietRowID {
                XCTAssertFalse(after.presentation.visibleRows.contains(where: { $0.id == quietRowID }))
                XCTAssertTrue(session.items.contains(where: { $0.id == quietRowID }))
            }
            func restoreSignal(_ snapshot: AgentTranscriptUISnapshot) -> AgentTranscriptRestoreSignal {
                .init(
                    tabID: snapshot.presentation.tabID,
                    bindingsHydrated: snapshot.presentation.bindingsHydrated,
                    presentationRevision: snapshot.presentation.revision
                )
            }
            XCTAssertEqual(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
                oldSignal: restoreSignal(before), newSignal: restoreSignal(after), currentTabID: session.tabID,
                rehydratePhase: .awaitingHydration(tabID: session.tabID, target: .liveBottom),
                lastRemountKey: nil, remountCount: 0, layoutPassToken: 42
            ), .init(tabID: session.tabID, presentationRevision: baseRevision, layoutPassToken: 42))
            let hydrated = try XCTUnwrap(session.quietTranscriptDisplayCache)
            XCTAssertEqual(hydrated.key, warm.key, "no new key state/revision is needed")
            var publications = 0
            let updates = h.host.ui.transcript.$snapshot.dropFirst().sink { _ in publications += 1 }
            for _ in 0 ..< 100 {
                _ = h.host.makeTranscriptUISnapshot()
                h.host.syncTranscriptUIState()
                hydrated.result.presentation.visibleBlocks.withUnsafeBufferPointer { old in
                    session.quietTranscriptDisplayCache?.result.presentation.visibleBlocks.withUnsafeBufferPointer { current in
                        XCTAssertEqual(old.baseAddress, current.baseAddress)
                    }
                }
            }
            XCTAssertEqual(publications, 0, "unchanged sync/getters reuse without publication")
            updates.cancel()

            // Real binding application suppresses intermediate UI sync. Its performance-only
            // assignment keeps the same revision, but must invalidate BEFORE the suppression guard.
            session.transcriptPerformanceSnapshot.projectionPublishCount += 1
            session.transcriptAutoFollowArmingState = h.host.activeTranscriptFollowBindingState.armingState == .armed
                ? .disarmedAfterManualDetach : .armed
            var observedSuppressedPublication = false
            let follow = h.host.$activeTranscriptFollowBindingState.dropFirst().sink { _ in
                observedSuppressedPublication = true
                XCTAssertTrue(h.host.isRestoringState, "observation is inside real suppressed binding application")
                XCTAssertNil(session.quietTranscriptDisplayCache, "presentation assignment invalidates even while UI sync is suppressed")
            }
            h.host.applySessionToBindings(session)
            follow.cancel()
            XCTAssertTrue(observedSuppressedPublication)
            XCTAssertEqual(h.host.activeTranscriptPresentation.revision, baseRevision)
            XCTAssertEqual(session.quietLedger.displayMaskRevision, maskRevision)
            let final = try XCTUnwrap(session.quietTranscriptDisplayCache)
            XCTAssertEqual(final.key, hydrated.key)
            XCTAssertEqual(final.result.presentation.performanceSnapshot, h.host.activeTranscriptPresentation.performanceSnapshot)
            XCTAssertTrue(final.result.presentation.bindingsHydrated)
            XCTAssertEqual(session.quietLedger.hiddenSourceIDs, hidden)
            if let quietRowID { XCTAssertFalse(final.result.presentation.visibleRows.contains(where: { $0.id == quietRowID })) }
            print("QUIET_A3_HYDRATION mask=\(hasMask) sameBaseRevision=true sameMaskRevision=true getterSyncIterations=100 unchangedPublications=\(publications) suppressedPublicationObserved=\(observedSuppressedPublication) blockVisits=\(final.result.blockVisits) rowVisits=\(final.result.rowVisits) anchorVisits=\(final.result.anchorVisits)")
        }
    }

    func testRealBarrierDefersDisplayBuildThenPublishesMaskRevisionAndReusesCacheWithoutGetterWork() async throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        session.runState = .running
        let owner = session.beginRunAttempt(source: "quiet-display")
        let wakeID = UUID()
        session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID)
        let row = AgentChatItem.assistant("[ack]")
        session.appendItem(row)
        h.host.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        let unmasked = h.host.ui.transcript.snapshot
        XCTAssertTrue(unmasked.presentation.visibleRows.contains(where: { $0.id == row.id }))
        var publications = 0
        let subscription = h.host.ui.transcript.$snapshot.dropFirst().sink { _ in publications += 1 }
        var barrierSyncAttempted = false
        session.onRunStateChanged = { s in
            guard s.terminalCommitInProgress else { return }
            barrierSyncAttempted = true
            XCTAssertNil(s.quietTranscriptDisplayCache)
            XCTAssertFalse(h.host.prepareQuietTranscriptDisplay())
            h.host.syncTranscriptUIState()
            XCTAssertNil(s.quietTranscriptDisplayCache, "No mask traversal or cache on barrier stack")
            XCTAssertEqual(h.host.ui.transcript.snapshot.displayMaskRevision, unmasked.displayMaskRevision)
        }
        let revision = await AgentRunTerminalCommitBarrier().commit(.init(
            binding: h.hooks.bindTerminalSession(session), ownership: owner, expectedRunID: session.runID,
            terminalState: .completed, source: "quiet-display", attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: false, supportsFollowUp: false, notifyTurnComplete: true, classifiesQuietCheckIn: true
        ))
        XCTAssertNotNil(revision)
        XCTAssertTrue(barrierSyncAttempted)
        h.host.syncTranscriptUIState()
        let masked = h.host.ui.transcript.snapshot
        XCTAssertGreaterThan(masked.displayMaskRevision, unmasked.displayMaskRevision)
        XCTAssertEqual(masked.presentationRevision, unmasked.presentationRevision, "Mask is not a forged base presentation mutation")
        XCTAssertFalse(masked.presentation.visibleRows.contains(where: { $0.id == row.id }))
        XCTAssertTrue(session.items.contains(where: { $0.id == row.id }), "Canonical source remains")
        let cache = try XCTUnwrap(session.quietTranscriptDisplayCache)
        let before = publications
        for _ in 0 ..< 100 {
            _ = h.host.makeTranscriptUISnapshot()
            h.host.syncTranscriptUIState()
            XCTAssertEqual(session.quietTranscriptDisplayCache?.key, cache.key)
            cache.result.presentation.visibleBlocks.withUnsafeBufferPointer { lhs in
                session.quietTranscriptDisplayCache?.result.presentation.visibleBlocks.withUnsafeBufferPointer { rhs in XCTAssertEqual(lhs.baseAddress, rhs.baseAddress) }
            }
        }
        XCTAssertEqual(publications, before, "Unchanged owner sync/getters do not publish")
        subscription.cancel()
    }

    func testActualSyntheticAnchorInstallThenRemoveAndHydrateLosesMaterializedMaskButNotPendingWake() throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let owner = session.beginRunAttempt(source: "quiet-anchor")
        let wake = UUID()
        session.quietLedger.markRoutineWake(owner: owner, wakeID: wake)
        let row = AgentChatItem.assistant("[ack]")
        session.appendItem(row)
        session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-anchor"))
        let turnID = UUID()
        let summary = AgentTranscriptTurnSummary(requestText: nil, conclusionText: "[ack]", compactConclusionText: "[ack]", middleSummaryText: nil, toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false)
        let transcript = AgentTranscript(turns: [.init(id: turnID, conclusionActivityID: row.id, retentionTier: .archived, summary: summary, terminalState: .completed, startedAt: date, completedAt: date)])
        h.host.applyTranscriptPresentation(transcript, to: session)
        XCTAssertFalse(session.fullTranscriptProjection.archivedBlocks.isEmpty)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        let hiddenArchive = try XCTUnwrap(session.quietTranscriptDisplayCache)
        XCTAssertTrue(hiddenArchive.result.archivedBlocks.isEmpty, "Separate archived conclusion is masked at actual UI sync")
        XCTAssertEqual(h.host.ui.transcript.snapshot.presentation.archivedHistoryState.blockCount, 0)
        h.host.setCompressedHistoryVisibility(tabID: session.tabID, isRevealed: true)
        h.host.syncTranscriptUIState()
        let revealed = try XCTUnwrap(session.quietTranscriptDisplayCache)
        XCTAssertNotEqual(revealed.key.presentationRevision, hiddenArchive.key.presentationRevision)
        XCTAssertTrue(h.host.ui.transcript.snapshot.archivedBlocks.isEmpty)
        h.host.setTranscriptWindowExpanded(tabID: session.tabID, isExpanded: true)
        h.host.syncTranscriptUIState()
        XCTAssertNotEqual(session.quietTranscriptDisplayCache?.key.presentationRevision, revealed.key.presentationRevision)
        XCTAssertTrue(h.host.ui.transcript.snapshot.presentation.visibleRows.isEmpty, "Existing archive/window paging paths cannot resurface hidden synthetic rows")
        _ = session.removeItem(at: 0)
        session.reconcileQuietSourceIDs(previousLiveIDs: [row.id])
        XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(row.id), "Materialized synthetic conclusion retains exact source proof")
        XCTAssertNotNil(session.fullTranscriptProjection.rowAnchorIndex[row.id], "Retained source is indexed by its existing anchor owner")
        session.clearDerivedTranscriptCaches()
        h.host.applyTranscriptPresentation(.empty, to: session)
        XCTAssertFalse(session.quietLedger.hiddenSourceIDs.contains(row.id), "Actual source-anchor retirement loses materialized proof")
        XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(wake), "Still-admissible unmaterialized wake is different")
        session.setItemsSilently([row], reason: .persistedSessionHydration)
        h.host.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        XCTAssertTrue(h.host.ui.transcript.snapshot.presentation.visibleRows.contains(where: { $0.id == row.id }), "B8 rehydration is visible, not a pending marker")
        XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(wake))
    }

    func testInactiveActivationArchiveWriterAndHelperOnlyChangesInvalidateExactCache() throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let first = AgentChatItem.assistant("[ack]", sequenceIndex: 0)
        let quiet = AgentChatItem.thinking("[ack]", sequenceIndex: 1)
        let turnID = UUID(), spanID = UUID()
        func transcript(_ rows: [AgentChatItem]) -> AgentTranscript {
            .init(turns: [.init(id: turnID, responseSpans: [.init(id: spanID, lifecycle: .completed, startedAt: date, completedAt: date, activities: rows.map { .init(from: $0) })], retentionTier: .condensed, terminalState: .completed, startedAt: date, completedAt: date)])
        }
        session.setItemsSilently([first], reason: .testOverride)
        let owner = session.beginRunAttempt(source: "inactive")
        // Use the real ledger classifier over a separate exact quiet suffix.
        let ack = AgentChatItem.assistant("[ack]")
        session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
        session.appendItem(quiet)
        session.appendItem(ack)
        session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "inactive"))
        h.host.test_setCurrentTabIDOverride(UUID())
        h.host.applyTranscriptPresentation(transcript(session.items), to: session)
        XCTAssertNil(session.quietTranscriptDisplayCache, "Inactive install does no mask work")
        h.host.test_setCurrentTabIDOverride(session.tabID)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        let installed = try XCTUnwrap(session.quietTranscriptDisplayCache)
        let originalNormalBlocks = h.host.activeTranscriptPresentation.visibleBlocks
        XCTAssertFalse(installed.result.presentation.visibleBlocks.flatMap(\.activityIDs).contains(ack.id))
        // Actual archive install owner clears the cache even with an unchanged mask.
        let revision = session.quietLedger.displayMaskRevision
        let sourceIDs = session.quietLedger.hiddenSourceIDs
        session.mutateItem(at: 0) { $0.kind = .thinking }
        session.mutateItem(at: 1) { $0.kind = .assistant }
        // Existing cache reset/install owns a canonical rebuild. Live source IDs still prove both
        // hidden rows; this is not persisted hydration, which would intentionally discard proof.
        session.clearDerivedTranscriptCaches()
        let next = transcript(session.items)
        let changed = h.host.applyTranscriptPresentation(next, to: session)
        XCTAssertNil(session.quietTranscriptDisplayCache)
        XCTAssertEqual(session.quietLedger.displayMaskRevision, revision)
        XCTAssertEqual(session.quietLedger.hiddenSourceIDs, sourceIDs)
        var before = originalNormalBlocks
        var after = changed.projection.workingBlocks
        for index in before.indices {
            before[index].displaySummaryInputs = []
        }
        for index in after.indices {
            after[index].displaySummaryInputs = []
        }
        XCTAssertEqual(before, after, "Only the lossless helper differs in the ordinary display value")
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        let rebuilt = try XCTUnwrap(session.quietTranscriptDisplayCache)
        XCTAssertNotEqual(rebuilt.key.presentationRevision, installed.key.presentationRevision)
        XCTAssertEqual(rebuilt.result.presentation.visibleBlocks.first?.groupedHistory?.summary.hiddenAssistantCount, 0)
        XCTAssertEqual(rebuilt.result.presentation.visibleBlocks.first?.groupedHistory?.summary.hiddenProgressCount, 1)
        session.clearDerivedTranscriptCaches()
        XCTAssertNil(session.quietTranscriptDisplayCache, "Actual archive reset owner also invalidates")
    }

    func testFullBufferedLeadingQuietNarrationDoesNotSurviveInFrozenToolsSummary() throws {
        let quiet = AgentChatItem.assistant("[ack]", sequenceIndex: 0)
        var rows = [quiet]
        for index in 0 ..< 20 {
            rows.append(.init(kind: .toolResult, text: "source \(index)", toolName: "read_file", toolInvocationID: UUID(), toolResultJSON: "{}", sequenceIndex: rows.count))
        }
        let turn = AgentTranscriptTurn(responseSpans: [.init(lifecycle: .completed, startedAt: date, completedAt: date, activities: rows.map { .init(from: $0, toolExecution: AgentTranscriptToolNormalizer.toolExecution(for: $0)) })], retentionTier: .full, terminalState: .completed, startedAt: date, completedAt: date)
        let frozen = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: .init(turns: [turn]))
        let base = AgentTranscriptProjectionBuilder.build(from: frozen)
        let original = try XCTUnwrap(base.workingBlocks.first(where: { $0.kind == .groupedHistory }))
        XCTAssertEqual(base.workingBlocks.first?.rows.first?.id, quiet.id, "Real leading-assistant buffering, outside group sections")
        XCTAssertEqual(original.groupedHistory?.summary.toolSummary?.shortNarration, "[ack]")
        XCTAssertFalse(try XCTUnwrap(original.groupedHistory).sections.flatMap(\.childBlocks).flatMap(\.rows).contains(where: { $0.id == quiet.id }))
        let result = AgentTranscriptProjectionBuilder.maskForLocalDisplay(presentation(base), archivedBlocks: base.workingBlocks, hiddenSourceIDs: [quiet.id])
        let masked = try XCTUnwrap(result.presentation.visibleBlocks.first(where: { $0.kind == .groupedHistory }))
        XCTAssertNil(masked.groupedHistory?.summary.toolSummary?.shortNarration, "Hidden buffered source cannot remain as narration in frozen summary")
        XCTAssertEqual(masked.groupedHistory?.summary.hiddenToolCardCount, original.groupedHistory?.summary.hiddenToolCardCount)
        XCTAssertEqual(result.archivedBlocks, result.presentation.visibleBlocks)
    }

    func testDisplayOwnerHardwareSamplesAndFrozenSummaryStorageReuse() throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let transcript = AgentTranscript(turns: (0 ..< 8).map { _ in AgentQuietCheckInReplay.toolHeavyTurn(date: date) })
        let built = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, protection: .none, turnCaches: [:])
        var sharedInputBuffers = 0
        for _ in 0 ..< 20 {
            let reused = AgentTranscriptProjectionBuilder.buildWithCaches(from: transcript, protection: .none, turnCaches: built.updatedTurnCaches)
            for (id, old) in built.updatedTurnCaches {
                let current = try XCTUnwrap(reused.updatedTurnCaches[id])
                let oldBlock = try XCTUnwrap(old.workingBlocks.first)
                let currentBlock = try XCTUnwrap(current.workingBlocks.first)
                oldBlock.displaySummaryInputs.withUnsafeBufferPointer { first in
                    currentBlock.displaySummaryInputs.withUnsafeBufferPointer { second in
                        XCTAssertEqual(first.baseAddress, second.baseAddress)
                        sharedInputBuffers += 1
                    }
                }
            }
        }
        XCTAssertEqual(sharedInputBuffers, 160)
        var compacted = AgentTranscriptCompactor.compact(transcript)
        for index in compacted.turns.indices {
            compacted.turns[index].retentionTier = .archived
        }
        h.host.applyTranscriptPresentation(compacted, to: session)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID)
        h.host.syncTranscriptUIState()
        var sealMS: [Double] = [], ownerMS: [Double] = [], hitMS: [Double] = []
        var measuredCacheBuilds = 0
        var workTotals = (blocks: 0, rows: 0, anchors: 0)
        var workMax = (blocks: 0, rows: 0, anchors: 0)
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        for _ in 0 ..< 100 {
            let owner = session.beginRunAttempt(source: "quiet-display-hardware")
            let wake = UUID()
            session.quietLedger.recordPhysicalDispatch(owner: owner, wakeID: wake, routineQuietCheckIn: true, alreadyAcquired: false)
            session.appendItem(.assistant("[ack]"))
            let start = ContinuousClock.now
            session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
            sealMS.append(ms(start.duration(to: .now)))
            XCTAssertNil(session.quietTranscriptDisplayCache, "Seal only invalidates membership/cache")
            let syncStart = ContinuousClock.now
            h.host.syncTranscriptUIState()
            ownerMS.append(ms(syncStart.duration(to: .now)))
            let cache = try XCTUnwrap(session.quietTranscriptDisplayCache)
            XCTAssertFalse(cache.result.archivedBlocks.isEmpty, "Separate archived materialization is part of the owning UI measurement")
            measuredCacheBuilds += 1
            workTotals.blocks += cache.result.blockVisits
            workTotals.rows += cache.result.rowVisits
            workTotals.anchors += cache.result.anchorVisits
            workMax.blocks = max(workMax.blocks, cache.result.blockVisits)
            workMax.rows = max(workMax.rows, cache.result.rowVisits)
            workMax.anchors = max(workMax.anchors, cache.result.anchorVisits)
            let hitStart = ContinuousClock.now
            for _ in 0 ..< 10 {
                _ = h.host.makeTranscriptUISnapshot()
            }
            hitMS.append(ms(hitStart.duration(to: .now)) / 10)
            cache.result.archivedBlocks.withUnsafeBufferPointer { old in
                session.quietTranscriptDisplayCache?.result.archivedBlocks.withUnsafeBufferPointer { current in XCTAssertEqual(old.baseAddress, current.baseAddress) }
            }
            XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-display-hardware"))
            session.retireQuietUnmaterializedWake(wake)
            h.host.syncTranscriptUIState()
        }
        func p99(_ samples: [Double]) -> Double {
            samples.sorted()[Int(Double(samples.count - 1) * 0.99)]
        }
        print("QUIET_C5_UI_HARDWARE samples=100 getters=1000 positivelyRoutineRowsPerSeal=1 sealP99MS=\(p99(sealMS)) ownerSyncP99MS=\(p99(ownerMS)) ownerSyncMaxMS=\(ownerMS.max()!) getterP99MS=\(p99(hitMS)) archiveBlocks=\(session.archivedTranscriptSnapshot.blocks.count) frozenCacheInputBufferMatches=\(sharedInputBuffers) observedNewHelperBuffersOnReuse=0 helperRowStride=\(MemoryLayout<AgentTranscriptDisplaySummaryInput.Row>.stride) helperInputStride=\(MemoryLayout<AgentTranscriptDisplaySummaryInput>.stride)")
        print("QUIET_A3_DISPLAY_WORK measuredCacheBuilds=\(measuredCacheBuilds) blocksTotal=\(workTotals.blocks) rowsTotal=\(workTotals.rows) anchorsTotal=\(workTotals.anchors) blocksMax=\(workMax.blocks) rowsMax=\(workMax.rows) anchorsMax=\(workMax.anchors)")
    }

    func testEmptyLocalMaskRetiresOnlyDisplayMetadataNotHydrationOrCanonicalFollowScope() {
        let row = AgentChatItem.assistant("[ack]", sequenceIndex: 0)
        let projected = projection([row], tier: .full)
        let turnID = projected.workingBlocks[0].turnID
        let base = AgentTranscriptPresentationSnapshot(
            tabID: UUID(), revision: 17, visibleBlocks: projected.workingBlocks, workingBlocks: projected.workingBlocks,
            visibleRows: projected.workingRows, workingRows: projected.workingRows,
            rowAnchorIndex: projected.rowAnchorIndex, anchorBlockIndex: projected.anchorBlockIndex,
            bindingsHydrated: true,
            metadata: .init(latestTurnID: turnID, dynamicSummaryLockTargetTurnID: turnID, recentAssistantItemIDs: [row.id])
        )
        let result = AgentTranscriptProjectionBuilder.maskForLocalDisplay(base, archivedBlocks: [], hiddenSourceIDs: [row.id]).presentation
        XCTAssertNil(result.metadata.latestTurnID)
        XCTAssertNil(result.metadata.dynamicSummaryLockTargetTurnID)
        XCTAssertTrue(result.metadata.recentAssistantItemIDs.isEmpty)
        XCTAssertEqual(result.tabID, base.tabID)
        XCTAssertEqual(result.revision, 17)
        XCTAssertTrue(result.bindingsHydrated)
        XCTAssertEqual(base.metadata.dynamicSummaryLockTargetTurnID, turnID)
    }

    func testNoRemovalPreservesExactWindowedMetadataAndPartialTurnSurvival() {
        let quiet = AgentChatItem.assistant("[ack]", sequenceIndex: 0)
        let ordinary = AgentChatItem.assistant("ordinary", sequenceIndex: 1)
        let projected = projection([quiet, ordinary], tier: .full)
        let turnID = projected.workingBlocks[0].turnID
        let outsideWindow = UUID()
        for target in [turnID, outsideWindow] {
            let base = AgentTranscriptPresentationSnapshot(
                revision: 31, workingBlocks: projected.workingBlocks, workingRows: projected.workingRows,
                rowAnchorIndex: projected.rowAnchorIndex, anchorBlockIndex: projected.anchorBlockIndex,
                archivedHistoryState: .init(hasArchivedHistory: true, presentedRowCount: 71, blockCount: 19),
                metadata: .init(latestTurnID: target, dynamicSummaryLockTargetTurnID: target)
            )
            let unchanged = AgentTranscriptProjectionBuilder.maskForLocalDisplay(base, archivedBlocks: [], hiddenSourceIDs: [UUID()])
            XCTAssertEqual(unchanged.presentation, base, "No removal is exactly the caller's windowed presentation")
            XCTAssertEqual(unchanged.anchorVisits, 0, "No-op masking does not rebuild the anchor indexes")
            let partial = AgentTranscriptProjectionBuilder.maskForLocalDisplay(base, archivedBlocks: [], hiddenSourceIDs: [quiet.id])
            XCTAssertEqual(partial.presentation.metadata, base.metadata, "Partial loss or an out-of-window reference is not full turn loss")
            XCTAssertEqual(partial.presentation.archivedHistoryState, base.archivedHistoryState, "An untouched archive keeps its caller metadata")
            XCTAssertTrue(partial.presentation.workingRows.contains(where: { $0.id == ordinary.id }))
            let full = AgentTranscriptProjectionBuilder.maskForLocalDisplay(base, archivedBlocks: [], hiddenSourceIDs: [quiet.id, ordinary.id])
            XCTAssertEqual(full.presentation.metadata.latestTurnID, target == turnID ? nil : target)
            XCTAssertEqual(full.presentation.metadata.dynamicSummaryLockTargetTurnID, target == turnID ? nil : target)
        }
    }

    func testStableArchiveAcrossRealStreamingBasePublicationsReusesBufferAndDoesNoArchiveWork() throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let history = AgentTranscript(turns: (0 ..< 2000).map { index in
            let sourceID = UUID()
            return AgentTranscriptTurn(
                conclusionActivityID: sourceID, retentionTier: .archived,
                summary: .init(requestText: nil, conclusionText: "ordinary history \(index)", compactConclusionText: "ordinary history \(index)", middleSummaryText: nil, toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false),
                terminalState: .completed, startedAt: date, completedAt: date
            )
        })
        h.host.applyTranscriptPresentation(history, to: session)
        let wake = UUID()
        let owner = session.beginRunAttempt(source: "quiet-archive-stream")
        session.quietLedger.markRoutineWake(owner: owner, wakeID: wake)
        session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-archive-stream"))
        let installedArchive = session.archivedTranscriptSnapshot
        session.archivedTranscriptSnapshot = installedArchive
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
        h.host.syncTranscriptUIState()
        let first = try XCTUnwrap(session.quietTranscriptDisplayCache)
        XCTAssertGreaterThanOrEqual(session.archivedTranscriptSnapshot.rows.count, 2000)
        XCTAssertGreaterThanOrEqual(first.result.rowVisits, 2000, "The initial archive projection is counted")
        XCTAssertEqual(session.quietLedger.hiddenSourceIDs, [wake], "Hidden source is absent from every materialized region")
        var samples: [Double] = []
        var work: [Int] = []
        for index in 0 ..< 100 {
            // Same archive and mask; ordinary live content changes at the existing presentation owner.
            let live = projection([.assistant("ordinary stream \(index)")], tier: .full)
            session.transcriptProjection = live
            session.workingTranscriptProjection = live
            let previousRevision = h.host.activeTranscriptPresentation.revision
            let start = ContinuousClock.now
            _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
            h.host.syncTranscriptUIState()
            let elapsed = start.duration(to: .now)
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            let base = h.host.activeTranscriptPresentation
            let cache = try XCTUnwrap(session.quietTranscriptDisplayCache)
            XCTAssertGreaterThan(base.revision, previousRevision, "Exercises the actual didSet and owner UI sync")
            XCTAssertEqual(cache.result.presentation, base)
            XCTAssertEqual(cache.result.presentation.metadata, base.metadata)
            XCTAssertEqual(cache.result.presentation.archivedHistoryState, base.archivedHistoryState)
            XCTAssertEqual(cache.result.anchorVisits, 0)
            XCTAssertEqual(cache.result.blockVisits, 2, "Only the live visible/working blocks; no archive ID/count pass")
            XCTAssertLessThanOrEqual(cache.result.rowVisits, 4, "Only visible/working live rows, never the stable 2000-row archive")
            work.append(cache.result.rowVisits)
            first.result.archivedBlocks.withUnsafeBufferPointer { old in
                cache.result.archivedBlocks.withUnsafeBufferPointer { current in XCTAssertEqual(old.baseAddress, current.baseAddress) }
            }
            session.archivedTranscriptSnapshot.blocks.withUnsafeBufferPointer { caller in
                cache.result.archivedBlocks.withUnsafeBufferPointer { current in XCTAssertEqual(caller.baseAddress, current.baseAddress, "No-op preserves caller archive buffer") }
            }
        }
        print("QUIET_F2_STREAM samplesMS=\(samples) totalRowVisits=\(work) p99MS=\(samples.sorted()[98]) maxMS=\(samples.max()!) quantile=nearestRankCeil0.99Nminus1 archiveRows=2000 baseAssignments=100")
        // An equal-value archive assignment is still a real writer/invalidation boundary.
        let snapshot = session.archivedTranscriptSnapshot
        session.archivedTranscriptSnapshot = snapshot
        XCTAssertNil(session.quietTranscriptDisplayCache)
        h.host.syncTranscriptUIState()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(session.quietTranscriptDisplayCache).result.rowVisits, 2000)
        session.retireQuietUnmaterializedWake(wake)
        h.host.syncTranscriptUIState()
        XCTAssertEqual(session.quietLedger.hiddenSourceIDs, [])
        XCTAssertEqual(session.quietTranscriptDisplayCache?.result.presentation, h.host.activeTranscriptPresentation)
    }

    func testSourceDrivenLiveRefreshReusesQuietArchiveForUnmaterializedWake() throws {
        try assertSourceDrivenLiveRefreshReusesQuietArchive(archivedQuietSource: false)
    }

    func testSourceDrivenLiveRefreshReusesQuietArchiveForArchivedSyntheticAlias() throws {
        try assertSourceDrivenLiveRefreshReusesQuietArchive(archivedQuietSource: true)
    }

    private func assertSourceDrivenLiveRefreshReusesQuietArchive(archivedQuietSource: Bool) throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let wake = UUID()
        let quiet = AgentChatItem.assistant("[ack]", sequenceIndex: 0)
        let owner = session.beginRunAttempt(source: "quiet-source-archive")
        session.quietLedger.markRoutineWake(owner: owner, wakeID: wake)
        if archivedQuietSource { session.appendItem(quiet) }
        session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-source-archive"))
        session.runState = .running
        let request = AgentChatItem.user("ordinary live request", sequenceIndex: 10000)
        let stream = AgentChatItem.assistant("ordinary live stream", sequenceIndex: 10001)
        let live = AgentTranscriptIO.buildTranscript(from: [request, stream], terminalState: .running, compact: false)
        let history = (0 ..< 2000).map { index in
            let text = archivedQuietSource && index == 0 ? "[ack]" : "ordinary history \(index)"
            return AgentTranscriptTurn(
                conclusionActivityID: archivedQuietSource && index == 0 ? quiet.id : UUID(), retentionTier: .archived,
                summary: .init(requestText: nil, conclusionText: text, compactConclusionText: text, middleSummaryText: nil, toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false),
                terminalState: .completed, startedAt: date, completedAt: date
            )
        }
        let transcript = AgentTranscriptCompactor.compact(AgentTranscript(turns: history + live.turns))
        h.host.applyTranscriptPresentation(transcript, to: session)
        // Retention movement preserves the archived source's proof; source mutations below use
        // the ordinary session callback, not direct base/projection assignment.
        session.setItemsSilently([request, stream], reason: .retentionCompaction)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
        h.host.syncTranscriptUIState()
        let initial = try XCTUnwrap(session.quietTranscriptDisplayCache)
        let installedArchive = session.archivedTranscriptSnapshot
        XCTAssertEqual(installedArchive.rows.count, 2000)
        XCTAssertEqual(initial.result.archiveBlockVisits, 2000)
        XCTAssertEqual(initial.result.archiveRowVisits, 2000)
        XCTAssertTrue(session.quietLedger.hiddenSourceIDs.contains(archivedQuietSource ? quiet.id : wake))
        let alias = try XCTUnwrap(installedArchive.rows.first)
        if archivedQuietSource {
            XCTAssertNotEqual(alias.id, quiet.id)
            XCTAssertTrue(session.quietTranscriptArchiveDisplayCache?.region.removedRowIDs.contains(alias.id) == true)
            XCTAssertFalse(initial.result.archivedBlocks.contains { $0.rows.contains { $0.id == alias.id } })
        }
        let expectedArchiveCount = archivedQuietSource ? 1999 : 2000
        XCTAssertEqual(initial.result.archivedBlocks.count, expectedArchiveCount)
        h.host.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(true)
        defer { h.host.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(false) }
        var quietMS: [Double] = [], builderMS: [Double] = [], refreshMS: [Double] = [], inclusiveMS: [Double] = [], archiveSnapshotMS: [Double] = []
        var quietArchiveBlocks: [Int] = [], quietArchiveRows: [Int] = []
        func ms(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
            let elapsed = from.duration(to: to)
            return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }
        for index in 0 ..< 100 {
            let oldSourceRevision = session.sourceItemsRevision
            let oldBuildCount = session.transcriptPerformanceSnapshot.projectionBuildCount
            let oldPresentationRevision = h.host.activeTranscriptPresentation.revision
            let start = ContinuousClock.now
            session.mutateItem(at: 1) { $0.text = "ordinary streamed text \(index)"
                $0.isStreaming = true
            }
            // Drain the real scheduled source refresh synchronously, separating existing builder
            // cost from publication + didSet-owned quiet display preparation. No projection helper.
            h.host.refreshDerivedTranscriptState(for: session, reason: .liveMutation, publishActivePresentation: false)
            let refreshed = ContinuousClock.now
            let publishStart = ContinuousClock.now
            _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
            h.host.syncTranscriptUIState()
            let end = ContinuousClock.now
            quietMS.append(ms(publishStart, end))
            refreshMS.append(ms(start, refreshed))
            inclusiveMS.append(ms(start, end))
            try builderMS.append(XCTUnwrap(session.transcriptPerformanceSnapshot.lastProjectionBuildDurationMS))
            let cache = try XCTUnwrap(session.quietTranscriptDisplayCache)
            let base = h.host.activeTranscriptPresentation
            XCTAssertGreaterThan(session.sourceItemsRevision, oldSourceRevision)
            XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, oldBuildCount + 1)
            XCTAssertGreaterThan(base.revision, oldPresentationRevision)
            XCTAssertEqual(session.transcriptPerformanceSnapshot.lastSanitizeReusedTurnCount, 2000)
            XCTAssertTrue(cache.result.presentation.visibleRows.contains { $0.id == stream.id && $0.text == "ordinary streamed text \(index)" })
            XCTAssertEqual(cache.result.presentation.visibleRows, base.visibleRows)
            XCTAssertEqual(cache.result.presentation.workingRows, base.workingRows)
            XCTAssertEqual(cache.result.presentation.visibleBlocks, base.visibleBlocks)
            XCTAssertEqual(cache.result.presentation.workingBlocks, base.workingBlocks)
            XCTAssertEqual(cache.result.presentation.metadata, base.metadata)
            XCTAssertEqual(cache.result.presentation.rowAnchorIndex, base.rowAnchorIndex)
            XCTAssertEqual(cache.result.presentation.anchorBlockIndex, base.anchorBlockIndex)
            XCTAssertEqual(cache.result.presentation.archivedHistoryState, .init(hasArchivedHistory: true, presentedRowCount: expectedArchiveCount, blockCount: expectedArchiveCount))
            XCTAssertEqual(cache.result.archiveBlockVisits, 0, "No repeated QUIET MASK archive traversal; existing builder work is separate")
            XCTAssertEqual(cache.result.archiveRowVisits, 0)
            XCTAssertEqual(cache.result.archivedBlocks.count, expectedArchiveCount)
            quietArchiveBlocks.append(cache.result.archiveBlockVisits)
            quietArchiveRows.append(cache.result.archiveRowVisits)
            initial.result.archivedBlocks.withUnsafeBufferPointer { old in
                cache.result.archivedBlocks.withUnsafeBufferPointer { current in XCTAssertEqual(old.baseAddress, current.baseAddress, "Masked archive storage survives the BUILT installation") }
            }
            installedArchive.blocks.withUnsafeBufferPointer { old in
                session.archivedTranscriptSnapshot.blocks.withUnsafeBufferPointer { current in XCTAssertEqual(old.baseAddress, current.baseAddress, "Unchanged archive is not reinstalled") }
            }
            // Diagnostic-only repetition of the unchanged production archive snapshot/count/index
            // routine on this SAME fixture, outside both timed real paths. This is a subcost,
            // not the entire builder cost, and is not additional production quiet-mask work.
            let archiveStart = ContinuousClock.now
            let measuredArchive = AgentTranscriptProjectionBuilder.archivedSnapshot(from: session.fullTranscriptProjection)
            archiveSnapshotMS.append(ms(archiveStart, .now))
            XCTAssertEqual(measuredArchive.rows.count, 2000)
        }
        func measurements(_ samples: [Double]) -> [String: Any] {
            ["samplesMS": samples, "p99MS": samples.sorted()[Int(ceil(0.99 * Double(samples.count))) - 1], "maxMS": samples.max()!]
        }
        let measurements: [String: Any] = [
            "scenario": archivedQuietSource ? "archived-synthetic-alias" : "unmaterialized-wake", "n": 100,
            "quantile": "sort(samples)[ceil(0.99*N)-1]", "archiveRows": 2000,
            "quietPublicationAndOwnerSync": measurements(quietMS), "existingBuilderTotal": measurements(builderMS),
            "sourceAndDerivedRefresh": measurements(refreshMS), "inclusiveSourceThroughUISync": measurements(inclusiveMS),
            "separateArchiveSnapshotSubcost": measurements(archiveSnapshotMS),
            "quietArchiveBlockVisits": quietArchiveBlocks, "quietArchiveRowVisits": quietArchiveRows,
            "builderStatus": "pre-existing, unchanged; current measurement, not a pristine-baseline measurement"
        ]
        try print("QUIET_F2_SOURCE_STREAM " + String(decoding: JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys]), as: UTF8.self))
        // A real archive replacement runs through the built installer and MUST retire both caches.
        var changed = session.transcript
        changed.turns[10].conclusionActivityID = UUID()
        changed.turns[10].summary?.conclusionText = "changed archived conclusion"
        changed.turns[10].summary?.compactConclusionText = "changed archived conclusion"
        h.host.applyTranscriptPresentation(changed, to: session)
        XCTAssertNil(session.quietTranscriptArchiveDisplayCache)
        XCTAssertNil(session.quietTranscriptDisplayCache)
        _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
        h.host.syncTranscriptUIState()
        let replaced = try XCTUnwrap(session.quietTranscriptDisplayCache)
        XCTAssertEqual(replaced.result.archiveBlockVisits, 2000)
        XCTAssertEqual(replaced.result.archiveRowVisits, 2000)
        XCTAssertTrue(replaced.result.archivedBlocks.contains { $0.rows.contains { $0.text == "changed archived conclusion" } })
        XCTAssertEqual(replaced.result.archivedBlocks.count, expectedArchiveCount)
        // Explicit same-content apply/hydration remains an invalidating writer, never a live reuse.
        h.host.applyTranscriptPresentation(session.transcript, to: session)
        XCTAssertNil(session.quietTranscriptArchiveDisplayCache)
    }

    func testReusedArchiveRetainsSyntheticAliasContributionAcrossWindowedBaseAssignments() throws {
        let (h, manager, session) = try liveFixture()
        defer { withExtendedLifetime(manager) {} }
        let row = AgentChatItem.assistant("[ack]")
        let owner = session.beginRunAttempt(source: "quiet-archive-alias")
        session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
        session.appendItem(row)
        session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
        XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-archive-alias"))
        let archived = projection([], tier: .archived, conclusionID: row.id, summary: .init(
            requestText: nil, conclusionText: "[ack]", compactConclusionText: "[ack]", middleSummaryText: nil,
            toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false
        ))
        session.archivedTranscriptSnapshot = AgentTranscriptProjectionBuilder.archivedSnapshot(from: archived)
        let synthetic = try XCTUnwrap(archived.archivedRows.first)
        XCTAssertNotEqual(synthetic.id, row.id)
        for index in 0 ..< 3 {
            // The archive carries the source anchor. Windowed flat rows can overlap it without
            // carrying that block/anchor themselves; archive removedRowIDs must still contribute.
            let windowed = AgentTranscriptProjection(workingRows: [synthetic], anchorBlockIndex: archived.anchorBlockIndex)
            session.transcriptProjection = windowed
            session.workingTranscriptProjection = windowed
            _ = h.host.test_publishTranscriptPresentation(tabID: session.tabID, forceRevision: true)
            h.host.syncTranscriptUIState()
            let result = try XCTUnwrap(session.quietTranscriptDisplayCache).result
            XCTAssertTrue(result.archivedBlocks.isEmpty)
            XCTAssertTrue(result.presentation.visibleRows.isEmpty)
            XCTAssertTrue(result.presentation.workingRows.isEmpty)
            XCTAssertTrue(result.presentation.anchorBlockIndex.isEmpty)
            if index > 0 { XCTAssertEqual(result.rowVisits, 2, "Only the two flat aliases are visited; no cached archive scan") }
        }
    }

    func testStructuralRekeyAndRetentionIndexOwnerWorkCadence() {
        let session = AgentTabSession(tabID: UUID())
        for _ in 0 ..< 12 {
            let owner = session.beginRunAttempt(source: "quiet-retained-source")
            let wake = UUID()
            session.quietLedger.recordPhysicalDispatch(owner: owner, wakeID: wake, routineQuietCheckIn: true, alreadyAcquired: false)
            session.appendItem(.assistant("[ack]"))
            session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
            XCTAssertTrue(session.endRunAttempt(ifCurrent: owner, source: "quiet-retained-source"))
            session.retireQuietUnmaterializedWake(wake)
        }
        let identities = session.liveItemIDs
        XCTAssertEqual(session.quietLedger.hiddenSourceIDs, identities)
        let maskRevision = session.quietLedger.displayMaskRevision
        let original = session.quietLedger.facts
        let scansBefore = session.test_fullRetentionPayloadMapScannedItemCount
        var samples: [Double] = []
        for _ in 0 ..< 32 {
            let start = ContinuousClock.now
            let next = session.nextSequenceIndex
            session.mutateItem(at: 0) { $0.sequenceIndex = next }
            session.setItemsSilentlyForRetentionCompaction(session.items)
            let elapsed = start.duration(to: .now)
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            XCTAssertEqual(session.liveItemIDs, identities)
            XCTAssertEqual(session.quietLedger.facts, original)
            XCTAssertEqual(session.quietLedger.hiddenSourceIDs, identities)
            XCTAssertEqual(session.quietLedger.displayMaskRevision, maskRevision, "Structural source proof survives without a fake membership change")
        }
        XCTAssertEqual(session.items.count, 12)
        print("QUIET_C5_STRUCTURAL samples=32 retainedSuffixRows=12 rekeyRetentionP99MS=\(samples.sorted()[31]) retentionPayloadItemsScanned=\(session.test_fullRetentionPayloadMapScannedItemCount - scansBefore) hiddenMembership=\(session.quietLedger.hiddenSourceIDs.count) newQuietAddressIndexes=0")
    }
}

/// The normal save owner may project on its persistence executor, not the main actor.
private final class QuietW0TraversalCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]

    func add(_ phase: String, _ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        values[phase, default: 0] += count
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// W0 feasibility only. Exact membership and an ordinary baseline are injected, not certified.
/// The owner, retention, codecs, storage writer, cold loader and projection builders are real.
@MainActor
final class AgentQuietRetainedViewFeasibilityTests: XCTestCase {
    func testFrozenRetainedTurnsComposeWithNewOrdinarySuffixThroughNormalSaveReload() async throws {
        for tier in [AgentTranscriptRetentionTier.full, .condensed, .summary, .archived] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-w0-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = WorkspaceModel(name: "Quiet W0", repoPaths: [], customStoragePath: directory)
            let service = AgentSessionDataService()
            let firstOrdinary = ordinaryRows(base: 0, toolCount: 6) + ordinaryRows(base: 200, toolCount: 6).dropFirst()
            let firstBaseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(
                from: firstOrdinary, terminalState: .idle
            ).turns.first)
            let firstQuiet = quietRows(base: 100, wakeID: id(900)) + quietRows(base: 300, wakeID: id(902))
            let secondRequest = row(1000, kind: .user, text: "New ordinary request")
            let secondOrdinary = [secondRequest] + ordinaryRows(base: 1000, toolCount: 9).dropFirst()
            // Eight newer ordinary executions move the protected tool tail off the old turn.
            // Further ordinary work below is appended to this SAME still-full suffix after trim.
            let initialSecondRows = Array(secondOrdinary.prefix(17))
            var transcript = AgentTranscriptIO.buildTranscript(
                from: firstOrdinary + firstQuiet + initialSecondRows, terminalState: .idle
            )
            AgentTranscriptIO.test_installQuietLocalBaseline(firstBaseline, in: &transcript)
            // Set an eligible OLD turn's tier, as the existing retention tests do, to exercise
            // each real destructive trim without inventing a production pressure threshold.
            transcript.turns[0].retentionTier = tier
            transcript = AgentTranscriptCompactor.compact(transcript)
            let frozenFirst = transcript.turns[0]
            let working = AgentTranscriptIO.workingSourceItems(from: transcript)
            XCTAssertEqual(working.contains { $0.id == firstOrdinary[1].id }, tier == .full)
            if tier != .full {
                XCTAssertFalse(transcript.turns[0].allActivities.contains { $0.itemKind == .toolCall })
                XCTAssertEqual(transcript.turns[0].summary?.toolCount, 14)
                XCTAssertEqual(transcript.turns[0].quietLocal?.summary?.toolCount, 12)
            }

            let secondBaseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(
                from: secondOrdinary, terminalState: .idle
            ).turns.first)
            let secondQuiet = quietRows(base: 1100, wakeID: id(901))
            transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: transcript,
                workingItems: working + Array(secondOrdinary.dropFirst(initialSecondRows.count)) + secondQuiet,
                terminalState: .completed
            )
            AgentTranscriptIO.test_installQuietLocalBaseline(secondBaseline, in: &transcript)
            XCTAssertEqual(transcript.turns.map(\.id), [firstBaseline.id, secondBaseline.id], "No quiet turn boundary")
            if tier != .full {
                XCTAssertEqual(transcript.turns[0], frozenFirst, "New work must not reopen a source-discarded turn")
            }
            let canonicalBeforeSave = transcript
            let sessionID = id(999)
            let session = AgentSession(
                id: sessionID, workspaceID: workspace.id, composeTabID: id(998), name: "Quiet W0",
                transcript: transcript, lastRunState: AgentSessionRunState.completed.rawValue
            )
            let url = try await service.saveAgentSession(session, for: workspace)
            let loaded = try await service.loadAgentSession(from: url)
            let restored = try XCTUnwrap(loaded.transcript)
            XCTAssertEqual(restored.turns.map(\.id), canonicalBeforeSave.turns.map(\.id))
            XCTAssertEqual(restored.turns[0].retentionTier, tier)
            XCTAssertEqual(restored.turns[1].retentionTier, .full)
            XCTAssertTrue(restored.turns[1].allActivities.contains { $0.quietCheckInWakeID == id(901) })
            let disk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual((disk["items"] as? [Any])?.count, 0, "No second persisted source array")

            let local = restored
            try assertLocal(local.turns[0], baseline: firstBaseline, tools: 12, tier: tier)
            try assertLocal(local.turns[1], baseline: secondBaseline, tools: 9, tier: .full)
            let localProjection = AgentTranscriptProjectionBuilder.build(from: local, excludingQuiet: true)
            let localRows = localProjection.workingRows + localProjection.archivedRows
            XCTAssertFalse(localRows.contains { $0.text.contains("Quiet closing") || $0.toolName == "self_noop" })
            let canonicalRows = AgentTranscriptIO.flattenFullTranscript(restored)
            XCTAssertTrue(canonicalRows.contains { $0.text == "Quiet closing 1100" })
            let audit = AgentTranscriptProjectionBuilder.build(from: restored)
            XCTAssertTrue(audit.workingRows.contains { $0.text == "Quiet closing 1100" }, "Default projection stays canonical")
            let handoff = try AgentTranscriptIO.buildHandoffTranscriptItems(from: restored, upToRowID: XCTUnwrap(secondQuiet.last?.id))
            XCTAssertTrue(handoff.contains { $0.text == "Quiet closing 1100" }, "Canonical handoff must not consume the local mask")
            if tier != .full {
                XCTAssertEqual(restored.turns[0].summary?.toolCount, 14, "Canonical audit was not filtered")
                XCTAssertEqual(restored.turns[0].quietLocal?.summary?.toolCount, 12)
            }
            let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: restored, workingItems: loaded.workingSourceItems(), terminalState: .completed
            )
            if tier != .full { XCTAssertEqual(rebuilt.turns[0], restored.turns[0]) }
            try assertLocal(rebuilt.turns[0], baseline: firstBaseline, tools: 12, tier: tier)
        }
    }

    func testBoundedMetadataMutationFoldsIntoNormalTerminalAndSavePaths() async throws {
        for mode in ["immediate", "deferred", "inactive", "save"] {
            var control: [String: Int] = [:]
            var controlSave: [String: Int] = [:]
            for stamps in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-w0-mutation-\(UUID())")
                defer { try? FileManager.default.removeItem(at: directory) }
                let service = AgentSessionDataService()
                let vm = AgentModeViewModel(
                    testWindowID: 1,
                    testWorkspacePath: directory.path,
                    codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) },
                    headlessProviderFactory: { _, _ in XCTFail("No provider in W0")
                        return AgentSessionLinkCapturingHeadlessProvider()
                    },
                    mcpServerEnabler: { false }
                )
                let tabID = UUID()
                let manager = AgentSessionLinkEndpointTestSupport.installWorkspace(on: vm, tabID: tabID, name: "W0 mutation")
                var workspace = try XCTUnwrap(manager.activeWorkspace)
                workspace.customStoragePath = directory
                manager.activeWorkspace = workspace
                var savedURL: URL?
                vm.test_setAgentSessionSaver { payload, workspace, count in
                    let url = try await service.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
                    savedURL = url
                    return url
                }
                let session = vm.session(for: tabID)
                session.hasLoadedPersistedState = true
                session.selectedAgent = .openCode
                _ = try XCTUnwrap(vm.test_installPersistentSessionBinding(sessionID: UUID(), on: session, updateWorkspaceMetadata: true))
                session.recordRestorationAuthoritative(.persistedPayloadApplied)
                session.installRunID(UUID())
                let ordinary = ordinaryRows(base: 0, toolCount: 9).map { $0.replacingID(UUID()) }
                let measuredTurnID = ordinary[0].id
                let ordinaryBaseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .idle).turns.first)
                session.setItemsSilently(ordinary, reason: .persistedSessionHydration)
                session.runState = .running
                _ = session.beginRunAttempt(source: "test.W0.metadata")
                vm.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(mode != "immediate")
                if mode == "inactive" { vm.test_setCurrentTabIDOverride(UUID()) }
                for var item in quietRows(base: 100, wakeID: id(900)) {
                    item.quietCheckInWakeID = nil
                    session.appendItem(item)
                }
                await vm.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)
                let range = (session.items.count - 4) ... (session.items.count - 1)
                let expectedIDs = range.map { session.items[$0].id }
                let metrics = QuietW0TraversalCounts()
                AgentTranscriptDebugInstrumentation.configure(.init(
                    summaryTraversalHandler: { value in
                        guard value.turnID == measuredTurnID else { return }
                        metrics.add(value.phase, value.activityCount)
                    },
                    refreshAttemptHandler: { value in
                        guard value.tabID == tabID else { return }
                        metrics.add("refreshes", 1)
                    }
                ))
                defer { AgentTranscriptDebugInstrumentation.reset()
                    session.saveDebounceTask?.cancel()
                }
                if stamps {
                    session.test_beforeQuietMetadataSeal = {
                        XCTAssertTrue(session.terminalCommitInProgress)
                        AgentTranscriptIO.test_installQuietLocalBaseline(ordinaryBaseline, in: &session.transcript)
                        let revision = session.sourceItemsRevision
                        let oldSaveToken = try! XCTUnwrap(vm.test_saveCommitToken(for: session, workspaceID: workspace.id))
                        XCTAssertTrue(vm.test_isSaveCommitTokenCurrent(oldSaveToken))
                        let activityAt = session.lastActivityAt
                        XCTAssertTrue(session.test_stampQuietMetadata(range: range, expectedIDs: expectedIDs, wakeID: self.id(900)))
                        XCTAssertEqual(session.sourceItemsRevision, revision + 1)
                        XCTAssertFalse(vm.test_isSaveCommitTokenCurrent(oldSaveToken), "Pre-stamp preparation cannot authorize the certified source revision")
                        XCTAssertEqual(session.lastActivityAt, activityAt)
                        XCTAssertEqual(session.test_quietMetadataVisitedItems, range.count * 2)
                    }
                }
                await vm.test_finishQuietFeasibilityRun(session)
                session.test_beforeQuietMetadataSeal = nil
                XCTAssertNotNil(session.runLifecycle.lastTerminalCommitRevision, "Real terminal owner must settle")
                let terminalMetrics = metrics.snapshot()
                if stamps {
                    for (phase, count) in terminalMetrics {
                        XCTAssertLessThanOrEqual(count, control[phase] ?? 0, "\(mode): no additional \(phase) traversal")
                    }
                    XCTAssertTrue(session.transcript.allActivities.contains { $0.quietCheckInWakeID == self.id(900) })
                    let rows = session.transcriptProjection.workingRows
                    XCTAssertFalse(rows.contains { $0.text.contains("Quiet closing") || $0.toolName == "self_noop" }, "Real terminal projection consumes the injected receipt")
                    XCTAssertTrue(rows.contains { $0.id == ordinaryBaseline.conclusionActivityID })
                } else { control = terminalMetrics }
                await vm.flushSave(for: tabID)
                let saveMetrics = metrics.snapshot().mapValues { $0 }.reduce(into: [String: Int]()) { result, entry in
                    result[entry.key] = entry.value - (terminalMetrics[entry.key] ?? 0)
                }
                if stamps {
                    for (phase, count) in saveMetrics {
                        XCTAssertLessThanOrEqual(count, controlSave[phase] ?? 0, "\(mode): no added save \(phase) traversal")
                    }
                } else { controlSave = saveMetrics }
                XCTAssertEqual(saveMetrics["refreshes", default: 0], 0, "Normal save reuses the current canonical snapshot")
                XCTAssertEqual(saveMetrics["turn-summary", default: 0], 0)
                XCTAssertEqual(saveMetrics["span-summary", default: 0], 0)
                let loaded = try await service.loadAgentSession(from: XCTUnwrap(savedURL))
                if stamps { XCTAssertTrue(loaded.transcript?.allActivities.contains { $0.quietCheckInWakeID == self.id(900) } == true) }
                print("QUIET_W0_G mode=\(mode) stamped=\(stamps) sourceRows=\(session.items.count) metadataVisits=\(session.test_quietMetadataVisitedItems) terminal=\(terminalMetrics) save=\(saveMetrics)")
            }
        }
    }

    /// Same existing projection/summary source passes, with local exclusion folded in.
    /// Synthetic dimensions establish operation structure, not representative runtime.
    func testLocalExclusionUsesExistingProjectionAndSummaryPasses() throws {
        for tools in [0, 12, 49, 98] {
            let ordinary = ordinaryRows(base: 0, toolCount: tools)
            let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .idle).turns.first)
            var transcript = AgentTranscriptIO.buildTranscript(from: ordinary + quietRows(base: 10000, wakeID: id(900)), terminalState: .completed)
            var visits: [String: Int] = [:]
            AgentTranscriptDebugInstrumentation.configure(.init(summaryTraversalHandler: { value in
                visits[value.phase, default: 0] += value.activityCount
            }))
            defer { AgentTranscriptDebugInstrumentation.reset() }
            _ = AgentTranscriptProjectionBuilder.build(from: transcript)
            let canonicalVisits = visits
            visits = [:]
            AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &transcript)
            let local = AgentTranscriptProjectionBuilder.build(from: transcript, excludingQuiet: true)
            for (phase, count) in visits {
                XCTAssertLessThanOrEqual(count, canonicalVisits[phase] ?? 0, "No extra source traversal for \(tools) tools: \(phase)")
            }
            XCTAssertFalse((local.workingRows + local.archivedRows).contains { $0.quietCheckInWakeID != nil })
            let localVisits = visits
            let expected = AgentTranscriptProjectionBuilder.build(from: .init(turns: [baseline]))
            XCTAssertEqual(local.workingBlocks.map(\.id), expected.workingBlocks.map(\.id))
            print("QUIET_W0_G_FOLDED tools=\(tools) sourceRows=\(transcript.allActivities.count) canonical=\(canonicalVisits) local=\(localVisits)")
        }
    }

    func testCompletedDisplayNeedsNoSeparateTerminalStateOrLastActivityBaseline() throws {
        let ordinary = ordinaryRows(base: 0, toolCount: 12)
        let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .idle).turns.first)
        for terminal in [AgentSessionRunState.completed, .failed, .idle] {
            var transcript = AgentTranscriptIO.buildTranscript(from: ordinary + quietRows(base: 1000, wakeID: id(900)), terminalState: terminal)
            AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &transcript)
            // Conflicting canonical dates and status remain audit data. Local rendering uses
            // the ordinary completion date; completedAt supplies the existing completion test.
            transcript.turns[0].lastActivityAt = Date(timeIntervalSince1970: 99999)
            try assertLocal(transcript.turns[0], baseline: baseline, tools: 12, tier: .full)
            XCTAssertEqual(transcript.turns[0].terminalState, terminal)
            XCTAssertEqual(transcript.turns[0].lastActivityAt, Date(timeIntervalSince1970: 99999))
        }
    }

    func testExistingTailOwnerNeedsNoDispatchTimeFrozenLimitOverride() throws {
        for tools in [0, 1, 7, 8, 9, 12] {
            let ordinary = ordinaryRows(base: 0, toolCount: tools)
            let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .idle).turns.first)
            for wakes in [1, 3, 9] {
                let quiet = (0 ..< wakes).flatMap { quietRows(base: 1000 + $0 * 10, wakeID: id(900 + $0)) }
                var transcript = AgentTranscriptIO.buildTranscript(from: ordinary + quiet, terminalState: .completed)
                AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &transcript)
                let actual = AgentTranscriptProjectionBuilder.build(from: transcript, excludingQuiet: true)
                let expected = AgentTranscriptProjectionBuilder.build(from: .init(turns: [baseline]))
                XCTAssertEqual(actual.workingBlocks.map(\.id), expected.workingBlocks.map(\.id), "tools=\(tools) wakes=\(wakes)")
                XCTAssertEqual(actual.workingRows.map(\.id), expected.workingRows.map(\.id))
            }
        }
    }

    func testRetainedBaselineFieldsHaveObservableConsumers() throws {
        let ordinary = ordinaryRows(base: 0, toolCount: 12)
        let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .idle).turns.first)
        var transcript = AgentTranscriptIO.buildTranscript(from: ordinary + quietRows(base: 1000, wakeID: id(900)) + ordinaryRows(base: 2000, toolCount: 8), terminalState: .completed)
        AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &transcript)
        transcript.turns[0].retentionTier = .condensed
        transcript = AgentTranscriptCompactor.compact(transcript)
        let retained = transcript.turns[0]
        try assertLocal(retained, baseline: baseline, tools: 12, tier: .condensed)
        let expected = AgentTranscriptProjectionBuilder.build(from: .init(turns: [retained]), excludingQuiet: true)
        let expectedConclusion = try XCTUnwrap(expected.workingBlocks.first { $0.kind == .conclusion })
        for field in ["conclusion", "completedAt", "summary", "span-summary"] {
            var omitted = retained
            switch field {
            case "conclusion": omitted.quietLocal?.conclusionActivityID = nil
            case "completedAt": omitted.quietLocal?.completedAt = nil
            case "summary": omitted.quietLocal?.summary = nil
            default: omitted.responseSpans[0].quietLocal = nil
            }
            let actual = AgentTranscriptProjectionBuilder.build(from: .init(turns: [omitted]), excludingQuiet: true)
            let conclusion = actual.workingBlocks.first { $0.kind == .conclusion }
            // Removing any remaining baseline component changes a user-observable anchor,
            // date, text or grouped count; no source-spelling/minimality oracle.
            XCTAssertTrue(
                conclusion?.primaryAnchor != expectedConclusion.primaryAnchor ||
                    conclusion?.rows.first?.timestamp != expectedConclusion.rows.first?.timestamp ||
                    conclusion?.rows.first?.text != expectedConclusion.rows.first?.text ||
                    actual.workingBlocks.first { $0.kind == .groupedHistory }?.groupedHistory?.summary != expected.workingBlocks.first { $0.kind == .groupedHistory }?.groupedHistory?.summary,
                field
            )
        }
    }

    /// Numeric-only workload diagnostics, not an owner-bounded worst case or a timing
    /// acceptance test. 3436 provider turns is the supplied session total, NOT the count
    /// of canonical user anchors. 98 = supplied max proxy 49 with an explicit 2x margin.
    func testNumericRepresentativeSuffixGrowthDiagnostic() throws {
        // The bounded run was stopped after N=64 at ~14.9s/refresh. Larger N=512/3436
        // remains unmeasured, not a passing scale gate. Match existing scale-test opt-in
        // so normal suite execution cannot silently resume this unbounded diagnostic.
        guard ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "1" else {
            throw XCTSkip("Long W0 growth diagnostic requires an explicitly budgeted scale run; representative acceptance remains open")
        }
        var maximumMS = 0.0
        for providerTurns in [1, 8, 64, 512, 3436] {
            let proxyPerProviderTurn = 98
            let toolsPerProviderTurn = proxyPerProviderTurn - 1
            var source = [row(0, kind: .user, text: "One cumulative user anchor")]
            for providerTurn in 0 ..< providerTurns {
                let base = (providerTurn + 1) * 1000
                // 97 tool calls + 1 assistant block = 98 proxy activities. Include actual
                // result rows too: 195 source activities/provider turn. This is conservative
                // placement/max occupancy, not a claim that the sampled turns all hit max.
                source += ordinaryRows(base: base, toolCount: toolsPerProviderTurn).dropFirst().prefix(toolsPerProviderTurn * 2)
                source.append(row(base + 900, kind: .assistant, text: "Ordinary provider completion"))
            }
            let baselineTranscript = AgentTranscriptIO.buildTranscript(from: source, terminalState: .idle)
            let baseline = try XCTUnwrap(baselineTranscript.turns.first)
            XCTAssertEqual(baselineTranscript.turns.count, 1)
            XCTAssertEqual(baselineTranscript.turns[0].retentionTier, .full)
            XCTAssertEqual(baselineTranscript.turns[0].allActivities.count, providerTurns * 195, "Newest full turn has no activity cap")
            let quiet = quietRows(base: (providerTurns + 1) * 1000, wakeID: id(900))
            var controlCounts: [String: Int] = [:]
            var measuredTimes: [Double] = []
            for stamped in [false, true] {
                var existing = baselineTranscript
                if stamped { AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &existing) }
                let appended = quiet.map { item in
                    var item = item
                    if !stamped { item.quietCheckInWakeID = nil }
                    return item
                }
                var counts: [String: Int] = [:]
                AgentTranscriptDebugInstrumentation.configure(.init(summaryTraversalHandler: { value in
                    if value.turnID == baseline.id { counts[value.phase, default: 0] += value.activityCount }
                }))
                let start = Date.timeIntervalSinceReferenceDate
                let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                    existingTranscript: existing, workingItems: source + appended,
                    earliestChangedIndex: source.count, terminalState: .completed
                )
                let projection = AgentTranscriptProjectionBuilder.build(from: rebuilt, excludingQuiet: stamped)
                let elapsedMS = (Date.timeIntervalSinceReferenceDate - start) * 1000
                AgentTranscriptDebugInstrumentation.reset()
                measuredTimes.append(elapsedMS)
                maximumMS = max(maximumMS, elapsedMS)
                XCTAssertEqual(rebuilt.turns.count, 1)
                XCTAssertEqual(rebuilt.turns[0].allActivities.count, providerTurns * 195 + 4)
                if stamped {
                    for (phase, count) in counts {
                        XCTAssertLessThanOrEqual(count, controlCounts[phase] ?? 0, phase)
                    }
                    XCTAssertFalse(projection.workingRows.contains { $0.quietCheckInWakeID != nil })
                } else { controlCounts = counts }
                print("QUIET_W0_NUMERIC providerTurns=\(providerTurns) canonicalTurns=1 proxyPerProviderTurn=98 sourceActivities=\(providerTurns * 195 + 4) stamped=\(stamped) elapsedMS=\(elapsedMS) passes=\(counts)")
            }
            XCTAssertEqual(measuredTimes.count, 2)
        }
        // A proposed diagnostic envelope derived from the largest observed sample, with
        // 100% extra time for scheduler/allocator variability; not a new product limit or
        // an independently validated performance acceptance threshold.
        print("QUIET_W0_NUMERIC_ENVELOPE measuredMaximumMS=\(maximumMS) proposedRepeatBudgetMS=\(maximumMS * 2) margin=100percent finiteOwnerSuffixBound=none")
    }

    func testActiveLocalViewCannotCachePreSealRowsAsCompleted() throws {
        let ordinary = ordinaryRows(base: 0, toolCount: 12)
        let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .idle).turns.first)
        let first = quietRows(base: 1000, wakeID: id(900))
        let second = quietRows(base: 2000, wakeID: id(901))
        let unsealed = second.map { item in
            var item = item
            item.quietCheckInWakeID = nil
            return item
        }
        var active = AgentTranscriptIO.buildTranscript(from: ordinary + first + unsealed, terminalState: .running)
        AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &active)
        let before = AgentTranscriptProjectionBuilder.buildWithCaches(from: active, turnCaches: [:], excludingQuiet: true)
        XCTAssertNil(before.updatedTurnCaches[baseline.id], "A previous ordinary completion cannot certify current active rows/cache currency")
        XCTAssertTrue(before.projection.workingRows.contains { $0.text == "Quiet closing 2000" })
        var completed = AgentTranscriptIO.buildTranscript(from: ordinary + first + second, terminalState: .completed)
        AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &completed)
        let after = AgentTranscriptProjectionBuilder.buildWithCaches(from: completed, turnCaches: before.updatedTurnCaches, excludingQuiet: true)
        XCTAssertFalse(after.projection.workingRows.contains { $0.quietCheckInWakeID != nil })
        XCTAssertTrue(after.projection.workingRows.contains { $0.id == baseline.conclusionActivityID })
        let audit = AgentTranscriptProjectionBuilder.buildWithCaches(from: completed, turnCaches: after.updatedTurnCaches)
        XCTAssertTrue(audit.projection.workingRows.contains { $0.text == "Quiet closing 2000" }, "A local cache cannot be reused for canonical audit/export")
    }

    func testW1AtomicMembershipAndPreStampCheckpointFailVisible() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-w1-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(name: "Quiet proof", repoPaths: [], customStoragePath: directory)
        let service = AgentSessionDataService()
        let session = AgentTabSession(tabID: id(999))
        let ordinary = ordinaryRows(base: 0, toolCount: 2)
        session.setItemsSilently(ordinary, reason: .persistedSessionHydration)
        session.transcript = AgentTranscriptIO.buildTranscript(from: session.items, terminalState: .completed)
        let turn = try XCTUnwrap(session.transcript.turns.last)
        let baseline = AgentTranscriptQuietLocalTurn(summary: nil, conclusionActivityID: turn.conclusionActivityID, completedAt: turn.completedAt)
        let quiet = quietRows(base: 100, wakeID: id(900)).map { item in
            var item = item
            item.quietCheckInWakeID = nil
            return item
        }
        session.appendItem(quiet[0])
        session.appendItem(row(150, kind: .system, text: "Foreign host marker"))
        quiet.dropFirst().forEach(session.appendItem)
        session.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: session.transcript, workingItems: session.items, terminalState: .completed
        )
        let checkpoint = AgentSession(id: id(990), workspaceID: workspace.id, composeTabID: session.tabID, name: "Checkpoint", transcript: session.transcript)
        let url = try await service.saveAgentSession(checkpoint, for: workspace)
        let loadedCheckpoint = try await service.loadAgentSession(from: url)
        let before = try XCTUnwrap(loadedCheckpoint.transcript)
        XCTAssertTrue(AgentTranscriptProjectionBuilder.build(from: before, excludingQuiet: true).workingRows.contains { $0.toolName == "self_noop" })
        XCTAssertTrue(before.allActivities.allSatisfy { $0.quietCheckInWakeID == nil })

        let members = session.items.enumerated().filter { quiet.map(\.id).contains($0.element.id) }.map { (index: $0.offset, id: $0.element.id) }
        let revision = session.sourceItemsRevision
        let activityAt = session.lastActivityAt
        let stampWakeID = id(900)
        var publishedStampCounts: [Int] = []
        let subscription = session.$items.dropFirst().sink { source in
            publishedStampCounts.append(source.count { $0.quietCheckInWakeID == stampWakeID })
        }
        defer { subscription.cancel() }
        var callbacks = 0
        session.onSourceItemsChanged = { source, mutation in
            callbacks += 1
            XCTAssertEqual(mutation.changedIndexRange, members.first!.index ... members.last!.index)
            XCTAssertFalse(mutation.isStructural)
            XCTAssertEqual(source.sourceItemsRevision, revision + 1)
            XCTAssertEqual(source.transcript.turns.last?.quietLocal, baseline)
            XCTAssertEqual(source.items.filter { $0.quietCheckInWakeID == self.id(900) }.map(\.id), quiet.map(\.id))
            XCTAssertNil(source.derivedTranscriptSyncState)
        }
        for bad in [members + [members[0]], [(index: members[0].index, id: id(9999))], [(index: 0, id: ordinary[0].id)]] {
            XCTAssertFalse(session.stampQuietCheckInMembers(bad, wakeID: id(900), turnID: turn.id, baseline: baseline, expectedSourceRevision: revision))
            XCTAssertTrue(session.items.allSatisfy { $0.quietCheckInWakeID == nil })
            XCTAssertNil(session.transcript.turns.last?.quietLocal)
        }
        XCTAssertFalse(session.stampQuietCheckInMembers(members, wakeID: id(900), turnID: turn.id, baseline: baseline, expectedSourceRevision: revision - 1))
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(session.stampQuietCheckInMembers(members, wakeID: id(900), turnID: turn.id, baseline: baseline, expectedSourceRevision: revision))
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(publishedStampCounts, [members.count], "Subscribers must never receive a half-stamped source batch")
        XCTAssertEqual(session.lastActivityAt, activityAt)
        session.onSourceItemsChanged = nil
        session.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: session.transcript, workingItems: session.items, earliestChangedIndex: members[0].index, terminalState: .completed)
        var certified = checkpoint
        certified.transcript = session.transcript
        let certifiedURL = try await service.saveAgentSession(certified, for: workspace)
        let loadedCertified = try await service.loadAgentSession(from: certifiedURL)
        let restored = try XCTUnwrap(loadedCertified.transcript)
        XCTAssertEqual(restored.allActivities.filter { $0.quietCheckInWakeID == id(900) }.map(\.id), quiet.map(\.id))
        let local = AgentTranscriptProjectionBuilder.build(from: restored, excludingQuiet: true)
        XCTAssertFalse(local.workingRows.contains { $0.toolName == "self_noop" || $0.text == "Quiet closing 100" })
        XCTAssertTrue(local.workingRows.contains { $0.text == "Foreign host marker" }, "Noncontiguous membership never swallows a foreign marker")
        XCTAssertEqual(AgentTranscriptIO.latestAssistantPreviewText(from: restored), "Quiet closing 100")
        XCTAssertTrue(try AgentTranscriptIO.buildHandoffTranscriptItems(from: restored, upToRowID: XCTUnwrap(quiet.last?.id)).contains { $0.text == "Quiet closing 100" })
    }

    func testW1SummaryOnlyCompactionPreservesCertifiedResultAndLocalQuietness() throws {
        for path in ["single-result", "current-source-alignment"] {
            let session = AgentTabSession(tabID: id(999))
            let ordinary = ordinaryRows(base: 0, toolCount: 2)
            var quiet = quietRows(base: 100, wakeID: id(900))
            let raw = #"{"status":"success","output":"Synthetic raw tool payload that must not reappear as an audit card","exit_code":0}"#
            quiet[0].toolName = "read_file"
            quiet[1].toolName = "read_file"
            quiet[1].text = raw
            quiet[1].toolResultJSON = raw
            session.setItemsSilently(ordinary + quiet, reason: .persistedSessionHydration)
            session.transcript = AgentTranscriptIO.buildTranscript(from: session.items, terminalState: .completed)
            let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .completed).turns.first)
            AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &session.transcript)
            let resultIndex = ordinary.count + 1
            let resultID = quiet[1].id
            let payloadRevision = try XCTUnwrap(session.ephemeralToolResultPayloadRevisionByItemID[resultID])
            let sourceRevision = session.sourceItemsRevision
            let sanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: session.items[resultIndex]))
            XCTAssertTrue(sanitized.shouldRetainEphemeralRawPayload, "Fixture must exercise real summary-only compaction")
            XCTAssertNotEqual(sanitized.resultJSON, raw)
            let before = AgentTranscriptProjectionBuilder.build(from: session.transcript, excludingQuiet: true)
            XCTAssertFalse(before.workingRows.contains { $0.id == resultID })

            if path == "single-result" {
                var compacted = session.items[resultIndex]
                compacted.text = sanitized.text
                compacted.toolResultJSON = sanitized.resultJSON
                compacted.toolIsError = sanitized.toolIsError
                XCTAssertTrue(session.replaceItemSilentlyForRetentionCompaction(at: resultIndex, with: compacted, retainedRawPayload: raw))
            } else {
                session.compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap()
            }

            XCTAssertEqual(session.sourceItemsRevision, sourceRevision + 1, path)
            XCTAssertEqual(session.items[resultIndex].toolResultJSON, sanitized.resultJSON, path)
            XCTAssertTrue(try AgentTranscriptToolNormalizer.isSummaryOnly(raw: XCTUnwrap(session.items[resultIndex].toolResultJSON)), path)
            XCTAssertEqual(session.items[resultIndex].quietCheckInWakeID, id(900), path)
            XCTAssertEqual(session.ephemeralToolResultPayloadByItemID[resultID], raw, path)
            XCTAssertEqual(session.ephemeralToolResultPayloadRevisionByItemID[resultID], payloadRevision, path)
            let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: session.transcript, workingItems: session.items,
                earliestChangedIndex: resultIndex, terminalState: .completed
            )
            let canonicalResult = try XCTUnwrap(rebuilt.allActivities.first { $0.id == resultID })
            XCTAssertEqual(canonicalResult.quietCheckInWakeID, id(900), path)
            let local = AgentTranscriptProjectionBuilder.build(from: rebuilt, excludingQuiet: true)
            XCTAssertFalse(local.workingRows.contains { $0.id == resultID }, path)
            XCTAssertTrue(local.workingBlocks.allSatisfy { !Set($0.activityIDs).contains(resultID) }, "Certified audit card must not reappear: \(path)")
            XCTAssertEqual(local.workingRows.map(\.id), before.workingRows.map(\.id), path)
        }
    }

    func testW1ChangedSourceInvalidatesButRetentionCopiesPreserveMembership() throws {
        for operation in ["replace", "mutate", "last", "batch", "direct", "repair"] {
            let session = AgentTabSession(tabID: id(999))
            let ordinary = ordinaryRows(base: 0, toolCount: 2)
            let quiet = quietRows(base: 100, wakeID: id(900))
            session.setItemsSilently(ordinary + quiet, reason: .persistedSessionHydration)
            session.transcript = AgentTranscriptIO.buildTranscript(from: session.items, terminalState: .completed)
            let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .completed).turns.first)
            AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &session.transcript)
            let index = session.items.count - 1
            let original = session.items[index]
            session.setItemsSilentlyForRetentionCompaction(session.items)
            XCTAssertEqual(session.items[index].quietCheckInWakeID, id(900))
            var changed = original
            changed.text = String(repeating: "Later ordinary material. ", count: 12)
            switch operation {
            case "replace": session.replaceItem(at: index, with: changed)
            case "mutate": session.mutateItem(at: index) { $0.text = changed.text }
            case "last": session.updateLastItem { $0.text = changed.text }
            case "batch": session.mutateItemsBatch { $0[index] = changed }
            case "direct": session.items[index] = changed
            default: session.setItemsSilently(Array(session.items.dropLast()) + [changed], reason: .pendingToolFinalizationRepair)
            }
            XCTAssertNil(session.items[index].quietCheckInWakeID, operation)
            XCTAssertEqual(session.items[index - 1].quietCheckInWakeID, id(900), "Unchanged sibling remains certified")
            let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: session.transcript, workingItems: session.items, earliestChangedIndex: index, terminalState: .completed)
            let local = AgentTranscriptProjectionBuilder.build(from: rebuilt, excludingQuiet: true)
            XCTAssertTrue(local.workingRows.contains { $0.id == original.id && $0.text == changed.text }, operation)
            XCTAssertFalse(local.workingRows.contains { $0.toolName == "self_noop" }, operation)
            XCTAssertEqual(rebuilt.turns.last?.quietLocal?.conclusionActivityID, original.id)
        }
        let stamped = quietRows(base: 100, wakeID: id(900))[0]
        XCTAssertEqual(stamped.replacingID(stamped.id).quietCheckInWakeID, id(900))
        XCTAssertNil(stamped.replacingID(id(9999)).quietCheckInWakeID)
        var reused = stamped
        reused.text = "Reused identity"
        let repaired = AgentSourceItemIDRepair.repairDuplicateIDs(in: [stamped, reused]).items
        XCTAssertEqual(repaired[0].quietCheckInWakeID, id(900))
        XCTAssertNil(repaired[1].quietCheckInWakeID)
    }

    func testW1ChangedHiddenRowEvictsExactTurnCacheEvenWhenValidationTokenIsUnchanged() throws {
        for operation in ["mutate", "batch-rekey", "direct-rekey"] {
            let session = AgentTabSession(tabID: id(999))
            let ordinary = ordinaryRows(base: 0, toolCount: 2)
            let later = row(200, kind: .assistant, text: String(repeating: "Later ordinary conclusion. ", count: 12))
            let rows = ordinary + quietRows(base: 100, wakeID: id(900)) + [later]
            session.setItemsSilently(rows, reason: .persistedSessionHydration)
            session.transcript = AgentTranscriptIO.buildTranscript(from: rows, terminalState: .completed)
            let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary + [later], terminalState: .completed).turns.first)
            AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &session.transcript)
            let before = AgentTranscriptProjectionBuilder.buildWithCaches(from: session.transcript, turnCaches: [:], excludingQuiet: true)
            session.fullTranscriptProjection = before.projection
            session.baseTranscriptProjection = before.projection
            session.turnProjectionCaches = before.updatedTurnCaches
            let cached = try XCTUnwrap(session.turnProjectionCaches[baseline.id])
            let changedIndex = try XCTUnwrap(session.items.firstIndex { $0.id == id(102) })
            var changed = session.items[changedIndex]
            changed.text = "New ordinary reasoning"
            switch operation {
            case "mutate": session.mutateItem(at: changedIndex) { $0 = changed }
            case "batch-rekey": session.mutateItemsBatch { $0[changedIndex] = changed.replacingID(id(9999)) }
            default: session.items[changedIndex] = changed.replacingID(id(9999))
            }
            XCTAssertNil(session.items[changedIndex].quietCheckInWakeID, operation)
            XCTAssertNil(session.turnProjectionCaches[baseline.id], operation)
            let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: session.transcript, workingItems: session.items, earliestChangedIndex: changedIndex, terminalState: .completed)
            XCTAssertEqual(cached.token, try AgentTranscriptProjectionBuilder.validationToken(for: XCTUnwrap(rebuilt.turns.first), excludingQuiet: true), "The ordinary cache token alone cannot detect changed hidden content")
            let after = AgentTranscriptProjectionBuilder.buildWithCaches(from: rebuilt, turnCaches: session.turnProjectionCaches, excludingQuiet: true)
            XCTAssertTrue(after.projection.workingRows.contains { $0.text == "New ordinary reasoning" }, operation)
            XCTAssertFalse(before.projection.workingRows.contains { $0.id == id(102) })
        }
    }

    func testW1OrdinaryWritesCannotRestoreRevokedCertificates() throws {
        for operation in ["replace", "mutate", "last", "batch", "direct", "repair", "append", "batch-reinsert", "direct-reinsert"] {
            let session = AgentTabSession(tabID: id(999))
            let ordinary = ordinaryRows(base: 0, toolCount: 2)
            session.setItemsSilently(ordinary + quietRows(base: 100, wakeID: id(900)), reason: .persistedSessionHydration)
            session.transcript = AgentTranscriptIO.buildTranscript(from: session.items, terminalState: .completed)
            let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .completed).turns.first)
            AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &session.transcript)
            let index = session.items.count - 1
            var captured = session.items[index]
            session.mutateItem(at: index) { $0.text = "First ordinary edit" }
            XCTAssertNil(session.items[index].quietCheckInWakeID)
            captured.text = String(repeating: "Changed captured ordinary content. ", count: 12)
            switch operation {
            case "replace": session.replaceItem(at: index, with: captured)
            case "mutate": session.mutateItem(at: index) { $0 = captured }
            case "last": session.updateLastItem { $0 = captured }
            case "batch": session.mutateItemsBatch { $0[index] = captured }
            case "direct": session.items[index] = captured
            case "repair": session.setItemsSilently(Array(session.items.dropLast()) + [captured], reason: .pendingToolFinalizationRepair)
            case "append":
                session.removeItem(at: index)
                session.appendItem(captured)
            case "batch-reinsert":
                session.removeItem(at: index)
                session.mutateItemsBatch { $0.append(captured) }
            default:
                session.removeItem(at: index)
                session.items.append(captured)
            }
            XCTAssertNil(session.items.last?.quietCheckInWakeID, operation)
            XCTAssertEqual(session.items[index - 1].quietCheckInWakeID, id(900), "Unchanged sibling stays certified")
            let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: session.transcript, workingItems: session.items, terminalState: .completed)
            let restored = try JSONDecoder().decode(AgentTranscript.self, from: JSONEncoder().encode(rebuilt))
            for transcript in [rebuilt, restored] {
                let local = AgentTranscriptProjectionBuilder.build(from: transcript, excludingQuiet: true)
                XCTAssertTrue(local.workingRows.contains { $0.id == captured.id && $0.text == captured.text }, operation)
                XCTAssertFalse(local.workingRows.contains { $0.toolName == "self_noop" }, operation)
            }
        }
    }

    func testW1SuccessfulStampEvictsUnchangedTokenTurnCache() throws {
        let session = AgentTabSession(tabID: id(999))
        let ordinary = ordinaryRows(base: 0, toolCount: 2)
        let later = row(300, kind: .assistant, text: String(repeating: "Later ordinary conclusion. ", count: 12))
        let unstamped = quietRows(base: 200, wakeID: id(901)).map { item in
            var item = item
            item.quietCheckInWakeID = nil
            return item
        }
        session.setItemsSilently(ordinary + quietRows(base: 100, wakeID: id(900)) + unstamped + [later], reason: .persistedSessionHydration)
        session.transcript = AgentTranscriptIO.buildTranscript(from: session.items, terminalState: .completed)
        let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary + [later], terminalState: .completed).turns.first)
        AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &session.transcript)
        let before = AgentTranscriptProjectionBuilder.buildWithCaches(from: session.transcript, turnCaches: [:], excludingQuiet: true)
        session.turnProjectionCaches = before.updatedTurnCaches
        let cached = try XCTUnwrap(session.turnProjectionCaches[baseline.id])
        let members = session.items.enumerated().filter { unstamped.map(\.id).contains($0.element.id) }.map { (index: $0.offset, id: $0.element.id) }
        XCTAssertTrue(before.projection.workingRows.contains { $0.id == id(203) })
        XCTAssertTrue(try session.stampQuietCheckInMembers(members, wakeID: id(901), turnID: baseline.id, baseline: XCTUnwrap(session.transcript.turns.last?.quietLocal), expectedSourceRevision: session.sourceItemsRevision))
        XCTAssertNil(session.turnProjectionCaches[baseline.id])
        let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: session.transcript, workingItems: session.items, terminalState: .completed)
        XCTAssertEqual(cached.token, try AgentTranscriptProjectionBuilder.validationToken(for: XCTUnwrap(rebuilt.turns.last), excludingQuiet: true), "This schedule must not rely on formatter-token changes")
        let after = AgentTranscriptProjectionBuilder.buildWithCaches(from: rebuilt, turnCaches: session.turnProjectionCaches, excludingQuiet: true)
        XCTAssertFalse(after.projection.workingRows.contains { $0.text.contains("Quiet closing") || $0.toolName == "self_noop" })
        let restored = try JSONDecoder().decode(AgentTranscript.self, from: JSONEncoder().encode(rebuilt))
        XCTAssertEqual(after.projection, AgentTranscriptProjectionBuilder.build(from: restored, excludingQuiet: true))
        XCTAssertEqual(AgentTranscriptProjectionBuilder.build(from: rebuilt).workingRows.map(\.id), AgentTranscriptProjectionBuilder.build(from: session.transcript).workingRows.map(\.id))
    }

    func testW2QualificationStampSeamRequiresUnchangedExaminedRows() throws {
        for changeBetweenExaminationAndStamp in [false, true] {
            let session = AgentTabSession(tabID: id(999))
            let ordinary = ordinaryRows(base: 0, toolCount: 2)
            session.setItemsSilently(ordinary, reason: .persistedSessionHydration)
            session.transcript = AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .completed)
            let turn = try XCTUnwrap(session.transcript.turns.last)
            let baseline = AgentTranscriptQuietLocalTurn(summary: nil, conclusionActivityID: turn.conclusionActivityID, completedAt: turn.completedAt)
            let members = quietRows(base: 100, wakeID: id(900)).map { item in
                var item = item
                item.quietCheckInWakeID = nil
                return item
            }
            members.forEach(session.appendItem)
            let examined = Array(session.items.suffix(members.count))
            let indices = Array((session.items.count - members.count) ..< session.items.count)
            if changeBetweenExaminationAndStamp {
                try session.mutateItem(at: XCTUnwrap(indices.last)) { $0.text = "Changed after qualification" }
            }
            // W2 proves the W1 caller obligation at the seam, not W3 production stamping.
            // A fresh revision and unchanged IDs alone cannot authorize an older examination.
            let unchanged = zip(indices, examined).allSatisfy { session.items[$0.0] == $0.1 }
            let stamped = unchanged && session.stampQuietCheckInMembers(
                zip(indices, examined).map { (index: $0.0, id: $0.1.id) }, wakeID: id(900),
                turnID: turn.id, baseline: baseline, expectedSourceRevision: session.sourceItemsRevision
            )
            XCTAssertEqual(stamped, !changeBetweenExaminationAndStamp)
            XCTAssertEqual(session.items.count { $0.quietCheckInWakeID != nil }, stamped ? members.count : 0)
        }
    }

    func testW2MaskChangeCallbackDoesNotSynchronouslyRebuildTurnCaches() throws {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
        let host = harness.host
        let session = try harness.makeBoundSession(agent: .claudeCode)
        XCTAssertEqual(host.currentTabID, session.tabID)
        session.setItemsSilently(ordinaryRows(base: 0, toolCount: 2), reason: .persistedSessionHydration)
        host.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        session.turnProjectionCaches.removeAll()
        var projectionBuilds = 0
        var rebuilds = 0
        AgentTranscriptDebugInstrumentation.configure(.init(
            rebuildHandler: { _ in rebuilds += 1 },
            projectionBuildHandler: { _ in projectionBuilds += 1 }
        ))
        defer { AgentTranscriptDebugInstrumentation.reset() }
        let revision = session.sourceItemsRevision
        session.onQuietDisplayMaskChanged?(session)
        XCTAssertEqual(projectionBuilds, 0)
        XCTAssertEqual(rebuilds, 0)
        XCTAssertEqual(session.sourceItemsRevision, revision)
    }

    func testW1StampRejectsUnprojectedNewUserTurn() throws {
        let session = AgentTabSession(tabID: id(999))
        session.setItemsSilently(ordinaryRows(base: 0, toolCount: 2), reason: .persistedSessionHydration)
        session.transcript = AgentTranscriptIO.buildTranscript(from: session.items, terminalState: .completed)
        let turn = try XCTUnwrap(session.transcript.turns.last)
        let baseline = AgentTranscriptQuietLocalTurn(summary: nil, conclusionActivityID: turn.conclusionActivityID, completedAt: turn.completedAt)
        session.appendItem(row(200, kind: .user, text: "New user turn before derived refresh"))
        let start = session.items.count
        for var item in quietRows(base: 300, wakeID: id(900)) {
            item.quietCheckInWakeID = nil
            session.appendItem(item)
        }
        let source = session.items
        let revision = session.sourceItemsRevision
        var callbacks = 0
        session.onSourceItemsChanged = { _, _ in callbacks += 1 }
        XCTAssertFalse(session.stampQuietCheckInMembers((start ..< session.items.count).map { (index: $0, id: session.items[$0].id) }, wakeID: id(900), turnID: turn.id, baseline: baseline, expectedSourceRevision: revision))
        XCTAssertEqual(session.items, source)
        XCTAssertEqual(session.sourceItemsRevision, revision)
        XCTAssertNil(session.transcript.turns.last?.quietLocal)
        XCTAssertEqual(callbacks, 0)
    }

    func testW1FullRebuildCapturesLocalSummariesBeforeNaturalDownshift() throws {
        let session = AgentTabSession(tabID: id(999))
        let ordinary = ordinaryRows(base: 0, toolCount: 12)
        let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .completed).turns.first)
        session.setItemsSilently(ordinary + quietRows(base: 100, wakeID: id(900)), reason: .persistedSessionHydration)
        session.transcript = AgentTranscriptIO.buildTranscript(from: session.items, terminalState: .completed)
        AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &session.transcript)
        // Exceed the real compactor budget in one full-source rebuild, not by assigning tiers.
        for turn in 1 ... 40 {
            ordinaryRows(base: turn * 1000, toolCount: turn == 40 ? 9 : 0).forEach(session.appendItem)
        }
        let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: session.transcript, workingItems: session.items, terminalState: .completed)
        let retained = try XCTUnwrap(rebuilt.turns.first)
        XCTAssertNotEqual(retained.retentionTier, .full)
        XCTAssertEqual(rebuilt.turns.last?.retentionTier, .full)
        XCTAssertNotNil(retained.quietLocal?.summary)
        try assertLocal(retained, baseline: baseline, tools: 12, tier: retained.retentionTier)
        let restored = try JSONDecoder().decode(AgentTranscript.self, from: JSONEncoder().encode(rebuilt))
        try assertLocal(XCTUnwrap(restored.turns.first), baseline: baseline, tools: 12, tier: retained.retentionTier)
        let audit = AgentTranscriptProjectionBuilder.build(from: restored)
        XCTAssertTrue((audit.workingRows + audit.archivedRows).contains { $0.text == "Quiet closing 100" })
    }

    func testW1NormalRebuildComposesOrdinarySuffixAndQuietAcrossEveryRetentionTier() async throws {
        for tier in [AgentTranscriptRetentionTier.full, .condensed, .summary, .archived] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-w1-tier-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = WorkspaceModel(name: "Retained proof", repoPaths: [], customStoragePath: directory)
            let service = AgentSessionDataService()
            let session = AgentTabSession(tabID: id(999))
            let firstOrdinary = ordinaryRows(base: 0, toolCount: 12)
            let firstBaseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: firstOrdinary, terminalState: .completed).turns.first)
            session.setItemsSilently(firstOrdinary, reason: .persistedSessionHydration)
            session.transcript = AgentTranscriptIO.buildTranscript(from: session.items, terminalState: .completed)
            func appendCertified(_ rows: [AgentChatItem], wakeID: UUID) throws {
                let turn = try XCTUnwrap(session.transcript.turns.last)
                let baseline = turn.quietLocal ?? AgentTranscriptQuietLocalTurn(summary: nil, conclusionActivityID: turn.conclusionActivityID, completedAt: turn.completedAt)
                let start = session.items.count
                for var row in rows {
                    row.quietCheckInWakeID = nil
                    session.appendItem(row)
                }
                XCTAssertTrue(session.stampQuietCheckInMembers((start ..< session.items.count).map { (index: $0, id: session.items[$0].id) }, wakeID: wakeID, turnID: turn.id, baseline: baseline, expectedSourceRevision: session.sourceItemsRevision))
                session.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: session.transcript, workingItems: session.items, earliestChangedIndex: start, terminalState: .completed)
            }
            try appendCertified(quietRows(base: 100, wakeID: id(900)), wakeID: id(900))
            // The actual newest turn stays full. Only old, tool-tail-eligible history trims.
            let secondOrdinary = ordinaryRows(base: 1000, toolCount: 9)
            secondOrdinary.forEach(session.appendItem)
            session.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: session.transcript, workingItems: session.items, terminalState: .completed)
            session.transcript.turns[0].retentionTier = tier
            session.transcript = AgentTranscriptCompactor.compact(session.transcript)
            let frozen = session.transcript.turns[0]
            session.setItemsSilentlyForRetentionCompaction(AgentTranscriptIO.workingSourceItems(from: session.transcript))
            session.appendItem(row(1100, kind: .assistant, text: String(repeating: "New ordinary suffix conclusion. ", count: 12)))
            session.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: session.transcript, workingItems: session.items, earliestChangedIndex: session.items.count - 1, terminalState: .completed)
            let secondBaseline = try XCTUnwrap(session.transcript.turns.last)
            try appendCertified(quietRows(base: 1200, wakeID: id(901)), wakeID: id(901))
            // Force the full fallback as well as the incremental path, then restore flatten/rebuild.
            session.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: session.transcript, workingItems: session.items, terminalState: .completed)
            let saved = AgentSession(id: id(998), workspaceID: workspace.id, composeTabID: session.tabID, name: "Retained", transcript: session.transcript)
            let url = try await service.saveAgentSession(saved, for: workspace)
            let loaded = try await service.loadAgentSession(from: url)
            let restored = try XCTUnwrap(loaded.transcript)
            let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: restored, workingItems: loaded.workingSourceItems(), terminalState: .completed)
            XCTAssertEqual(rebuilt.turns.last?.retentionTier, .full)
            if tier != .full { XCTAssertEqual(rebuilt.turns[0], frozen) }
            try assertLocal(rebuilt.turns[0], baseline: firstBaseline, tools: 12, tier: tier)
            let local = AgentTranscriptProjectionBuilder.build(from: rebuilt, excludingQuiet: true)
            XCTAssertTrue(local.workingRows.contains { $0.id == secondBaseline.conclusionActivityID && $0.text == String(repeating: "New ordinary suffix conclusion. ", count: 12) })
            XCTAssertFalse((local.workingRows + local.archivedRows).contains { $0.toolName == "self_noop" || $0.text.contains("Quiet closing") })
            XCTAssertEqual(rebuilt.turns.last?.quietLocal?.completedAt, secondBaseline.completedAt)
            XCTAssertEqual(AgentTranscriptIO.latestAssistantPreviewText(from: rebuilt), "Quiet closing 1200")
            // Continued ordinary work on the SAME certified full suffix updates, not freezes,
            // its formatter inputs without a test-only baseline reset.
            session.transcript = rebuilt
            session.setItemsSilently(loaded.workingSourceItems(), reason: .persistedSessionHydration)
            session.appendItem(row(1300, kind: .assistant, text: String(repeating: "Still later ordinary conclusion. ", count: 12)))
            session.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(existingTranscript: rebuilt, workingItems: session.items, earliestChangedIndex: session.items.count - 1, terminalState: .completed)
            try appendCertified(quietRows(base: 1400, wakeID: id(902)), wakeID: id(902))
            let finalLocal = AgentTranscriptProjectionBuilder.build(from: session.transcript, excludingQuiet: true)
            XCTAssertTrue(finalLocal.workingRows.contains { $0.text == String(repeating: "Still later ordinary conclusion. ", count: 12) })
            XCTAssertFalse(finalLocal.workingRows.contains { $0.text.contains("Quiet closing") })
        }
    }

    func testW1MalformedOrMissingDisplayProofNeverReconstructsFromCallOrText() throws {
        let ordinary = ordinaryRows(base: 0, toolCount: 12)
        let baseline = try XCTUnwrap(AgentTranscriptIO.buildTranscript(from: ordinary, terminalState: .completed).turns.first)
        var transcript = AgentTranscriptIO.buildTranscript(from: ordinary + quietRows(base: 100, wakeID: id(900)) + ordinaryRows(base: 1000, toolCount: 9), terminalState: .completed)
        AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &transcript)
        transcript.turns[0].retentionTier = .condensed
        transcript = AgentTranscriptCompactor.compact(transcript)
        let encoded = try JSONEncoder().encode(transcript)
        for damage in ["missing-turn", "malformed-turn", "missing-span", "malformed-stamp", "retained-stamp"] {
            var payload = encoded
            if damage == "malformed-stamp" {
                var full = AgentTranscriptIO.buildTranscript(from: ordinary + quietRows(base: 100, wakeID: id(900)), terminalState: .completed)
                AgentTranscriptIO.test_installQuietLocalBaseline(baseline, in: &full)
                payload = try JSONEncoder().encode(full)
            }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            var turns = try XCTUnwrap(object["turns"] as? [[String: Any]])
            if damage == "missing-turn" { turns[0].removeValue(forKey: "quietLocal") }
            if damage == "malformed-turn" { turns[0]["quietLocal"] = ["completedAt": "not-a-date"] }
            if damage == "missing-span" {
                var spans = try XCTUnwrap(turns[0]["responseSpans"] as? [[String: Any]])
                spans[0]["quietLocal"] = [:] as [String: Any]
                turns[0]["responseSpans"] = spans
            }
            if damage == "malformed-stamp" {
                var full = try XCTUnwrap(turns[0]["responseSpans"] as? [[String: Any]])
                var activities = try XCTUnwrap(full[0]["activities"] as? [[String: Any]])
                let callIndex = try XCTUnwrap(activities.firstIndex { $0["toolName"] as? String == "self_noop" || ($0["id"] as? String)?.lowercased() == id(100).uuidString.lowercased() })
                activities[callIndex]["quietCheckInWakeID"] = "not-a-uuid"
                full[0]["activities"] = activities
                turns[0]["responseSpans"] = full
            }
            if damage == "retained-stamp" {
                var spans = try XCTUnwrap(turns[0]["responseSpans"] as? [[String: Any]])
                var activities = try XCTUnwrap(spans[0]["activities"] as? [[String: Any]])
                XCTAssertEqual(activities.count, 1, "The normal retained canonical conclusion is the witness")
                activities[0]["quietCheckInWakeID"] = "not-a-uuid"
                spans[0]["activities"] = activities
                turns[0]["responseSpans"] = spans
            }
            object["turns"] = turns
            let decoded = try JSONDecoder().decode(AgentTranscript.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.turns.count, damage == "malformed-stamp" ? 1 : 2, "Optional damage must not discard canonical audit")
            if damage == "malformed-stamp" {
                XCTAssertNil(decoded.turns[0].allActivities.first { $0.id == id(100) }?.quietCheckInWakeID)
                XCTAssertTrue(AgentTranscriptProjectionBuilder.build(from: decoded, excludingQuiet: true).workingRows.contains { $0.id == id(100) })
            } else {
                let local = AgentTranscriptProjectionBuilder.build(from: decoded, excludingQuiet: true)
                let audit = AgentTranscriptProjectionBuilder.build(from: decoded)
                XCTAssertEqual(local.workingRows, audit.workingRows, damage)
            }
        }
        let legacy = AgentTranscriptIO.buildTranscript(from: [row(0, kind: .user, text: "Request"), row(1, kind: .assistant, text: "[ack]")], terminalState: .completed)
        XCTAssertTrue(AgentTranscriptProjectionBuilder.build(from: legacy, excludingQuiet: true).workingRows.contains { $0.text == "[ack]" })
    }

    private func assertLocal(
        _ turn: AgentTranscriptTurn, baseline: AgentTranscriptTurn, tools: Int, tier: AgentTranscriptRetentionTier,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let projection = AgentTranscriptProjectionBuilder.build(from: .init(turns: [turn]), excludingQuiet: true)
        let blocks = projection.workingBlocks + projection.archivedBlocks
        let conclusion = try XCTUnwrap(blocks.first { $0.kind == .conclusion }, file: file, line: line)
        XCTAssertEqual(conclusion.primaryAnchor, try .conclusion(turnID: turn.id, activityID: XCTUnwrap(baseline.conclusionActivityID)), file: file, line: line)
        let fullText = try XCTUnwrap(baseline.allActivities.first { $0.id == baseline.conclusionActivityID }?.text)
        let expectedText = tier == .summary || tier == .archived
            ? String(fullText.prefix(220)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            : (tier == .condensed ? fullText.trimmingCharacters(in: .whitespacesAndNewlines) : fullText)
        XCTAssertEqual(conclusion.rows.first?.text, expectedText, file: file, line: line)
        XCTAssertEqual(conclusion.rows.first?.timestamp, baseline.completedAt, file: file, line: line)
        if tier == .full {
            var ordinaryReference = baseline
            // Preserve the existing owner's later global-tail tightening, not an obsolete
            // dispatch-time raw cap. Exclusion must not expand an older full turn's tail.
            ordinaryReference.frozenDetailedToolTailLimit = turn.frozenDetailedToolTailLimit
            let expected = AgentTranscriptProjectionBuilder.build(from: .init(turns: [ordinaryReference]))
            let expectedTools = expected.workingBlocks.filter { $0.kind == .standaloneTool }.flatMap(\.activityIDs)
            let actualTools = blocks.filter { $0.kind == .standaloneTool }.flatMap(\.activityIDs)
            XCTAssertEqual(actualTools, expectedTools, file: file, line: line)
            if turn.frozenDetailedToolTailLimit != 0 {
                XCTAssertFalse(expectedTools.isEmpty, "Current suffix oracle exercises detailed tools", file: file, line: line)
            }
        } else {
            XCTAssertEqual(turn.quietLocal?.summary?.toolCount, tools, file: file, line: line)
            XCTAssertEqual(turn.quietLocal?.summary?.notableToolNames, ["read_file"], file: file, line: line)
            XCTAssertEqual(turn.quietLocal?.summary?.hadWarning, true, file: file, line: line)
            if tier != .archived {
                let group = try XCTUnwrap(blocks.first { $0.kind == .groupedHistory }?.groupedHistory, file: file, line: line)
                XCTAssertEqual(group.summary.hiddenToolCardCount, tools, file: file, line: line)
                XCTAssertEqual(group.summary.toolSummary?.shortNarration, "Ordinary narration", file: file, line: line)
            }
        }
    }

    private func ordinaryRows(base: Int, toolCount: Int) -> [AgentChatItem] {
        var result = [row(base, kind: .user, text: "Ordinary request")]
        for index in 0 ..< toolCount {
            var call = row(base + index * 2 + 1, kind: .toolCall, text: "")
            call.toolName = "read_file"
            call.toolInvocationID = id(base + 5000 + index)
            call.toolArgsJSON = #"{"path":"example.swift"}"#
            var response = row(base + index * 2 + 2, kind: .toolResult, text: "Ordinary result")
            response.toolName = "read_file"
            response.toolInvocationID = call.toolInvocationID
            response.toolResultJSON = index == 0 ? #"{"status":"warning","content":"ordinary"}"# : #"{"content":"ordinary"}"#
            result += [call, response]
        }
        let tail = max(70, toolCount * 2 + 1)
        result.append(row(base + tail, kind: .assistant, text: "Ordinary narration"))
        result.append(row(base + tail + 1, kind: .thinking, text: "Ordinary reasoning"))
        result.append(row(base + tail + 2, kind: .assistant, text: String(repeating: "Ordinary conclusion. ", count: 15)))
        return result
    }

    private func quietRows(base: Int, wakeID: UUID) -> [AgentChatItem] {
        var call = row(base, kind: .toolCall, text: "")
        call.toolName = "self_noop"
        call.toolInvocationID = id(base + 6000)
        call.toolArgsJSON = "{}"
        var response = row(base + 1, kind: .toolResult, text: "{}")
        response.toolName = "self_noop"
        response.toolInvocationID = call.toolInvocationID
        response.toolResultJSON = "{}"
        return [call, response, row(base + 2, kind: .thinking, text: "Quiet reasoning"), row(base + 3, kind: .assistant, text: "Quiet closing \(base)")].map {
            var stamped = $0
            stamped.quietCheckInWakeID = wakeID
            return stamped
        }
    }

    private func row(_ value: Int, kind: AgentChatItemKind, text: String) -> AgentChatItem {
        AgentChatItem(id: id(value), timestamp: Date(timeIntervalSince1970: Double(value + 1)), kind: kind, text: text, sequenceIndex: value)
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

/// BEGIN W0 PAIRED COMMON HARNESS -- identical in pristine and candidate worktrees.
/// Approved empirical W0(g) owner-boundary diagnostic, not dispatch/fanout certification.
@MainActor
final class AgentQuietW0PairedScaleTests: XCTestCase {
    private struct Input {
        let seed: [AgentChatItem]
        let wakes: [[AgentChatItem]]
        let batches: [Int: [AgentChatItem]]
        let digest: String
    }

    private struct Counts: Codable {
        var calls: [String: Int] = [:]
        var rows: [String: Int] = [:]
        mutating func add(_ phase: String, _ count: Int) {
            calls[phase, default: 0] += 1
            rows[phase, default: 0] += count
        }
    }

    func testRepresentative200() throws {
        try run(wakeCount: 200)
    }

    func testStress400() throws {
        try run(wakeCount: 400)
    }

    private func run(wakeCount: Int) throws {
        guard ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "1" else {
            throw XCTSkip("W0 paired empirical job requires its explicit 600-second scale admission")
        }
        MainActor.preconditionIsolated()
        let input = try makeInput(wakeCount: wakeCount)
        // Exercise real per-window chat registries, not a replacement registry/history owner.
        // These inactive chats have no mutated source. Link role/admission/fanout is NOT
        // simulated here: the standing ~10 directional links belong to the next W0(d) gate.
        let windows = (1 ... 3).map { windowID in
            AgentModeViewModel(
                testWindowID: windowID, testWorkspacePath: FileManager.default.temporaryDirectory.path,
                codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) },
                headlessProviderFactory: { _, _ in
                    XCTFail("No live provider in W0 paired scale")
                    return AgentSessionLinkCapturingHeadlessProvider()
                }, mcpServerEnabler: { false }
            )
        }
        var chats: [AgentTabSession] = []
        for (windowIndex, window) in windows.enumerated() {
            for index in 0 ..< 100 {
                chats.append(window.session(for: uuid(900_000 + windowIndex * 100 + index)))
            }
        }
        let vm = windows[0]
        let session = chats[0]
        // Explicitly model one already-coalesced source batch at each provider-terminal cut.
        // There is no automatic second refresh/save task, provider run, or publication proof.
        session.onSourceItemsChanged = nil
        session.selectedAgent = .openCode
        defer {
            AgentTranscriptDebugInstrumentation.reset()
            for chat in chats {
                chat.saveDebounceTask?.cancel()
                chat.derivedTranscriptRefreshTask?.cancel()
            }
        }
        for item in input.seed {
            session.appendItem(item)
        }
        let initial = AgentTranscriptIO.buildTranscript(from: session.items, terminalState: .completed)
        _ = vm.applyTranscriptPresentation(initial, to: session)
        let turnID = try XCTUnwrap(session.transcript.turns.first?.id)
        var allCounts = Counts()
        var currentCounts = Counts()
        AgentTranscriptDebugInstrumentation.configure(.init(
            rebuildHandler: { value in
                currentCounts.add(value.usedIncrementalFinalTurnUpdate ? "incremental-rebuild" : "fallback-rebuild", value.workingItemsCount)
            },
            summaryTraversalHandler: { value in
                if value.turnID == turnID { currentCounts.add(value.phase, value.activityCount) }
            },
            projectionBuildHandler: { _ in currentCounts.add("projection-build", 0) }
        ))
        var ownerTimes: [Double] = []
        var appendTimes: [Double] = []
        let sampleStart = DispatchTime.now().uptimeNanoseconds
        print("QUIET_W0_PAIRED_INPUT " + json([
            "role": QuietW0ScaleAdapter.role, "wakes": wakeCount, "inputSHA256": input.digest,
            "chatOwners": chats.count, "windowOwners": windows.count,
            "standingDirectionalLinks": 10, "fanoutExercised": false,
            "proxyDefinition": "tool calls plus assistant text blocks; results/system rows counted separately",
            "nativeProxyUnits": wakeCount * 12 + (wakeCount / 20) * 98 + 1,
            "ordinaryWakeSourceRows": 24, "quietWakeSourceRows": 14, "ordinaryBatchSourceRows": 195,
            "onMainActor": true,
            "percentiles": "median average middle pair; p95 nearest rank",
            "boundary": "metadata preparation/stamp + incremental rebuild + production presentation builder/live commit; common raw admission timed separately"
        ]))

        for wake in 1 ... wakeCount {
            currentCounts = Counts()
            var appendMS = 0.0
            var ownerMS = 0.0
            var rebuildMS = 0.0
            var presentationMS = 0.0
            func apply(_ rows: [AgentChatItem], quiet: Bool) throws {
                let firstChanged = session.items.count
                let appendStart = DispatchTime.now().uptimeNanoseconds
                for row in rows {
                    session.appendItem(row)
                }
                appendMS += elapsedMS(since: appendStart)
                let start = DispatchTime.now().uptimeNanoseconds
                try QuietW0ScaleAdapter.prepare(quiet: quiet, range: firstChanged ... (session.items.count - 1), session: session)
                let rebuildStart = DispatchTime.now().uptimeNanoseconds
                var imported = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                    existingTranscript: session.transcript, workingItems: session.items,
                    earliestChangedIndex: firstChanged, terminalState: .completed,
                    nextSequenceIndex: session.nextSequenceIndex
                )
                rebuildMS += elapsedMS(since: rebuildStart)
                QuietW0ScaleAdapter.afterRebuild(quiet: quiet, transcript: &imported)
                let presentationStart = DispatchTime.now().uptimeNanoseconds
                let built = AgentModeViewModel.buildTranscriptPresentation(
                    from: imported, sourceItems: session.items,
                    precomputedEphemeralPayloadByItemID: session.ephemeralToolResultPayloadByItemID,
                    precomputedEphemeralPayloadRevisionByItemID: session.ephemeralToolResultPayloadRevisionByItemID,
                    selectedAgent: session.selectedAgent, previousPerformanceSnapshot: session.transcriptPerformanceSnapshot,
                    trackedLocalInputIDs: Set(session.localInputIndex.records.map(\.itemID)),
                    previousSanitizedTranscript: session.transcript, previousBaseProjection: session.baseTranscriptProjection,
                    previousTurnProjectionCaches: session.turnProjectionCaches,
                    previousProjectionProtection: session.transcriptProjectionProtection,
                    projectionProtection: .none, trustedIncrementalFinalTurnStartSequenceIndex: 0
                )
                vm.test_applyQuietW0ScalePresentation(built, to: session)
                presentationMS += elapsedMS(since: presentationStart)
                ownerMS += elapsedMS(since: start)
                XCTAssertEqual(session.transcript.turns.count, 1, "Routine wakes and ordinary batches never add a user anchor")
                XCTAssertEqual(session.transcript.turns[0].retentionTier, .full)
                XCTAssertEqual(session.transcript.turns[0].allActivities.count, session.items.count - 1, "No source prefilter or newest-suffix activity cap")
                try QuietW0ScaleAdapter.check(quiet: quiet, rows: rows, session: session)
            }
            if let batch = input.batches[wake] { try apply(batch, quiet: false) }
            try apply(input.wakes[wake - 1], quiet: wake.isMultiple(of: 3))
            ownerTimes.append(ownerMS)
            appendTimes.append(appendMS)
            for (phase, count) in currentCounts.calls {
                allCounts.calls[phase, default: 0] += count
            }
            for (phase, count) in currentCounts.rows {
                allCounts.rows[phase, default: 0] += count
            }
            print("QUIET_W0_PAIRED_WAKE " + json([
                "role": QuietW0ScaleAdapter.role, "wake": wake, "target": wakeCount,
                "quiet": wake.isMultiple(of: 3), "ordinaryBatch": input.batches[wake] != nil,
                "sourceRows": session.items.count, "canonicalActivities": session.transcript.turns[0].allActivities.count,
                "ownerMS": ownerMS, "appendMS": appendMS, "rebuildMS": rebuildMS, "presentationMS": presentationMS,
                "calls": currentCounts.calls, "rowVisits": currentCounts.rows,
                "metadataVisits": QuietW0ScaleAdapter.metadataVisits(session)
            ]))
            if wake.isMultiple(of: 50) {
                print("QUIET_W0_PAIRED_CURVE " + json([
                    "role": QuietW0ScaleAdapter.role, "wake": wake, "target": wakeCount,
                    "cumulative": stats(ownerTimes), "last50": stats(Array(ownerTimes.suffix(50))),
                    "sourceRows": session.items.count
                ]))
            }
        }
        XCTAssertNil(allCounts.calls["fallback-rebuild"], "Every measured append must use the actual incremental final-user-suffix route")
        print("QUIET_W0_PAIRED_SUMMARY " + json([
            "role": QuietW0ScaleAdapter.role, "wakes": wakeCount, "inputSHA256": input.digest,
            "sourceRows": session.items.count, "canonicalActivities": session.transcript.turns[0].allActivities.count,
            "canonicalUserAnchors": session.transcript.turns.count,
            "nativeProxyUnits": wakeCount * 12 + (wakeCount / 20) * 98 + 1,
            "quietWakes": wakeCount / 3, "ordinaryBatches": wakeCount / 20,
            "ownerMS": stats(ownerTimes), "rawAppendMS": stats(appendTimes),
            "calls": allCounts.calls, "rowVisits": allCounts.rows,
            "measurementWallMS": elapsedMS(since: sampleStart), "finiteNewestSuffixBound": false
        ]))
    }

    private func makeInput(wakeCount: Int) throws -> Input {
        var serial = 0
        func row(_ kind: AgentChatItemKind, _ text: String) -> AgentChatItem {
            serial += 1
            return AgentChatItem(id: uuid(serial), timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(serial)), kind: kind, text: text, sequenceIndex: serial - 1)
        }
        func tools(_ count: Int, quiet: Bool) -> [AgentChatItem] {
            var result: [AgentChatItem] = []
            for _ in 0 ..< count {
                var call = row(.toolCall, "")
                call.toolName = quiet ? "self_noop" : "read_file"
                call.toolInvocationID = uuid(1_000_000 + serial)
                call.toolArgsJSON = quiet ? "{}" : #"{"path":"example.swift"}"#
                var response = row(.toolResult, quiet ? #"{"result":"declared"}"# : "Ordinary result")
                response.toolName = call.toolName
                response.toolInvocationID = call.toolInvocationID
                response.toolResultJSON = quiet ? #"{"result":"declared"}"# : #"{"content":"ordinary"}"#
                result += [call, response]
            }
            return result
        }
        let seed = [row(.user, "Standing task"), row(.assistant, "Initial ordinary completion")]
        var wakes: [[AgentChatItem]] = []
        var batches: [Int: [AgentChatItem]] = [:]
        var rawInput = seed
        for wake in 1 ... wakeCount {
            if wake.isMultiple(of: 20) {
                // 97 calls + 1 assistant block = 98 native proxy units, 195 source rows.
                let batch = tools(97, quiet: false) + [row(.assistant, "Ordinary batch completion")]
                batches[wake] = batch
                rawInput += batch
            }
            let markerIdentity = row(.system, "")
            var rows = [AgentChatItem.laneUpdateAutoWake(wakeID: markerIdentity.id, acceptedAt: markerIdentity.timestamp, sequenceIndex: markerIdentity.sequenceIndex)]
            if wake.isMultiple(of: 3) {
                // Exactly one declaration, then trailing text-only closing blocks. No
                // other tools/refusal/error/recovery or invented neutral provider noise.
                // 1 call + 11 assistant blocks = 12 proxy units; result + provenance add 2 rows.
                rows += tools(1, quiet: true)
                for index in 1 ... 11 {
                    rows.append(row(.assistant, "Quiet closing segment \(index)"))
                }
            } else {
                // 11 calls + 1 assistant block = 12 proxy units, plus 11 results + provenance.
                rows += tools(11, quiet: false) + [row(.assistant, "Ordinary wake completion")]
            }
            wakes.append(rows)
            rawInput += rows
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(rawInput.map { AgentChatItemPersist(from: $0, sanitizeToolResults: false) })
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Input(seed: seed, wakes: wakes, batches: batches, digest: digest)
    }

    private func stats(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return [
            "median": sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle],
            "p95": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], "max": sorted.last ?? 0
        ]
    }

    private func elapsedMS(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            XCTFail("Invalid W0 measurement JSON")
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func uuid(_ serial: Int) -> UUID {
        UUID(uuidString: String(format: "00100000-0000-0000-0000-%012d", serial))!
    }
}

// END W0 PAIRED COMMON HARNESS

/// BEGIN W0 PAIRED ADAPTER -- only optional-carrier APIs differ from pristine.
@MainActor
private enum QuietW0ScaleAdapter {
    static let role = "candidate"

    static func prepare(quiet: Bool, range: ClosedRange<Int>, session: AgentTabSession) throws {
        guard quiet else { return }
        let ordinary = try XCTUnwrap(session.transcript.turns.last)
        AgentTranscriptIO.test_installQuietLocalBaseline(ordinary, in: &session.transcript)
        let ids = range.map { session.items[$0].id }
        let wakeID = try XCTUnwrap(ids.first)
        XCTAssertTrue(session.test_stampQuietMetadata(range: range, expectedIDs: ids, wakeID: wakeID))
    }

    static func afterRebuild(quiet: Bool, transcript: inout AgentTranscript) {
        guard !quiet, let ordinary = transcript.turns.last, ordinary.quietLocal != nil else { return }
        // Known ordinary work updates the two baseline fields from the actual freshly
        // rebuilt canonical owner. No filtered-source import or side history is prepared.
        AgentTranscriptIO.test_installQuietLocalBaseline(ordinary, in: &transcript)
    }

    static func check(quiet: Bool, rows: [AgentChatItem], session: AgentTabSession) throws {
        guard quiet else { return }
        let ids = Set(rows.map(\.id))
        XCTAssertFalse(session.baseTranscriptProjection.workingRows.contains { ids.contains($0.id) })
        XCTAssertTrue(session.transcript.turns[0].allActivities.contains { ids.contains($0.id) }, "Audit remains canonical")
    }

    static func metadataVisits(_ session: AgentTabSession) -> Int {
        session.test_quietMetadataVisitedItems
    }
}

// END W0 PAIRED ADAPTER
