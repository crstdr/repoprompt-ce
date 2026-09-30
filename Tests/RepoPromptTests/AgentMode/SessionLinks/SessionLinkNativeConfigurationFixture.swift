import Foundation
@testable import RepoPromptApp

/// Actor-owned fake receipt state. Every application intent supersedes earlier receipts, even
/// identical values. Tests that replace a process rotate its lifetime rather than reuse counters.
struct SessionLinkNativeConfigurationFixture {
    private var lifetime = UUID()
    private var generation: UInt64 = 0
    private var current: NativeAgentRuntimeConfigurationProof?

    mutating func apply() -> NativeAgentRuntimeConfigurationApplication {
        generation &+= 1
        let proof = NativeAgentRuntimeConfigurationProof(
            lifetime: lifetime, intentGeneration: generation, requestGeneration: generation
        )
        current = proof
        return .applied(proof)
    }

    mutating func replaceProcess() {
        lifetime = UUID()
        current = nil
    }

    func validate(_ proof: NativeAgentRuntimeConfigurationProof) throws {
        guard current == proof else { throw NativeAgentRuntimeControllerError.configurationNotCurrent }
    }
}
