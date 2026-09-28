import Foundation
import MCP
import RepoPromptDomainRuntime

extension WindowStatesManager {
    func agentSessionLinkWasCreatedBy(sessionID: UUID, creatorSessionID: UUID) -> Bool {
        guard !isTerminating else { return false }
        return allWindows.contains { window in
            !window.isClosing && window.agentModeViewModel.agentSessionLinkWasCreatedBy(
                sessionID: sessionID, creatorSessionID: creatorSessionID
            )
        }
    }

    func agentSessionLinkHasChildSessions(parentSessionID: UUID) -> Bool {
        guard !isTerminating else { return true }
        return allWindows.contains { window in
            !window.isClosing && window.agentModeViewModel.agentSessionLinkHasChildSessions(
                parentSessionID: parentSessionID
            )
        }
    }

    func agentSessionLinkHasPersistedChildSessions(parentSessionID: UUID) async -> Bool {
        guard !isTerminating else { return true }
        var visited: Set<UUID> = []
        for window in allWindows where !window.isClosing {
            for workspace in window.workspaceManager.workspaces where visited.insert(workspace.id).inserted {
                do {
                    if try await AgentSessionDataService.shared.hasPersistedChildSession(
                        parentSessionID: parentSessionID, workspace: workspace
                    ) { return true }
                } catch {
                    // An unreadable inventory cannot prove that retirement is child-free.
                    return true
                }
            }
        }
        return false
    }

    func agentSessionLinkBindingCount(sessionID: UUID) -> Int {
        guard !isTerminating else { return 0 }
        return allWindows.filter { !$0.isClosing }.reduce(0) { count, window in
            count + window.workspaceManager.workspaces.reduce(0) { workspaceCount, workspace in
                workspaceCount + workspace.composeTabs.count(where: {
                    $0.activeAgentSessionID == sessionID
                })
            }
        }
    }

    /// Route only to a registered, non-closing window whose requested workspace is already active.
    /// No window focus or workspace switch is performed on the overseer's behalf.
    func agentSessionLinkCreateLane(
        destinationWindowID: Int,
        workspaceID: UUID,
        creatorSessionID: UUID,
        sessionName: String?,
        selection: AgentSessionLanePolicy.RoleSelection
    ) async throws -> AgentSessionLaneHostCreationOutcome {
        guard !isTerminating,
              let window = window(withID: destinationWindowID),
              !window.isClosing,
              window.workspaceManager.activeWorkspaceID == workspaceID,
              window.workspaceManager.activeWorkspace?.id == workspaceID
        else {
            throw MCPError.invalidParams("The lane destination is unavailable.")
        }
        let outcome = try await window.agentModeViewModel.mcpCreateOversightLane(
            creatorSessionID: creatorSessionID,
            sessionName: sessionName,
            selection: selection,
            expectedWorkspaceID: workspaceID
        )
        switch outcome {
        case let .created(sessionID, tabID, bindingToken):
            return .created(sessionID: sessionID, tabID: tabID, bindingToken: bindingToken)
        case let .creationIncomplete(sessionID, tabID):
            return .creationIncomplete(sessionID: sessionID, tabID: tabID)
        }
    }

    func agentSessionLinkRetireLane(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        commit: Bool,
        isStillRetirable: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard !isTerminating,
              let window = window(withID: endpoint.windowID),
              !window.isClosing,
              window.workspaceManager.activeWorkspaceID == endpoint.workspaceID,
              window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint
        else { return false }
        return await window.agentModeViewModel.agentSessionLinkRetireLane(
            endpoint: endpoint,
            commit: commit,
            isStillRetirable: isStillRetirable
        )
    }

    func agentSessionLinkLaneProvenance(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UUID? {
        guard !isTerminating,
              let window = window(withID: endpoint.windowID),
              !window.isClosing
        else { return nil }
        return window.agentModeViewModel.agentSessionLinkLaneProvenance(for: endpoint)
    }

    func agentSessionLinkLaneCreatorLabel(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> String? {
        guard !isTerminating,
              let window = window(withID: endpoint.windowID),
              !window.isClosing
        else { return nil }
        return window.agentModeViewModel.agentSessionLinkLaneCreatorLabel(for: endpoint)
    }
}
