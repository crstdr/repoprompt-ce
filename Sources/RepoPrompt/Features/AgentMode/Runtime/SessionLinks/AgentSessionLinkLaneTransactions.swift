import Foundation
import RepoPromptDomainRuntime

/// Host-neutral inputs and receipts for the bridge's process-local lane transaction.
struct AgentSessionLaneCreateRequest {
    let idempotencyKey: String
    let role: String?
    var modelID: String?
    let sessionName: String?
    /// The caller's selector, not a window/workspace binding that can move after the request.
    var workspaceSelector: String?
    let message: String?
    let workflowReference: AgentWorkflowReference?

    var digest: String {
        let fields = [
            modelID.map { "model:\($0)" } ?? role ?? "pair", sessionName ?? "", Self.canonicalSelector(workspaceSelector),
            message ?? "", AgentWorkflowReference.canonicalSelector(for: workflowReference)
        ]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return AgentSessionLinkMessageDigest.digest(message: canonical, workflowSelector: "create_lane/v1")
    }

    static func canonicalSelector(_ value: String?) -> String {
        guard let value else { return "caller-workspace" }
        if let id = UUID(uuidString: value) { return "id:\(id.uuidString)" }
        let folded = value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        return "name:\(folded.precomposedStringWithCanonicalMapping)"
    }
}

enum AgentSessionLaneHostCreationOutcome {
    case created(sessionID: UUID, tabID: UUID, bindingToken: AgentSessionRestorationBindingToken)
    case creationIncomplete(sessionID: UUID, tabID: UUID)
}

enum AgentSessionLaneHostUnavailable: Error { case unavailable }

struct AgentSessionLaneCreateReceipt: Equatable {
    enum Result: Equatable { case created, creationIncomplete, refused }
    enum Reason: String, Equatable {
        case shuttingDown = "shutting_down"
        case denied
        case persistenceUnavailable = "persistence_unavailable"
        case destinationUnavailable = "destination_unavailable"
        case hostUnavailable = "host_unavailable"
        case laneLimitReached = "lane_limit_reached"
        case admissionUnstable = "admission_unstable"
        case roleUnavailable = "role_unavailable"
        case modelUnavailable = "model_unavailable"
        case idempotencyConflict = "idempotency_conflict"
        case ledgerFull = "ledger_full"
        case saveFailed = "save_failed"
        case addFailed = "add_failed"
    }

    enum FirstTask: Equatable { case none, delivered, queued, failed }

    let result: Result
    let sessionID: UUID?
    let sessionName: String?
    let linked: Bool
    let reason: Reason?
    let firstTask: FirstTask
    let laneCount: Int
    var duplicate = false
    var firstTaskReason: String?
    /// Original destination display name, preserved on replay; not a live location or selector.
    var workspaceName: String?

    static func refused(_ reason: Reason, laneCount: Int = 0) -> Self {
        Self(
            result: .refused,
            sessionID: nil,
            sessionName: nil,
            linked: false,
            reason: reason,
            firstTask: .none,
            laneCount: laneCount
        )
    }
}

/// Retirement may stash a settled subtree, but must preserve every descendant that still owns work.
struct AgentSessionLaneChildRetirementRecord {
    /// Which evidence produced the record. Only a hydrated session is newer than its unflushed disk
    /// header, so only it may shadow persisted or index blocking state; the rest can add edges and
    /// blocking evidence but never erase them.
    enum Source {
        case persisted
        case sessionIndex
        case unhydratedSession
        case hydratedSession

        var isSessionDerived: Bool {
            self == .unhydratedSession || self == .hydratedSession
        }
    }

    let sessionID: UUID
    let parentSessionID: UUID?
    let blocksRetirement: Bool
    let source: Source

    init(sessionID: UUID, parentSessionID: UUID?, blocksRetirement: Bool, source: Source = .persisted) {
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.blocksRetirement = blocksRetirement
        self.source = source
    }

