import AppKit
@testable import RepoPromptApp
import SwiftUI
import XCTest

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
