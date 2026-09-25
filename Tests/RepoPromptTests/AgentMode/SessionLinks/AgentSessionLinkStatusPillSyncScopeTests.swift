import Combine
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Projection storage rebuilds the status-pill snapshot only when the current tab's exact endpoint
/// entry changes; every changed transaction still posts its single owner-scoped notification.
@MainActor
final class AgentSessionLinkStatusPillSyncScopeTests: XCTestCase {
    private var retainedViewModels: [AgentModeViewModel] = []
    private var retainedWorkspaces: [WorkspaceManagerViewModel] = []

    override func tearDown() {
        retainedViewModels.removeAll()
        retainedWorkspaces.removeAll()
        super.tearDown()
    }

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let tabID: UUID
        let endpoint: DomainAgentSessionLinkEndpointIdentity
    }

    private func makeFixture() throws -> Fixture {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 83,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retainedViewModels.append(viewModel)
        retainedWorkspaces.append(AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Status pill sync scope"
        ))
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        _ = try XCTUnwrap(
            viewModel.test_ensureSessionBoundToTab(session),
            "expected a durable persistent binding"
        )
        let fixture = try Fixture(
            viewModel: viewModel,
            session: session,
            tabID: tabID,
            endpoint: AgentSessionLinkEndpointTestSupport.endpoint(viewModel, tabID: tabID)
        )
        XCTAssertEqual(viewModel.currentTabID, tabID)
        return fixture
    }

    /// An exact endpoint in the same window that is not the current tab.
    private func nonCurrentEndpoint(_ fixture: Fixture) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: fixture.endpoint.windowID,
            workspaceID: fixture.endpoint.workspaceID,
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 0
        )
    }

    private func props(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        outboundCount: Int = 1
    ) -> AgentMonitorPillProps {
        AgentMonitorPillProps(
            sessionID: endpoint.sessionID,
            sidebarOversightMenu: nil,
            outbound: (0 ..< outboundCount).map { index in
                let targetSessionID = UUID()
                return AgentMonitorPillProps.Outbound(
                    linkID: UUID(),
                    generation: UInt64(index + 1),
                    targetSessionID: targetSessionID,
                    targetEndpoint: AgentSessionLinkIdentityTestSupport.endpoint(
                        sessionID: targetSessionID
                    ),
                    displayName: "Target \(index)",
                    providerDisplayName: "Codex CLI",
                    locationLabel: "worktree/\(index)",
                    status: .idle
                )
            },
            inbound: [],
            recentNotices: [],
            canAddReason: nil
        )
    }

    private func observeNotifications(
        _ viewModel: AgentModeViewModel,
        onPost: @escaping () -> Void = {}
    ) -> (AnyCancellable, () -> Int) {
        var count = 0
        let cancellable = NotificationCenter.default.publisher(
            for: .agentSessionLinkOverseerProjectionDidChange,
            object: viewModel
        ).sink { _ in
            count += 1
            onPost()
        }
        return (cancellable, { count })
    }

    func testNonCurrentEndpointChangesSkipStatusPillRebuildButKeepOneNotificationEach() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        viewModel.agentSessionLinkPublishProjection(props(endpoint: fixture.endpoint), to: fixture.endpoint)
        let snapshotBefore = viewModel.ui.statusPills.snapshot
        let revisionBefore = viewModel.ui.statusPills.revision
        let (cancellable, notificationCount) = observeNotifications(viewModel)
        viewModel.test_statusPillsSnapshotBuildCount = 0

        let others = (0 ..< 3).map { _ in nonCurrentEndpoint(fixture) }
        for (index, endpoint) in others.enumerated() {
            viewModel.agentSessionLinkPublishProjection(props(endpoint: endpoint), to: endpoint)
            XCTAssertEqual(notificationCount(), index + 1)
        }
        // A second, different projection for an already stored non-current endpoint is also a
        // changed transaction that must notify without rebuilding.
        viewModel.agentSessionLinkPublishProjection(props(endpoint: others[0], outboundCount: 2), to: others[0])

        XCTAssertEqual(viewModel.test_statusPillsSnapshotBuildCount, 0)
        XCTAssertEqual(notificationCount(), others.count + 1)
        XCTAssertEqual(Set(viewModel.monitorPillPropsByEndpoint.keys), Set(others + [fixture.endpoint]))
        XCTAssertEqual(viewModel.ui.statusPills.snapshot, snapshotBefore)
        XCTAssertEqual(viewModel.ui.statusPills.revision, revisionBefore)
        withExtendedLifetime(cancellable) {}
    }

    func testCurrentEndpointChangeRebuildsOnceBeforeItsNotification() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let published = props(endpoint: fixture.endpoint, outboundCount: 2)
        var monitorAtNotification: AgentMonitorPillProps?
        let (cancellable, notificationCount) = observeNotifications(viewModel) {
            monitorAtNotification = viewModel.ui.statusPills.snapshot.monitor
        }
        viewModel.test_statusPillsSnapshotBuildCount = 0

        viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)

        XCTAssertEqual(viewModel.test_statusPillsSnapshotBuildCount, 1)
        XCTAssertEqual(notificationCount(), 1)
        var expected = viewModel.monitorPillPropsByEndpoint[fixture.endpoint]
        expected?.pendingUpdates = .empty
        XCTAssertNotNil(expected)
        XCTAssertEqual(monitorAtNotification, expected)
        XCTAssertEqual(monitorAtNotification?.outbound.count, 2)
        withExtendedLifetime(cancellable) {}
    }

    func testStatusPillSnapshotStaysCurrentAcrossProjectionAndPolicyMutations() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let other = nonCurrentEndpoint(fixture)
        fixture.session.oversight.autoWakeOnUpdates = false

        func assertCurrent(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(
                viewModel.ui.statusPills.snapshot,
                viewModel.makeStatusPillsSnapshot(),
                "status pills stale after \(step)",
                file: file,
                line: line
            )
        }

        viewModel.agentSessionLinkPublishProjection(props(endpoint: fixture.endpoint), to: fixture.endpoint)
        assertCurrent("current endpoint publish")
        viewModel.agentSessionLinkPublishProjection(props(endpoint: other), to: other)
        assertCurrent("non-current endpoint publish")
        viewModel.agentSessionLinkPublishProjection(props(endpoint: other, outboundCount: 3), to: other)
        assertCurrent("non-current endpoint republish")
        XCTAssertTrue(viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(true, for: fixture.endpoint))
        assertCurrent("Auto-wake master write")
        XCTAssertTrue(viewModel.agentSessionLinkSetRoutineWakeInterval(
            enabled: true,
            seconds: 3600,
            for: fixture.endpoint
        ))
        assertCurrent("routine interval write")
        viewModel.agentSessionLinkApplyPersistencePresentation(
            AgentSessionOversightPersistencePresentation(availability: .ready)
        )
        assertCurrent("persistence presentation")
        viewModel.agentSessionLinkPublishProjection(
            props(endpoint: fixture.endpoint, outboundCount: 2),
            to: fixture.endpoint
        )
        assertCurrent("current endpoint republish")
        viewModel.agentSessionLinkPruneProjections()
        XCTAssertNil(viewModel.monitorPillPropsByEndpoint[other])
        XCTAssertNotNil(viewModel.monitorPillPropsByEndpoint[fixture.endpoint])
        assertCurrent("prune of non-current stale endpoint")
    }
}
