import Foundation
import RepoPromptDomainRuntime

/// Host-neutral inputs and receipts for the bridge's process-local lane transaction.
struct AgentSessionLaneCreateRequest {
    let idempotencyKey: String
    let role: String?
    let sessionName: String?
    let destinationWindowID: Int
    let workspaceID: UUID
    let message: String?
    let workflowReference: AgentWorkflowReference?

    var digest: String {
        let fields = [
            role ?? "pair", sessionName ?? "", String(destinationWindowID), workspaceID.uuidString,
            message ?? "", AgentWorkflowReference.canonicalSelector(for: workflowReference),
        ]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return AgentSessionLinkMessageDigest.digest(message: canonical, workflowSelector: "create_lane/v1")
    }
}

enum AgentSessionLaneHostCreationOutcome {
    case created(sessionID: UUID, tabID: UUID)
    case creationIncomplete(sessionID: UUID, tabID: UUID)
}

enum AgentSessionLaneHostUnavailable: Error { case unavailable }

struct AgentSessionLaneCreateReceipt: Equatable {
    enum Result: Equatable { case created, creationIncomplete, refused }
    enum Reason: String, Equatable {
        case shuttingDown = "freeze"
        case denied
        case persistenceUnavailable = "persistence_unavailable"
        case destinationUnavailable = "destination_unavailable"
        case laneLimitReached = "lane_limit_reached"
        case roleUnavailable = "role_unavailable"
        case idempotencyConflict = "idempotency_conflict"
        case ledgerFull = "ledger_full"
        case saveFailed = "save_failed"
        case addFailed = "add_failed"
        case deleted
        case independentlyLinked = "independently_linked"
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

    static func refused(_ reason: Reason, laneCount: Int = 0) -> Self {
        Self(result: .refused, sessionID: nil, sessionName: nil, linked: false,
             reason: reason, firstTask: .none, laneCount: laneCount)
    }
}

enum AgentSessionLaneRetireOutcome: Equatable {
    enum Reason: String, Equatable {
        case denied, shuttingDown, notRetirable = "not_retirable"
        case managementNotGranted = "management_not_granted"
        case laneInUse = "lane_in_use"
        case laneBusy = "lane_busy"
        case stopFailed = "stop_failed"
        case alreadyStopped = "already_stopped"
    }
    case retired(sessionID: UUID)
    case notRetired(sessionID: UUID, reason: Reason)
    case unlinkedNotStashed(sessionID: UUID)
}
