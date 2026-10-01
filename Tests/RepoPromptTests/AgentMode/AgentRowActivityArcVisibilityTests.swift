import AppKit
import QuartzCore
@testable import RepoPromptApp
import XCTest

/// Tests the real CALayer playback boundary without creating a window or hosting SwiftUI.
@MainActor
final class AgentRowActivityArcVisibilityTests: XCTestCase {
    func testHidingStopsRotationAndShowingRestartsOnlyWhileAttached() throws {
        let arc = AgentRowActivityArcLayerView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        arc.updateAnimation(isAttachedToWindow: true)
        let rotation = try XCTUnwrap(arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey))
        arc.updateAnimation(isAttachedToWindow: true)
        XCTAssertTrue(arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey) === rotation)

        arc.isPresentationVisible = false
        arc.updateAnimation(isAttachedToWindow: true)
        XCTAssertNil(arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey))
        XCTAssertEqual(arc.arcLayer.strokeEnd, 0.7, "the same arc remains visible, standing still")
        XCTAssertEqual(arc.intrinsicContentSize, NSSize(width: 15, height: 15))

        arc.isPresentationVisible = true
        arc.updateAnimation(isAttachedToWindow: false)
        XCTAssertNil(arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey))
        arc.updateAnimation(isAttachedToWindow: true)
        let resumed = try XCTUnwrap(
            arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey) as? CABasicAnimation
        )
        XCTAssertEqual(resumed.keyPath, "transform.rotation.z")
        XCTAssertEqual(resumed.duration, 1)
        XCTAssertEqual(resumed.repeatCount, .infinity)
        arc.updateAnimation(isAttachedToWindow: false)
        XCTAssertNil(arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey))
    }
}
