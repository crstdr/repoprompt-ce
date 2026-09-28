import Foundation
import RepoPromptDomainRuntime

/// Host-neutral inputs and receipts for the bridge's process-local lane transaction.
struct AgentSessionLaneCreateRequest {
    let idempotencyKey: String
    let role: String?
    let sessionName: String?
    /// The caller's selector, not a window/workspace binding that can move after the request.
    var workspaceSelector: String?
    let message: String?
    let workflowReference: AgentWorkflowReference?

    var digest: String {
        let fields = [
            role ?? "pair", sessionName ?? "", Self.canonicalSelector(workspaceSelector),
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

enum AgentSessionLaneRetireOutcome: Equatable {
    enum Reason: String, Equatable {
        case denied
        case shuttingDown = "shutting_down"
        case notRetirable = "not_retirable"
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
