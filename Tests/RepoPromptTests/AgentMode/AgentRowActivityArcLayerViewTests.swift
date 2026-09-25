import AppKit
import QuartzCore
@testable import RepoPromptApp
import SwiftUI
import XCTest

/// The running row's arc spins on the render server: a Core Animation rotation on its own shape
/// layer, not a SwiftUI `repeatForever` that re-renders the whole window every frame on main.
@MainActor
final class AgentRowActivityArcLayerViewTests: XCTestCase {
    func testVisibleRunningIndicatorSpinsWithARenderServerRotation() throws {
        let visible = hostIndicator(isWindowPresentationVisible: true)
        let hidden = hostIndicator(isWindowPresentationVisible: false)
        defer {
            visible.window.close()
            hidden.window.close()
        }

        let arcs = arcViews(in: visible.host)
        XCTAssertEqual(arcs.count, 1, "the visible running row renders the layer-backed arc")
        let arc = try XCTUnwrap(arcs.first)
        let rotation = try XCTUnwrap(
            arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey) as? CABasicAnimation,
            "the rotation is a Core Animation layer animation"
        )
        XCTAssertEqual(rotation.keyPath, "transform.rotation.z")
        XCTAssertEqual(rotation.repeatCount, .infinity)
        XCTAssertEqual(rotation.duration, 1.0)
        XCTAssertEqual(try XCTUnwrap(rotation.fromValue as? CGFloat), 0)
        XCTAssertEqual(try XCTUnwrap(rotation.toValue as? CGFloat), 2 * .pi, accuracy: 1e-9)
        XCTAssertEqual(rotation.timingFunction, CAMediaTimingFunction(name: .linear))
        XCTAssertFalse(rotation.isRemovedOnCompletion)

        XCTAssertTrue(arcViews(in: hidden.host).isEmpty, "a hidden window keeps no animation at all")
    }

    func testArcGeometryMatchesTheStillArc() {
        let arc = AgentRowActivityArcLayerView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        arc.layout()

        XCTAssertEqual(arc.intrinsicContentSize, NSSize(width: 15, height: 15))
        XCTAssertEqual(arc.arcLayer.frame, arc.bounds)
        XCTAssertEqual(arc.arcLayer.path?.boundingBox, CGRect(x: 0, y: 0, width: 15, height: 15))
        XCTAssertEqual(arc.arcLayer.strokeStart, 0)
        XCTAssertEqual(arc.arcLayer.strokeEnd, 0.7)
        XCTAssertEqual(arc.arcLayer.lineWidth, 1.5)
        XCTAssertEqual(arc.arcLayer.lineCap, .round)
        XCTAssertNil(arc.arcLayer.fillColor)
    }

    func testRotationStartsOnlyInAWindowOnceAndStopsWhenDetached() {
        let arc = AgentRowActivityArcLayerView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        arc.startAnimatingIfNeeded()
        XCTAssertNil(arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey))

        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(arc)
        let installed = arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey)
        XCTAssertNotNil(installed)
        arc.startAnimatingIfNeeded()
        XCTAssertTrue(
            arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey) === installed,
            "repeated updates keep the running rotation instead of restarting it"
        )

        arc.removeFromSuperview()
        XCTAssertNil(arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey))
    }

    func testTintIsStrokedAtTheStillArcOpacity() throws {
        let arc = AgentRowActivityArcLayerView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        arc.tint = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)

        let stroke = try XCTUnwrap(arc.arcLayer.strokeColor)
        XCTAssertEqual(stroke.alpha, 0.75, accuracy: 0.001)
        let components = try XCTUnwrap(try stroke.converted(
            to: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            intent: .defaultIntent,
            options: nil
        )?.components)
        XCTAssertEqual(components[0], 1, accuracy: 0.01)
        XCTAssertEqual(components[1], 0.5, accuracy: 0.01)
        XCTAssertEqual(components[2], 0, accuracy: 0.01)
    }

    // MARK: - Helpers

    private func hostIndicator(
        isWindowPresentationVisible: Bool
    ) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(
            AgentRowRunningIndicator()
                .environment(\.windowIsPresentationVisible, isWindowPresentationVisible)
        ))
        let window = makeWindow()
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func arcViews(in view: NSView) -> [AgentRowActivityArcLayerView] {
        let own: [AgentRowActivityArcLayerView] = (view as? AgentRowActivityArcLayerView).map { [$0] } ?? []
        return own + view.subviews.flatMap { arcViews(in: $0) }
    }
}
