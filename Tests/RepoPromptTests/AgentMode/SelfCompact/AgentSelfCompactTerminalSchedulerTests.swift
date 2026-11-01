@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSelfCompactTerminalSchedulerTests: XCTestCase {
    @MainActor private final class BindGate {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    @MainActor private final class Fake {
        var state = AgentSelfCompactState()
        var endpointIsCurrent = true
        var teardownIsSettled = true
        var toolsAreDrained = true
        var support: AgentSessionLinkCompactSupport = .claudeCode
        var dispatched = 0
        var polls = 0
        var onPoll: (() -> Void)?
        let runID = UUID()
        let attemptID = UUID()
        let endpoint = AgentSelfCompactOwner(
            windowID: 1,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            runID: UUID(),
            runAttemptID: UUID()
        )

        func scheduler() -> AgentSelfCompactTerminalScheduler {
            AgentSelfCompactTerminalScheduler(
                load: { self.state },
                store: { self.state = $0 },
                isCurrentOwner: { _ in self.endpointIsCurrent },
                hasActiveTools: { _ in !self.toolsAreDrained },
                support: { self.support },
                dispatch: { _, _, stillAdmissible in
                    guard stillAdmissible() else { return .refused(.stillAdmissibleLost) }
                    self.dispatched += 1
                    return .started
                },
                maximumDrainPolls: 50,
                sleep: { _ in
                    self.polls += 1
                    self.onPoll?()
                }
            )
        }

        func arm() {
            var owner = endpoint
            owner = AgentSelfCompactOwner(
                windowID: owner.windowID,
                workspaceID: owner.workspaceID,
                tabID: owner.tabID,
                sessionID: owner.sessionID,
                persistentBindingGeneration: owner.persistentBindingGeneration,
                bindingTransitionGeneration: owner.bindingTransitionGeneration,
                runID: runID,
                runAttemptID: attemptID
            )
            _ = state.reserve(note: "resume here", idempotencyKey: "key", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes, owner: owner)
            state.active?.admittedSupport = .claudeCode
        }
    }

    private func drain() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    func testAcceptedCommitDispatchesOnlyFromWorkerAndDuplicateDoesNotDispatchTwice() async {
        let fake = Fake()
        fake.arm()
        let scheduler = fake.scheduler()
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        XCTAssertEqual(fake.dispatched, 0, "terminal hook must not call provider inline")
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        await drain()
        XCTAssertEqual(fake.dispatched, 1)
        XCTAssertEqual(fake.state.active?.phase, .awaitingCompactTurn)
    }

    func testRejectedStaleSuccessorAndWrongAttemptNeverDispatch() async {
        for publication in [
            AgentRunTerminalPublicationResult.rejected(reason: "no"),
            .stale,
            .accepted(successorEpoch: nil)
        ] {
            let fake = Fake()
            fake.arm()
            let scheduler = fake.scheduler()
            scheduler.terminalSettled(
                runID: fake.runID,
                runAttemptID: publication == .accepted(successorEpoch: nil) ? UUID() : fake.attemptID,
                terminalState: .completed,
                publication: publication,
                successorClaimed: false,
                teardownSettled: { true }
            )
            await drain()
            XCTAssertEqual(fake.dispatched, 0)
        }
        let fake = Fake()
        fake.arm()
        let scheduler = fake.scheduler()
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: true, teardownSettled: { true }
        )
        await drain()
        XCTAssertEqual(fake.dispatched, 0)
        XCTAssertEqual(fake.state.latest?.outcome, .cancelled)
    }

    func testRejectedPublicationCanRetryButStaleCancels() async {
        let fake = Fake()
        fake.arm()
        let scheduler = fake.scheduler()
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .rejected(reason: "transient"),
            successorClaimed: false, teardownSettled: { true }
        )
        XCTAssertEqual(fake.state.active?.phase, .scheduled)
        XCTAssertEqual(fake.dispatched, 0)
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await drain()
        XCTAssertEqual(fake.dispatched, 1)

        let stale = Fake()
        stale.arm()
        stale.scheduler().terminalSettled(
            runID: stale.runID, runAttemptID: stale.attemptID,
            terminalState: .completed, publication: .stale,
            successorClaimed: false, teardownSettled: { true }
        )
        XCTAssertEqual(stale.state.latest?.outcome, .cancelled)
        XCTAssertEqual(stale.dispatched, 0)

        let abandoned = Fake()
        abandoned.arm()
        abandoned.scheduler().terminalSettled(
            runID: abandoned.runID, runAttemptID: abandoned.attemptID,
            terminalState: .completed, publication: .rejected(reason: "never retried"),
            successorClaimed: false, teardownSettled: { true }
        )
        for _ in 0 ..< 120 {
            await Task.yield()
        }
        XCTAssertNil(abandoned.state.active)
        XCTAssertEqual(abandoned.state.latest?.outcome, .failed)
        XCTAssertEqual(abandoned.dispatched, 0)
    }

    func testEndpointAndSupportAreRecheckedAfterTeardown() async {
        for invalidateEndpoint in [false, true] {
            let fake = Fake()
            fake.arm()
            fake.teardownIsSettled = false
            fake.onPoll = {
                fake.teardownIsSettled = true
                if invalidateEndpoint {
                    fake.endpointIsCurrent = false
                } else {
                    fake.support = .notSupported
                }
            }
            let scheduler = fake.scheduler()
            scheduler.terminalSettled(
                runID: fake.runID, runAttemptID: fake.attemptID,
                terminalState: .completed, publication: .accepted(successorEpoch: nil),
                successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
            )
            await drain()
            XCTAssertEqual(fake.dispatched, 0)
            XCTAssertNil(fake.state.active)
            XCTAssertEqual(fake.state.latest?.outcome, invalidateEndpoint ? .cancelled : .failed)
        }
    }

    func testAcceptedLocalInputAndSupportChangeCancelBeforeDispatch() async {
        let fake = Fake()
        fake.arm()
        fake.teardownIsSettled = false
        let scheduler = fake.scheduler()
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        scheduler.cancelForAcceptedLocalInput()
        fake.teardownIsSettled = true
        await drain()
        XCTAssertEqual(fake.dispatched, 0)
        XCTAssertEqual(fake.state.latest?.outcome, .cancelled)

        let changed = Fake()
        changed.arm()
        changed.support = .codex
        let other = changed.scheduler()
        other.terminalSettled(
            runID: changed.runID, runAttemptID: changed.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await drain()
        XCTAssertEqual(changed.dispatched, 0)
        XCTAssertEqual(changed.state.latest?.outcome, .failed)
    }

    func testACPBindAfterPipelineStartCanFollowAwaitingCompactTurn() async throws {
        let fake = Fake()
        fake.arm()
        fake.state.active?.admittedSupport = .acpAdvertisedCommand
        fake.support = .acpAdvertisedCommand
        let requestID = try XCTUnwrap(fake.state.active?.id)
        let runID = UUID()
        let runAttemptID = UUID()
        let gate = BindGate()
        let completion = AgentSelfCompactNativeCompletionCoordinator(
            load: { fake.state },
            store: { fake.state = $0 },
            isCurrentOwner: { _ in true },
            dispatchNote: { _, _ in false }
        )
        let bindAfterPreparation = Task { @MainActor in
            await gate.wait()
            return completion.bindCompact(
                .init(requestID: requestID, stage: .compact),
                runID: runID, runAttemptID: runAttemptID
            )
        }
        await gate.waitUntilEntered()
        fake.scheduler().terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await drain()
        XCTAssertEqual(fake.dispatched, 1)
        XCTAssertEqual(fake.state.active?.phase, .awaitingCompactTurn)
        gate.release()
        let bound = await bindAfterPreparation.value
        XCTAssertTrue(bound, "ACP physical command must still bind after pipeline-start receipt")
        XCTAssertEqual(fake.state.active?.compactRunID, runID)
        XCTAssertEqual(fake.state.active?.compactRunAttemptID, runAttemptID)
        completion.cancelRuntimeWork()
    }

    func testACPAdvertisedCommandDispatchesTheCompactTurn() async {
        let fake = Fake()
        fake.arm()
        fake.state.active?.admittedSupport = .acpAdvertisedCommand
        fake.support = .acpAdvertisedCommand
        fake.scheduler().terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await drain()
        XCTAssertEqual(fake.dispatched, 1)
        XCTAssertEqual(fake.state.active?.phase, .awaitingCompactTurn)
        XCTAssertNil(fake.state.latest)
    }

    func testTeardownAndToolDrainAreBoundedWithoutCancellingForeignTools() async {
        let fake = Fake()
        fake.arm()
        fake.toolsAreDrained = false
        let scheduler = fake.scheduler()
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertEqual(fake.dispatched, 0)
        XCTAssertNil(fake.state.active)
        XCTAssertEqual(fake.state.latest?.outcome, .failed)
        XCTAssertLessThanOrEqual(fake.polls, 50)
        XCTAssertFalse(fake.toolsAreDrained, "worker must not cancel another tool")

        let teardown = Fake()
        teardown.arm()
        teardown.teardownIsSettled = false
        teardown.scheduler().terminalSettled(
            runID: teardown.runID, runAttemptID: teardown.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { teardown.teardownIsSettled }
        )
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertNil(teardown.state.active)
        XCTAssertEqual(teardown.dispatched, 0)
        XCTAssertLessThanOrEqual(teardown.polls, 50)
    }
}

