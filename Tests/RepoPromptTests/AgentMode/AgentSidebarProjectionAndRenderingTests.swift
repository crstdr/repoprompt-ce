import AppKit
import ObjectiveC
@testable import RepoPromptApp
import SwiftUI
import XCTest

/// Covers the sidebar projection's two invalidation/laziness contracts:
///
/// 1. Normalized search fields are materialized only when a search query is
///    active, and are memoized by their source inputs.
/// 2. Presentation-only sidebar state (thread collapse, attention badges)
///    re-projects rows without rebuilding them.
///
/// Both protect against a main-thread rebuild storm during workspace restore,
/// where every sidebar invalidation previously re-normalized every row.
@MainActor
final class AgentSidebarSearchFieldDeferralTests: XCTestCase {
    // MARK: - Materialization is deferred and folding behavior is pinned

    func testSourceCaptureKeepsRawTextAndMaterializationFoldsCaseAndDiacritics() throws {
        let source = AgentModeSidebarSessionBuilder.searchFieldSource(
            title: "Café RÉSUMÉ",
            entry: entry(agentModelRaw: "GPT-5.2", parentSessionID: id(7)),
            runState: nil,
            isMCPControlled: false,
            worktree: nil,
            mergeAttention: nil,
            sessionID: id(1),
            tabID: id(2)
        )

        // Capturing a source must not normalize: normalization is the expensive
        // step this change defers out of ordinary rebuilds.
        XCTAssertEqual(source.title, "Café RÉSUMÉ")

        let fields = AgentModeSidebarSessionBuilder.searchFields(source: source)
        let title = try XCTUnwrap(fields.fields.first { $0.kind == .title })
        XCTAssertEqual(title.text, "Café RÉSUMÉ")
        XCTAssertEqual(title.normalizedText, "cafe resume")

        let model = try XCTUnwrap(fields.fields.first { $0.kind == .model })
        XCTAssertEqual(model.normalizedText, "gpt-5.2")

        // Entry-derived secondary and identifier fields survive the indirection.
        XCTAssertTrue(fields.fields.contains { $0.kind == .secondary && $0.normalizedText == "sub-agent" })
        XCTAssertTrue(fields.fields.contains { $0.kind == .identifier && $0.normalizedText == id(2).uuidString.lowercased() })
    }

    func testMaterializedFieldsMatchTheEagerBuilderForTheSameInputs() {
        let indexEntry = entry(agentModelRaw: "sonnet", parentSessionID: nil)
        let eager = AgentModeSidebarSessionBuilder.searchFields(
            title: "Rebuild Storm",
            entry: indexEntry,
            runState: .running,
            isMCPControlled: true,
            worktree: nil,
            mergeAttention: nil,
            sessionID: id(1),
            tabID: id(2)
        )
        let deferred = AgentModeSidebarSessionBuilder.searchFields(
            source: AgentModeSidebarSessionBuilder.searchFieldSource(
                title: "Rebuild Storm",
                entry: indexEntry,
                runState: .running,
                isMCPControlled: true,
                worktree: nil,
                mergeAttention: nil,
                sessionID: id(1),
                tabID: id(2)
            )
        )

        XCTAssertEqual(eager, deferred)
        XCTAssertFalse(deferred.fields.isEmpty)
    }

    func testSearchMatchingStillFindsFoldedQueryAgainstDeferredFields() {
        let row = row(tabID: id(2), title: "Café RÉSUMÉ")
        let query = AgentSessionSearchQuery.parse("cafe")

        XCTAssertTrue(AgentSessionSearchMatcher.matches(query: query, fields: row.makeSearchFields()))
        XCTAssertFalse(
            AgentSessionSearchMatcher.matches(
                query: AgentSessionSearchQuery.parse("zzzznomatch"),
                fields: row.makeSearchFields()
            )
        )
    }

    // MARK: - Memoization

    func testSearchFieldMemoReusesUnchangedRowsAndPrunesToCurrentRowSet() {
        let viewModel = makeViewModel()
        let rows = (1 ... 3).map { row(tabID: id($0), title: "Session \($0)") }

        let first = viewModel.sidebarSearchFields(for: rows)
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 3)

        // The result is positionally aligned with the input rows, which is what
        // makes the caller's lookup total and keeps every materialization counted.
        XCTAssertEqual(first.count, rows.count)
        XCTAssertEqual(
            first.map { $0.fields.first?.normalizedText },
            rows.map { $0.makeSearchFields().fields.first?.normalizedText }
        )

