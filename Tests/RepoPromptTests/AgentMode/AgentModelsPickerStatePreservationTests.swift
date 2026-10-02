import AppKit
import Combine
@testable import RepoPromptApp
import RepoPromptSecureStorage
import SwiftUI
import XCTest

@MainActor
final class AgentModelsPickerStatePreservationTests: XCTestCase {
    func testPickerActionPreservesDirtyOverlaysAndPersistsOnlyModelSelection() async throws {
        let store = try makeStore()
        let workspaceID = UUID()
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile(.gpt56SolLow))
        let window = makeWindow(store: store, workspaceID: workspaceID)
        await finishNotificationDelivery()
        let persistedCopy = try encoded(store.copySettings(for: workspaceID))
        let persistedChat = store.chatSettings(for: workspaceID)
        let dirty = try dirtyOverlays(window, workspaceID: workspaceID)

        var broadEvents = 0
        var scopedEvents = 0
        let broad = NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .filter { $0.userInfo?[AgentModelsSettingsNotification.sourceWorkspaceIDKey] as? UUID == workspaceID }
            .sink { _ in broadEvents += 1 }
        let scoped = NotificationCenter.default.publisher(for: .agentModelsSettingsDidChange)
            .filter { ($0.object as? GlobalSettingsStore) === store }
            .filter { $0.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID == workspaceID }
            .sink { _ in scopedEvents += 1 }
        defer { broad.cancel()
            scoped.cancel()
        }

        _ = NSApplication.shared // Establish AppKit's action dispatcher; do not launch a visible app.
        let view = AgentModelsPopoverView(promptViewModel: window.prompt, apiSettingsVM: window.api, windowID: -574)
        let menu = NSMenu.stableMenu(from: view.contextBuilderAgentModelMenuItems())
        let codexMenu = try XCTUnwrap(menu.items.first { $0.title == AgentProviderKind.codexExec.displayName }?.submenu)
        let option = try XCTUnwrap(window.prompt.contextBuilderModelOptions(for: .codexExec).first {
            $0.rawValue == AgentModel.gpt56SolHigh.rawValue
        })
        let item = try XCTUnwrap(actionItem(titled: option.displayName, in: codexMenu))
        let owner = try XCTUnwrap(item.menu)
        XCTAssertTrue(item.isEnabled)
        owner.performActionForItem(at: owner.index(of: item))
        await finishNotificationDelivery()

