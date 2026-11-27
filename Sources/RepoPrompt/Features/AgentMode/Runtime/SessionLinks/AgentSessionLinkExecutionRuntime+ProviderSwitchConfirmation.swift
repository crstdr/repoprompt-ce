import Foundation
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

@MainActor
extension AgentSessionLinkExecutionRuntime {
    /// Starts or coalesces the provider-free confirmation protocol. Triggers carry no evidence;
    /// the runtime record decides. Save A may run only for the originating writer, and Save B
    /// only for a durable marker whose carrying run is terminally resolved. Anything else leaves
    /// the live `.sending` marker untouched for a later event or the manual-review path.
    func providerSwitchReconcileConfirmation(for session: TabSession) {
        guard let scope,
              scope.sessions[session.tabID] === session,
              let acceptedID = session.pendingHandoff.providerSwitchAcceptedID,
              session.pendingHandoff.providerSwitchDelivery == .sending,
              let sessionID = session.activeAgentSessionID
        else { return }
        let flightKey = ProviderSwitchConfirmationKey(sessionID: sessionID, acceptedID: acceptedID)
        if providerSwitchConfirmationFlights[flightKey] != nil {
            // Coalesce: the active flight reconciles once more when it ends.
            providerSwitchConfirmationRerunRequested.insert(flightKey)
            return
        }
        // A trigger that cannot make progress must not reset an exposed save-failed state.
        guard providerSwitchConfirmationCanProgress(session, sessionID: sessionID, acceptedID: acceptedID) else {
            providerSwitchConfirmationExposeIfStranded(session, sessionID: sessionID, acceptedID: acceptedID)
            return
        }
        let flightID = UUID()
        providerSwitchConfirmationFlights[flightKey] = flightID
        session.providerSwitchConfirmationSaveFailed = false
        providerSwitchConfirmationSaveFailures.remove(sessionID)
        let task = Task { @MainActor [weak self, weak session, weak scope] in
            guard let self, let session, let scope else { return }
            defer {
                self.pendingSendEffects.removeValue(forKey: flightID)
                self.providerSwitchConfirmationFlightEnded(flightKey, flightID: flightID, session: session)
                scope.noteSettlementChanged()
            }
            var lastFailure = false
            for attempt in 0 ..< 3 {
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
                guard let writer = providerSwitchConfirmationWriter(for: session) else {
                    lastFailure = true
                    continue
                }
                guard let record = providerSwitchConfirmationRecords[sessionID],
                      record.acceptedID == acceptedID
                else { return }
                if !record.markerDurable {
                    // Only the originating writer may record a late provider acceptance. A
                    // successor waits for durable evidence instead of inferring acceptance.
                    guard let origin = record.originWriter, writer.identity == origin else {
                        if !providerSwitchConfirmationRerunRequested.contains(flightKey) {
                            providerSwitchConfirmationExposeIfStranded(session, sessionID: sessionID, acceptedID: acceptedID)
                        }
                        return
                    }
                    let save = await scope.persistence.flushSaveRequired(writer: writer)
                    guard case .success = save else {
                        lastFailure = true
                        continue
                    }
                    if Task.isCancelled { return }
                    providerSwitchNoteDurableMarker(sessionID: sessionID, acceptedID: acceptedID)
                }
                guard let settled = providerSwitchConfirmationRecords[sessionID],
                      settled.acceptedID == acceptedID, settled.markerDurable, settled.terminalResolved
                else { return }
                guard let payload = providerSwitchConfirmationPayload(
                    for: session, acceptedID: acceptedID
                ) else {
                    lastFailure = true
                    continue
                }
                let result = await scope.persistence.flushProviderSwitchProjectedSave(
                    payload: payload,
                    writer: writer,
                    canonicalItemCount: payload.effectiveCanonicalItemCount,
                    rebuildPayload: { self.providerSwitchConfirmationPayload(for: session, acceptedID: acceptedID) },
                    apply: { [weak self, weak session] receipt in
                        guard let self, let session,
                              scope.sessions[session.tabID] === session,
                              session.activeAgentSessionID == sessionID,
                              session.pendingHandoff.providerSwitchAcceptedID == acceptedID,
                              let transcript = receipt.payload.transcript
                        else { return false }
                        applyProviderSwitchConfirmationReceipt(receipt, to: session, transcript: transcript)
                        providerSwitchConfirmationSaveFailures.remove(sessionID)
                        return true
                    }
                )
                if case .success = result { return }
                if Task.isCancelled { return }
                lastFailure = true
            }
            // A coalesced trigger gets its rerun first; only a flight with nothing pending may
            // expose save failure.
            guard scope.sessions[session.tabID] === session,
                  session.activeAgentSessionID == sessionID,
                  session.pendingHandoff.providerSwitchAcceptedID == acceptedID,
                  lastFailure,
                  !providerSwitchConfirmationRerunRequested.contains(flightKey)
            else { return }
            providerSwitchConfirmationSaveFailures.insert(sessionID)
            session.providerSwitchConfirmationSaveFailed = true
            scope.noteSettlementChanged()
        }
        pendingSendEffects[flightID] = PendingSendEffect(
            sessionIdentity: ObjectIdentifier(session), task: task
        )
    }

