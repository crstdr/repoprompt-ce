import AppKit
@testable import RepoPromptApp
import SwiftUI
import XCTest

/// The transcript's running-indicator slot keeps its height but does not build its native
/// indeterminate progress indicator while nothing is running.
@MainActor
final class AgentReservedIndicatorSlotTests: XCTestCase {
    func testHiddenSlotBuildsNoProgressIndicatorAndKeepsItsReservedHeight() {
        let hidden = hostSlot(isShown: false)
        let shown = hostSlot(isShown: true)
        defer {
            hidden.window.close()
            shown.window.close()
        }

        XCTAssertEqual(progressIndicatorCount(in: hidden.host), 0, "no native spinner while not shown")
        XCTAssertEqual(progressIndicatorCount(in: shown.host), 1, "positive control: the shown slot spins")
        XCTAssertEqual(hidden.host.fittingSize.height, Self.reservedHeight)
        XCTAssertEqual(shown.host.fittingSize.height, Self.reservedHeight)
    }

    // MARK: - Helpers

    private static let reservedHeight: CGFloat = 24

    private func hostSlot(isShown: Bool) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(
            AgentReservedIndicatorSlot(isShown: isShown, reservedHeight: Self.reservedHeight) {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Thinking…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 300)
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func progressIndicatorCount(in view: NSView) -> Int {
        (view is NSProgressIndicator ? 1 : 0) + view.subviews.reduce(0) { $0 + progressIndicatorCount(in: $1) }
    }
}
