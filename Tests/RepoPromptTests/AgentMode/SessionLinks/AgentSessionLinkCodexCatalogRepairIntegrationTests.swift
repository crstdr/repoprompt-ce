import Combine
import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptShared
import XCTest

/// Covers the production server path that repairs a stale Codex catalog when an exact grant is
/// restored, including an inbound-only created lane.
@MainActor
final class AgentSessionLinkCodexCatalogRepairIntegrationTests: XCTestCase {
    private let clientName = AgentProviderKind.openCodeMCPClientID

    func testRestoredOutboundGrantInvalidationRepairsCodexCatalogThroughServerProjection() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: true)
    }

    func testRestoredCreatedLaneInboundGrantRepairsCodexCatalogWithoutOutboundAuthority() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: false)
    }

    func testActivatedNoLinkRepairsCatalogOnNextTurn() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: false, surfaceTransition: .activation)
    }

    func testReducedCatalogUpgradeRepairsOnceAfterQuiescence() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: true, surfaceTransition: .upgrade)
    }

    func testBareOrchestratorCanDiscoverScopeRequestsWithoutAnyGrant() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: false, surfaceTransition: .orchestrator)
    }

    func testDelegationEligibilityAndForcedRelistPreserveRoleSizedOversightSurface() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: false, surfaceTransition: .delegation)
    }

    func testToolbarActivationAndRetirementRelistScopeEligibilityWithoutGrantingAuthority() async throws {
        try await assertRestoredGrantRepairsCatalog(outbound: false, surfaceTransition: .toolbar)
    }

    func testIgnoredScopeGrantNotificationRepairsCatalogAfterQuiescence() async throws {
        // With oversight enabled, an eligible session lists session_admin from its first turn, so a
        // scope grant or revocation does not change its surface and needs no repair. The repair
        // path remains for the oversight-disabled surface, where only scope authority lists it.
        for oversightEnabled in [false] {
            try await assertRestoredGrantRepairsCatalog(
                outbound: false, surfaceTransition: .delegationGrant, oversightEnabled: oversightEnabled
            )
        }
    }

    func testIgnoredScopeRevocationNotificationRepairsCatalogAfterQuiescence() async throws {
        // With oversight enabled, an eligible session lists session_admin from its first turn, so a
        // scope grant or revocation does not change its surface and needs no repair. The repair
        // path remains for the oversight-disabled surface, where only scope authority lists it.
        for oversightEnabled in [false] {
            try await assertRestoredGrantRepairsCatalog(
                outbound: false, surfaceTransition: .delegationRevocation, oversightEnabled: oversightEnabled
            )
        }
    }

    private enum SurfaceTransition { case activation, upgrade, orchestrator, delegation, toolbar, delegationGrant, delegationRevocation }

    private func assertRestoredGrantRepairsCatalog(
        outbound: Bool, surfaceTransition: SurfaceTransition? = nil, oversightEnabled: Bool = true
    ) async throws {
        #if DEBUG
            let manager = ServerNetworkManager(
                domainHost: AppDomainRuntimeComposition.shared.runtime.domainHost
            )
            let window = makeWindow()
            WindowStatesManager.shared.registerWindowState(window)
            let runID = UUID()
            let connectionID = UUID()
            let tabID = UUID()
            let conversationID = "restored-oversight-thread"
            let rolloutPath = "/tmp/restored-oversight-rollout.jsonl"

            let registration: MCPDomainToolRegistrationResult
            do {
                try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                registration = try await AppDomainRuntimeComposition.shared.register(
                    window.mcpServer.windowMCPToolCatalogService
                )
            } catch {
                WindowStatesManager.shared.unregisterWindowState(window)
                throw error
            }
            addTeardownBlock { @MainActor in
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(
                    anyActive: nil,
                    outbound: nil
                )
                await self.cleanup(
                    manager: manager,
                    runID: runID,
                    connectionID: connectionID,
                    windowID: window.windowID
                )
                await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                WindowStatesManager.shared.unregisterWindowState(window)
            }

            await window.workspaceManager.awaitInitialized()
            try await installRoutingSnapshot(for: tabID, in: window)
            let session = window.agentModeViewModel.session(for: tabID)
            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            session.selectedAgent = .codexExec
            session.hasLoadedPersistedState = true
            session.createdByOverseerSessionID = outbound || surfaceTransition != nil ? nil : UUID()
            session.installRunID(runID)
            session.codexConversationID = conversationID
            session.codexRolloutPath = rolloutPath
            session.codexController = controller
            // Catalog repair begins with an existing restored conversation.
            _ = try XCTUnwrap(window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session, updateWorkspaceMetadata: true))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            XCTAssertTrue(session.qualifiedRestorationReadiness.isAuthoritative)
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                window.agentModeViewModel,
                tabID: tabID
            )
            let isScopeRepair = surfaceTransition == .delegationGrant || surfaceTransition == .delegationRevocation
            let scopes = AgentSessionLinkRuntimeBridge.shared.delegationScopes
            let scopeSessionID = try XCTUnwrap(session.activeAgentSessionID)
            func grantScope() throws -> UUID {
                let request = try scopes.requestScope(
                    requesterSessionID: scopeSessionID, requesterTabID: tabID,
                    kind: .tree(rootSessionID: scopeSessionID), capabilities: [.observe],
                    guardrails: .init(), reason: nil, idempotencyKey: nil
                ).get()
                let scope = try scopes.approve(
                    requestID: request.id, presentedWindowID: window.windowID,
                    presentedTabID: tabID, presentedSessionID: scopeSessionID
                ).get()
                addTeardownBlock { @MainActor in scopes.revoke(scopeID: scope.id) }
                return scope.id
            }
            var scopeToRevoke: UUID?
            if isScopeRepair {
                let availability = ToolAvailabilityStore.shared
                let wasEnabled = availability.isEnabled(MCPWindowToolName.agentSessionLink)
                XCTAssertTrue(availability.isEnabled(MCPWindowToolName.sessionAdmin))
                await availability.toggle(MCPWindowToolName.agentSessionLink, enabled: oversightEnabled)
                addTeardownBlock { @MainActor in
                    await availability.toggle(MCPWindowToolName.agentSessionLink, enabled: wasEnabled)
                }
                if surfaceTransition == .delegationRevocation { scopeToRevoke = try grantScope() }
            }
            await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: surfaceTransition == .upgrade ? [endpoint] : [], outbound: [])
            if surfaceTransition != nil { session.runState = .running }
            await installAuthoritativePolicy(
                manager: manager,
                runID: runID,
                tabID: tabID,
                windowID: window.windowID,
                allowsAgentExternalControlTools: surfaceTransition == .orchestrator
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            let testConnection = CatalogRepairPolicyAuthorityTestConnection()
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: testConnection,
                pendingClientID: clientName
            )
            let applied = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: "catalog-repair-\(runID.uuidString)",
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            XCTAssertEqual(applied.outcome, "applied")

            let names = try await manager.debugListToolNames(for: connectionID)
            XCTAssertEqual(names.contains(MCPWindowToolName.agentSessionLink), surfaceTransition == .upgrade)
            let unlinkedProjection = await manager.debugRunCatalogProjection(for: runID)
            let unlinked = try XCTUnwrap(unlinkedProjection)
            XCTAssertEqual(unlinked.hasAgentSessionLink, surfaceTransition == .upgrade)
            XCTAssertEqual(unlinked.hasActiveOutboundLink, false)
            XCTAssertNil(session.codexSessionLinkCatalogRepairCycle?.observedControllerGeneration)
            XCTAssertNotNil(session.codexController)

            let sessionID = try XCTUnwrap(session.activeAgentSessionID)
            if surfaceTransition == .orchestrator {
                XCTAssertTrue(names.contains(MCPWindowToolName.sessionAdmin), "Bare orchestrators can request authority, not exercise it")
                XCTAssertFalse(AgentSessionLinkRuntimeBridge.shared.delegationScopes.hasLiveScope(grantedTo: sessionID))
                return
            }
            if surfaceTransition == .toolbar {
                XCTAssertTrue(names.contains(MCPWindowToolName.sessionAdmin), "An eligible session can request a scope from its first turn")
                let host = WindowStatesManager.shared
                let authority = DomainAgentSessionLinkAuthority(identity: DomainRuntimeIdentity(
                    runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()
                ))
                let bridge = AgentSessionLinkRuntimeBridge(
                    authority: authority, host: host,
                    toolAdvertisementInvalidator: { await manager.notifyToolListChangedForAgentSession($0) }
                )
                bridge.attach(host: host)
                defer { host.attachAgentSessionLinkBridge() }
                let scopes = AgentSessionLinkRuntimeBridge.shared.delegationScopes
                let availability = ToolAvailabilityStore.shared
                let oversightWasEnabled = availability.isEnabled(MCPWindowToolName.agentSessionLink)
                XCTAssertTrue(oversightWasEnabled)
                addTeardownBlock { @MainActor in
                    await availability.toggle(MCPWindowToolName.agentSessionLink, enabled: oversightWasEnabled)
                }
                for (keepScope, disableOversight) in [(false, false), (false, true), (true, true)] {
                    let beforeActivation = await testConnection.notificationCount()
                    let expected = try XCTUnwrap(window.agentModeViewModel.agentSessionLinkBootstrapState(for: endpoint))
                    let enabled = await bridge.enableOverseerFromToolbar(endpoint: endpoint, expected: expected, isEnabled: { true })
                    XCTAssertTrue(enabled)
                    let afterActivation = await testConnection.notificationCount()
                    XCTAssertGreaterThan(afterActivation, beforeActivation, "Toolbar consent relists the exact running Agent route")
                    let activatedNames = try await manager.debugListToolNames(for: connectionID)
                    XCTAssertTrue(activatedNames.contains(MCPWindowToolName.sessionAdmin))
                    XCTAssertTrue(activatedNames.contains(MCPWindowToolName.agentSessionLink))
                    // Activation exposes controls but retains targeted bootstrap discovery.
                    XCTAssertTrue(activatedNames.contains(MCPWindowToolName.becomeOverseer))
                    XCTAssertFalse(scopes.hasLiveScope(grantedTo: sessionID), "Opt-in is discovery, not user-granted scope authority")
                    let links = await authority.links(forObserver: sessionID)
                    XCTAssertTrue(links.items.isEmpty, "Toolbar consent never manufactures a link")
                    var scopeID: UUID?
                    if keepScope {
                        let request = try scopes.requestScope(
                            requesterSessionID: sessionID, requesterTabID: tabID,
                            kind: .tree(rootSessionID: sessionID), capabilities: [.observe],
                            guardrails: .init(), reason: nil, idempotencyKey: nil
                        ).get()
                        let scope = try scopes.approve(
                            requestID: request.id, presentedWindowID: window.windowID,
                            presentedTabID: tabID, presentedSessionID: sessionID
                        ).get()
                        scopeID = scope.id
                        addTeardownBlock { @MainActor in scopes.revoke(scopeID: scope.id) }
                    }
                    if disableOversight {
                        await availability.toggle(MCPWindowToolName.agentSessionLink, enabled: false)
                        let disabledNames = try await manager.debugListToolNames(for: connectionID)
                        XCTAssertEqual(disabledNames.contains(MCPWindowToolName.sessionAdmin), keepScope, "Disabled oversight withdraws opt-in-only scope requests, not independently approved scope authority")
                        XCTAssertFalse(disabledNames.contains(MCPWindowToolName.agentSessionLink))
                        XCTAssertFalse(disabledNames.contains(MCPWindowToolName.becomeOverseer))
                        XCTAssertNotNil(session.oversight.overseerActivation, "Availability changes do not retire user consent")
                    }
                    let beforeRetirement = await testConnection.notificationCount()
                    session.oversight.overseerActivation = nil
                    if !disableOversight {
                        try await AsyncTestWait.waitUntil("activation retirement relists the exact Agent route") {
                            await testConnection.notificationCount() > beforeRetirement
                        }
                    }
                    let retiredNames = try await manager.debugListToolNames(for: connectionID)
                    XCTAssertEqual(
                        retiredNames.contains(MCPWindowToolName.sessionAdmin), keepScope || !disableOversight,
                        "Retirement keeps scope requests for an eligible session; disabled oversight keeps only approved scope authority"
                    )
                    XCTAssertFalse(retiredNames.contains(MCPWindowToolName.agentSessionLink), "A durable scope does not fabricate oversight activation or pair grants")
                    XCTAssertEqual(retiredNames.contains(MCPWindowToolName.becomeOverseer), !disableOversight)
                    if let scopeID {
                        scopes.revoke(scopeID: scopeID)
                        let beforeRevoke = await testConnection.notificationCount()
                        await manager.notifyToolListChangedForAgentSession(sessionID, forceRelist: true)
                        let afterRevoke = await testConnection.notificationCount()
                        XCTAssertGreaterThan(afterRevoke, beforeRevoke, "Scope-only withdrawal relists despite an unchanged oversight fingerprint")
                        let revokedNames = try await manager.debugListToolNames(for: connectionID)
                        XCTAssertFalse(revokedNames.contains(MCPWindowToolName.sessionAdmin))
                    }
                    if disableOversight {
                        await availability.toggle(MCPWindowToolName.agentSessionLink, enabled: true)
                        await manager.notifyToolListChangedForAgentSession(sessionID)
                        let reenabledNames = try await manager.debugListToolNames(for: connectionID)
                        XCTAssertTrue(reenabledNames.contains(MCPWindowToolName.sessionAdmin), "Re-enabling the family restores scope requests for an eligible session")
                        XCTAssertFalse(reenabledNames.contains(MCPWindowToolName.agentSessionLink), "Re-enabling the family cannot revive retired opt-in")
                        XCTAssertTrue(reenabledNames.contains(MCPWindowToolName.becomeOverseer))
                    }
                }
                XCTAssertEqual(session.runID, runID)
                XCTAssertTrue(session.codexController === controller, "Discovery cannot replace a held provider")
                XCTAssertNil(session.oversight.pendingAutoWake, "Opt-in and retirement never manufacture a turn")
                return
            }
            if surfaceTransition == .delegation {
                // An eligible session lists session_admin to request a scope; listing grants nothing.
                XCTAssertTrue(names.contains(MCPWindowToolName.sessionAdmin))
                // Inbound oversight alone is not a scope request/administration grant.
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: [endpoint], outbound: [])
                let inboundNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(inboundNames.contains(MCPWindowToolName.agentSessionLink))
                XCTAssertTrue(inboundNames.contains(MCPWindowToolName.sessionAdmin))
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: [endpoint], outbound: [endpoint])
                let outboundNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(outboundNames.contains(MCPWindowToolName.sessionAdmin))
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: [], outbound: [])
                let noLinkNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(noLinkNames.contains(MCPWindowToolName.sessionAdmin))

                let scopes = AgentSessionLinkRuntimeBridge.shared.delegationScopes
                let request = try scopes.requestScope(
                    requesterSessionID: sessionID, requesterTabID: tabID,
                    kind: .tree(rootSessionID: sessionID), capabilities: [.observe],
                    guardrails: .init(), reason: nil, idempotencyKey: nil
                ).get()
                let scope = try scopes.approve(
                    requestID: request.id, presentedWindowID: window.windowID,
                    presentedTabID: tabID, presentedSessionID: sessionID
                ).get()
                addTeardownBlock { @MainActor in scopes.revoke(scopeID: scope.id) }
                let notificationsBeforeGrant = await testConnection.notificationCount()
                await manager.notifyToolListChangedForAgentSession(sessionID, forceRelist: true)
                let notificationsAfterGrant = await testConnection.notificationCount()
                XCTAssertGreaterThan(notificationsAfterGrant, notificationsBeforeGrant, "A scope-only grant must relist even when every link fact is unchanged")
                let scopedNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(scopedNames.contains(MCPWindowToolName.sessionAdmin))
                XCTAssertFalse(scopedNames.contains(MCPWindowToolName.agentSessionLink), "A scope does not fabricate pair or activated-overseer authority")
                scopes.revoke(scopeID: scope.id)
                await manager.notifyToolListChangedForAgentSession(sessionID, forceRelist: true)
                let revokedNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(revokedNames.contains(MCPWindowToolName.sessionAdmin))
                XCTAssertFalse(scopes.hasLiveScope(grantedTo: sessionID), "Listing survives revocation; authority does not")
                XCTAssertEqual(session.runID, runID, "Scope discovery never retargets the run")
                XCTAssertNotNil(session.codexController, "Scope changes do not recycle a running provider")
                return
            }
            let sourceGeneration = session.codexControllerGeneration
            if isScopeRepair {
                XCTAssertEqual(names.contains(MCPWindowToolName.sessionAdmin), surfaceTransition == .delegationRevocation)
                if let scopeToRevoke {
                    scopes.revoke(scopeID: scopeToRevoke)
                } else {
                    _ = try grantScope()
                }
            } else if surfaceTransition == .activation {
                let state = try XCTUnwrap(window.agentModeViewModel.agentSessionLinkBootstrapState(for: endpoint))
                XCTAssertTrue(window.agentModeViewModel.agentSessionLinkActivateOverseer(for: endpoint, expected: state))
            } else {
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: [endpoint], outbound: outbound ? [endpoint] : [])
            }
            // This connection records notifications but intentionally does not relist: exercise
            // the stale client catalog rather than healing it in the test before reconciliation.
            await manager.notifyToolListChangedForAgentSession(sessionID, forceRelist: isScopeRepair)

            let stuckProjection = await manager.debugRunCatalogProjection(for: runID)
            let stuck = try XCTUnwrap(stuckProjection)
            XCTAssertEqual(stuck.hasAgentSessionLink, surfaceTransition == .upgrade)
            if surfaceTransition != nil {
                XCTAssertNotEqual(stuck.expectedSurface, stuck.returnedSurface)
                XCTAssertEqual(stuck.returnedSurface, unlinked.returnedSurface)
                XCTAssertNotNil(session.codexController, "Busy provider is not replaced")
                XCTAssertEqual(session.runID, runID)
                XCTAssertEqual(session.codexSessionLinkCatalogRepairCycle?.observedControllerGeneration, sourceGeneration)
                if isScopeRepair {
                    XCTAssertFalse(stuck.hasAnyActiveLink == true)
                    XCTAssertTrue(AgentSessionLinkCatalogSurface.differs(
                        toolName: MCPWindowToolName.sessionAdmin,
                        expected: stuck.expectedSurface, returned: stuck.returnedSurface
                    ))
                }
                session.runState = .completed
                window.agentModeViewModel.test_codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(for: session)
            }
            XCTAssertEqual(stuck.hasActiveOutboundLink, outbound)
            XCTAssertEqual(stuck.routeToken?.observerEndpoint, endpoint)
            XCTAssertEqual(stuck.isReady, surfaceTransition == .upgrade, "Schema freshness is not outbound prompt authority")
            XCTAssertNil(session.runID, "the stale process run is retired so cold bootstrap applies")
            XCTAssertNil(session.codexController, "exactly one controller replacement")
            XCTAssertEqual(session.codexConversationID, conversationID)
            XCTAssertEqual(session.codexRolloutPath, rolloutPath)
            XCTAssertEqual(session.codexSessionLinkCatalogRepairCycle?.observedControllerGeneration, sourceGeneration)
            XCTAssertNotEqual(sourceGeneration, session.codexControllerGeneration)
            if surfaceTransition != nil {
                XCTAssertNil(session.oversight.pendingAutoWake, "An empty passive queue never manufactures a continuation")
                XCTAssertEqual(session.oversight.overseerActivation != nil, surfaceTransition == .activation)
                let spentGeneration = session.codexControllerGeneration
                window.agentModeViewModel.test_codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(for: session)
                XCTAssertEqual(session.codexControllerGeneration, spentGeneration)
                // Production retirement clears the old run's provider PID when its transport
                // terminates (CodexAppServerClient.finishTransportTermination). This no-op controller
                // has no process, and both runs share the XCTest PID, so mirror that clear; otherwise
                // the retired run still looks like a live ancestor and the next bootstrap is
                // correctly refused as ambiguous_run_policy.
                await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                // The next ordinary installed run re-lists the full surface; no synthetic turn.
                let nextRunID = UUID()
                let nextConnectionID = UUID()
                session.installRunID(nextRunID)
                session.codexController = LifecycleNoopCodexController(recorder: LifecycleRecorder())
                await installAuthoritativePolicy(manager: manager, runID: nextRunID, tabID: tabID, windowID: window.windowID)
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: nextRunID)
                await manager.debugInstallDirectAdmissionConnectionForTesting(connectionID: nextConnectionID, connection: CatalogRepairPolicyAuthorityTestConnection(), pendingClientID: clientName)
                let nextApplied = await manager.debugApplyPendingPolicy(clientName: clientName, connectionID: nextConnectionID, clientPid: Int(getpid()), bootstrapClientName: "repoprompt_ce_cli_debug", sessionKey: "next-\(nextRunID)", pidGateTimeout: 0.25, requireRunRouting: true)
                XCTAssertEqual(nextApplied.outcome, "applied")
                let nextNames = try await manager.debugListToolNames(for: nextConnectionID)
                XCTAssertEqual(nextNames.contains(MCPWindowToolName.agentSessionLink), !isScopeRepair)
                XCTAssertEqual(nextNames.contains(MCPWindowToolName.becomeOverseer), oversightEnabled, "Eligible roles retain targeted bootstrap; disabled oversight still removes it")
                if isScopeRepair {
                    XCTAssertEqual(nextNames.contains(MCPWindowToolName.sessionAdmin), surfaceTransition == .delegationGrant)
                } else if surfaceTransition == .activation {
                    XCTAssertTrue(nextNames.contains(MCPWindowToolName.sessionAdmin), "A still-activated zero-link overseer can request a scope on the next ordinary run")
                }
                let healed = await manager.debugRunCatalogProjection(for: nextRunID)
                XCTAssertEqual(healed?.expectedSurface, healed?.returnedSurface)
                XCTAssertEqual(healed?.returnedSurface, stuck.expectedSurface)
                XCTAssertNil(session.codexSessionLinkCatalogRepairCycle)
                XCTAssertEqual(session.codexConversationID, conversationID)
                XCTAssertEqual(session.codexRolloutPath, rolloutPath)
                await cleanup(manager: manager, runID: nextRunID, connectionID: nextConnectionID, windowID: window.windowID)
            }
        #else
            throw XCTSkip("Run catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    #if DEBUG
        private func installRoutingSnapshot(for tabID: UUID, in window: WindowState) async throws {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Run catalog observation \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let switchResult = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "runCatalogObservationInitial"
            )
            XCTAssertEqual(switchResult, .switched)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(id: tabID, name: "Run catalog observation")
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabID
            let reloadResult = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
                window.workspaceManager.workspaces[workspaceIndex],
                reason: "runCatalogObservationTab"
            )
            XCTAssertEqual(reloadResult, .switched)
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        }

        private func makeWindow() -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            return window
        }

        private func installAuthoritativePolicy(
            manager: ServerNetworkManager,
            runID: UUID,
            tabID: UUID,
            windowID: Int,
            allowsAgentExternalControlTools: Bool = false
        ) async {
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "Restored oversight catalog repair integration test",
                ttl: 10,
                tabID: tabID,
                runID: runID,
                additionalTools: nil,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                requiresExpectedAgentPID: true
            )
        }

        private func cleanup(
            manager: ServerNetworkManager,
            runID: UUID,
            connectionID: UUID,
            windowID: Int
        ) async {
            await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
            await manager.removeConnection(connectionID)
            await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
        }

    #endif
}

