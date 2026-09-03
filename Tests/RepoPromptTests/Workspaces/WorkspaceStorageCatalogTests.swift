@testable import RepoPromptApp
import XCTest

/// Renaming a workspace updates its display name but never moves its directory, so the
/// name-derived path stops resolving and the workspace vanishes from the catalog load.
/// Resolution must fall back to the authority's persisted identity mapping.
final class WorkspaceStorageCatalogTests: XCTestCase {
    func testResolvesRenamedWorkspaceByIdentityWhenNameDerivedPathIsStale() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStorageCatalogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceID = UUID()
        let workspaceRoot = root.appendingPathComponent("Workspaces", isDirectory: true)
        // On disk under the *current* name; the index still carries the pre-rename name.
        let actualDirectory = workspaceRoot
            .appendingPathComponent("Workspace-renamed-\(workspaceID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
        let actualFile = actualDirectory.appendingPathComponent("workspace.json")
        try Data("{}".utf8).write(to: actualFile)

        let runtimeRoot = DomainWorkspaceCatalogReader.runtimeRoot(
            storageDirectory: root,
            profileIdentifier: "default"
        )
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let catalog = """
        {"version":1,"revision":1,"updatedAt":0,"deletions":[],"entries":[\
        {"workspaceID":"\(workspaceID.uuidString)","fileURL":"\(actualFile.absoluteString)"}]}
        """
        try Data(catalog.utf8).write(to: runtimeRoot.appendingPathComponent("workspace-catalog.json"))

        WorkspaceStorageCatalog.configure(storageDirectory: root, profileIdentifier: "default")

        let resolved = WorkspaceStorageCatalog.resolveWorkspaceFileURL(
            id: workspaceID,
            name: "stale-name",
            customStoragePath: nil,
            baseRoot: workspaceRoot
        )
        XCTAssertEqual(resolved.standardizedFileURL, actualFile.standardizedFileURL)

        // An identifier the catalog does not know still resolves to the name-derived creation
        // target, so new workspaces and healthy installs are unaffected.
        let unknownID = UUID()
        let unknown = WorkspaceStorageCatalog.resolveWorkspaceFileURL(
            id: unknownID,
            name: "fresh",
            customStoragePath: nil,
            baseRoot: workspaceRoot
        )
        XCTAssertEqual(
            unknown.deletingLastPathComponent().lastPathComponent,
            "Workspace-fresh-\(unknownID.uuidString)"
        )
    }
}
