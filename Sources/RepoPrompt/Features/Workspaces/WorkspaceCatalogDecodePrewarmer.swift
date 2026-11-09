import Foundation
import RepoPromptDomainRuntime

/// Constructed only from bytes whose digest was bound by the authority document.
struct WorkspaceCatalogDecodeInput {
    let digest: String
    let bytes: Data

    init(_ document: DomainWorkspaceDocument) {
        digest = document.contentDigest
        bytes = document.documentBytes
    }
}

enum WorkspaceCatalogDecodeOutcome: String {
    case resident, noncacheable, stored, evicted, synthesized, failed
}
