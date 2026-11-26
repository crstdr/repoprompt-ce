import Foundation
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

@MainActor
extension AgentSessionLinkExecutionRuntime {
    /// Starts or coalesces the provider-free confirmation protocol. A hydrated marker is already
    /// durable; an acceptance callback must first persist Save A before projecting the clear.
    func providerSwitchReconcileConfirmation(
        for session: TabSession,
        markerAlreadyDurable: Bool
    ) {
        guard let scope,
              scope.sessions[session.tabID] === session,
              let acceptedID = session.pendingHandoff.providerSwitchAcceptedID,
              session.pendingHandoff.providerSwitchDelivery == .sending,
              let sessionID = session.activeAgentSessionID
        else { return }
        if providerSwitchConfirmationFlights[session.tabID] != nil { return }
        let flightID = UUID()
        providerSwitchConfirmationFlights[session.tabID] = flightID
        session.providerSwitchConfirmationSaveFailed = false
        providerSwitchConfirmationSaveFailures.remove(sessionID)
        let task = Task { @MainActor [weak self, weak session, weak scope] in
            guard let self, let session, let scope else { return }
            defer {
                if self.providerSwitchConfirmationFlights[session.tabID] == flightID {
                    self.providerSwitchConfirmationFlights.removeValue(forKey: session.tabID)
                }
                self.pendingSendEffects.removeValue(forKey: flightID)
                scope.noteSettlementChanged()
            }
            var markerDurable = markerAlreadyDurable
            var lastFailure = false
            for attempt in 0..<3 {
                guard scope.sessions[session.tabID] === session,
                      session.activeAgentSessionID == sessionID,
                      session.pendingHandoff.providerSwitchAcceptedID == acceptedID,
                      session.pendingHandoff.providerSwitchDelivery == .sending
                else { return }
                if attempt > 0 {
                    // Bounded and event-driven: the delay is only within this single flight and
                    // never parks a timer after persistent failure.
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
                    if Task.isCancelled { return }
                }
                guard let writer = self.providerSwitchConfirmationWriter(for: session) else {
                    lastFailure = true
                    continue
                }
                if !markerDurable {
                    let save = await scope.persistence.flushSaveRequired(writer: writer)
                    guard case .success = save else {
                        lastFailure = true
                        continue
                    }
                    if Task.isCancelled { return }
                    markerDurable = true
                }
                guard let payload = self.providerSwitchConfirmationPayload(
                    for: session, acceptedID: acceptedID
                ) else {
                    lastFailure = true
                    continue
                }
                let result = await scope.persistence.flushProviderSwitchProjectedSave(
                    payload: payload,
                    writer: writer,
                    canonicalItemCount: payload.effectiveCanonicalItemCount,
                    apply: { [weak self, weak session] receipt in
                        guard let self, let session,
                              scope.sessions[session.tabID] === session,
                              session.activeAgentSessionID == sessionID,
                              session.pendingHandoff.providerSwitchAcceptedID == acceptedID,
                              let transcript = receipt.payload.transcript
                        else { return false }
                        self.applyProviderSwitchConfirmationReceipt(receipt, to: session, transcript: transcript)
                        self.providerSwitchConfirmationSaveFailures.remove(sessionID)
                        return true
                    }
                )
                if case .success = result { return }
                lastFailure = true
            }
            guard scope.sessions[session.tabID] === session,
                  session.activeAgentSessionID == sessionID,
                  session.pendingHandoff.providerSwitchAcceptedID == acceptedID,
                  lastFailure
            else { return }
            self.providerSwitchConfirmationSaveFailures.insert(sessionID)
            session.providerSwitchConfirmationSaveFailed = true
            scope.noteSettlementChanged()
        }
        pendingSendEffects[flightID] = PendingSendEffect(
            sessionIdentity: ObjectIdentifier(session), task: task
        )
    }

