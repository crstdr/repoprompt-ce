import CryptoKit
import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class StoredPromptPersistenceBoundaryTests: XCTestCase {
    func testReviewCanonicalAndPredecessorByteFingerprints() throws {
        let storage = ReviewPromptStorageSpy(loadResult: .success([]))
        let viewModel = ReviewPromptTestSupport.makeViewModel(storage: storage)
        let canonical = try reviewRecord(in: viewModel.storedPrompts)

        assertFingerprint(
            canonical.content,
            characters: 1740,
            lines: 31,
            tabs: 0,
            sha256: "dd2b76428e020f92c23a14f6e03b92db067e8d3e73b5fe02a4f3d018b64e1d27"
        )
        assertFingerprint(
            ReviewPromptTestFixtures.legacyV1,
            characters: 1547,
            lines: 41,
            tabs: 21,
            sha256: "942fb763e8dd9c6c3227656f25137cd27f9dc97d367aa880cf96d734ce9bbaa5"
        )
        assertFingerprint(
            ReviewPromptTestFixtures.preFixV2,
            characters: 1710,
            lines: 31,
            tabs: 10,
            sha256: "80d17ed6e6863c9eae7dff113394d5ff39577e2a4a07e25a229c9bb27b417921"
        )

        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        XCTAssertEqual(composed, decomposed, "Swift String equality is canonically equivalent")
        XCTAssertFalse(PromptViewModel.hasIdenticalUTF8Bytes(composed, decomposed))
    }

    func testExactReviewPredecessorsMigrateAndResetEditedFlag() throws {
        let baseline = ReviewPromptTestSupport.canonicalBuiltIns()
        let canonical = try reviewRecord(in: baseline)
        let cases = [
            (label: "RCA-observed legacy", content: ReviewPromptTestFixtures.legacyV1),
            (label: "immediately previous canonical", content: ReviewPromptTestFixtures.preFixV2)
        ]

        for testCase in cases {
            var loaded = baseline
            let index = try XCTUnwrap(loaded.firstIndex(where: { $0.id == ReviewPromptTestFixtures.reviewID }))
            loaded[index] = PromptViewModel.StoredPrompt(
                id: ReviewPromptTestFixtures.reviewID,
                title: "[Review]",
                content: testCase.content,
                isUserEdited: true
            )
            let storage = ReviewPromptStorageSpy(loadResult: .success(loaded))
            let viewModel = ReviewPromptTestSupport.makeViewModel(storage: storage)
            let migrated = try reviewRecord(in: viewModel.storedPrompts)

            XCTAssertTrue(
                PromptViewModel.hasIdenticalUTF8Bytes(migrated.content, canonical.content),
                testCase.label
            )
            XCTAssertFalse(migrated.isUserEdited, testCase.label)
            XCTAssertEqual(storage.savedSnapshots.count, 1, testCase.label)
            let saved = try reviewRecord(in: storage.savedSnapshots[0])
            XCTAssertTrue(
                PromptViewModel.hasIdenticalUTF8Bytes(saved.content, canonical.content),
                testCase.label
            )
            XCTAssertFalse(saved.isUserEdited, testCase.label)
        }
    }

    func testReviewMigrationPreservesNonAllowlistedContent() throws {
        struct NearMatch {
            let label: String
            let record: PromptViewModel.StoredPrompt
            let expectedSaveCount: Int
            let expectedEditedFlag: Bool
            let replacesBuiltIn: Bool
        }

        let baseline = ReviewPromptTestSupport.canonicalBuiltIns()
        let differentID = try XCTUnwrap(UUID(uuidString: "A3BC7D58-D3F2-4B15-A215-B268237398C1"))
        let cases = [
            NearMatch(
                label: "different UUID",
                record: .init(
                    id: differentID,
                    title: "[Review]",
                    content: ReviewPromptTestFixtures.legacyV1
                ),
                expectedSaveCount: 1,
                expectedEditedFlag: false,
                replacesBuiltIn: false
            ),
            NearMatch(
                label: "changed title",
                record: .init(
                    id: ReviewPromptTestFixtures.reviewID,
                    title: "[Review ]",
                    content: ReviewPromptTestFixtures.legacyV1
                ),
                expectedSaveCount: 1,
                expectedEditedFlag: true,
                replacesBuiltIn: true
            ),
            NearMatch(
                label: "one-byte body change already marked edited",
                record: .init(
                    id: ReviewPromptTestFixtures.reviewID,
                    title: "[Review]",
                    content: ReviewPromptTestFixtures.preFixV2 + "!",
                    isUserEdited: true
                ),
                expectedSaveCount: 0,
                expectedEditedFlag: true,
                replacesBuiltIn: true
            ),
            NearMatch(
                label: "CRLF variant",
                record: .init(
                    id: ReviewPromptTestFixtures.reviewID,
                    title: "[Review]",
                    content: ReviewPromptTestFixtures.legacyV1.replacingOccurrences(of: "\n", with: "\r\n")
                ),
                expectedSaveCount: 1,
                expectedEditedFlag: true,
                replacesBuiltIn: true
            ),
            NearMatch(
                label: "removed loose phrase fingerprint",
                record: .init(
                    id: ReviewPromptTestFixtures.reviewID,
                    title: "[Review]",
                    content: "Acknowledge what's done particularly well\nAre the commit boundaries logical?"
                ),
                expectedSaveCount: 1,
                expectedEditedFlag: true,
                replacesBuiltIn: true
            )
        ]

        for testCase in cases {
            var loaded = baseline
            if testCase.replacesBuiltIn {
                let index = try XCTUnwrap(loaded.firstIndex(where: { $0.id == ReviewPromptTestFixtures.reviewID }))
                loaded[index] = testCase.record
            } else {
                loaded.removeAll(where: { $0.id == ReviewPromptTestFixtures.reviewID })
                loaded.append(testCase.record)
            }

            let storage = ReviewPromptStorageSpy(loadResult: .success(loaded))
            let viewModel = ReviewPromptTestSupport.makeViewModel(storage: storage)
            let preserved = try XCTUnwrap(viewModel.storedPrompts.first(where: { $0.id == testCase.record.id }))

            XCTAssertTrue(
                PromptViewModel.hasIdenticalUTF8Bytes(preserved.title, testCase.record.title),
                testCase.label
            )
            XCTAssertTrue(
                PromptViewModel.hasIdenticalUTF8Bytes(preserved.content, testCase.record.content),
                testCase.label
            )
            XCTAssertEqual(preserved.isUserEdited, testCase.expectedEditedFlag, testCase.label)
            XCTAssertEqual(storage.savedSnapshots.count, testCase.expectedSaveCount, testCase.label)

            if let savedSnapshot = storage.savedSnapshots.first {
                let saved = try XCTUnwrap(savedSnapshot.first(where: { $0.id == testCase.record.id }))
                XCTAssertTrue(
                    PromptViewModel.hasIdenticalUTF8Bytes(saved.title, testCase.record.title),
                    testCase.label
                )
                XCTAssertTrue(
                    PromptViewModel.hasIdenticalUTF8Bytes(saved.content, testCase.record.content),
                    testCase.label
                )
                XCTAssertEqual(saved.isUserEdited, testCase.expectedEditedFlag, testCase.label)
            }

            if !testCase.replacesBuiltIn {
                let canonical = try reviewRecord(in: viewModel.storedPrompts)
                XCTAssertFalse(canonical.isUserEdited, testCase.label)
                XCTAssertNotEqual(canonical.id, testCase.record.id, testCase.label)
            }
        }
    }

    func testCanonicalReviewIsIdempotentAndLoadFailureDoesNotSave() throws {
        let baseline = ReviewPromptTestSupport.canonicalBuiltIns()
        let canonicalStorage = ReviewPromptStorageSpy(loadResult: .success(baseline))
        let canonicalViewModel = ReviewPromptTestSupport.makeViewModel(storage: canonicalStorage)
        let canonical = try reviewRecord(in: canonicalViewModel.storedPrompts)

        XCTAssertFalse(canonical.isUserEdited)
        XCTAssertTrue(canonicalStorage.savedSnapshots.isEmpty)

        let failedStorage = ReviewPromptStorageSpy(loadResult: .failure(ReviewPromptTestError.loadFailed))
        let failedViewModel = ReviewPromptTestSupport.makeViewModel(storage: failedStorage)

        XCTAssertTrue(failedViewModel.storedPrompts.isEmpty)
        XCTAssertTrue(failedStorage.savedSnapshots.isEmpty)
    }

    private func reviewRecord(
        in prompts: [PromptViewModel.StoredPrompt]
    ) throws -> PromptViewModel.StoredPrompt {
        try XCTUnwrap(prompts.first(where: { $0.id == ReviewPromptTestFixtures.reviewID }))
    }

    private func assertFingerprint(
        _ content: String,
        characters: Int,
        lines: Int,
        tabs: Int,
        sha256 expectedSHA256: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(content.count, characters, file: file, line: line)
        XCTAssertEqual(content.components(separatedBy: "\n").count, lines, file: file, line: line)
        XCTAssertEqual(content.filter { $0 == "\t" }.count, tabs, file: file, line: line)
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expectedSHA256, file: file, line: line)
    }
}

