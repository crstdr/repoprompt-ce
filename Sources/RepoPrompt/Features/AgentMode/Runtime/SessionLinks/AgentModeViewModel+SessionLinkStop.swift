import Foundation
import RepoPromptDomainRuntime

/// One-shot, exact-object managed Stop. The authority fence precedes every target mutation;
/// cancellation then follows the same run-service path as the lane user's Stop.
extension AgentModeViewModel {
    func agentSessionLinkPerformStop(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkStopRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        queueHasCommittedDrain: @escaping @MainActor () -> Bool,
        withdrawInbound: @escaping @MainActor () -> Bool,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome,
        teardownDeadlineSeconds: TimeInterval = 30,
        auditDeadlineSeconds: TimeInterval = 5,
        beforeCleanupTask: @escaping @MainActor () -> Void = {}
    ) async -> AgentSessionLinkStopTransactionOutcome {
        guard let session = agentSessionLinkLiveSession(matching: candidate), liveness().permitsDelivery else {
            return .blocked(.endpointInvalidated)
        }
        guard (try? mcpSettledLiveSessionForStop(sessionID: candidate.sessionID)) === session else {
            return .blocked(.targetLoading)
        }
        let initial = Self.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        )
        if case let .blocked(failure) = AgentSessionLinkStopAdmission.classify(initial) {
            return .blocked(failure)
        }
        if queueHasCommittedDrain() { return .blocked(.targetBusy) }

        let commit = await commitAuthorization()
        guard commit == .committed else { return .blocked(commit.refusal) }