        // Identical sources must not re-normalize.
        _ = viewModel.sidebarSearchFields(for: rows)
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 3)

        // A changed source re-materializes only that row.
        var changed = rows
        changed[1] = row(tabID: id(2), title: "Session 2 renamed")
        _ = viewModel.sidebarSearchFields(for: changed)
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 4)

        // The memo is replaced by the current row set, so dropped rows are not
        // retained; re-requesting them materializes again.
        _ = viewModel.sidebarSearchFields(for: [changed[0]])
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 4)
        _ = viewModel.sidebarSearchFields(for: changed)
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 6)
    }

    func testDeactivatingSearchReleasesMemoizedFields() {
        let viewModel = makeViewModel()
        let tabs = (1 ... 3).map { ComposeTabState(id: id($0), name: "Session \($0)") }

        viewModel.setSessionSidebarSearchText("session")
        _ = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 3)
        XCTAssertEqual(viewModel.sidebarSearchFieldsMemo.count, 3)

        viewModel.clearSessionSidebarSearchText()
        _ = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertTrue(viewModel.sidebarSearchFieldsMemo.isEmpty)

        viewModel.setSessionSidebarSearchText("session")
        _ = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertEqual(
            viewModel.test_sidebarSearchFieldsMaterializationCount,
            6,
            "reactivating search should rematerialize fields released while inactive"
        )
    }

    // MARK: - Restore publication batching

    func testRestoreBatchSizePublishesPreferredRowsOnceAfterPrioritizedActiveTab() {
        XCTAssertEqual(
            AgentModeViewModel.sessionSidebarRestoreBatchSize(forPersistedTabCount: 0),
            1
        )
        XCTAssertEqual(
            AgentModeViewModel.sessionSidebarRestoreBatchSize(forPersistedTabCount: 969),
            969,
            "all already-projected preferred rows should arrive in one main-actor publication"
        )
    }

    // MARK: - Projection-level invalidation contract

    func testInactiveSearchProjectionMaterializesNoSearchFields() {
        let viewModel = makeViewModel()
        let tabs = (1 ... 4).map { ComposeTabState(id: id($0), name: "Session \($0)") }

        _ = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)

        XCTAssertEqual(viewModel.test_sidebarSessionRowsBuildCount, 1)
        XCTAssertEqual(
            viewModel.test_sidebarSearchFieldsMaterializationCount,
            0,
            "an empty search box must not normalize any row"
        )
    }

    func testActiveSearchProjectionMaterializesFieldsAndStillFilters() {
        let viewModel = makeViewModel()
        let tabs = [
            ComposeTabState(id: id(1), name: "Café RÉSUMÉ"),
            ComposeTabState(id: id(2), name: "Unrelated")
        ]
        let store = viewModel.ui.sessionSidebar
        store.update(
            searchText: "cafe",
            visibleSessionCount: AgentModeViewModel.sessionSidebarPageSize,
            archivedVisibleSessionCount: AgentModeViewModel.sessionSidebarArchivedPageSize
        )

        let result = projection(viewModel, tabs: tabs, snapshot: store.snapshot)

        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 2)
        XCTAssertEqual(result.filteredSessions.map(\.tabID), [id(1)])
    }

    /// Drives the real `AgentSessionSidebarUIStore` publish paths rather than a
    /// synthetic snapshot, because `buildSidebarSessions` keys its row cache on
    /// the live store's `rowContentRevision`.
    func testPresentationOnlyStoreChangesReprojectWithoutRebuildingRows() {
        let viewModel = makeViewModel()
        let tabs = (1 ... 3).map { ComposeTabState(id: id($0), name: "Session \($0)") }
        let store = viewModel.ui.sessionSidebar

        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)
        XCTAssertEqual(viewModel.test_sidebarSessionRowsBuildCount, 1)
        XCTAssertEqual(viewModel.test_sidebarListProjectionBuildCount, 1)

        store.setThreadCollapsed(true, for: .tab(id(1)))
        XCTAssertTrue(store.markRunStateAttention(tabID: id(2), state: .completed))
        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)

        XCTAssertEqual(viewModel.test_sidebarListProjectionBuildCount, 2, "projection must re-run")
        XCTAssertEqual(viewModel.test_sidebarSessionRowsBuildCount, 1, "rows must not rebuild")
    }

    /// `observeSidebarRunStateTransition` relies on `clearRunStateAttention`
    /// having published something: when the clear publishes, it deliberately does
    /// *not* call `syncSidebarUIState(refresh:reason:)`. Before this change the
    /// clear also bumped `rowContentRevision`, so the sidebar happened to update
    /// via a full row rebuild. Now the clear is presentation-only, so this proves
    /// the transition still reaches the sidebar through re-projection alone.
    func testRunningTransitionClearingAttentionUpdatesSidebarWithoutRebuildingRows() {
        let viewModel = makeViewModel()
        let tabs = (1 ... 3).map { ComposeTabState(id: id($0), name: "Session \($0)") }
        let store = viewModel.ui.sessionSidebar
        let backgroundTabID = id(2)
        let session = AgentModeViewModel.TabSession(tabID: backgroundTabID)

        // Seed the observed run state so the first real transition is not swallowed.
        session.runState = .idle
        viewModel.observeSidebarRunStateTransition(for: session)

        // A background completion raises an unseen-attention badge.
        session.runState = .completed
        viewModel.observeSidebarRunStateTransition(for: session)
        XCTAssertEqual(store.attentionRunState(for: backgroundTabID), .completed)

        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)
        let rowBuildsAfterBaseline = viewModel.test_sidebarSessionRowsBuildCount
        let projectionBuildsAfterBaseline = viewModel.test_sidebarListProjectionBuildCount
        let revisionBeforeClear = store.snapshot.revision
        let rowContentRevisionBeforeClear = store.snapshot.rowContentRevision

        // Resuming the run supersedes the stale badge.
        session.runState = .running
        viewModel.observeSidebarRunStateTransition(for: session)

        XCTAssertNil(
            store.attentionRunState(for: backgroundTabID),
            "resuming a run must clear the stale completion badge"
        )
        XCTAssertGreaterThan(
            store.snapshot.revision,
            revisionBeforeClear,
            "the clear must publish so the sidebar re-projects"
        )
        XCTAssertEqual(
            store.snapshot.rowContentRevision,
            rowContentRevisionBeforeClear,
            "the duplicate content fingerprint must not force another row rebuild"
        )

        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)
        XCTAssertEqual(
            viewModel.test_sidebarListProjectionBuildCount,
            projectionBuildsAfterBaseline + 1,
            "the cleared badge must reach the sidebar through re-projection"
        )
        XCTAssertEqual(
            viewModel.test_sidebarSessionRowsBuildCount,
            rowBuildsAfterBaseline,
            "a duplicate content fingerprint must not rebuild rows for an attention-only transition"
        )
    }

    func testBackgroundWaitingTransitionRefreshesCachedSearchFields() {
        let viewModel = makeViewModel()
        var tabs = (1 ... 3).map { ComposeTabState(id: id($0), name: "Session \($0)") }
        let backgroundTabID = id(2)
        tabs[1].activeAgentSessionID = id(500)
        let session = AgentModeViewModel.TabSession(tabID: backgroundTabID)
        session.runState = .running
        session.hasLoadedPersistedState = true
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: id(500), on: session))
        viewModel.test_installLiveSession(session)

        // Seed both transition observation and the content fingerprint while
        // the background session is running.
        viewModel.observeSidebarRunStateTransition(for: session)
        viewModel.syncSidebarUIState(refresh: true, reason: .runState, sidebarTabs: tabs)
        viewModel.setSessionSidebarSearchText("approval")

        let before = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertFalse(before.filteredSessions.contains { $0.tabID == backgroundTabID })
        let rowBuildsBeforeTransition = viewModel.test_sidebarSessionRowsBuildCount
        let rowContentRevisionBeforeTransition = viewModel.ui.sessionSidebar.snapshot.rowContentRevision

        // The tab remains active across this transition, so tabsWithActiveAgentRun
        // does not change. The transition observer must still refresh the row's
        // cached run-state search source.
        session.runState = .waitingForApproval
        viewModel.observeSidebarRunStateTransition(for: session)

        XCTAssertGreaterThan(
            viewModel.ui.sessionSidebar.snapshot.rowContentRevision,
            rowContentRevisionBeforeTransition
        )
        let after = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertTrue(after.filteredSessions.contains { $0.tabID == backgroundTabID })
        XCTAssertEqual(viewModel.test_sidebarSessionRowsBuildCount, rowBuildsBeforeTransition + 1)
    }

    func testForcedSidebarRefreshRebuildsRows() {
        let viewModel = makeViewModel()
        let tabs = (1 ... 3).map { ComposeTabState(id: id($0), name: "Session \($0)") }
        let store = viewModel.ui.sessionSidebar

        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)
        XCTAssertEqual(viewModel.test_sidebarSessionRowsBuildCount, 1)

        store.refresh()
        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)

        XCTAssertEqual(
            viewModel.test_sidebarSessionRowsBuildCount,
            2,
            "a forced content refresh remains the row-content invalidation path"
        )
    }

    // MARK: - Helpers

    private func projection(
        _ viewModel: AgentModeViewModel,
        tabs: [ComposeTabState],
        snapshot: AgentSessionSidebarSnapshot
    ) -> AgentModeViewModel.SidebarListProjection {
        viewModel.sidebarListProjection(
            workspaceID: nil,
            composeTabs: tabs,
            stashedTabs: [],
            currentTabID: tabs.first?.id,
            sidebarSnapshot: snapshot,
            archivedSessionsExpanded: false,
            showComposeTabsWithoutAgentSessions: true
        )
    }

    private func row(tabID: UUID, title: String) -> AgentModeViewModel.SidebarSession {
        AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: title,
            lastUserMessageAt: nil,
            activityDate: Date(timeIntervalSince1970: 0),
            isPinned: false,
            sessionID: nil,
            parentSessionID: nil,
            depth: 0,
            isMCPControlled: false,
            searchFieldSource: AgentModeSidebarSessionBuilder.searchFieldSource(
                title: title,
                entry: nil,
                runState: nil,
                isMCPControlled: false,
                worktree: nil,
                mergeAttention: nil,
                sessionID: nil,
                tabID: tabID
            )
        )
    }

    private func entry(agentModelRaw: String?, parentSessionID: UUID?) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id(500),
            tabID: id(2),
            name: "Indexed",
            lastUserMessageAt: nil,
            savedAt: Date(timeIntervalSince1970: 0),
            lastRunStateRaw: nil,
            itemCount: 1,
            agentKindRaw: nil,
            agentModelRaw: agentModelRaw,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: parentSessionID,
            hasUnknownConversationContent: false,
            isMCPOriginated: false,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: -991,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Sidebar projection tests must not start a Codex session")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}

