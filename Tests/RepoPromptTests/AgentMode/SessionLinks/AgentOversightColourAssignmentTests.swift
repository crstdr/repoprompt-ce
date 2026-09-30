import AppKit
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Fb iconography support types: the palette slot allocator, the per-row role derivation, and
/// the palette's contrast contract against the sidebar background in both appearances.
@MainActor
final class AgentOversightColourAssignmentTests: XCTestCase {
    private func id(_ seed: UInt8) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", seed))!
    }

    private func endpoint(sessionID: UUID) -> DomainAgentSessionLinkEndpointIdentity {
        AgentSessionLinkIdentityTestSupport.endpoint(sessionID: sessionID)
    }

    private func inbound(
        overseerSessionID: UUID,
        linkID: UUID = UUID(),
        linkCreatedAt: Date? = nil,
        displayName: String = "Overseer"
    ) -> AgentMonitorPillProps.Inbound {
        AgentMonitorPillProps.Inbound(
            linkID: linkID,
            generation: 1,
            observerSessionID: overseerSessionID,
            observerEndpoint: endpoint(sessionID: overseerSessionID),
            linkCreatedAt: linkCreatedAt,
            displayName: displayName,
            providerDisplayName: nil
        )
    }

    private func outbound(
        targetSessionID: UUID,
        linkCreatedAt: Date? = nil,
        displayName: String = "Lane"
    ) -> AgentMonitorPillProps.Outbound {
        AgentMonitorPillProps.Outbound(
            linkID: UUID(),
            generation: 1,
            targetSessionID: targetSessionID,
            targetEndpoint: endpoint(sessionID: targetSessionID),
            linkCreatedAt: linkCreatedAt,
            displayName: displayName,
            providerDisplayName: nil,
            locationLabel: nil,
            status: .idle
        )
    }

    // MARK: - Allocator

    func testAllocatorTakesLowestFreeSlotAndKeepsItAcrossChurn() {
        let allocator = AgentOversightColourAllocator()
        let a = id(1)
        let b = id(2)
        let c = id(3)
        let now = Date()

        allocator.reconcile(activeOverseerFirstLinkDates: [a: now, b: now, c: now])
        XCTAssertEqual(allocator.slot(for: a), 0)
        XCTAssertEqual(allocator.slot(for: b), 1)
        XCTAssertEqual(allocator.slot(for: c), 2)

        // Removing the middle holder frees its slot but never reshuffles the survivors.
        allocator.reconcile(activeOverseerFirstLinkDates: [a: now, c: now])
        XCTAssertEqual(allocator.slot(for: a), 0)
        XCTAssertEqual(allocator.slot(for: c), 2)

        // A newcomer fills the vacated lowest slot rather than appending.
        let d = id(4)
        allocator.reconcile(activeOverseerFirstLinkDates: [a: now, c: now, d: now])
        XCTAssertEqual(allocator.slot(for: d), 1)
    }

    func testAllocatorReleasesOnLastLinkAndReassignsInLinkOrder() {
        let allocator = AgentOversightColourAllocator()
        let early = id(1)
        let late = id(2)
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)

        allocator.reconcile(activeOverseerFirstLinkDates: [early: t0, late: t1])
        XCTAssertEqual(allocator.slot(for: early), 0)
        XCTAssertEqual(allocator.slot(for: late), 1)

        // Last link gone: the slot is released and a later appearance starts over.
        allocator.reconcile(activeOverseerFirstLinkDates: [:])
        XCTAssertEqual(allocator.slotsByOverseerID, [:])

        // Reappearing overseers are assigned in link-creation order, not dictionary order.
        allocator.reconcile(activeOverseerFirstLinkDates: [late: t1, early: t0])
        XCTAssertEqual(allocator.slot(for: early), 0)
        XCTAssertEqual(allocator.slot(for: late), 1)
    }

    func testAllocatorWrapsPastTenOverseers() {
        let allocator = AgentOversightColourAllocator()
        let now = Date()
        var active: [UUID: Date] = [:]
        for index in 0 ..< 11 {
            active[id(UInt8(index + 1))] = now + TimeInterval(index)
        }
        allocator.reconcile(activeOverseerFirstLinkDates: active)

        XCTAssertEqual(Set(active.keys).count, 11)
        // The eleventh distinct overseer wraps onto slot 0 rather than extending the palette.
        XCTAssertEqual(allocator.slotsByOverseerID[id(11)], 0)
        XCTAssertEqual(allocator.slotsByOverseerID.count, 11)
    }

    // MARK: - Role derivation

    func testRoleIsNoneWithoutLinks() {
        let role = AgentSessionOversightRole.make(
            inbound: [],
            outbound: [],
            ownSessionID: id(1)
        ) { _ in 0 }
        XCTAssertFalse(role.hasMark)
    }

    func testRoleOverseerOnlyGetsOwnSlotAndTargetNames() {
        let me = id(1)
        let role = AgentSessionOversightRole.make(
            inbound: [],
            outbound: [outbound(targetSessionID: id(9), displayName: "Lane A")],
            ownSessionID: me
        ) { sessionID in
            XCTAssertEqual(sessionID, me)
            return 4
        }
        XCTAssertEqual(role.ownOverseerSlot, 4)
        XCTAssertTrue(role.isOverseer)
        XCTAssertFalse(role.isOverseen)
        XCTAssertEqual(role.overseeingNames, ["Lane A"])
    }

    func testRoleOverseenOnlyListsOverseersInLinkCreationOrder() {
        let first = id(10)
        let second = id(11)
        let t0 = Date(timeIntervalSince1970: 10)
        let t1 = Date(timeIntervalSince1970: 20)
        let role = AgentSessionOversightRole.make(
            inbound: [
                // Listed in reverse creation order to prove the sort, not the input order.
                inbound(overseerSessionID: second, linkCreatedAt: t1, displayName: "Late"),
                inbound(overseerSessionID: first, linkCreatedAt: t0, displayName: "Early")
            ],
            outbound: [],
            ownSessionID: id(1)
        ) { sessionID in
            sessionID == first ? 3 : 7
        }
        XCTAssertEqual(role.overseers.map(\.sessionID), [first, second])
        XCTAssertEqual(role.overseers.map(\.slot), [3, 7])
        XCTAssertNil(role.ownOverseerSlot)
        XCTAssertTrue(role.hasMark)
    }

    func testRoleBothRolesAndDuplicateIncarnationDedupes() {
        let me = id(1)
        let overseer = id(10)
        let role = AgentSessionOversightRole.make(
            inbound: [
                // Same overseer session projected through two incarnations stays one group.
                inbound(overseerSessionID: overseer, linkCreatedAt: Date(timeIntervalSince1970: 5)),
                inbound(overseerSessionID: overseer, linkCreatedAt: Date(timeIntervalSince1970: 9))
            ],
            outbound: [outbound(targetSessionID: id(20))],
            ownSessionID: me
        ) { $0 == me ? 0 : 2 }
        XCTAssertEqual(role.ownOverseerSlot, 0)
        XCTAssertEqual(role.overseers.count, 1)
        XCTAssertEqual(role.overseers.first?.slot, 2)
    }

    // MARK: - Palette

    func testPaletteWrapsAndContrastsWithTheSidebarBackground() {
        // Approximate sidebar backgrounds; a material backdrop only ever reduces contrast, so the
        // flat colours are the conservative bound.
        let lightBackground = NSColor(srgbRed: 0.925, green: 0.925, blue: 0.925, alpha: 1)
        let darkBackground = NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)

        for slot in 0 ..< AgentOversightPalette.slotCount {
            let light = AgentOversightPalette.resolvedColor(for: slot, darkAppearance: false)
            let dark = AgentOversightPalette.resolvedColor(for: slot, darkAppearance: true)
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(light, lightBackground), 3.0,
                "slot \(slot) light variant fails the non-text contrast floor"
            )
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(dark, darkBackground), 3.0,
                "slot \(slot) dark variant fails the non-text contrast floor"
            )
        }

        // Slots wrap rather than indexing past the palette.
        let first = AgentOversightPalette.resolvedColor(for: 0, darkAppearance: false)
        let wrapped = AgentOversightPalette.resolvedColor(
            for: AgentOversightPalette.slotCount,
            darkAppearance: false
        )
        XCTAssertEqual(first, wrapped)
    }

    /// WCAG relative-luminance contrast ratio.
    private static func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
            func linear(_ channel: CGFloat) -> Double {
                let c = Double(channel)
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(srgb.redComponent)
                + 0.7152 * linear(srgb.greenComponent)
                + 0.0722 * linear(srgb.blueComponent)
        }
        let bright = max(luminance(a), luminance(b))
        let dark = min(luminance(a), luminance(b))
        return (bright + 0.05) / (dark + 0.05)
    }
}
