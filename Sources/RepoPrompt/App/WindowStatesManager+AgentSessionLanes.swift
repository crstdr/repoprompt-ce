import Foundation
import MCP
import RepoPromptDomainRuntime

extension WindowStatesManager {
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
        case let .created(sessionID, tabID): return .created(sessionID: sessionID, tabID: tabID)
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
