import Foundation
import OSLog

/// Closed vocabulary: no continuation text, idempotency keys, names, paths or tool payloads.
enum AgentSelfCompactParkingReason: String {
    case nativeDeadline
    case successorClaimed
    case ordinaryInput
    case acpCompletionUnverified
    case teardownDeadline
    case noteStartRefused
    case definitiveNonAttempt
    case transportNotAttempted
    case runtimeTeardown
}

enum AgentSelfCompactNoteRefusal: String {
    case admissionChanged
    case composerTarget
    case composerClaim
    case queuedProviderWork
    case ownerChanged
    case workspaceChanged
    case deliveryReadiness
    case requiredSave
    case runNotStarted
}

enum AgentSelfCompactDiagnostics {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RepoPrompt", category: "AgentSelfCompact")

    static func parked(requestID: UUID, reason: AgentSelfCompactParkingReason) {
        logger.notice("self_compact request=\(requestID.uuidString, privacy: .public) phase=parked reason=\(reason.rawValue, privacy: .public)")
    }

    static func noteRefused(requestID: UUID, reason: AgentSelfCompactNoteRefusal) {
        logger.notice("self_compact request=\(requestID.uuidString, privacy: .public) phase=note_refused reason=\(reason.rawValue, privacy: .public)")
    }
}