/// Protects the rendered row lifetime needed to retain an in-flight press.
/// This deliberately does not assert AppKit mouse delivery: the CI XCTest
/// process can render rows without delivering even a stationary control tap.
@MainActor
final class AgentSidebarRunningTapTests: XCTestCase {
    func testRenderedRowIdentitySurvivesAStationaryUpdate() throws {
        let rows = Self.sessions(now: Self.now)
        var updated = rows
        updated[3] = Self.session(
            index: 1, activity: rows[3].activityDate, title: "Updated while pressed"
        )

        // The control updates content, not just the same value twice, and both
        // renderers must retain it when no ancestry or ordering changes.
        try Self.assertRowLifetime(before: rows, after: updated, pressedID: rows[3].tabID)
        try Self.assertRowLifetime(
            before: rows, after: updated, pressedID: rows[3].tabID,
            style: .firstRowSectionIdentity
        )
    }

    func testRenderedRowIdentitySurvivesOtherRunningSessionsResorting() throws {
        let rows = Self.sessions(now: Self.now)
        let pressedID = rows[3].tabID
        let promotedID = try XCTUnwrap(rows.last?.tabID)
        let updated = Self.sessions(now: Self.now, promotedTabID: promotedID)
        XCTAssertNotEqual(promotedID, pressedID)
        XCTAssertEqual(updated.first?.tabID, promotedID)
        XCTAssertNotEqual(rows.map(\.tabID), updated.map(\.tabID))

        try Self.assertRowLifetime(before: rows, after: updated, pressedID: pressedID)
        try Self.assertRowLifetime(
            before: rows, after: updated, pressedID: pressedID,
            style: .firstRowSectionIdentity, survives: false
        )
    }

    func testRenderedRowIdentitySurvivesThePressedRowMoving() throws {
        let rows = Self.sessions(now: Self.now)
        let pressedID = rows[3].tabID
        let updated = Self.sessions(now: Self.now, promotedTabID: pressedID)
        XCTAssertNotEqual(rows.first?.tabID, pressedID)
        XCTAssertEqual(updated.first?.tabID, pressedID)

        try Self.assertRowLifetime(before: rows, after: updated, pressedID: pressedID)
        try Self.assertRowLifetime(
            before: rows, after: updated, pressedID: pressedID,
            style: .firstRowSectionIdentity, survives: false
        )
    }

    func testRenderedRowIdentitySurvivesASectionOrdinalChange() throws {
        let yesterday = Self.now.addingTimeInterval(-86400)
        let pinned = Self.session(index: 0, activity: yesterday, isPinned: true)
        let today = Self.session(index: 1, activity: Self.now)
        let pressed = Self.session(index: 2, activity: yesterday.addingTimeInterval(-60))
        let rows = [pinned, today, pressed]
        let updated = [
            Self.session(index: 0, activity: Self.now.addingTimeInterval(5), isPinned: true),
            today,
            pressed
        ]
        let before = Self.sections(rows)
        let after = Self.sections(updated)
        XCTAssertEqual(before.map(\.bucket), [.yesterday, .today, .yesterday])
        XCTAssertEqual(after.map(\.bucket), [.today, .yesterday])
        XCTAssertNotEqual(before.last?.id, after.last?.id)
        XCTAssertEqual(before.last?.groups.first?.id, after.last?.groups.first?.id)

        try Self.assertRowLifetime(before: rows, after: updated, pressedID: pressed.tabID)
        // Even bucket/ordinal section IDs are not safe ancestors of the row.
        try Self.assertRowLifetime(
            before: rows, after: updated, pressedID: pressed.tabID,
            style: .sectionAndGroupAncestry, survives: false
        )
    }

    func testRenderedRowIdentitySurvivesRootToThreadChildRegrouping() throws {
        let parent = Self.session(index: 0, activity: Self.now)
        let pressed = Self.session(index: 1, activity: Self.now.addingTimeInterval(-30))
        let rows = [parent, pressed]
        let updated = [
            Self.session(index: 0, activity: Self.now, hasThreadChildren: true),
            Self.session(
                index: 1, activity: pressed.activityDate,
                parentSessionID: parent.tabID, depth: 1
            )
        ]
        let before = Self.sections(rows)
        let after = Self.sections(updated)
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.first?.groups.map(\.id), [parent.tabID, pressed.tabID])
        XCTAssertEqual(after.first?.groups.map(\.id), [parent.tabID])
        XCTAssertEqual(after.first?.groups.first?.rows.map(\.tabID), [parent.tabID, pressed.tabID])

