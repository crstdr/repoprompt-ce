import CryptoKit
import Foundation
import OSLog
import RepoPromptInstrumentation

/// Low-volume, always-on local diagnostics for oversight catalog convergence.
/// Accepts only closed enums, booleans, generations, revisions, and hashed identifiers.
enum AgentSessionLinkCatalogDiagnostics {
    enum Presence: String, Equatable {
        case present
        case absent
        case unknown

        init(_ value: Bool?) {
            switch value {
            case true: self = .present
            case false: self = .absent
            case nil: self = .unknown
            }
        }
    }

    enum Event: String, Equatable {
        case catalogPublished = "catalog-published"
        case projectionEvaluated = "projection-evaluated"
        case repairTransition = "repair-transition"
        case toolCallReceived = "tool-call-received"
    }

    typealias Outcome = AgentSessionLinkCatalogOutcome

    struct Record: Equatable {
        let event: Event
        let outcome: Outcome?
        let run: String
        let tab: String
        let connection: String
        let revision: UInt64?
        let routingGeneration: UInt64?
        let lifecycleGeneration: UInt64?
        let routePresent: Bool?
        let catalog: Presence?
        let outbound: Presence?

        var renderedLine: String {
            let outcomeValue = outcome?.rawValue ?? "nil"
            let revisionValue = revision.map(String.init) ?? "nil"
            let routingGenerationValue = routingGeneration.map(String.init) ?? "nil"
            let lifecycleGenerationValue = lifecycleGeneration.map(String.init) ?? "nil"
            let routePresentValue = routePresent.map(String.init) ?? "nil"
            let catalogValue = catalog?.rawValue ?? "nil"
            let outboundValue = outbound?.rawValue ?? "nil"
            return [
                "event=\(event.rawValue)",
                "outcome=\(outcomeValue)",
                "run=\(run)",
                "tab=\(tab)",
                "connection=\(connection)",
                "revision=\(revisionValue)",
                "routingGeneration=\(routingGenerationValue)",
                "lifecycleGeneration=\(lifecycleGenerationValue)",
                "routePresent=\(routePresentValue)",
                "catalog=\(catalogValue)",
                "outbound=\(outboundValue)"
            ].joined(separator: " ")
        }
    }

    /// Retirement entry point: agent_session_link retire_lane. Local, release-capable markers
    /// contain only a fresh opaque operation UUID and closed phase/transition enums. The socket
    /// owner carries the same UUID through its existing transport request-identity seam.
    enum RetirementStage: String, Equatable {
        case service = "retire_lane.service"
        case stash = "retire_lane.stash"
        case stashProjection = "retire_lane.stash_projection"
        case replacementTab = "retire_lane.replacement_tab"
        case activation = "retire_lane.activation"
        case cleanup = "retire_lane.cleanup"
        case cleanupWillClose = "retire_lane.cleanup_will_close"
        case cleanupRouting = "retire_lane.cleanup_routing"
        case cleanupDidRemove = "retire_lane.cleanup_did_remove"
        case canonicalSave = "retire_lane.canonical_save"
        case recovery = "retire_lane.recovery"
        case workingPublication = "retire_lane.working_publication"
        case save = "retire_lane.save"
        case domainSave = "retire_lane.domain_save"
        case flush = "retire_lane.flush"
        case replyWrite = "retire_lane.reply_write"
    }

    enum RetirementTransition: String, Equatable {
        case started
        // Returned means the await settled, not that persistence/retirement succeeded.
        case returned
        case committed
        case failed
    }

    struct RetirementRecord: Equatable {
        let operationID: UUID
        let stage: RetirementStage
        let transition: RetirementTransition

        var renderedLine: String {
            "operation=\(operationID.uuidString) stage=\(stage.rawValue) transition=\(transition.rawValue)"
        }
    }

    @TaskLocal static var retirementOperationID: UUID?
    /// Only the explicitly awaited canonical save is traced, not autosaves spawned by stash.
    @TaskLocal static var retirementCanonicalSave = false
    #if DEBUG
        @TaskLocal static var retirementTestSink: (@Sendable (RetirementRecord) -> Void)?
    #endif

    static func retirement(
        _ stage: RetirementStage,
        _ transition: RetirementTransition,
        operationID: UUID? = retirementOperationID
    ) {
        guard let operationID else { return }
        let record = RetirementRecord(operationID: operationID, stage: stage, transition: transition)
        logger.notice("\(record.renderedLine, privacy: .public)")
        #if DEBUG
            retirementTestSink?(record)
        #endif
    }

    static func retirementPersistence(_ stage: RetirementStage, _ transition: RetirementTransition) {
        guard retirementCanonicalSave else { return }
        retirement(stage, transition)
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoPrompt",
        category: "AgentSessionLinkCatalog"
    )