#if DEBUG
    private actor CatalogRepairPolicyAuthorityTestConnection: MCPServerConnection {
        private var toolListChangedCount = 0

        func notificationCount() -> Int {
            toolListChangedCount
        }

        nonisolated var isFilesystemBacked: Bool {
            false
        }

        nonisolated var connectionFolderURL: URL? {
            nil
        }

        nonisolated var capabilityToken: String? {
            nil
        }

        func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}
        func stop() async {}
        func abortForExecutionWatchdog(context _: MCPExecutionWatchdogTerminalContext) async {}
        func notifyToolListChanged() async {
            toolListChangedCount += 1
        }

        func connectionState() -> ConnectionStateSnapshot {
            .ready
        }

        func isViableForRetention() -> Bool {
            true
        }

        func secondsSinceLastActivity() async -> TimeInterval {
            0
        }

        func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
            nil
        }

        func responseDeliverySnapshot() async -> MCPResponseDeliverySnapshot? {
            nil
        }

        func terminate(reason _: TerminationReason, message _: String?) async {}
        func sendProgress(
            tool _: String,
            kind _: RepoPromptProgressKind,
            stage _: String,
            message _: String
        ) async {}
    }
#endif

#if DEBUG
    /// Pins RP's live absent-to-present discovery, not any vendor's model-side tool cache.
    @MainActor
    final class AgentSessionLinkLiveDiscoveryTests: XCTestCase {
        func testUserOverseeGrantRefreshesExactAgentRouteDuringHeldProviderTurn() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery()
            }
        }

        func testBecomeOverseerRefreshesExactAgentRouteWithoutGrantDuringHeldTurn() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(activate: true)
            }
        }

        func testFamilyDisableAndReenableBeforeProofSubscriptionRejectsOriginalInvocation() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(activate: true, originalQualificationFamilyABA: true)
            }
        }

        func testUnrelatedConnectionAndRunPolicyChurnPreservesPendingBootstrap() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(activate: true, proofMutation: .unrelatedRoute)
            }
        }

        func testExactConnectionPolicyABADuringQualificationRejectsPendingBootstrap() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(activate: true, proofMutation: .exactConnectionPolicyABA)
            }
        }

        func testW0fClaudeReturnedCatalogConvergesAfterLateGrant() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode)
            }
        }

        func testW0fCodexReturnedCatalogNeverRepairsQuietOnlyChanges() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .codexExec)
            }
        }

        func testW2RegisteredNoopKeepsFinalQuietFactsWhenHostCallbacksAreQueued() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                for delayed in [false, true] {
                    try await MCPSharedServerTestLease.shared.withLease { _ in
                        try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .terminal(delayed: delayed, nativeResult: true))
                    }
                }
            }
        }

        func testW2ClosingTextAfterAcceptedBodySurvivesQueuedCanonicalRows() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                for delayed in [false, true] {
                    try await MCPSharedServerTestLease.shared.withLease { _ in
                        try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .terminal(delayed: delayed, nativeResult: true, closing: true))
                    }
                }
            }
        }

        func testW2LeadingTextRemainsOrdinaryWithQueuedDeclaration() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .terminal(delayed: true, nativeResult: true, leading: true))
                }
            }
        }

        func testW2RunServiceStopDuringQueuedObservationCutSettlesExactlyOnce() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .terminal(delayed: true, nativeResult: true, closing: true, cancel: true))
                }
            }
        }

        func testW2RegisteredNoopWithoutNativeResultRemainsOrdinaryAfterQueuedHostDrain() async throws {
            for kind in [AgentProviderKind.claudeCode, .codexExec] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: kind, w2Probe: .terminal(delayed: true, nativeResult: false))
                }
            }
        }

        func testW2SameRouteCatalogWithdrawalDuringLocalProofRemovesActualSentHint() async throws {
            for withdraw in [false, true] {
                try await MCPSharedServerTestLease.shared.withLease { _ in
                    try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .hint(withdraw: withdraw))
                }
            }
        }

        func testW2ProductionCatalogProofHandoffCostWithActualAndTenfoldCatalog() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(w0fProvider: .claudeCode, w2Probe: .catalogCost)
            }
        }

        private enum W2Probe {
            case terminal(delayed: Bool, nativeResult: Bool, closing: Bool = false, leading: Bool = false, cancel: Bool = false)
            case hint(withdraw: Bool)
            case catalogCost
        }

        private enum ProofMutation {
            case unrelatedRoute
            case exactConnectionPolicyABA
        }

        func testInboundCreationPromotesReducedCatalogToFullDuringHeldTurn() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseLiveDiscovery(inbound: true)
            }
        }

        private func exerciseLiveDiscovery(
            activate: Bool = false, inbound: Bool = false, originalQualificationFamilyABA: Bool = false,
            proofMutation: ProofMutation? = nil, w0fProvider: AgentProviderKind? = nil,
            w2Probe: W2Probe? = nil
        ) async throws {
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let manager = ServerNetworkManager.shared
            let window = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
            WindowStatesManager.shared.registerWindowState(window)
            WindowStatesManager.shared.attachAgentSessionLinkBridge()
            let bridge = AgentSessionLinkRuntimeBridge.shared
            let authority = AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority
            let provider = HeldDiscoveryProvider()
            let codexRecorder = LifecycleRecorder()
            let codex = LifecycleNoopCodexController(recorder: codexRecorder)
            let clientName = w0fProvider == .codexExec ? AgentProviderKind.codexMCPClientID : AgentProviderKind.claudeMCPClientID
            let w0fKind = w0fProvider ?? .claudeCode
            let runID = UUID()
            var transport: PersistentMCPTestEndpoint?
            var grant: DomainAgentSessionLinkReference?
            let catalogGate = DiscoveryCatalogGate()
            let disabledCatalogGate = DiscoveryCatalogGate()
            let qualificationGate = DiscoveryCatalogGate()
            var pendingBootstrap: Task<PersistentMCPTestRPCResponse, Error>?
            let unrelatedRunID = UUID()
            let unrelatedClientName = "proof-unrelated-\(UUID())"
            var unrelatedTransport: PersistentMCPTestEndpoint?
            var catalogDisabledForTesting = false
            var delayedCatalog: Task<Set<String>, Error>?
            let registration = try await AppDomainRuntimeComposition.shared.register(window.mcpServer.windowMCPToolCatalogService)
            let cleanup: @MainActor () async -> Void = {
                await manager.debugSetReturnedCatalogToolsForTesting(nil)
                await manager.debugSetAfterExpectedCatalogSurfaceForTesting(nil)
                await manager.debugSetAfterBecomeOverseerProofRegistrationForTesting(nil)
                await qualificationGate.release()
                _ = await pendingBootstrap?.result
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.becomeOverseer, operation: nil)
                await catalogGate.release()
                await disabledCatalogGate.release()
                _ = await delayedCatalog?.result
                if catalogDisabledForTesting { await manager.setEnabled(true) }
                if let grant { await bridge.revokeLink(linkID: grant.linkID, generation: grant.generation) }
                await provider.shutdown()
                if let unrelatedTransport {
                    unrelatedTransport.client.close()
                    await unrelatedTransport.connectionManager.stop()
                    await manager.debugRemoveConnection(unrelatedTransport.connectionID)
                }
                if case .unrelatedRoute? = proofMutation {
                    await manager.clearClientConnectionPolicy(for: unrelatedClientName, windowID: window.windowID, runID: unrelatedRunID)
                    await manager.cleanupRunRoutingState(for: unrelatedRunID, windowID: window.windowID)
                }
                if let transport {
                    transport.client.close()
                    await transport.connectionManager.stop()
                    await manager.debugRemoveConnection(transport.connectionID)
                }
                await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)
                await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                await window.tearDown()
                await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            do {
                await window.workspaceManager.awaitInitialized()
                let observerTab = UUID()
                let targetTab = UUID()
                let observerID = UUID()
                let targetID = UUID()
                var workspace = WorkspaceModel(name: "Live discovery", repoPaths: [])
                workspace.isEphemeral = true
                workspace.composeTabs = [
                    ComposeTabState(id: observerTab, name: "User-created planning chat", activeAgentSessionID: observerID),
                    ComposeTabState(id: targetTab, name: "Harmless idle target", activeAgentSessionID: targetID)
                ]
                workspace.activeComposeTabID = observerTab
                // Restoration must earn both runtime readiness and owner-valid placement metadata.
                // A fabricated loaded latch has no index row until an unrelated debounced save wins.
                for tab in workspace.composeTabs {
                    let payload = try AgentSession(
                        id: XCTUnwrap(tab.activeAgentSessionID), workspaceID: workspace.id,
                        composeTabID: tab.id, name: tab.name, agentKind: w0fKind.rawValue,
                        autoWakeOnOversightUpdates: false
                    )
                    _ = try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace)
                }
                window.workspaceManager.workspaces.append(workspace)
                let switched = await window.workspaceManager.switchWorkspace(to: workspace, saveState: false)
                XCTAssertTrue(switched.didSwitch)
                window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
                let vm = window.agentModeViewModel
                let observer = await vm.ensureSessionReady(tabID: observerTab, reconnectActiveProviders: false)
                let target = await vm.ensureSessionReady(tabID: targetTab, reconnectActiveProviders: false)
                for (session, expectedID) in [(observer, observerID), (target, targetID)] {
                    XCTAssertEqual(session.activeAgentSessionID, expectedID)
                    XCTAssertEqual(session.selectedAgent, w0fKind)
                    XCTAssertTrue(session.qualifiedRestorationReadiness.isAuthoritative)
                    XCTAssertEqual(vm.ownerValidatedSessionIndex[expectedID]?.tabID, session.tabID)
                    let projector = SpawnProvenanceDelegationMembershipProjector.production(worktreeOwnership: bridge.worktreeOwnership)
                    XCTAssertEqual(projector.pointResolutionState(for: expectedID), .unique)
                    XCTAssertFalse(projector.authorityConflictInAncestry(of: expectedID))
                }
                let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(vm, tabID: observerTab)
                XCTAssertNil(observer.parentSessionID)
                XCTAssertFalse(observer.isMCPOriginated)
                XCTAssertNil(observer.mcpControlContext)
                XCTAssertFalse(vm.isMCPControlled(tabID: observerTab))
                let initialLinks = await authority.links(forObserver: observerID)
                XCTAssertTrue(initialLinks.items.isEmpty)
                if inbound {
                    guard case .added = await bridge.addMonitorLink(observerSessionID: targetID, rawTargetSessionID: observerID.uuidString) else {
                        throw DiscoveryFailure.overseeRefused
                    }
                    let links = await authority.links(forObserver: targetID)
                    let link = try XCTUnwrap(links.items.first)
                    grant = .init(linkID: link.linkID, generation: link.generation)
                }

                observer.installRunID(runID)
                if w0fProvider == .codexExec {
                    observer.codexController = codex
                    _ = try await codex.startOrResume(existing: nil, baseInstructions: "")
                    _ = try await codex.startUserTurn(text: "", images: [], model: nil, reasoningEffort: nil, serviceTier: nil)
                } else {
                    observer.claudeController = provider
                }
                if w0fProvider != nil {
                    await manager.debugSetReturnedCatalogToolsForTesting(Self.w0fReturnedShape())
                }
                observer.runState = .running
                // Install the ordinary restricted Agent policy BEFORE initialize/tools/list. This
                // transport is never an external unrestricted caller that is converted after the fact.
                await manager.installClientConnectionPolicy(
                    for: clientName, windowID: window.windowID,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true,
                    reason: "Live Oversee discovery regression", ttl: 60, tabID: observerTab,
                    runID: runID, additionalTools: nil, purpose: .agentModeRun,
                    taskLabelKind: nil, allowsAgentExternalControlTools: false
                )
                await manager.setEnabled(true)
                let connection = try await PersistentMCPTestEndpoint.make(
                    label: "held-provider", networkManager: manager,
                    clientName: clientName, requiredToolNames: [MCPWindowToolName.readFile]
                )
                transport = connection
                await provider.attach(connection)
                let turnID = try await provider.sendUserMessage("Hold this synthetic turn until the test releases it.")
                let heldTurn = await provider.heldTurnSnapshot
                XCTAssertEqual(heldTurn.activeTurnID, turnID)
                let before = try await provider.listTools()
                XCTAssertEqual(before.contains(MCPWindowToolName.agentSessionLink), inbound)
                XCTAssertTrue(before.contains(MCPWindowToolName.becomeOverseer), "Inbound discovery requests no additional authority")
                let beforeDefinitions = try await provider.definitions(wireCaptureName: inbound ? "inbound-before" : (activate ? "activation-before" : "grant-before"))
                try DiscoveryArtifactCapture.write(beforeDefinitions, name: inbound ? "inbound-before" : (activate ? "activation-before" : "grant-before"))
                if inbound {
                    let reduced = try XCTUnwrap(beforeDefinitions.first { $0["name"] as? String == MCPWindowToolName.agentSessionLink })
                    XCTAssertEqual(DiscoveryArtifactCapture.operations(reduced), ["set_waiting_on", "request_attention", "create_lane"])
                }
                let policy = await manager.debugConnectionPolicyState(for: connection.connectionID)
                XCTAssertEqual(policy.purpose, .agentModeRun)
                XCTAssertEqual(policy.windowID, window.windowID)
                XCTAssertEqual(policy.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
                let routeBefore = await manager.authoritativeRunCatalogRouteToken(runID: runID, windowID: window.windowID, tabID: observerTab)
                let route = try XCTUnwrap(routeBefore)
                XCTAssertEqual(route.connectionID, connection.connectionID)
                XCTAssertEqual(route.observerEndpoint, endpoint)
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], connection.connectionID)

                if w0fProvider != nil {
                    let initial = try await w0fProjection(manager, runID)
                    let supported = await manager.hasCurrentReturnedTool(Self.w0fTool(), routeToken: route, projectionRevision: initial.projectionRevision)
                    XCTAssertFalse(supported, "A started provider without the returned definition has no positive support")
                }

                if originalQualificationFamilyABA || proofMutation != nil {
                    let registered = expectation(description: "Exact observed proof registered before async qualification")
                    await manager.debugSetAfterBecomeOverseerProofRegistrationForTesting { _, sampledEndpoint in
                        guard sampledEndpoint == endpoint else { return }
                        registered.fulfill()
                        await qualificationGate.hold()
                    }
                    pendingBootstrap = Task {
                        try await connection.callTool(name: MCPWindowToolName.becomeOverseer, arguments: [:], timeoutSeconds: 5)
                    }
                    await fulfillment(of: [registered], timeout: 2)
                    if let proofMutation {
                        switch proofMutation {
                        case .unrelatedRoute:
                            target.installRunID(unrelatedRunID)
                            await manager.installClientConnectionPolicy(
                                for: unrelatedClientName, windowID: window.windowID,
                                restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true,
                                reason: "Unrelated route churn while bootstrap is parked", ttl: 60, tabID: targetTab,
                                runID: unrelatedRunID, additionalTools: nil, purpose: .agentModeRun,
                                taskLabelKind: nil, allowsAgentExternalControlTools: false
                            )
                            let unrelated = try await PersistentMCPTestEndpoint.make(
                                label: "unrelated-proof-route", networkManager: manager,
                                clientName: unrelatedClientName, requiredToolNames: [MCPWindowToolName.readFile]
                            )
                            unrelatedTransport = unrelated
                            let unrelatedPolicy = await manager.debugConnectionPolicyState(for: unrelated.connectionID)
                            XCTAssertEqual(unrelatedPolicy.purpose, .agentModeRun)
                            XCTAssertEqual(unrelatedPolicy.windowID, window.windowID)
                            unrelated.client.close()
                            await unrelated.connectionManager.stop()
                            await manager.debugRemoveConnection(unrelated.connectionID)
                            unrelatedTransport = nil
                            await manager.clearClientConnectionPolicy(for: unrelatedClientName, windowID: window.windowID, runID: unrelatedRunID)
                            await manager.cleanupRunRoutingState(for: unrelatedRunID, windowID: window.windowID)
                        case .exactConnectionPolicyABA:
                            await manager.debugSetAdditionalTools(
                                for: connection.connectionID, additionalTools: policy.additionalTools.union([MCPWindowToolName.getFileTree])
                            )
                            await manager.debugSetAdditionalTools(for: connection.connectionID, additionalTools: policy.additionalTools)
                            let restored = await manager.debugConnectionPolicyState(for: connection.connectionID)
                            XCTAssertEqual(restored.additionalTools, policy.additionalTools)
                        }
                        let routeAfter = await manager.authoritativeRunCatalogRouteToken(runID: runID, windowID: window.windowID, tabID: observerTab)
                        XCTAssertEqual(routeAfter, route, "The original exact route remains current; policy ABA must still revoke its old proof")
                        let policyAfter = await manager.debugConnectionPolicyState(for: connection.connectionID)
                        XCTAssertEqual(policyAfter.restrictedTools, policy.restrictedTools)
                        XCTAssertEqual(policyAfter.additionalTools, policy.additionalTools)
                        XCTAssertEqual(policyAfter.purpose, policy.purpose)
                        XCTAssertEqual(policyAfter.windowID, policy.windowID)
                        await manager.debugSetAfterBecomeOverseerProofRegistrationForTesting(nil)
                        await qualificationGate.release()
                        let response = try await XCTUnwrap(pendingBootstrap).value
                        let result = try XCTUnwrap(try MCPExportWatchdogIntegrationTests.responseObject(from: response)["result"] as? [String: Any])
                        let links = await authority.links(forObserver: observerID)
                        XCTAssertTrue(links.items.isEmpty, "Bootstrap never manufactures a link")
                        switch proofMutation {
                        case .unrelatedRoute:
                            XCTAssertNotEqual(result["isError"] as? Bool, true, "Unrelated connection/run churn must not revoke this invocation: \(response.rawJSON)")
                            XCTAssertNotNil(observer.oversight.overseerActivation)
                            let tools = try await provider.listTools()
                            XCTAssertTrue(tools.contains(MCPWindowToolName.agentSessionLink))
                            XCTAssertTrue(tools.contains(MCPWindowToolName.becomeOverseer), "Targeted bootstrap remains available after activation")
                        case .exactConnectionPolicyABA:
                            XCTAssertEqual(result["isError"] as? Bool, true, "Exact-connection policy ABA must latch revocation: \(response.rawJSON)")
                            XCTAssertNil(observer.oversight.overseerActivation)
                        }
                        await cleanup()
                        return
                    }
                    let store = ToolAvailabilityStore.shared
                    let beforeDisabled = store.disabledTools
                    let beforePersisted = UserDefaults.standard.object(forKey: "mcp.disabledTools") as? [String]
                    XCTAssertTrue(store.isEnabled(MCPWindowToolName.agentSessionLink))
                    var disabledProposals: [Bool] = []
                    let availabilityProbe = store.$disabledTools.sink { names in
                        disabledProposals.append(names.contains(MCPWindowToolName.agentSessionLink))
                    }
                    defer { availabilityProbe.cancel() }
                    // Keep the original RED schedule's gate after registry insertion. Observation
                    // now precedes the first network check, so this withdrawal must already be latched.
                    // Use real @Published mutations without defaults or delayed broadcast work.
                    store.debugDisableAndReenableWithoutPersistenceForTesting(MCPWindowToolName.agentSessionLink)
                    XCTAssertEqual(disabledProposals, [false, true, false], "Withdrawal and restoration both completed during registered proof qualification")
                    XCTAssertEqual(store.disabledTools, beforeDisabled)
                    XCTAssertEqual(UserDefaults.standard.object(forKey: "mcp.disabledTools") as? [String], beforePersisted)
                    await manager.debugSetAfterBecomeOverseerProofRegistrationForTesting(nil)
                    await qualificationGate.release()
                    let response = try await XCTUnwrap(pendingBootstrap).value
                    let result = try XCTUnwrap(try MCPExportWatchdogIntegrationTests.responseObject(from: response)["result"] as? [String: Any])
                    let links = await authority.links(forObserver: observerID)
                    XCTAssertTrue(links.items.isEmpty, "Bootstrap must never manufacture a link")
                    XCTAssertEqual(result["isError"] as? Bool, true, "Original invocation crossed a family withdrawal during qualification: \(response.rawJSON)")
                    XCTAssertNil(observer.oversight.overseerActivation, "Disable/re-enable at the original qualification gate must invalidate the invocation")
                    await cleanup()
                    return
                }

                if activate {
                    // Network-owner proof test through a real admitted invocation, before opt-in.
                    // The override only tests the commit fence; it never activates or invents grants.
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.becomeOverseer) {
                        let invocation = try MCPInvocationContextBridge.require(
                            toolName: MCPWindowToolName.becomeOverseer, expectedWindowID: endpoint.windowID
                        )
                        let observed = await MCPBecomeOverseerActivationProof.prepareObservingFamily(
                            invocation: invocation, endpoint: endpoint
                        )
                        let observedProof = try XCTUnwrap(observed)
                        let issued = await manager.issueBecomeOverseerActivationProof(
                            invocation: invocation, endpoint: endpoint, observedProof: observedProof
                        )
                        let proof = try XCTUnwrap(issued)
                        await manager.setEnabled(false)
                        await manager.setEnabled(true)
                        let committed = await proof.commitIfCurrent(invocation: invocation, endpoint: endpoint) { true }
                        proof.invalidate()
                        return .object(["committed": .bool(committed)])
                    }
                    let deniedCommit = try await connection.callTool(name: MCPWindowToolName.becomeOverseer, arguments: ["_rawJSON": true], timeoutSeconds: 2)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.becomeOverseer, operation: nil)
                    let object = try MCPExportWatchdogIntegrationTests.responseObject(from: deniedCommit)
                    let result = try XCTUnwrap(object["result"] as? [String: Any])
                    XCTAssertNotEqual(result["isError"] as? Bool, true, deniedCommit.rawJSON)
                    let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                    let text = content.compactMap { $0["text"] as? String }.joined()
                    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    XCTAssertEqual(payload["committed"] as? Bool, false, "Global disable/re-enable must not resurrect the synchronous commit fence")
                    XCTAssertNil(observer.oversight.overseerActivation)
                    let noLinks = await authority.links(forObserver: observerID)
                    XCTAssertTrue(noLinks.items.isEmpty)
                }

                let received = expectation(description: "Actual tools/list_changed frame on the provider's socket")
                received.assertForOverFulfill = false
                let frames = DiscoveryNotificationFrames()
                connection.client.observeNotifications { data in
                    if frames.captureListChanged(data) { received.fulfill() }
                }
                if activate {
                    let paused = expectation(description: "tools/list sampled bootstrap before activation")
                    await manager.debugSetAfterExpectedCatalogSurfaceForTesting {
                        await catalogGate.hold { paused.fulfill() }
                    }
                    delayedCatalog = Task { try await provider.listTools() }
                    await fulfillment(of: [paused], timeout: 2)
                    await manager.debugSetAfterExpectedCatalogSurfaceForTesting(nil)
                }
                // Catalog/activation requests and notification waits retain their two-second watchdogs.
                // Prove refresh is independent of turn completion and the deliberately held catalog
                // response; aggregate elapsed time also includes their serial setup and actor hops.
                let clock = ContinuousClock()
                let start = clock.now
                var expectedTargetID = targetID
                if activate {
                    let response = try await connection.callTool(name: MCPWindowToolName.becomeOverseer, arguments: [:], timeoutSeconds: 2)
                    XCTAssertNotNil(try MCPExportWatchdogIntegrationTests.responseObject(from: response)["result"] as? [String: Any])
                    let noLinks = await authority.links(forObserver: observerID)
                    XCTAssertTrue(noLinks.items.isEmpty, "Activation manufactures no grants")
                    XCTAssertNotNil(observer.oversight.overseerActivation)
                } else if !inbound {
                    let added = await bridge.addMonitorLink(observerSessionID: observerID, rawTargetSessionID: targetID.uuidString)
                    guard case .added = added else {
                        XCTFail("Real user Oversee Add failed: \(added)")
                        throw DiscoveryFailure.overseeRefused
                    }
                }
                if inbound {
                    window.apiSettingsViewModel.isClaudeCodeConnected = true
                    try await AsyncTestWait.waitUntil("fixture destination availability") { window.apiSettingsViewModel.agentAvailability.claudeCodeAvailable }
                    AgentAdvertisedModelCatalog.shared.record([AgentModelOption(rawValue: "sonnet:high", displayName: "Fixture model", description: nil, isPlaceholderDefault: false, isProviderDefault: false)], for: .claudeCode, generation: AgentAdvertisedModelCatalog.shared.productionGeneration(for: .claudeCode))
                    defer { AgentAdvertisedModelCatalog.shared.invalidate(.claudeCode) }
                    let created = try await connection.callTool(name: MCPWindowToolName.agentSessionLink, arguments: ["op": "create_lane", "model_id": "claudeCode:sonnet:high", "idempotency_key": "discovery-first-lane", "session_name": "Harmless created lane", "_rawJSON": true], timeoutSeconds: 10)
                    let object = try MCPExportWatchdogIntegrationTests.responseObject(from: created)
                    let result = try XCTUnwrap(object["result"] as? [String: Any])
                    XCTAssertNotEqual(result["isError"] as? Bool, true, created.rawJSON)
                    let createdContent = try XCTUnwrap(result["content"] as? [[String: Any]])
                    let createdText = createdContent.compactMap { $0["text"] as? String }.joined()
                    let createdReceipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(createdText.utf8)) as? [String: Any])
                    XCTAssertEqual(createdReceipt["result"] as? String, "created", created.rawJSON)
                    XCTAssertEqual(createdReceipt["linked"] as? Bool, true, created.rawJSON)
                    let inventory = await authority.links(forObserver: observerID)
                    expectedTargetID = try XCTUnwrap(inventory.items.first?.targetSessionID)
                    XCTAssertNil(observer.oversight.overseerActivation, "Inbound creation needs no bootstrap")
                }
                let inventory = await authority.links(forObserver: observerID)
                let item = inventory.items.first { $0.targetSessionID == expectedTargetID }
                if let item, !inbound { grant = DomainAgentSessionLinkReference(linkID: item.linkID, generation: item.generation) }
                await fulfillment(of: [received], timeout: 2)
                XCTAssertFalse(frames.snapshot.isEmpty)
                let turnAtNotification = await provider.heldTurnSnapshot
                XCTAssertEqual(turnAtNotification, heldTurn, "Discovery must notify without interrupting, restarting, or completing the held turn")
                if activate {
                    let staleCatalogIsHeld = await catalogGate.isHeld
                    XCTAssertTrue(staleCatalogIsHeld, "The real notification must arrive before the older tools/list response is released")
                    await catalogGate.release()
                    let stale = try await XCTUnwrap(delayedCatalog).value
                    XCTAssertTrue(stale.contains(MCPWindowToolName.becomeOverseer))
                    XCTAssertFalse(stale.contains(MCPWindowToolName.agentSessionLink))
                    let observed = await manager.debugRunCatalogProjection(for: runID)
                    let projection = try XCTUnwrap(observed)
                    XCTAssertNotEqual(projection.expectedSurface, projection.returnedSurface, "A late bootstrap completion must preserve newer full expectations")
                    XCTAssertTrue(AgentSessionLinkCodexCatalogRepair.isStuckProjection(projection))
                }
                if w0fProvider != nil {
                    await bridge.test_settleProjections()
                    let stale = try await w0fProjection(manager, runID)
                    let supported = await manager.hasCurrentReturnedTool(Self.w0fTool(), routeToken: route, projectionRevision: stale.projectionRevision)
                    XCTAssertFalse(supported, "A grant/notification is not returned tool evidence")
                }
                let after = try await provider.listTools()
                let visibleElapsed = start.duration(to: clock.now)
                let turnAtVisibleCatalog = await provider.heldTurnSnapshot
                XCTAssertEqual(turnAtVisibleCatalog, heldTurn, "The refreshed catalog must be observable on the same uninterrupted provider turn")
                XCTAssertTrue(after.contains(MCPWindowToolName.agentSessionLink))
                XCTAssertTrue(after.contains(MCPWindowToolName.becomeOverseer), "Targeted bootstrap remains discoverable in the continuing flow")
                if let w2Probe {
                    switch w2Probe {
                    case let .terminal(delayed, nativeResult, closing, leading, cancel):
                        try await w2RegisteredTerminal(window: window, session: observer, connection: connection, runID: runID, delayed: delayed, nativeResult: nativeResult, closing: closing, leading: leading, cancel: cancel)
                    case let .hint(withdraw):
                        try await w2CatalogProof(window: window, session: observer, provider: provider, endpoint: endpoint, route: route, runID: runID, withdraw: withdraw)
                    case .catalogCost:
                        try await w2CatalogCost(window: window, session: observer, provider: provider, endpoint: endpoint, runID: runID, inactiveTabID: targetTab)
                    }
                    await cleanup()
                    return
                }
                if let w0fProvider {
                    try await w0fRepairControls(manager: manager, provider: provider, window: window, observer: observer, endpoint: endpoint, route: route, runID: runID, kind: w0fProvider, codex: codex, codexRecorder: codexRecorder)
                    await cleanup()
                    return
                }
                let afterDefinitions = try await provider.definitions(wireCaptureName: inbound ? "inbound-after" : (activate ? "activation-after" : "grant-after"))
                try DiscoveryArtifactCapture.write(afterDefinitions, name: inbound ? "inbound-after" : (activate ? "activation-after" : "grant-after"))
                let full = try XCTUnwrap(afterDefinitions.first { $0["name"] as? String == MCPWindowToolName.agentSessionLink })
                XCTAssertGreaterThan(DiscoveryArtifactCapture.operations(full).count, 3)
                if activate {
                    let noLinks = await authority.links(forObserver: observerID)
                    XCTAssertTrue(noLinks.items.isEmpty)
                    let stable = await manager.debugRunCatalogProjection(for: runID)
                    XCTAssertEqual(stable?.expectedSurface, stable?.returnedSurface)
                    XCTAssertEqual(stable?.hasAnyActiveLink, false)
                    XCTAssertEqual(stable?.isReady, false, "Activation is never prompt authority")
                    let frameCount = frames.snapshot.count
                    await manager.notifyToolListChangedForAgentSession(observerID)
                    _ = try await provider.listTools()
                    XCTAssertEqual(frames.snapshot.count, frameCount, "Stable full/no-link must not loop notices")

                    // Configuration-only overlap: activation and link membership remain unchanged.
                    // The old full list must merge its returned evidence with the newer empty
                    // expectation, not restore equality from its pre-disable shaping snapshot.
                    let fullProjection = try XCTUnwrap(stable)
                    let fullSurface = try XCTUnwrap(fullProjection.expectedSurface)
                    let emptySurface = Data("[]".utf8)
                    let paused = expectation(description: "tools/list sampled activated full before global MCP disable")
                    await manager.debugSetAfterExpectedCatalogSurfaceForTesting {
                        paused.fulfill()
                        await disabledCatalogGate.hold()
                    }
                    delayedCatalog = Task { try await provider.listTools() }
                    await fulfillment(of: [paused], timeout: 2)
                    await manager.debugSetAfterExpectedCatalogSurfaceForTesting(nil)
                    catalogDisabledForTesting = true
                    await manager.setEnabled(false)
                    await manager.notifyToolListChangedForAgentSession(observerID)
                    let disabledObservation = await manager.debugRunCatalogProjection(for: runID)
                    let disabledProjection = try XCTUnwrap(disabledObservation)
                    XCTAssertGreaterThan(disabledProjection.projectionRevision, fullProjection.projectionRevision)
                    XCTAssertEqual(disabledProjection.expectedSurface, emptySurface)
                    XCTAssertEqual(disabledProjection.returnedSurface, fullSurface)
                    XCTAssertEqual(disabledProjection.hasAnyActiveLink, fullProjection.hasAnyActiveLink)
                    XCTAssertEqual(disabledProjection.hasActiveOutboundLink, fullProjection.hasActiveOutboundLink)
                    XCTAssertNotNil(observer.oversight.overseerActivation)
                    XCTAssertTrue(AgentSessionLinkCodexCatalogRepair.isStuckProjection(disabledProjection))
                    XCTAssertFalse(AgentSessionLinkCodexCatalogRepair.projectionResolvesCycle(disabledProjection))

                    await disabledCatalogGate.release()
                    let lateFull = try await XCTUnwrap(delayedCatalog).value
                    XCTAssertTrue(lateFull.contains(MCPWindowToolName.agentSessionLink))
                    let lateObservation = await manager.debugRunCatalogProjection(for: runID)
                    let lateProjection = try XCTUnwrap(lateObservation)
                    XCTAssertGreaterThan(lateProjection.projectionRevision, disabledProjection.projectionRevision)
                    XCTAssertEqual(lateProjection.routeToken, route)
                    XCTAssertEqual(lateProjection.expectedSurface, emptySurface, "Late full completion must preserve newer disabled expectations")
                    XCTAssertEqual(lateProjection.returnedSurface, fullSurface)
                    XCTAssertEqual(lateProjection.hasAnyActiveLink, fullProjection.hasAnyActiveLink)
                    XCTAssertEqual(lateProjection.hasActiveOutboundLink, fullProjection.hasActiveOutboundLink)
                    XCTAssertFalse(lateProjection.isReady, "Activation still grants no prompt authority")
                    XCTAssertTrue(AgentSessionLinkCodexCatalogRepair.isStuckProjection(lateProjection))
                    XCTAssertFalse(AgentSessionLinkCodexCatalogRepair.projectionResolvesCycle(lateProjection))

                    let emptyList = try await provider.listTools()
                    XCTAssertFalse(emptyList.contains(MCPWindowToolName.agentSessionLink))
                    XCTAssertFalse(emptyList.contains(MCPWindowToolName.becomeOverseer))
                    let freshObservation = await manager.debugRunCatalogProjection(for: runID)
                    let freshProjection = try XCTUnwrap(freshObservation)
                    XCTAssertEqual(freshProjection.expectedSurface, emptySurface)
                    XCTAssertEqual(freshProjection.returnedSurface, emptySurface)
                    XCTAssertEqual(freshProjection.hasAnyActiveLink, fullProjection.hasAnyActiveLink)
                    XCTAssertEqual(freshProjection.hasActiveOutboundLink, fullProjection.hasActiveOutboundLink)
                    XCTAssertFalse(freshProjection.isReady)
                    XCTAssertFalse(AgentSessionLinkCodexCatalogRepair.isStuckProjection(freshProjection))
                    XCTAssertTrue(AgentSessionLinkCodexCatalogRepair.projectionResolvesCycle(freshProjection))
                    XCTAssertNotNil(observer.oversight.overseerActivation)

                    await manager.setEnabled(true)
                    catalogDisabledForTesting = false
                    await manager.notifyToolListChangedForAgentSession(observerID)
                    let restored = try await provider.listTools()
                    XCTAssertTrue(restored.contains(MCPWindowToolName.agentSessionLink))
                    XCTAssertTrue(restored.contains(MCPWindowToolName.becomeOverseer), "Re-enabling oversight restores bootstrap too")
                }
                let response = try await provider.listLinks()
                let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
                let result = try XCTUnwrap(object["result"] as? [String: Any])
                // An activated Overseer with no links lists an empty inventory instead of an error.
                XCTAssertNotEqual(result["isError"] as? Bool, true, response.rawJSON)
                let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                let text = content.compactMap { $0["text"] as? String }.joined()
                if activate {
                    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    XCTAssertEqual((payload["items"] as? [[String: Any]])?.count, 0)
                }
                if !activate {
                    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    let listed = try XCTUnwrap(payload["items"] as? [[String: Any]])
                    XCTAssertEqual(listed.count, 1)
                    XCTAssertEqual(listed.first?["session_id"] as? String, expectedTargetID.uuidString)
                    XCTAssertEqual(listed.first?["link_id"] as? String, item?.linkID.uuidString)
                    XCTAssertEqual(listed.first?["managed"] as? Bool, true)
                }
                if activate {
                    window.apiSettingsViewModel.isClaudeCodeConnected = true
                    try await AsyncTestWait.waitUntil("activated fixture destination availability") { window.apiSettingsViewModel.agentAvailability.claudeCodeAvailable }
                    AgentAdvertisedModelCatalog.shared.record([AgentModelOption(rawValue: "sonnet:high", displayName: "Fixture model", description: nil, isPlaceholderDefault: false, isProviderDefault: false)], for: .claudeCode, generation: AgentAdvertisedModelCatalog.shared.productionGeneration(for: .claudeCode))
                    defer { AgentAdvertisedModelCatalog.shared.invalidate(.claudeCode) }
                    let created = try await connection.callTool(name: MCPWindowToolName.agentSessionLink, arguments: ["op": "create_lane", "model_id": "claudeCode:sonnet:high", "idempotency_key": "activated-discovery-first-lane", "_rawJSON": true], timeoutSeconds: 10)
                    let object = try MCPExportWatchdogIntegrationTests.responseObject(from: created)
                    let result = try XCTUnwrap(object["result"] as? [String: Any])
                    XCTAssertNotEqual(result["isError"] as? Bool, true, created.rawJSON)
                    let createdContent = try XCTUnwrap(result["content"] as? [[String: Any]])
                    let createdText = createdContent.compactMap { $0["text"] as? String }.joined()
                    let createdReceipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(createdText.utf8)) as? [String: Any])
                    XCTAssertEqual(createdReceipt["result"] as? String, "created", created.rawJSON)
                    XCTAssertEqual(createdReceipt["linked"] as? Bool, true, created.rawJSON)
                    let inventory = await authority.links(forObserver: observerID)
                    XCTAssertEqual(inventory.items.count, 1)
                    let link = try XCTUnwrap(inventory.items.first)
                    grant = .init(linkID: link.linkID, generation: link.generation)
                }
                let routeAfter = await manager.authoritativeRunCatalogRouteToken(runID: runID, windowID: window.windowID, tabID: observerTab)
                XCTAssertEqual(routeAfter, route)
                XCTAssertTrue(observer.claudeController === provider)
                XCTAssertEqual(observer.runID, runID)
                XCTAssertEqual(observer.runState, .running)
                let finalTurn = await provider.heldTurnSnapshot
                XCTAssertEqual(finalTurn, heldTurn, "No completion, interruption, restart, or controller replacement during discovery")
                XCTAssertNil(observer.parentSessionID)
                XCTAssertFalse(observer.isMCPOriginated)
                XCTAssertNil(observer.mcpControlContext)
                XCTAssertFalse(vm.isMCPControlled(tabID: observerTab))
                print("LIVE_OVERSEE_DISCOVERY scenario_to_visible=\(visibleElapsed) catalog_watchdog=2s notification_watchdog=2s held_turn_unchanged=\(finalTurn == heldTurn) connection=\(connection.connectionID) turn=\(turnID) notification=\(frames.snapshot)")
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
    }

    enum DiscoveryArtifactCapture {
        static func operations(_ tool: [String: Any]) -> [String] {
            let schema = tool["inputSchema"] as? [String: Any]
            let properties = schema?["properties"] as? [String: Any]
            return (properties?["op"] as? [String: Any])?["enum"] as? [String] ?? []
        }

        static func write(_ tools: [[String: Any]], name: String) throws {
            guard let directory = DiscoveryArtifactConfiguration.directory else { return }
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let family = tools.filter { [MCPWindowToolName.agentSessionLink, MCPWindowToolName.becomeOverseer].contains($0["name"] as? String ?? "") }
            let data = try JSONSerialization.data(withJSONObject: family, options: [.sortedKeys, .withoutEscapingSlashes])
            try data.write(to: root.appendingPathComponent(name + ".json"))
        }
    }

    private actor DiscoveryCatalogGate {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        var isHeld: Bool {
            continuation != nil && !released
        }

        func hold(onHeld: (@Sendable () -> Void)? = nil) async {
            guard !released else { return }
            await withCheckedContinuation {
                continuation = $0
                onHeld?()
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private enum DiscoveryFailure: Error {
        case overseeRefused
    }

    private final class DiscoveryNotificationFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [String] = []
        var snapshot: [String] {
            lock.withLock { frames }
        }

        func captureListChanged(_ data: Data) -> Bool {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "notifications/tools/list_changed", object["id"] == nil
            else { return false }
            return lock.withLock {
                frames.append(String(decoding: data, as: UTF8.self))
                return frames.count == 1
            }
        }
    }

    /// A controllable provider with a held turn and its own real Agent MCP client; never launches a CLI.
    actor HeldDiscoveryProvider: NativeAgentRuntimeControlling {
        struct HeldTurnSnapshot: Equatable {
            let activeTurnID: UUID?
            let lifecycleRevision: Int
        }

        private var connection: PersistentMCPTestEndpoint?
        private(set) var activeTurnID: UUID?
        private var lifecycleRevision = 0
        var heldTurnSnapshot: HeldTurnSnapshot {
            .init(activeTurnID: activeTurnID, lifecycleRevision: lifecycleRevision)
        }

        private var configuration = SessionLinkNativeConfigurationFixture()
        private let eventPair = AsyncStream<NativeAgentRuntimeEvent>.makeStream()
        var hasActiveSession: Bool {
            connection != nil
        }

        var hasTurnInFlight: Bool {
            activeTurnID != nil
        }

        var events: AsyncStream<NativeAgentRuntimeEvent> {
            eventPair.stream
        }

        func attach(_ connection: PersistentMCPTestEndpoint) {
            self.connection = connection
        }

        func ensureEventsStreamReady() {}
        func resetEventsStreamForNewRun() {
            lifecycleRevision += 1
        }

        func startOrResume(existingSessionID _: String?, model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?, systemPromptOverride _: String?) async throws -> NativeAgentRuntimeSessionRef {
            lifecycleRevision += 1
            return currentSessionRef()
        }

        func currentSessionRef() -> NativeAgentRuntimeSessionRef {
            .init(sessionID: "held-discovery-provider")
        }

        func applyModelAndEffort(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws {
            _ = configuration.apply()
        }

        func applyModelAndEffortWithProof(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws -> NativeAgentRuntimeConfigurationApplication {
            configuration.apply()
        }

        func sendUserMessage(_: String, configuration proof: NativeAgentRuntimeConfigurationProof) async throws -> UUID {
            try configuration.validate(proof)
            return try await sendUserMessage("")
        }

        func sendUserMessage(_: String) async throws -> UUID {
            let id = UUID()
            lifecycleRevision += 1
            activeTurnID = id
            return id
        }

        func listTools() async throws -> Set<String> {
            try await Set(definitions().compactMap { $0["name"] as? String })
        }

        func definitions(wireCaptureName: String? = nil) async throws -> [[String: Any]] {
            let connection = try XCTUnwrap(connection)
            let response = try await connection.client.request(method: "tools/list", params: [:], timeoutSeconds: 2)
            if let name = wireCaptureName, let directory = DiscoveryArtifactConfiguration.directory {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data(response.rawJSON.utf8).write(to: root.appendingPathComponent(name + "-wire.json"))
            }
            let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            return try XCTUnwrap(result["tools"] as? [[String: Any]])
        }

        func callSelfNoop() async throws -> PersistentMCPTestRPCResponse {
            try await XCTUnwrap(connection).callTool(name: MCPWindowToolName.selfNoop, arguments: [:], timeoutSeconds: 2)
        }

        func listLinks() async throws -> PersistentMCPTestRPCResponse {
            try await XCTUnwrap(connection).callTool(name: MCPWindowToolName.agentSessionLink, arguments: ["op": "list", "_rawJSON": true], timeoutSeconds: 2)
        }

        func interruptTurn(reason _: String) -> NativeAgentRuntimeInterruptOutcome {
            lifecycleRevision += 1
            return .noTurnInFlight
        }

        func shutdown() {
            lifecycleRevision += 1
            activeTurnID = nil
            connection = nil
            eventPair.continuation.finish()
        }

        func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) {}
    }
#endif
#if DEBUG
    @MainActor
    private extension AgentSessionLinkLiveDiscoveryTests {
        nonisolated static func w0fTool() -> MCP.Tool {
            MCP.Tool(
                name: "self_noop", description: "Quietly close a routine wake that needs nothing.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
            )
        }

        nonisolated static func w0fReturnedShape(copies: Int = 1, permissiveSchema: Bool = false) -> @Sendable ([MCP.Tool], Bool) -> [MCP.Tool] {
            { tools, outbound in
                guard outbound, tools.contains(where: { $0.name == MCPWindowToolName.agentSessionLink }) else { return tools }
                guard let candidate = tools.first(where: { $0.name == MCPWindowToolName.selfNoop }) else { return tools }
                let returned = permissiveSchema
                    ? MCP.Tool(name: candidate.name, description: candidate.description, inputSchema: .object(["type": .string("object")]))
                    : candidate
                return tools.filter { $0.name != MCPWindowToolName.selfNoop } + Array(repeating: returned, count: copies)
            }
        }

        func assertW2Acknowledgement(_ content: [[String: Any]]) throws {
            XCTAssertEqual(content.count, 1)
            XCTAssertEqual(content.first?["type"] as? String, "text")
            let text = try XCTUnwrap(content.first?["text"] as? String)
            XCTAssertTrue(text.hasPrefix("```json\n"))
            XCTAssertTrue(text.hasSuffix("\n```"))
            let body = String(text.dropFirst("```json\n".count).dropLast("\n```".count))
            let decoded = try JSONDecoder().decode(Value.self, from: Data(body.utf8))
            XCTAssertEqual(decoded, .object(["result": .string("done")]), "Exact body, decoded through unchanged generic MCP envelope")
        }

        /// Actual registered body + normal native ingress and production terminal hooks. The only
        /// eligibility input supplied by this fixture is the routine wake's origin qualification.
        func w2RegisteredTerminal(
            window: WindowState, session: AgentTabSession, connection: PersistentMCPTestEndpoint,
            runID: UUID, delayed: Bool, nativeResult: Bool, closing: Bool, leading: Bool, cancel: Bool
        ) async throws {
            let vm = window.agentModeViewModel
            let manager = ServerNetworkManager.shared
            let claude = session.selectedAgent == .claudeCode
            vm.test_initializeRunService()
            session.appendItem(.user("routine fixture origin", sequenceIndex: session.nextSequenceIndex))
            let owner = session.beginRunAttempt(source: "W2.registered-native-terminal")
            let handler = vm.test_claudeCoordinator.testToolTrackingHandler(for: session)
            let codex = vm.test_codexCoordinator
            let decoder = CodexNativeSessionController(client: CodexAppServerClient(), runID: runID, tabID: session.tabID, windowID: window.windowID, workspacePaths: .uniform(nil))
            let thread = "w2-exact-thread"
            let turn = "w2-exact-turn"
            let raw = claude ? "toolu_w2_queued_host" : "w2_original_native_call_string"
            let mailbox = TestReleaseFence(name: "before first registered noop host callback")
            var translator = ClaudeSDKNDJSONTranslator()
            var nativeTask: Task<Void, Never>?
            var terminalTask: Task<Void, Never>?
            var nativeIDs: [UUID] = []
            var nativeDelivered: XCTestExpectation?
            let terminalDelivered = AsyncStream<Void>.makeStream()
            if claude {
                await handler.startTracking(runID: runID, session: session, clientNameHint: nil)
            } else {
                session.codexController = decoder
                session.codexConversationID = thread
                session.codexPendingTurnKind = .user
                await decoder.test_installThreadState(threadID: thread, authoritativeTurnID: turn, routingTurnID: turn)
                await codex.test_handleCodexNativeEvent(.turnStarted(turnID: turn), session: session, sourceController: decoder)
                await codex.testStartCodexToolTracking(for: session, runID: runID)
                let events = decoder.events
                nativeTask = Task {
                    for await event in events {
                        await codex.test_handleCodexNativeEvent(event, session: session, sourceController: decoder)
                        switch event {
                        case let .toolCall(_, id, _, _), let .toolResult(_, id, _, _, _, _):
                            if let id { nativeIDs.append(id) }
                            nativeDelivered?.fulfill()
                        case .turnCompleted: terminalDelivered.continuation.yield(())
                        default: break
                        }
                    }
                }
            }
            session.quietLedger.markRoutineWake(owner: owner, wakeID: UUID())
            func flush() async {
                if claude { await handler.waitForPendingEventDeliveries() }
                else { await codex.testFlushCodexToolTracking(for: session) }
            }
            func native(result: Bool) async throws {
                if claude {
                    let block: [String: Any] = result
                        ? ["type": "tool_result", "tool_use_id": raw, "content": [["type": "text", "text": "{\"result\":\"done\"}"]]]
                        : ["type": "tool_use", "id": raw, "name": "mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__self_noop", "input": [:]]
                    let data = try JSONSerialization.data(withJSONObject: ["type": result ? "user" : "assistant", "message": ["content": [block]]])
                    for stream in translator.parseNDJSONLine(data) {
                        if stream.type == "tool_result" { XCTAssertNil(stream.toolIsError, "Host-owned error verdict is intentionally not inferred by the translator") }
                        if let id = stream.toolInvocationID { nativeIDs.append(id) }
                        await vm.test_handleStreamResult(stream, session: session, runID: runID, runAttemptID: owner.attemptID)
                    }
                } else {
                    let delivered = expectation(description: "registered noop native representation")
                    nativeDelivered = delivered
                    await decoder.test_handleNotification(method: result ? "item/completed" : "item/started", params: [
                        "threadId": .string(thread), "turnId": .string(turn), "item": .object([
                            "type": .string("mcpToolCall"), "id": .string(raw),
                            "server": .string(MCPIntegrationHelper.repoPromptMCPServerName), "tool": .string("self_noop"),
                            "arguments": .object([:]), "status": .string(result ? "completed" : "inProgress"),
                            "result": result ? .object(["content": .array([.object(["type": .string("text"), "text": .string("{\"result\":\"done\"}")])])]) : .null
                        ])
                    ])
                    await fulfillment(of: [delivered], timeout: 5)
                    nativeDelivered = nil
                }
            }
            func assistantText(_ text: String) async throws {
                if claude {
                    let data = try JSONSerialization.data(withJSONObject: ["type": "assistant", "message": ["content": [["type": "text", "text": text]]]])
                    for stream in translator.parseNDJSONLine(data) {
                        await vm.test_handleStreamResult(stream, session: session, runID: runID, runAttemptID: owner.attemptID)
                    }
                } else {
                    await codex.test_handleCodexNativeEvent(.assistantDelta(text), session: session, sourceController: decoder)
                }
            }
            func cleanup() async {
                mailbox.release()
                await terminalTask?.value
                await decoder.shutdown()
                await nativeTask?.value
                terminalDelivered.continuation.finish()
                if claude { await handler.stopTracking(for: session) }
                else { await codex.testStopCodexToolTracking(for: session) }
            }
            do {
                if leading { try await assistantText("leading output before declaration") }
                try await native(result: false)
                if delayed {
                    if claude { handler.enqueueEventDeliveryBarrierForTesting { await mailbox.enterAndWait() } }
                    else { codex.testEnqueueCodexToolTrackingBarrier(for: session) { await mailbox.enterAndWait() } }
                    guard await mailbox.waitUntilEntered() else { throw CancellationError() }
                }
                let metadata: [String: Any] = claude ? ["claudecode/toolUseId": raw] : ["callId": raw, "threadId": thread, "itemId": "not-a-host-UUID"]
                let response = try await connection.client.request(method: "tools/call", params: ["name": "self_noop", "arguments": [:], "_meta": metadata])
                let result = try XCTUnwrap(try MCPExportWatchdogIntegrationTests.responseObject(from: response)["result"] as? [String: Any])
                XCTAssertNotEqual(result["isError"] as? Bool, true, response.rawJSON)
                let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                try assertW2Acknowledgement(content)
                let hostID = session.quietLedger.acceptedDeclarationInvocationID(owner: owner)
                XCTAssertEqual(hostID == nil, leading, "Leading text irreversibly prevents acceptance")
                XCTAssertEqual(session.quietLedger.declarationBodyEntryCardinality(owner: owner), 1)
                if let hostID { XCTAssertTrue(nativeIDs.allSatisfy { $0 != hostID }) }
                XCTAssertFalse(window.mcpServer.hasActiveToolExecutions(runID: runID))
                XCTAssertFalse(manager.hasPendingToolCardObservations(windowID: window.windowID, runID: runID))
                if nativeResult { try await native(result: true) }
                XCTAssertEqual(nativeIDs.count, nativeResult ? 2 : 1)
                if !delayed { await flush() }
                if closing { try await assistantText("allowed closing output after accepted body") }
                XCTAssertEqual(session.quietLedger.hasOrdinaryOccurrence(owner: owner), leading, "Temporal ingress distinguishes leading text from allowed closing output")
                let complete = hostID.map { id in claude ? handler.hasCompleteExactAssociation(hostInvocationID: id, owner: owner, session: session) : session.quietLedger.codexAssociationIsComplete(owner: owner, hostID: id, runID: runID, threadID: thread) } ?? false
                let rowDiagnostics = session.items.map { "\($0.sequenceIndex):\($0.kind):\($0.toolInvocationID == hostID):\($0.isStreaming)" }
                print("W2_PRE_TERMINAL provider=\(session.selectedAgent.rawValue) delayed=\(delayed) occurrence=\(session.quietLedger.hasOrdinaryOccurrence(owner: owner)) complete=\(complete) start=\(String(describing: session.quietLedger.startKey(owner: owner))) rows=\(rowDiagnostics)")
                terminalTask = Task {
                    if claude {
                        let id = UUID()
                        session.claudeExpectedTurnIDs.insert(id)
                        let stream = AsyncStream<NativeAgentRuntimeEvent> { c in
                            c.yield(.turnCompleted(turnID: id, status: .completed))
                            c.finish()
                        }
                        _ = await vm.test_consumeClaudeTerminalEvents(stream, session: session, runID: runID, owner: owner)
                    } else {
                        await decoder.test_handleNotification(method: "turn/completed", params: ["threadId": .string(thread), "turn": .object(["id": .string(turn), "status": .string("completed")])])
                        for await _ in terminalDelivered.stream {
                            break
                        }
                    }
                }
                if delayed {
                    try await AsyncTestWait.waitUntil("terminal reaches the queued observation cut or conservative leading-text settlement") {
                        (claude ? handler.pendingEventDeliveryWaiterCountForTesting : codex.testCodexToolTrackingWaiterCount(for: session)) > 0 || session.lastTerminalCommitRevision != nil
                    }
                    if !leading { XCTAssertNil(session.lastTerminalCommitRevision, "Must drain queued host evidence before deciding eligibility") }
                    if cancel {
                        print("W2_CANCEL_CUT provider=\(session.selectedAgent.rawValue) phase=\(session.terminalCommitInProgress) revision=\(session.lastTerminalCommitRevision != nil) drain=\(session.providerTerminalDrainGeneration)")
                        await vm.cancelAgentRun(tabID: session.tabID, completion: .terminalPublished)
                    }
                    mailbox.release()
                }
                await terminalTask?.value
                XCTAssertEqual(session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: nativeResult && !leading && !cancel ? 0 : 1), "\(session.selectedAgent) delayed=\(delayed) nativeResult=\(nativeResult) closing=\(closing) leading=\(leading) cancel=\(cancel)")
                XCTAssertNotNil(session.lastTerminalCommitRevision)
                if cancel {
                    XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .cancelled)
                    XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, owner)
                    XCTAssertNil(session.activeRunOwnership)
                    XCTAssertFalse(session.terminalCommitInProgress)
                    let revision = session.lastTerminalCommitRevision
                    await vm.cancelAgentRun(tabID: session.tabID, completion: .terminalPublished)
                    XCTAssertEqual(session.lastTerminalCommitRevision, revision, "Duplicate Stop must not create a second terminal revision")
                    XCTAssertEqual(session.quietLedger.facts, .init(settledThrough: 1, ordinaryThrough: 1))
                }
                if closing { XCTAssertTrue(session.items.contains { $0.text.contains("allowed closing output after accepted body") }, "Buffered output survives terminal/cancellation settlement") }
                XCTAssertTrue(session.items.allSatisfy { $0.quietCheckInWakeID == nil }, "W3 remains excluded")
                print("W2_REGISTERED_TERMINAL provider=\(session.selectedAgent.rawValue) delayed=\(delayed) nativeResult=\(nativeResult) settled=\(session.quietLedger.facts?.settledThrough ?? 0) ordinary=\(session.quietLedger.facts?.ordinaryThrough ?? 0)")
                await cleanup()
            } catch { await cleanup()
                throw error
            }
        }

        func w2RoutineClaim(
            window: WindowState, session: AgentTabSession, endpoint: DomainAgentSessionLinkEndpointIdentity,
            localRead: Bool
        ) throws -> (AgentRunOwnership, AgentSessionLinkPromptDispatchID, AgentSessionLinkOutboundPromptClaim) {
            let vm = window.agentModeViewModel
            session.runState = .idle
            let inventory = try XCTUnwrap(vm.agentSessionLinkPromptInventoryBySessionID[endpoint.sessionID])
            let wake = UUID()
            let snapshot = AgentSessionLinkPassiveStatusNotices.Snapshot(observerEndpoint: endpoint, queueEpoch: UUID(), queueRevision: 1, linkSetRevision: inventory.inventory.linkSetRevision, isEnabled: true, isDeliverable: true, entries: [], unacknowledgedOverflowCount: 1, overflowProduced: 1)
            vm.agentSessionLinkPublishPassiveStatusNotices(snapshot, to: endpoint)
            session.oversight.pendingAutoWake = .init(wakeID: wake, observerEndpoint: endpoint, queueEpoch: snapshot.queueEpoch, queueRevision: 1, wakeFingerprint: nil, admissionBasis: .routineStatusOrOverflow, attemptedFingerprint: nil, physicalOutcome: .notAttempted, phase: .preparingDispatch, task: nil)
            if localRead {
                vm.test_agentSessionLinkLocalInputDecoration = { baseline in
                    .init(fragment: baseline.fragment + "\n<user_input>proof gate fixture</user_input>", markupDeltaBytes: 49, requirements: [])
                }
            }
            let dispatch = AgentSessionLinkPromptDispatchID.autoWake(wakeID: wake)
            let claim = try XCTUnwrap(vm.agentSessionLinkPromptClaimOutcome(for: session, dispatchID: dispatch).claim)
            XCTAssertTrue(claim.routineQuietCheckIn)
            XCTAssertTrue(claim.fragment.contains("Nothing needed? Call self_noop."))
            let owner = session.beginRunAttempt(source: "W2.production-proof-fixture")
            session.quietLedger.markRoutineWake(owner: owner, wakeID: wake)
            session.oversight.pendingAutoWake?.phase = .dispatching
            session.runState = .running
            return (owner, dispatch, claim)
        }

        func w2CatalogProof(
            window: WindowState, session: AgentTabSession, provider: HeldDiscoveryProvider,
            endpoint: DomainAgentSessionLinkEndpointIdentity, route: AgentSessionLinkRunCatalogRouteToken,
            runID: UUID, withdraw: Bool
        ) async throws {
            let vm = window.agentModeViewModel
            let manager = ServerNetworkManager.shared
            let gate = TestReleaseFence(name: "production local-read proof before final catalog fence")
            let nativeBefore = await provider.heldTurnSnapshot
            let generation = session.codexControllerGeneration
            let repair = session.codexSessionLinkCatalogRepairCycle
            let (_, dispatch, original) = try w2RoutineClaim(window: window, session: session, endpoint: endpoint, localRead: true)
            let frozenProjection = try XCTUnwrap(vm.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint])
            vm.test_agentSessionLinkLocalInputReadProof = { _ in await gate.enterAndWait()
                return false
            }
            let proofTask = Task { await vm.agentSessionLinkProveProviderInput(for: session, claim: original) }
            var catalogTask: Task<Set<String>, Error>?
            func cleanup() async {
                gate.release()
                _ = await proofTask.value
                await manager.debugResumeRunCatalogPublicationBeforeMainActor()
                _ = await catalogTask?.result
                await manager.debugSetReturnedCatalogToolsForTesting(nil)
                vm.test_agentSessionLinkLocalInputDecoration = nil
                vm.test_agentSessionLinkLocalInputReadProof = nil
                session.oversight.pendingAutoWake = nil
            }
            do {
                guard await gate.waitUntilEntered() else { throw CancellationError() }
                if withdraw {
                    await manager.debugSetReturnedCatalogToolsForTesting(Self.w0fReturnedShape(copies: 0))
                    await manager.debugSuspendNextRunCatalogPublicationBeforeMainActor()
                    catalogTask = Task { try await provider.listTools() }
                    try await AsyncTestWait.waitUntil("server catalog withdrawn before MainActor publication") { await manager.debugIsRunCatalogPublicationBeforeMainActorSuspended() }
                    let latest = try await w0fProjection(manager, runID)
                    XCTAssertEqual(latest.routeToken, route)
                    XCTAssertFalse(latest.containsReturnedTool(Self.w0fTool()))
                    XCTAssertEqual(vm.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint], frozenProjection, "Mirror intentionally lags the authoritative observation")
                }
                gate.release()
                let proof = await proofTask.value
                let released = vm.agentSessionLinkHandoffProviderInput(for: session, dispatchID: dispatch, claim: original, proof: proof)
                XCTAssertFalse(released.mustAbortDispatch, "Missing optional noop support never blocks ordinary delivery")
                let capturing = AgentSessionLinkCapturingHeadlessProvider()
                _ = try await capturing.streamAgentMessage(released.message(AgentMessage(systemPrompt: "fixture", userMessage: "routine")), runID: runID)
                let messages = await capturing.messages
                XCTAssertEqual(messages.count, 1)
                XCTAssertEqual(messages[0].userMessage.contains("Nothing needed? Call self_noop."), !withdraw)
                XCTAssertEqual(released.claim?.routineQuietCheckIn, !withdraw)
                if withdraw {
                    let stillHeld = await manager.debugIsRunCatalogPublicationBeforeMainActorSuspended()
                    XCTAssertTrue(stillHeld, "The send did not wait for mirror publication/repair")
                }
                let nativeAfter = await provider.heldTurnSnapshot
                XCTAssertEqual(nativeBefore, nativeAfter)
                XCTAssertEqual(session.codexControllerGeneration, generation)
                XCTAssertEqual(session.codexSessionLinkCatalogRepairCycle, repair)
                print("W2_PRODUCTION_HINT withdraw=\(withdraw) messages=\(messages.count) routine=\(released.claim?.routineQuietCheckIn == true)")
                await cleanup()
            } catch { await cleanup()
                throw error
            }
        }

        /// Debug dispatch-preparation budget, not an importer or end-to-end provider benchmark.
        /// Separately vary catalog bytes and unrelated history; fixture construction is untimed.
        func w2CatalogCost(
            window: WindowState, session: AgentTabSession, provider: HeldDiscoveryProvider,
            endpoint: DomainAgentSessionLinkEndpointIdentity, runID: UUID, inactiveTabID: UUID
        ) async throws {
            let manager = ServerNetworkManager.shared
            let vm = window.agentModeViewModel
            // Isolate dispatch preparation from unrelated active-transcript UI rebuilds. This is a
            // valid second tab in the same fixture window, not a rendering/importer benchmark.
            vm.test_setCurrentTabIDOverride(inactiveTabID)
            defer { vm.test_setCurrentTabIDOverride(nil) }
            let baseline = try await w0fProjection(manager, runID)
            let actualTools = try Array(XCTUnwrap(baseline.returnedCatalog).values.joined())
            let clock = ContinuousClock()
            func ms(_ duration: Duration) -> Double {
                Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            }
            func stats(_ values: [Double]) -> [String: Double] {
                let ordered = values.sorted()
                return ["median": (ordered[19] + ordered[20]) / 2, "p95": ordered[37], "max": ordered[39]]
            }
            let repairBefore = session.codexSessionLinkCatalogRepairCycle
            let generationBefore = session.codexControllerGeneration
            // Three comparisons, not a Cartesian matrix: catalog growth and history growth isolated.
            for (factor, historyCount) in [(1, 0), (10, 0), (1, 10000)] {
                if let owner = session.activeRunOwnership { _ = session.endRunAttempt(ifCurrent: owner, source: "W2.cost-fixture-reset") }
                session.oversight.pendingAutoWake = nil
                await manager.debugSetReturnedCatalogToolsForTesting { _, _ in
                    var expanded = actualTools
                    if factor > 1 {
                        for copyIndex in 1 ..< factor {
                            expanded += actualTools.map { tool in
                                MCP.Tool(name: "w2_cost_\(copyIndex)__\(tool.name)", description: tool.description, inputSchema: tool.inputSchema, annotations: tool.annotations)
                            }
                        }
                    }
                    return expanded
                }
                _ = try await provider.listTools()
                let projection = try await w0fProjection(manager, runID)
                let returned = try XCTUnwrap(projection.returnedCatalog)
                // Footprint encoding is evidence-only, outside all production-path timing.
                let catalog = try JSONEncoder().encode(Array(returned.values.joined()))
                let toolCount = returned.values.reduce(0) { $0 + $1.count }
                XCTAssertEqual(toolCount, actualTools.count * factor)
                session.setItemsSilently((0 ..< historyCount).map { .assistant("unrelated fixture history", sequenceIndex: $0) }, reason: .persistedSessionHydration)
                let (owner, dispatch, original) = try w2RoutineClaim(window: window, session: session, endpoint: endpoint, localRead: false)
                var claimMS: [Double] = [], proofMS: [Double] = [], handoffMS: [Double] = [], totalMS: [Double] = [], syncMS: [Double] = []
                let sourceRevision = session.sourceItemsRevision
                var rebuilds = 0, projectionBuilds = 0
                defer { AgentTranscriptDebugInstrumentation.reset() }
                for sample in 0 ..< 45 {
                    if sample == 5 {
                        AgentTranscriptDebugInstrumentation.configure(.init(rebuildHandler: { _ in rebuilds += 1 }, projectionBuildHandler: { _ in projectionBuilds += 1 }))
                    }
                    let start = clock.now
                    let outcome = vm.agentSessionLinkPromptClaimOutcome(for: session, dispatchID: dispatch)
                    let claimedAt = clock.now
                    let proof = await vm.agentSessionLinkProveProviderInput(for: session, claim: outcome.claim)
                    let provedAt = clock.now
                    let released = vm.agentSessionLinkHandoffProviderInput(for: session, dispatchID: dispatch, claim: outcome.claim, proof: proof)
                    let finished = clock.now
                    XCTAssertFalse(released.mustAbortDispatch)
                    XCTAssertEqual(released.claim, original)
                    XCTAssertTrue(released.fragment?.contains("Nothing needed? Call self_noop.") == true)
                    if sample >= 5 {
                        claimMS.append(ms(start.duration(to: claimedAt)))
                        proofMS.append(ms(claimedAt.duration(to: provedAt)))
                        handoffMS.append(ms(provedAt.duration(to: finished)))
                        totalMS.append(ms(start.duration(to: finished)))
                        syncMS.append(ms(start.duration(to: claimedAt)) + ms(provedAt.duration(to: finished)))
                    }
                }
                AgentTranscriptDebugInstrumentation.reset()
                XCTAssertEqual(rebuilds, 0, "Catalog proof/handoff must not rebuild transcript history")
                XCTAssertEqual(projectionBuilds, 0)
                XCTAssertEqual(session.sourceItemsRevision, sourceRevision)
                let total = stats(totalMS), synchronous = stats(syncMS)
                // Predeclared local Debug budgets: actual catalog total p95 < ~11% of W0's supplied
                // 466ms wake context; 10x stress bounded separately. Not new production limits.
                XCTAssertLessThanOrEqual(total["p95"]!, factor == 1 ? 50 : 250)
                XCTAssertLessThanOrEqual(synchronous["p95"]!, factor == 1 ? 25 : 125)
                XCTAssertLessThanOrEqual(total["max"]!, 1000)
                let record: [String: Any] = [
                    "catalog_factor": factor, "catalog_tools": toolCount, "catalog_bytes": catalog.count,
                    "unrelated_history_rows": historyCount, "observer_tab_active": false, "samples": 40, "warmups": 5,
                    "claim_ms": stats(claimMS), "proof_ms": stats(proofMS), "handoff_ms": stats(handoffMS),
                    "total_ms": total, "sync_claim_plus_handoff_ms": synchronous,
                    "full_decodes_per_positive_path_source_derived": 0,
                    "decoded_bytes_40_samples_source_derived": 0,
                    "exact_name_lookups_per_positive_path_source_derived": 4,
                    "observed_transcript_rebuilds": rebuilds, "observed_projection_builds": projectionBuilds,
                    "redundant_observation_encodes_per_tools_list_source_derived": 0,
                    "budget_total_p95_ms": factor == 1 ? 50 : 250,
                    "budget_sync_p95_ms": factor == 1 ? 25 : 125,
                    "budget_total_max_ms": 1000
                ]
                try print("W2_CATALOG_COST " + (JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])).base64EncodedString())
                vm.abandonAgentSessionLinkPromptClaim(original)
                _ = session.endRunAttempt(ifCurrent: owner, source: "W2.cost-fixture-end")
            }
            XCTAssertEqual(session.codexSessionLinkCatalogRepairCycle, repairBefore)
            XCTAssertEqual(session.codexControllerGeneration, generationBefore)
            await manager.debugSetReturnedCatalogToolsForTesting(nil)
            session.oversight.pendingAutoWake = nil
        }

        func w0fProjection(_ manager: ServerNetworkManager, _ runID: UUID) async throws -> AgentSessionLinkRunCatalogProjection {
            let projection = await manager.debugRunCatalogProjection(for: runID)
            return try XCTUnwrap(projection)
        }

        func w0fRepairControls(
            manager: ServerNetworkManager, provider: HeldDiscoveryProvider, window: WindowState,
            observer: AgentTabSession, endpoint: DomainAgentSessionLinkEndpointIdentity,
            route: AgentSessionLinkRunCatalogRouteToken, runID: UUID, kind: AgentProviderKind,
            codex: LifecycleNoopCodexController, codexRecorder: LifecycleRecorder
        ) async throws {
            let owner = observer.beginRunAttempt(source: "W0f.catalog-proof")
            let wireDefinitions = try await provider.definitions()
            let wireTools = try JSONDecoder().decode([MCP.Tool].self, from: JSONSerialization.data(withJSONObject: wireDefinitions))
            let positive = try await w0fProjection(manager, runID)
            XCTAssertEqual(positive.returnedCatalog, Dictionary(grouping: wireTools, by: \.name), "The single typed observation slot preserves every actual returned definition and duplicate")
            let nativeBefore = await provider.heldTurnSnapshot
            let codexBefore = codexRecorder.events
            let generation = observer.codexControllerGeneration
            XCTAssertEqual(positive.expectedSurface, positive.returnedSurface)
            XCTAssertTrue(positive.containsReturnedTool(Self.w0fTool()))
            let actualTools = try Array(XCTUnwrap(positive.returnedCatalog).values.joined())
            let actualDefinition = try XCTUnwrap(actualTools.first { $0.name == MCPWindowToolName.selfNoop })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let wireDefinition = try XCTUnwrap(wireTools.first { $0.name == MCPWindowToolName.selfNoop })
            XCTAssertEqual(actualDefinition, wireDefinition)
            let producedDefinition = try encoder.encode(wireDefinition)
            // The existing W0 fixture is the exact pinned fork trial definition. Use the same
            // real MCP.Tool encoder, without assuming empty-annotation wire behavior.
            let trialDefinition = try encoder.encode(Self.w0fTool())
            XCTAssertEqual(producedDefinition, trialDefinition)
            print("W2_TRIAL_DEFINITION " + trialDefinition.base64EncodedString())
            print("W2_ACTUAL_DEFINITION " + producedDefinition.base64EncodedString())

            /// W0-only consumer. No product hint, dispatch admission or terminal decision is wired.
            func hint(_ sample: AgentSessionLinkRunCatalogProjection, owner capturedOwner: AgentRunOwnership) async -> String? {
                guard let token = await manager.authoritativeRunCatalogRouteToken(runID: runID, windowID: window.windowID, tabID: endpoint.tabID) else { return nil }
                let supported = await manager.hasCurrentReturnedTool(Self.w0fTool(), routeToken: token, projectionRevision: sample.projectionRevision)
                guard supported, !Task.isCancelled, sample.routeToken == token,
                      ToolAvailabilityStore.shared.isEnabled(Self.w0fTool().name),
                      sample.hasActiveOutboundLink == true, observer.runID == runID,
                      observer.isCurrentRunAttemptForCurrentBinding(capturedOwner),
                      window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
                      window.agentModeViewModel.agentSessionLinkRunCatalogProjectionByEndpoint[endpoint]?.projectionRevision == sample.projectionRevision,
                      manager.hasLiveProviderInputConnection(token)
                else { return nil }
                return "Nothing needed? Call self_noop."
            }
            func assertNoQuietRepair() {
                guard kind == .codexExec else { return }
                window.agentModeViewModel.test_codexCoordinator.codexRepairSessionLinkCatalogIfQuiescent(for: observer)
                XCTAssertNil(observer.codexSessionLinkCatalogRepairCycle)
                XCTAssertEqual(observer.codexControllerGeneration, generation)
                XCTAssertTrue(observer.codexController === codex)
                XCTAssertEqual(observer.runID, runID)
            }
            let supportedHint = await hint(positive, owner: owner)
            XCTAssertEqual(supportedHint, "Nothing needed? Call self_noop.")
            let acknowledgement = try await provider.callSelfNoop()
            let callObject = try MCPExportWatchdogIntegrationTests.responseObject(from: acknowledgement)
            let callResult = try XCTUnwrap(callObject["result"] as? [String: Any])
            XCTAssertNotEqual(callResult["isError"] as? Bool, true)
            let content = try XCTUnwrap(callResult["content"] as? [[String: Any]])
            try assertW2Acknowledgement(content)
            XCTAssertEqual(observer.quietLedger.declarationBodyEntryCardinality(owner: owner), 1, "The real registration packet reaches the current caller body")
            XCTAssertNil(observer.quietLedger.acceptedDeclarationInvocationID(owner: owner), "A non-routine advertised caller is acknowledged, not quiet")
            // The returned catalog is not permission to borrow another attempt or route.
            let successor = observer.beginRunAttempt(source: "W0f.catalog-proof.successor")
            let oldAttemptHint = await hint(positive, owner: owner)
            XCTAssertNil(oldAttemptHint)
            let foreign = AgentSessionLinkRunCatalogRouteToken(runID: runID, observerEndpoint: endpoint, connectionID: UUID(), routingAuthorityGeneration: route.routingAuthorityGeneration, connectionLifecycleGeneration: route.connectionLifecycleGeneration)
            let foreignSupport = await manager.hasCurrentReturnedTool(Self.w0fTool(), routeToken: foreign, projectionRevision: positive.projectionRevision)
            XCTAssertFalse(foreignSupport)

            // Equivalent absent/suppressed and ambiguous returned catalogs. The healthy idle Codex
            // controller must not even open a cycle; ordinary delivery remains available.
            if kind == .codexExec { observer.runState = .idle }
            for (label, copies, permissive) in [("absent/suppressed", 0, false), ("ambiguous", 2, false), ("non-exact schema", 1, true)] {
                await manager.debugSetReturnedCatalogToolsForTesting(Self.w0fReturnedShape(copies: copies, permissiveSchema: permissive))
                _ = try await provider.listTools()
                let current = try await w0fProjection(manager, runID)
                XCTAssertEqual(current.expectedSurface, positive.expectedSurface, label)
                XCTAssertEqual(current.returnedSurface, positive.returnedSurface, label)
                XCTAssertTrue(current.isReady, "Quiet support cannot gate ordinary delivery: \(label)")
                let delivery = await window.agentModeViewModel.qualifyProviderInputRoute(for: observer)
                XCTAssertEqual(delivery, .ready(route), "Ordinary route qualification never waits on quiet support")
                let absentHint = await hint(current, owner: successor)
                let staleHint = await hint(positive, owner: successor)
                XCTAssertNil(absentHint, label)
                XCTAssertNil(staleHint, "A prior positive catalog revision is not current")
                assertNoQuietRepair()
            }

            // Real global disable is confined to the test runner's disposable sandbox. It must
            // veto retained positive evidence even before tools/list has refreshed.
            observer.runState = .running
            await manager.debugSetReturnedCatalogToolsForTesting(Self.w0fReturnedShape())
            _ = try await provider.listTools()
            let beforeDisable = try await w0fProjection(manager, runID)
            await manager.setEnabled(false)
            let disabledHint = await hint(beforeDisable, owner: successor)
            XCTAssertNil(disabledHint)
            _ = try await provider.listTools()
            let disabled = try await w0fProjection(manager, runID)
            XCTAssertFalse(disabled.containsReturnedTool(Self.w0fTool()))
            await manager.setEnabled(true)
            _ = try await provider.listTools()
            let restored = try await w0fProjection(manager, runID)
            let restoredHint = await hint(restored, owner: successor)
            XCTAssertEqual(restoredHint, "Nothing needed? Call self_noop.")
            let nativeAfter = await provider.heldTurnSnapshot
            XCTAssertEqual(nativeAfter, nativeBefore)
            XCTAssertEqual(codexRecorder.events, codexBefore)
            if kind == .codexExec {
                observer.runState = .idle
                assertNoQuietRepair()
                // One deterministic overlap proves the new payload cannot revive an older
                // positive response after a newer same-run catalog publication.
                let gate = DiscoveryCatalogGate()
                let paused = expectation(description: "older catalog completion suspended")
                await manager.debugSetAfterExpectedCatalogSurfaceForTesting { await gate.hold { paused.fulfill() } }
                let older = Task { try await provider.listTools() }
                await fulfillment(of: [paused], timeout: 2)
                await manager.debugSetAfterExpectedCatalogSurfaceForTesting(nil)
                do {
                    await manager.debugSetReturnedCatalogToolsForTesting(Self.w0fReturnedShape(copies: 0))
                    _ = try await provider.listTools()
                    await gate.release()
                    _ = try await older.value
                } catch {
                    await gate.release()
                    _ = await older.result
                    throw error
                }
                let latest = try await w0fProjection(manager, runID)
                XCTAssertNil(latest.returnedCatalog, "Overlapping older completion is unknown, never positive support")
                let overlappedHint = await hint(latest, owner: successor)
                XCTAssertNil(overlappedHint)
                assertNoQuietRepair()
            }
        }
    }
#endif
