import Foundation
import RepoPromptDomainRuntime

struct AgentSessionLinkModelReceipt {
    let modelID: String
    let modelRaw: String
    let reasoningEffortRaw: String?
    let changed: Bool
}

enum AgentSessionLinkModelOutcome {
    case accepted(AgentSessionLinkModelReceipt)
    case blocked(AgentSessionLinkSendFailure)
    case invalid(String)
}

extension AgentSessionLinkEndpointHost {
    func agentSessionLinkModelAvailability(windowID _: Int) -> AgentModelCatalog.AvailabilityContext {
        .none
    }

    func agentSessionLinkModelCandidate(
        for _: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkEndpointCandidate? {
        nil
    }

    func agentSessionLinkPerformSetModel(
        to _: AgentSessionLinkEndpointCandidate,
        modelID _: String,
        liveness _: @escaping AgentSessionLinkSendLivenessProbe,
        reauthorize _: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkModelOutcome {
        .blocked(.endpointHost)
    }
}

extension AgentModeViewModel {
    /// The target owns the final suspension. No hydration, provider calls, composer claim, or
    /// discovery occurs here. A concurrent send winning during reauthorization must defeat us.
    func agentSessionLinkPerformSetModel(
        to candidate: AgentSessionLinkEndpointCandidate,
        modelID: String,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        availability: @MainActor () -> AgentModelCatalog.AvailabilityContext,
        reauthorize: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkModelOutcome {
        guard let session = agentSessionLinkLiveSession(matching: candidate),
              liveness().permitsDelivery, !Task.isCancelled else { return .blocked(.endpointInvalidated) }
        if let failure = agentSessionLinkModelReadiness(session) { return .blocked(failure) }
        let admittedAvailability = availability()
        do {
            let selection = try AgentAdvertisedModelCatalog.shared.selection(modelID, availability: admittedAvailability)
            guard selection.agent == session.selectedAgent else {
                return .invalid("set_model cannot change agent kind (current: \(session.selectedAgent.rawValue)). Use agent_manage.list_agents for a same-agent model_id.")
            }
        } catch let error as AgentAdvertisedModelCatalog.AdmissionError { return .invalid(error.message) }
        catch { return .invalid("Model catalogue admission failed.") }

        let commit = await reauthorize()
        guard commit == .committed else { return .blocked(commit.refusal) }
        // Last suspension above. Exact object, both endpoints, workspace, readiness, and original
        // full-ID membership are re-read synchronously before any configuration assignment.
        guard !Task.isCancelled, liveness().permitsDelivery,
              agentSessionLinkLiveSession(matching: candidate) === session,
              workspaceManager?.activeWorkspace?.id == candidate.workspaceID
        else {
            return .blocked(.endpointInvalidated)
        }
        if let failure = agentSessionLinkModelReadiness(session) { return .blocked(failure) }
        guard availability() == admittedAvailability else {
            return .invalid("Destination model availability changed. Refresh agent_manage.list_agents and retry.")
        }
        do {
            let selection = try AgentAdvertisedModelCatalog.shared.selection(modelID, availability: admittedAvailability)
            guard selection.agent == session.selectedAgent else {
                return .invalid("The target agent changed. Refresh agent_manage.list_agents and choose a same-agent model_id.")
            }
            return .accepted(agentSessionLinkCommitModel(selection, to: session))
        } catch let error as AgentAdvertisedModelCatalog.AdmissionError { return .invalid(error.message) }
        catch { return .invalid("Model catalogue admission failed.") }
    }

    private func agentSessionLinkModelReadiness(_ session: TabSession) -> AgentSessionLinkSendFailure? {
        AgentSessionLinkDeliveryReadiness.managedDeliveryFailure(snapshot: Self.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        ))
    }

    /// Synchronous commit seam: only per-session model/effort, narrow active UI, and scheduled save.
    private func agentSessionLinkCommitModel(
        _ selection: AgentAdvertisedModelCatalog.Selection,
        to session: TabSession
    ) -> AgentSessionLinkModelReceipt {
        let changed = session.selectedModelRaw != selection.storedModelRaw
            || session.selectedReasoningEffortRaw != selection.reasoningEffortRaw
        if changed {
            session.selectedModelRaw = selection.storedModelRaw
            session.selectedReasoningEffortRaw = selection.reasoningEffortRaw
            session.isDirty = true
            if session.tabID == currentTabID {
                let restoring = isRestoringState
                isRestoringState = true
                defer { isRestoringState = restoring }
                selectedModelRaw = session.selectedModelRaw
                selectedReasoningEffortRaw = session.selectedReasoningEffortRaw
                // Do not call makeComposerProps: it resolves parameter/worktree/catalogue state.
                // Publish only selection, dropping old model-qualified controls (not their pins).
                var props = ui.composer.props
                props.selectedModelRaw = session.selectedModelRaw
                props.selectedModelDisplayName = selection.option.displayName
                props.selectedReasoningEffortRaw = session.selectedReasoningEffortRaw
                props.selectedReasoningEffortDisplayName = selection.reasoningEffortRaw ?? ""
                props.acpModelParameterControls = []
                ui.composer.update(props)
            }
            scheduleSave(for: session)
            let binding = session.persistentSessionBindingIdentity
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, sessions[session.tabID] === session,
                      session.persistentSessionBindingIdentity == binding else { return }
                handleObservedMCPStateChange(for: session)
            }
        }
        return AgentSessionLinkModelReceipt(
            modelID: selection.id.rawValue, modelRaw: session.selectedModelRaw,
            reasoningEffortRaw: session.selectedReasoningEffortRaw, changed: changed
        )
    }
}