    #if DEBUG
        private final class TestCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var isCapturing = false
            private var records: [Record] = []

            func begin() {
                lock.lock()
                records.removeAll(keepingCapacity: true)
                isCapturing = true
                lock.unlock()
            }

            func append(_ record: Record) {
                lock.lock()
                if isCapturing {
                    records.append(record)
                }
                lock.unlock()
            }

            func end() -> [Record] {
                lock.lock()
                defer { lock.unlock() }
                isCapturing = false
                return records
            }
        }

        private static let testCapture = TestCapture()

        static func beginCaptureForTesting() {
            testCapture.begin()
        }

        static func endCaptureForTesting() -> [Record] {
            testCapture.end()
        }
    #endif

    static func catalogPublished(
        runID: UUID,
        tabID: UUID?,
        connectionID: UUID?,
        revision: UInt64,
        routingGeneration: UInt64?,
        lifecycleGeneration: UInt64?,
        routePresent: Bool,
        catalog: Bool?,
        outbound: Bool?
    ) {
        emit(Record(
            event: .catalogPublished,
            outcome: nil,
            run: hashedID(runID),
            tab: hashedID(tabID),
            connection: hashedID(connectionID),
            revision: revision,
            routingGeneration: routingGeneration,
            lifecycleGeneration: lifecycleGeneration,
            routePresent: routePresent,
            catalog: Presence(catalog),
            outbound: Presence(outbound)
        ))
    }

    static func projectionEvaluated(
        runID: UUID,
        tabID: UUID,
        revision: UInt64,
        catalog: Bool?,
        outbound: Bool?,
        outcome: Outcome
    ) {
        emit(Record(
            event: .projectionEvaluated,
            outcome: outcome,
            run: hashedID(runID),
            tab: hashedID(tabID),
            connection: "nil",
            revision: revision,
            routingGeneration: nil,
            lifecycleGeneration: nil,
            routePresent: nil,
            catalog: Presence(catalog),
            outbound: Presence(outbound)
        ))
    }

    static func repairTransition(runID: UUID?, tabID: UUID, outcome: Outcome) {
        emit(Record(
            event: .repairTransition,
            outcome: outcome,
            run: hashedID(runID),
            tab: hashedID(tabID),
            connection: "nil",
            revision: nil,
            routingGeneration: nil,
            lifecycleGeneration: nil,
            routePresent: nil,
            catalog: nil,
            outbound: nil
        ))
    }

    static func toolCallReceived(runID: UUID?, tabID: UUID?, connectionID: UUID) {
        emit(Record(
            event: .toolCallReceived,
            outcome: nil,
            run: hashedID(runID),
            tab: hashedID(tabID),
            connection: hashedID(connectionID),
            revision: nil,
            routingGeneration: nil,
            lifecycleGeneration: nil,
            routePresent: nil,
            catalog: nil,
            outbound: nil
        ))
    }

    private static func emit(_ record: Record) {
        logger.notice("\(record.renderedLine, privacy: .public)")
        #if DEBUG
            testCapture.append(record)
        #endif
    }

    private static func hashedID(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        let digest = SHA256.hash(data: Data(id.uuidString.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// App-owned synchronous implementation; the extracted contract never sees unhashed output.
struct AppAgentSessionLinkCatalogEventSink: AgentSessionLinkCatalogEventSink {
    func record(_ event: AgentSessionLinkCatalogEvent) {
        switch event {
        case let .catalogPublished(runID, tabID, connectionID, revision, routingGeneration, lifecycleGeneration, routePresent, catalog, outbound):
            AgentSessionLinkCatalogDiagnostics.catalogPublished(
                runID: runID,
                tabID: tabID,
                connectionID: connectionID,
                revision: revision,
                routingGeneration: routingGeneration,
                lifecycleGeneration: lifecycleGeneration,
                routePresent: routePresent,
                catalog: catalog,
                outbound: outbound
            )
        case let .projectionEvaluated(runID, tabID, revision, catalog, outbound, outcome):
            AgentSessionLinkCatalogDiagnostics.projectionEvaluated(
                runID: runID,
                tabID: tabID,
                revision: revision,
                catalog: catalog,
                outbound: outbound,
                outcome: outcome
            )
        case let .repairTransition(runID, tabID, outcome):
            AgentSessionLinkCatalogDiagnostics.repairTransition(runID: runID, tabID: tabID, outcome: outcome)
        case let .toolCallReceived(runID, tabID, connectionID):
            AgentSessionLinkCatalogDiagnostics.toolCallReceived(runID: runID, tabID: tabID, connectionID: connectionID)
        }
    }
}
