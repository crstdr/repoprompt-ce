import Foundation
@testable import RepoPromptApp
import RepoPromptFoundation
import XCTest

final class WorkspaceFileContextCatalogReconciliationBatchTests: XCTestCase {
    func testReconciliationScansBeyondServiceBatchLimit() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogReconciliationBatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for index in 0 ..< 260 {
            let folder = rootURL.appendingPathComponent(String(format: "folder-%03d", index), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try "initial\n".write(
                to: folder.appendingPathComponent("marker.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: root.id)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let tailPath = "folder-259/new.swift"
        try "struct NewlyFound {}\n".write(
            to: rootURL.appendingPathComponent(tailPath),
            atomically: true,
            encoding: .utf8
        )

        let deltas = await store.reconcileLoadedRootCatalogWithDisk(rootID: root.id)
        XCTAssertTrue(deltas.contains(.fileAdded(tailPath)))
        let cataloged = await store.file(rootID: root.id, relativePath: tailPath)
        XCTAssertNotNil(cataloged)
    }
}

@MainActor
final class CatalogFileExtensionInventoryTests: XCTestCase {
    func testHeavyRecountUsesAllLoadedLanguageInventoryWithoutEnumeratingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let primaryURL = directory.appendingPathComponent("primary")
        let hiddenURL = directory.appendingPathComponent("hidden")
        for url in [primaryURL, hiddenURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for name in ["main.SWIFT", "script.py", "README", "unknown.zzz"] {
            try "fixture".write(to: primaryURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for name in ["app.ts", "more.py"] {
            try "fixture".write(to: hiddenURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let primary = try await store.loadRoot(path: primaryURL.path)
        let hidden = try await store.loadRoot(path: hiddenURL.path, kind: .sessionWorktree)
        addTeardownBlock {
            await store.unloadRoot(id: primary.id)
            await store.unloadRoot(id: hidden.id)
            try? FileManager.default.removeItem(at: directory)
        }
        // Capture the previous implementation's result before resetting counters.
        let primaryFiles = await store.files(inRoot: primary.id)
        let hiddenFiles = await store.files(inRoot: hidden.id)
        let expectedLanguages = Set((primaryFiles + hiddenFiles).compactMap {
            SyntaxManager.shared.extensionToLanguage[($0.name as NSString).pathExtension.lowercased()]
        })
        XCTAssertFalse(expectedLanguages.isEmpty)
        let manager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let git = GitViewModel(fileManager: manager, gitContextRefreshIntervalNanoseconds: 0)
        let counter = TokenCountingViewModel()
        counter.suspendAutomaticRecounts()
        counter.configure(
            fileManager: manager,
            gitViewModel: git,
            getPromptText: { "" },
            getSelectedInstructionsText: { "" },
            getSettings: { .init(fileTreeOption: .none, codeMapUsage: .none, filePathDisplayOption: .relative, includeFilesInClipboard: false, duplicateUserInstructionsAtTop: false, onlyIncludeRootsWithSelectedFiles: false, codeMapsGloballyDisabled: true) },
            getCopyContext: { .init(includeFiles: false, includeUserPrompt: false, includeMetaPrompts: false, includeFileTree: false, fileTreeMode: .none, codeMapUsage: .none, gitInclusion: .none, duplicateUserInstructionsAtTop: false) },
            getStoredSelection: { StoredSelection() }
        )
        await store.resetFilesInRootRequestCountForTesting()
        await counter.forceImmediateRecount()
        XCTAssertEqual(counter.scannedLanguages, expectedLanguages)
        let enumerations = await store.fileEnumerationRequestCountForTesting()
        XCTAssertEqual(enumerations, 0)
        let extensions = await store.allLoadedFileExtensions()
        XCTAssertEqual(extensions, ["swift", "py", "ts", "", "zzz"])
    }

    func testManagedOnlyFileStaysExcludedAcrossRepeatedAddsAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "*.toml\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: directory.path)
        addTeardownBlock {
            await store.unloadRoot(id: root.id)
            try? FileManager.default.removeItem(at: directory)
        }
        let before = await store.allLoadedFileExtensions()
        try "fixture".write(to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        _ = try await store.materializeCatalogFileAfterDiskWrite(rootID: root.id, relativePath: "config.toml")
        let managed = await store.allLoadedFileExtensions()
        XCTAssertEqual(managed, before)
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(rootID: root.id, deltas: [.fileAdded("config.toml")])
        // Ignored add events are rejected by the existing catalog preflight;
        // exact managed-only materialization must not become discovery.
        let afterAdd = await store.allLoadedFileExtensions()
        XCTAssertEqual(afterAdd, before)
        let discoverable = await store.files(inRoot: root.id)
        XCTAssertFalse(discoverable.contains { $0.name == "config.toml" })
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(rootID: root.id, deltas: [.fileRemoved("config.toml")])
        let removed = await store.allLoadedFileExtensions()
        XCTAssertEqual(removed, before)
    }

    func testInventoryTracksUpsertsLastExtensionRemovalAndRootUnload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for path in ["first.swift", "second.swift", "nested/script.py"] {
            try "fixture".write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await store.loadRoot(path: directory.path)
        addTeardownBlock {
            await store.unloadRoot(id: root.id)
            try? FileManager.default.removeItem(at: directory)
        }
        try "fixture".write(to: directory.appendingPathComponent("new.rs"), atomically: true, encoding: .utf8)
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(rootID: root.id, deltas: [.fileAdded("first.swift"), .fileAdded("new.rs"), .fileRemoved("second.swift")])
        let afterUpsert = await store.allLoadedFileExtensions()
        XCTAssertEqual(afterUpsert, ["swift", "py", "rs"])
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(rootID: root.id, deltas: [.fileRemoved("first.swift"), .folderRemoved("nested")])
        let afterRemoval = await store.allLoadedFileExtensions()
        XCTAssertEqual(afterRemoval, ["rs"])
        await store.unloadRoot(id: root.id)
        let afterUnload = await store.allLoadedFileExtensions()
        XCTAssertEqual(afterUnload, [])
    }
}