    /// Finalizes an accepted marker through the same projected Save B as automatic confirmation.
    /// The safe Discard action therefore cannot expose a carrier-free live state to a concurrent
    /// save or provider ingress before its clear is durable.
    func providerSwitchDiscardAcceptedConfirmation(for session: TabSession) async -> Bool {
        guard let scope,
              scope.sessions[session.tabID] === session,
              session.providerSwitchConfirmationSaveFailed,
              let acceptedID = session.pendingHandoff.providerSwitchAcceptedID,
              let writer = providerSwitchConfirmationWriter(for: session),
              let payload = providerSwitchConfirmationPayload(for: session, acceptedID: acceptedID),
              let transcript = payload.transcript
        else { return false }
        let result = await scope.persistence.flushProviderSwitchProjectedSave(
            payload: payload,
            writer: writer,
            canonicalItemCount: payload.effectiveCanonicalItemCount,
            apply: { [weak self, weak session] receipt in
                guard let self, let session,
                      scope.sessions[session.tabID] === session,
                      session.pendingHandoff.providerSwitchAcceptedID == acceptedID,
                      receipt.payload.transcript != nil
                else { return false }
                self.applyProviderSwitchConfirmationReceipt(receipt, to: session, transcript: transcript)
                return true
            }
        )
        if case .success = result { return true }
        return false
    }

    func providerSwitchConfirmationWriter(
        for session: TabSession
    ) -> AgentSessionRuntimeStore.Writer? {
        guard let scope, let sessionID = session.activeAgentSessionID,
              case let .unique(writer) = scope.resolveWriter(sessionID: sessionID),
              writer.scope === scope, writer.session === session,
              writer.restoration == session.currentRestorationBindingToken,
              writer.isCurrent
        else { return nil }
        return writer
    }

    /// Builds the final value projection without touching the live carrier or transcript.
    func providerSwitchConfirmationPayload(
        for session: TabSession,
        acceptedID: UUID
    ) -> AgentSession? {
        guard let scope,
              let workspaceID = session.persistentSessionBindingIdentity?.workspaceID
        else { return nil }
        let snapshot = Self.providerSwitchConfirmationSnapshot(session)
        let composition = scope.persistence.composition
        var payload = AgentSessionPayloadBuilder.makePayload(
            session: session,
            sessionID: session.activeAgentSessionID ?? session.tabID,
            workspaceID: workspaceID,
            name: composition?.displayName(session.tabID) ?? AgentSessionRestoreSupport.normalizedSessionTitle(nil),
            snapshot: snapshot
        )
        let existingItems = payload.toLiveItems()
        let noticeText = "Handover sent to \(session.selectedAgent.displayName) / \(commands.modelDisplayName(session))."
        let notice = AgentChatItem(
            id: acceptedID,
            timestamp: Date(),
            kind: .system,
            text: noticeText,
            sequenceIndex: max((existingItems.map(\.sequenceIndex).max() ?? -1) + 1, session.nextSequenceIndex),
            recoveryDiagnostic: AgentTranscriptRecoveryDiagnostic(
                id: acceptedID,
                reason: "providerSwitch",
                outcome: "sent",
                text: noticeText
            )
        )
        var items = existingItems
        if !items.contains(where: { $0.id == acceptedID }) {
            items.append(notice)
        }
        payload = payload.withItems(items)
        payload.pendingHandoffProviderSwitchDelivery = nil
        payload.providerSwitchAcceptedID = nil
        payload.pendingHandoffPayload = nil
        payload.pendingHandoffCreatedAt = nil
        payload.pendingHandoffSourceItemID = nil
        payload.pendingHandoffDefersProviderLockUntilSend = false
        return payload
    }

    private func applyProviderSwitchConfirmationReceipt(
        _ receipt: AgentSessionSaveRuntime.Receipt,
        to session: TabSession,
        transcript: AgentTranscript
    ) {
        let sourceItems = receipt.payload.toLiveItems()
        session.setItemsSilently(sourceItems, reason: .persistedSessionHydration)
        _ = AgentSessionTranscriptRefreshRuntime.applyTranscriptPresentation(
            transcript, sourceItems: sourceItems, to: session
        )
        session.pendingHandoff.clearAfterSend()
        session.providerSwitchConfirmationSaveFailed = false
        session.isDirty = false
    }

    private static func providerSwitchConfirmationSnapshot(
        _ session: TabSession
    ) -> AgentPersistableTranscriptSnapshot {
        AgentSessionTranscriptRefreshRuntime.prepareSave(
            for: session,
            isActiveOwnedForSave: false,
            perfRecorder: NoopAgentModePerfRecorder(),
            diagnosticPresentationID: "provider-switch-confirmation"
        ).snapshot
    }
}
