import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class ReviewPromptPackagingTests: XCTestCase {
    func testReviewPresetPackagesTabFreeCanonicalSystemPrompt() async throws {
        let storage = ReviewPromptStorageSpy(loadResult: .success([]))
        let viewModel = ReviewPromptTestSupport.makeViewModel(storage: storage)
        let canonical = try XCTUnwrap(
            viewModel.storedPrompts.first(where: { $0.id == ReviewPromptTestFixtures.reviewID })
        )

        let message = await viewModel.packagePrompt(
            conversation: [ConversationEntry(role: .user, content: "Review these changes")],
            overridePromptConfig: promptConfig(storedPromptIDs: [ReviewPromptTestFixtures.reviewID]),
            overrideChatPreset: .BuiltIn.review,
            overrideMode: .review,
            gitInclusionOverride: .none,
            selectionOverride: StoredSelection(codemapAutoEnabled: false),
            lookupContextOverride: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        )

        XCTAssertFalse(canonical.content.contains("\t"))
        XCTAssertTrue(message.systemPrompt.hasPrefix(canonical.content + "\n\n"))
        XCTAssertFalse(message.systemPrompt.contains("\t"))
    }

    func testPackagingPreservesArbitraryTabbedPromptsAndSelectedArtifacts() async throws {
        let storage = ReviewPromptStorageSpy(loadResult: .success([]))
        let viewModel = ReviewPromptTestSupport.makeViewModel(storage: storage)
        let customPrompt = viewModel.addStoredPrompt(
            title: "Custom tab semantics",
            content: "Keep\tthis custom prompt byte-exact."
        )
        let customPreset = ChatPreset(
            name: "Custom tab semantics",
            mode: .chat,
            storedPromptIds: [customPrompt.id],
            useStoredPromptsAsSystem: true
        )

        let customSystemMessage = await viewModel.packagePrompt(
            conversation: [ConversationEntry(role: .user, content: "Use the custom prompt")],
            overridePromptConfig: promptConfig(storedPromptIDs: [customPrompt.id]),
            overrideChatPreset: customPreset,
            overrideMode: .chat,
            gitInclusionOverride: .none,
            selectionOverride: StoredSelection(codemapAutoEnabled: false),
            lookupContextOverride: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        )

        XCTAssertTrue(customSystemMessage.systemPrompt.hasPrefix(customPrompt.content + "\n\n"))
        XCTAssertTrue(customSystemMessage.systemPrompt.contains("\t"))

        let artifactCases = [
            (name: "Source.ts", content: "const\tvalue = 1"),
            (name: "Makefile", content: "build:\n\ttool --flag"),
            (name: "table.tsv", content: "left\tright\n1\t2"),
            (name: "parser.fixture", content: "fixture\tvalue")
        ]
        let rootID = UUID()
        let entries = artifactCases.map { artifact in
            ResolvedPromptFileEntry(
                file: WorkspaceFileRecord(
                    rootID: rootID,
                    name: artifact.name,
                    relativePath: artifact.name,
                    fullPath: "/repo/\(artifact.name)",
                    parentFolderID: nil
                ),
                loadedContent: artifact.content,
                rootFolderPath: "/repo"
            )
        }
        let fileBlocks = PromptPackagingService.generatePartitionedFileBlocks(
            entries,
            filePathDisplay: .relative,
            codemapSnapshotBundle: .empty
        ).contentBlocks
        let gitDiff = "diff --git a/Source.ts b/Source.ts\n+const\tvalue = 1"
        let metaPrompt = MetaInstruction(title: "Custom", content: "meta\tvalue")
        let userContent = "user\trequest"
        let message = PromptPackagingService.buildAIMessage(
            systemPrompt: customPrompt.content,
            metaInstructions: [metaPrompt],
            fileTree: "root\tmap",
            fileContents: fileBlocks,
            gitDiff: gitDiff,
            conversation: [ConversationEntry(role: .user, content: userContent)],
            temperature: nil,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: []
        )

        XCTAssertEqual(message.systemPrompt, customPrompt.content)
        XCTAssertEqual(message.gitDiff, gitDiff)
        XCTAssertEqual(fileBlocks.count, artifactCases.count)
        for artifact in artifactCases {
            let block = try XCTUnwrap(fileBlocks.first(where: { $0.contains("File: \(artifact.name)\n") }))
            XCTAssertTrue(block.contains(artifact.content), artifact.name)
        }
        let packagedMeta = try XCTUnwrap(message.metaPrompts.first)
        let packagedUser = try XCTUnwrap(message.conversationMessages.first)
        XCTAssertTrue(packagedMeta.contains(metaPrompt.content))
        XCTAssertTrue(packagedUser.content.contains(userContent))

        let tail = message.buildTail(embedSystemPrompt: false)
        XCTAssertTrue(tail.contains("root\tmap"))
        XCTAssertTrue(tail.contains(gitDiff))
        XCTAssertTrue(tail.contains(metaPrompt.content))
        for artifact in artifactCases {
            XCTAssertTrue(tail.contains(artifact.content), artifact.name)
        }
    }

    private func promptConfig(storedPromptIDs: [UUID]) -> PromptContextResolved {
        PromptContextResolved(
            includeFiles: false,
            includeUserPrompt: true,
            includeMetaPrompts: false,
            includeFileTree: false,
            fileTreeMode: .none,
            codeMapUsage: .none,
            gitInclusion: .none,
            storedPromptIds: storedPromptIDs
        )
    }
}
