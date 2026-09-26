import AppKit
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
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.makeKeyAndOrderFront(nil)
        let appeared = Self.render(until: Date().addingTimeInterval(0.3)) { harness.appeared }
        XCTAssertTrue(appeared)
        let point = Self.point(in: host, rowIndex: pressedIndex)
        window.sendEvent(Self.mouseEvent(.leftMouseDown, at: point, window: window))
        window.sendEvent(Self.mouseEvent(.leftMouseUp, at: point, window: window))
        _ = Self.render(until: Date().addingTimeInterval(0.2)) { !harness.activated.isEmpty }

        XCTAssertEqual(harness.activated, [pressedID])
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
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.makeKeyAndOrderFront(nil)
        _ = Self.render(until: Date().addingTimeInterval(0.3)) { harness.appeared }

        let sectionIDAtPress = harness.seenSectionIDs.last
        let point = Self.point(in: host, rowIndex: pressedIndex)
        window.sendEvent(Self.mouseEvent(.leftMouseDown, at: point, window: window))

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

        window.sendEvent(Self.mouseEvent(.leftMouseUp, at: point, window: window))
        _ = Self.render(until: Date().addingTimeInterval(0.2)) { !harness.activated.isEmpty }

        XCTAssertEqual(harness.activated, [pressedID])
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
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.makeKeyAndOrderFront(nil)
        _ = Self.render(until: Date().addingTimeInterval(0.3)) { harness.appeared }

        let sectionIDAtPress = harness.sectionIDByRow[pressed.tabID]
        let point = Self.point(in: host, rowIndex: 2)
        window.sendEvent(Self.mouseEvent(.leftMouseDown, at: point, window: window))

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

        window.sendEvent(Self.mouseEvent(.leftMouseUp, at: point, window: window))
        _ = Self.render(until: Date().addingTimeInterval(0.2)) { !harness.activated.isEmpty }

        XCTAssertEqual(harness.activated, [pressed.tabID])
        window.orderOut(nil)
    }

    func testTapSurvivesWhenAPressedRootBecomesAThreadChild() {
        let now = Date()
        let parent = Self.session(index: 0, activity: now)
        let pressed = Self.session(index: 1, activity: now.addingTimeInterval(-30))
        let harness = SidebarRunningTapHarness(now: now)
        harness.rows = [parent, pressed]
        let (window, host) = Self.makeWindow(harness)
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.makeKeyAndOrderFront(nil)
        _ = Self.render(until: Date().addingTimeInterval(0.3)) { harness.appeared }

        let groupIDAtPress = harness.groupIDByRow[pressed.tabID]
        XCTAssertEqual(groupIDAtPress, pressed.tabID)
        let point = Self.point(in: host, rowIndex: 1)
        window.sendEvent(Self.mouseEvent(.leftMouseDown, at: point, window: window))

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

        window.sendEvent(Self.mouseEvent(.leftMouseUp, at: point, window: window))
        _ = Self.render(until: Date().addingTimeInterval(0.2)) { !harness.activated.isEmpty }

        XCTAssertEqual(harness.activated, [pressed.tabID])
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

    private static let rowHeight: CGFloat = 36

    private static func makeWindow(
        _ harness: SidebarRunningTapHarness
    ) -> (NSWindow, NSHostingView<SidebarRunningTapList>) {
        let host = NSHostingView(rootView: SidebarRunningTapList(harness: harness))
        let window = NSWindow(
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
            if condition() { return true }
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