        try Self.assertRowLifetime(before: rows, after: updated, pressedID: pressed.tabID)
        try Self.assertRowLifetime(
            before: rows, after: updated, pressedID: pressed.tabID,
            style: .sectionAndGroupAncestry, survives: false
        )
    }

    func testDateSectionIdentitySurvivesARunningResort() throws {
        let now = Self.now
        let rows = Self.sessions(now: now)
        let before = AgentSidebarDateSectionBuilder.activeSections(for: rows, now: now, calendar: Self.calendar)
        let promotedID = try XCTUnwrap(rows.last?.tabID)
        let after = AgentSidebarDateSectionBuilder.activeSections(
            for: Self.sessions(now: now, promotedTabID: promotedID),
            now: now,
            calendar: Self.calendar
        )

        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.map(\.bucket), [.today])
        XCTAssertNotEqual(before.first?.groups.first?.id, after.first?.groups.first?.id)
    }

    func testSplitRunsOfTheSameDayKeepDistinctSectionIdentities() throws {
        let now = Self.now
        let yesterday = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -1, to: now))
        let rows = [
            Self.session(index: 0, activity: yesterday, isPinned: true),
            Self.session(index: 1, activity: now),
            Self.session(index: 2, activity: yesterday.addingTimeInterval(-60))
        ]
        let sections = AgentSidebarDateSectionBuilder.activeSections(for: rows, now: now, calendar: Self.calendar)

        XCTAssertEqual(sections.map(\.bucket), [.yesterday, .today, .yesterday])
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
    }

    func testArchivedSectionIdentitySurvivesReorderingWithinADay() throws {
        let now = Self.now
        let first = try StashedTab(
            id: XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000001")),
            tab: ComposeTabState(),
            stashedAt: now
        )
        let second = try StashedTab(
            id: XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000002")),
            tab: ComposeTabState(),
            stashedAt: now.addingTimeInterval(-30)
        )
        let info = AgentModeViewModel.SidebarSessionDateInfo(lastEngagementAt: now, activityDate: now)
        let forward = AgentSidebarDateSectionBuilder.archivedSections(
            for: [first, second],
            now: now,
            calendar: Self.calendar,
            dateInfo: { _ in info }
        )
        let reversed = AgentSidebarDateSectionBuilder.archivedSections(
            for: [second, first],
            now: now,
            calendar: Self.calendar,
            dateInfo: { _ in info }
        )

        XCTAssertEqual(forward.map(\.id), reversed.map(\.id))
        XCTAssertEqual(forward.map(\.bucket), [.today])
    }

    func testRenderedRowsKeepSectionHeadersThreadOrderAndDepth() throws {
        let now = Self.now
        let yesterday = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -1, to: now))
        let previous = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -3, to: now))
        let pinned = Self.session(index: 0, activity: yesterday, isPinned: true)
        let parent = Self.session(index: 1, activity: now, hasThreadChildren: true)
        let child = Self.session(
            index: 2,
            activity: now.addingTimeInterval(-20),
            parentSessionID: parent.tabID,
            depth: 1
        )
        let older = Self.session(index: 3, activity: previous)
        let rendered = AgentSidebarDateSectionBuilder.renderedActiveRows(
            for: AgentSidebarDateSectionBuilder.activeSections(
                for: [pinned, parent, child, older],
                now: now,
                calendar: Self.calendar
            )
        )

        XCTAssertEqual(
            rendered.map(\.session.tabID),
            [pinned.tabID, parent.tabID, child.tabID, older.tabID]
        )
        XCTAssertEqual(rendered.map(\.showsHeader), [true, true, false, true])
        XCTAssertEqual(rendered.map(\.isFirstHeader), [true, false, false, false])
        XCTAssertEqual(rendered.map(\.headerTitle), ["Yesterday", "Today", "Today", "Previous"])
        XCTAssertEqual(rendered.map(\.session.depth), [0, 0, 1, 0])
        XCTAssertEqual(rendered.map(\.session.isPinned), [true, false, false, false])
    }

    func testArchivedRenderedRowsKeepOneHeaderPerDay() throws {
        let now = Self.now
        let yesterday = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -1, to: now))
        let today = try StashedTab(
            id: XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000011")),
            tab: ComposeTabState(),
            stashedAt: now
        )
        let older = try StashedTab(
            id: XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000012")),
            tab: ComposeTabState(),
            stashedAt: yesterday
        )
        let rendered = AgentSidebarDateSectionBuilder.renderedArchivedRows(
            for: AgentSidebarDateSectionBuilder.archivedSections(
                for: [today, older],
                now: now,
                calendar: Self.calendar,
                dateInfo: { tab in
                    AgentModeViewModel.SidebarSessionDateInfo(
                        lastEngagementAt: tab.stashedAt,
                        activityDate: tab.stashedAt
                    )
                }
            )
        )

        XCTAssertEqual(rendered.map(\.row.id), [today.id, older.id])
        XCTAssertEqual(rendered.map(\.showsHeader), [true, true])
        XCTAssertEqual(rendered.map(\.isFirstHeader), [true, false])
        XCTAssertEqual(rendered.map(\.headerTitle), ["Today", "Yesterday"])
    }

    func testFlatRowListMatchesSectionListFrames() {
        let sectionFrames = Self.measureFrames(.sectionForEach)
        let flatFrames = Self.measureFrames(.flatRows)

        XCTAssertEqual(Set(sectionFrames.keys), Set(["H-Yesterday", "H-Today", "H-Previous", "R0", "R1", "R2", "R3"]))
        XCTAssertEqual(sectionFrames.keys.sorted(), flatFrames.keys.sorted())
        for name in sectionFrames.keys.sorted() {
            XCTAssertEqual(
                flatFrames[name]?.minY ?? -1,
                sectionFrames[name]?.minY ?? -2,
                accuracy: 0.5,
                "\(name) vertical position"
            )
            XCTAssertEqual(
                flatFrames[name]?.height ?? -1,
                sectionFrames[name]?.height ?? -2,
                accuracy: 0.5,
                "\(name) height"
            )
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_780_660_800)
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func sections(
        _ rows: [AgentModeViewModel.SidebarSession]
    ) -> [AgentSidebarActiveDateSection] {
        AgentSidebarDateSectionBuilder.activeSections(for: rows, now: now, calendar: calendar)
    }

    private static func assertRowLifetime(
        before: [AgentModeViewModel.SidebarSession],
        after: [AgentModeViewModel.SidebarSession],
        pressedID: UUID,
        style: SidebarIdentityList.Style = .current,
        survives: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let host = NSHostingView(rootView: SidebarIdentityList(sections: sections(before), style: style))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 420)
        host.layoutSubtreeIfNeeded()
        let initialRows = identityRows(in: host)
        XCTAssertEqual(Set(initialRows.compactMap { $0.session?.tabID }), Set(before.map(\.tabID)), file: file, line: line)
        XCTAssertEqual(initialRows.count, before.count, file: file, line: line)
        let pressedRow = try XCTUnwrap(initialRows.first { $0.session?.tabID == pressedID }, file: file, line: line)
        // A row-local marker, not a synthetic gesture/activation implementation.
        // Keeping a strong reference also prevents address reuse from hiding replacement.
        pressedRow.pressedTabID = pressedID

        host.rootView = SidebarIdentityList(sections: sections(after), style: style)
        host.layoutSubtreeIfNeeded()
        let updatedRows = identityRows(in: host)
        XCTAssertNil(host.window, "Identity checks must not require a window", file: file, line: line)
        XCTAssertEqual(Set(updatedRows.compactMap { $0.session?.tabID }), Set(after.map(\.tabID)), file: file, line: line)
        XCTAssertEqual(updatedRows.count, after.count, file: file, line: line)
        let updatedRow = try XCTUnwrap(updatedRows.first { $0.session?.tabID == pressedID }, file: file, line: line)
        XCTAssertEqual(updatedRow.session, after.first { $0.tabID == pressedID }, "The retained row must receive updated content", file: file, line: line)
        XCTAssertEqual(pressedRow === updatedRow, survives, "\(style) effective row identity", file: file, line: line)
        XCTAssertEqual(updatedRow.pressedTabID, survives ? pressedID : nil, "\(style) row-local press state", file: file, line: line)
    }

    private static func identityRows(in view: NSView) -> [SidebarIdentityRowView] {
        (view as? SidebarIdentityRowView).map { [$0] } ?? view.subviews.flatMap { identityRows(in: $0) }
    }

    private static func measureFrames(
        _ style: SidebarLayoutProbe.Style
    ) -> [String: CGRect] {
        let sink = SidebarLayoutFrameSink()
        let host = NSHostingView(rootView: SidebarLayoutProbe(style: style, sink: sink))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 420)
        host.layoutSubtreeIfNeeded()
        return sink.frames
    }

    private static func sessions(
        now: Date,
        promotedTabID: UUID? = nil
    ) -> [AgentModeViewModel.SidebarSession] {
        let rows = (0 ..< 5).map { index in
            let tabID = UUID(uuidString: "00000000-0000-4000-8000-00000000000\(index)")!
            var activity = now.addingTimeInterval(-Double(40 - index * 10))
            if promotedTabID == tabID {
                activity = now.addingTimeInterval(5)
            }
            return Self.session(index: index, activity: activity)
        }
        return rows.sorted { $0.activityDate > $1.activityDate }
    }

    private static func session(
        index: Int,
        activity: Date,
        isPinned: Bool = false,
        parentSessionID: UUID? = nil,
        depth: Int = 0,
        hasThreadChildren: Bool = false,
        title: String? = nil
    ) -> AgentModeViewModel.SidebarSession {
        let tabID = UUID(uuidString: "00000000-0000-4000-8000-00000000000\(index)")!
        return AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: title ?? "Running \(index)",
            lastUserMessageAt: nil,
            activityDate: activity,
            isPinned: isPinned,
            sessionID: tabID,
            parentSessionID: parentSessionID,
            depth: depth,
            isMCPControlled: false,
            hasThreadChildren: hasThreadChildren
        )
    }
}

