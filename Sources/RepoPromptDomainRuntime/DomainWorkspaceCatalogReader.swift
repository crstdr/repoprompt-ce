import Foundation

/// Read-only access to the authoritative `workspace-catalog.json` that
/// `DomainPersistenceCoordinator` already writes.
///
/// Storage identity is a `workspaceID`, never the mutable display name. Renaming a workspace
/// updates its name but does not move its directory, so a name-derived path stops resolving
/// while this mapping stays correct.
///
/// Callers treat the mapping as a *candidate* rather than an authority (see
/// `WorkspaceStorageCatalog` in the app target): a stale or relocated entry degrades to the
/// name-derived path instead of failing, so this reader cannot introduce a new loss path.
package enum DomainWorkspaceCatalogReader {
    /// Only the fields needed to resolve a path. Dates and tombstones are deliberately not
    /// decoded so this reader cannot break when the writer changes its date strategy.
    private struct CatalogEntriesOnly: Decodable {
        struct Entry: Decodable {
            let workspaceID: UUID
            let fileURL: URL
        }

        let version: Int
        let entries: [Entry]
    }

    /// Mirrors `DomainPersistenceCoordinator.runtimeRoot`, which derives from the same inputs.
    package static func runtimeRoot(storageDirectory: URL, profileIdentifier: String) -> URL {
        let safe = profileIdentifier
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
            .prefix(48)
        let digest = DomainContentDigest.sha256(Data(profileIdentifier.utf8)).prefix(12)
        return storageDirectory
            .appendingPathComponent("DomainRuntime", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("\(safe)-\(digest)", isDirectory: true)
    }

    package static func catalogURL(storageDirectory: URL, profileIdentifier: String) -> URL {
        runtimeRoot(storageDirectory: storageDirectory, profileIdentifier: profileIdentifier)
            .appendingPathComponent("workspace-catalog.json")
    }

    /// The persisted `workspaceID -> workspace.json` mapping, or an empty map when the catalog
    /// is absent, unreadable, or written by a newer schema. Every failure degrades to "no
    /// opinion", which returns callers to today's name-derived behaviour.
    package static func fileURLsByWorkspaceID(
        storageDirectory: URL,
        profileIdentifier: String
    ) -> [UUID: URL] {
        let url = catalogURL(storageDirectory: storageDirectory, profileIdentifier: profileIdentifier)
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(CatalogEntriesOnly.self, from: data),
              catalog.version <= DomainWorkspaceCatalogSchema.version
        else { return [:] }

        return Dictionary(
            catalog.entries.map { ($0.workspaceID, $0.fileURL) },
            uniquingKeysWith: { _, latest in latest }
        )
    }
}

/// Shared schema version so the reader and the writing coordinator cannot drift apart.
package enum DomainWorkspaceCatalogSchema {
    package static let version = 1
}