        // No suspension from this recheck through selection, queue withdrawal and gate claim.
        guard agentSessionLinkLiveSession(matching: candidate) === session,
              liveness().permitsDelivery,
              workspaceManager?.activeWorkspace?.id == candidate.workspaceID,
              (try? mcpSettledLiveSessionForStop(sessionID: candidate.sessionID)) === session
        else { return .blocked(.endpointInvalidated) }
        let snapshot = Self.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        )
        let selection = AgentSessionLinkStopAdmission.classify(snapshot)
        if case let .blocked(failure) = selection { return .blocked(failure) }
        if queueHasCommittedDrain() { return .blocked(.targetBusy) }
        guard let binding = session.persistentSessionBindingIdentity else { return .blocked(.targetBusy) }

        if selection == .notRunning {
            return .settled(Self.agentSessionLinkStopReceipt(
                request: request, targetSessionID: candidate.sessionID,
                result: .notRunning, stopRequested: false, audit: .notRequired,
                runState: session.runState.rawValue
            ))
        }
        if selection == .activeRun, session.activeRunOwnership == nil || session.runID == nil {
            return .blocked(.targetBusy)
        }
        guard withdrawInbound() else { return .blocked(.targetBusy) }

        let admission = AgentRunCancellationAdmission(
            scope: selection == .activeRun ? .activeRun : .pendingStart,
            session: session,
            binding: binding,
            expectedOwnership: session.activeRunOwnership,
            expectedRunID: session.runID,
            cancellationGeneration: session.stopState.cancellationGeneration,
            pendingStartFence: nil,
            validateAndClaim: { [weak self, weak session] in
                guard let self, let session else { return false }
                return agentSessionLinkLiveSession(matching: candidate) === session
                    && workspaceManager?.activeWorkspace?.id == candidate.workspaceID
            }
        )

        if selection == .pendingStart {
            guard withdrawPendingStartForSessionLink(session: session, admission: admission) else {
                return .settled(Self.agentSessionLinkStopReceipt(
                    request: request, targetSessionID: candidate.sessionID,
                    result: .stopFailed, failure: .cancellationUnconfirmed,
                    stopRequested: true, audit: .notRequired
                ))
            }
            let itemID = agentSessionLinkAppendStopRow(
                request: request, candidate: candidate, session: session, binding: binding
            )
            let audit = await agentSessionLinkFlushStopAudit(
                candidate: candidate, session: session, binding: binding,
                itemID: itemID, deadlineSeconds: auditDeadlineSeconds
            )
            return .settled(Self.agentSessionLinkStopReceipt(
                request: request, targetSessionID: candidate.sessionID,
                result: .stopped, stopRequested: true, itemID: itemID,
                audit: audit, runState: "pending_start_withdrawn"
            ))
        }

        guard let ownership = session.activeRunOwnership, session.runID != nil else {
            return .blocked(.targetBusy)
        }
        // This is the synchronous claim: a deferred producer cannot enter while the cleanup task
        // is waiting for its first MainActor turn.
        guard session.stopState.claimManagedStop(id: request.requestID, binding: binding) else {
            return .blocked(.targetBusy)
        }
        session.noteMonitorObservationInputsChanged()
        requestUIRefresh(tabID: candidate.tabID, urgent: true)
        let recorder = AgentRunCancellationOutcomeRecorder(
            expectedOwnership: ownership,
            expectedRunID: session.runID,
            expectedBinding: binding,
            onAcceptedPrimaryPublication: { [weak self, weak session] _ in
                guard let self, let session else { return }
                _ = agentSessionLinkAppendStopRow(
                    request: request, candidate: candidate, session: session, binding: binding
                )
            }
        )
        let teardown = AgentSessionLinkStopSignal<Bool>()
        let audit = AgentSessionLinkStopSignal<DomainAgentSessionLinkStopReceipt.AuditStatus>()
        Task { [weak self, weak session] in
            session?.stopState.markCleanupStarted(id: request.requestID, binding: binding)
            guard let self, let session else {
                teardown.finish(false)
                audit.finish(.unknown)
                return
            }
            beforeCleanupTask()
            let routed = await cancelAgentRunForSessionLink(
                session: session, admission: admission, outcomeRecorder: recorder
            )
            teardown.finish(routed && recorder.teardownCompleted)
            if session.stopState.releaseManagedStop(id: request.requestID, binding: binding) {
                session.noteMonitorObservationInputsChanged()
                requestUIRefresh(tabID: candidate.tabID, urgent: true)
            }
            let itemID = session.items.contains(where: { $0.id == request.requestID })
                ? request.requestID : nil
            await audit.finish(agentSessionLinkFlushStopAudit(
                candidate: candidate, session: session, binding: binding,
                itemID: itemID, deadlineSeconds: auditDeadlineSeconds
            ))
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, teardownDeadlineSeconds) * 1_000_000_000))
            teardown.finish(false)
            session.stopState.markCleanupUnclaimedIfNeverStarted(id: request.requestID, binding: binding)
        }
        let teardownCompleted = await teardown.value()
        let accepted = if case .accepted? = recorder.publicationResult { true } else { false }
        let itemID = session.items.contains(where: { $0.id == request.requestID })
            ? request.requestID : nil
        if !teardownCompleted {
            if !recorder.initiatedCancellation, session.runState.isTerminalForCommit {
                return .settled(Self.agentSessionLinkStopReceipt(
                    request: request, targetSessionID: candidate.sessionID,
                    result: .notRunning, stopRequested: false,
                    audit: .notRequired, runState: session.runState.rawValue
                ))
            }
            let failure: DomainAgentSessionLinkStopReceipt.FailureReason = switch recorder.publicationResult {
            case .accepted?: .teardownTimeout
            case .stale?: .terminalPublicationStale
            case .rejected?: .terminalPublicationRejected
            case nil: .cancellationUnconfirmed
            }
            return .settled(Self.agentSessionLinkStopReceipt(
                request: request, targetSessionID: candidate.sessionID,
                result: .stopFailed, failure: failure,
                stopRequested: recorder.initiatedCancellation,
                teardownCompleted: recorder.teardownCompleted,
                itemID: itemID, audit: itemID == nil ? .notRequired : .unknown,
                runState: recorder.primaryRevision?.terminalState.rawValue
            ))
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, auditDeadlineSeconds) * 1_000_000_000))
            audit.finish(.unknown)
        }
        let auditStatus = await audit.value()
        return .settled(Self.agentSessionLinkStopReceipt(
            request: request, targetSessionID: candidate.sessionID,
            result: accepted ? .stopped : .stopFailed,
            failure: accepted ? nil : .cancellationUnconfirmed,
            stopRequested: recorder.initiatedCancellation,
            teardownCompleted: recorder.teardownCompleted,
            itemID: itemID, audit: auditStatus,
            runState: recorder.primaryRevision?.terminalState.rawValue
        ))
    }

    private func agentSessionLinkAppendStopRow(
        request: AgentSessionLinkStopRequest,
        candidate: AgentSessionLinkEndpointCandidate,
        session: TabSession,
        binding: AgentPersistentSessionBindingIdentity
    ) -> UUID? {
        guard agentSessionLinkLiveSession(matching: candidate) === session,
              session.persistentSessionBindingIdentity == binding
        else { return nil }
        if session.items.contains(where: { $0.id == request.requestID }) { return request.requestID }
        session.appendItem(.overseerRunStopped(
            stopID: request.requestID, stoppedAt: Date(),
            attribution: request.attribution, sequenceIndex: session.nextSequenceIndex
        ))
        updateBindingsFromSession(session)
        scheduleSave(for: candidate.tabID)
        requestUIRefresh(tabID: candidate.tabID, urgent: true)
        return request.requestID
    }

    private func agentSessionLinkFlushStopAudit(
        candidate: AgentSessionLinkEndpointCandidate,
        session: TabSession,
        binding: AgentPersistentSessionBindingIdentity,
        itemID: UUID?,
        deadlineSeconds: TimeInterval
    ) async -> DomainAgentSessionLinkStopReceipt.AuditStatus {
        guard itemID != nil else { return .failed }
        guard agentSessionLinkLiveSession(matching: candidate) === session,
              session.persistentSessionBindingIdentity == binding
        else { return .failed }
        let signal = AgentSessionLinkStopSignal<DomainAgentSessionLinkStopReceipt.AuditStatus>()
        Task { [weak self] in
            guard let self else { signal.finish(.unknown)
                return
            }
            let result = await flushSaveRequired(
                for: candidate.tabID, workspaceID: candidate.workspaceID
            )
            switch result {
            case .success: signal.finish(.persisted)
            case .failure: signal.finish(.failed)
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadlineSeconds) * 1_000_000_000))
            signal.finish(.unknown)
        }
        return await signal.value()
    }

    private static func agentSessionLinkStopReceipt(
        request: AgentSessionLinkStopRequest,
        targetSessionID: UUID,
        result: DomainAgentSessionLinkStopReceipt.Result,
        failure: DomainAgentSessionLinkStopReceipt.FailureReason? = nil,
        stopRequested: Bool?,
        teardownCompleted: Bool? = nil,
        itemID: UUID? = nil,
        audit: DomainAgentSessionLinkStopReceipt.AuditStatus,
        runState: String? = nil
    ) -> DomainAgentSessionLinkStopReceipt {
        DomainAgentSessionLinkStopReceipt(
            requestID: request.requestID, targetSessionID: targetSessionID,
            result: result, failureReason: failure,
            stopRequested: stopRequested, teardownCompleted: teardownCompleted,
            targetItemID: itemID?.uuidString, auditStatus: audit,
            resultingRunState: runState, settledAt: Date()
        )
    }
}
