import Foundation
import RepoPromptDomainRuntime

/// Resolves a workspace's `workspace.json` without deriving storage identity from the mutable
/// display name.
///
/// Renaming a workspace updates its name but never moves its directory, so the name-derived
/// path stops resolving and the workspace disappears from the catalog load. Windows bound to it
/// then fall back to Default, and that degraded layout gets written back over the window
/// session snapshot.
///
/// Resolution is an ordered list of candidates, first existing wins:
///
///   1. the per-workspace storage override (unchanged precedence),
///   2. the name-derived path, so a healthy install behaves exactly as before,
///   3. the domain authority's persisted `workspaceID -> workspace.json` mapping.
///
/// Checking the name-derived path before the catalog keeps a relocated storage root working
/// (catalog entries are absolute paths) and means a stale catalog can never win over a real
/// directory. When nothing exists the name-derived path is returned as the creation target,
/// which preserves today's behaviour for new workspaces.
///
/// The mapping is read once per process. It is a lookup table, never a directory scan — the
/// reverted `WorkspaceStorageDirectoryResolver` enumerated a 15k-entry root per lookup on every
/// launch, which is what regressed startup.
enum WorkspaceStorageCatalog {
    private static let lock = NSLock()
    private static var location: (storageDirectory: URL, profileIdentifier: String)?
    private static var cachedFileURLsByID: [UUID: URL]?
    private static var cachedModificationDate: Date?

    /// Binds the catalog to the domain runtime's storage location. Called once during app
    /// composition; until then resolution is purely name-derived.
    static func configure(storageDirectory: URL, profileIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        location = (storageDirectory, profileIdentifier)
        cachedFileURLsByID = nil
        cachedModificationDate = nil
    }

    /// The authoritative path for `workspaceID`, or nil when the catalog has no opinion.
    ///
    /// Reached only after the name-derived path has already missed, so a healthy install never
    /// gets here. The cached map is revalidated against the catalog file's modification date,
    /// which costs one `stat` on that miss path and keeps a workspace created or renamed during
    /// this session resolvable - a stale map would otherwise send the rename to a fresh
    /// directory and split its storage.
    static func authoritativeFileURL(for workspaceID: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let location else { return nil }

        let url = DomainWorkspaceCatalogReader.catalogURL(
            storageDirectory: location.storageDirectory,
            profileIdentifier: location.profileIdentifier
        )
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate

        if cachedFileURLsByID == nil || modified != cachedModificationDate {
            let loaded = DomainWorkspaceCatalogReader.fileURLsByWorkspaceID(
                storageDirectory: location.storageDirectory,
                profileIdentifier: location.profileIdentifier
            )
            // Never memoize an empty read. The first lookup can land before the authority has
            // written the catalog, and caching that would disable identity resolution for the
            // whole session - on the upgrade launch that needs it most.
            guard !loaded.isEmpty else { return nil }
            cachedFileURLsByID = loaded
            cachedModificationDate = modified
        }
        return cachedFileURLsByID?[workspaceID]
    }

    static func resolveWorkspaceFileURL(
        id: UUID,
        name: String,
        customStoragePath: URL?,
        baseRoot: URL
    ) -> URL {
        if let customStoragePath {
            return customStoragePath.appendingPathComponent("workspace.json")
        }

        let derived = baseRoot
            .appendingPathComponent(
                DomainWorkspaceStoragePath.directoryName(name: name, id: id),
                isDirectory: true
            )
            .appendingPathComponent("workspace.json")
        if FileManager.default.fileExists(atPath: derived.path) { return derived }

        if let authoritative = authoritativeFileURL(for: id),
           FileManager.default.fileExists(atPath: authoritative.path)
        {
            return authoritative
        }

        return derived
    }

    static func resolveWorkspaceDirectory(
        id: UUID,
        name: String,
        customStoragePath: URL?,
        baseRoot: URL
    ) -> URL {
        if let customStoragePath { return customStoragePath }
        return resolveWorkspaceFileURL(
            id: id,
            name: name,
            customStoragePath: nil,
            baseRoot: baseRoot
        ).deletingLastPathComponent()
    }
}
