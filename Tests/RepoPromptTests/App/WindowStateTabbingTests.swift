import AppKit
import Combine
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class WindowStateTabbingTests: XCTestCase {
    func testAttachedMainWindowsShareAutomaticTabbingIdentity() async {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }

        let firstState = WindowState()
        let secondState = WindowState()
        let firstWindow = makeTestWindow()
        let secondWindow = makeTestWindow()
        firstWindow.tabbingMode = .disallowed
        secondWindow.tabbingMode = .disallowed
        firstWindow.tabbingIdentifier = "test.first"
        secondWindow.tabbingIdentifier = "test.second"

        firstState.attachWindow(firstWindow)
        secondState.attachWindow(secondWindow)

        XCTAssertEqual(firstWindow.tabbingMode, .automatic)
        XCTAssertEqual(secondWindow.tabbingMode, .automatic)
        XCTAssertFalse(firstWindow.tabbingIdentifier.isEmpty)
        XCTAssertEqual(firstWindow.tabbingIdentifier, secondWindow.tabbingIdentifier)

        firstState.attachWindow(nil)
        secondState.attachWindow(nil)
        firstState.beginClose()
        secondState.beginClose()
        await firstState.tearDown()
        await secondState.tearDown()
    }

    private func makeTestWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }
}

#if DEBUG
    @MainActor
    final class WindowGitPollingLifecycleTests: XCTestCase {
        private var originalAutoStart: Bool?
        private var originalGitMode: String?
        private var windows: [WindowState] = []

        override func setUp() async throws {
            try await super.setUp()
            guard ProcessInfo.processInfo.environment["REPOPROMPT_TEST_SANDBOX_ROOT"] != nil else {
                throw XCTSkip("Requires the isolated test sandbox (run via ./conductor test)")
            }
            originalAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            originalGitMode = UserDefaults.standard.string(forKey: "gitDiffInclusionMode")
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        }

        override func tearDown() async throws {
            for state in windows {
                state.attachWindow(nil)
                state.beginClose()
                await state.tearDown()
            }
            windows.removeAll()
            if let originalAutoStart {
                GlobalSettingsStore.shared.setMCPAutoStart(originalAutoStart, commit: false)
                if let originalGitMode {
                    UserDefaults.standard.set(originalGitMode, forKey: "gitDiffInclusionMode")
                } else {
                    UserDefaults.standard.removeObject(forKey: "gitDiffInclusionMode")
                }
            }
            try await super.tearDown()
        }

        func testClosingWindowStopsStatusPollingAndRejectsLateRefreshes() async throws {
            let firstWait = expectation(description: "Open window awaits its first poll")
            let secondWait = expectation(description: "Open window refreshes and awaits its second poll")
            let clock = PollClock(waits: [firstWait, secondWait])
            let (state, window, actor) = await openPollingWindow(clock: clock)
            await fulfillment(of: [firstWait], timeout: 2)
            let initialSnapshot = await actor.test_latestSnapshot
            let initial = try XCTUnwrap(initialSnapshot)

            await clock.advance()
            await fulfillment(of: [secondWait], timeout: 2)
            let beforeCloseSnapshot = await actor.test_latestSnapshot
            let beforeClose = try XCTUnwrap(beforeCloseSnapshot)
            XCTAssertEqual(beforeClose.generation, initial.generation + 1)

            await close(state)
            let hasPollerAfterClose = await actor.test_hasPollingTask
            XCTAssertFalse(hasPollerAfterClose)

            // Exercise late observer/root work as well as a tick after the close boundary.
            await clock.advance()
            await actor.setInclusionMode(.none)
            await actor.setInclusionMode(.all)
            await actor.setSelectedRoot("/closed-window-root")
            await actor.restartPollingIfNeeded()
            let lateRefresh = await actor.refresh(trigger: .explicitRefresh)
            let afterClose = await actor.test_latestSnapshot
            let hasRestartedPoller = await actor.test_hasPollingTask
            let waits = await clock.waitCount
            XCTAssertNil(lateRefresh)
            XCTAssertEqual(afterClose?.generation, beforeClose.generation)
            XCTAssertFalse(hasRestartedPoller)
            XCTAssertEqual(waits, 2)
            await actor.shutdown() // Also clean up when exercising a deliberately broken close path.
            withExtendedLifetime(window) {}
        }

        func testReopeningWindowStartsANewStatusPollerWithoutRevivingClosedWindow() async throws {
            let closedWait = expectation(description: "First window polls")
            let closedClock = PollClock(waits: [closedWait])
            let (closedState, closedWindow, closedActor) = await openPollingWindow(clock: closedClock)
            await fulfillment(of: [closedWait], timeout: 2)
            let closedSnapshot = await closedActor.test_latestSnapshot
            let closedGeneration = try XCTUnwrap(closedSnapshot).generation
            await close(closedState)

            let firstWait = expectation(description: "Reopened window awaits a poll")
            let secondWait = expectation(description: "Reopened window refreshes and keeps polling")
            let reopenedClock = PollClock(waits: [firstWait, secondWait])
            let (reopenedState, reopenedWindow, reopenedActor) = await openPollingWindow(clock: reopenedClock)
            await fulfillment(of: [firstWait], timeout: 2)
            let initialSnapshot = await reopenedActor.test_latestSnapshot
            let initial = try XCTUnwrap(initialSnapshot)
            await reopenedClock.advance()
            await fulfillment(of: [secondWait], timeout: 2)
            let refreshed = await reopenedActor.test_latestSnapshot
            let reopenedHasPoller = await reopenedActor.test_hasPollingTask
            let closedHasPoller = await closedActor.test_hasPollingTask
            let afterReopen = await closedActor.test_latestSnapshot
            XCTAssertEqual(refreshed?.generation, initial.generation + 1)
            XCTAssertTrue(reopenedHasPoller)
            XCTAssertFalse(closedHasPoller)
            XCTAssertEqual(afterReopen?.generation, closedGeneration)
            await closedActor.shutdown()

            await close(reopenedState)
            withExtendedLifetime((closedWindow, reopenedWindow)) {}
        }

        private func openPollingWindow(clock: PollClock) async -> (WindowState, NSWindow, GitStatusActor) {
            UserDefaults.standard.set(GitDiffInclusionMode.none.rawValue, forKey: "gitDiffInclusionMode")
            let state = WindowState()
            windows.append(state)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            state.attachWindow(window)
            let actor = state.promptManager.gitViewModel.test_statusActor
            await actor.test_setPollingWait { try await clock.sleep() }
            // No repository is needed: the real refresh still publishes a generation on every tick.
            state.promptManager.gitViewModel.gitDiffInclusionMode = .all
            await actor.setInclusionMode(.all)
            return (state, window, actor)
        }

        private func close(_ state: WindowState) async {
            state.attachWindow(nil)
            state.beginClose()
            await state.tearDown()
            windows.removeAll { $0 === state }
        }

        private actor PollClock {
            private let waits: [XCTestExpectation]
            private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
            private(set) var waitCount = 0

            init(waits: [XCTestExpectation]) {
                self.waits = waits
            }

            func sleep() async throws {
                let id = UUID()
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            sleepers[id] = continuation
                            waitCount += 1
                            if waitCount <= waits.count { waits[waitCount - 1].fulfill() }
                        }
                    }
                } onCancel: {
                    Task { await self.cancel(id) }
                }
            }

            func advance() {
                let pending = sleepers
                sleepers.removeAll()
                pending.values.forEach { $0.resume() }
            }

            private func cancel(_ id: UUID) {
                sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }
#endif

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

    func testRegisteringWindowPublishesManagerChangeOnce() async throws {
        // Registration and unregistration persist the window session to Application Support. Only run
        // where the coordinated test runner has redirected HOME to a disposable sandbox, so a direct
        // `swift test` or Xcode run can never overwrite the user's real windowSessions.json.
        guard let sandboxRoot = ProcessInfo.processInfo.environment["REPOPROMPT_TEST_SANDBOX_ROOT"] else {
            throw XCTSkip("Requires the isolated test sandbox (run via ./conductor test)")
        }
        try XCTSkipUnless(
            WindowSessionStore.sessionFileURL().resolvingSymlinksInPath().path
                .hasPrefix(URL(fileURLWithPath: sandboxRoot).resolvingSymlinksInPath().path + "/"),
            "Window session storage is not redirected into the test sandbox"
        )

        let manager = WindowStatesManager.shared
        guard manager.pendingURLs.isEmpty else {
            return XCTFail("Precondition: no queued deep links to drain before registering")
        }

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
