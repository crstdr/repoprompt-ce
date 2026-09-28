import AppKit
import ObjectiveC
@testable import RepoPromptApp
import SwiftUI
import XCTest

/// Hosts the sidebar's row `ForEach` and presses a row while running sessions
/// re-sort or a root becomes a thread child. Either change used to replace the
/// view under the pointer and drop the in-flight tap.
@MainActor
final class AgentSidebarRunningTapTests: XCTestCase {
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

    func testDateSectionIdentitySurvivesARunningResort() throws {
        let now = Date()
        let rows = Self.sessions(now: now)
        let before = AgentSidebarDateSectionBuilder.activeSections(for: rows, now: now)
        let promotedID = try XCTUnwrap(rows.last?.tabID)
        let after = AgentSidebarDateSectionBuilder.activeSections(
            for: Self.sessions(now: now, promotedTabID: promotedID),
            now: now
        )

        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.map(\.bucket), [.today])
        XCTAssertNotEqual(before.first?.groups.first?.id, after.first?.groups.first?.id)
    }

    func testSplitRunsOfTheSameDayKeepDistinctSectionIdentities() throws {
        let now = Date()
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let rows = [
            Self.session(index: 0, activity: yesterday, isPinned: true),
            Self.session(index: 1, activity: now),
            Self.session(index: 2, activity: yesterday.addingTimeInterval(-60))
        ]
        let sections = AgentSidebarDateSectionBuilder.activeSections(for: rows, now: now)

        XCTAssertEqual(sections.map(\.bucket), [.yesterday, .today, .yesterday])
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
    }

    func testArchivedSectionIdentitySurvivesReorderingWithinADay() throws {
        let now = Date()
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
            dateInfo: { _ in info }
        )
        let reversed = AgentSidebarDateSectionBuilder.archivedSections(
            for: [second, first],
            now: now,
            dateInfo: { _ in info }
        )

        XCTAssertEqual(forward.map(\.id), reversed.map(\.id))
        XCTAssertEqual(forward.map(\.bucket), [.today])
    }

    func testRenderedRowsKeepSectionHeadersThreadOrderAndDepth() throws {
        let now = Date()
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let previous = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: now))
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
                now: now
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
        let now = Date()
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
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

    private static func measureFrames(
        _ style: SidebarLayoutProbe.Style
    ) -> [String: CGRect] {
        let sink = SidebarLayoutFrameSink()
        let host = NSHostingView(rootView: SidebarLayoutProbe(style: style, sink: sink))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 140, y: 140))
        window.makeKeyAndOrderFront(nil)
        _ = render(until: Date().addingTimeInterval(0.4)) { sink.frames.count >= 7 }
        window.orderOut(nil)
        return sink.frames
    }

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
            contentRect: NSRect(x: 0, y: 0, width: 280, height: rowHeight * 5),
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

    private static func point(in host: NSView, rowIndex: Int) -> NSPoint {
        let yFromTop = CGFloat(rowIndex) * rowHeight + rowHeight / 2
        let y = host.isFlipped ? yFromTop : host.bounds.height - yFromTop
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
            ForEach(AgentSidebarDateSectionBuilder.renderedActiveRows(for: sections)) { item in
                let session = item.session
                Text(verbatim: session.title)
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { harness.activated.append(session.tabID) }
                    .focusable()
            }
        }
        .frame(width: 280, height: 180, alignment: .top)
        .onAppear { harness.appeared = true }
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
}

private extension NSView {
    @objc func sidebarTapTests_acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}
