import Foundation
import MCP
import RepoPromptDomainRuntime

/// One self-only MCP surface. Caller authority comes exclusively from server-owned run routing and
/// the immutable registration-time run attempt; tool arguments cannot name a target.
@MainActor
struct AgentSelfMCPToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata
    typealias Endpoint = DomainAgentSessionLinkEndpointIdentity
    typealias ObserverEndpointResolver = AgentSessionTargetOperationGuard.ObserverEndpointResolver

    enum Admission {
        case scheduled(AgentSelfCompactAttempt)
        case duplicate(requestID: UUID, status: AgentSelfCompactStatus?)
        case blocked(reason: String)
        case unavailable
    }

    let captureRequestMetadata: () async -> RequestMetadata
    let requireTargetWindow: () throws -> WindowState
    let resolveObserverEndpoint: ObserverEndpointResolver
    let captureCallOrigin: () -> AgentSelfMCPCallOrigin?
    let readSelf: (WindowState, Endpoint, AgentSelfMCPCallOrigin) -> AgentSelfContextSnapshot?
    let scheduleCompact: (WindowState, Endpoint, AgentSelfMCPCallOrigin, String, String) async -> Admission

    static let unavailableError = MCPError.invalidParams("agent_self is not available for this session.")

    func execute(args: [String: Value]) async throws -> Value {
        guard let op = AgentMCPToolHelpers.normalizedString(args["op"])?.lowercased() else {
            throw MCPError.invalidParams("agent_self op is required: context or compact.")
        }
        let allowed: Set<String> = switch op {
        case "context": ["op"]
        case "compact": ["op", "note", "idempotency_key"]
        default: throw MCPError.invalidParams("Unknown agent_self op '\(op)'.")
        }
        for key in args.keys.sorted() where !allowed.contains(key) {
            throw MCPError.invalidParams("agent_self \(op) does not support '\(key)'.")
        }
        // Registration-time origin must exist before any await. The exact endpoint is resolved
        // independently from live server routing, and must still equal that captured incarnation.
        guard let origin = captureCallOrigin() else { throw Self.unavailableError }
        let metadata = await captureRequestMetadata()
        let window = try requireTargetWindow()
        guard !window.isClosing,
              let endpoint = await AgentSessionTargetOperationGuard.resolveObserverEndpoint(
                  metadata: metadata, targetWindow: window, resolveObserverEndpoint: resolveObserverEndpoint
              ), endpoint == origin.endpoint, endpoint.hasResolvedPersistentBinding
        else { throw Self.unavailableError }

        switch op {
        case "context":
            guard let snapshot = readSelf(window, endpoint, origin) else { throw Self.unavailableError }
            return .object([
                "result": .string("ok"),
                "context": AgentSessionLinkResponseRenderer.contextLoadValue(snapshot.context),
                "self_compact": Self.statusValue(snapshot.selfCompact)
            ])
        case "compact":
            guard case let .string(note)? = args["note"] else {
                throw MCPError.invalidParams("agent_self compact note is required as a string.")
            }
            let bytes: Int
            switch AgentSessionSelfCompactNotePolicy.validation(of: note) {
            case let .valid(byteCount): bytes = byteCount
            case .empty: throw MCPError.invalidParams("agent_self compact note must not be empty or whitespace-only.")
            case let .tooLong(byteCount, maximum):
                throw MCPError.invalidParams("agent_self compact note is \(byteCount) UTF-8 bytes; maximum \(maximum).")
            case .invalidScalar:
                throw MCPError.invalidParams("agent_self compact note contains a disallowed control character.")
            }
            guard case let .string(key)? = args["idempotency_key"],
                  AgentSessionSelfCompactNotePolicy.idempotencyKeyIsValid(key),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw MCPError.invalidParams("agent_self compact idempotency_key is required (1...200 UTF-8 bytes).")
            }
            let admission = await scheduleCompact(window, endpoint, origin, note, key)
            switch admission {
            case let .scheduled(attempt):
                return .object([
                    "result": .string("scheduled"),
                    "request_id": .string(attempt.id.uuidString),
                    "provider": attempt.admittedSupport.map { .string($0.rawValue) } ?? .null,
                    "note_bytes": .int(bytes),
                    "duplicate": .bool(false),
                    "phase": .string(attempt.phase.rawValue)
                ])
            case let .duplicate(requestID, status):
                return .object([
                    "result": .string(status?.phase == nil ? "settled" : "scheduled"),
                    "request_id": .string(requestID.uuidString),
                    "duplicate": .bool(true),
                    "self_compact": Self.statusValue(status)
                ])
            case let .blocked(reason):
                return .object(["result": .string("blocked"), "reason": .string(reason)])
            case .unavailable:
                throw Self.unavailableError
            }
        default:
            preconditionFailure("Validated agent_self operation")
        }
    }

    static func statusValue(_ status: AgentSelfCompactStatus?) -> Value {
        guard let status else { return .null }
        return .object([
            "request_id": status.requestID.map { .string($0.uuidString) } ?? .null,
            "phase": status.phase.map { .string($0) } ?? .null,
            "outcome": status.outcome.map { .string($0.rawValue) } ?? .null,
            "completion_verified": status.completionVerified.map { .bool($0) } ?? .null,
            "note_delivery": status.noteDelivery.map { .string($0.rawValue) } ?? .null,
            "recovery_note": status.recoveryNote.map { .string($0) } ?? .null
        ])
    }
}
