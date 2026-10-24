import Foundation
import MCP
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AntigravityHeadlessBoundaryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

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
    func testMCPInteractiveSelectionAndDiscoveryPreserveAntigravity() async throws {
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

        let direct = try await AgentMCPSelectionResolver.resolve(modelID: "antigravity:\(model)", availability: availability)
        XCTAssertEqual(direct.agentRaw, AgentProviderKind.antigravity.rawValue)
        let role = try await AgentMCPSelectionResolver.resolve(
            modelID: "pair",
            availability: availability,
            roleSelectionProvider: { _, _ in .init(agent: .antigravity, modelRaw: model) }
        )
        XCTAssertEqual(role.agentRaw, AgentProviderKind.antigravity.rawValue)
        XCTAssertEqual(role.modelRaw, model)
        XCTAssertTrue(AgentModelCatalog.discoveryAgents(availability: availability).contains { $0.agent == .antigravity })
        XCTAssertFalse(AgentModelCatalog.discoveryAgents(availability: availability, surface: .headless).contains { $0.agent == .antigravity })
        do {
            _ = try await AgentMCPSelectionResolver.resolve(
                modelID: "antigravity:\(model)", availability: availability, surface: .headless
            )
            XCTFail("Expected headless selection to reject Antigravity")
        } catch {
            // Antigravity is interactive-only.
        }
        for modelID: String? in ["explore", nil] {
            do {
                _ = try await AgentMCPSelectionResolver.resolve(
                    modelID: modelID,
                    defaultTaskLabel: .explore,
                    availability: availability,
                    roleSelectionProvider: { _, _ in .init(agent: .antigravity, modelRaw: model) },
                    surface: .headless
                )
                XCTFail("Expected headless role selection to reject Antigravity")
            } catch {
                assertInteractiveOnlyRoleError(error)
            }
        }
    }

    @MainActor
    func testStoredExploreOverrideRejectsHeadlessResolutionBeforeDispatch() async throws {
        let registry = AgentACPModelRegistry.shared
        registry.test_reset(providerID: .antigravity)
        let settings = GlobalSettingsStore.shared
        let previousOverrides = settings.mcpAgentRoleOverrides(scope: .global)
        defer {
            settings.updateMCPAgentRoleOverrides(previousOverrides, scope: .global, commit: true)
            registry.test_reset(providerID: .antigravity)
        }
        let model = "gemini-test-model"
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(rawValue: model, displayName: model, description: nil, isDefault: true)],
                currentModelRaw: model
            ),
            for: .antigravity
        )
        MCPAgentRoleDefaultsService.setSelection(
            .init(agent: .antigravity, modelRaw: model), for: .explore, scope: .global
        )
        let effective = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(for: .explore, availability: availability))
        XCTAssertTrue(effective.hasStoredOverride)
        XCTAssertFalse(effective.overrideUnavailable)
        XCTAssertEqual(effective.effective.agent, .antigravity)

        for modelID: String? in ["explore", nil] {
            let interactive = try await AgentMCPSelectionResolver.resolve(
                modelID: modelID, defaultTaskLabel: .explore, availability: availability
            )
            XCTAssertEqual(interactive.agentRaw, AgentProviderKind.antigravity.rawValue)
            XCTAssertEqual(interactive.modelRaw, model)
            do {
                _ = try await AgentMCPSelectionResolver.resolve(
                    modelID: modelID, defaultTaskLabel: .explore, availability: availability, surface: .headless
                )
                XCTFail("Expected headless role selection to reject Antigravity")
            } catch {
                assertInteractiveOnlyRoleError(error)
            }

            let unavailable = AgentModelCatalog.AvailabilityContext(
                claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: true,
                cursorAvailable: true, grokBuildAvailable: true, antigravityAvailable: false
            )
            let fallback = try await AgentMCPSelectionResolver.resolve(
                modelID: modelID, defaultTaskLabel: .explore, availability: unavailable, surface: .headless
            )
            XCTAssertNotNil(fallback.agentRaw)
            XCTAssertNotEqual(fallback.agentRaw, AgentProviderKind.antigravity.rawValue)
        }
    }

    private func assertInteractiveOnlyRoleError(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case let MCPError.invalidParams(detail) = error, let detail else {
            return XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
        XCTAssertTrue(detail.contains("antigravity"), file: file, line: line)
        XCTAssertTrue(detail.contains("explore"), file: file, line: line)
        XCTAssertTrue(detail.contains("interactive Agent Mode"), file: file, line: line)
        XCTAssertTrue(detail.contains("Agent Models settings"), file: file, line: line)
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
            XCTAssertEqual(detail, "Headless execution is not supported for this provider.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await provider.dispose()
    }
}

final class AgentMCPSelectionResolverTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = try WorkspaceTestProcessSandbox.validate()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    private let openCodeOnly = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.openCode)
    private let globalModel = "rolepin/global"
    private let workspaceModel = "rolepin/workspace"
    private let interactiveModel = "rolepin-interactive"

    @MainActor
    func testRecommendationlessPinsUseEffectiveWorkspaceProfileAndParameters() async throws {
        try await withFixture { settings in
            let workspaceID = UUID()
            let globalProfile = profile(settings, model: globalModel, effort: "high")
            let workspaceProfile = profile(settings, model: workspaceModel, effort: "low")
            settings.setGlobalAgentModelsProfile(globalProfile, contextBuilderWriteIntent: .preserveExistingOwnership)
            settings.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)
            settings.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)

            for label in ["global", "workspace", "inherited"] {
                let targetID: UUID? = label == "global" ? nil : workspaceID
                let expectedModel = label == "workspace" ? workspaceModel : globalModel
                let surface: AgentModelCatalog.AgentSelectionSurface = label == "inherited" ? .headless : .general
                if label == "inherited" {
                    settings.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useGlobalSettings)
                    XCTAssertEqual(settings.workspaceAgentModelsProfile(for: workspaceID)?.mcpAgentRoleOverrides?["pair"], "openCode:\(workspaceModel)")
                }
                let effectiveProfile = settings.effectiveAgentModelsProfile(workspaceID: targetID)
                let parameters = try XCTUnwrap(effectiveProfile.mcpAgentRoleModelParameters?["pair"], label)
                XCTAssertEqual(parameters, [parameter(model: expectedModel, effort: label == "workspace" ? "low" : "high")], label)
                let pin = try XCTUnwrap(MCPAgentRoleDefaultsService.executableStoredSelection(
                    for: .pair, overrides: effectiveProfile.mcpAgentRoleOverrides,
                    roleModelParameters: effectiveProfile.mcpAgentRoleModelParameters, availability: openCodeOnly
                ), label)
                XCTAssertEqual(pin.selection.agent, .openCode, label)
                XCTAssertEqual(pin.selection.modelRaw, expectedModel, label)
                XCTAssertEqual(pin.modelParameters, parameters, label)
                XCTAssertNil(MCPAgentRoleDefaultsService.effectiveSelection(for: .pair, availability: openCodeOnly, workspaceID: targetID), label)

                for modelID: String? in ["pair", nil] {
                    do {
                        let result = try await AgentMCPSelectionResolver.resolve(
                            modelID: modelID, defaultTaskLabel: .pair, availability: openCodeOnly,
                            workspaceID: targetID, surface: surface
                        )
                        assertSelection(result, agent: .openCode, model: expectedModel, role: .pair, parameters: parameters, label: "\(label), modelID=\(modelID ?? "omitted")")
                    } catch {
                        XCTFail("\(label), modelID=\(modelID ?? "omitted"): executable pin was rejected: \(error)")
                    }
                }
            }
        }
    }

    @MainActor
    func testIneligiblePinOnlyCandidatesPreserveExistingFallback() async throws {
        try await withFixture { settings in
            let globalProfile = profile(settings, model: globalModel, effort: "high")
            settings.setGlobalAgentModelsProfile(globalProfile, contextBuilderWriteIntent: .preserveExistingOwnership)
            let workspaceID = UUID()
            let cases: [(String, String?, AgentModelCatalog.AvailabilityContext, AgentModelCatalog.AgentSelectionSurface)] = [
                ("missing workspace role", nil, openCodeOnly, .general),
                ("malformed pin", "not-a-compound-id", openCodeOnly, .general),
                ("unavailable provider", "openCode:\(globalModel)", .none, .general),
                ("missing catalog model", "openCode:rolepin/missing", openCodeOnly, .general),
                ("interactive-only candidate", "antigravity:\(interactiveModel)", .none.assumingAvailable(.antigravity), .headless)
            ]
            for (label, override, availability, surface) in cases {
                var candidate = globalProfile
                candidate.mcpAgentRoleOverrides = override.map { ["pair": $0] } ?? [:]
                settings.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: candidate)
                settings.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
                XCTAssertEqual(settings.globalAgentModelsProfile().mcpAgentRoleOverrides?["pair"], "openCode:\(globalModel)", label)
                XCTAssertNil(MCPAgentRoleDefaultsService.effectiveSelection(for: .pair, availability: availability, workspaceID: workspaceID), label)
                let effectiveProfile = settings.effectiveAgentModelsProfile(workspaceID: workspaceID)
                let pin = MCPAgentRoleDefaultsService.executableStoredSelection(
                    for: .pair, overrides: effectiveProfile.mcpAgentRoleOverrides,
                    roleModelParameters: effectiveProfile.mcpAgentRoleModelParameters, availability: availability
                )
                if label == "interactive-only candidate" {
                    let executable = try XCTUnwrap(pin, label)
                    XCTAssertEqual(executable.selection.agent, .antigravity)
                    XCTAssertFalse(surface.allows(executable.selection.agent))
                } else {
                    XCTAssertNil(pin, label)
                }
                let omitted = try await AgentMCPSelectionResolver.resolve(
                    modelID: nil, defaultTaskLabel: .pair, availability: availability,
                    workspaceID: workspaceID, surface: surface
                )
                assertSelection(omitted, agent: nil, model: nil, role: nil, label: label)
                do {
                    _ = try await AgentMCPSelectionResolver.resolve(
                        modelID: "pair", availability: availability, workspaceID: workspaceID, surface: surface
                    )
                    XCTFail("\(label): expected unavailable role to be rejected")
                } catch {
                    switch error {
                    case let MCPError.invalidParams(message):
                        XCTAssertEqual(message, "No available agent/model for task label 'pair'.", label)
                    default:
                        XCTFail("\(label): unexpected error \(error)")
                    }
                }
            }
            // Same valid interactive pin is eligible on general; only headless must retain nil.
            let general = try await AgentMCPSelectionResolver.resolve(
                modelID: nil, defaultTaskLabel: .pair, availability: .none.assumingAvailable(.antigravity),
                workspaceID: workspaceID, surface: .general
            )
            assertSelection(general, agent: .antigravity, model: interactiveModel, role: .pair, label: "eligible general control")
        }
    }

    @MainActor
    func testExistingSelectionPrecedenceAndNonRoleBehaviorRemainUnchanged() async throws {
        try await withFixture { settings in
            settings.setGlobalAgentModelsProfile(profile(settings, model: globalModel, effort: "high"), contextBuilderWriteIntent: .preserveExistingOwnership)
            let provided = try await AgentMCPSelectionResolver.resolve(
                modelID: "pair", availability: openCodeOnly,
                roleSelectionProvider: { _, _ in .init(agent: .openCode, modelRaw: self.workspaceModel) }
            )
            assertSelection(provided, agent: .openCode, model: workspaceModel, role: .pair, label: "provider precedence")

            let noDefault = try await AgentMCPSelectionResolver.resolve(modelID: nil, availability: openCodeOnly)
            assertSelection(noDefault, agent: nil, model: nil, role: nil, label: "no default")
            let compound = try await AgentMCPSelectionResolver.resolve(modelID: "openCode:\(workspaceModel)", availability: openCodeOnly)
            assertSelection(compound, agent: .openCode, model: workspaceModel, role: nil, label: "compound ID")

            let recommendedAvailability = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.codexExec)
            let effective = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(for: .pair, availability: recommendedAvailability))
            XCTAssertTrue(effective.hasStoredOverride)
            XCTAssertTrue(effective.overrideUnavailable)
            XCTAssertEqual(effective.effective.agent, .codexExec)
            XCTAssertEqual(effective.modelParameters, [])
            let fallback = try await AgentMCPSelectionResolver.resolve(modelID: "pair", availability: recommendedAvailability)
            assertSelection(fallback, agent: effective.effective.agent, model: effective.effective.modelRaw, role: .pair, label: "existing unavailable-pin recommendation")
        }
    }

    @MainActor
    private func withFixture(_ body: (GlobalSettingsStore) async throws -> Void) async throws {
        let settings = GlobalSettingsStore.shared
        let originalProfile = settings.globalAgentModelsProfile()
        let registry = AgentACPModelRegistry.shared
        defer {
            settings.setGlobalAgentModelsProfile(originalProfile, contextBuilderWriteIntent: .preserveExistingOwnership)
            registry.test_reset(providerID: .openCode)
            registry.test_reset(providerID: .antigravity)
        }
        registry.test_reset(providerID: .openCode)
        registry.test_reset(providerID: .antigravity)
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [globalModel, workspaceModel].map {
                    AgentModelOption(rawValue: $0, displayName: $0, description: nil, isDefault: $0 == globalModel)
                },
                currentModelRaw: globalModel
            ), for: .openCode
        )
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(rawValue: interactiveModel, displayName: interactiveModel, description: nil, isDefault: true)],
                currentModelRaw: interactiveModel
            ), for: .antigravity
        )
        try await body(settings)
    }

    @MainActor
    private func profile(_ settings: GlobalSettingsStore, model: String, effort: String) -> AgentModelsSettingsProfile {
        var result = settings.globalAgentModelsProfile()
        result.mcpAgentRoleOverrides = ["pair": "openCode:\(model)"]
        result.mcpAgentRoleModelParameters = ["pair": [parameter(model: model, effort: effort)]]
        return result
    }

    private func parameter(model: String, effort: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(providerID: .openCode, baseModelRaw: model, kind: .thinking, configID: "effort", valueRaw: effort)
    }

    private func assertSelection(
        _ result: AgentMCPSelectionResolver.ResolvedSelection,
        agent: AgentProviderKind?, model: String?, role: AgentModelCatalog.TaskLabelKind?,
        parameters: [ACPModelParameterSelection] = [], label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.agentRaw, agent?.rawValue, label, file: file, line: line)
        XCTAssertEqual(result.modelRaw, model, label, file: file, line: line)
        XCTAssertEqual(result.taskLabelKind, role, label, file: file, line: line)
        XCTAssertEqual(result.modelParameterSelections, parameters, label, file: file, line: line)
        XCTAssertFalse(result.usageBalancingEligible, label, file: file, line: line)
    }
}