    /// Releases a flight key and runs at most one reconciliation for triggers coalesced into it.
    /// The rerun passes the normal fences and single-flight admission.
    private func providerSwitchConfirmationFlightEnded(
        _ flightKey: ProviderSwitchConfirmationKey, flightID: UUID, session: TabSession
    ) {
        guard providerSwitchConfirmationFlights[flightKey] == flightID else { return }
        providerSwitchConfirmationFlights.removeValue(forKey: flightKey)
        guard providerSwitchConfirmationRerunRequested.remove(flightKey) != nil else { return }
        providerSwitchReconcileConfirmation(for: session)
    }

    /// Whether a new flight could perform Save A or Save B from the current record evidence.
    private func providerSwitchConfirmationCanProgress(
        _ session: TabSession, sessionID: UUID, acceptedID: UUID
    ) -> Bool {
        guard let record = providerSwitchConfirmationRecords[sessionID],
              record.acceptedID == acceptedID
        else { return false }
        if record.markerDurable { return record.terminalResolved }
        guard let origin = record.originWriter else { return false }
        return providerSwitchConfirmationWriter(for: session)?.identity == origin
    }

    /// After its run has ended, an accepted marker that is not durable and whose originating
    /// writer is gone cannot be saved or finished by anyone (a successor never records Save A).
    /// Expose the existing save-failed state so the banner offers Discard rather than an endless
    /// progress state. Later durable evidence still wakes reconciliation and clears it.
    private func providerSwitchConfirmationExposeIfStranded(
        _ session: TabSession, sessionID: UUID, acceptedID: UUID
    ) {
        guard let record = providerSwitchConfirmationRecords[sessionID],
              record.acceptedID == acceptedID, record.terminalResolved, !record.markerDurable,
              !session.providerSwitchConfirmationSaveFailed
        else { return }
        providerSwitchConfirmationSaveFailures.insert(sessionID)
        session.providerSwitchConfirmationSaveFailed = true
        scope?.noteSettlementChanged()
    }

    private func providerSwitchNoteDurableMarker(sessionID: UUID, acceptedID: UUID) {
        guard var record = providerSwitchConfirmationRecords[sessionID],
              record.acceptedID == acceptedID, !record.markerDurable
        else { return }
        record.markerDurable = true
        providerSwitchConfirmationRecords[sessionID] = record
    }