/// The production list supplies identity and header ancestry; only the row
/// content is replaced with an inspectable AppKit lifetime probe.
private struct SidebarIdentityList: View {
    enum Style {
        case current
        case firstRowSectionIdentity
        case sectionAndGroupAncestry
    }

    let sections: [AgentSidebarActiveDateSection]
    let style: Style

    var body: some View {
        VStack(spacing: 2) {
            switch style {
            case .current:
                AgentSidebarKeyedRowList(
                    items: AgentSidebarDateSectionBuilder.renderedActiveRows(for: sections),
                    showsHeader: \.showsHeader,
                    headerTitle: \.headerTitle,
                    isFirstHeader: \.isFirstHeader
                ) { item in
                    SidebarIdentityRow(session: item.session)
                }
            case .firstRowSectionIdentity:
                // Before ebf21f155, a section was keyed by its first row.
                // Recreate that changing ancestor even with today's builder.
                ForEach(sections) { section in
                    legacySection(section)
                        .id(section.groups.first?.id)
                }
            case .sectionAndGroupAncestry:
                // Stable day/ordinal sections alone still replace a row when
                // its section ordinal or thread-group ancestry changes.
                ForEach(sections) { section in
                    legacySection(section)
                }
            }
        }
    }

    private func legacySection(_ section: AgentSidebarActiveDateSection) -> some View {
        ForEach(section.groups) { group in
            ForEach(group.rows) { session in
                SidebarIdentityRow(session: session)
            }
        }
    }
}

private struct SidebarIdentityRow: NSViewRepresentable {
    let session: AgentModeViewModel.SidebarSession

    func makeNSView(context _: Context) -> SidebarIdentityRowView {
        SidebarIdentityRowView()
    }

    func updateNSView(_ view: SidebarIdentityRowView, context _: Context) {
        view.session = session
    }
}

private final class SidebarIdentityRowView: NSView {
    var session: AgentModeViewModel.SidebarSession?
    var pressedTabID: UUID?

    override var intrinsicContentSize: NSSize {
        NSSize(width: 280, height: 36)
    }
}

private struct SidebarLayoutFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

@MainActor
private final class SidebarLayoutFrameSink {
    var frames: [String: CGRect] = [:]
}

private struct SidebarLayoutProbe: View {
    enum Style {
        case sectionForEach
        case flatRows
    }

    let style: Style
    let sink: SidebarLayoutFrameSink

    var body: some View {
        stack
            .coordinateSpace(name: "probe")
            .frame(width: 280, alignment: .top)
            .onPreferenceChange(SidebarLayoutFrameKey.self) { sink.frames = $0 }
    }

    @ViewBuilder
    private var stack: some View {
        switch style {
        case .sectionForEach:
            VStack(spacing: 2) {
                ForEach(Self.sections, id: \.title) { section in
                    marker(section.title, minHeight: nil, top: section.isFirst ? 2 : 14, bottom: 4)
                    ForEach(section.rows, id: \.self) { name in
                        marker(name, minHeight: 36, top: 0, bottom: 0)
                    }
                }
            }
        case .flatRows:
            VStack(spacing: 2) {
                ForEach(Array(Self.flatItems.enumerated()), id: \.offset) { _, item in
                    if let header = item.header {
                        marker(header, minHeight: nil, top: item.isFirst ? 2 : 14, bottom: 4)
                    }
                    marker(item.row, minHeight: 36, top: 0, bottom: 0)
                }
            }
        }
    }

    private func marker(
        _ name: String,
        minHeight: CGFloat?,
        top: CGFloat,
        bottom: CGFloat
    ) -> some View {
        Text(verbatim: name)
            .frame(
                maxWidth: .infinity,
                minHeight: minHeight,
                maxHeight: minHeight,
                alignment: .leading
            )
            .padding(.top, top)
            .padding(.bottom, bottom)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SidebarLayoutFrameKey.self,
                        value: [name: proxy.frame(in: .named("probe"))]
                    )
                }
            }
    }

    private static let sections: [(title: String, isFirst: Bool, rows: [String])] = [
        ("H-Yesterday", true, ["R0"]),
        ("H-Today", false, ["R1", "R2"]),
        ("H-Previous", false, ["R3"])
    ]

    private static let flatItems: [(header: String?, isFirst: Bool, row: String)] = [
        ("H-Yesterday", true, "R0"),
        ("H-Today", false, "R1"),
        (nil, false, "R2"),
        ("H-Previous", false, "R3")
    ]
}

/// Hosts the sidebar's row `ForEach` and presses a row while running sessions
/// re-sort or a root becomes a thread child. Either change used to replace the
/// view under the pointer and drop the in-flight tap.
@MainActor
final class AgentSidebarHostedTapTests: XCTestCase {
    override func tearDown() {
        SidebarTapFirstMouse.uninstall()
        super.tearDown()
    }

