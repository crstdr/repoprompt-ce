import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentComposerDraftRestorationTests: XCTestCase {
    func testCoalescedManualAndQueuedRecoveriesRestoreEachFragmentOnce() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        viewModel.storeDraftText(for: tabID, "D")

        viewModel.restoreRejectedManualSubmissionComposerState(
            tabID: tabID,
            session: session,
            draftText: "B",
            images: [],
            taggedFiles: [],
            selectedWorkflow: nil,
            selectedWorkflowMutationGeneration: nil,
            message: "Failed start"
        )
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "C",
            message: "Stopped queued work",
            strategy: .prependAlways
        )

        let finalEvent = try XCTUnwrap(viewModel.draftRestorationEvent)
        let operation = try XCTUnwrap(finalEvent.operation)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "C\nB\nD")
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                operation,
                to: "D",
                lastAppliedRestorationEventID: nil
            ),
            "C\nB\nD"
        )
    }

    func testConsumedRecoveryAndNewerTypingAreNotDuplicated() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "B",
            message: "Failed start",
            strategy: .prependAlways
        )
        let firstEvent = try XCTUnwrap(viewModel.draftRestorationEvent)
        let firstOperation = try XCTUnwrap(firstEvent.operation)
        let firstEditorText = AgentComposerDraftRestorationReducer.apply(
            firstOperation,
            to: "D",
            lastAppliedRestorationEventID: nil
        )
        XCTAssertEqual(firstEditorText, "B\nD")

        let editedText = firstEditorText + "\nnew typing"
        viewModel.storeDraftText(for: tabID, editedText)
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "C",
            message: "Stopped queued work",
            strategy: .prependAlways
        )
        let finalOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                finalOperation,
                to: editedText,
                lastAppliedRestorationEventID: firstEvent.id
            ),
            "C\nB\nD\nnew typing"
        )
    }

    func testSkippedIntermediateRecoveryStillAppliesOnlyMissingFragments() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")
        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)
        let firstEvent = try XCTUnwrap(viewModel.draftRestorationEvent)
        let firstOperation = try XCTUnwrap(firstEvent.operation)
        let firstEditorText = AgentComposerDraftRestorationReducer.apply(
            firstOperation,
            to: "D",
            lastAppliedRestorationEventID: nil
        )
        viewModel.restoreComposerDraft(tabID: tabID, text: "B", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: tabID, text: "C", message: "", strategy: .prependAlways)

        let finalOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                finalOperation,
                to: firstEditorText,
                lastAppliedRestorationEventID: firstEvent.id
            ),
            "C\nB\nA\nD"
        )
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Draft restoration tests must not start Codex")
            },
            headlessProviderFactory: { _, _ in
                UnsupportedHeadlessAgentProvider(reason: "draft restoration test")
            }
        )
    }
}
