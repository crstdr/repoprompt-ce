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

    /// One queued status edge for the observer's first outbound row, as the passive reducer would
    /// publish it after a target transition.
    private func passiveSnapshot(
        observer: DomainAgentSessionLinkEndpointIdentity,
        row: AgentMonitorPillProps.Outbound
    ) -> AgentSessionLinkPassiveStatusNotices.Snapshot {
        let reference = DomainAgentSessionLinkReference(linkID: row.linkID, generation: row.generation)
        return AgentSessionLinkPassiveStatusNotices.Snapshot(
            observerEndpoint: observer,
            queueEpoch: UUID(),
            queueRevision: 1,
            linkSetRevision: 1,
            isEnabled: true,
            isDeliverable: true,
            entries: [
                AgentSessionLinkPassiveStatusNotices.PendingEntry(
                    reference: reference,
                    targetEndpoint: row.targetEndpoint,
                    targetSessionID: row.targetSessionID,
                    displayName: row.displayName,
                    fromStatus: .running,
                    toStatus: .idle,
                    observedAt: Date(timeIntervalSince1970: 0),
                    idleForSend: true,
                    latestVisibleAssistantPreview: "Done.",
                    changeSequence: 1,
                    edgeSequence: 1
                )
            ],
            attentionRequests: [],
            unacknowledgedOverflowCount: 0,
            overflowProduced: 0,
            autoWakeLanes: [
                AgentSessionLinkPassiveStatusNotices.AutoWakeLane(
                    reference: reference,
                    targetEndpoint: row.targetEndpoint,
                    targetSessionID: row.targetSessionID,
                    isEffectivelySelected: false
                )
            ]
        )
    }

    /// The pending-updates section is derived from the passive queue, which changes without any link
    /// projection change. Its own publication must refresh the on-screen observer's pill.
    func testPassiveNoticePublishForCurrentObserverRefreshesStatusPills() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        fixture.session.oversight.autoWakeOnUpdates = false
        let published = props(endpoint: fixture.endpoint)
        let row = try XCTUnwrap(published.outbound.first)
        viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)
        viewModel.test_flushPendingUIRefresh()
        let pendingBefore = viewModel.ui.statusPills.snapshot.monitor.pendingUpdates

        viewModel.agentSessionLinkPublishPassiveStatusNotices(
            passiveSnapshot(observer: fixture.endpoint, row: row),
            to: fixture.endpoint
        )
        viewModel.test_flushPendingUIRefresh()

        let fresh = viewModel.makeStatusPillsSnapshot()
        XCTAssertEqual(fresh.monitor.pendingUpdates?.updateCount, 1)
        XCTAssertNotEqual(fresh.monitor.pendingUpdates, pendingBefore)
        XCTAssertEqual(viewModel.ui.statusPills.snapshot, fresh)
    }

    /// Before projection-scoped syncing, an unrelated endpoint's projection change incidentally
    /// repaired a stale pending-updates section. The on-screen pill must not depend on that.
    func testPassiveNoticeFreshnessDoesNotDependOnUnrelatedProjectionChanges() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        fixture.session.oversight.autoWakeOnUpdates = false
        let published = props(endpoint: fixture.endpoint)
        let row = try XCTUnwrap(published.outbound.first)
        viewModel.agentSessionLinkPublishProjection(published, to: fixture.endpoint)

        viewModel.agentSessionLinkPublishPassiveStatusNotices(
            passiveSnapshot(observer: fixture.endpoint, row: row),
            to: fixture.endpoint
        )
        let other = nonCurrentEndpoint(fixture)
        viewModel.agentSessionLinkPublishProjection(props(endpoint: other), to: other)
        viewModel.test_flushPendingUIRefresh()

        XCTAssertEqual(viewModel.ui.statusPills.snapshot.monitor.pendingUpdates?.updateCount, 1)
        XCTAssertEqual(viewModel.ui.statusPills.snapshot, viewModel.makeStatusPillsSnapshot())
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
