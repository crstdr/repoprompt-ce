import AppKit
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import SwiftUI
import XCTest

/// Materializes real row providers without constructing a VM or starting a provider.
@MainActor
final class AgentSidebarMenuOpeningTests: XCTestCase {
    private final class Projection {
        var props: AgentSidebarOversightMenuProps?
        var reads = 0
    }

    private func props(peerName: String) -> AgentSidebarOversightMenuProps {
        let endpoint = AgentSessionLinkIdentityTestSupport.endpoint(sessionID: UUID())
        let peer = AgentSessionLinkIdentityTestSupport.endpoint(sessionID: UUID())
        return AgentSidebarOversightMenuProps(
            targetEndpoint: endpoint, targetSessionID: endpoint.sessionID,
            targetDisplayName: "Row", observerOptions: [], targetOptions: [.init(
                peerEndpoint: peer, peerSessionID: peer.sessionID, displayName: peerName,
                providerDisplayName: nil, menuLabel: peerName, fullIdentityDescription: peerName,
                relationship: .available
            )]
        )
    }

    private func host(_ projection: Projection) throws -> (NSWindow, StableMenuContextView) {
        _ = NSApplication.shared
        var row = AgentSessionRow(
            title: "Row", isActive: false, isPinned: false, isMCPControlled: false,
            runState: .idle, threadDepth: 0, onSelectionGesture: { _ in .ignored },
            onSelect: {}, onTogglePin: {}, onDelete: {}, onRename: { _ in },
            sessionIDCopyAction: .init(sessionID: nil, clipboardWriter: { _ in })
        )
        row.resolveSidebarOversightMenu = {
            projection.reads += 1
            return projection.props
        }
        row.onAddSidebarOversight = { _, _ in .changed }
        row.onStopSidebarOversight = { _, _, _ in .changed }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        // Register teardown before any lookup can throw.
        addTeardownBlock { @MainActor in window.close() }
        let hosting = NSHostingView(rootView: row)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func region(_ view: NSView) -> StableMenuContextView? {
            if let region = view as? StableMenuContextView { return region }
            return view.subviews.lazy.compactMap { region($0) }.first
        }
        return try (window, XCTUnwrap(region(hosting)))
    }

    private func submenu(_ menu: NSMenu, title: String) throws -> NSMenu {
        try XCTUnwrap(menu.items.first { $0.title == title }?.submenu)
    }

    func testColdOpeningReadsCurrentProjectionWithoutHover() throws {
        let projection = Projection()
        let (window, region) = try host(projection)
        defer { withExtendedLifetime(window) {} }
        projection.props = props(peerName: "First")
        let first = NSMenu.stableMenu(from: region.itemsProvider())
        XCTAssertTrue(try submenu(first, title: AgentOversightUICopy.overseeNewTitle).items.contains { $0.title == "First" })
        projection.props = props(peerName: "Second")
        let reopened = NSMenu.stableMenu(from: region.itemsProvider())
        XCTAssertTrue(try submenu(reopened, title: AgentOversightUICopy.overseeNewTitle).items.contains { $0.title == "Second" })
        XCTAssertFalse(try submenu(first, title: AgentOversightUICopy.overseeNewTitle).items.contains { $0.title == "Second" }, "Previous menu remains frozen")
    }

    func testUnavailableProjectionStillShowsBothOversightSubmenus() throws {
        let projection = Projection()
        let (window, region) = try host(projection)
        defer { withExtendedLifetime(window) {} }
        let menu = NSMenu.stableMenu(from: region.itemsProvider())
        for title in [AgentOversightUICopy.overseeNewTitle, AgentOversightUICopy.overseeByTitle] {
            let children = try submenu(menu, title: title).items
            XCTAssertEqual(children.map(\.title), [AgentOversightUICopy.oversightMenuUnavailableMessage])
            XCTAssertFalse(try XCTUnwrap(children.first).isEnabled)
        }
    }

    func testSubmenuOpeningRefreshesChoicesWithoutReplacingRootItems() throws {
        let projection = Projection()
        let (window, region) = try host(projection)
        defer { withExtendedLifetime(window) {} }
        let menu = NSMenu.stableMenu(from: region.itemsProvider())
        let rootItems = menu.items
        let child = try submenu(menu, title: AgentOversightUICopy.overseeNewTitle)
        projection.props = props(peerName: "Ready")
        try XCTUnwrap(child.delegate).menuNeedsUpdate?(child)
        XCTAssertTrue(child.items.contains { $0.title == "Ready" })
        XCTAssertEqual(menu.items, rootItems, "AppKit root identities must not change during submenu refresh")
    }
}
