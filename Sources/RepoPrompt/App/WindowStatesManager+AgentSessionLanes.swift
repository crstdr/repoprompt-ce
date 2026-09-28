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
    ) async throws -> AgentModeViewModel.MCPOversightLaneCreationOutcome {
        guard !isTerminating,
              let window = window(withID: destinationWindowID),
              !window.isClosing,
              window.workspaceManager.activeWorkspaceID == workspaceID,
              window.workspaceManager.activeWorkspace?.id == workspaceID
        else {
            throw MCPError.invalidParams("The lane destination is unavailable.")
        }
        return try await window.agentModeViewModel.mcpCreateOversightLane(
            creatorSessionID: creatorSessionID,
            sessionName: sessionName,
            selection: selection,
            expectedWorkspaceID: workspaceID
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
}
