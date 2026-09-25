import Foundation

// MARK: - Shared Worktree Listing

/// Configuration for the process-wide worktree listing shared by periodic Git context refreshes.
struct SharedWorktreeListingConfiguration {
    /// Must not exceed one `GitViewModel` context-refresh interval (2.5 s), so a single window
    /// never observes a listing older than its previous refresh.
    static let defaultTimeToLive: TimeInterval = 2.5

    var timeToLive: TimeInterval = Self.defaultTimeToLive
    /// Monotonic clock in seconds.
    var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Test seam replacing `git worktree list` plus per-worktree layout resolution.
    var lister: (@Sendable (URL) async throws -> [GitWorktreeDescriptor])?
}

/// Cache entries, in-flight enumerations, and the invalidation generation.
struct SharedWorktreeListingState {
    struct Entry {
        let descriptors: [GitWorktreeDescriptor]
        /// Age is measured from the start of the enumeration that produced the entry.
        let fetchStartedAt: TimeInterval
    }

    struct Flight {
        let id: UInt64
        let task: Task<[GitWorktreeDescriptor], Error>
    }

    var entries: [String: Entry] = [:]
    var flights: [String: Flight] = [:]
    var generation: UInt64 = 0
    var nextFlightID: UInt64 = 0
    /// Standardized repo-root path -> cache key; a `nil` value marks a root that must bypass the cache.
    var keyByRootPath: [String: String?] = [:]
}

extension VCSService {
    /// Worktree listing for periodic, read-only Git context refreshes, shared across windows.
    ///
    /// Every window refreshes its Git worktree context every ~2.5 s. Each refresh runs
    /// `git worktree list` and resolves every linked worktree's `.git` and `commondir`, so windows
    /// whose roots belong to one repository used to repeat the same enumeration. Here those
    /// refreshes share one enumeration per repository:
    /// - entries expire `timeToLive` after their enumeration started;
    /// - concurrent requests for one repository join a single in-flight enumeration;
    /// - `invalidateSharedWorktreeListings()` (also run by `invalidateCache(for:)` and
    ///   `clearCache()`) drops entries and in-flight joins and prevents an enumeration that
    ///   started earlier from being stored, so RepoPrompt's own worktree mutations are visible
    ///   on the next refresh;
    /// - failures are never cached, and there is no modification-time validation.
    ///
    /// The key is the standardized common Git directory plus the known main-worktree root, so
    /// callers sharing an entry give descriptor construction identical inputs. Only `isCurrent`
    /// depends on the caller, and it is re-projected per request. Roots whose main worktree
    /// cannot be derived from the common directory bypass the cache. Explicit tool listings keep
    /// using the uncached `listGitWorktrees`.
    func sharedGitWorktreeListing(for resolved: VCSResolvedRepo) async throws -> [GitWorktreeDescriptor] {
        guard resolved.backendKind == .git else {
            throw VCSError.unsupportedOperation(operation: "list_worktrees", backend: resolved.backendKind)
        }
        let rootURL = resolved.rootURL
        let lister = gitWorktreeLister()
        guard let key = sharedWorktreeListingKey(forRepoRoot: rootURL) else {
            return try await lister(rootURL)
        }
        let descriptors = try await sharedWorktreeListing(forKey: key, rootURL: rootURL, lister: lister)
        return Self.projectingCurrentWorktree(descriptors, currentRepoURL: rootURL)
    }

    /// Drop every shared worktree listing. Call after any RepoPrompt worktree mutation.
    func invalidateSharedWorktreeListings() {
        sharedWorktreeListing.generation &+= 1
        sharedWorktreeListing.entries.removeAll()
        sharedWorktreeListing.flights.removeAll()
        sharedWorktreeListing.keyByRootPath.removeAll()
    }

    private func sharedWorktreeListing(
        forKey key: String,
        rootURL: URL,
        lister: @escaping @Sendable (URL) async throws -> [GitWorktreeDescriptor]
    ) async throws -> [GitWorktreeDescriptor] {
        let startedAt = sharedWorktreeListingConfiguration.now()
        if let entry = sharedWorktreeListing.entries[key] {
            if startedAt - entry.fetchStartedAt < sharedWorktreeListingConfiguration.timeToLive {
                return entry.descriptors
            }
            sharedWorktreeListing.entries.removeValue(forKey: key)
        }
        if let flight = sharedWorktreeListing.flights[key] {
            return try await flight.task.value
        }

        let generation = sharedWorktreeListing.generation
        sharedWorktreeListing.nextFlightID &+= 1
        let flightID = sharedWorktreeListing.nextFlightID
        // Unstructured so one waiter's cancellation cannot fail the other joined waiters.
        let task = Task { try await lister(rootURL) }
        sharedWorktreeListing.flights[key] = SharedWorktreeListingState.Flight(id: flightID, task: task)
        let result = await task.result
        if sharedWorktreeListing.flights[key]?.id == flightID {
            sharedWorktreeListing.flights.removeValue(forKey: key)
        }
        if case let .success(descriptors) = result, sharedWorktreeListing.generation == generation {
            sharedWorktreeListing.entries[key] = SharedWorktreeListingState.Entry(
                descriptors: descriptors,
                fetchStartedAt: startedAt
            )
        }
        return try result.get()
    }

    private func sharedWorktreeListingKey(forRepoRoot rootURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path
        if let memoized = sharedWorktreeListing.keyByRootPath[rootPath] {
            return memoized
        }
        let key: String? = if let layout = gitRepositoryLayout(forRepoRoot: rootURL),
                              let mainRoot = layout.knownMainWorktreeRoot
        {
            layout.commonDir.standardizedFileURL.path + "\n" + mainRoot.standardizedFileURL.path
        } else {
            nil
        }
        sharedWorktreeListing.keyByRootPath[rootPath] = .some(key)
        return key
    }

    private func gitWorktreeLister() -> @Sendable (URL) async throws -> [GitWorktreeDescriptor] {
        if let lister = sharedWorktreeListingConfiguration.lister {
            return lister
        }
        let backend = gitBackend()
        return { url in try await backend.listWorktrees(at: url) }
    }

    /// Mirrors `GitService.makeWorktreeDescriptors`, where `isCurrent` is `path == currentPath`.
    nonisolated static func projectingCurrentWorktree(
        _ descriptors: [GitWorktreeDescriptor],
        currentRepoURL: URL
    ) -> [GitWorktreeDescriptor] {
        let currentPath = currentRepoURL.standardizedFileURL.path
        return descriptors.map { descriptor in
            let isCurrent = descriptor.path == currentPath
            guard descriptor.isCurrent != isCurrent else { return descriptor }
            return GitWorktreeDescriptor(
                worktreeID: descriptor.worktreeID,
                repository: descriptor.repository,
                path: descriptor.path,
                gitDir: descriptor.gitDir,
                name: descriptor.name,
                branch: descriptor.branch,
                head: descriptor.head,
                isMain: descriptor.isMain,
                isCurrent: isCurrent,
                isDetached: descriptor.isDetached,
                isLocked: descriptor.isLocked,
                lockReason: descriptor.lockReason,
                isPrunable: descriptor.isPrunable,
                prunableReason: descriptor.prunableReason
            )
        }
    }
}