        XCTAssertEqual(broadEvents, 0, "A picker action is not a recommendation application.")
        XCTAssertGreaterThan(scopedEvents, 0)
        try assertOverlays(window, workspaceID: workspaceID, equal: dirty)
        XCTAssertEqual(window.prompt.contextBuilderAgentModelRaw, option.rawValue)
        XCTAssertTrue(store.reloadFromDisk(), "Verify the actual saved profile, not only its in-memory projection.")
        XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).contextBuilderModelsByAgent?[AgentProviderKind.codexExec.rawValue], option.rawValue)
        XCTAssertEqual(try encoded(store.copySettings(for: workspaceID)), persistedCopy)
        XCTAssertEqual(store.chatSettings(for: workspaceID), persistedChat)
    }

    func testExternalScopedUpdatesReachApplicableWindowsWithoutDiscardingOverlays() async throws {
        let store = try makeStore()
        store.setGlobalAgentModelsProfile(profile(.gpt56SolLow), contextBuilderWriteIntent: .userInitiated)
        let workspaceID = UUID()
        let unrelatedID = UUID()
        let inheritedID = UUID()
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile(.gpt56SolLow))
        store.setWorkspaceAgentModelsProfile(workspaceID: unrelatedID, profile: profile(.gpt56SolLow))
        let first = makeWindow(store: store, workspaceID: workspaceID)
        let second = makeWindow(store: store, workspaceID: workspaceID)
        let unrelated = makeWindow(store: store, workspaceID: unrelatedID)
        let inherited = makeWindow(store: store, workspaceID: inheritedID)
        let windows = [(first, workspaceID), (second, workspaceID), (unrelated, unrelatedID), (inherited, inheritedID)]
        await finishNotificationDelivery()
        let dirty = try windows.map { try dirtyOverlays($0.0, workspaceID: $0.1) }

        // An external writer changes the shared authority, not either PromptVM.
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile(.gpt56SolHigh))
        await finishNotificationDelivery()
        XCTAssertEqual(first.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolHigh.rawValue)
        XCTAssertEqual(second.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolHigh.rawValue)
        XCTAssertEqual(unrelated.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolLow.rawValue)
        XCTAssertEqual(inherited.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolLow.rawValue)

        store.setGlobalAgentModelsProfile(profile(.gpt56SolMedium), contextBuilderWriteIntent: .userInitiated)
        await finishNotificationDelivery()
        XCTAssertEqual(inherited.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolMedium.rawValue)
        XCTAssertEqual(first.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolHigh.rawValue)
        XCTAssertEqual(second.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolHigh.rawValue)
        XCTAssertEqual(unrelated.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolLow.rawValue)
        for (index, entry) in windows.enumerated() {
            try assertOverlays(entry.0, workspaceID: entry.1, equal: dirty[index])
        }
    }

    func testRecommendationApplyStillRefreshesMatchingWorkspaceOnly() async throws {
        let store = try makeStore()
        let workspaceID = UUID()
        let unrelatedID = UUID()
        let first = makeWindow(store: store, workspaceID: workspaceID)
        let second = makeWindow(store: store, workspaceID: workspaceID)
        let unrelated = makeWindow(store: store, workspaceID: unrelatedID)
        await finishNotificationDelivery()
        _ = try dirtyOverlays(first, workspaceID: workspaceID)
        _ = try dirtyOverlays(second, workspaceID: workspaceID)
        let unrelatedDirty = try dirtyOverlays(unrelated, workspaceID: unrelatedID)

        var copy = store.copySettings(for: workspaceID)
        copy.fileTreeOption = .none
        store.updateCopySettings(copy)
        var chat = store.chatSettings(for: workspaceID)
        chat.fileTreeOption = .none
        chat.proFileEdits = false
        store.updateChatSettings(chat)
        RecommendationApplyNotification.post(
            sourceWorkspaceID: workspaceID,
            agentModelsScope: .workspace(workspaceID),
            includesPresetExposure: false
        )
        await finishNotificationDelivery()

        for window in [first, second] {
            XCTAssertEqual(try encoded(window.settings.copySettings(for: workspaceID)), try encoded(copy))
            XCTAssertEqual(window.settings.chatSettings(for: workspaceID), chat)
            XCTAssertEqual(window.prompt.fileTreeOption, .none)
        }
        try assertOverlays(unrelated, workspaceID: unrelatedID, equal: unrelatedDirty)
    }

    private struct Window {
        let prompt: PromptViewModel
        let settings: WindowSettingsManager
        let api: APISettingsViewModel
    }

    private func makeStore() throws -> GlobalSettingsStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentModelsPicker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AgentModelsPicker.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json")))
    }

    private func makeWindow(store: GlobalSettingsStore, workspaceID: UUID) -> Window {
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let queries = AIQueriesService(keyManager: keys)
        let api = APISettingsViewModel(aiQueriesService: queries, keyManager: keys, loadStoredDataOnInit: false)
        api.isCodexConnected = true
        api.test_completeContextBuilderProviderValidation(verifiedProviders: [.codexExec])
        addTeardownBlock { @MainActor in api.prepareForWindowClose() }
        let files = WorkspaceFilesViewModel()
        files.setCurrentWorkspaceID(workspaceID)
        let settings = WindowSettingsManager(windowID: -574, store: store)
        let prompt = PromptViewModel(fileManager: files, aiQueriesService: queries, apiSettingsViewModel: api, windowID: -574, settingsManager: settings, refreshAvailableModelsOnInit: false)
        return Window(prompt: prompt, settings: settings, api: api)
    }

    private func profile(_ model: AgentModel) -> AgentModelsSettingsProfile {
        AgentModelsSettingsProfile(contextBuilderAgentRaw: AgentProviderKind.codexExec.rawValue, contextBuilderModelsByAgent: [AgentProviderKind.codexExec.rawValue: model.rawValue])
    }

    private func dirtyOverlays(_ window: Window, workspaceID: UUID) throws -> (Data, ChatGlobalSettings) {
        var copy = window.settings.copySettings(for: workspaceID)
        copy.fileTreeOption = .files
        window.settings.updateCopySettings(copy, commit: false)
        var chat = window.settings.chatSettings(for: workspaceID)
        chat.fileTreeOption = .files
        chat.proFileEdits = true
        window.settings.updateChatSettings(chat, commit: false)
        return try (encoded(copy), chat)
    }

    private func assertOverlays(_ window: Window, workspaceID: UUID, equal expected: (Data, ChatGlobalSettings), file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try encoded(window.settings.copySettings(for: workspaceID)), expected.0, file: file, line: line)
        XCTAssertEqual(window.settings.chatSettings(for: workspaceID), expected.1, file: file, line: line)
    }

    private func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private func actionItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title, item.action != nil {
                return item
            }
            if let submenu = item.submenu, let match = actionItem(titled: title, in: submenu) {
                return match
            }
        }
        return nil
    }

    private func finishNotificationDelivery() async {
        // The old picker scheduled its broad post on the main queue; subscribers then
        // scheduled delivery there too. Two FIFO barriers cover both hops, without sleeps.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// Lifecycle contract of the window-scoped `StableMenuPresenter`: the presented `NSMenu`
/// is screen-anchored and owned outside the trigger's view state, so tearing down
/// the hosted `StableMenuButton` mid-track must not dismiss it — that was the
/// sidebar oversight menu's disappearing-list defect. Closing the presenting
/// window must still release the menu so a gone window cannot orphan it.
@MainActor
final class StableMenuLifetimeTests: XCTestCase {
    private struct TriggerRow: View {
        let showsTrigger: Bool
        var body: some View {
            if showsTrigger {
                StableMenuButton(
                    items: { [.action("Pinned") {}] },
                    label: { Text("Trigger") }
                )
            }
        }
    }

    private var window: NSWindow!
    private var hosting: NSHostingView<TriggerRow>!
    private var trackedMenu: NSMenu?
    /// Whether `openMenu` was released while tracking — observed on a runloop beat
    /// after the teardown, so it reflects mid-track release, not `present`'s
    /// post-`popUp` cleanup.
    private var releasedDuringTracking = false
    /// Whether the post-teardown observation actually ran. If teardown ends
    /// tracking early, `popUp` returns before the verify timer fires — requiring
    /// this flag keeps an early dismissal from satisfying the survival asserts.
    private var observationCompleted = false
    private var teardownOnOpen: (() -> Void)?
    private var teardownAtGrace = false
    private var pendingTimers: [Timer] = []

    override func tearDown() {
        pendingTimers.forEach { $0.invalidate() }
        pendingTimers = []
        teardownOnOpen = nil
        trackedMenu = nil
        hosting = nil
        window = nil
        super.tearDown()
    }

    private func schedule(_ interval: TimeInterval, selector: Selector) {
        let timer = Timer(
            timeInterval: interval, target: self,
            selector: selector, userInfo: nil, repeats: false
        )
        pendingTimers.append(timer)
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The button's `.background` anchor is the only bare `NSView` in the hosted tree.
    private func findAnchor(in view: NSView) -> NSView? {
        if type(of: view) == NSView.self {
            return view
        }
        for subview in view.subviews {
            if let found = findAnchor(in: subview) {
                return found
            }
        }
        return nil
    }

    @objc private func menuBeganTracking(_ note: Notification) {
        MainActor.assumeIsolated {
            guard let menu = note.object as? NSMenu,
                  menu === window.stableMenuPresenter.openMenu
            else { return }
            trackedMenu = menu
            if !teardownAtGrace {
                teardownOnOpen?()
            }
            schedule(0.1, selector: #selector(graceElapsed(_:)))
        }
    }

    /// Fires on the next common-mode beat after teardown so the assertion reads the
    /// post-teardown tracking state rather than cleanup inside `present`. The
    /// fallback `cancelTracking` keeps `popUp` from hanging if a teardown did not
    /// end tracking.
    @objc private func graceElapsed(_: Timer) {
        MainActor.assumeIsolated {
            if teardownAtGrace {
                teardownOnOpen?()
                schedule(0.05, selector: #selector(verifiedAfterTeardown(_:)))
            } else {
                finishTrackingObservation()
            }
        }
    }

    @objc private func verifiedAfterTeardown(_: Timer) {
        MainActor.assumeIsolated {
            finishTrackingObservation()
        }
    }

    private func finishTrackingObservation() {
        releasedDuringTracking = window.stableMenuPresenter.openMenu == nil
        observationCompleted = true
        window.stableMenuPresenter.openMenu?.cancelTracking()
    }

    /// Hosts the trigger, presents through the shared presenter at the mounted
    /// anchor, and runs `teardown` once tracking begins. `popUp` is synchronous, so
    /// all state is settled when it returns.
    private func presentHostedMenu(atGrace: Bool = false, teardown: @escaping () -> Void) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: TriggerRow(showsTrigger: true))
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        defer { window.close() }

        guard let anchor = findAnchor(in: hosting) else {
            XCTFail("StableMenuAnchorView did not mount a backing NSView")
            return
        }
        teardownOnOpen = teardown
        teardownAtGrace = atGrace
        defer { teardownOnOpen = nil }
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuBeganTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil
        )
        defer { NotificationCenter.default.removeObserver(self) }

        window.stableMenuPresenter.present([.action("Pinned") {}], from: anchor)
    }

    func testPresentedMenuSurvivesTriggerUnmount() {
        _ = NSApplication.shared
        presentHostedMenu { [self] in
            // The sidebar invalidation analogue: the conditional gate flips and the
            // whole `StableMenuButton` subtree (anchor view and view-scoped state)
            // is dismantled while its menu is tracking.
            hosting.rootView = TriggerRow(showsTrigger: false)
            hosting.layoutSubtreeIfNeeded()
        }
        XCTAssertNotNil(trackedMenu, "presented menu never began tracking")
        XCTAssertTrue(
            observationCompleted,
            "observation must run inside tracking — an early teardown-induced close cannot satisfy the survival assert"
        )
        XCTAssertFalse(
            releasedDuringTracking,
            "menu tracking was cancelled when the trigger subtree unmounted"
        )
        XCTAssertNil(window.stableMenuPresenter.openMenu)
    }

    func testPresentedMenuClosesWithWindow() {
        _ = NSApplication.shared
        presentHostedMenu(atGrace: true) { [self] in
            // Closing the presenting window posts `willClose`; driving the
            // notification directly exercises the same cancellation path without
            // destroying a window inside AppKit's tracking loop.
            NotificationCenter.default.post(
                name: NSWindow.willCloseNotification, object: window
            )
        }
        XCTAssertNotNil(trackedMenu, "presented menu never began tracking")
        XCTAssertTrue(
            observationCompleted,
            "observation must run inside tracking — an early close cannot satisfy the mid-track release assert"
        )
        XCTAssertTrue(
            releasedDuringTracking,
            "window close must release the menu mid-track, not only at popUp return"
        )
        XCTAssertNil(window.stableMenuPresenter.openMenu)
    }
}

/// `StableMenuContextRegion` is the row's right-click path: it presents through the
/// window-scoped presenter, so a re-render of the hosting row must not tear down the
/// open context menu (the regression Cristian reported with SwiftUI `.contextMenu`,
/// reproduced red as `testContextMenuSurvivesRowRerender` before the conversion).
@MainActor
final class StableMenuContextMenuTests: XCTestCase {
    private struct RegionRow: View {
        let tick: Int
        var body: some View {
            Text("row \(tick)")
                .frame(width: 160, height: 40)
                .overlay(StableMenuContextRegion(anchor: StableMenuAnchor()) {
                    [.action("Pinned") {}]
                })
        }
    }

    private var window: NSWindow!
    private var hosting: NSHostingView<RegionRow>!
    private var trackedMenu: NSMenu?
    private var sawEnd = false
    private var endedByTeardown = false
    private var teardownOnOpen: (() -> Void)?
    private var teardownAtGrace = false
    private var pendingTimers: [Timer] = []

    override func tearDown() {
        pendingTimers.forEach { $0.invalidate() }
        pendingTimers = []
        teardownOnOpen = nil
        trackedMenu = nil
        hosting = nil
        window = nil
        super.tearDown()
    }

    private func schedule(_ interval: TimeInterval, selector: Selector) {
        let timer = Timer(
            timeInterval: interval, target: self,
            selector: selector, userInfo: nil, repeats: false
        )
        pendingTimers.append(timer)
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func began(_ note: Notification) {
        MainActor.assumeIsolated {
            guard let menu = note.object as? NSMenu,
                  menu === window.stableMenuPresenter.openMenu
            else { return }
            trackedMenu = menu
            if !teardownAtGrace {
                teardownOnOpen?()
            }
            schedule(0.1, selector: #selector(graceElapsed(_:)))
        }
    }

    @objc private func ended(_ note: Notification) {
        MainActor.assumeIsolated {
            if let trackedMenu, (note.object as? NSMenu) === trackedMenu {
                sawEnd = true
            }
        }
    }

    @objc private func graceElapsed(_: Timer) {
        MainActor.assumeIsolated {
            if teardownAtGrace {
                teardownOnOpen?()
                schedule(0.05, selector: #selector(verifiedAfterTeardown(_:)))
            } else {
                finishObservation()
            }
        }
    }

    @objc private func verifiedAfterTeardown(_: Timer) {
        MainActor.assumeIsolated {
            finishObservation()
        }
    }

    private var finished = false

    /// Records whether AppKit already ended tracking before our cleanup cancels it —
    /// that is the teardown signal; asserting `sawEnd` after `cancelTracking` would be
    /// contaminated by our own dismissal.
    private func finishObservation() {
        endedByTeardown = sawEnd || window.stableMenuPresenter.openMenu == nil
        window.stableMenuPresenter.openMenu?.cancelTracking()
        finished = true
    }

    /// Sends a right-click into the hosted row region. The region consumes the down
    /// event in its monitor and presents on the next main-queue turn; `popUp` then
    /// blocks until tracking ends, so teardown runs from inside the tracking
    /// callbacks and the loop below only drives the runloop until tracking settles.
    private func rightClickRow(atGrace: Bool = false, teardown: @escaping () -> Void) {
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: RegionRow(tick: 0))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        defer { window.close() }

        teardownOnOpen = teardown
        teardownAtGrace = atGrace
        defer { teardownOnOpen = nil }
        NotificationCenter.default.addObserver(
            self, selector: #selector(began(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(ended(_:)),
            name: NSMenu.didEndTrackingNotification, object: nil
        )
        defer { NotificationCenter.default.removeObserver(self) }

        let point = NSPoint(x: 100, y: 30)
        guard let down = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ), let up = NSEvent.mouseEvent(
            with: .rightMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ) else {
            XCTFail("could not synthesize right-click events")
            return
        }
        NSApp.sendEvent(down)
        NSApp.sendEvent(up)

        let deadline = Date().addingTimeInterval(3)
        while !finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// The reproduction's contract on the converted path: re-rendering the host row
    /// mid-track must not tear down the open context menu. (The SwiftUI `.contextMenu`
    /// variant of this scenario — `testContextMenuSurvivesRowRerender`, run during
    /// development — went red before the conversion.)
    func testContextMenuSurvivesHostRerender() {
        _ = NSApplication.shared
        rightClickRow { [self] in
            hosting.rootView = RegionRow(tick: 1)
        }
        XCTAssertNotNil(trackedMenu, "context menu never began tracking")
        XCTAssertFalse(endedByTeardown, "open context menu was torn down by the row re-render")
    }

    func testContextMenuClosesWithWindow() {
        _ = NSApplication.shared
        rightClickRow(atGrace: true) { [self] in
            NotificationCenter.default.post(
                name: NSWindow.willCloseNotification, object: window
            )
        }
        XCTAssertNotNil(trackedMenu, "context menu never began tracking")
        XCTAssertTrue(
            endedByTeardown,
            "window close must release the presented context menu mid-track"
        )
        XCTAssertNil(window.stableMenuPresenter.openMenu)
    }
}