    func testTapActivatesThePressedRowWhenTheListStaysStill() {
        let now = Date()
        let harness = SidebarRunningTapHarness(now: now)
        harness.rows = Self.sessions(now: now)
        let pressedIndex = 3
        let pressedID = harness.rows[pressedIndex].tabID
        let (window, host) = Self.makeWindow(harness)
        Self.showForClicks(window)
        let appeared = Self.render(until: Date().addingTimeInterval(0.3)) { harness.appeared }
        XCTAssertTrue(appeared)
        let point = Self.point(in: host, rowIndex: pressedIndex)
        Self.send(.leftMouseDown, at: point, window: window)
        Self.send(.leftMouseUp, at: point, window: window)
        _ = Self.render(until: Date().addingTimeInterval(0.2)) { !harness.activated.isEmpty }

        Self.assertActivated(harness, equals: [pressedID], window: window)
        window.orderOut(nil)
    }

    func testTapActivatesThePressedRowWhenRunningSessionsResort() {
        let now = Date()
        let harness = SidebarRunningTapHarness(now: now)
        harness.rows = Self.sessions(now: now)
        let pressedIndex = 3
        let pressedID = harness.rows[pressedIndex].tabID
        let promotedID = harness.rows[harness.rows.count - 1].tabID
        XCTAssertNotEqual(promotedID, pressedID)

        let (window, host) = Self.makeWindow(harness)
        Self.showForClicks(window)
        _ = Self.render(until: Date().addingTimeInterval(0.3)) { harness.appeared }

        let sectionIDAtPress = harness.seenSectionIDs.last
        let point = Self.point(in: host, rowIndex: pressedIndex)
        Self.send(.leftMouseDown, at: point, window: window)

        harness.rows = Self.sessions(now: now, promotedTabID: promotedID)
        let resorted = Self.render(until: Date().addingTimeInterval(0.4)) {
            harness.renderedFirstRowID == promotedID
        }
        XCTAssertTrue(resorted, "The press must overlap a rendered re-sort")
        XCTAssertEqual(
            harness.seenSectionIDs.last,
            sectionIDAtPress,
            "Re-sorting running rows must not change the date section identity"
        )

        Self.send(.leftMouseUp, at: point, window: window)
        _ = Self.render(until: Date().addingTimeInterval(0.2)) { !harness.activated.isEmpty }

        Self.assertActivated(harness, equals: [pressedID], window: window)
        window.orderOut(nil)
    }

    func testTapActivatesThePressedRowWhenThatRowMovesDuringThePress() {
        let now = Date()
        let harness = SidebarRunningTapHarness(now: now)
        harness.rows = Self.sessions(now: now)
        let pressedIndex = 3
        let pressedID = harness.rows[pressedIndex].tabID

        let (window, host) = Self.makeWindow(harness)
        Self.showForClicks(window)
        _ = Self.render(until: Date().addingTimeInterval(0.3)) { harness.appeared }

        let point = Self.point(in: host, rowIndex: pressedIndex)
        Self.send(.leftMouseDown, at: point, window: window)

        harness.rows = Self.sessions(now: now, promotedTabID: pressedID)
        let moved = Self.render(until: Date().addingTimeInterval(0.4)) {
            harness.renderedFirstRowID == pressedID
        }
        XCTAssertTrue(moved, "The press must overlap the pressed row moving to the top")

        Self.send(.leftMouseUp, at: point, window: window)
        _ = Self.render(until: Date().addingTimeInterval(0.2)) { !harness.activated.isEmpty }

        Self.assertActivated(harness, equals: [pressedID], window: window)
        window.orderOut(nil)
    }

    func testTapSurvivesWhenAnEarlierRunOfTheSameDayJoinsToday() throws {
        let now = Date()
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let pinned = Self.session(index: 0, activity: yesterday, isPinned: true)
        let today = Self.session(index: 1, activity: now)
        let pressed = Self.session(index: 2, activity: yesterday.addingTimeInterval(-60))
        let harness = SidebarRunningTapHarness(now: now)
        harness.rows = [pinned, today, pressed]
        let (window, host) = Self.makeWindow(harness)
        Self.showForClicks(window)
        _ = Self.render(until: Date().addingTimeInterval(0.3)) { harness.appeared }

        let sectionIDAtPress = harness.sectionIDByRow[pressed.tabID]
        let point = Self.point(in: host, rowIndex: 2)
        Self.send(.leftMouseDown, at: point, window: window)

        harness.rows = [
            Self.session(index: 0, activity: now.addingTimeInterval(5), isPinned: true),
            today,
            pressed
        ]
        let shifted = Self.render(until: Date().addingTimeInterval(0.4)) {
            harness.sectionIDByRow[pressed.tabID] != sectionIDAtPress
        }
        XCTAssertTrue(
            shifted,
            "The press must overlap the later Yesterday section changing ordinal"
        )

        Self.send(.leftMouseUp, at: point, window: window)
        _ = Self.render(until: Date().addingTimeInterval(0.2)) { !harness.activated.isEmpty }

        Self.assertActivated(harness, equals: [pressed.tabID], window: window)
        window.orderOut(nil)
    }

    func testTapSurvivesWhenAPressedRootBecomesAThreadChild() {
        let now = Date()
        let parent = Self.session(index: 0, activity: now)
        let pressed = Self.session(index: 1, activity: now.addingTimeInterval(-30))
        let harness = SidebarRunningTapHarness(now: now)
        harness.rows = [parent, pressed]
        let (window, host) = Self.makeWindow(harness)
        Self.showForClicks(window)
        _ = Self.render(until: Date().addingTimeInterval(0.3)) { harness.appeared }

        let groupIDAtPress = harness.groupIDByRow[pressed.tabID]
        XCTAssertEqual(groupIDAtPress, pressed.tabID)
        let point = Self.point(in: host, rowIndex: 1)
        Self.send(.leftMouseDown, at: point, window: window)

        harness.rows = [
            Self.session(index: 0, activity: now, hasThreadChildren: true),
            Self.session(
                index: 1,
                activity: now.addingTimeInterval(-30),
                parentSessionID: parent.tabID,
                depth: 1
            )
        ]
        let regrouped = Self.render(until: Date().addingTimeInterval(0.4)) {
            harness.groupIDByRow[pressed.tabID] == parent.tabID
        }
        XCTAssertTrue(
            regrouped,
            "The press must overlap the row leaving its own group for its parent"
        )

        Self.send(.leftMouseUp, at: point, window: window)
        _ = Self.render(until: Date().addingTimeInterval(0.2)) { !harness.activated.isEmpty }

        Self.assertActivated(harness, equals: [pressed.tabID], window: window)
        window.orderOut(nil)
    }

