import Foundation

// MARK: - Attempt state

/// The single automatic lane-update follow-up one exact observer incarnation may reserve.
///
/// Deliberately tiny. It stores an identity, a position in the queue, a phase, and a cancellable
/// task — never entries, previews, or overflow details. The bridge-owned reducer stays the only
/// authority on what the turn will actually say, so a scheduled wake can never ship a stale payload
/// it captured at scheduling time.
enum AgentSessionLinkPhysicalDispatchOutcome: Equatable {
    /// The dispatch was retracted before its provider transport boundary.
    case notAttempted
    /// The provider's existing acceptance signal settled the claim.
    case accepted
    /// The physical call began, but no definitive acceptance or rejection was observed.
    case ambiguous
}

struct AgentSessionLinkAutoWakeAttempt {
    enum Phase: Equatable {
        /// Gates passed; waiting for the observer to become dispatchable.
        case scheduled
        /// Parked behind an active run, a terminal commit, or an accepted successor.
        case awaitingSettlement
        /// The coordinator is preparing provider input, but no physical call is owned yet.
        case preparingDispatch
        /// Preparation lost ownership; retained only to make every late provider seam fail closed.
        case cancelledBeforeDispatch
        /// The provider call may be in flight. A local user send no longer cancels it.
        case dispatching
    }

    let wakeID: UUID
    let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    let queueEpoch: UUID
    /// Local-input ownership observed when this wake was reserved.
    let localInputEpoch: UInt64
    /// High-water mark, not a snapshot: newer revisions raise it rather than starting a second
    /// attempt.
    var queueRevision: UInt64
    /// The newest structural shape known to the reservation.
    var wakeFingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint
    /// Frozen only at the physical boundary, so a later edge can never be suppressed as though it
    /// had been included in already-immutable provider text.
    var attemptedFingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?
    /// Fresh target-local epochs represented by this accepted wake, consumed atomically on acceptance.
    var humanRearmEpochs: [DomainAgentSessionLinkReference: UInt64]
    var physicalOutcome: AgentSessionLinkPhysicalDispatchOutcome
    var phase: Phase
    var task: Task<Void, Never>?
}

/// Why an unaccepted attempt was released.
enum AgentSessionLinkAutoWakeCancellationReason: String {
    case settingDisabled = "setting_disabled"
    case endpointInvalidated = "endpoint_invalidated"
    case queueCleared = "queue_cleared"
    case naturalDeliveryWon = "natural_delivery_won"
    case localUserWon = "local_user_won"
    case eligibilityLost = "eligibility_lost"
    case shutdown
    /// The required lane claim disappeared before any provider call could begin.
    case requiredClaimUnavailable = "required_claim_unavailable"

    /// Whether this reason definitively proves that no physical provider call occurred.
    ///
    /// Queue changes do not prove that once dispatch ownership has been acquired: a natural receipt,
    /// unlink, or transient publication can race a suspended provider call. Only the dispatch path's
    /// own pre-call refusal or definitive return may release that identity.
    var definitivelyNoPhysicalCall: Bool {
        switch self {
        case .requiredClaimUnavailable: true
        default: false
        }
    }
}

// MARK: - Coordinator

@MainActor
extension AgentModeViewModel {
    /// Endpoint-addressed scheduling hint, driven by every authoritative queue publication.
    ///
    /// There is no timer and no event bus: a dropped publication is recovered by the next complete
    /// projection refresh, which is the same invariant that lets the reducer skip polling.
    func agentSessionLinkNoteAutoWakeOpportunity(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint) else { return }

        // Baselined ahead of the deliverability guard, because the publication that *activates* a lane
        // carries no entries yet. Seeding the watermark from a lane's first update instead would
        // consume the very epoch that update was caused by, so the first direct human turn in a
        // freshly linked or freshly selected target could never re-arm the observer.
        agentSessionLinkReconcileAutoWakeLaneBaselines(snapshot, session: session)

        // Content gone: a natural turn claimed it, or membership moved. Release the reservation
        // without a transcript row — nothing was ever delivered under this wake's name.
        guard snapshot.isDeliverable, snapshot.hasDeliverableContent else {
            // Once content is acknowledged or removed, an old failure must not suppress a later
            // independent edge with the same shape. A dispatching attempt retains its identity until
            // its own physical outcome settles; `cancel` deliberately refuses this queue-side race.
            session.suppressedOversightWakeFingerprint = nil
            cancelAgentSessionLinkAutoWake(for: endpoint, reason: .naturalDeliveryWon)
            return
        }

