import Foundation
import MCP
import RepoPromptDomainRuntime

extension AgentModeViewModel {
    enum MCPOversightLaneCreationOutcome: Equatable {
        case created(sessionID: UUID, tabID: UUID, bindingToken: AgentSessionRestorationBindingToken)
        case creationIncomplete(sessionID: UUID, tabID: UUID)
    }

    /// Creates a user-visible, top-level session without MCP ownership or a provider turn. The
    /// caller may establish an oversight link only after `.created` proves the first payload save.
    func mcpCreateOversightLane(
        creatorSessionID: UUID,
        sessionName: String?,
        selection: AgentSessionLanePolicy.RoleSelection,
        expectedWorkspaceID: UUID
    ) async throws -> MCPOversightLaneCreationOutcome {
        guard workspaceManager?.activeWorkspaceID == expectedWorkspaceID,
              workspaceManager?.activeWorkspace?.id == expectedWorkspaceID
        else {
            throw MCPError.invalidParams("The destination workspace is not active.")
        }
        let target = try await mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: sessionName,
            parentSessionID: nil,
            inheritWorktreeBindings: false,
            expectedWorkspaceID: expectedWorkspaceID,
            creationKind: .oversightLane(creatorSessionID: creatorSessionID)
        )
        // A published lane is an ordinary session even if later configuration or persistence fails.
        // Accept the provisional admission rather than invoking MCP's discard/delete recovery path.
        mcpAcceptSessionTarget(target)
        // Acceptance settles the recovery claim. Subsequent configuration checks must use the
        // claimless exact lifecycle identity, not ask a settled claim to still be provisional.
        let settledTarget = MCPSessionTarget(
            tabID: target.tabID, sessionID: target.sessionID,
            origin: .existingSession, lifecycleIdentity: target.lifecycleIdentity
        )
        guard let sessionID = target.sessionID else {
            throw MCPError.internalError("The new lane has no session ID.")
        }
        let incomplete: MCPOversightLaneCreationOutcome = .creationIncomplete(
            sessionID: sessionID,
            tabID: target.tabID
        )
        guard let session = session(for: target.tabID, createIfNeeded: false),
              session.activeAgentSessionID == sessionID,
              session.createdByOverseerSessionID == creatorSessionID,
              session.parentSessionID == nil,
              !session.isMCPOriginated,
              session.mcpControlContext == nil
        else { return incomplete }

        // Provenance was installed by the fresh-session seam before this first dirty marking.
        session.isDirty = true
        #if DEBUG
            await test_afterOversightLaneProvision?(target.tabID)
        #endif
        do {
            try requireCurrentMCPWorkspaceTarget(settledTarget, expectedWorkspaceID: expectedWorkspaceID)
            try await mcpConfigureSession(
                tabID: target.tabID,
                agentRaw: selection.agentRaw,
                modelRaw: selection.modelRaw,
                reasoningEffortRaw: selection.reasoningEffortRaw,
                requireInactiveRunState: true,
                workspaceAuthority: .init(
                    target: settledTarget,
                    expectedWorkspaceID: expectedWorkspaceID,
                    allowMatchingControlledSession: false
                )
            )
            try requireCurrentMCPWorkspaceTarget(settledTarget, expectedWorkspaceID: expectedWorkspaceID)
            try mcpApplyModelParameterSelections(
                tabID: target.tabID,
                selections: selection.modelParameterSelections
            )
            guard mcpOversightLaneSelectionMatches(selection, session: session)
            else {
                scheduleSave(for: session)
                return incomplete
            }
        } catch {
            scheduleSave(for: session)
            return incomplete
        }

