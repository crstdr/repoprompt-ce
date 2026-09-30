import Combine
import Darwin
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

#if DEBUG
    @MainActor
    final class MCPSetModelTransportTests: XCTestCase {
        func testCapturedRequestUsesOnlyInstalledRoutingAndRejectsColdContextWithoutRepair() async throws {
            try await withFixture { fixture in
                try await self.exerciseInstalledRouting(fixture, checkPermissions: false)
            }
        }

        func testCapturedModelRequestRetainsManageAndEnabledToolChecks() async throws {
            try await withFixture { fixture in
                try await self.exerciseInstalledRouting(fixture, checkPermissions: true)
            }
        }

        func testDashboardProjectionTracksSourceReplacementRemovalAndWindowMode() async throws {
            try await withFixture { fixture in
                let server = fixture.contextA.window.mcpServer
                _ = await server.setWindowToolsEnabled(true)
                let windowID = fixture.contextA.window.windowID
                func connection(window: Int?, tool: String?, sequence: UInt64 = 1) -> MCPService.DashboardConnection {
                    let scopes = tool.map { [ConnectionDashboardActiveToolScope(windowID: windowID, toolName: $0, sequence: sequence)] } ?? []
                    return .init(
                        id: UUID(),
                        clientName: "projection",
                        windowID: window,
                        transport: .network,
                        state: .ready,
                        createdAt: Date(),
                        lastToolCallAt: nil,
                        totalToolCalls: 0,
                        idleSeconds: nil,
                        hasInFlightCalls: !scopes.isEmpty,
                        activeToolScope: scopes.first,
                        activeToolScopes: scopes,
                        sessionKey: nil
                    )
                }
                let originalWindows = WindowStatesManager.shared.allWindows
                defer { WindowStatesManager.shared.allWindows = originalWindows }
                WindowStatesManager.shared.allWindows = [fixture.contextA.window]
                server.debugSetDashboardForTesting(.init(isRunning: true, diagnostics: .init(), connections: [
                    connection(window: windowID, tool: "older"), connection(window: nil, tool: "newer", sequence: 2)
                ], recentToolCalls: [], alwaysAllowedClients: [], autoApproveAllClients: false))
                XCTAssertEqual(server.windowActiveToolName, "newer")
                XCTAssertEqual(server.closeSafetyState.liveConnectionCount, 2)
                XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 2)
                WindowStatesManager.shared.allWindows = originalWindows
                server.debugSetDashboardForTesting(server.dashboard)
                XCTAssertEqual(server.closeSafetyState.liveConnectionCount, 1)
                server.debugSetDashboardForTesting(.init(isRunning: true, diagnostics: .init(), connections: [
                    connection(window: windowID, tool: "replacement")
                ], recentToolCalls: [], alwaysAllowedClients: [], autoApproveAllClients: false))
                XCTAssertEqual(server.windowActiveToolName, "replacement")
                XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 1)
                server.debugSetDashboardForTesting(nil)
                XCTAssertNil(server.windowActiveToolName)
                XCTAssertEqual(server.closeSafetyState.liveConnectionCount, 0)
                XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 0)
            }
        }

        func testCloseSafetyTracksRegistrationCompletionRunRevocationAndConnectionRemoval() async throws {
            try await withFixture { fixture in
                let server = fixture.contextA.window.mcpServer
                _ = await server.setWindowToolsEnabled(true)
                server.debugSetDashboardForTesting(nil)
                let connectionID = UUID()
                let runID = UUID()
                server.connectionIDToRunID[connectionID] = runID
                defer { server.connectionIDToRunID.removeValue(forKey: connectionID) }
                let metadata = MCPServerViewModel.RequestMetadata(connectionID: connectionID, clientName: "close-safety", windowID: fixture.contextA.window.windowID)
                let first = await server.test_beginResolvedToolExecution(metadata: metadata, resolvedContext: nil, toolName: "agent_session_link")
                let firstID = try XCTUnwrap(first?.executionID)
                XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 1)
                let second = await server.test_beginResolvedToolExecution(metadata: metadata, resolvedContext: nil, toolName: "read_file")
                _ = try XCTUnwrap(second?.executionID)
                XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 2, "Generic and model operations keep identical lifecycle accounting")
                server.test_endToolExecution(executionID: firstID)
                XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 1)
                XCTAssertEqual(server.cancelActiveToolsForRun(runID: runID, reason: "route revoked"), 1)
                XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 0)
                let third = await server.test_beginResolvedToolExecution(metadata: metadata, resolvedContext: nil)
                _ = try XCTUnwrap(third?.executionID)
                XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 1)
                XCTAssertEqual(server.cancelActiveToolsForConnection(connectionID: connectionID, reason: "connection removed"), 1)
                XCTAssertEqual(server.closeSafetyState.activeExecutionCount, 0)
                XCTAssertEqual(server.test_activeToolExecutionCount(connectionID: connectionID), 0)
            }
        }

        private func withFixture(_ operation: (PersistentMCPTestFixture) async throws -> Void) async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease, domainRuntime: AppDomainRuntimeComposition.shared.runtime)
                do {
                    try await operation(fixture)
                    await AppDomainRuntimeComposition.shared.runtime.domainHost.debugSetBeforeProviderActivationForTesting(nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await AppDomainRuntimeComposition.shared.runtime.domainHost.debugSetBeforeProviderActivationForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private func exerciseInstalledRouting(_ fixture: PersistentMCPTestFixture, checkPermissions: Bool) async throws {
            let transport = try fixture.endpointA()
            let manager = fixture.networkManager
            let context = fixture.contextA
            let window = context.window
            let workspace = try XCTUnwrap(window.workspaceManager.workspaces.first { $0.id == context.workspaceID })
            _ = await window.workspaceManager.switchWorkspace(to: workspace, saveState: false)
            let vm = window.agentModeViewModel
            let observer = vm.session(for: context.tabID)
            observer.selectedAgent = .claudeCode
            observer.hasLoadedPersistedState = true
            observer.oversight.autoWakeOnUpdates = false
            let runID = UUID()
            observer.installRunID(runID)
            _ = try XCTUnwrap(vm.test_ensureSessionBoundToTab(observer))
            let observerEndpoint = try AgentSessionLinkEndpointTestSupport.endpoint(vm, tabID: context.tabID)
            let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == context.workspaceID })
            let targetTabID = UUID()
            window.workspaceManager.workspaces[workspaceIndex].composeTabs.append(ComposeTabState(id: targetTabID, name: "Transport model target"))
            let target = vm.session(for: targetTabID)
            target.selectedAgent = .claudeCode
            target.hasLoadedPersistedState = true
            let targetSessionID = try XCTUnwrap(vm.test_ensureSessionBoundToTab(target))
            let targetEndpoint = try AgentSessionLinkEndpointTestSupport.endpoint(vm, tabID: targetTabID)
            let host = WindowStatesManager.shared
            host.attachAgentSessionLinkBridge()
            let authority = AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority
            guard case let .reserved(reservation, _) = await authority.reserveLink(observer: observerEndpoint, target: targetEndpoint),
                  let candidate = host.agentSessionLinkModelCandidate(for: targetEndpoint),
                  case let .activated(activation) = await authority.activateLink(
                      reservation: reservation, initialSnapshot: host.agentSessionLinkObservationSnapshot(for: candidate), sourcePublicationSequence: 1
                  ) else { return XCTFail("Expected managed link") }
            let available = expectation(description: "Cached Claude availability")
            let subscription = window.apiSettingsViewModel.$agentAvailability.first { $0.claudeCodeAvailable }.sink { _ in available.fulfill() }
            window.apiSettingsViewModel.isClaudeCodeConnected = true
            await fulfillment(of: [available], timeout: 2)
            subscription.cancel()
            defer {
                observer.saveDebounceTask?.cancel()
                target.saveDebounceTask?.cancel()
                AgentAdvertisedModelCatalog.shared.invalidate(.claudeCode)
            }
            await manager.installClientConnectionPolicy(
                for: transport.clientName, windowID: window.windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true,
                reason: "Set model transport regression", ttl: 60, tabID: context.tabID,
                runID: runID, additionalTools: nil, purpose: .agentModeRun,
                taskLabelKind: nil, allowsAgentExternalControlTools: false
            )
            let applied = await manager.debugApplyPendingPolicy(
                clientName: transport.clientName, connectionID: transport.connectionID,
                clientPid: nil, bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: "model-transport-\(runID)", pidGateTimeout: 0.25, requireRunRouting: true
            )
            XCTAssertEqual(applied.outcome, "applied")
            _ = try await manager.debugListToolNames(for: transport.connectionID)
            let installed = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[transport.connectionID])
            // Use the ordinary in-memory producer before the request; concurrent UI publications
            // may legitimately replace a synthetic test-only catalogue entry.
            let options = AgentModelCatalog.options(for: .claudeCode, availability: host.agentSessionLinkModelAvailability(windowID: window.windowID))
            let rawModel = try XCTUnwrap(options.first { !$0.isPlaceholderDefault && !$0.rawValue.isEmpty }).rawValue
            target.selectedModelRaw = "previous-transport-model"
            let args: [String: Any] = [
                "op": "set_model", "session_id": targetSessionID.uuidString,
                "model_id": AgentModelSelectionID(agentRaw: "claudeCode", modelRaw: rawModel).rawValue, "_rawJSON": true
            ]
            let before = target.saveRequestGeneration
            let securityProbe = ModelTransportSecurityProbe()
            await manager.debugSetObservedPeerPIDForTesting(Int(getpid()), connectionID: transport.connectionID)
            await AppDomainRuntimeComposition.shared.runtime.domainHost.debugSetBeforeProviderActivationForTesting { _, tool, _ in
                if tool == MCPWindowToolName.agentSessionLink {
                    await securityProbe.record(MCPDomainInvocationSecurityContext.current)
                }
            }
            // Actual SDK request -> production metadata capture -> registered service -> target VM.
            let warm = try await transport.callTool(name: MCPWindowToolName.agentSessionLink, arguments: args)
            XCTAssertTrue(warm.rawJSON.contains("accepted"), warm.rawJSON)
            let capturedSecurity = await securityProbe.context
            let security = try XCTUnwrap(capturedSecurity)
            XCTAssertEqual(security.connectionID, transport.connectionID)
            XCTAssertEqual(security.principal.runID, runID)
            XCTAssertEqual(security.principal.assurance, .displayNameOnly)
            XCTAssertNil(security.principal.verifiedIdentityFingerprint, "No executable stat or stale verified identity cache")
            XCTAssertTrue(security.authorizedCanonicalRoots.isEmpty, "No filesystem canonicalization or filesystem grant")
            XCTAssertTrue(security.ephemeralGrantedToolNames.isEmpty)
            XCTAssertFalse(security.hasAuthoritativeRoutingContext)
            XCTAssertEqual(target.selectedModelRaw, rawModel)
            XCTAssertEqual(target.saveRequestGeneration, before + 1)
            XCTAssertNil(target.runID)
            XCTAssertTrue(target.items.isEmpty)
            target.saveDebounceTask?.cancel()

            if checkPermissions {
                await manager.setEnabled(false)
                let disabled = try await transport.callTool(name: MCPWindowToolName.agentSessionLink, arguments: args)
                XCTAssertTrue(disabled.rawJSON.contains("disabled"), disabled.rawJSON)
                await manager.setEnabled(true)
                _ = await authority.revoke(linkID: activation.grant.id, generation: activation.grant.generation, reason: .userRequested)
                guard case let .reserved(watchReservation, _) = await authority.reserveLink(observer: observerEndpoint, target: targetEndpoint, capabilities: DomainAgentSessionLinkCapability.version1),
                      case .activated = await authority.activateLink(
                          reservation: watchReservation, initialSnapshot: host.agentSessionLinkObservationSnapshot(for: candidate), sourcePublicationSequence: 2
                      ) else { return XCTFail("Expected Watch-only link") }
                let watchOnly = try await transport.callTool(name: MCPWindowToolName.agentSessionLink, arguments: args)
                XCTAssertTrue(watchOnly.rawJSON.contains("management_not_granted"), watchOnly.rawJSON)
            } else {
                var mismatched = args
                mismatched["_windowID"] = fixture.contextB.window.windowID
                let wrongWindow = try await transport.callTool(name: MCPWindowToolName.agentSessionLink, arguments: mismatched)
                XCTAssertTrue(wrongWindow.rawJSON.contains("already-installed"), wrongWindow.rawJSON)
                window.mcpServer.tabContextByConnectionID.removeValue(forKey: transport.connectionID)
                let cold = try await transport.callTool(name: MCPWindowToolName.agentSessionLink, arguments: args)
                XCTAssertTrue(cold.rawJSON.contains("already-installed"), cold.rawJSON)
                XCTAssertNil(window.mcpServer.tabContextByConnectionID[transport.connectionID], "tools/call must not repair cold routing")
                window.mcpServer.tabContextByConnectionID[transport.connectionID] = installed
                window.mcpServer.connectionIDByRunID[runID] = UUID()
                let stale = try await transport.callTool(name: MCPWindowToolName.agentSessionLink, arguments: args)
                XCTAssertTrue(stale.rawJSON.contains("already-installed"), stale.rawJSON)
                XCTAssertNotEqual(window.mcpServer.connectionIDByRunID[runID], transport.connectionID)
                window.mcpServer.connectionIDByRunID[runID] = transport.connectionID
                host.allWindows.append(window)
                let ambiguous = try await transport.callTool(name: MCPWindowToolName.agentSessionLink, arguments: args)
                XCTAssertTrue(ambiguous.rawJSON.contains("already-installed"), ambiguous.rawJSON)
                host.allWindows.removeLast()
                await AppDomainRuntimeComposition.shared.runtime.domainHost.debugSetBeforeProviderActivationForTesting { _, tool, _ in
                    if tool == MCPWindowToolName.agentSessionLink {
                        await MainActor.run { window.mcpServer.connectionIDByRunID[runID] = UUID() }
                    }
                }
                let displacedAtEntry = try await transport.callTool(name: MCPWindowToolName.agentSessionLink, arguments: args)
                XCTAssertTrue(displacedAtEntry.rawJSON.contains("already-installed"), displacedAtEntry.rawJSON)
                XCTAssertNotEqual(window.mcpServer.connectionIDByRunID[runID], transport.connectionID)
                window.mcpServer.connectionIDByRunID[runID] = transport.connectionID
            }
            XCTAssertEqual(target.saveRequestGeneration, before + 1, "Every denied call must leave target configuration untouched")
            await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
        }
    }

    private actor ModelTransportSecurityProbe {
        var context: DomainToolInvocationSecurityContext?

        func record(_ context: DomainToolInvocationSecurityContext?) {
            self.context = context
        }
    }
#endif
