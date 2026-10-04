import Combine
import Foundation
import RepoPromptDomainRuntime

/// Shared by existing menu callers and the authority-backed chooser; ranking is unchanged.
enum WorkspaceMenuPolicy {
    static func items(in workspaces: [WorkspaceModel], query: WorkspaceMenuQuery = .init()) -> [WorkspaceModel] {
        var items = workspaces
        if !query.includeSystem { items = items.filter { !$0.isSystemWorkspace } }
        if !query.includeHidden { items = items.filter { !$0.isHiddenInMenus } }
        if !query.includeTemporary { items = items.filter { !$0.isTemporaryWorkspace } }
        if query.sortMostRecentFirst { items = WorkspaceRecentOrdering.sorted(items) }
        return items
    }
}

enum WorkspaceChooserQuery: Equatable {
    enum Collection: Equatable {
        case saved, temporary
    }

    case compact(maxRecent: Int)
    case expanded(collection: Collection, searchText: String)

    var collection: Collection? {
        if case let .expanded(collection, _) = self { return collection }
        return nil
    }

    var rawSearchText: String {
        if case let .expanded(_, text) = self { return text }
        return ""
    }

    var trimmedSearchText: String {
        rawSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func applying(to presentation: WorkspaceChooserPresentation) -> WorkspaceChooserPresentation {
        guard case let .ready(catalog, refresh) = presentation else { return presentation }
        let rows: [WorkspaceModel]
        switch self {
        case let .compact(maxRecent):
            rows = Array(WorkspaceMenuPolicy.items(in: catalog.workspaces).prefix(maxRecent))
        case let .expanded(collection, _):
            let search = trimmedSearchText
            rows = WorkspaceMenuPolicy.items(in: catalog.workspaces, query: .init(includeTemporary: true)).filter {
                $0.isTemporaryWorkspace == (collection == .temporary)
                    && (
                        search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                            || $0.repoPaths.contains { $0.localizedCaseInsensitiveContains(search) }
                    )
            }
        }
        return .ready(.init(workspaces: rows, source: catalog.source), refresh: refresh)
    }
}

#if DEBUG
    /// Inputs consumed at the actual results branch, never reconstructed from manager getters.
    struct WorkspaceChooserConsumption: Equatable {
        enum Kind: Equatable { case loading, failed, ready }
        enum Layout: Equatable { case compact, expanded }
        enum Collection: Equatable { case recent, saved, temporary }
        let kind: Kind
        let orderedIDs: [UUID]
        let query: WorkspaceChooserQuery
        let source: WorkspaceChooserCatalog.Source?
        let failure: WorkspaceChooserFailure?

        var layout: Layout {
            if case .compact = query { return .compact }
            return .expanded
        }

        var collection: Collection {
            switch query {
            case .compact: .recent
            case .expanded(collection: .saved, searchText: _): .saved
            case .expanded(collection: .temporary, searchText: _): .temporary
            }
        }

        var rawQuery: String {
            query.rawSearchText
        }

        var trimmedQuery: String {
            query.trimmedSearchText
        }

        var failureID: UUID? {
            failure?.id
        }

        var recovery: WorkspaceChooserRecovery {
            failure?.recovery ?? .idle
        }
    }
#endif

/// Coherent workspace-chooser state owned by `WorkspaceManagerViewModel` (#1142). Loading and
/// failure carry no rows, so constructor-loaded legacy membership can never read as accepted.
enum WorkspaceChooserPresentation: Equatable {
    case loading
    case failed(WorkspaceChooserFailure)
    /// `ready` means the rows are usable; an incomplete authority stamp always carries a failed refresh.
    case ready(WorkspaceChooserCatalog, refresh: WorkspaceChooserRefresh)

