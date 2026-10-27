import Foundation

/// Owns only the origin turn's terminal boundary and native-command start. Completion and note
/// delivery are deliberately separate stages. A restored attempt never constructs this worker.
@MainActor
final class AgentSelfCompactTerminalScheduler {
    typealias Dispatch = @MainActor (
        _ requestID: UUID,
        _ support: AgentSessionLinkCompactSupport,
        _ stillAdmissible: @escaping @MainActor () -> Bool
    ) async -> AgentSelfCompactDiagnostics.CompactDispatchOutcome

    private let load: @MainActor () -> AgentSelfCompactState
    private let store: @MainActor (AgentSelfCompactState) -> Void
    private let isCurrentOwner: @MainActor (AgentSelfCompactOwner) -> Bool
    private let hasActiveTools: @MainActor (UUID) -> Bool
    private let support: @MainActor () async -> AgentSessionLinkCompactSupport
    private let dispatch: Dispatch
    private let sleep: @MainActor (Duration) async -> Void
    private let maximumDrainPolls: Int

    init(
        load: @escaping @MainActor () -> AgentSelfCompactState,
        store: @escaping @MainActor (AgentSelfCompactState) -> Void,
        isCurrentOwner: @escaping @MainActor (AgentSelfCompactOwner) -> Bool,
        hasActiveTools: @escaping @MainActor (UUID) -> Bool,
        support: @escaping @MainActor () async -> AgentSessionLinkCompactSupport,
        dispatch: @escaping Dispatch,
        maximumDrainPolls: Int = 600,
        sleep: @escaping @MainActor (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.load = load
        self.store = store
        self.isCurrentOwner = isCurrentOwner
        self.hasActiveTools = hasActiveTools
        self.support = support
        self.dispatch = dispatch
        self.maximumDrainPolls = maximumDrainPolls
        self.sleep = sleep
    }

    /// Called only after publication and successor arbitration. It never contacts a provider inline.
    func terminalSettled(
        runID: UUID?,
        runAttemptID: UUID,
        terminalState: AgentSessionRunState,
        publication: AgentRunTerminalPublicationResult,
        successorClaimed: Bool,
        teardownSettled: @escaping @MainActor () -> Bool
    ) {
        var state = load()
        guard let attempt = state.active,
              attempt.phase == .scheduled,
              let owner = attempt.owner,
              owner.runID == runID,
              owner.runAttemptID == runAttemptID
        else { return }

        switch publication {
        case let .rejected(reason):
            // A duplicate commit may retry this exact revision, but an unretired rejection must
            // not block readiness forever if no retry comes.
            Task { @MainActor [self] in
                await settleRejectedIfUnresolved(
                    requestID: attempt.id, owner: owner, rejectionReason: reason
                )
            }
            return
        case .stale:
            settleCancelled(attempt.id, cause: .publicationStale, details: .init(publication: .stale))
            return
        case .accepted(successorEpoch: nil):
            break
        case .accepted:
            settleCancelled(
                attempt.id,
                cause: .successorEpochCommitted,
                details: .init(publication: .acceptedSuccessorEpoch)
            )
            return
        }
        // Item 2 deliberately narrowed the plan's failed-origin allowance. A generic .failed
        // terminal does not prove context exhaustion or even a live provider conversation, so native
        // self-compaction remains fail-closed until a typed context-limit failure is available.
        guard !successorClaimed else {
            settleCancelled(
                attempt.id,
                cause: .successorClaimed,
                details: .init(publication: publicationKind(publication))
            )
            return
        }
        guard terminalState == .completed else {
            settleCancelled(
                attempt.id,
                cause: .originNotCompleted,
                details: .init(publication: publicationKind(publication))
            )
            return
        }
        guard isCurrentOwner(owner) else {
            settleCancelled(
                attempt.id,
                cause: .ownerLost,
                details: .init(publication: publicationKind(publication))
            )
            return
        }
        state.active?.phase = .compactDispatchPending
        store(state)
        // The barrier has finished publication but may still be inside its own stack. A new task is
        // the earliest place provider preparation may begin, and this task owns the bounded drain.
        Task { @MainActor [self] in
            await run(requestID: attempt.id, owner: owner, teardownSettled: teardownSettled)
        }
    }

    /// Local input wins only once accepted, not when a draft changes or admission is refused.
    func cancelForAcceptedLocalInput() {
        guard let active = load().active,
              active.phase == .scheduled || active.phase == .compactDispatchPending
        else { return }
        settleCancelled(active.id, cause: .acceptedLocalInput)
    }

    private func run(
        requestID: UUID,
        owner: AgentSelfCompactOwner,
        teardownSettled: @escaping @MainActor () -> Bool
    ) async {
        for poll in 0 ... maximumDrainPolls {
            guard isPending(requestID, owner: owner) else { return }
            guard isCurrentOwner(owner) else {
                settleCancelled(requestID, cause: .ownerLost)
                return
            }
            if teardownSettled(), !hasActiveTools(owner.runID) { break }
            guard poll < maximumDrainPolls else {
                var details = AgentSelfCompactDiagnostics.SettleDetails()
                details.toolsActive = hasActiveTools(owner.runID)
                details.teardownPending = !teardownSettled()
                settleFailed(requestID, cause: .drainTimeout, details: details)
                return
            }
            await sleep(.milliseconds(100))
            await Task.yield()
        }
        guard isPending(requestID, owner: owner) else { return }
        guard isCurrentOwner(owner) else {
            settleCancelled(requestID, cause: .ownerLost)
            return
        }
        let admittedSupport = await support()
        guard isPending(requestID, owner: owner) else { return }
        guard isCurrentOwner(owner) else {
            settleCancelled(requestID, cause: .ownerLost)
            return
        }
        guard load().active?.admittedSupport == admittedSupport,
              admittedSupport == .codex || admittedSupport == .claudeCode
              || admittedSupport == .acpAdvertisedCommand
        else {
            settleFailed(
                requestID,
                cause: .supportChanged,
                details: .init(supportNow: admittedSupport)
            )
            return
        }
        var state = load()
        state.active?.phase = .dispatchingCompact
        state.active?.compactDispatchStarted = true
        store(state)
        let dispatchOutcome = await dispatch(requestID, admittedSupport) { [self] in
            isDispatching(requestID, owner: owner)
                && isCurrentOwner(owner)
                && load().active?.admittedSupport == admittedSupport
        }
        let didStart = dispatchOutcome.didStart
        guard isDispatching(requestID, owner: owner) else { return }
        guard isCurrentOwner(owner) else {
            if didStart {
                settleCompletionUnverified(requestID, cause: .ownerLost, didStart: true)
            } else {
                settleCancelled(requestID, cause: .ownerLost, details: .init(didStart: false))
            }
            return
        }
        state = load()
        if didStart {
            recordSettle(state: state, requestID: requestID, outcome: .compactDispatched, cause: .compactDispatchStarted)
            state.active?.phase = .awaitingCompactTurn
            store(state)
        } else {
            settleFailed(
                requestID,
                cause: .dispatchNotStarted,
                details: .init(blocker: dispatchOutcome.blocker ?? .unknown)
            )
        }
    }

    private func settleRejectedIfUnresolved(
        requestID: UUID,
        owner: AgentSelfCompactOwner,
        rejectionReason: String
    ) async {
        // A rejected publication gets only a short duplicate-commit retry window, not the full
        // teardown/tool-drain budget.
        for _ in 0 ..< min(maximumDrainPolls, 50) {
            guard let attempt = load().active,
                  attempt.id == requestID, attempt.owner == owner, attempt.phase == .scheduled
            else { return }
            await sleep(.milliseconds(100))
            await Task.yield()
        }
        guard let attempt = load().active,
              attempt.id == requestID, attempt.owner == owner, attempt.phase == .scheduled
        else { return }
        settleFailed(
            requestID,
            cause: .rejectedPublicationTimeout,
            details: .init(
                publication: .rejected,
                publicationRejection: .init(rawReason: rejectionReason)
            )
        )
    }

    private func isPending(_ requestID: UUID, owner: AgentSelfCompactOwner) -> Bool {
        guard let attempt = load().active else { return false }
        return attempt.id == requestID && attempt.phase == .compactDispatchPending
            && attempt.owner == owner
    }

    private func isDispatching(_ requestID: UUID, owner: AgentSelfCompactOwner) -> Bool {
        guard let attempt = load().active else { return false }
        return attempt.id == requestID && attempt.phase == .dispatchingCompact
            && attempt.owner == owner
    }

    private func publicationKind(
        _ publication: AgentRunTerminalPublicationResult
    ) -> AgentSelfCompactDiagnostics.PublicationKind {
        switch publication {
        case let .accepted(successorEpoch):
            successorEpoch == nil ? .accepted : .acceptedSuccessorEpoch
        case .stale:
            .stale
        case .rejected:
            .rejected
        }
    }

    private func recordSettle(
        state: AgentSelfCompactState,
        requestID: UUID,
        outcome: AgentSelfCompactDiagnostics.SettleOutcome,
        cause: AgentSelfCompactDiagnostics.SettleCause,
        details: AgentSelfCompactDiagnostics.SettleDetails = .init()
    ) {
        guard let attempt = state.active, attempt.id == requestID else { return }
        AgentSelfCompactDiagnostics.settle(
            attempt: attempt,
            outcome: outcome,
            cause: cause,
            details: details
        )
    }

    private func settleCancelled(
        _ requestID: UUID,
        cause: AgentSelfCompactDiagnostics.SettleCause,
        details: AgentSelfCompactDiagnostics.SettleDetails = .init()
    ) {
        var state = load()
        guard state.active?.id == requestID else { return }
        recordSettle(state: state, requestID: requestID, outcome: .cancelled, cause: cause, details: details)
        state.settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
        store(state)
    }

    private func settleCompletionUnverified(
        _ requestID: UUID,
        cause: AgentSelfCompactDiagnostics.SettleCause,
        didStart: Bool
    ) {
        var state = load()
        guard state.active?.id == requestID else { return }
        recordSettle(
            state: state,
            requestID: requestID,
            outcome: .completionUnverified,
            cause: cause,
            details: .init(didStart: didStart)
        )
        state.settle(.completionUnverified, noteDelivery: .notSent, completionVerified: false)
        store(state)
    }

    private func settleFailed(
        _ requestID: UUID,
        cause: AgentSelfCompactDiagnostics.SettleCause,
        details: AgentSelfCompactDiagnostics.SettleDetails = .init()
    ) {
        var state = load()
        guard state.active?.id == requestID else { return }
        recordSettle(state: state, requestID: requestID, outcome: .failed, cause: cause, details: details)
        state.settle(.failed, noteDelivery: .notSent, completionVerified: false)
        store(state)
    }
}
