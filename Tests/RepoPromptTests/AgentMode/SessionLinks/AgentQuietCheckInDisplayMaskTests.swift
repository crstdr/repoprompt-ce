import Combine
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