    /// Merge every live record for `persisted.sessionID` over the persisted row. Blocking favors
    /// fail-closed evidence: a hydrated session's quiescence clears stale disk/index rows, while an
    /// unhydrated session's default state proves nothing and keeps the block. Parentage prefers
    /// session-derived, then index, then persisted values, and conflicting live parents keep every
    /// edge rather than dropping a descendant.
    static func merging(live: [Self], over persisted: Self) -> [Self] {
        let hydrated = live.contains { $0.source == .hydratedSession }
        let sessionBlocks = live.contains { $0.source.isSessionDerived && $0.blocksRetirement }
        let blocks = hydrated
            ? sessionBlocks
            : live.contains { $0.blocksRetirement } || persisted.blocksRetirement
        var parents = Set(live.filter(\.source.isSessionDerived).compactMap(\.parentSessionID))
        if parents.isEmpty {
            parents = Set(live.filter { $0.source == .sessionIndex }.compactMap(\.parentSessionID))
        }
        if parents.isEmpty, let parent = persisted.parentSessionID { parents = [parent] }
        guard !parents.isEmpty else {
            return [Self(
                sessionID: persisted.sessionID,
                parentSessionID: nil,
                blocksRetirement: blocks,
                source: persisted.source
            )]
        }
        return parents.sorted { $0.uuidString < $1.uuidString }.map {
            Self(
                sessionID: persisted.sessionID,
                parentSessionID: $0,
                blocksRetirement: blocks,
                source: persisted.source
            )
        }
    }

    static func hasBlockingDescendant(of parentSessionID: UUID, in records: [Self]) -> Bool {
        let descendants = descendantIDs(of: parentSessionID, in: records)
        return records.contains { descendants.contains($0.sessionID) && $0.blocksRetirement }
    }

    static func descendantIDs(of parentSessionID: UUID, in records: [Self]) -> Set<UUID> {
        let childrenByParent = Dictionary(grouping: records.compactMap { record in
            record.parentSessionID.map { ($0, record) }
        }, by: { $0.0 })
        var visited: Set<UUID> = [parentSessionID]
        var pending = [parentSessionID]
        while let parent = pending.popLast() {
            for (_, child) in childrenByParent[parent] ?? [] {
                guard visited.insert(child.sessionID).inserted else { continue }
                pending.append(child.sessionID)
            }
        }
        visited.remove(parentSessionID)
        return visited
    }
}

enum AgentSessionLaneRetireOutcome: Equatable {
    enum Reason: String, Equatable {
        case denied
        case shuttingDown = "shutting_down"
        case notRetirable = "not_retirable"
        case managementNotGranted = "management_not_granted"
        case laneInUse = "lane_in_use"
        case laneInUseBindings = "lane_in_use_bindings"
        case laneInUseChildren = "lane_in_use_children"
        case laneInUseDiskChild = "lane_in_use_disk_child"
        case laneInUseInboundCount = "lane_in_use_in_count"
        case laneInUseInboundLink = "lane_in_use_in_link"
        case laneInUseInboundGeneration = "lane_in_use_in_gen"
        case laneInUseOutbound = "lane_in_use_outbound"
        case laneInUsePending = "lane_in_use_pending"
        case laneBusy = "lane_busy"
        case stopFailed = "stop_failed"
        case alreadyStopped = "already_stopped"

        var wireReason: String {
            subreason == nil ? rawValue : Reason.laneInUse.rawValue
        }

        var subreason: String? {
            switch self {
            case .laneInUse: "unknown"
            case .laneInUseBindings: "bindings"
            case .laneInUseChildren: "children"
            case .laneInUseDiskChild: "disk_child"
            case .laneInUseInboundCount: "in_count"
            case .laneInUseInboundLink: "in_link"
            case .laneInUseInboundGeneration: "in_gen"
            case .laneInUseOutbound: "outbound"
            case .laneInUsePending: "pending"
            default: nil
            }
        }
    }

    case retired(sessionID: UUID)
    case notRetired(sessionID: UUID, reason: Reason)
    case unlinkedNotStashed(sessionID: UUID)
}