    /// Ordinary save settlement. A committed receipt whose payload carries the live accepted ID
    /// is durable-marker evidence for any same-session writer; it then wakes reconciliation, as
    /// does any settlement while the confirmation is exposed as save-failed.
    func providerSwitchConfirmationSaveSettled(
        _ session: TabSession, sessionID: UUID, committedAcceptedID: UUID?
    ) {
        guard let scope, scope.sessions[session.tabID] === session,
              session.activeAgentSessionID == sessionID,
              let acceptedID = session.pendingHandoff.providerSwitchAcceptedID,
              session.pendingHandoff.providerSwitchDelivery == .sending
        else { return }
        let wasDurable = providerSwitchConfirmationRecords[sessionID]?.markerDurable == true
        if committedAcceptedID == acceptedID {
            providerSwitchNoteDurableMarker(sessionID: sessionID, acceptedID: acceptedID)
        }
        let becameDurable = !wasDurable && providerSwitchConfirmationRecords[sessionID]?.markerDurable == true
        if becameDurable || session.providerSwitchConfirmationSaveFailed {
            providerSwitchReconcileConfirmation(for: session)
        }
    }

    /// A hydrated payload carrying the accepted ID is durable evidence, and no run from before
    /// the restart can still carry the handover, so hydration reconciles straight to Save B.
    func providerSwitchConfirmationHydrated(_ session: TabSession, acceptedID: UUID) {
        guard let scope, scope.sessions[session.tabID] === session,
              let sessionID = session.activeAgentSessionID,
              session.pendingHandoff.providerSwitchAcceptedID == acceptedID,
              session.pendingHandoff.providerSwitchDelivery == .sending
        else { return }
        providerSwitchConfirmationRecords[sessionID] = .init(
            acceptedID: acceptedID,
            binding: session.currentRestorationBindingToken,
            runOwnership: nil,
            runID: nil,
            originWriter: nil,
            terminalResolved: true,
            markerDurable: true
        )
        providerSwitchReconcileConfirmation(for: session)
    }

