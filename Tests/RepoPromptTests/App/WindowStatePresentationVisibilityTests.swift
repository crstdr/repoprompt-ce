import AppKit
@testable import RepoPromptApp
import RepoPromptSettingsCore
import SwiftUI
import XCTest

/// `WindowState.isPresentationVisible` follows the attached window's on-screen presentation and
/// nothing else; the rows' activity arc stops animating whenever it is false or Reduce Motion is on.
@MainActor
final class WindowStatePresentationVisibilityTests: XCTestCase {
    private final class SampleBox {
        var visible = true
    }

    func testSignalFollowsOcclusionMiniaturizeAndAppHideForTheAttachedWindowOnly() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }

        let state = WindowState()
        let sample = SampleBox()
        state.presentationVisibilitySampler = { _ in sample.visible }
        let window = makeTestWindow()
        let otherWindow = makeTestWindow()

        sample.visible = false
        state.attachWindow(window)
        try await waitForVisibility(state, false, "sampled on attach")

        let transitions: [(Notification.Name, AnyObject, Bool)] = [
            (NSWindow.didChangeOcclusionStateNotification, window, true),
            (NSWindow.didChangeOcclusionStateNotification, window, false),
            (NSWindow.didDeminiaturizeNotification, window, true),
            (NSWindow.didMiniaturizeNotification, window, false),
            (NSApplication.didUnhideNotification, NSApplication.shared, true),
            (NSApplication.didHideNotification, NSApplication.shared, false)
        ]
        for (name, object, expected) in transitions {
            sample.visible = expected
            NotificationCenter.default.post(name: name, object: object)
            try await waitForVisibility(state, expected, name.rawValue)
        }

        // Another window's occlusion change is not this window's business.
        sample.visible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: otherWindow)
        await settle()
        XCTAssertFalse(state.isPresentationVisible)

        // Detaching restores the unknown-is-visible default and stops observing the old window.
        state.attachWindow(nil)
        try await waitForVisibility(state, true, "detach default")
        sample.visible = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await settle()
        XCTAssertTrue(state.isPresentationVisible)

        state.beginClose()
        await state.tearDown()
    }

    func testCloseStopsObservingPresentationVisibility() async throws {
        #if DEBUG
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }

            let state = WindowState()
            state.presentationVisibilitySampler = { _ in true }
            let window = makeTestWindow()
            state.attachWindow(window)
            XCTAssertEqual(
                state.debugPresentationVisibilityObserverCount,
                WindowPresentationVisibility.windowNotifications.count
                    + WindowPresentationVisibility.applicationNotifications.count
            )

            // Close tears the observers down with the focus observers, before async teardown.
            state.beginClose()
            XCTAssertEqual(state.debugPresentationVisibilityObserverCount, 0)
            await state.tearDown()
        #else
            throw XCTSkip("Requires the DEBUG observer count.")
        #endif
    }

    /// A deferred WindowAccessor callback can deliver the first attach after `beginClose()` has
    /// already run. Because `beginClose` is idempotent, observers installed by that late attach would
    /// never be removed; the closed state must refuse the attach instead.
    func testLateAttachAfterBeginCloseInstallsNoPresentationObservers() async throws {
        #if DEBUG
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }

            let state = WindowState()
            state.presentationVisibilitySampler = { _ in true }
            state.beginClose()
            state.attachWindow(makeTestWindow())
            XCTAssertEqual(state.debugPresentationVisibilityObserverCount, 0)
            await state.tearDown()
        #else
            throw XCTSkip("Requires the DEBUG observer count.")
        #endif
    }

    func testPresentationPredicateRequiresEveryOnScreenCondition() {
        XCTAssertTrue(WindowPresentationVisibility.isVisible(
            windowIsVisible: true, isMiniaturized: false, occlusionIsVisible: true, appIsHidden: false
        ))
        XCTAssertFalse(WindowPresentationVisibility.isVisible(
            windowIsVisible: false, isMiniaturized: false, occlusionIsVisible: true, appIsHidden: false
        ))
        XCTAssertFalse(WindowPresentationVisibility.isVisible(
            windowIsVisible: true, isMiniaturized: true, occlusionIsVisible: true, appIsHidden: false
        ))
        XCTAssertFalse(WindowPresentationVisibility.isVisible(
            windowIsVisible: true, isMiniaturized: false, occlusionIsVisible: false, appIsHidden: false
        ))
        XCTAssertFalse(WindowPresentationVisibility.isVisible(
            windowIsVisible: true, isMiniaturized: false, occlusionIsVisible: true, appIsHidden: true
        ))
    }

    /// Hidden and visible presentations use the same layer-backed arc and shared Running label;
    /// both take the same 15 pt frame, so the visibility transition cannot change
    /// layout or what VoiceOver announces. SwiftUI does not materialize its accessibility tree for an
    /// off-screen test host, so the label is pinned through the shared constant; the layout is
    /// measured in a real hosting view.
    func testStillAndAnimatedRunningIndicatorsShareFrameAndAccessibilityLabel() {
        let visible = hostIndicator(isWindowPresentationVisible: true)
        let hidden = hostIndicator(isWindowPresentationVisible: false)
        defer {
            visible.window.close()
            hidden.window.close()
        }

        XCTAssertEqual(visible.host.fittingSize, hidden.host.fittingSize)
        XCTAssertEqual(visible.host.fittingSize, NSSize(width: 15, height: 15))
        XCTAssertEqual(AgentRowRunningIndicator.accessibilityLabelText, "Running")
    }

    // MARK: - Helpers

    private func hostIndicator(
        isWindowPresentationVisible: Bool
    ) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(
            AgentRowRunningIndicator()
                .environment(\.windowIsPresentationVisible, isWindowPresentationVisible)
        ))
        let window = makeTestWindow()
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func waitForVisibility(
        _ state: WindowState,
        _ expected: Bool,
        _ description: String
    ) async throws {
        try await AsyncTestWait.waitUntil("presentation visibility \(expected) after \(description)") {
            await MainActor.run { state.isPresentationVisible == expected }
        }
    }

    private func settle() async {
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func makeTestWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