    var failure: WorkspaceChooserFailure? {
        switch self {
        case .loading, .ready(_, refresh: .current): nil
        case let .failed(failure), let .ready(_, refresh: .failed(failure)): failure
        }
    }
}

/// Stores full, current clearance witnesses without invalidating the chooser for witness-only reports.
/// Real changes retain @Published's synchronous preassignment delivery; newer reentrant writes win.
@MainActor
@propertyWrapper
final class WorkspaceChooserPublication {
    private var value: WorkspaceChooserPresentation
    private let publications: CurrentValueSubject<WorkspaceChooserPresentation, Never>
    private var writeGeneration: UInt64 = 0

    init(wrappedValue: WorkspaceChooserPresentation) {
        value = wrappedValue
        publications = CurrentValueSubject(wrappedValue)
    }

    @available(*, unavailable, message: "Use on an ObservableObject instance")
    var wrappedValue: WorkspaceChooserPresentation {
        get { fatalError() }
        set { fatalError() }
    }

    var projectedValue: AnyPublisher<WorkspaceChooserPresentation, Never> {
        Deferred { [self] in
            var initial = true
            return publications.map { [weak self] publication in
                // The subject's last emission may predate a silent witness update.
                if initial {
                    initial = false
                    return self?.value ?? publication
                }
                return publication
            }.eraseToAnyPublisher()
        }.eraseToAnyPublisher()
    }

    static subscript<Owner: ObservableObject>(
        _enclosingInstance owner: Owner,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Owner, WorkspaceChooserPresentation>,
        storage storageKeyPath: ReferenceWritableKeyPath<Owner, WorkspaceChooserPublication>
    ) -> WorkspaceChooserPresentation where Owner.ObjectWillChangePublisher == ObservableObjectPublisher {
        get { owner[keyPath: storageKeyPath].value }
        set {
            let storage = owner[keyPath: storageKeyPath]
            storage.writeGeneration += 1
            let generation = storage.writeGeneration
            // Compare to the announced value, which can lead the getter during synchronous delivery.
            if !storage.publications.value.hasEquivalentUI(to: newValue) {
                owner.objectWillChange.send()
                guard generation == storage.writeGeneration else { return }
                storage.publications.send(newValue)
            }
            guard generation == storage.writeGeneration else { return }
            storage.value = newValue
        }
    }
}

private extension WorkspaceChooserPresentation {
    func hasEquivalentUI(to other: Self) -> Bool {
        func equivalent(_ lhs: WorkspaceChooserFailure, _ rhs: WorkspaceChooserFailure) -> Bool {
            lhs.kind == rhs.kind && lhs.recovery == rhs.recovery
        }
        switch (self, other) {
        case (.loading, .loading): return true
        case let (.failed(lhs), .failed(rhs)): return equivalent(lhs, rhs)
        case let (.ready(lhs, lhsRefresh), .ready(rhs, rhsRefresh)):
            guard lhs == rhs else { return false }
            switch (lhsRefresh, rhsRefresh) {
            case (.current, .current): return true
            case let (.failed(lhs), .failed(rhs)): return equivalent(lhs, rhs)
            default: return false
            }
        default: return false
        }
    }
}

struct WorkspaceChooserCatalog: Equatable {
    enum Source: Equatable {
        case local
        case authority(WorkspaceChooserAcceptanceStamp)
    }

    var workspaces: [WorkspaceModel]
    let source: Source

    /// Applies one admitted local mutation (`old` → `new`) to retained rows: touched IDs update or
    /// leave, locally added IDs join, and untouched rows (even if absent from both) are kept, so a
    /// local edit can never smuggle in membership from an incomplete reconciliation.
    mutating func applyLocalDelta(from old: [WorkspaceModel], to new: [WorkspaceModel]) {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let retainedIDs = Set(workspaces.map(\.id))
        workspaces = workspaces.compactMap { row in
            oldByID[row.id] == newByID[row.id] ? row : newByID[row.id]
        } + new.filter { oldByID[$0.id] == nil && !retainedIDs.contains($0.id) }
    }
}

enum WorkspaceChooserRefresh: Equatable {
    case current
    case failed(WorkspaceChooserFailure)
}

/// Identifies the accepted reconciliation whose rows a ready authority catalog shows.
struct WorkspaceChooserAcceptanceStamp: Equatable {
    let publicationSequence: UInt64
    let catalogRevision: UInt64
    let reconciliationGeneration: UInt64
    let isComplete: Bool
}

struct WorkspaceChooserFailure: Equatable {
    enum Kind: Equatable {
        case notBootstrapped
        case authorityUnavailable(DomainAuthorityHealth)
        case unavailableMembers(Set<UUID>)
        /// Diagnostic for logs/tests only; never rendered.
        case modelProjection(String)
        case catalogChangedDuringRefresh
    }

