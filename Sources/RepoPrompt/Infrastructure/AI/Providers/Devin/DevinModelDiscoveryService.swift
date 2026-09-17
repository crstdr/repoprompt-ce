import Foundation

actor DevinModelDiscoveryService {
    static let shared = DevinModelDiscoveryService()

    enum Outcome: Equatable {
        case notInstalled
        case discovered(modelCount: Int)
        case noModelsAdvertised
        case failed(message: String)
    }

    typealias InstalledCheck = @Sendable () -> Bool
    typealias SessionRunner = @Sendable (DevinAgentConfig) async throws -> Int?

    private let isInstalled: InstalledCheck
    private let runSession: SessionRunner
    private var inFlight: Task<Outcome, Never>?
    private var lastAttempt: Outcome?
    private var waiterCount = 0

    init(
        isInstalled: @escaping InstalledCheck = { DevinRuntimeLocator.isInstalledSync() },
        runSession: @escaping SessionRunner = { config in
            try await DevinModelDiscoveryService.runThrowawaySession(config)
        }
    ) {
        self.isInstalled = isInstalled
        self.runSession = runSession
    }

    func discoverIfNeeded(force: Bool = false) async -> Outcome {
        if !force, inFlight == nil, let lastAttempt {
            return lastAttempt
        }
        waiterCount += 1
        let task: Task<Outcome, Never>
        if let inFlight {
            task = inFlight
        } else {
            task = Task { [isInstalled, runSession] in
                await AgentACPModelRegistry.shared.warmStandardStoreIfNeeded()
                if force {
                    await CLIEnvironmentCache.shared.invalidate()
                }
                guard isInstalled() else { return Outcome.notInstalled }
                do {
                    try Task.checkCancellation()
                    guard let count = try await runSession(
                        DevinAgentConfig(
                            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                            includeRepoPromptMCPServer: false
                        )
                    ), count > 0 else {
                        try Task.checkCancellation()
                        return .noModelsAdvertised
                    }
                    try Task.checkCancellation()
                    return .discovered(modelCount: count)
                } catch is CancellationError {
                    return .failed(message: "cancelled")
                } catch {
                    return .failed(message: error.localizedDescription)
                }
            }
            inFlight = task
        }
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.cancelSharedDiscoveryIfLastWaiter() }
        }
        waiterCount -= 1
        if waiterCount == 0 {
            inFlight = nil
        }
        if !Task.isCancelled,
           outcome != .notInstalled,
           outcome != .failed(message: "cancelled")
        {
            lastAttempt = outcome
        }
        return outcome
    }

    private func cancelSharedDiscoveryIfLastWaiter() {
        if waiterCount <= 1 {
            inFlight?.cancel()
        }
    }

    private static func runThrowawaySession(_ config: DevinAgentConfig) async throws -> Int? {
        let provider = DevinACPAgentProvider(config: config)
        let request = ACPRunRequest(
            agentKind: .devin,
            modelString: nil,
            workspacePath: nil,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let support = try await provider.support(for: request)
        guard case .supported = support else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Devin ACP is not available."
            )
        }

        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        do {
            try Task.checkCancellation()
            _ = try await controller.bootstrap()
            try Task.checkCancellation()
            let count = await controller.currentDiscoveredSessionModels()?.options.count
            await controller.shutdown()
            return count
        } catch {
            await controller.shutdown()
            throw error is CancellationError ? error : provider.normalizeError(error)
        }
    }
}