        guard await mcpCommitOversightLaneFirstSave(
            session: session,
            sessionID: sessionID,
            workspaceID: expectedWorkspaceID
        ) else {
            scheduleSave(for: session)
            return incomplete
        }
        guard session.activeAgentSessionID == sessionID,
              session.createdByOverseerSessionID == creatorSessionID,
              session.parentSessionID == nil,
              session.mcpControlContext == nil,
              !session.isMCPOriginated
        else { return incomplete }
        guard case let .authoritative(bindingToken, .freshBindingDurablyCreated) = session.restorationReadiness
        else { return incomplete }
        return .created(sessionID: sessionID, tabID: target.tabID, bindingToken: bindingToken)
    }

    private func mcpOversightLaneSelectionMatches(
        _ selection: AgentSessionLanePolicy.RoleSelection,
        session: TabSession
    ) -> Bool {
        guard session.selectedAgent.rawValue == selection.agentRaw,
              selection.reasoningEffortRaw.map({ session.selectedReasoningEffortRaw == $0 }) ?? true
        else { return false }
        if session.selectedAgent == .codexExec {
            let requested = CodexModelSpecifier(raw: selection.modelRaw)
            let installed = CodexModelSpecifier(raw: session.selectedModelRaw)
            return requested.baseModel == installed.baseModel
                && requested.serviceTier == installed.serviceTier
        }
        if session.selectedAgent.usesClaudeNativeRuntime {
            return ClaudeModelSpecifier(raw: selection.modelRaw).baseModel
                == ClaudeModelSpecifier(raw: session.selectedModelRaw).baseModel
        }
        return session.selectedModelRaw == selection.modelRaw
    }

    /// Exact-incarnation read for cap and retirement checks; a stale endpoint never inherits a
    /// replacement's provenance merely because the session UUID is the same.
    func agentSessionLinkLaneProvenance(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UUID? {
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              let session = session(for: endpoint.tabID, createIfNeeded: false),
              session.activeAgentSessionID == endpoint.sessionID
        else { return nil }
        if session.hasLoadedPersistedState {
            return session.createdByOverseerSessionID
        }
        return ownerValidatedSessionIndex[endpoint.sessionID]?.createdByOverseerSessionID
    }

    func agentSessionLinkLaneCreatorLabel(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> String? {
        guard let creatorID = agentSessionLinkLaneProvenance(for: endpoint) else { return nil }
        return agentSessionLinkLaneCreatorLabel(creatorID: creatorID)
    }

    func agentSessionLinkLaneCreatorLabel(for sessionID: UUID) -> String? {
        guard let creatorID = ownerValidatedSessionIndex[sessionID]?.createdByOverseerSessionID else {
            return nil
        }
        return agentSessionLinkLaneCreatorLabel(creatorID: creatorID)
    }

    private func agentSessionLinkLaneCreatorLabel(creatorID: UUID) -> String {
        let name = ownerValidatedSessionIndex[creatorID]?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.flatMap { $0.isEmpty ? nil : $0 }
            ?? AgentMonitorSessionIDFormatter.short(creatorID)
    }

    /// Preflight or stash one exact inactive lane. Both removal CAS hooks repeat the check around
    /// the required session flush; a prompt or run starting during that await keeps the tab open.
    func agentSessionLinkRetireLane(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        commit: Bool,
        isStillRetirable: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let canRetire: @MainActor () -> Bool = { [weak self] in
            guard let self,
                  isStillRetirable(),
                  self.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
                  let session = self.session(for: endpoint.tabID, createIfNeeded: false),
                  session.activeAgentSessionID == endpoint.sessionID,
                  !session.runState.isActive,
                  session.waitingPrompt == nil,
                  Self.pendingInteractionKind(for: session) == nil,
                  !session.isComposerSubmissionInFlight,
                  !session.mcpFollowUpRunPending,
                  !session.terminalCommitInProgress,
                  session.pendingInstructions.isEmpty,
                  session.pendingACPSteeringInstructions.isEmpty,
                  session.pendingClaudeSteeringInstructions.isEmpty,
                  session.oversight.pendingAutoWake == nil
            else { return false }
            return true
        }
        guard canRetire(), let promptManager else { return false }
        guard commit else { return true }
        let report = await promptManager.stashComposeTabs(
            withIDs: [endpoint.tabID],
            isMutationContextCurrent: canRetire,
            postPreflightValidation: canRetire,
            expandCascade: false
        )
        return report.rejections.isEmpty
            && report.removedComposeTabIDs.contains(endpoint.tabID)
            && workspaceManager?.activeWorkspace?.stashedTabs.contains(where: {
                $0.tab.id == endpoint.tabID
            }) == true
    }
}
