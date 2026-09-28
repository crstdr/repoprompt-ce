import Foundation
import RepoPromptDomainRuntime

/// A request belongs to one live endpoint incarnation and one originating run attempt.
/// Persisting this identity is evidence for recovery, never authority to dispatch after restore.
struct AgentSelfCompactOwner: Codable, Equatable {
    let windowID: Int
    let workspaceID: UUID
    let tabID: UUID
    let sessionID: UUID
    let persistentBindingGeneration: UUID
    let bindingTransitionGeneration: UInt64
    let runID: UUID
    let runAttemptID: UUID
}

struct AgentSelfCompactAttempt: Codable, Equatable {
    enum Phase: String, CaseIterable, Codable {
        case scheduled
        case compactDispatchPending
        case dispatchingCompact
        case awaitingCompactTurn
        case acpSettling
        case awaitingNoteBoundary
        case noteDispatchPending
        case dispatchingNote
        case parked
    }

    let id: UUID
    let idempotencyKey: String
    let noteDigest: String
    let note: String
    let owner: AgentSelfCompactOwner?
    let acceptedAt: Date
    var phase: Phase
    var compactDispatchStarted = false
    var admittedSupport: AgentSessionLinkCompactSupport?
    var noteDispatchStarted = false

    init(
        id: UUID = UUID(),
        idempotencyKey: String,
        note: String,
        owner: AgentSelfCompactOwner? = nil,
        acceptedAt: Date = Date(),
        phase: Phase = .scheduled
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        noteDigest = AgentSessionSelfCompactNotePolicy.digest(of: note)
        self.note = note
        self.owner = owner
        self.acceptedAt = acceptedAt
        self.phase = phase
    }

    var isValid: Bool {
        guard case .valid = AgentSessionSelfCompactNotePolicy.validation(of: note) else { return false }
        return AgentSessionSelfCompactNotePolicy.idempotencyKeyIsValid(idempotencyKey)
            && noteDigest == AgentSessionSelfCompactNotePolicy.digest(of: note)
    }
}

struct AgentSelfCompactSettlement: Codable, Equatable {
    enum Outcome: String, Codable {
        case noteAccepted
        case cancelled
        case failed
        case completionUnverified
        case deliveryUnknown
        case recoveryRequired
    }

    enum NoteDelivery: String, Codable {
        case accepted
        case deliveryUnknown
        case notSent
        case parked
        case prepended
    }

    let requestID: UUID?
    let idempotencyKey: String?
    let noteDigest: String?
    let outcome: Outcome
    let noteDelivery: NoteDelivery
    let completionVerified: Bool
    let settledAt: Date
    /// Present when explicit recovery is needed; never stored in a system-row text.
    let recoveryNote: String?

    static func recoveryRequired(from attempt: AgentSelfCompactAttempt, at date: Date = Date()) -> Self {
        let delivery: NoteDelivery = if attempt.noteDispatchStarted || attempt.phase == .dispatchingNote {
            .deliveryUnknown
        } else if attempt.phase == .parked {
            .parked
        } else {
            .notSent
        }
        return Self(
            requestID: attempt.id,
            idempotencyKey: attempt.idempotencyKey,
            noteDigest: attempt.noteDigest,
            outcome: .recoveryRequired,
            noteDelivery: delivery,
            completionVerified: false,
            settledAt: date,
            recoveryNote: attempt.note
        )
    }

    static func malformedRecovery(at date: Date = Date()) -> Self {
        Self(
            requestID: nil,
            idempotencyKey: nil,
            noteDigest: nil,
            outcome: .recoveryRequired,
            noteDelivery: .notSent,
            completionVerified: false,
            settledAt: date,
            recoveryNote: nil
        )
    }

    var isValid: Bool {
        if let idempotencyKey {
            guard requestID != nil,
                  AgentSessionSelfCompactNotePolicy.idempotencyKeyIsValid(idempotencyKey),
                  let noteDigest, noteDigest.count == 64
            else { return false }
        }
        guard let recoveryNote else { return true }
        guard case .valid = AgentSessionSelfCompactNotePolicy.validation(of: recoveryNote) else { return false }
        return noteDigest == nil || noteDigest == AgentSessionSelfCompactNotePolicy.digest(of: recoveryNote)
    }
}