        let fingerprint = snapshot.wakeEligibilityFingerprint
        let selectedLanes = agentSessionLinkLiveSelectedAutoWakeLanes(snapshot, session: session)
        let representedSelectedEntries = snapshot.entries.filter { selectedLanes[$0.reference] != nil }
        let freshHumanEpochs: [DomainAgentSessionLinkReference: UInt64] = representedSelectedEntries
            .reduce(into: [:]) { epochs, entry in
                guard let lane = selectedLanes[entry.reference],
                      lane.targetTurnIsLocalUser,
                      lane.targetLocalInputEpoch
                      > (session.agentSessionLinkConsumedTargetLocalEpochs[entry.reference] ?? 0)
                else { return }
                epochs[entry.reference] = lane.targetLocalInputEpoch
            }

        // One attempt absorbs newer revisions. A metadata-only revision deliberately does not clear a
        // failed attempt's suppression, so improving payload fidelity cannot re-trigger a provider
        // that already refused.
        if var attempt = session.pendingOversightAutoWake {
            guard attempt.observerEndpoint == endpoint, attempt.queueEpoch == snapshot.queueEpoch else {
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .endpointInvalidated)
                return
            }
            attempt.queueRevision = max(attempt.queueRevision, snapshot.queueRevision)
            attempt.wakeFingerprint = fingerprint
            for (reference, epoch) in freshHumanEpochs {
                attempt.humanRearmEpochs[reference] = max(attempt.humanRearmEpochs[reference] ?? 0, epoch)
            }
            session.pendingOversightAutoWake = attempt
            agentSessionLinkScheduleAutoWakeReevaluation(wakeID: attempt.wakeID, endpoint: endpoint)
            agentSessionLinkLogAutoWakeGate(endpoint, fingerprint, "absorbed")
            return
        }

        guard !representedSelectedEntries.isEmpty
            || agentSessionLinkOverflowAloneMayWake(snapshot, selectedLanes: selectedLanes)
        else { return }
        if session.agentSessionLinkTurnOrigin.requiresNewLocalUserInstruction, freshHumanEpochs.isEmpty {
            agentSessionLinkLogAutoWakeGate(endpoint, fingerprint, "blocked.turnOrigin")
            return
        }
        guard session.suppressedOversightWakeFingerprint != fingerprint else {
            agentSessionLinkLogAutoWakeGate(endpoint, fingerprint, "suppressed")
            return
        }
        guard agentSessionLinkPromptContext(for: session)?.epoch.allowsSupplement == true else {
            agentSessionLinkLogAutoWakeGate(endpoint, fingerprint, "blocked.ineligible")
            return
        }

        let attempt = AgentSessionLinkAutoWakeAttempt(
            wakeID: UUID(),
            observerEndpoint: endpoint,
            queueEpoch: snapshot.queueEpoch,
            localInputEpoch: session.agentSessionLinkLocalInputEpoch,
            queueRevision: snapshot.queueRevision,
            wakeFingerprint: fingerprint,
            attemptedFingerprint: nil,
            humanRearmEpochs: freshHumanEpochs,
            physicalOutcome: .notAttempted,
            phase: .scheduled,
            task: nil
        )
        session.pendingOversightAutoWake = attempt
        agentSessionLinkScheduleAutoWakeReevaluation(wakeID: attempt.wakeID, endpoint: endpoint)
        agentSessionLinkLogAutoWakeGate(endpoint, fingerprint, "scheduled")
    }

    /// Releases an unaccepted attempt. Never retracts a provider call that may already be in flight.
    func cancelAgentSessionLinkAutoWake(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        reason: AgentSessionLinkAutoWakeCancellationReason
    ) {
        guard let session = sessions[endpoint.tabID],
              let attempt = session.pendingOversightAutoWake,
              attempt.observerEndpoint == endpoint
        else {
            return
        }
        // Past the ownership boundary the physical call may already have happened, so an "ambiguous
        // cancellation" would be a lie in both directions. Let it settle instead — unless this is one
        // of the coordinator's own pre-dispatch decisions, which provably retracts nothing.
        guard attempt.phase != .dispatching || reason.definitivelyNoPhysicalCall else { return }
        if attempt.phase == .preparingDispatch, !reason.definitivelyNoPhysicalCall {
            // Preparation owns the only finalizer that can prove the transport was never called.
            // Mark cancellation intent, but do not cancel that finalizer out from under the attempt.
            var cancelledAttempt = attempt
            cancelledAttempt.phase = .cancelledBeforeDispatch
            session.pendingOversightAutoWake = cancelledAttempt
            agentSessionLinkLogAutoWakeGate(
                endpoint,
                attempt.wakeFingerprint,
                "cancelled.preDispatch.\(reason.rawValue)"
            )
            return
        }
        attempt.task?.cancel()
        session.pendingOversightAutoWake = nil
        agentSessionLinkLogAutoWakeGate(endpoint, attempt.wakeFingerprint, "cancelled.\(reason.rawValue)")
    }

    /// Clears suppression so an explicit off/on cycle can retry a known failure.
    ///
    /// It cannot bypass the turn-origin guard: only accepted local-user input re-arms that.
    func agentSessionLinkClearAutoWakeSuppression(for endpoint: DomainAgentSessionLinkEndpointIdentity) {
        sessions[endpoint.tabID]?.suppressedOversightWakeFingerprint = nil
    }

    // MARK: Dispatch

    private func agentSessionLinkScheduleAutoWakeReevaluation(
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint),
              var attempt = session.pendingOversightAutoWake,
              attempt.wakeID == wakeID,
              attempt.phase == .scheduled || attempt.phase == .awaitingSettlement,
              attempt.task == nil
        else {
            return
        }
        attempt.task = Task { @MainActor [weak self] in
            await self?.agentSessionLinkRunAutoWake(wakeID: wakeID, endpoint: endpoint)
        }
        session.pendingOversightAutoWake = attempt
    }

    private func agentSessionLinkRunAutoWake(
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) async {
        while !Task.isCancelled {
            guard let session = agentSessionLinkAutoWakeSession(for: endpoint),
                  let attempt = session.pendingOversightAutoWake,
                  attempt.wakeID == wakeID
            else {
                return
            }
            guard agentSessionLinkAutoWakeAttemptIsStillEligible(attempt, session: session) else {
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
                return
            }

            guard let route = agentSessionLinkAutoWakeRoute(session) else {
                guard agentSessionLinkAutoWakeMayStillSettle(session) else {
                    cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
                    return
                }
                agentSessionLinkSetAutoWakePhase(.awaitingSettlement, wakeID: wakeID, endpoint: endpoint)
                // One owned task subscribes to the next readiness event and is cancelled with the
                // attempt. There is no yield loop, timer, or second queue authority.
                for await _ in session.monitorReadinessChangePublisher.values {
                    break
                }
                continue
            }

            let dispatchID = AgentSessionLinkPromptDispatchID.autoWake(
                wakeID: wakeID,
                localInputEpoch: attempt.localInputEpoch
            )
            if route == .waitingContinuation, session.selectedAgent == .codexExec {
                let expectedWaitID = session.instructionWaitID
                let expectedControllerID = session.codexController.map(ObjectIdentifier.init)
                let readiness = await ensureProviderInputCatalogReady(for: session)
                guard readiness == .ready || readiness == .notRequired,
                      let current = agentSessionLinkAutoWakeSession(for: endpoint),
                      current === session,
                      current.pendingOversightAutoWake?.wakeID == wakeID,
                      current.instructionWaitID == expectedWaitID,
                      current.codexController.map(ObjectIdentifier.init) == expectedControllerID,
                      agentSessionLinkAutoWakeRoute(current) == .waitingContinuation
                else {
                    agentSessionLinkRecordPhysicalDispatchNotAttempted(for: session, dispatchID: dispatchID)
                    return
                }
            }
            // Reserve the exact rendered lane batch before provider preparation. Budget omission,
            // receipt competition, revocation, and membership drift therefore remain definite
            // no-call outcomes.
            let monitoring = agentSessionLinkDecoratedProviderText(
                "",
                session: session,
                dispatchID: dispatchID
            )
            guard !monitoring.mustAbortDispatch, let reservedClaim = monitoring.claim else {
                agentSessionLinkRecordPhysicalDispatchNotAttempted(for: session, dispatchID: dispatchID)
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .requiredClaimUnavailable)
                return
            }

            agentSessionLinkPrepareAutoWakeDispatch(wakeID: wakeID, endpoint: endpoint)
            switch route {
            case .idleFollowUp:
                let startOutcome = await startAgentRun(
                    tabID: endpoint.tabID,
                    initialMessage: "",
                    directStartOptions: .laneUpdate(wakeID: wakeID)
                )
                if case .some(.queuedFallback) = startOutcome {
                    // Codex owns a durable queued submission. Keep the wake identity attached until
                    // that queue reaches its physical boundary and reports acceptance or ambiguity.
                    if var queuedAttempt = session.pendingOversightAutoWake,
                       queuedAttempt.wakeID == wakeID
                    {
                        queuedAttempt.task = nil
                        session.pendingOversightAutoWake = queuedAttempt
                    }
                    return
                }
            case .waitingContinuation:
                agentSessionLinkResumeWaitingContinuationForAutoWake(
                    claim: reservedClaim,
                    wakeID: wakeID,
                    endpoint: endpoint
                )
            }

            await agentSessionLinkAwaitPhysicalDispatchSettlement(
                wakeID: wakeID,
                endpoint: endpoint
            )
            return
        }
    }

    /// Acquires the actual transport boundary for an auto-wake. Ordinary dispatches pass through.
    /// Providers call this after final prompt composition and immediately before their physical call.
    @discardableResult
    func agentSessionLinkAcquirePhysicalDispatch(
        for session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) -> Bool {
        let effectiveID = agentSessionLinkEffectiveDispatchID(for: session, dispatchID: dispatchID)
        guard let wakeID = effectiveID.autoWakeID else { return true }
        guard var attempt = session.pendingOversightAutoWake,
              attempt.wakeID == wakeID,
              attempt.localInputEpoch == effectiveID.autoWakeLocalInputEpoch
        else { return false }
        if attempt.phase == .cancelledBeforeDispatch {
            attempt.task?.cancel()
            session.pendingOversightAutoWake = nil
            return false
        }
        guard attempt.phase == .preparingDispatch || attempt.phase == .dispatching else {
            return false
        }
        if attempt.phase != .dispatching {
            // The acceptance fence, evaluated exactly once and only on this side of the transport
            // boundary. A re-entrant acquire for an attempt that is already `dispatching` must not
            // consult it: the physical call may already have happened, so retracting the identity
            // here would report "no call" for a turn the provider is running.
            guard agentSessionLinkAutoWakeAttemptIsStillEligible(attempt, session: session) else {
                attempt.task?.cancel()
                session.pendingOversightAutoWake = nil
                return false
            }
            attempt.phase = .dispatching
            attempt.attemptedFingerprint = attempt.wakeFingerprint
            attempt.physicalOutcome = .ambiguous
            session.pendingOversightAutoWake = attempt
            session.monitorObservationSignal.send(())
            agentSessionLinkLogAutoWakeGate(
                attempt.observerEndpoint,
                attempt.attemptedFingerprint,
                "dispatching"
            )
        }
        return true
    }

    /// Settles a prepared wake when the provider path definitively exits before its transport call.
    ///
    /// Idempotent by wake identity. It installs neither failure suppression nor anti-chain origin,
    /// because the provider received nothing and the lane batch remains owed.
    func agentSessionLinkRecordPhysicalDispatchNotAttempted(
        for session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) {
        let effectiveID = agentSessionLinkEffectiveDispatchID(for: session, dispatchID: dispatchID)
        guard let wakeID = effectiveID.autoWakeID,
              let attempt = session.pendingOversightAutoWake,
              attempt.wakeID == wakeID,
              attempt.localInputEpoch == effectiveID.autoWakeLocalInputEpoch,
              attempt.phase != .dispatching,
              attempt.physicalOutcome == .notAttempted
        else {
            return
        }
        attempt.task?.cancel()
        session.pendingOversightAutoWake = nil
        session.monitorObservationSignal.send(())
        requestUIRefresh(tabID: session.tabID)
        agentSessionLinkLogAutoWakeGate(
            attempt.observerEndpoint,
            attempt.wakeFingerprint,
            "settled.notAttempted"
        )
    }

    func agentSessionLinkRecordPhysicalDispatchFailure(
        for session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) {
        let effectiveID = agentSessionLinkEffectiveDispatchID(for: session, dispatchID: dispatchID)
        guard let wakeID = effectiveID.autoWakeID,
              let attempt = session.pendingOversightAutoWake,
              attempt.wakeID == wakeID,
              attempt.physicalOutcome == .ambiguous
        else {
            return
        }
        agentSessionLinkSettleAmbiguousAutoWake(attempt, session: session)
    }

    private func agentSessionLinkPrepareAutoWakeDispatch(
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = sessions[endpoint.tabID],
              var attempt = session.pendingOversightAutoWake,
              attempt.wakeID == wakeID
        else { return }
        attempt.phase = .preparingDispatch
        attempt.attemptedFingerprint = nil
        attempt.physicalOutcome = .notAttempted
        session.pendingOversightAutoWake = attempt
    }

    private func agentSessionLinkAwaitPhysicalDispatchSettlement(
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) async {
        // This is the sole preparation finalizer. It must observe cancellation intent even when its
        // task was cancelled by an older caller, so termination is driven by explicit settlement.
        while true {
            guard let session = agentSessionLinkAutoWakeSession(for: endpoint),
                  let attempt = session.pendingOversightAutoWake,
                  attempt.wakeID == wakeID
            else { return }

            if attempt.phase == .cancelledBeforeDispatch {
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .requiredClaimUnavailable)
                return
            }
            switch attempt.physicalOutcome {
            case .accepted:
                return
            case .notAttempted where !session.runState.isActive:
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .requiredClaimUnavailable)
                return
            case .ambiguous where !session.runState.isActive:
                agentSessionLinkSettleAmbiguousAutoWake(attempt, session: session)
                return
            case .notAttempted, .ambiguous:
                // The run still owns preparation/call settlement. Await the next readiness or
                // physical-boundary publication; cancellation tears down this exact subscription.
                for await _ in session.monitorReadinessChangePublisher.values {
                    break
                }
            }
        }
    }

    private func agentSessionLinkSettleAmbiguousAutoWake(
        _ attempt: AgentSessionLinkAutoWakeAttempt,
        session: TabSession
    ) {
        attempt.task?.cancel()
        session.pendingOversightAutoWake = nil
        session.suppressedOversightWakeFingerprint = attempt.attemptedFingerprint
        // The provider may have accepted the turn. Preserve the anti-chain unless a newer local
        // instruction already owns the session; the lane receipt intentionally remains owed.
        if session.agentSessionLinkLocalInputEpoch == attempt.localInputEpoch {
            session.agentSessionLinkTurnOrigin = .laneUpdateAutoWake(wakeID: attempt.wakeID)
            session.isDirty = true
            scheduleSave(for: session.tabID)
        }
        agentSessionLinkLogAutoWakeGate(
            attempt.observerEndpoint,
            attempt.attemptedFingerprint,
            "settled.ambiguous"
        )
    }

    /// Records one physically accepted auto-wake, in the order the plan requires.
    ///
    /// Called from the shared claim-acceptance path, so every provider family reaches it through the
    /// physical-acceptance signal it already reports and no acceptance boundary moves earlier.
    ///
    /// The wake is identified by the **claim**, not by whatever the session happens to hold when the
    /// provider signals. `dispatchID` was stamped `lane.autowake:<wakeID>` when the claim was
    /// reserved, so a late acceptance from a superseded wake cannot settle the current one, and an
    /// ordinary turn that merely happened to carry a lane batch is not a wake at all.
    func agentSessionLinkRecordAcceptedAutoWake(
        _ claim: AgentSessionLinkOutboundPromptClaim,
        acceptedAt: Date = Date()
    ) {
        guard let wakeID = claim.dispatchID.autoWakeID,
              let localInputEpoch = claim.dispatchID.autoWakeLocalInputEpoch,
              let endpoint = claim.passive?.observerEndpoint,
              let session = sessions[endpoint.tabID],
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              !session.items.contains(where: { $0.id == wakeID })
        else {
            return
        }
        let acceptedAttempt = session.pendingOversightAutoWake.flatMap { attempt in
            attempt.wakeID == wakeID ? attempt : nil
        }
        if var acceptedAttempt {
            acceptedAttempt.physicalOutcome = .accepted
            acceptedAttempt.task?.cancel()
            session.pendingOversightAutoWake = nil
        }
        // Receipt/provenance remains truthful even when the user won meanwhile, but only a callback
        // from the current local-input epoch may claim turn origin.
        if session.agentSessionLinkLocalInputEpoch == localInputEpoch {
            session.agentSessionLinkTurnOrigin = .laneUpdateAutoWake(wakeID: wakeID)
        }
        session.suppressedOversightWakeFingerprint = nil
        for (reference, epoch) in acceptedAttempt?.humanRearmEpochs ?? [:] {
            session.agentSessionLinkConsumedTargetLocalEpochs[reference] = max(
                session.agentSessionLinkConsumedTargetLocalEpochs[reference] ?? 0,
                epoch
            )
        }
        agentSessionLinkClearWaitingOnAfterAcceptedTurn(session)
        session.appendItem(AgentChatItem.laneUpdateAutoWake(
            wakeID: wakeID,
            acceptedAt: acceptedAt,
            sequenceIndex: session.nextSequenceIndex
        ))
        session.isDirty = true
        requestUIRefresh(tabID: endpoint.tabID)
        scheduleSave(for: endpoint.tabID)
    }

    /// Delivers one lane update into an already-waiting run's one-shot instruction continuation.
    ///
    /// The cheaper of the two routes and the correct one here: the run is already in flight and is
    /// asking what to do next, so starting a second run alongside it would be both wasteful and a
    /// race. Successful `resume(returning:)` is the physical acceptance boundary, exactly as it is
    /// for an ordinary instruction — no new acceptance point is introduced.
    ///
    /// It resumes with a lane origin and no user text, so nothing downstream can mistake it for the
    /// user's answer: no `.user` row, no `lastUserMessageAt` move, no handoff consumption.
    private func agentSessionLinkResumeWaitingContinuationForAutoWake(
        claim: AgentSessionLinkOutboundPromptClaim,
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint),
              session.pendingOversightAutoWake?.wakeID == wakeID,
              agentSessionLinkAutoWakeRoute(session) == .waitingContinuation
        else {
            return
        }
        guard agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: claim.dispatchID) else {
            return
        }
        _ = resumeWaitingInstructionContinuation(
            session: session,
            providerText: claim.fragment,
            claim: claim,
            origin: .laneUpdateAutoWake(wakeID: wakeID)
        )
    }

    // MARK: Gates

    private func agentSessionLinkAutoWakeSession(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> TabSession? {
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              let session = sessions[endpoint.tabID]
        else {
            return nil
        }
        return session
    }

    /// The two routes a wake may take, or `nil` while the observer is not dispatchable at all.
    enum AutoWakeRoute: Equatable {
        /// Fully idle: start one typed system-origin follow-up run.
        case idleFollowUp
        /// Waiting for its own user's next instruction: resume that one-shot continuation instead of
        /// starting a second run alongside it.
        case waitingContinuation
    }

    /// Which route, if any, this observer can take right now.
    ///
    /// Deliberately one function for both, so "is it safe to wake?" and "how would we wake?" cannot
    /// drift. A pending approval, question, input request, permission prompt, or review is never a
    /// route: answering one is a different capability than delivering an update, and lane data is
    /// never an interaction response.
    private func agentSessionLinkAutoWakeRoute(_ session: TabSession) -> AutoWakeRoute? {
        guard agentSessionLinkAutoWakeIsUnblocked(session) else { return nil }
        // `waitingPrompt`/`instructionContinuation` is ordinary "what next?" state, which the shared
        // blocker set above has already proven carries no interaction of its own.
        if session.instructionContinuation != nil, session.runState == .waitingForUser {
            return .waitingContinuation
        }
        guard !session.runState.isActive, session.runState != .waitingForUser else { return nil }
        return .idleFollowUp
    }

    /// Every blocker an inbound `send` has to clear, minus the two that describe the wake itself.
    ///
    /// Reused rather than restated so a blocker can never be enforced for one caller and forgotten
    /// for the other. `pendingOversightAutoWake` is excluded because *this* attempt is it, and the
    /// waiting-prompt pair is excluded because it is a route rather than a blocker.
    private func agentSessionLinkAutoWakeIsUnblocked(_ session: TabSession) -> Bool {
        session.hasLoadedPersistedState
            && !session.bindingTransitionInProgress
            && !session.terminalCommitInProgress
            && !session.mcpFollowUpRunPending
            && !session.isComposerSubmissionInFlight
            && !session.isPreparingInitialWorktree
            && !session.isChangingExecutionLocation
            && session.pendingInstructions.isEmpty
            && session.pendingACPSteeringInstructions.isEmpty
            && session.pendingClaudeSteeringInstructions.isEmpty
            && session.pendingAskUser == nil
            && session.pendingUserInputRequest == nil
            && session.pendingApproval == nil
            && session.pendingPermissionsRequest == nil
            && session.pendingMCPElicitationRequest == nil
            && session.pendingApplyEditsReview == nil
            && session.pendingWorktreeMergeReview == nil
    }

    private func agentSessionLinkReconcileAutoWakeLaneBaselines(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        session: TabSession
    ) {
        let currentReferences = Set(snapshot.autoWakeLanes.map(\.reference))
        session.agentSessionLinkConsumedTargetLocalEpochs = session.agentSessionLinkConsumedTargetLocalEpochs
            .filter { currentReferences.contains($0.key) }
        session.agentSessionLinkAutoWakeEffectiveSelection = session.agentSessionLinkAutoWakeEffectiveSelection
            .filter { currentReferences.contains($0.key) }
        // Live selection, not the snapshot's projection of it. Reading the projection here would
        // re-run the unselected -> selected transition on the first publication that catches up with
        // a selection the fence already baselined, consuming the target's newest epoch as though it
        // predated the selection.
        let selectedLanes = agentSessionLinkLiveSelectedAutoWakeLanes(snapshot, session: session)
        for lane in snapshot.autoWakeLanes {
            let isSelected = selectedLanes[lane.reference] != nil
            let wasEffective = session.agentSessionLinkAutoWakeEffectiveSelection[lane.reference]
            if wasEffective == nil || (wasEffective == false && isSelected) {
                session.agentSessionLinkConsumedTargetLocalEpochs[lane.reference] = lane.targetLocalInputEpoch
            }
            session.agentSessionLinkAutoWakeEffectiveSelection[lane.reference] = isSelected
        }
    }

    /// The lanes this observer has selected for Auto-wake **right now**.
    ///
    /// The snapshot supplies the lanes; the selection comes from the session, never from the lane's
    /// own `isEffectivelySelected`. That flag is a projection frozen when the lane was last
    /// published, and a toggle the user just flipped reaches it only on the next authoritative
    /// refresh. Scheduling, baselining, and the acceptance fence all run on the same main actor as
    /// the selection write, so reading the setting directly is what linearizes them: a deselected
    /// lane cannot cross the transport boundary on the strength of a stale republication, and a
    /// freshly selected one is not left waiting for one.
    private func agentSessionLinkLiveSelectedAutoWakeLanes(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        session: TabSession
    ) -> [DomainAgentSessionLinkReference: AgentSessionLinkPassiveStatusNotices.AutoWakeLane] {
        let masterEnabled = session.autoWakeOnOversightUpdates
        let selectedTargetSessionIDs = session.agentSessionLinkAutoWakeTargetSessionIDs
        return snapshot.autoWakeLanes.reduce(into: [:]) { lanes, lane in
            guard masterEnabled || selectedTargetSessionIDs.contains(lane.targetSessionID) else { return }
            lanes[lane.reference] = lane
        }
    }

    /// Whether the queue's unattributed overflow may reserve a wake on its own.
    ///
    /// `unacknowledgedOverflowCount` is a whole-queue count: it records that status edges were
    /// dropped, never which lane produced them. Treating "some lane is selected" as sufficient
    /// therefore lets an unselected target's dropped edges start an autonomous turn about a session
    /// the user deliberately excluded — the one thing per-target selection exists to prevent.
    ///
    /// The conservative rule, deliberately chosen over attributing overflow per link: overflow counts
    /// only when *every* live lane is selected, so the dropped edges provably cannot have come from
    /// an excluded one. Master-on satisfies it by construction, so the whole-observer case is
    /// unchanged. The cost is a missed wake for pure overflow while any lane is unselected, and the
    /// content stays owed to the next natural turn either way.
    ///
    /// One predicate for both scheduling and the acceptance fence: an attempt that could be reserved
    /// under a rule the fence does not share would be scheduled and then silently refused, or worse,
    /// accepted on a broader rule than the one that admitted it.
    private func agentSessionLinkOverflowAloneMayWake(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        selectedLanes: [DomainAgentSessionLinkReference: AgentSessionLinkPassiveStatusNotices.AutoWakeLane]
    ) -> Bool {
        guard snapshot.unacknowledgedOverflowCount > 0, !snapshot.autoWakeLanes.isEmpty else {
            return false
        }
        return snapshot.autoWakeLanes.allSatisfy { selectedLanes[$0.reference] != nil }
    }

    /// Linearizes one Auto-wake selection change with scheduling and the acceptance fence.
    ///
    /// Runs synchronously, in the same main-actor step as the setting write, and does the two things
    /// the projection refresh it triggers cannot do correctly by the time it lands:
    ///
    /// - It baselines every newly selected lane at the epoch that lane last published, which is the
    ///   target's work *as of the selection*. Left to the refresh, the first "selected" snapshot may
    ///   already carry an input the target's own user made after the selection, and baselining that
    ///   would spend the first valid human re-arm.
    /// - It retracts an attempt the change just made ineligible, rather than leaving a deselected
    ///   lane's wake alive until something else happens to re-evaluate it.
    func agentSessionLinkFenceAutoWakeSelectionChange(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint) else { return }
        if let snapshot = agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID],
           snapshot.observerEndpoint == endpoint
        {
            let selectedLanes = agentSessionLinkLiveSelectedAutoWakeLanes(snapshot, session: session)
            for lane in snapshot.autoWakeLanes {
                let isSelected = selectedLanes[lane.reference] != nil
                if isSelected, session.agentSessionLinkAutoWakeEffectiveSelection[lane.reference] != true {
                    session.agentSessionLinkConsumedTargetLocalEpochs[lane.reference] = lane.targetLocalInputEpoch
                }
                session.agentSessionLinkAutoWakeEffectiveSelection[lane.reference] = isSelected
            }
        }
        guard let attempt = session.pendingOversightAutoWake,
              !agentSessionLinkAutoWakeAttemptIsStillEligible(attempt, session: session)
        else { return }
        cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
    }

    private func agentSessionLinkAutoWakeAttemptIsStillEligible(
        _ attempt: AgentSessionLinkAutoWakeAttempt,
        session: TabSession
    ) -> Bool {
        guard let snapshot = agentSessionLinkPassiveNoticesBySessionID[attempt.observerEndpoint.sessionID],
              snapshot.observerEndpoint == attempt.observerEndpoint,
              snapshot.queueEpoch == attempt.queueEpoch
        else { return false }
        // Live selection: this is the last gate a wake crosses before the provider transport, so a
        // lane the user deselected a moment ago must be gone from it whether or not the projection
        // has caught up.
        let selectedLanes = agentSessionLinkLiveSelectedAutoWakeLanes(snapshot, session: session)
        if !attempt.humanRearmEpochs.isEmpty {
            for (reference, epoch) in attempt.humanRearmEpochs {
                guard let lane = selectedLanes[reference],
                      lane.targetTurnIsLocalUser,
                      lane.targetLocalInputEpoch == epoch,
                      epoch > (session.agentSessionLinkConsumedTargetLocalEpochs[reference] ?? 0)
                else { return false }
            }
            return true
        }
        guard !session.agentSessionLinkTurnOrigin.requiresNewLocalUserInstruction else { return false }
        return snapshot.entries.contains { selectedLanes[$0.reference] != nil }
            || agentSessionLinkOverflowAloneMayWake(snapshot, selectedLanes: selectedLanes)
    }

    /// Whether an undispatchable observer is merely busy rather than gone.
    private func agentSessionLinkAutoWakeMayStillSettle(_ session: TabSession) -> Bool {
        guard let attempt = session.pendingOversightAutoWake else { return false }
        return agentSessionLinkAutoWakeAttemptIsStillEligible(attempt, session: session)
    }

    private func agentSessionLinkSetAutoWakePhase(
        _ phase: AgentSessionLinkAutoWakeAttempt.Phase,
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = sessions[endpoint.tabID],
              var attempt = session.pendingOversightAutoWake,
              attempt.wakeID == wakeID
        else {
            return
        }
        guard attempt.phase != phase else { return }
        attempt.phase = phase
        session.pendingOversightAutoWake = attempt
    }

    private func agentSessionLinkLogAutoWakeGate(
        _ endpoint: DomainAgentSessionLinkEndpointIdentity,
        _ fingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?,
        _ decision: String
    ) {
        #if DEBUG
            // Identity, structural shape, and decision only. Never a name, a preview, or any other
            // target-derived content.
            AgentModePerfDiagnostics.event(
                "sessionLink.autoWake",
                tabID: endpoint.tabID,
                fields: [
                    "session": endpoint.sessionID.uuidString,
                    "edges": String(fingerprint?.edges.count ?? 0),
                    "overflow": String(fingerprint?.overflowProduced ?? 0),
                    "decision": decision
                ]
            )
        #else
            _ = (endpoint, fingerprint, decision)
        #endif
    }
}