    func testFlattenedActiveAndArchivedRowIDsAreUnique() throws {
        let now = Date()
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let pinned = Self.session(index: 0, activity: yesterday, isPinned: true)
        let parent = Self.session(index: 1, activity: now, hasThreadChildren: true)
        let child = Self.session(
            index: 2,
            activity: now.addingTimeInterval(-20),
            parentSessionID: parent.tabID,
            depth: 1
        )
        let older = Self.session(index: 3, activity: yesterday.addingTimeInterval(-60))
        let active = AgentSidebarDateSectionBuilder.renderedActiveRows(
            for: AgentSidebarDateSectionBuilder.activeSections(
                for: [pinned, parent, child, older],
                now: now
            )
        )
        let activeIDs = active.map(\.id)

        XCTAssertEqual(Set(activeIDs).count, activeIDs.count)
        XCTAssertEqual(activeIDs, [pinned.id, parent.id, child.id, older.id])
        XCTAssertTrue(AgentSidebarDateSectionBuilder.activeSections(for: [], now: now).isEmpty)

        let today = try Self.stashedTab(index: 1, at: now)
        let previous = try Self.stashedTab(index: 2, at: yesterday)
        let archived = AgentSidebarDateSectionBuilder.renderedArchivedRows(
            for: AgentSidebarDateSectionBuilder.archivedSections(
                for: [today, previous],
                now: now,
                dateInfo: { tab in
                    AgentModeViewModel.SidebarSessionDateInfo(
                        lastEngagementAt: tab.stashedAt,
                        activityDate: tab.stashedAt
                    )
                }
            )
        )
        let archivedIDs = archived.map(\.id)

        XCTAssertEqual(Set(archivedIDs).count, archivedIDs.count)
        XCTAssertEqual(archivedIDs, [today.id, previous.id])
        XCTAssertTrue(
            AgentSidebarDateSectionBuilder.archivedSections(
                for: [],
                now: now,
                dateInfo: { _ in
                    AgentModeViewModel.SidebarSessionDateInfo(lastEngagementAt: nil, activityDate: nil)
                }
            ).isEmpty
        )
    }

    func testSidebarSessionIDSurvivesAThreadMetadataRebuild() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let parentTabID = try XCTUnwrap(UUID(uuidString: "20000000-0000-4000-8000-000000000001"))
        let childTabID = try XCTUnwrap(UUID(uuidString: "20000000-0000-4000-8000-000000000002"))
        let pinnedTabID = try XCTUnwrap(UUID(uuidString: "20000000-0000-4000-8000-000000000003"))
        let parentSessionID = try XCTUnwrap(UUID(uuidString: "20000000-0000-4000-8000-000000000011"))
        let childSessionID = try XCTUnwrap(UUID(uuidString: "20000000-0000-4000-8000-000000000012"))
        let pinnedSessionID = try XCTUnwrap(UUID(uuidString: "20000000-0000-4000-8000-000000000013"))
        let parent = Self.composeTab(id: parentTabID, name: "Parent", sessionID: parentSessionID, modified: now)
        let child = Self.composeTab(
            id: childTabID,
            name: "Child",
            sessionID: childSessionID,
            modified: now.addingTimeInterval(-30)
        )
        let pinned = Self.composeTab(
            id: pinnedTabID,
            name: "Pinned",
            sessionID: pinnedSessionID,
            modified: now.addingTimeInterval(-120),
            isPinned: true
        )
        let tabs = [parent, child, pinned]

        let threaded = Self.sidebarRows(
            tabs: tabs,
            entries: [
                Self.indexEntry(id: parentSessionID, tabID: parentTabID, savedAt: now, parentSessionID: nil),
                Self.indexEntry(
                    id: childSessionID,
                    tabID: childTabID,
                    savedAt: now.addingTimeInterval(-30),
                    parentSessionID: parentSessionID
                ),
                Self.indexEntry(
                    id: pinnedSessionID,
                    tabID: pinnedTabID,
                    savedAt: now.addingTimeInterval(-120),
                    parentSessionID: nil
                )
            ]
        )
        let detached = Self.sidebarRows(
            tabs: tabs,
            entries: [
                Self.indexEntry(id: parentSessionID, tabID: parentTabID, savedAt: now, parentSessionID: nil),
                Self.indexEntry(
                    id: childSessionID,
                    tabID: childTabID,
                    savedAt: now.addingTimeInterval(-30),
                    parentSessionID: nil
                ),
                Self.indexEntry(
                    id: pinnedSessionID,
                    tabID: pinnedTabID,
                    savedAt: now.addingTimeInterval(-120),
                    parentSessionID: nil
                )
            ]
        )