enum ReviewPromptTestFixtures {
    static let reviewID = UUID(uuidString: "D7F1B2E4-3C5A-6B8D-CF8E-1F5D0E2A4C6B")!

    static let legacyV1 = """
    You are reviewing code changes with git diffs included in the prompt. Focus on ensuring the changes are sound, clean, intentional, and void of regressions.

    **Primary Review Goals:**

    1. **Verify Change Correctness**:
    \t- Confirm the changes achieve their intended purpose
    \t- Check for unintended side effects or regressions
    \t- Validate edge cases are handled properly
    \t- Ensure error paths are covered

    2. **Code Quality & Cleanliness**:
    \t- Is the code readable and self-documenting?
    \t- Are the changes minimal and focused?
    \t- Do they follow existing patterns in the codebase?
    \t- Are there any code smells or anti-patterns?

    3. **Intentionality Check**:
    \t- Does every change have a clear purpose?
    \t- Are there any accidental modifications?
    \t- Is there dead code being introduced?
    \t- Are the commit boundaries logical?

    4. **Potential Issues to Flag**:
    \t- Performance degradations
    \t- Security vulnerabilities
    \t- Race conditions or concurrency issues
    \t- Resource leaks (memory, file handles, etc.)
    \t- Breaking changes to internal APIs

    5. **Constructive Suggestions**:
    \t- Alternative approaches that might be cleaner
    \t- Opportunities to reduce complexity
    \t- Missing test coverage for critical paths
    \t- Documentation gaps for complex logic

    **Review Format:**
    - Start with a summary of what the changes accomplish
    - List any critical issues that must be addressed
    - Note minor improvements that would enhance quality

    Remember: The git diff shows what changed, and the file contents show the full context. Use both to understand the complete picture.
    """

