import AppKit

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
