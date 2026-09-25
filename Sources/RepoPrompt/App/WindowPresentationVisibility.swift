import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Whether the hosting window is currently presented on screen: visible, not miniaturized, not
    /// fully occluded (including another Space), and its app not hidden.
    ///
    /// Presentation-only. It exists so purely decorative, continuously running animations can stop
    /// while nobody can see them; it must never gate execution, persistence, or model publication.
    /// Defaults to `true` so a view outside a tracked window keeps its existing behavior.
    @Entry var windowIsPresentationVisible: Bool = true
}

/// Samples whether a window is presented on screen, for `WindowState.isPresentationVisible`.
enum WindowPresentationVisibility {
    /// Window notifications after which the sample can change.
    static let windowNotifications: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification
    ]

    /// Application notifications after which the sample can change.
    static let applicationNotifications: [Notification.Name] = [
        NSApplication.didHideNotification,
        NSApplication.didUnhideNotification
    ]

    static func isVisible(
        windowIsVisible: Bool,
        isMiniaturized: Bool,
        occlusionIsVisible: Bool,
        appIsHidden: Bool
    ) -> Bool {
        windowIsVisible && !isMiniaturized && occlusionIsVisible && !appIsHidden
    }

    @MainActor
    static func sample(_ window: NSWindow) -> Bool {
        isVisible(
            windowIsVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            occlusionIsVisible: window.occlusionState.contains(.visible),
            appIsHidden: NSApplication.shared.isHidden
        )
    }
}