    /// Stable across equivalent reports so identity churn does not republish equal content.
    let id: UUID
    let kind: Kind
    let publicationSequence: UInt64
    let catalogRevision: UInt64
    /// Report version of the latest equivalent report; clearance must match the version.
    var reportVersion: UInt64 = 0
    /// Actual (possibly deduplicated) legacy projection issue published for this report.
    var legacyIssue: DomainProjectionIssueWitness?
    var recovery: WorkspaceChooserRecovery = .idle
}

/// A `.projectionFailure` issue as it stood: ID plus the report generation, which advances on every
/// report even when the issue publisher deduplicates content and keeps the existing ID.
struct DomainProjectionIssueWitness: Equatable {
    let issueID: UUID
    let reportGeneration: UInt64
}

/// Captured before an attempt's first await. Orders its success/failure (sequence, then generation)
/// and scopes what it may clear to the failure and projection issue that existed when it began.
struct DomainCatalogAttempt: Equatable {
    struct FailureWitness: Equatable {
        let id: UUID
        let reportVersion: UInt64
    }

    let generation: UInt64
    let failureWitness: FailureWitness?
    let projectionIssueWitness: DomainProjectionIssueWitness?
}

enum WorkspaceChooserRecovery: Equatable {
    case idle
    case retrying(UUID)

    var isRetrying: Bool {
        if case .retrying = self { return true }
        return false
    }
}

/// Chooser completeness of an accepted reconciliation. Only `.complete` certifies ordinary readiness.
enum DomainCatalogCompleteness: Equatable {
    case complete
    case incomplete(WorkspaceChooserFailure)

    var failure: WorkspaceChooserFailure? {
        if case let .incomplete(failure) = self { failure } else { nil }
    }
}

enum DomainCatalogProjection {
    case full([WorkspaceModel])
    /// Valid only against the manager's current accepted reconciliation generation.
    case metadata(baselineGeneration: UInt64)
}

/// Bridge callers take canonical roots from snapshot metadata; manager reload/cleanup callers keep
/// their freshly decoded models' roots, matching their pre-#1142 behavior.
enum DomainCatalogRootMapPolicy {
    case snapshotMetadata
    case decodedModels
}

/// Proof that the manager accepted a reconciliation; completeness is a separate fact.
struct DomainCatalogApplicationReceipt: Equatable {
    enum Kind: Equatable {
        case full
        case metadata
    }

    let kind: Kind
    let publicationSequence: UInt64
    let catalogRevision: UInt64
    let reconciliationGeneration: UInt64
    let completeness: DomainCatalogCompleteness
}

enum DomainCatalogRejection: Equatable {
    case closing
    case cancelled
    case stalePublication
    case staleCatalogRevision
    case reentrant
    /// An older attempt resolving after a newer one at the same (or a later) sequence.
    case superseded
    case fullProjectionRequired
    case invalidCatalog(String)
}

enum DomainCatalogApplicationResult: Equatable {
    case accepted(DomainCatalogApplicationReceipt)
    case rejected(DomainCatalogRejection)

    var receipt: DomainCatalogApplicationReceipt? {
        if case let .accepted(receipt) = self { receipt } else { nil }
    }

    var rejection: DomainCatalogRejection? {
        if case let .rejected(reason) = self { reason } else { nil }
    }
}
