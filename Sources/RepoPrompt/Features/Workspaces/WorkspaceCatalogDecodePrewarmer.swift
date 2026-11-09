import Foundation
import RepoPromptDomainRuntime

/// Constructed only from bytes whose digest was bound by the authority document.
// swiftformat:disable:next redundantSendable
struct WorkspaceCatalogDecodeInput: Sendable {
    let digest: String
    let bytes: Data

    init(_ document: DomainWorkspaceDocument) {
        digest = document.contentDigest
        bytes = document.documentBytes
    }
}

/// Single-flight cache preparation only. Synchronous consumers never wait on this registry.
final class WorkspaceCatalogDecodePrewarmer: @unchecked Sendable {
    private let lock = NSLock()
    private var flights: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    #if DEBUG
        let measurements = WorkspaceCatalogPrewarmMeasurements()
        private let beforeWork: @Sendable () async -> Void
        init(beforeWork: @escaping @Sendable () async -> Void = {}) {
            self.beforeWork = beforeWork
        }
    #endif

    func admit(_ input: WorkspaceCatalogDecodeInput) -> (task: Task<Void, Never>?, outcome: CatalogPrewarmOutcome) {
        guard input.bytes.count <= 16 * 1024 * 1024 else { return (nil, .oversized) }
        if let outcome = WorkspaceFileDecodeCache.shared.catalogPrewarmEligibility(input) { return (nil, outcome) }
        #if DEBUG
            let submitted = DispatchTime.now().uptimeNanoseconds
            let inherited = WorkspaceProjectionDecodeDiagnostics.context
            let context = inherited.map {
                WorkspaceProjectionDecodeDiagnostics.Context(
                    recorder: $0.recorder, contentOrdinal: $0.contentOrdinal, consumerOrdinal: $0.consumerOrdinal,
                    revision: $0.revision, schemaVersion: $0.schemaVersion, onMainActor: false
                )
            }
        #endif
        return lock.withLock {
            if let flight = flights[input.digest] { return (flight.task, .joined) }
            guard flights.isEmpty else { return (nil, .busy) }
            let token = UUID()
            // Completion uses the same lock, so even a cache-hit worker cannot retire before installation.
            let task = Task.detached(priority: .userInitiated) { [self] in
                defer { retire(input.digest, token: token) }
                let outcome: CatalogPrewarmOutcome
                #if DEBUG
                    measurements.start(Double(DispatchTime.now().uptimeNanoseconds - submitted) / 1_000_000)
                    await beforeWork()
                    outcome = WorkspaceProjectionDecodeDiagnostics.contextTaskLocal.withValue(context) {
                        WorkspaceProjectionDecodeDiagnostics.measure(inputBytes: input.bytes.count) {
                            WorkspaceFileDecodeCache.shared.prewarmCatalogDocument(input)
                        }
                    }
                #else
                    outcome = WorkspaceFileDecodeCache.shared.prewarmCatalogDocument(input)
                #endif
                CatalogPerf.shared.prewarm(outcome)
            }
            flights[input.digest] = (token, task)
            return (task, .started)
        }
    }

    private func retire(_ digest: String, token: UUID) {
        lock.withLock {
            guard flights[digest]?.token == token else { return }
            flights.removeValue(forKey: digest)
        }
    }

    #if DEBUG
        func awaitIdleForTesting() async {
            while let task = lock.withLock({ flights.values.first?.task }) {
                await task.value
            }
        }
    #endif
}
