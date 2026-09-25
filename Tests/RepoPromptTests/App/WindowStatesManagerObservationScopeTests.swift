import Combine
@testable import RepoPromptApp
import SwiftUI
import XCTest

/// Guards the observation scope of the process-wide `WindowStatesManager`.
///
/// Every `objectWillChange` from the manager invalidates each view that observes it. Window roots
/// and menu commands only need the manager inside callbacks/actions, so observing it made every
/// window open/close re-evaluate all ~W window roots and the App commands.
@MainActor
final class WindowStatesManagerObservationScopeTests: XCTestCase {
    func testObservingWrapperDetectionFindsManagerSubscriptions() {
        // Positive control so the structural assertions below cannot pass vacuously.
        let probe = ObservingProbe(manager: WindowStatesManager.shared)
        XCTAssertEqual(observingManagerWrapperLabels(in: probe), ["_manager"])
    }

    func testWindowRootDoesNotObserveWindowStatesManager() {
        XCTAssertEqual(observingManagerWrapperLabels(in: WindowContentView()), [])
    }

    func testWorkspaceCommandsDoNotObserveWindowStatesManager() {
        let commands = WorkspaceCommands(windowStatesManager: WindowStatesManager.shared)
        XCTAssertEqual(observingManagerWrapperLabels(in: commands), [])
    }

    func testRegisteringWindowPublishesManagerChangeOnce() async {
        let manager = WindowStatesManager.shared
        XCTAssertTrue(manager.pendingURLs.isEmpty, "Precondition: no queued deep links to drain")

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        let emissions = EmissionCounter()
        let subscription = manager.objectWillChange.sink { _ in emissions.count += 1 }

        manager.registerWindowState(window)

        subscription.cancel()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        XCTAssertEqual(
            emissions.count,
            1,
            "Registering one window should publish exactly one manager change (the allWindows append)"
        )

        window.beginClose()
        await window.tearDown()
        manager.unregisterWindowState(window)
    }

    private func observingManagerWrapperLabels(in subject: Any) -> [String] {
        let observingPrefixes = ["SwiftUI.EnvironmentObject<", "SwiftUI.ObservedObject<", "SwiftUI.StateObject<"]
        return Mirror(reflecting: subject).children.compactMap { child in
            let typeName = String(reflecting: type(of: child.value))
            guard observingPrefixes.contains(where: { typeName.hasPrefix($0) }),
                  typeName.contains("WindowStatesManager")
            else { return nil }
            return child.label ?? typeName
        }
    }

    private struct ObservingProbe {
        @ObservedObject var manager: WindowStatesManager
    }

    private final class EmissionCounter {
        var count = 0
    }
}
