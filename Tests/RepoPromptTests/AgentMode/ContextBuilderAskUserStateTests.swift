@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class ContextBuilderAskUserStateTests: XCTestCase {
    func testTabSessionInitializesWithNoPendingAskUserInteraction() {
        let session = ContextBuilderAgentViewModel.TabSession(tabID: UUID())

        XCTAssertNil(session.pendingAskUser)
        XCTAssertNil(session.askUserContinuation)
        XCTAssertNil(session.pendingAskUserRunID)
        XCTAssertNil(session.askUserTimeoutTask)
        XCTAssertEqual(session.pendingAskUserTimeoutGeneration, 0)
    }

    func testTabSessionStoresStructuredPendingAskUserState() throws {
        let tabID = UUID()
        let interactionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000128"))
        let session = ContextBuilderAgentViewModel.TabSession(tabID: tabID)
        let interaction = AgentAskUserInteraction(
            id: interactionID,
            title: "Clarify selection",
            context: "Context Builder needs one more detail.",
            timeoutSeconds: 30,
            questions: [
                AgentAskUserQuestion(
                    id: "scope",
                    header: "Scope",
                    question: "Which files should be included?",
                    options: [
                        AgentAskUserOption(label: "Changed only"),
                        AgentAskUserOption(label: "All relevant")
                    ],
                    allowsMultiple: false,
                    allowsCustom: false
                ),
                AgentAskUserQuestion(
                    id: "notes",
                    question: "Any extra constraints?",
                    allowsCustom: true
                )
            ]
        )
        try interaction.validate()

        var drafts = interaction.emptyDrafts()
        drafts["scope"] = AgentAskUserDraft(selectedOptionLabels: ["All relevant"])
        let pending = AgentAskUserPendingState(
            interaction: interaction,
            draftsByQuestionID: drafts,
            currentQuestionIndex: 1
        )

        let runID = UUID()
        session.pendingAskUser = pending
        session.pendingAskUserRunID = runID

        let stored = try XCTUnwrap(session.pendingAskUser)
        XCTAssertEqual(session.pendingAskUserRunID, runID)
        XCTAssertEqual(stored.id, interactionID)
        XCTAssertEqual(stored.currentQuestion?.id, "notes")
        XCTAssertEqual(stored.draftsByQuestionID["scope"]?.selectedOptionLabels, ["All relevant"])
        XCTAssertEqual(stored.legacyDiscoveryQuestion?.id, interactionID)
        XCTAssertEqual(stored.legacyDiscoveryQuestion?.question, "Which files should be included?")
    }
}

@MainActor
final class AskUserActivityDeadlineTests: XCTestCase {
    func testCardActivityRenewsSharedDeadlineAndTimeoutReturnsPartialDraft() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let session = fixture.session
        let interaction = AgentAskUserInteraction(
            timeoutSeconds: 0.5,
            questions: [AgentAskUserQuestion(id: "notes", question: "Notes?", allowsCustom: true)]
        )
        defer { fixture.viewModel.cancelAskUserInteraction(tabID: session.tabID, interactionID: interaction.id) }
        session.pendingAskUser = AgentAskUserPendingState(interaction: interaction)
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                session.askUserContinuation = continuation
            } as AgentAskUserResponse
        }
        try await AsyncTestWait.waitUntil("question continuation installed", timeout: 2) {
            session.askUserContinuation != nil
        }
        fixture.viewModel.updateAskUserDraft(
            tabID: session.tabID, interactionID: interaction.id, questionID: "notes",
            draft: AgentAskUserDraft(customResponse: "unfinished draft")
        )
        // Start the short test budget only after asynchronous fixture preparation finishes.
        let deadline = DomainInteractionBroker.Deadline(
            deadline: Date().addingTimeInterval(1.3), renewalTimeoutSeconds: interaction.timeoutSeconds
        )
        let oldDeadline = try XCTUnwrap(deadline.acceptanceDeadline())
        session.askUserDeadline = deadline
        fixture.viewModel.noteAskUserCardActivity(tabID: session.tabID, interactionID: interaction.id)
        let renewed = try XCTUnwrap(deadline.acceptanceDeadline())
        XCTAssertGreaterThan(renewed, oldDeadline)
        let anchor = try XCTUnwrap(session.pendingAskUser?.timeoutStartedAt)
        XCTAssertEqual(anchor.addingTimeInterval(interaction.timeoutSeconds), renewed.addingTimeInterval(-1))
        let response = try await task.value
        XCTAssertTrue(response.timedOut)
        XCTAssertFalse(response.skipped)
        XCTAssertEqual(response.answersByQuestionID["notes"]?.answers, ["unfinished draft"])
        XCTAssertNil(session.pendingAskUser)
        XCTAssertNil(session.askUserDeadline)
    }

    func testCancelledCardIgnoresLaterActivity() async throws {
        let fixture = try await AgentRepromptTestFixture()
        defer { fixture.cleanUp() }
        let session = fixture.session
        let interaction = AgentAskUserInteraction(
            timeoutSeconds: 30,
            questions: [AgentAskUserQuestion(id: "notes", question: "Notes?", allowsCustom: true)]
        )
        defer { fixture.viewModel.cancelAskUserInteraction(tabID: session.tabID, interactionID: interaction.id) }
        let deadline = DomainInteractionBroker.Deadline(
            deadline: Date().addingTimeInterval(31), renewalTimeoutSeconds: 30
        )
        session.pendingAskUser = AgentAskUserPendingState(interaction: interaction)
        session.askUserDeadline = deadline
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                session.askUserContinuation = continuation
            } as AgentAskUserResponse
        }
        try await AsyncTestWait.waitUntil("question continuation installed", timeout: 2) {
            session.askUserContinuation != nil
        }
        XCTAssertTrue(fixture.viewModel.cancelAskUserInteraction(tabID: session.tabID, interactionID: interaction.id))
        let previous = deadline.acceptanceDeadline()
        fixture.viewModel.noteAskUserCardActivity(tabID: session.tabID, interactionID: interaction.id)
        XCTAssertEqual(deadline.acceptanceDeadline(), previous)
        XCTAssertNil(session.pendingAskUser)
        XCTAssertNil(session.askUserDeadline)
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Cancellation must not become a timeout result.
        }
    }
}
