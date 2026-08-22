import AppKit
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class WindowStateDisplayedTitleTests: XCTestCase {
    func testOverseerPrefixUsesTextPresentationScalarSequence() {
        XCTAssertEqual(
            WindowTitleFormatter.overseerPrefix.unicodeScalars.map(\.value),
            [0x1F441, 0xFE0E, 0x20]
        )
    }

    func testOverseerPrefixDecoratorLeavesInactiveBaseTitleUnchanged() {
        let baseTitle = "Agent session — Workspace"

        XCTAssertEqual(
            WindowTitleFormatter.applyingOverseerPrefix(to: baseTitle, isOverseer: false),
            baseTitle
        )
        XCTAssertEqual(
            WindowTitleFormatter.applyingOverseerPrefix(to: baseTitle, isOverseer: true),
            WindowTitleFormatter.overseerPrefix + baseTitle
        )
    }

    func testDisplayedWindowTitleFollowsWorkspaceName() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStateDisplayedTitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        let nsWindow = makeTestWindow()
        window.attachWindow(nsWindow)
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspaceName = "Displayed Title \(UUID().uuidString.prefix(8))"
            let workspace = window.workspaceManager.createWorkspace(
                name: workspaceName,
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "windowStateDisplayedTitleTests"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            XCTAssertEqual(activeWorkspace.id, workspace.id)

            try await waitForDisplayedTitle(window, and: nsWindow, endingWith: workspaceName)
        } catch {
            await cleanup(window: window, rootURL: rootURL)
            throw error
        }
        await cleanup(window: window, rootURL: rootURL)
    }

    func testDisplayedWindowTitleRefreshesWhenActiveAgentSessionIsRenamedThroughAgentMode() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStateDisplayedTitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        let nsWindow = makeTestWindow()
        window.attachWindow(nsWindow)
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspaceName = "Rename Title \(UUID().uuidString.prefix(8))"
            let workspace = window.workspaceManager.createWorkspace(
                name: workspaceName,
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "windowStateDisplayedTitleRenameTests"
            )
            let activeTabID = try XCTUnwrap(window.promptManager.activeComposeTabID)

            window.agentModeViewModel.renameSession(tabID: activeTabID, to: "Renamed Agent Session")

            try await waitForDisplayedTitle(
                window,
                and: nsWindow,
                equalTo: "Renamed Agent Session — \(workspaceName)"
            )
        } catch {
            await cleanup(window: window, rootURL: rootURL)
            throw error
        }
        await cleanup(window: window, rootURL: rootURL)
    }

    func testProjectionNotificationDecoratesEveryTitleSurfaceAndTracksLinkCount() async throws {
        try await withOverseerTitleFixture { fixture in
            let baseTitle = fixture.baseTitle(for: fixture.tabAID)
            let decoratedTitle = WindowTitleFormatter.overseerPrefix + baseTitle

            publishProjection(on: fixture, endpoint: fixture.endpointA, outboundCount: 1)
            try await waitForDisplayedTitle(fixture.window, and: fixture.nsWindow, equalTo: decoratedTitle)
            XCTAssertEqual(fixture.window.agentChatTitleCluster.state.title, decoratedTitle)

            publishProjection(on: fixture, endpoint: fixture.endpointA, outboundCount: 2)
            try await allowDeferredTitleUpdateToSettle()
            XCTAssertEqual(fixture.window.displayedWindowTitle, decoratedTitle)
            XCTAssertFalse(
                fixture.window.displayedWindowTitle
                    .dropFirst(WindowTitleFormatter.overseerPrefix.count)
                    .hasPrefix(WindowTitleFormatter.overseerPrefix),
                "republishing additional links must decorate a freshly resolved base title"
            )

            publishProjection(on: fixture, endpoint: fixture.endpointA, outboundCount: 1)
            try await allowDeferredTitleUpdateToSettle()
            XCTAssertEqual(fixture.window.displayedWindowTitle, decoratedTitle)

            publishProjection(on: fixture, endpoint: fixture.endpointA, outboundCount: 0)
            try await waitForDisplayedTitle(fixture.window, and: fixture.nsWindow, equalTo: baseTitle)
            XCTAssertEqual(fixture.window.agentChatTitleCluster.state.title, baseTitle)
        }
    }

    func testOnlyTheActiveTabsExactRoleDecoratesTheWindowTitle() async throws {
        try await withOverseerTitleFixture { fixture in
            publishProjection(on: fixture, endpoint: fixture.endpointA, outboundCount: 1)
            try await waitForDisplayedTitle(
                fixture.window,
                and: fixture.nsWindow,
                equalTo: WindowTitleFormatter.overseerPrefix + fixture.baseTitle(for: fixture.tabAID)
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            try await waitForDisplayedTitle(
                fixture.window,
                and: fixture.nsWindow,
                equalTo: fixture.baseTitle(for: fixture.tabBID)
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabAID)
            try await waitForDisplayedTitle(
                fixture.window,
                and: fixture.nsWindow,
                equalTo: WindowTitleFormatter.overseerPrefix + fixture.baseTitle(for: fixture.tabAID)
            )
        }
    }

    func testInboundOnlyProjectionDoesNotDecorateTitle() async throws {
        try await withOverseerTitleFixture { fixture in
            let baseTitle = fixture.baseTitle(for: fixture.tabAID)
            publishProjection(on: fixture, endpoint: fixture.endpointA, outboundCount: 1)
            try await waitForDisplayedTitle(
                fixture.window,
                and: fixture.nsWindow,
                equalTo: WindowTitleFormatter.overseerPrefix + baseTitle
            )

            publishProjection(
                on: fixture,
                endpoint: fixture.endpointA,
                outboundCount: 0,
                hasInbound: true
            )
            try await waitForDisplayedTitle(fixture.window, and: fixture.nsWindow, equalTo: baseTitle)
            XCTAssertFalse(fixture.window.agentModeViewModel.agentSessionLinkIsOverseer(tabID: fixture.tabAID))
        }
    }

    func testStaleReboundProjectionFailsClosed() async throws {
        try await withOverseerTitleFixture { fixture in
            let baseTitle = fixture.baseTitle(for: fixture.tabAID)
            publishProjection(on: fixture, endpoint: fixture.endpointA, outboundCount: 1)
            try await waitForDisplayedTitle(
                fixture.window,
                and: fixture.nsWindow,
                equalTo: WindowTitleFormatter.overseerPrefix + baseTitle
            )

            fixture.sessionA.testInstallPersistentSessionBinding(sessionID: fixture.sessionAID)
            let reboundEndpoint = try XCTUnwrap(
                fixture.window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tabAID)
            )
            XCTAssertNotEqual(reboundEndpoint, fixture.endpointA)

            fixture.window.agentModeViewModel.agentSessionLinkPruneProjections()
            try await waitForDisplayedTitle(fixture.window, and: fixture.nsWindow, equalTo: baseTitle)
            XCTAssertFalse(fixture.window.agentModeViewModel.agentSessionLinkIsOverseer(tabID: fixture.tabAID))
        }
    }

    func testBaseTitleCacheNeverRetainsOverseerDecoration() async throws {
        try await withOverseerTitleFixture { fixture in
            let baseTitle = fixture.baseTitle(for: fixture.tabAID)
            publishProjection(on: fixture, endpoint: fixture.endpointA, outboundCount: 1)
            try await waitForDisplayedTitle(
                fixture.window,
                and: fixture.nsWindow,
                equalTo: WindowTitleFormatter.overseerPrefix + baseTitle
            )

            let loadedWorkspaces = fixture.window.workspaceManager.workspaces
            fixture.window.workspaceManager.workspaces.removeAll()
            XCTAssertNotNil(fixture.window.workspaceManager.activeWorkspaceID)
            XCTAssertNil(fixture.window.workspaceManager.activeWorkspace)

            publishProjection(on: fixture, endpoint: fixture.endpointA, outboundCount: 0)
            try await waitForDisplayedTitle(fixture.window, and: fixture.nsWindow, equalTo: baseTitle)

            fixture.window.workspaceManager.workspaces = loadedWorkspaces
        }
    }

    func testDuplicateSessionUUIDInAnotherWindowDoesNotDecorate() async throws {
        let sharedSessionID = UUID()
        try await withOverseerTitleFixture(
            workspaceName: "First Duplicate Window",
            sessionAID: sharedSessionID
        ) { first in
            try await withOverseerTitleFixture(
                workspaceName: "Second Duplicate Window",
                sessionAID: sharedSessionID
            ) { second in
                publishProjection(on: second, endpoint: second.endpointA, outboundCount: 1)
                try await waitForDisplayedTitle(
                    second.window,
                    and: second.nsWindow,
                    equalTo: WindowTitleFormatter.overseerPrefix + second.baseTitle(for: second.tabAID)
                )
                try await allowDeferredTitleUpdateToSettle()

                XCTAssertEqual(first.window.displayedWindowTitle, first.baseTitle(for: first.tabAID))
                XCTAssertEqual(first.nsWindow.title, first.baseTitle(for: first.tabAID))
                XCTAssertFalse(first.window.agentModeViewModel.agentSessionLinkIsOverseer(tabID: first.tabAID))
            }
        }
    }

    private func makeTestWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func cleanup(window: WindowState, rootURL: URL) async {
        window.attachWindow(nil)
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func withOverseerTitleFixture(
        workspaceName: String = "Overseer Title \(UUID().uuidString.prefix(8))",
        sessionAID: UUID = UUID(),
        _ body: (OverseerTitleFixture) async throws -> Void
    ) async throws {
        let fixture = try await makeOverseerTitleFixture(
            workspaceName: workspaceName,
            sessionAID: sessionAID
        )
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeOverseerTitleFixture(
        workspaceName: String,
        sessionAID: UUID
    ) async throws -> OverseerTitleFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStateDisplayedTitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        let nsWindow = makeTestWindow()
        window.attachWindow(nsWindow)
        // Intentionally do not register this fixture with `WindowStatesManager`: these tests drive
        // the exact projection storage boundary directly, and the process-wide runtime bridge must
        // not replace the synthetic rows from authority state while a title assertion is pending.
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: workspaceName,
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "windowStateDisplayedOverseerTitleTests"
            )

            let tabAID = UUID()
            let tabBID = UUID()
            let sessionBID = UUID()
            let tabA = ComposeTabState(id: tabAID, name: "Alpha", activeAgentSessionID: sessionAID)
            let tabB = ComposeTabState(id: tabBID, name: "Beta", activeAgentSessionID: sessionBID)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [tabA, tabB]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabAID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let sessionA = window.agentModeViewModel.session(for: tabAID)
            let sessionB = window.agentModeViewModel.session(for: tabBID)
            sessionA.hasLoadedPersistedState = true
            sessionB.hasLoadedPersistedState = true
            let endpointA = try XCTUnwrap(
                window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: tabAID)
            )
            _ = try XCTUnwrap(window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: tabBID))

            window.updateWindowTitleIfPossible()
            let fixture = OverseerTitleFixture(
                window: window,
                nsWindow: nsWindow,
                rootURL: rootURL,
                workspaceName: workspaceName,
                tabAID: tabAID,
                tabBID: tabBID,
                sessionAID: sessionAID,
                sessionA: sessionA,
                endpointA: endpointA
            )
            try await waitForDisplayedTitle(
                window,
                and: nsWindow,
                equalTo: fixture.baseTitle(for: tabAID)
            )
            return fixture
        } catch {
            window.attachWindow(nil)
            window.beginClose()
            await window.tearDown()
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func cleanup(_ fixture: OverseerTitleFixture) async {
        fixture.window.attachWindow(nil)
        fixture.window.beginClose()
        await fixture.window.tearDown()
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private func publishProjection(
        on fixture: OverseerTitleFixture,
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        outboundCount: Int,
        hasInbound: Bool = false
    ) {
        let outbound = (0 ..< outboundCount).map { index in
            let targetSessionID = UUID()
            return AgentMonitorPillProps.Outbound(
                linkID: UUID(),
                generation: UInt64(index + 1),
                targetSessionID: targetSessionID,
                targetEndpoint: AgentSessionLinkIdentityTestSupport.endpoint(
                    sessionID: targetSessionID
                ),
                displayName: "Target \(index + 1)",
                providerDisplayName: nil,
                locationLabel: nil,
                status: .idle
            )
        }
        let observerEndpoint = AgentSessionLinkIdentityTestSupport.endpoint(sessionID: UUID())
        let inbound = hasInbound
            ? [AgentMonitorPillProps.Inbound(
                linkID: UUID(),
                generation: 1,
                observerSessionID: observerEndpoint.sessionID,
                observerEndpoint: observerEndpoint,
                displayName: "Observer",
                providerDisplayName: nil
            )]
            : []
        let props = AgentMonitorPillProps(
            sessionID: endpoint.sessionID,
            endpoint: endpoint,
            sidebarOversightMenu: nil,
            outbound: outbound,
            inbound: inbound,
            recentNotices: [],
            canAddReason: nil
        )
        fixture.window.agentModeViewModel.agentSessionLinkPublishProjection(props, to: endpoint)
    }

    private func allowDeferredTitleUpdateToSettle() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    /// The displayed title is published from a deferred task, so poll briefly instead of
    /// asserting immediately after the workspace switch returns. The title may carry an
    /// Agent session prefix ("T1 — <workspace>"), so only the workspace suffix is asserted.
    private func waitForDisplayedTitle(
        _ window: WindowState,
        and nsWindow: NSWindow,
        endingWith expectedSuffix: String,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if window.displayedWindowTitle.hasSuffix(expectedSuffix),
               nsWindow.title.hasSuffix(expectedSuffix)
            {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(
            "displayedWindowTitle was \"\(window.displayedWindowTitle)\" and NSWindow.title was \"\(nsWindow.title)\", expected suffix \"\(expectedSuffix)\""
        )
    }

    private func waitForDisplayedTitle(
        _ window: WindowState,
        and nsWindow: NSWindow,
        equalTo expected: String,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if window.displayedWindowTitle == expected,
               nsWindow.title == expected
            {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(
            "displayedWindowTitle was \"\(window.displayedWindowTitle)\" and NSWindow.title was \"\(nsWindow.title)\", expected \"\(expected)\""
        )
    }

    private struct OverseerTitleFixture {
        let window: WindowState
        let nsWindow: NSWindow
        let rootURL: URL
        let workspaceName: String
        let tabAID: UUID
        let tabBID: UUID
        let sessionAID: UUID
        let sessionA: AgentModeViewModel.TabSession
        let endpointA: DomainAgentSessionLinkEndpointIdentity

        func baseTitle(for tabID: UUID) -> String {
            let tabName = tabID == tabAID ? "Alpha" : "Beta"
            return "\(tabName) — \(workspaceName)"
        }
    }
}
