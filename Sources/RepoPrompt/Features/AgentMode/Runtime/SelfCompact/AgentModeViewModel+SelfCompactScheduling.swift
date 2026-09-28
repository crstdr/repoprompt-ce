import Foundation
import RepoPromptDomainRuntime

/// The self-compaction request is never exposed until the service is wired in a later item. These
/// routines are the app-side owner of its terminal boundary, not a second overseer transaction.
extension AgentModeViewModel {
    /// Synchronous admission captures the authoritative run attempt before a future MCP await.
    func agentSelfCompactSchedule(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        runID: UUID,
        runAttemptID: UUID,
        note: String,
        idempotencyKey: String
    ) -> AgentSelfCompactState.Reservation? {
        guard let session = sessions[endpoint.tabID],
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              session.runID == runID,
              session.runState == .running,
              session.activeRunOwnership?.attemptID == runAttemptID,
              let bindingGeneration = endpoint.persistentBindingGeneration,
              !session.terminalCommitInProgress
        else { return nil }
        let owner = AgentSelfCompactOwner(
            windowID: endpoint.windowID,
            workspaceID: endpoint.workspaceID,
            tabID: endpoint.tabID,
            sessionID: endpoint.sessionID,
            persistentBindingGeneration: bindingGeneration,
            bindingTransitionGeneration: endpoint.bindingTransitionGeneration,
            runID: runID,
            runAttemptID: runAttemptID
        )
        var state = session.selfCompactState
        let reservation = state.reserve(note: note, idempotencyKey: idempotencyKey, owner: owner)
        if case .scheduled = reservation {
            let support = agentSessionLinkCompactSupport(for: session)
            // ACP self-dispatch stays disabled until its fire-and-forget completion contract lands.
            guard support == .codex || support == .claudeCode else {
                return nil
            }
            state.active?.admittedSupport = support
            session.selfCompactState = state
            scheduleSave(for: session)
        }
        return reservation
    }

    func agentSelfCompactTerminalSettled(
        session: TabSession,
        revision: AgentRunTerminalCommitRevision,
        publication: AgentRunTerminalPublicationResult,
        teardownSettled: @escaping @MainActor () -> Bool
    ) {
        guard session.selfCompactState.active?.phase == .scheduled else { return }
        agentSelfCompactScheduler(for: session).terminalSettled(
            runID: revision.expectedRunID,
            runAttemptID: revision.ownership.attemptID,
            terminalState: revision.terminalState,
            publication: publication,
            successorClaimed: revision.successorKind != nil,
            teardownSettled: teardownSettled
        )
    }

    func agentSelfCompactCancelForAcceptedLocalInput(_ session: TabSession) {
        guard session.selfCompactState.active != nil else { return }
        agentSelfCompactScheduler(for: session).cancelForAcceptedLocalInput()
    }

    private func agentSelfCompactScheduler(for session: TabSession) -> AgentSelfCompactTerminalScheduler {
        AgentSelfCompactTerminalScheduler(
            load: { session.selfCompactState },
            store: { [weak self] state in
                let previous = session.selfCompactState
                session.selfCompactState = state
                if previous.active != nil, state.active == nil {
                    let row: AgentChatItem? = switch state.latest?.outcome {
                    case .cancelled:
                        AgentChatItem.selfCompactionCancelled(sequenceIndex: session.nextSequenceIndex)
                    case .failed:
                        AgentChatItem.selfCompactionCouldNotStart(sequenceIndex: session.nextSequenceIndex)
                    default:
                        nil
                    }
                    if let row {
                        session.appendItem(row)
                        self?.updateBindingsFromSession(session)
                    }
                }
                self?.scheduleSave(for: session)
                self?.requestUIRefresh(tabID: session.tabID, urgent: true)
            },
            isCurrentOwner: { [weak self] owner in
                self?.agentSelfCompactOwnerIsCurrent(owner, session: session) ?? false
            },
            hasActiveTools: { [weak self] runID in
                self?.agentSelfCompactHasActiveMCPTools(runID: runID) ?? false
            },
            support: { [weak self] in
                self?.agentSessionLinkCompactSupport(for: session) ?? .notSupported
            },
            dispatch: { [weak self] requestID, support, stillAdmissible in
                guard let self else { return false }
                return await agentSelfCompactDispatchNative(
                    requestID: requestID,
                    session: session,
                    support: support,
                    stillAdmissible: stillAdmissible
                )
            }
        )
    }

    private func agentSelfCompactOwnerIsCurrent(
        _ owner: AgentSelfCompactOwner,
        session: TabSession
    ) -> Bool {
        guard sessions[owner.tabID] === session,
              let endpoint = agentSessionLinkObserverEndpoint(tabID: owner.tabID)
        else { return false }
        return endpoint.windowID == owner.windowID
            && endpoint.workspaceID == owner.workspaceID
            && endpoint.tabID == owner.tabID
            && endpoint.sessionID == owner.sessionID
            && endpoint.persistentBindingGeneration == owner.persistentBindingGeneration
            && endpoint.bindingTransitionGeneration == owner.bindingTransitionGeneration
    }

    private func agentSelfCompactDispatchNative(
        requestID: UUID,
        session: TabSession,
        support: AgentSessionLinkCompactSupport,
        stillAdmissible: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard let owner = session.selfCompactState.active?.owner,
              stillAdmissible(),
              let target = makeComposerSubmitTarget(tabID: owner.tabID, session: session),
              target.route == .existingAgentSession,
              target.expectedSourceAgentSessionID == owner.sessionID
        else { return false }
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
        )
        guard case let .claimed(claim) = claimComposerSubmitAttempt(
            attempt, requireActiveTabOwnership: false
        ) else { return false }
        defer { releaseComposerSubmitClaim(claim) }

        let ready: @MainActor () -> Bool = { [weak self] in
            guard let self, stillAdmissible(), composerSubmitClaimIsCurrent(claim),
                  !Self.agentSessionLinkCompactHasQueuedProviderWork(session),
                  agentSessionLinkCompactSupport(for: session) == support,
                  workspaceManager?.activeWorkspace?.id == owner.workspaceID
            else { return false }
            return AgentSessionLinkDeliveryReadiness.evaluate(
                snapshot: Self.agentSessionLinkDeliveryReadinessSnapshot(
                    session: session,
                    endpointMatchesGrant: agentSelfCompactOwnerIsCurrent(owner, session: session),
                    isClosing: false,
                    ignoresComposerSubmissionInFlight: true,
                    ignoresSelfCompactRequestID: requestID
                )
            ) == .ready
        }
        guard ready() else { return false }

        // The fixed system row and attempt state are saved before any native command. The note
        // itself is never written to provider-replayed row text.
        let row = AgentChatItem.selfCompactionRequest(sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        updateBindingsFromSession(session)
        requestUIRefresh(tabID: owner.tabID, urgent: true)
        if case .failure = await flushSaveRequired(for: owner.tabID, workspaceID: owner.workspaceID) {
            if let index = session.items.firstIndex(where: { $0.id == row.id }) {
                _ = session.removeItem(at: index)
            }
            _ = await flushSaveRequired(for: owner.tabID, workspaceID: owner.workspaceID)
            return false
        }
        guard ready() else { return false }
        let result = await agentSessionLinkDispatchNativeCompact(
            session: session,
            tabID: owner.tabID,
            support: support,
            isStillAdmissible: ready
        )
        return result == .started
    }
}
