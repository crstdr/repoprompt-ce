import Foundation
@testable import RepoPromptApp
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