/// At most one active request and one latest settlement. Older keys may be reused by design.
struct AgentSelfCompactState: Codable, Equatable {
    static let currentVersion = 1
    private var version = currentVersion

    enum Reservation: Equatable {
        case scheduled(AgentSelfCompactAttempt)
        case duplicate(UUID)
        case conflict
        case alreadyPending
        case invalidNote(AgentSessionSelfCompactNotePolicy.Validation)
        case invalidIdempotencyKey
    }

    var active: AgentSelfCompactAttempt?
    var latest: AgentSelfCompactSettlement?

    init(active: AgentSelfCompactAttempt? = nil, latest: AgentSelfCompactSettlement? = nil) {
        self.active = active
        self.latest = latest
    }

    enum CodingKeys: String, CodingKey {
        case version
        case active
        case latest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Unknown self-compaction state version"
            )
        }
        active = try container.decodeIfPresent(AgentSelfCompactAttempt.self, forKey: .active)
        latest = try container.decodeIfPresent(AgentSelfCompactSettlement.self, forKey: .latest)
        guard active != nil || latest != nil,
              active?.isValid != false,
              latest?.isValid != false
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid self-compaction record")
            )
        }
    }

    mutating func reserve(
        note: String,
        idempotencyKey: String,
        owner: AgentSelfCompactOwner? = nil,
        at date: Date = Date()
    ) -> Reservation {
        let validation = AgentSessionSelfCompactNotePolicy.validation(of: note)
        guard case .valid = validation else { return .invalidNote(validation) }
        guard AgentSessionSelfCompactNotePolicy.idempotencyKeyIsValid(idempotencyKey) else {
            return .invalidIdempotencyKey
        }
        let digest = AgentSessionSelfCompactNotePolicy.digest(of: note)
        if let active {
            if active.idempotencyKey == idempotencyKey {
                return active.noteDigest == digest ? .duplicate(active.id) : .conflict
            }
            return .alreadyPending
        }
        if let latest, latest.idempotencyKey == idempotencyKey {
            guard latest.noteDigest == digest, let requestID = latest.requestID else { return .conflict }
            return .duplicate(requestID)
        }
        let attempt = AgentSelfCompactAttempt(
            idempotencyKey: idempotencyKey,
            note: note,
            owner: owner,
            acceptedAt: date
        )
        active = attempt
        return .scheduled(attempt)
    }

    mutating func settle(
        _ outcome: AgentSelfCompactSettlement.Outcome,
        noteDelivery: AgentSelfCompactSettlement.NoteDelivery,
        completionVerified: Bool,
        at date: Date = Date()
    ) {
        guard let active else { return }
        latest = AgentSelfCompactSettlement(
            requestID: active.id,
            idempotencyKey: active.idempotencyKey,
            noteDigest: active.noteDigest,
            outcome: outcome,
            noteDelivery: noteDelivery,
            completionVerified: completionVerified,
            settledAt: date,
            recoveryNote: outcome == .noteAccepted ? nil : active.note
        )
        self.active = nil
    }

    /// Every persisted phase, including parked, is inert after a process restart.
    @discardableResult
    mutating func reconcileColdLaunch(at date: Date = Date()) -> Bool {
        guard let active else { return false }
        latest = .recoveryRequired(from: active, at: date)
        self.active = nil
        return true
    }

    var status: AgentSelfCompactStatus? {
        if let active {
            return AgentSelfCompactStatus(
                requestID: active.id,
                phase: active.phase.rawValue,
                outcome: nil,
                completionVerified: nil,
                noteDelivery: nil,
                recoveryNote: nil
            )
        }
        guard let latest else { return nil }
        return AgentSelfCompactStatus(
            requestID: latest.requestID,
            phase: nil,
            outcome: latest.outcome,
            completionVerified: latest.completionVerified,
            noteDelivery: latest.noteDelivery,
            recoveryNote: latest.recoveryNote
        )
    }
}

/// A stable context response model; the load itself remains the existing poll value.
struct AgentSelfContextSnapshot {
    let context: DomainAgentSessionContextLoad?
    let selfCompact: AgentSelfCompactStatus?
}

struct AgentSelfCompactStatus: Equatable {
    let requestID: UUID?
    let phase: String?
    let outcome: AgentSelfCompactSettlement.Outcome?
    let completionVerified: Bool?
    let noteDelivery: AgentSelfCompactSettlement.NoteDelivery?
    let recoveryNote: String?
}
