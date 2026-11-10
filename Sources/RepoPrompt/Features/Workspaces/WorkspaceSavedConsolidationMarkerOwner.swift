import Darwin
import Foundation

/// Saved-phase observations only. Presentation-cache models may already contain marker-cleared
/// working state. Every physical read uses a fresh raw full WorkspaceModel decode.
final class WorkspaceSavedConsolidationMarkerOwner: @unchecked Sendable {
    enum Status: Equatable { case marked, unmarked, unreadable }
    static let maximumEntries = 128
    static let maximumFlights = 32

    private struct Version: Hashable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        let reusable: Bool

        static func probe(_ url: URL) -> Self? {
            var info = Darwin.stat()
            guard stat(url.path, &info) == 0 else { return nil }
            var filesystem = Darwin.statfs()
            let local = statfs(url.path, &filesystem) == 0 && (filesystem.f_flags & UInt32(MNT_LOCAL)) != 0
            let type = withUnsafeBytes(of: &filesystem.f_fstypename) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            return Self(
                device: info.st_dev,
                inode: info.st_ino,
                size: info.st_size,
                modifiedSeconds: info.st_mtimespec.tv_sec,
                modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec,
                changedNanoseconds: info.st_ctimespec.tv_nsec,
                reusable: WorkspaceSavedConsolidationMarkerOwner.supportsReuse(local: local, fileSystemType: type)
            )
        }
    }

    /// Explicit support policy, not an inference from the value of a particular timestamp.
    static func supportsReuse(local: Bool, fileSystemType: String) -> Bool {
        local && fileSystemType == "apfs"
    }

    private struct Key: Hashable {
        let path: String
        let workspaceID: UUID
        let version: Version?
        let token: UInt64
    }

    private struct Entry {
        let key: Key
        let status: Status
        let ordinal: UInt64
    }

    private enum Lookup {
        case cached(Status)
        case work(Task<Status?, Never>)
    }

    private let read: @Sendable (URL, UUID) -> Status

    init(read: @escaping @Sendable (URL, UUID) -> Status) {
        self.read = read
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var flights: [Key: Task<Status?, Never>] = [:]
    // Tokens exist only for registered flights (at most 32), never for every path ever saved.
    private var invalidatedFlightTokens: Set<UInt64> = []
    private var nextFlightToken: UInt64 = 0
    private var ordinal: UInt64 = 0

    func invalidate(url: URL) {
        let path = url.standardizedFileURL.path
        lock.withLock {
            entries.removeValue(forKey: path)
            for key in flights.keys where key.path == path {
                invalidatedFlightTokens.insert(key.token)
            }
            #if DEBUG
                stats.invalidations += 1
            #endif
        }
    }

    func status(url: URL, workspaceID: UUID) async -> Status {
        #if DEBUG
            let legacy = lock.withLock {
                stats.requests += 1
                stats.activeLookups += 1
                return perCaller
            }
            defer { lock.withLock { stats.activeLookups -= 1 } }
            if legacy { return read(url, workspaceID) }
        #endif
        let url = url.standardizedFileURL
        // Reuse requires a validated version. Discarded observations may be stale or torn.
        for _ in 0 ..< 2 {
            switch admit(url: url, workspaceID: workspaceID) {
            case let .cached(status): return status
            case let .work(task): if let status = await task.value { return status }
            }
        }
        // Restore the original per-caller read semantics under continued churn. Never retain this result.
        return read(url, workspaceID)
    }

    private func admit(url: URL, workspaceID: UUID) -> Lookup {
        let version = Version.probe(url)
        return lock.withLock {
            let reusable = version?.reusable ?? false
            if reusable, let entry = entries[url.path], entry.key.workspaceID == workspaceID, entry.key.version == version {
                #if DEBUG
                    stats.cacheHits += 1
                #endif
                return .cached(entry.status)
            }
            if reusable, let flight = flights.first(where: {
                $0.key.path == url.path && $0.key.workspaceID == workspaceID && $0.key.version == version
                    && !invalidatedFlightTokens.contains($0.key.token)
            }) {
                #if DEBUG
                    stats.flightsJoined += 1
                #endif
                return .work(flight.value)
            }
            nextFlightToken &+= 1
            let key = Key(path: url.path, workspaceID: workspaceID, version: version, token: nextFlightToken)
            // Overflow falls back to an independent validated read, never to an invented status.
            let registered = reusable && flights.count < Self.maximumFlights
            #if DEBUG
                stats.flightsStarted += 1
                stats.activeReads += 1
                let gate = readGate
            #endif
            let task = Task<Status?, Never>.detached(priority: .utility) { [self] in
                #if DEBUG
                    await gate?(.beforeRead, url)
                #endif
                let status = read(url, workspaceID)
                #if DEBUG
                    await gate?(.afterRead, url)
                #endif
                let after = Version.probe(url)
                return lock.withLock {
                    let invalidated = invalidatedFlightTokens.remove(key.token) != nil
                    if registered { flights.removeValue(forKey: key) }
                    #if DEBUG
                        stats.activeReads -= 1
                    #endif
                    guard !invalidated, after == version else {
                        #if DEBUG
                            stats.staleCompletions += 1
                        #endif
                        return nil
                    }
                    if registered, let version, version.reusable, status != .unreadable {
                        if entries[key.path] == nil, entries.count >= Self.maximumEntries,
                           let oldest = entries.min(by: { $0.value.ordinal < $1.value.ordinal })?.key
                        {
                            entries.removeValue(forKey: oldest)
                        }
                        ordinal &+= 1
                        entries[key.path] = Entry(key: key, status: status, ordinal: ordinal)
                    }
                    return status
                }
            }
            // Completion takes this lock, so a worker cannot retire before installation.
            if registered { flights[key] = task }
            return .work(task)
        }
    }

    #if DEBUG
        static func reuseSupportedForTesting(at url: URL) -> Bool {
            Version.probe(url)?.reusable == true
        }

        enum ReadPhase { case beforeRead, afterRead, betweenLookups }
        struct Stats: Encodable, Equatable {
            var requests = 0
            var cacheHits = 0
            var flightsStarted = 0
            var flightsJoined = 0
            var staleCompletions = 0
            var invalidations = 0
            var activeReads = 0
            var activeLookups = 0
            var activeClassifications = 0
        }

        private var stats = Stats()
        private var perCaller = false
        private var readGate: (@Sendable (ReadPhase, URL) async -> Void)?

        @discardableResult
        func resetForTesting(perCaller: Bool = false) -> Bool {
            lock.withLock {
                guard isIdleForTesting else { return false }
                entries.removeAll()
                stats = Stats()
                self.perCaller = perCaller
                readGate = nil
                invalidatedFlightTokens.removeAll()
                return true
            }
        }

        func beginClassificationForTesting() {
            lock.withLock { stats.activeClassifications += 1 }
        }

        func endClassificationForTesting() {
            lock.withLock { stats.activeClassifications -= 1 }
        }

        func betweenLookupsForTesting(url: URL) async {
            let gate = lock.withLock { readGate }
            await gate?(.betweenLookups, url)
        }

        func setReadGateForTesting(_ gate: (@Sendable (ReadPhase, URL) async -> Void)?) {
            lock.withLock { readGate = gate }
        }

        func snapshotForTesting() -> (stats: Stats, entries: Int, flights: Int, invalidatedFlights: Int, perCaller: Bool, hasReadGate: Bool) {
            lock.withLock { (stats, entries.count, flights.count, invalidatedFlightTokens.count, perCaller, readGate != nil) }
        }

        private var isIdleForTesting: Bool {
            stats.activeReads == 0 && stats.activeLookups == 0 && stats.activeClassifications == 0 && flights.isEmpty
        }

        @discardableResult
        func awaitIdleForTesting(timeout: Duration = .seconds(5)) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !lock.withLock({ isIdleForTesting }) {
                guard clock.now < deadline else { return false }
                await Task.yield()
            }
            return true
        }
    #endif
}
