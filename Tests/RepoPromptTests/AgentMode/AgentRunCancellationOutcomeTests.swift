import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentRunCancellationOutcomeTests: XCTestCase {
    func testStopBoundaryValuesRemainSendable() {
        func requireSendable(_: (some Sendable).Type) {}
        requireSendable(AgentRunStartStopFence.self)
        requireSendable(AgentRunCancellationAdmission.self)
        requireSendable(AgentRunOwnership.self)
        requireSendable(AgentPersistentSessionBindingIdentity.self)
    }

    @MainActor
    func testStartFenceRejectsOldGenerationAndOldBindingButAllowsNewWork() {
        let session = AgentTabSession(tabID: UUID())
        let firstBinding = AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID())
        session.installPersistentSessionBinding(firstBinding)
        let scheduled = AgentRunStartStopFence(session: session)
        XCTAssertTrue(scheduled.permitsStart(of: session))

        session.stopState.invalidateScheduledStarts()
        XCTAssertFalse(scheduled.permitsStart(of: session))
        let newInstruction = AgentRunStartStopFence(session: session)
        XCTAssertTrue(newInstruction.permitsStart(of: session))

        let rebound = AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: firstBinding.sessionID)
        session.installPersistentSessionBinding(rebound)
        XCTAssertFalse(newInstruction.permitsStart(of: session))
    }

    @MainActor
    func testStopGateCanOnlyBeReleasedByItsOwnBindingAndRequest() {
        var state = AgentRunStopState()
        let binding = AgentPersistentSessionBindingIdentity(tabID: UUID(), sessionID: UUID())
        let stopID = UUID()
        XCTAssertTrue(state.claimManagedStop(id: stopID, binding: binding))
        XCTAssertFalse(state.claimManagedStop(id: UUID(), binding: binding))
        XCTAssertTrue(state.isStopping(binding: binding))
        XCTAssertFalse(state.releaseManagedStop(id: UUID(), binding: binding))
        XCTAssertFalse(state.releaseManagedStop(id: stopID, binding: AgentPersistentSessionBindingIdentity(
            tabID: binding.tabID,
            sessionID: binding.sessionID
        )))
        XCTAssertTrue(state.isStopping(binding: binding))
        XCTAssertTrue(state.releaseManagedStop(id: stopID, binding: binding))
        XCTAssertFalse(state.isStopping(binding: binding))
    }

    @MainActor
    func testPublicationTimeRebindRetainsCausalResultWithoutAttribution() {
        let session = AgentTabSession(tabID: UUID())
        let binding = AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID())
        session.installPersistentSessionBinding(binding)
        let ownership = session.beginRunAttempt(source: "publication-rebind")
        let runID = UUID()
        var attributed = false
        let recorder = AgentRunCancellationOutcomeRecorder(
            expectedOwnership: ownership, expectedRunID: runID, expectedBinding: binding,
            onAcceptedPrimaryPublication: { _ in attributed = true }
        )
        recorder.recordCancellationInitiated()
        let revision = AgentRunTerminalCommitRevision(
            commitID: UUID(), ownership: ownership, terminalState: .cancelled,
            failureReason: nil, expectedRunID: runID, sourceItemsRevision: 0,
            assistantDeltaFlushGeneration: 0, providerDrainGeneration: 0,
            mcpPublicationEnvelope: nil, successorKind: nil, providerSuccessorID: nil
        )
        session.installPersistentSessionBinding(
            AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID())
        )
        recorder.recordPrimaryPublication(revision: revision, result: .accepted(successorEpoch: nil), session: session)
        XCTAssertEqual(recorder.primaryRevision, revision)
        XCTAssertEqual(recorder.publicationResult, .accepted(successorEpoch: nil))
        XCTAssertFalse(attributed)
    }

    @MainActor
    func testRecorderOnlyAttributesPrimaryAcceptedCancellationForExactOwnership() {
        let session = AgentTabSession(tabID: UUID())
        let binding = AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID())
        session.installPersistentSessionBinding(binding)
        let ownership = session.beginRunAttempt(source: "stop-test")
        let runID = UUID()
        var callbackCount = 0
        let recorder = AgentRunCancellationOutcomeRecorder(
            expectedOwnership: ownership,
            expectedRunID: runID,
            expectedBinding: binding,
            onAcceptedPrimaryPublication: { _ in callbackCount += 1 }
        )
        func revision(
            ownership: AgentRunOwnership,
            terminalState: AgentSessionRunState
        ) -> AgentRunTerminalCommitRevision {
            AgentRunTerminalCommitRevision(
                commitID: UUID(),
                ownership: ownership,
                terminalState: terminalState,
                failureReason: nil,
                expectedRunID: runID,
                sourceItemsRevision: 0,
                assistantDeltaFlushGeneration: 0,
                providerDrainGeneration: 0,
                mcpPublicationEnvelope: nil,
                successorKind: nil,
                providerSuccessorID: nil
            )
        }
        let acceptedRevision = revision(ownership: ownership, terminalState: .cancelled)
        recorder.recordPrimaryPublication(revision: acceptedRevision, result: .accepted(successorEpoch: nil), session: session)
        XCTAssertEqual(callbackCount, 0, "Observation before cancellation admission is not attribution")
        recorder.recordCancellationInitiated()
        recorder.recordPrimaryPublication(revision: revision(ownership: ownership, terminalState: .completed), result: .accepted(successorEpoch: nil), session: session)
        XCTAssertEqual(callbackCount, 0)
        recorder.recordPrimaryPublication(revision: acceptedRevision, result: .accepted(successorEpoch: nil), session: session)
        recorder.recordPrimaryPublication(revision: acceptedRevision, result: .accepted(successorEpoch: nil), session: session)
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(recorder.primaryRevision, acceptedRevision)
        XCTAssertEqual(recorder.publicationResult, .accepted(successorEpoch: nil))
        XCTAssertFalse(recorder.teardownCompleted)
        recorder.recordTeardownCompleted()
        XCTAssertTrue(recorder.teardownCompleted)
    }
}
