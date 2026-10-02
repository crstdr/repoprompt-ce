import Foundation

/// Distinguishes turn authorization from provider settings that landed after newer intent.
enum NativeAgentRuntimeTurnConfigurationOutcome: Equatable {
    case applied, appliedButSuperseded, superseded
}

/// Ephemeral failure authority for one controller lifetime/intent, never an application receipt.
struct NativeAgentRuntimeConfigurationFailure: Error, LocalizedError {
    let underlyingError: any Error
    let lifetime: UUID
    let intentGeneration: UInt64
    let requestGeneration: UInt64
    var errorDescription: String? {
        underlyingError.localizedDescription
    }
}
