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
    /// samples as the control's text tint instead — a very different colour.
    private func pixelCount(
        near expected: NSColor,
        in rep: NSBitmapImageRep,
        tolerance: CGFloat = 0.14
    ) -> Int {
        guard let want = expected.usingColorSpace(.sRGB) else { return 0 }
        var count = 0
        let width = Int(rep.size.width)
        let height = Int(rep.size.height)
        for x in 0 ..< width {
            for y in 0 ..< height {
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

    /// The failing case from Cristian's live check: an overseen row's interactive mark must
    /// paint the overseer's slot-0 group colour, not the control tint.
    func testInteractiveOverseenMarkKeepsTheFirstOverseersPaletteColour() {
        let role = AgentSessionOversightRole(
            ownOverseerSlot: nil,
            overseers: [.init(sessionID: id(1), displayName: "Overseer", slot: 0)],
            overseeingNames: []
        )
        let expected = AgentOversightPalette.resolvedColor(for: 0, darkAppearance: true)

        let (rep, window) = rasterize(row(role: role, interactive: true))
        defer { window.close() }
        XCTAssertGreaterThan(
            pixelCount(near: expected, in: rep), 0,
            "interactive overseen mark lost the overseer's palette colour (template-flattened)"
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

        XCTAssertGreaterThan(
            pixelCount(near: AgentOversightPalette.resolvedColor(for: 1, darkAppearance: true), in: rep),
            0,
            "dual-role mark lost the row's own group colour"
        )
        XCTAssertGreaterThan(
            pixelCount(near: AgentOversightPalette.resolvedColor(for: 0, darkAppearance: true), in: rep),
            0,
            "dual-role mark lost the first overseer's ring colour"
        )
    }

    /// Control: an inactive (no link) row draws no palette pixels at all, proving the colour
    /// assertions above come from the mark rather than stray UI.
    func testRowWithoutRolePaintsNoPalettePixels() {
        let (rep, window) = rasterize(row(role: .none, interactive: false))
        defer { window.close() }
        XCTAssertEqual(
            pixelCount(near: AgentOversightPalette.resolvedColor(for: 0, darkAppearance: true), in: rep),
            0
        )
    }
}