    static let preFixV2 = """
    You are reviewing code changes with git diffs included in the prompt. The git diff shows what changed; the file contents show full context. Use both.

    **Review Criteria:**

    1. **Correctness & Safety**:
    \t- Do the changes achieve their intended purpose without regressions?
    \t- Are edge cases and error paths handled?
    \t- Any security vulnerabilities, race conditions, or resource leaks?
    \t- Any breaking changes to APIs or contracts?

    2. **Design & Complexity**:
    \t- Do changes increase coupling or reduce separation of concerns?
    \t- Is new complexity justified, or can the same result be achieved more simply?
    \t- Are there DRY violations — duplicated logic that should be extracted?
    \t- Do abstractions sit at the right level (not too early, not too late)?

    3. **Intentionality**:
    \t- Does every change have a clear purpose? Flag accidental modifications or dead code.
    \t- Are the changes minimal and focused, or is scope creeping in?

    **Severity Levels — be disciplined about classification:**
    - **P0 (Must fix)**: Bugs, data loss, security holes, crashes — things that break correctness.
    - **P1 (Should fix)**: Design issues that will compound — poor separation of concerns, growing complexity, DRY violations, missing error handling for reachable paths.
    - **P2 (Consider)**: Style, naming, minor refactoring opportunities, test coverage gaps.

    Most findings should be P1 or P2. Reserve P0 for genuinely broken behavior.

    **Output Format:**
    1. One-paragraph summary of what the changes accomplish.
    2. Findings grouped by severity (P0 → P1 → P2), each with: file reference, what's wrong, and a concrete suggestion. Omit empty severity groups.
    3. If no issues found at a severity level, skip it — don't pad the review.
    """
}

enum ReviewPromptTestError: Error {
    case loadFailed
}

final class ReviewPromptStorageSpy: PromptStorage {
    var loadResult: Result<[PromptViewModel.StoredPrompt], Error>
    var savedSnapshots: [[PromptViewModel.StoredPrompt]] = []

    init(loadResult: Result<[PromptViewModel.StoredPrompt], Error>) {
        self.loadResult = loadResult
        super.init()
    }

    override func loadPrompts() -> Result<[PromptViewModel.StoredPrompt], Error> {
        loadResult
    }

    override func savePrompts(
        _ prompts: [PromptViewModel.StoredPrompt],
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        savedSnapshots.append(prompts)
        completion?(.success(()))
    }
}

@MainActor
enum ReviewPromptTestSupport {
    private static var nextWindowID = -98100

    static func makeViewModel(storage: PromptStorage) -> PromptViewModel {
        defer { nextWindowID -= 1 }
        let secureService = SecureKeysService(secureStorage: TestSecureStorageBackend(values: [:]))
        let keyManager = KeyManager(secureService: secureService)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        return PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            apiSettingsViewModel: apiSettings,
            windowID: nextWindowID,
            settingsManager: WindowSettingsManager(windowID: nextWindowID),
            promptStorage: storage
        )
    }

    static func canonicalBuiltIns() -> [PromptViewModel.StoredPrompt] {
        let storage = ReviewPromptStorageSpy(loadResult: .success([]))
        return makeViewModel(storage: storage).storedPrompts
    }
}