        XCTAssertEqual(threaded.map(\.id), [pinnedTabID, parentTabID, childTabID])
        XCTAssertEqual(threaded.map(\.depth), [0, 0, 1])
        XCTAssertEqual(detached.map(\.id), threaded.map(\.id))
        XCTAssertEqual(detached.map(\.depth), [0, 0, 0])
        XCTAssertEqual(Set(threaded.map(\.id)).count, threaded.count)
    }

    private static let rowHeight: CGFloat = 36

    /// The CI runner's XCTest process is inactive, and a borderless window cannot
    /// become key, so SwiftUI drops `onTapGesture`. Finish launch, become a regular
    /// app, and put a keyable window on a screen before sending events.
    private static func showForClicks(_ window: NSWindow) {
        SidebarTapFirstMouse.install()
        let app = NSApplication.shared
        if app.activationPolicy() != .regular {
            _ = app.setActivationPolicy(.regular)
        }
        if !app.isRunning {
            app.finishLaunching()
        }
        app.activate(ignoringOtherApps: true)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            var frame = window.frame
            frame.origin = NSPoint(
                x: screen.visibleFrame.minX + 80,
                y: screen.visibleFrame.minY + 80
            )
            window.setFrame(frame, display: true)
        } else {
            window.setFrameOrigin(NSPoint(x: 80, y: 80))
        }
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            window.orderFrontRegardless()
            window.makeKey()
        }
    }

    private static func makeWindow(
        _ harness: SidebarRunningTapHarness
    ) -> (NSWindow, SidebarTapHostingView<SidebarRunningTapList>) {
        let host = SidebarTapHostingView(rootView: SidebarRunningTapList(harness: harness))
        let window = SidebarTapWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: rowHeight * 8),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private static func sessions(
        now: Date,
        promotedTabID: UUID? = nil
    ) -> [AgentModeViewModel.SidebarSession] {
        let rows = (0 ..< 5).map { index in
            let tabID = UUID(uuidString: "00000000-0000-4000-8000-00000000000\(index)")!
            var activity = now.addingTimeInterval(-Double(40 - index * 10))
            if promotedTabID == tabID {
                activity = now.addingTimeInterval(5)
            }
            return Self.session(index: index, activity: activity)
        }
        return rows.sorted { $0.activityDate > $1.activityDate }
    }

    private static func stashedTab(index: Int, at date: Date) throws -> StashedTab {
        try StashedTab(
            id: XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-00000000002\(index)")),
            tab: ComposeTabState(),
            stashedAt: date
        )
    }

    private static func composeTab(
        id: UUID,
        name: String,
        sessionID: UUID,
        modified: Date,
        isPinned: Bool = false
    ) -> ComposeTabState {
        ComposeTabState(
            id: id,
            name: name,
            lastModified: modified,
            isPinned: isPinned,
            activeAgentSessionID: sessionID
        )
    }

    private static func indexEntry(
        id: UUID,
        tabID: UUID,
        savedAt: Date,
        parentSessionID: UUID?
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id,
            tabID: tabID,
            name: "Indexed",
            lastUserMessageAt: nil,
            savedAt: savedAt,
            lastRunStateRaw: nil,
            itemCount: 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: parentSessionID,
            hasUnknownConversationContent: false,
            isMCPOriginated: false,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private static func sidebarRows(
        tabs: [ComposeTabState],
        entries: [AgentSessionIndexEntry]
    ) -> [AgentModeViewModel.SidebarSession] {
        AgentModeSidebarSessionBuilder(
            allTabs: tabs,
            rowTabs: tabs,
            sessions: [:],
            authoritativeSessionIDByTabID: Dictionary(
                uniqueKeysWithValues: tabs.compactMap { tab in
                    tab.activeAgentSessionID.map { (tab.id, $0) }
                }
            ),
            sessionIndex: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
            sessionListSortDates: [:],
            sessionListCacheReady: true,
            sidebarRestoreFrozenOrderByTabID: [:],
            mcpControlledTabIDs: []
        ).build()
    }

    private static func session(
        index: Int,
        activity: Date,
        isPinned: Bool = false,
        parentSessionID: UUID? = nil,
        depth: Int = 0,
        hasThreadChildren: Bool = false
    ) -> AgentModeViewModel.SidebarSession {
        let tabID = UUID(uuidString: "00000000-0000-4000-8000-00000000000\(index)")!
        return AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: "Running \(index)",
            lastUserMessageAt: nil,
            activityDate: activity,
            isPinned: isPinned,
            sessionID: tabID,
            parentSessionID: parentSessionID,
            depth: depth,
            isMCPControlled: false,
            hasThreadChildren: hasThreadChildren
        )
    }

    private static func point(in host: SidebarTapHostingView<SidebarRunningTapList>, rowIndex: Int) -> NSPoint {
        let harness = host.rootView.harness
        let key = harness.rows[rowIndex].tabID.uuidString
        _ = render(until: Date().addingTimeInterval(0.3)) { harness.rowFrames[key] != nil }
        guard let frame = harness.rowFrames[key] else {
            XCTFail("The pressed row must have a rendered frame")
            return .zero
        }
        let y = host.isFlipped ? frame.midY : host.bounds.height - frame.midY
        return host.convert(NSPoint(x: 40, y: y), to: nil)
    }

    private static func send(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) {
        if !window.isKeyWindow {
            window.makeKey()
        }
        window.sendEvent(mouseEvent(type, at: point, window: window))
    }

    private static func assertActivated(
        _ harness: SidebarRunningTapHarness,
        equals expected: [UUID],
        window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = NSApplication.shared
        XCTAssertEqual(
            harness.activated,
            expected,
            """
            tap missed key=\(window.isKeyWindow) active=\(app.isActive) \
            policy=\(app.activationPolicy().rawValue) screens=\(NSScreen.screens.count) \
            number=\(window.windowNumber) visible=\(window.isVisible) \
            onScreen=\(window.screen != nil)
            """,
            file: file,
            line: line
        )
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        window: NSWindow
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }

    private static func render(until deadline: Date, condition: () -> Bool) -> Bool {
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}

@MainActor
private final class SidebarRunningTapHarness: ObservableObject {
    @Published var rows: [AgentModeViewModel.SidebarSession] = []
    var activated: [UUID] = []
    var appeared = false
    var seenSectionIDs: [UUID] = []
    var renderedFirstRowID: UUID?
    var rowFrames: [String: CGRect] = [:]
    let now: Date

    init(now: Date) {
        self.now = now
    }

    var sectionIDByRow: [UUID: UUID] = [:]
    var groupIDByRow: [UUID: UUID] = [:]

    func note(_ sections: [AgentSidebarActiveDateSection]) {
        renderedFirstRowID = sections.first?.groups.first?.rows.first?.tabID
        noteSectionID(sections.first?.id)
        var ids: [UUID: UUID] = [:]
        var groupIDs: [UUID: UUID] = [:]
        for section in sections {
            for group in section.groups {
                for row in group.rows {
                    ids[row.tabID] = section.id
                    groupIDs[row.tabID] = group.id
                }
            }
        }
        sectionIDByRow = ids
        groupIDByRow = groupIDs
    }

    func noteSectionID(_ id: UUID?) {
        guard let id, seenSectionIDs.last != id else { return }
        seenSectionIDs.append(id)
    }
}

private struct SidebarRunningTapList: View {
    @ObservedObject var harness: SidebarRunningTapHarness

    var body: some View {
        let sections = AgentSidebarDateSectionBuilder.activeSections(for: harness.rows, now: harness.now)
        let _ = harness.note(sections)
        VStack(spacing: 0) {
            AgentSidebarKeyedRowList(
                items: AgentSidebarDateSectionBuilder.renderedActiveRows(for: sections),
                showsHeader: \.showsHeader,
                headerTitle: \.headerTitle,
                isFirstHeader: \.isFirstHeader
            ) { item in
                let session = item.session
                Text(verbatim: session.title)
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { harness.activated.append(session.tabID) }
                    .focusable()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: SidebarLayoutFrameKey.self,
                                value: [session.tabID.uuidString: proxy.frame(in: .named("tapProbe"))]
                            )
                        }
                    }
            }
        }
        .coordinateSpace(name: "tapProbe")
        .frame(width: 280, height: 288, alignment: .top)
        .onPreferenceChange(SidebarLayoutFrameKey.self) { harness.rowFrames = $0 }
        .onAppear { harness.appeared = true }
    }
}

/// Borderless windows refuse `makeKey()` unless they opt in. The click tests
/// need a key window so SwiftUI does not discard the gesture.
private final class SidebarTapWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

/// The hosting view is the hit target when SwiftUI has not inserted a subview.
/// Accepting the first mouse covers the runner case where the app never becomes active.
private final class SidebarTapHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// SwiftUI may hit-test an internal descendant. That descendant's default
/// `acceptsFirstMouse` is false, and an inactive app then drops the click.
/// The test process accepts the first mouse on every view so the real
/// `onTapGesture` still runs.
private enum SidebarTapFirstMouse {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        guard
            let original = class_getInstanceMethod(
                NSView.self,
                #selector(NSView.acceptsFirstMouse(for:))
            ),
            let replacement = class_getInstanceMethod(
                NSView.self,
                #selector(NSView.sidebarTapTests_acceptsFirstMouse(for:))
            )
        else { return }
        method_exchangeImplementations(original, replacement)
        installed = true
    }

    static func uninstall() {
        guard installed,
              let original = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))),
              let replacement = class_getInstanceMethod(NSView.self, #selector(NSView.sidebarTapTests_acceptsFirstMouse(for:)))
        else { return }
        method_exchangeImplementations(original, replacement)
        installed = false
    }
}

private extension NSView {
    @objc func sidebarTapTests_acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}