    /// Finalizes an accepted marker through the same projected Save B as automatic confirmation.
    /// The safe Discard action therefore cannot expose a carrier-free live state to a concurrent
    /// save or provider ingress before its clear is durable.
    func providerSwitchDiscardAcceptedConfirmation(for session: TabSession) async -> Bool {
        guard let scope,
              scope.sessions[session.tabID] === session,
              session.providerSwitchConfirmationSaveFailed,
              let acceptedID = session.pendingHandoff.providerSwitchAcceptedID,
              let sessionID = session.activeAgentSessionID,
              providerSwitchConfirmationFlights[ProviderSwitchConfirmationKey(sessionID: sessionID, acceptedID: acceptedID)] == nil,
              providerSwitchConfirmationRecords[sessionID]?.terminalResolved != false,
              let writer = providerSwitchConfirmationWriter(for: session),
              let payload = providerSwitchConfirmationPayload(for: session, acceptedID: acceptedID, includeNotice: false),
              payload.transcript != nil
        else { return false }
        let discardFlightID = UUID()
        let discardFlightKey = ProviderSwitchConfirmationKey(sessionID: sessionID, acceptedID: acceptedID)
        providerSwitchConfirmationFlights[discardFlightKey] = discardFlightID
        defer { providerSwitchConfirmationFlightEnded(discardFlightKey, flightID: discardFlightID, session: session) }
        let result = await scope.persistence.flushProviderSwitchProjectedSave(
            payload: payload,
            writer: writer,
            canonicalItemCount: payload.effectiveCanonicalItemCount,
            rebuildPayload: { self.providerSwitchConfirmationPayload(for: session, acceptedID: acceptedID, includeNotice: false) },
            apply: { [weak self, weak session] receipt in
                guard let self, let session,
                      scope.sessions[session.tabID] === session,
                      session.pendingHandoff.providerSwitchAcceptedID == acceptedID,
                      let finalTranscript = receipt.payload.transcript
                else { return false }
                applyProviderSwitchConfirmationReceipt(receipt, to: session, transcript: finalTranscript)
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
        acceptedID: UUID,
        includeNotice: Bool = true
    ) -> AgentSession? {
        guard let scope,
              let workspaceID = session.persistentSessionBindingIdentity?.workspaceID
        else { return nil }
        let prepared = Self.providerSwitchConfirmationSnapshot(session)
        let composition = scope.persistence.composition
        func makePayload(_ snapshot: AgentPersistableTranscriptSnapshot) -> AgentSession {
            AgentSessionPayloadBuilder.makePayload(
                session: session,
                sessionID: session.activeAgentSessionID ?? session.tabID,
                workspaceID: workspaceID,
                name: composition?.displayName(session.tabID) ?? AgentSessionRestoreSupport.normalizedSessionTitle(nil),
                snapshot: snapshot
            )
        }
        var payload = makePayload(prepared)
        if includeNotice {
            // Look the notice up in stored activities, not rendered rows: grouped history can hide
            // a stored row from the rendered list. Nothing here is re-imported as a live row.
            let storedActivities = prepared.transcript.turns.flatMap(\.allActivities)
            let storedSequenceEnd = (storedActivities.map(\.sequenceIndex).max() ?? -1) + 1
            let noticeText = "Handover sent to \(session.selectedAgent.displayName) / \(commands.modelDisplayName(session))."
            let notice = AgentChatItem(
                id: acceptedID,
                timestamp: Date(),
                kind: .system,
                text: noticeText,
                sequenceIndex: max(storedSequenceEnd, prepared.transcript.nextSequenceIndex, session.nextSequenceIndex),
                recoveryDiagnostic: AgentTranscriptRecoveryDiagnostic(
                    id: acceptedID,
                    reason: "providerSwitch",
                    outcome: "sent",
                    text: noticeText
                )
            )
            if let existing = storedActivities.first(where: { $0.id == acceptedID }) {
                guard existing.recoveryDiagnostic?.id == acceptedID,
                      existing.recoveryDiagnostic?.reason == "providerSwitch",
                      existing.recoveryDiagnostic?.outcome == "sent"
                else { return nil }
            } else {
                let summaryIDs = payload.transcript?.turns.flatMap { turn in
                    turn.summary?.recoveryDiagnostics ?? []
                } ?? []
                if let summary = summaryIDs.first(where: { $0.id == acceptedID }) {
                    guard summary.reason == "providerSwitch", summary.outcome == "sent" else { return nil }
                } else {
                    payload = makePayload(Self.providerSwitchConfirmationSnapshot(prepared, appending: notice, for: session))
                }
            }
        }
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
        // Install only full-detail working rows, as hydration does. Archived rows installed as live
        // sources would be re-imported as new turns on the next rebuild, duplicating history.
        let previousNextSequenceIndex = session.nextSequenceIndex
        session.setItemsSilently(
            AgentTranscriptIO.workingSourceItems(from: transcript), reason: .persistedSessionHydration
        )
        // Present the rows as installed: the setter may normalize them.
        _ = AgentSessionTranscriptRefreshRuntime.applyTranscriptPresentation(
            transcript, sourceItems: session.items, to: session
        )
        session.nextSequenceIndex = max(previousNextSequenceIndex, transcript.nextSequenceIndex)
        session.pendingHandoff.clearAfterSend()
        session.providerSwitchConfirmationSaveFailed = false
        session.isDirty = false
    }

    /// The prepared snapshot with the confirmation notice appended to its working tail, built the
    /// way an ordinary save of "working rows + notice" would be: compacted turns and the
    /// compaction frontier are preserved as they are.
    private static func providerSwitchConfirmationSnapshot(
        _ base: AgentPersistableTranscriptSnapshot,
        appending notice: AgentChatItem,
        for session: TabSession
    ) -> AgentPersistableTranscriptSnapshot {
        AgentSessionTranscriptRefreshRuntime.persistableTranscriptSnapshot(
            for: session,
            workingItems: AgentTranscriptIO.workingSourceItems(from: base.transcript) + [notice],
            existingTranscript: base.transcript,
            importPolicy: .liveSession(hidePendingQuestionToolCall: session.hasPendingQuestionUI),
            projectionProtection: AgentSessionTranscriptRefreshRuntime.transcriptProjectionProtection(
                for: session, transcript: base.transcript
            ),
            nextSequenceIndex: max(notice.sequenceIndex + 1, base.transcript.nextSequenceIndex, session.nextSequenceIndex)
        )
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
