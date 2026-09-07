import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AntigravityHeadlessBoundaryTests: XCTestCase {
    private let availability = AgentModelCatalog.AvailabilityContext(
        claudeCodeAvailable: true,
        codexAvailable: true,
        openCodeAvailable: true,
        cursorAvailable: true,
        grokBuildAvailable: true,
        antigravityAvailable: true
    )

    func testInteractiveCatalogIncludesAntigravityButHeadlessSurfaceExcludesIt() {
        XCTAssertTrue(AgentModelCatalog.selectableAgents(availability: availability).contains(.antigravity))
        XCTAssertFalse(AgentModelCatalog.selectableAgents(availability: availability, surface: .headless).contains(.antigravity))
    }

    @MainActor
    func testMCPInteractiveSelectionAndDiscoveryPreserveAntigravity() throws {
        let registry = AgentACPModelRegistry.shared
        registry.test_reset(providerID: .antigravity)
        defer { registry.test_reset(providerID: .antigravity) }
        let model = "gemini-test-model"
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(rawValue: model, displayName: model, description: nil, isDefault: true)],
                currentModelRaw: model
            ),
            for: .antigravity
        )

        let direct = try AgentMCPSelectionResolver.resolve(modelID: "antigravity:\(model)", availability: availability)
        XCTAssertEqual(direct.agentRaw, AgentProviderKind.antigravity.rawValue)
        let role = try AgentMCPSelectionResolver.resolve(
            modelID: "pair",
            availability: availability,
            roleSelectionProvider: { _, _ in .init(agent: .antigravity, modelRaw: model) }
        )
        XCTAssertEqual(role.agentRaw, AgentProviderKind.antigravity.rawValue)
        XCTAssertEqual(role.modelRaw, model)
        XCTAssertTrue(AgentModelCatalog.discoveryAgents(availability: availability).contains { $0.agent == .antigravity })
        XCTAssertFalse(AgentModelCatalog.discoveryAgents(availability: availability, surface: .headless).contains { $0.agent == .antigravity })
        XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
            modelID: "antigravity:\(model)", availability: availability, surface: .headless
        ))
        let headlessRole = try AgentMCPSelectionResolver.resolve(
            modelID: "explore",
            availability: availability,
            roleSelectionProvider: { _, _ in .init(agent: .antigravity, modelRaw: model) },
            surface: .headless
        )
        XCTAssertNotEqual(headlessRole.agentRaw, AgentProviderKind.antigravity.rawValue)
    }

    func testHeadlessFactoryFailsClosedInsteadOfFallingBackToAnotherProvider() async {
        let provider = AgentRuntimeProviderService.shared.makeProvider(for: .antigravity, modelString: "gemini-placeholder")
        XCTAssertTrue(provider is UnsupportedHeadlessAgentProvider)
        XCTAssertFalse(provider is CodexExecAgentProvider)
        XCTAssertFalse(provider is GrokBuildACPHeadlessAgentProvider)
        do {
            _ = try await provider.streamAgentMessage(AgentMessage(userMessage: "test"), runID: UUID())
            XCTFail("Expected unsupported headless execution to fail closed")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertTrue(detail.contains("interactive Agent Mode"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await provider.dispose()
    }
}
