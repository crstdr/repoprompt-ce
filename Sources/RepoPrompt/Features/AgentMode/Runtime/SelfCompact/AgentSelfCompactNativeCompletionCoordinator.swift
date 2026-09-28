import Foundation

/// Request-correlated native completion and one-shot continuation. The injectable sleeper makes
/// the 300-second monotonic deadline testable without wall-clock waits.
@MainActor
final class AgentSelfCompactNativeCompletionCoordinator {
    typealias State = AgentSelfCompactState
    typealias NoteDispatch = @MainActor (
        _ requestID: UUID,
        _ stillAdmissible: @escaping @MainActor () -> Bool
    ) async -> Bool

    private let load: @MainActor () -> State
    private let store: @MainActor (State) -> Void
    private let isCurrentOwner: @MainActor (AgentSelfCompactOwner) -> Bool
    private let dispatchNote: NoteDispatch
    private let sleep: @MainActor (Duration) async -> Void
    private var deadlineTask: Task<Void, Never>?
    private var noteTask: Task<Void, Never>?

    init(
        load: @escaping @MainActor () -> State,
        store: @escaping @MainActor (State) -> Void,
        isCurrentOwner: @escaping @MainActor (AgentSelfCompactOwner) -> Bool,
        dispatchNote: @escaping NoteDispatch,
        sleep: @escaping @MainActor (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.load = load
        self.store = store
        self.isCurrentOwner = isCurrentOwner
        self.dispatchNote = dispatchNote
        self.sleep = sleep
    }

    @discardableResult
    func bindCompact(
        _ dispatchID: AgentSelfCompactionDispatchID,
        runID: UUID?,
        runAttemptID: UUID?
    ) -> Bool {
        var state = load()
        guard state.bindCompactRun(dispatchID, runID: runID, attemptID: runAttemptID) else { return false }
        store(state)
        deadlineTask?.cancel()
        deadlineTask = Task { @MainActor [self] in
            await sleep(.seconds(300))
            guard !Task.isCancelled else { return }
            var current = load()
            guard current.active?.id == dispatchID.requestID,
                  current.active?.phase == .dispatchingCompact
                  || current.active?.phase == .awaitingCompactTurn
            else { return }
            if let owner = current.active?.owner, !isCurrentOwner(owner) {
                current.settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
            } else {
                current.settle(.completionUnverified, noteDelivery: .notSent, completionVerified: false)
            }
            store(current)
        }
        return true
    }

    func compactTurnSettled(
        revision: AgentRunTerminalCommitRevision,
        publication: AgentRunTerminalPublicationResult,
        teardownSettled: @escaping @MainActor () -> Bool
    ) {
        var state = load()
        guard let attempt = state.active,
              attempt.phase == .dispatchingCompact || attempt.phase == .awaitingCompactTurn,
              let owner = attempt.owner,
              attempt.compactRunID == revision.expectedRunID,
              attempt.compactRunAttemptID == revision.ownership.attemptID
        else { return }
        guard case .accepted(successorEpoch: nil) = publication else {
            if case .rejected = publication { return }
            deadlineTask?.cancel()
            state.settle(.completionUnverified, noteDelivery: .notSent, completionVerified: false)
            store(state)
            return
        }
        deadlineTask?.cancel()
        guard isCurrentOwner(owner) else {
            state.settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
            store(state)
            return
        }
        guard revision.successorKind == nil else {
            state.active?.phase = .parked
            store(state)
            return
        }
        let succeeded = revision.terminalState == .completed
            && (attempt.admittedSupport == .claudeCode || attempt.compactTurnSucceeded == true)
        guard succeeded else {
            state.settle(.failed, noteDelivery: .notSent, completionVerified: false)
            store(state)
            return
        }
        state.active?.compactTurnSucceeded = true
        state.active?.phase = .awaitingNoteBoundary
        store(state)
        noteTask = Task { @MainActor [self] in
            await beginNote(requestID: attempt.id, owner: owner, teardownSettled: teardownSettled)
        }
    }

    func cancelRuntimeWork() {
        deadlineTask?.cancel()
        deadlineTask = nil
        noteTask?.cancel()
        noteTask = nil
    }

    /// An ordinary accepted input may win after native dispatch. It carries the parked note on
    /// its own physical send; the maintenance worker never races it with an extra prompt.
    func supersedeForOrdinaryInput() {
        var state = load()
        guard let attempt = state.active,
              attempt.phase != .scheduled,
              attempt.phase != .compactDispatchPending,
              attempt.phase != .parked,
              !attempt.noteDispatchStarted
        else { return }
        deadlineTask?.cancel()
        if let owner = attempt.owner, !isCurrentOwner(owner) {
            state.settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
        } else {
            state.active?.phase = .parked
        }
        store(state)
    }

    private func beginNote(
        requestID: UUID,
        owner: AgentSelfCompactOwner,
        teardownSettled: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< 600 {
            guard load().active?.id == requestID,
                  load().active?.phase == .awaitingNoteBoundary
            else { return }
            guard isCurrentOwner(owner) else {
                var state = load()
                state.settle(.cancelled, noteDelivery: .notSent, completionVerified: true)
                store(state)
                return
            }
            if teardownSettled() { break }
            await sleep(.milliseconds(100))
            guard !Task.isCancelled else { return }
            await Task.yield()
        }
        var state = load()
        guard state.active?.id == requestID,
              state.active?.phase == .awaitingNoteBoundary
        else { return }
        guard teardownSettled(), isCurrentOwner(owner) else {
            state.active?.phase = .parked
            store(state)
            return
        }
        state.active?.phase = .noteDispatchPending
        store(state)
        let didStart = await dispatchNote(requestID) { [self] in
            let current = load().active
            return current?.id == requestID
                && (current?.phase == .noteDispatchPending || current?.phase == .dispatchingNote)
                && current?.noteDispatchStarted == false
                && isCurrentOwner(owner)
        }
        state = load()
        guard state.active?.id == requestID else { return }
        if !didStart, state.active?.noteDispatchStarted == false {
            state.active?.phase = .parked
            store(state)
        }
    }
}
