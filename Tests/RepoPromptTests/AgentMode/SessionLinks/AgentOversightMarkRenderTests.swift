import AppKit
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import SwiftUI
import XCTest

/// The interactive oversight mark must keep its palette colour. Wrapping the glyph in a macOS
/// `Menu` label template-renders it, flattening every `foregroundStyle` to the control tint —
/// the fix keeps the glyph as ordinary content underneath a clear-label Menu hit target.
/// These tests rasterize the row and sample pixels, because a structure check cannot see
/// through the Menu's native label rendering.
@MainActor
final class AgentOversightMarkRenderTests: XCTestCase {
    private func id(_ seed: UInt8) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", seed))!
    }

    private func props() -> AgentSidebarOversightMenuProps {
        let endpoint = AgentSessionLinkIdentityTestSupport.endpoint(sessionID: id(9))
        return AgentSidebarOversightMenuProps(
            targetEndpoint: endpoint,
            targetSessionID: endpoint.sessionID,
            targetDisplayName: "Lane",
            observerOptions: []
        )
    }

    private func row(role: AgentSessionOversightRole, interactive: Bool) -> AgentSessionRow {
        var row = AgentSessionRow(
            title: "Lane A",
            isActive: false,
            isPinned: false,
            isMCPControlled: false,
            runState: .idle,
            threadDepth: 0,
            onSelectionGesture: { _ in .ignored },
            onSelect: {},
            onTogglePin: {},
            onDelete: {},
            onRename: { _ in },
            sessionIDCopyAction: AgentSidebarSessionIDCopyAction(sessionID: nil, clipboardWriter: { _ in })
        )
        row.oversightRole = role
        if interactive {
            let props = props()
            row.resolveSidebarOversightMenu = { props }
            row.onAddSidebarOversight = { _, _ in .changed }
            row.onStopSidebarOversight = { _, _, _ in .changed }
        }
        return row
    }

    /// Hosts a row in a real window so the Menu materializes its native control, then
    /// rasterizes it in dark appearance (the reported failure environment).
    private func rasterize(_ view: some View) -> (rep: NSBitmapImageRep, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 280)))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("could not allocate bitmap for hosted row")
            return (NSBitmapImageRep(), window)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, window)
    }

    /// Pixels within `tolerance` (per sRGB channel) of `expected`. A template-rendered mark
    /// samples as the control's text tint instead — a very different colour. `pixelsWide`/`High`
    /// are used (not `size`, which is points) so a retina backing still scans the whole bitmap.
    private func pixelCount(
        near expected: NSColor,
        in rep: NSBitmapImageRep,
        tolerance: CGFloat = 0.14
    ) -> Int {
        guard let want = expected.usingColorSpace(.sRGB) else { return 0 }
        var count = 0
        for x in 0 ..< rep.pixelsWide {
            for y in 0 ..< rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(pixel.redComponent - want.redComponent) < tolerance,
                   abs(pixel.greenComponent - want.greenComponent) < tolerance,
                   abs(pixel.blueComponent - want.blueComponent) < tolerance
                {
                    count += 1
                }
            }
        }
        return count
    }

    /// A glyph-sized mark is far more than a stray matching pixel even at 1x backing.
    private let markPixelFloor = 8

    /// The failing case from Cristian's live check: an overseen row's interactive mark must
    /// paint the overseer's slot-0 group colour, not the control tint. The selected row
    /// reported identical white pixels — same template path — so both states are asserted.
    func testInteractiveOverseenMarkKeepsTheFirstOverseersPaletteColour() {
        let role = AgentSessionOversightRole(
            ownOverseerSlot: nil,
            overseers: [.init(sessionID: id(1), displayName: "Overseer", slot: 0)],
            overseeingNames: []
        )
        let expected = AgentOversightPalette.resolvedColor(for: 0, darkAppearance: true)

        let (rep, window) = rasterize(row(role: role, interactive: true))
        defer { window.close() }
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: expected, in: rep), markPixelFloor,
            "interactive overseen mark lost the overseer's palette colour (template-flattened)"
        )

        var selectedRow = row(role: role, interactive: true)
        selectedRow.isSelected = true
        let (selectedRep, selectedWindow) = rasterize(selectedRow)
        defer { selectedWindow.close() }
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: expected, in: selectedRep), markPixelFloor,
            "interactive overseen mark lost the palette colour on the selected row"
        )
    }

    /// The non-interactive branch was already correct — the mark was only template-flattened
    /// inside a Menu label — so a muted row keeps its colour too. Guards the two branches
    /// staying visually identical.
    func testNonInteractiveOverseenMarkKeepsTheSamePaletteColour() {
        let role = AgentSessionOversightRole(
            ownOverseerSlot: nil,
            overseers: [.init(sessionID: id(1), displayName: "Overseer", slot: 0)],
            overseeingNames: []
        )
        let expected = AgentOversightPalette.resolvedColor(for: 0, darkAppearance: true)

        let (rep, window) = rasterize(row(role: role, interactive: false))
        defer { window.close() }
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: expected, in: rep), markPixelFloor,
            "non-interactive overseen mark lost the palette colour"
        )
    }

    /// A selected/active-looking row hits the same Menu label path — the palette survives
    /// because the glyph is ordinary content, not a template image.
    func testInteractiveBothRolesMarkKeepsBothPaletteColours() {
        let role = AgentSessionOversightRole(
            ownOverseerSlot: 1,
            overseers: [
                .init(sessionID: id(1), displayName: "Overseer A", slot: 0),
                .init(sessionID: id(2), displayName: "Overseer B", slot: 3)
            ],
            overseeingNames: ["Lane B"]
        )
        let (rep, window) = rasterize(row(role: role, interactive: true))
        defer { window.close() }

        XCTAssertGreaterThanOrEqual(
            pixelCount(near: AgentOversightPalette.resolvedColor(for: 1, darkAppearance: true), in: rep),
            markPixelFloor,
            "dual-role mark lost the row's own group colour"
        )
        XCTAssertGreaterThanOrEqual(
            pixelCount(near: AgentOversightPalette.resolvedColor(for: 0, darkAppearance: true), in: rep),
            markPixelFloor,
            "dual-role mark lost the first overseer's ring colour"
        )
    }

    /// Control: an inactive (no link) row draws no palette pixels at all, proving the colour
    /// assertions above come from the mark rather than stray UI.
    func testRowWithoutRolePaintsNoPalettePixels() {
        let (rep, window) = rasterize(row(role: .none, interactive: false))
        defer { window.close() }
        XCTAssertGreaterThan(rep.pixelsWide, 0, "raster produced an empty bitmap")
        XCTAssertEqual(
            pixelCount(near: AgentOversightPalette.resolvedColor(for: 0, darkAppearance: true), in: rep),
            0
        )
    }

    // MARK: - Passive overseer-only switch

    private func role(own: Int?, overseers: Int) -> AgentSessionOversightRole {
        AgentSessionOversightRole(
            ownOverseerSlot: own,
            overseers: (0 ..< overseers).map {
                .init(sessionID: id(UInt8($0 + 1)), displayName: "Overseer \($0)", slot: $0)
            },
            overseeingNames: own == nil ? [] : ["Lane B"]
        )
    }

    /// Switch ON (current default): an overseer-only mark is passive — tooltip only — while
    /// overseen and dual-role marks keep the Oversee-by menu.
    func testPassiveSwitchOnMakesOnlyOverseerOnlyMarksNonInteractive() {
        agentOversightPassiveOverseerOnlyMark = true
        defer { agentOversightPassiveOverseerOnlyMark = true }
        XCTAssertFalse(agentSessionRowOversightMarkIsInteractive(role: role(own: 0, overseers: 0)))
        XCTAssertTrue(agentSessionRowOversightMarkIsInteractive(role: role(own: nil, overseers: 1)))
        XCTAssertTrue(agentSessionRowOversightMarkIsInteractive(role: role(own: 0, overseers: 1)))
    }

    /// Switch OFF (rollback path): every role mark keeps the menu, including overseer-only.
    func testPassiveSwitchOffRestoresOverseerOnlyMenu() {
        agentOversightPassiveOverseerOnlyMark = false
        defer { agentOversightPassiveOverseerOnlyMark = true }
        XCTAssertTrue(agentSessionRowOversightMarkIsInteractive(role: role(own: 0, overseers: 0)))
        XCTAssertTrue(agentSessionRowOversightMarkIsInteractive(role: role(own: nil, overseers: 1)))
        XCTAssertTrue(agentSessionRowOversightMarkIsInteractive(role: role(own: 0, overseers: 1)))
    }

    // MARK: - ID-less rows (option a)

    /// A fresh chat has no session ID until the first send: its context menu still lists both
    /// Oversee submenus, each containing only the approved disabled reason.
    func testIDLessRowOffersDisabledOversightSubmenusWithReason() {
        XCTAssertEqual(
            AgentOversightUICopy.oversightAvailableAfterFirstMessage,
            "Available after the first message"
        )

        var idlessRow = row(role: .none, interactive: false)
        idlessRow.sidebarOversightUnavailableReason =
            AgentOversightUICopy.oversightAvailableAfterFirstMessage
        XCTAssertTrue(idlessRow.showsDisabledOversightContextSubmenus)

        // Multi-select / bulk-mutation modes suppress the oversight section entirely.
        var suppressedRow = row(role: .none, interactive: false)
        suppressedRow.sidebarOversightUnavailableReason =
            AgentOversightUICopy.oversightAvailableAfterFirstMessage
        suppressedRow.showsSelectionPresentation = true
        XCTAssertFalse(suppressedRow.showsDisabledOversightContextSubmenus)

        // A bound row resolves a live menu — the disabled pair must not appear alongside it.
        var linkedRow = row(role: .none, interactive: true)
        linkedRow.sidebarOversightUnavailableReason =
            AgentOversightUICopy.oversightAvailableAfterFirstMessage
        XCTAssertFalse(linkedRow.showsDisabledOversightContextSubmenus)

        // And a bound row never carries the reason.
        XCTAssertFalse(row(role: .none, interactive: true).showsDisabledOversightContextSubmenus)
    }
}