@MainActor
final class AgentSelfCompactDiagnosticsTests: XCTestCase {
    private func makeOwner() -> AgentSelfCompactOwner {
        AgentSelfCompactOwner(
            windowID: 1,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            runID: UUID(),
            runAttemptID: UUID()
        )
    }

    private func makeAttempt() throws -> AgentSelfCompactAttempt {
        var state = AgentSelfCompactState()
        _ = state.reserve(
            note: "note text that must never be logged",
            idempotencyKey: "key",
            maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes,
            owner: makeOwner()
        )
        return try XCTUnwrap(state.active)
    }

    func testSettleRecordCarriesOnlyStructuredFieldsAndNoFreeText() throws {
        let attempt = try makeAttempt()
        AgentSelfCompactDiagnostics.beginCaptureForTesting()
        defer { _ = AgentSelfCompactDiagnostics.endCaptureForTesting() }
        AgentSelfCompactDiagnostics.settle(
            attempt: attempt,
            outcome: .failed,
            cause: .drainTimeout,
            details: .init(toolsActive: true, teardownPending: false)
        )
        let records = AgentSelfCompactDiagnostics.endCaptureForTesting()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.event, .settle)
        XCTAssertEqual(record.outcome, "failed")
        XCTAssertEqual(record.cause, "drain_timeout")
        XCTAssertEqual(record.phase, "scheduled")
        XCTAssertEqual(record.toolsActive, true)
        XCTAssertEqual(record.teardownPending, false)
        XCTAssertEqual(record.request.count, 12)
        XCTAssertNotEqual(record.request, attempt.id.uuidString)
        let line = record.renderedLine
        XCTAssertTrue(line.hasPrefix("event=selfcompact-settle "))
        XCTAssertFalse(line.contains("note text"))
        XCTAssertFalse(line.contains(attempt.id.uuidString))
        XCTAssertFalse(try line.contains(XCTUnwrap(attempt.owner?.runAttemptID.uuidString)))
        XCTAssertTrue(line.contains("request="))
        XCTAssertTrue(line.contains("cause=drain_timeout"))
    }

    func testRejectedPublicationReasonIsBoundedToKnownEnum() throws {
        let attempt = try makeAttempt()
        AgentSelfCompactDiagnostics.beginCaptureForTesting()
        defer { _ = AgentSelfCompactDiagnostics.endCaptureForTesting() }
        var details = AgentSelfCompactDiagnostics.SettleDetails()
        details.publication = .rejected
        details.publicationRejection = .init(rawReason: "different_commit_already_published")
        AgentSelfCompactDiagnostics.settle(
            attempt: attempt,
            outcome: .failed,
            cause: .rejectedPublicationTimeout,
            details: details
        )
        AgentSelfCompactDiagnostics.settle(
            attempt: attempt,
            outcome: .failed,
            cause: .rejectedPublicationTimeout,
            details: .init(
                publication: .rejected,
                publicationRejection: .init(rawReason: "some unexpected free-form reason text")
            )
        )
        let records = AgentSelfCompactDiagnostics.endCaptureForTesting()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].publicationReason, "different_commit_already_published")
        XCTAssertEqual(records[1].publicationReason, "other")
        XCTAssertFalse(records[1].renderedLine.contains("free-form"))
    }

    func testRefusedDispatchEmitsExactlyOneSettleRecordWithNamedCause() async throws {
        var state = AgentSelfCompactState()
        let owner = makeOwner()
        _ = state.reserve(
            note: "note", idempotencyKey: "key",
            maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes,
            owner: owner
        )
        state.active?.admittedSupport = .claudeCode
        let scheduler = AgentSelfCompactTerminalScheduler(
            load: { state },
            store: { state = $0 },
            isCurrentOwner: { _ in true },
            hasActiveTools: { _ in false },
            support: { .claudeCode },
            dispatch: { _, _, _ in .refused(.readiness(.targetNotIdle)) },
            maximumDrainPolls: 1,
            sleep: { _ in }
        )
        AgentSelfCompactDiagnostics.beginCaptureForTesting()
        defer { _ = AgentSelfCompactDiagnostics.endCaptureForTesting() }
        scheduler.terminalSettled(
            runID: owner.runID,
            runAttemptID: owner.runAttemptID,
            terminalState: .completed,
            publication: .accepted(successorEpoch: nil),
            successorClaimed: false,
            teardownSettled: { true }
        )
        for _ in 0 ..< 30 {
            await Task.yield()
        }
        let records = AgentSelfCompactDiagnostics.endCaptureForTesting()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.cause, "dispatch_not_started")
        XCTAssertEqual(record.blocker, "readiness_target_not_idle")
        XCTAssertEqual(record.outcome, "failed")
        XCTAssertEqual(record.phase, "dispatchingCompact")
        XCTAssertEqual(state.latest?.outcome, .failed)
    }

    func testNothingEmittedWithoutActiveSelfCompact() async {
        var state = AgentSelfCompactState()
        let scheduler = AgentSelfCompactTerminalScheduler(
            load: { state },
            store: { state = $0 },
            isCurrentOwner: { _ in true },
            hasActiveTools: { _ in false },
            support: { .claudeCode },
            dispatch: { _, _, _ in .started },
            maximumDrainPolls: 1,
            sleep: { _ in }
        )
        AgentSelfCompactDiagnostics.beginCaptureForTesting()
        defer { _ = AgentSelfCompactDiagnostics.endCaptureForTesting() }
        scheduler.terminalSettled(
            runID: UUID(),
            runAttemptID: UUID(),
            terminalState: .completed,
            publication: .accepted(successorEpoch: nil),
            successorClaimed: false,
            teardownSettled: { true }
        )
        scheduler.cancelForAcceptedLocalInput()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertTrue(AgentSelfCompactDiagnostics.endCaptureForTesting().isEmpty)
    }
}
