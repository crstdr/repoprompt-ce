import Combine
import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

@MainActor
final class RecommendationWizardScopedTargetTests: XCTestCase {
    func testEditingScopeResolverMapsInheritanceToGlobalOrWorkspace() {
        let workspaceID = UUID()

        XCTAssertEqual(
            AgentModelsEditingScope.resolve(
                workspaceID: nil,
                inheritanceMode: .useWorkspaceOverrides
            ),
            .global
        )
        XCTAssertEqual(
            AgentModelsEditingScope.resolve(
                workspaceID: workspaceID,
                inheritanceMode: .useGlobalSettings
            ),
            .global
        )
        XCTAssertEqual(
            AgentModelsEditingScope.resolve(
                workspaceID: workspaceID,
                inheritanceMode: .useWorkspaceOverrides
            ),
            .workspace(workspaceID)
        )
    }

    func testQuickApplyGlobalTargetPreservesWorkspaceProfileAndUsesWorkspaceBookkeeping() throws {
        let fixture = try makeFixture()
        let workspace = WorkspaceModel(name: "Global Project", repoPaths: [])
        let sentinel = AIModel.claude4Sonnet.rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: sentinel,
                preferredComposeModelRaw: sentinel
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspace.id,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: sentinel,
                preferredComposeModelRaw: sentinel
            )
        )
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspace.id,
            mode: .useGlobalSettings
        )
        let manager = makeWorkspaceManager(workspaces: [workspace])
        let viewModel = RecommendationWizardViewModel(
            engine: fixture.engine,
            settingsStore: fixture.store,
            workspaceManager: manager
        )
        var receivedNotifications: [Notification] = []
        let notificationCancellable = NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .filter { ($0.object as? RecommendationWizardViewModel) === viewModel }
            .sink { receivedNotifications.append($0) }
        defer { notificationCancellable.cancel() }

        XCTAssertEqual(viewModel.agentModelsScopeLabel, "Agent Models: Global settings")
        XCTAssertTrue(viewModel.canApplyRecommendations)
        XCTAssertTrue(viewModel.applyActionScopeLabels.contains("Agent Models: Global settings"))
        XCTAssertTrue(viewModel.applyActionScopeLabels.contains("MCP Presets: Global settings"))

        let recommended = try recommendedOpenAIModelRaw(from: fixture.engine)
        viewModel.applyAllRecommendations()

        XCTAssertEqual(fixture.store.globalAgentModelsProfile().planningModelRaw, recommended)
        XCTAssertEqual(
            fixture.store.workspaceAgentModelsProfile(for: workspace.id)?.planningModelRaw,
            sentinel
        )
        XCTAssertTrue(fixture.engine.hasCompletedRecently(workspaceID: workspace.id))
        XCTAssertEqual(receivedNotifications.count, 1)
        let notification = try XCTUnwrap(receivedNotifications.first)
        XCTAssertEqual(
            notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String,
            AgentModelsSettingsNotification.Scope.global.rawValue
        )
        XCTAssertEqual(notification.userInfo?[AgentModelsSettingsNotification.sourceWorkspaceIDKey] as? UUID, workspace.id)
        XCTAssertNil(notification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey])
    }

    func testInheritanceChangeRecomputesWorkspaceTargetBeforeQuickApply() throws {
        let fixture = try makeFixture()
        let workspace = WorkspaceModel(name: "Scoped Project", repoPaths: [])
        let sentinel = AIModel.claude4Sonnet.rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: sentinel,
                preferredComposeModelRaw: sentinel
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspace.id,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: sentinel,
                preferredComposeModelRaw: sentinel
            )
        )
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspace.id,
            mode: .useGlobalSettings
        )
        let manager = makeWorkspaceManager(workspaces: [workspace])
        let viewModel = RecommendationWizardViewModel(
            engine: fixture.engine,
            settingsStore: fixture.store,
            workspaceManager: manager
        )
        var receivedNotifications: [Notification] = []
        let notificationCancellable = NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .filter { ($0.object as? RecommendationWizardViewModel) === viewModel }
            .sink { receivedNotifications.append($0) }
        defer { notificationCancellable.cancel() }

        XCTAssertEqual(viewModel.agentModelsScopeLabel, "Agent Models: Global settings")
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspace.id,
            mode: .useWorkspaceOverrides
        )

        XCTAssertEqual(viewModel.currentStep, .intro)
        XCTAssertEqual(viewModel.agentModelsScopeLabel, "Agent Models: Workspace — Scoped Project")
        XCTAssertTrue(viewModel.canApplyRecommendations)

        let recommended = try recommendedOpenAIModelRaw(from: fixture.engine)
        viewModel.applyAllRecommendations()

        XCTAssertEqual(fixture.store.globalAgentModelsProfile().planningModelRaw, sentinel)
        XCTAssertEqual(
            fixture.store.workspaceAgentModelsProfile(for: workspace.id)?.planningModelRaw,
            recommended
        )
        XCTAssertEqual(receivedNotifications.count, 2)
        let workspaceNotification = try XCTUnwrap(receivedNotifications.first { notification in
            notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
                == AgentModelsSettingsNotification.Scope.workspace.rawValue
        })
        let globalNotification = try XCTUnwrap(receivedNotifications.first { notification in
            notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
                == AgentModelsSettingsNotification.Scope.global.rawValue
        })
        XCTAssertEqual(
            workspaceNotification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID,
            workspace.id
        )
        XCTAssertNil(globalNotification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey])
        for notification in receivedNotifications {
            XCTAssertEqual(
                notification.userInfo?[AgentModelsSettingsNotification.sourceWorkspaceIDKey] as? UUID,
                workspace.id
            )
        }
    }

    func testPresetOnlyWorkspaceTargetNotifiesGlobalScope() throws {
        let fixture = try makeFixture()
        let workspace = WorkspaceModel(name: "Preset Project", repoPaths: [])
        let recommended = try recommendedOpenAIModelRaw(from: fixture.engine)
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspace.id,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: recommended,
                preferredComposeModelRaw: recommended
            )
        )
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspace.id,
            mode: .useWorkspaceOverrides
        )
        let manager = makeWorkspaceManager(workspaces: [workspace])
        let viewModel = RecommendationWizardViewModel(
            engine: fixture.engine,
            settingsStore: fixture.store,
            workspaceManager: manager
        )
        var receivedNotifications: [Notification] = []
        let notificationCancellable = NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .filter { ($0.object as? RecommendationWizardViewModel) === viewModel }
            .sink { receivedNotifications.append($0) }
        defer { notificationCancellable.cancel() }

        XCTAssertEqual(viewModel.applyActionScopeLabels, [viewModel.mcpPresetsScopeLabel])
        viewModel.nextStep()
        XCTAssertEqual(viewModel.currentStep, .presets)

        viewModel.applyCurrentStep()

        XCTAssertTrue(fixture.store.mcpShowModelPresets())
        XCTAssertTrue(fixture.store.mcpTemporarilyDisablePresets())
        XCTAssertEqual(receivedNotifications.count, 1)
        let notification = try XCTUnwrap(receivedNotifications.first)
        XCTAssertEqual(
            notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String,
            AgentModelsSettingsNotification.Scope.global.rawValue
        )
        XCTAssertNil(notification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey])
        XCTAssertEqual(
            notification.userInfo?[AgentModelsSettingsNotification.sourceWorkspaceIDKey] as? UUID,
            workspace.id
        )
    }

    func testWorkspaceSwitchCannotApplyPreviousWorkspaceRecommendations() throws {
        let fixture = try makeFixture()
        let first = WorkspaceModel(name: "First", repoPaths: [])
        let second = WorkspaceModel(name: "Second", repoPaths: [])
        let sentinel = AIModel.claude4Sonnet.rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: sentinel,
                preferredComposeModelRaw: sentinel
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        for workspaceID in [first.id, second.id] {
            fixture.store.setWorkspaceAgentModelsProfile(
                workspaceID: workspaceID,
                profile: AgentModelsSettingsProfile(
                    planningModelRaw: sentinel,
                    preferredComposeModelRaw: sentinel
                )
            )
        }
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: first.id,
            mode: .useGlobalSettings
        )
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: second.id,
            mode: .useWorkspaceOverrides
        )
        let manager = makeWorkspaceManager(workspaces: [first, second])
        let viewModel = RecommendationWizardViewModel(
            engine: fixture.engine,
            settingsStore: fixture.store,
            workspaceManager: manager
        )

        XCTAssertEqual(viewModel.agentModelsScopeLabel, "Agent Models: Global settings")
        manager.activeWorkspace = second
        XCTAssertEqual(manager.activeWorkspaceID, second.id)

        XCTAssertEqual(viewModel.currentStep, .intro)
        XCTAssertEqual(viewModel.agentModelsScopeLabel, "Agent Models: Workspace — Second")
        XCTAssertTrue(viewModel.canApplyRecommendations)

        let recommended = try recommendedOpenAIModelRaw(from: fixture.engine)
        viewModel.applyAllRecommendations()

        XCTAssertEqual(fixture.store.globalAgentModelsProfile().planningModelRaw, sentinel)
        XCTAssertEqual(
            fixture.store.workspaceAgentModelsProfile(for: first.id)?.planningModelRaw,
            sentinel
        )
        XCTAssertEqual(
            fixture.store.workspaceAgentModelsProfile(for: second.id)?.planningModelRaw,
            recommended
        )
    }

    private func recommendedOpenAIModelRaw(from engine: AutoRecommendationEngine) throws -> String {
        let recommendations = engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: UUID(), scope: .global),
            enabledProviders: [.openAI]
        )
        return try XCTUnwrap(recommendations.chatModel?.openAIOption?.modelString)
    }

    private func makeFixture() throws -> (
        store: GlobalSettingsStore,
        engine: AutoRecommendationEngine,
        apiSettings: APISettingsViewModel
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecommendationWizardScopedTargetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let suiteName = "RecommendationWizardScopedTargetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: temp.appendingPathComponent("Settings/globalSettings.json")
            )
        )
        store.installApplicationEventBridge()
        store.setGlobalRecommendationProviderFilter([.openAI])
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        apiSettings.openAIApiKey = "test-key"
        apiSettings.isOpenAIKeyValid = true
        let engine = AutoRecommendationEngine(
            settingsStore: store,
            profileSettingsManager: store,
            apiSettingsViewModel: apiSettings
        )
        return (store, engine, apiSettings)
    }

    private func makeWorkspaceManager(workspaces: [WorkspaceModel]) -> WorkspaceManagerViewModel {
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        manager.workspaces = workspaces
        manager.activeWorkspace = workspaces.first
        return manager
    }
}

@MainActor
final class StartupRecommendationBaselineTests: XCTestCase {
    private struct Owner {
        let workspace: WorkspaceModel
        let manager: WorkspaceManagerViewModel
        let api: APISettingsViewModel
        let engine: AutoRecommendationEngine
        var wizard: RecommendationWizardViewModel?
    }

    func testPreferredCodexFamilyUsesOneProductionWithLegacyResults() {
        let registry = AgentCodexModelRegistry.shared
        let originalLive = registry.currentLiveModels()
        let originalPersisted = UserDefaults.standard.object(forKey: "CodexDynamicModelRecords")
        defer {
            StartupRecommendationDiagnostics.end()
            registry.updateLiveModels(originalLive)
            UserDefaults.standard.set(originalPersisted, forKey: "CodexDynamicModelRecords")
            AgentAdvertisedModelCatalog.shared.invalidate(.codexExec)
        }
        let available = AgentModelCatalog.AvailabilityContext(codexAvailable: true)
        let persisted = [
            remote("gpt-6-luna", efforts: ["high"]),
            remote("gpt-6.1-sol", efforts: ["low"]),
            remote("gpt-6.1-sol-medium", efforts: [])
        ]
        registry.updateLiveModels([
            remote("gpt-6-luna", efforts: ["low"], isDefault: true),
            remote("gpt-6.1-sol", efforts: ["low", "medium", "high"])
        ])
        CodexDynamicModelStore.save(persisted)

        /// Preserve the original two-read algorithm as an output oracle for fixed catalog inputs.
        func legacyValue(_ family: String, effort: CodexReasoningEffort, availability: AgentModelCatalog.AvailabilityContext) -> String? {
            guard let option = AgentModelCatalog.preferredCodexFamilyOption(family, availability: availability),
                  let base = CodexModelSpecifier(raw: option.rawValue).baseModel else { return nil }
            let desired = "\(base)-\(effort.rawValue)"
            return AgentModelCatalog.options(for: .codexExec, availability: availability).contains {
                $0.rawValue.caseInsensitiveCompare(desired) == .orderedSame
            } ? desired : nil
        }
        func check(_ family: String, effort: CodexReasoningEffort, availability: AgentModelCatalog.AvailabilityContext, expected: String?) {
            StartupRecommendationDiagnostics.end()
            let legacy = legacyValue(family, effort: effort, availability: availability)
            XCTAssertEqual(legacy, expected, family)
            StartupRecommendationDiagnostics.begin()
            let actual = AgentModelCatalog.preferredCodexFamilyModelRaw(family, effort: effort, availability: availability)
            let counts = StartupRecommendationDiagnostics.snapshot()
            StartupRecommendationDiagnostics.end()
            XCTAssertEqual(actual, legacy, family)
            XCTAssertEqual(counts["family"], 1, family)
            XCTAssertEqual(counts["codexOptionsRequest"], 1, family)
            XCTAssertEqual(counts["codexOptionsProduction"], 1, family)
            XCTAssertEqual(counts["codexRecordAttempt"], availability.codexAvailable ? 1 : 0, family)
            XCTAssertEqual(counts["codexRecordAccepted"], availability.codexAvailable ? 1 : 0, family)
        }
        check("sol", effort: .high, availability: available, expected: "gpt-6.1-sol-high")
        check(" SOL ", effort: .medium, availability: available, expected: "gpt-6.1-sol-medium")
        check("luna", effort: .low, availability: available, expected: "gpt-6-luna-low")
        check("unknown", effort: .high, availability: available, expected: nil)
        check("", effort: .low, availability: available, expected: nil)
        check("sol", effort: .high, availability: .none, expected: nil)

        // The newest advertised family member lacks high effort; older static entries must not win.
        registry.updateLiveModels([remote("gpt-99-sol", efforts: ["low"], isDefault: true)])
        CodexDynamicModelStore.save(persisted)
        check("sol", effort: .high, availability: available, expected: nil)

        registry.updateLiveModels([remote("GPT-99.2-Sol", efforts: ["high"], isDefault: true)])
        CodexDynamicModelStore.save(persisted)
        let mixedCase = legacyValue("sOl", effort: .high, availability: available)
        XCTAssertEqual(mixedCase?.lowercased(), "gpt-99.2-sol-high")
        check("sOl", effort: .high, availability: available, expected: mixedCase)
    }

    func testRoleResolutionOutputsMatchFrozenReference() {
        let original = StandardEffortDefaultsFixture()
        defer { original.restore() }
        ClaudeAgentToolPreferences.setEffortLevel(.low, forModelRaw: AgentModel.claudeSonnet.rawValue, agentKind: .claudeCode)
        ClaudeAgentToolPreferences.setEffortLevel(.low, forModelRaw: AgentModel.claudeOpus.rawValue, agentKind: .claudeCode)
        CodexAgentToolPreferences.setLastUsedReasoningEffort(.high, forModelRaw: "unadvertised-pin")
        UserDefaults.standard.set("medium", forKey: "agentMode.codex.lastUsedReasoningEffort")
        let hostile = StandardEffortDefaultsFixture.snapshot()
        withConflictingCodexCatalog {
            let actual = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: false)
            let codexOnly = actual.filteredForRecommendationProviders([.codex])
            let pins = [
                "explore": "codexExec:gpt-6.1-sol-high",
                "engineer": "claudeCode:\(AgentModel.claudeSonnet.rawValue)",
                "pair": "codexExec:gpt-6.1-sol-medium",
                "design": "codexExec:unadvertised-pin"
            ]
            let display = [
                CodexAppServerClient.RemoteModel(id: "gpt-6.1-sol", model: "gpt-6.1-sol", displayName: "Display Sol", description: "Display only", isDefault: true, supportedReasoningEfforts: ["low", "medium", "high"].map { .init(reasoningEffort: $0, description: "") }, defaultReasoningEffort: "medium"),
                remote("gpt-99-sol", efforts: ["high"])
            ]
            let scenarios: [(String, AgentModelCatalog.AvailabilityContext, AgentModelCatalog.AvailabilityContext, [CodexAppServerClient.RemoteModel]?)] = [
                ("nil", actual, actual, nil),
                ("empty", actual, actual, []),
                ("display", actual, actual, display),
                ("collision", actual, actual, display + [remote("gpt-6.1-sol-medium", efforts: [])]),
                ("filtered", actual, codexOnly, nil),
                ("fallback", actual, .none, nil),
                ("unavailablePins", .none, codexOnly, nil),
                ("noAgents", .none, .none, nil)
            ]
            let expected = [
                "nil": "c86360da9e76aecdb2d229ded1b15311f907d64bc0fdfa31496b361ea80903aa",
                "empty": "81ac2ac8cc75a568c56698f979bfff0488f91084f4b11962be55c50e33209ea8",
                "display": "4754f6d86b028542cd290fbfc018a17f1f5c166b60b7e44aa56e543817bb2506",
                "collision": "4754f6d86b028542cd290fbfc018a17f1f5c166b60b7e44aa56e543817bb2506",
                "filtered": "bb54c3b24bac119ed0438c39240419e7348e9e9a397edd8d97b2f036a5345b85",
                "fallback": "c86360da9e76aecdb2d229ded1b15311f907d64bc0fdfa31496b361ea80903aa",
                "unavailablePins": "2e80c9b0cf6e6815621effce567793d2847c398ec3a5893e55c3d71da44c7b87",
                "noAgents": "821bf06b4dcb406ea508a4a992eadc22f29850cd208ba24aea7c29148de8ccf1"
            ]
            var outputs: [String: [MCPAgentRoleDefaultsService.RoleDefaultResolution]] = [:]
            for (name, availability, recommended, override) in scenarios {
                let store = AgentModelsProfileRoleDefaultsStore(overrides: pins)
                let rows = MCPAgentRoleDefaultsService.resolutions(availability: availability, recommendedAvailability: recommended, codexDynamicModels: override, settingsStore: store)
                XCTAssertEqual(rows, MCPAgentRoleDefaultsService.resolutions(availability: availability, recommendedAvailability: recommended, codexDynamicModels: override, settingsStore: store), name)
                let derived = rows.map { "\($0.selectionID.rawValue)|\(String(reflecting: $0.pinState))|\(String(reflecting: $0.thinkingParameterValueRaw))" }
                let value = String(reflecting: rows) + String(reflecting: derived)
                let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(digest, expected[name], name)
                outputs[name] = rows
            }
            for name in ["empty", "display", "collision"] {
                XCTAssertEqual(outputs[name]?.map(\.recommended), outputs["nil"]?.map(\.recommended), name)
            }
            XCTAssertNotEqual(outputs["nil"], outputs["empty"], "An empty display override must consult persistence instead of live records")
        }
        XCTAssertEqual(StandardEffortDefaultsFixture.snapshot(), hostile, "The fixture must restore the caller's effort preferences")
    }

    func testCodexOperationSeparatesInputsAndPreservesParsingAndLabels() throws {
        try withConflictingCodexCatalog {
            let actual = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: false)
            let filtered = actual.filteredForRecommendationProviders([.codex])
            func displayModel(_ label: String) -> CodexAppServerClient.RemoteModel {
                .init(id: "gpt-6.1-sol", model: "gpt-6.1-sol", displayName: label, description: "Display override", isDefault: true, supportedReasoningEfforts: ["low", "medium", "high"].map { .init(reasoningEffort: $0, description: "") }, defaultReasoningEffort: "medium")
            }
            let display = [displayModel("Display Sol")]
            let inputs: [(AgentModelCatalog.AvailabilityContext, [CodexAppServerClient.RemoteModel]?)] = [
                (actual, nil), (actual, []), (actual, display), (filtered, nil),
                (actual, [displayModel("Changed Display Sol")]),
                (actual, display + [remote("gpt-6.1-sol-medium", efforts: [])])
            ]
            let expected = inputs.map { AgentModelCatalog.options(for: .codexExec, availability: $0.0, codexDynamicModels: $0.1) }
            let operation = AgentModelCatalog.CodexOptionsOperation()
            StartupRecommendationDiagnostics.begin()
            for (index, input) in inputs.enumerated() {
                XCTAssertEqual(operation.options(availability: input.0, codexDynamicModels: input.1), expected[index])
                XCTAssertEqual(operation.options(availability: input.0, codexDynamicModels: input.1), expected[index])
            }
            let counts = StartupRecommendationDiagnostics.snapshot()
            StartupRecommendationDiagnostics.end()
            XCTAssertEqual(counts["codexOperationCapture"], inputs.count)
            XCTAssertEqual(counts["codexOperationHit"], inputs.count)
            XCTAssertEqual(counts["codexOptionsProduction"], inputs.count)
            XCTAssertEqual(counts["codexRecordAttempt"], 2, "Only the two canonical nil-override inputs may publish")
            XCTAssertEqual(counts["codexRecordAccepted"], 2)
            XCTAssertNotEqual(expected[0], expected[1], "nil uses live records; empty uses persisted records")
            XCTAssertEqual(expected[5].first { $0.rawValue == "gpt-6.1-sol-medium" }?.effortVariant, AgentModelEffortVariant(baseModelRaw: "gpt-6.1-sol", reasoningEffort: .medium))

            let suite = "CodexOperationLabels.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            CodexAgentToolPreferences.setLastUsedReasoningEffort(.high, forModelRaw: "gpt-6.1-sol", defaults: defaults)
            for input in inputs {
                for raw in ["gpt-6.1-sol", "gpt-6.1-sol-medium", "default", "unadvertised-pin"] {
                    let legacy = AgentModelCatalog.displayName(for: raw, agentKind: .codexExec, availability: input.0, codexDynamicModels: input.1, defaults: defaults)
                    XCTAssertEqual(AgentModelCatalog.displayName(for: raw, agentKind: .codexExec, availability: input.0, codexDynamicModels: input.1, defaults: defaults, codexOperation: operation), legacy)
                }
            }
            let defaultLabel = AgentModelCatalog.displayName(for: "gpt-6.1-sol", agentKind: .codexExec, codexDynamicModels: display, defaults: defaults)
            XCTAssertEqual(AgentModelCatalog.displayName(for: "gpt-6.1-sol", agentKind: .codexExec, codexDynamicModels: display, defaults: defaults, codexOperation: operation), defaultLabel)
            XCTAssertNotEqual(defaultLabel, AgentModelCatalog.displayName(for: "gpt-6.1-sol", agentKind: .codexExec, availability: .none, codexDynamicModels: display, defaults: defaults, codexOperation: operation))

            let old = operation.options(availability: actual)
            let raw = AgentModel.gpt54MiniMedium.rawValue
            XCTAssertNotNil(old.first { $0.rawValue == raw }?.effortVariant)
            CodexDynamicModelStore.save([remote(raw, efforts: [])])
            XCTAssertEqual(operation.options(availability: actual), old)
            let fresh = AgentModelCatalog.CodexOptionsOperation().options(availability: actual)
            XCTAssertEqual(fresh, AgentModelCatalog.options(for: .codexExec, availability: actual))
            XCTAssertNil(fresh.first { $0.rawValue == raw }?.effortVariant)
            XCTAssertNotEqual(fresh, old, "A fresh operation must observe direct persisted writes even with unchanged live records")
        }
    }

    func testRoleOperationPreservesModelParameterPins() throws {
        CursorDiscoveredCatalogTestSupport.reset()
        defer { CursorDiscoveredCatalogTestSupport.reset() }
        try withConflictingCodexCatalog {
            let available = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: false, cursorAvailable: true)
            let pin = ACPModelParameterSelection(providerID: .cursor, baseModelRaw: "future-cursor-pin", kind: .thinking, configID: "reasoning_effort", valueRaw: "xhigh")
            let store = AgentModelsProfileRoleDefaultsStore(overrides: ["engineer": "cursor:future-cursor-pin"], roleModelParameters: ["engineer": [pin]])
            let selected = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(for: .engineer, availability: available, recommendedAvailability: available.filteredForRecommendationProviders([.codex]), settingsStore: store))
            XCTAssertEqual(selected.selectionID.rawValue, "cursor:future-cursor-pin")
            XCTAssertEqual(selected.modelParameters, [pin])
            XCTAssertEqual(selected.thinkingParameterValueRaw, "xhigh")
            XCTAssertTrue(selected.hasStoredOverride)
            XCTAssertTrue(selected.hasCustomOverride)
            XCTAssertFalse(selected.overrideUnavailable)
            let unavailable = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(for: .engineer, availability: available.filteredForRecommendationProviders([.codex]), settingsStore: store))
            XCTAssertEqual(unavailable.effective, unavailable.recommended)
            XCTAssertTrue(unavailable.overrideUnavailable)
            XCTAssertEqual(unavailable.modelParameters, [])
            XCTAssertNil(unavailable.thinkingParameterValueRaw)
        }
    }

    func testCapturedOptionsRetainExistingPersistedParserSensitivity() {
        withConflictingCodexCatalog {
            let models = [remote("gpt-99-sol-high", efforts: []), remote("gpt-99-sol-medium", efforts: [])]
            AgentCodexModelRegistry.shared.updateLiveModels(models)
            CodexDynamicModelStore.save(models)
            let availability = AgentModelCatalog.AvailabilityContext()
            let operation = AgentModelCatalog.CodexOptionsOperation()
            let captured = operation.options(availability: availability)
            let before = AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .medium, availability: availability, precomputedOptions: captured)
            CodexDynamicModelStore.save([])
            let reused = AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .medium, availability: availability, precomputedOptions: captured)
            let fresh = AgentModelCatalog.preferredCodexFamilyModelRaw("sol", effort: .medium, availability: availability)
            XCTAssertEqual(before, "gpt-6.1-sol-medium")
            XCTAssertEqual(reused, "gpt-99-sol-medium")
            XCTAssertEqual(reused, fresh, "The reused array must retain the fresh producer's implicit persisted-parser semantics")
            XCTAssertEqual(operation.options(availability: availability), captured)
        }
    }

    func testRecorderIsolatesThreadsScopesAndStaleTimers() async {
        let owner = NSObject()
        let foreign = NSObject()
        StartupRecommendationDiagnostics.begin(timings: true, scopeCatalogCounts: true, scope: owner)
        defer { StartupRecommendationDiagnostics.end() }
        StartupRecommendationDiagnostics.count("delivery", scope: foreign)
        StartupRecommendationDiagnostics.enterCompute(scope: foreign)
        StartupRecommendationDiagnostics.count("compute")
        StartupRecommendationDiagnostics.count("catalog", catalog: true)
        XCTAssertNil(StartupRecommendationDiagnostics.start())
        StartupRecommendationDiagnostics.leaveCompute()
        StartupRecommendationDiagnostics.count("delivery", scope: owner)
        StartupRecommendationDiagnostics.enterCompute(scope: owner)
        StartupRecommendationDiagnostics.count("compute")
        StartupRecommendationDiagnostics.count("catalog", catalog: true)
        let token = StartupRecommendationDiagnostics.start()
        StartupRecommendationDiagnostics.finish("compute", since: token)
        StartupRecommendationDiagnostics.leaveCompute()
        let before = StartupRecommendationDiagnostics.snapshot()
        let background = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                StartupRecommendationDiagnostics.begin()
                StartupRecommendationDiagnostics.count("foreign")
                let count = StartupRecommendationDiagnostics.snapshot()["foreign"]
                StartupRecommendationDiagnostics.end()
                continuation.resume(returning: count)
            }
        }
        XCTAssertEqual(background, 1)
        XCTAssertEqual(StartupRecommendationDiagnostics.snapshot(), before)
        XCTAssertEqual(before.counts, ["delivery": 1, "compute": 1, "catalog": 1])
        XCTAssertEqual(before.durations["compute"]?.count, 1)
        StartupRecommendationDiagnostics.begin(timings: true, scope: owner)
        StartupRecommendationDiagnostics.finish("stale", since: token)
        XCTAssertEqual(StartupRecommendationDiagnostics.snapshot(), .init())
    }

    private struct TimingSummary {
        let computeSum: Double
        let computeUpperMiddle: Double
        let roleSum: Double
        let span: Double
    }

    private func timingSummary(_ snapshot: StartupRecommendationDiagnostics.Snapshot, expected: Int) -> TimingSummary? {
        guard expected > 0, let compute = snapshot.durations["compute"], compute.count == expected,
              let role = snapshot.durations["roleBatch"], role.count == expected,
              snapshot.durations["wizard"]?.count == expected,
              let first = snapshot.firstStart, let last = snapshot.lastEnd, last >= first else { return nil }
        return TimingSummary(
            computeSum: compute.reduce(0.0) { $0 + Double($1) } / 1e6,
            computeUpperMiddle: Double(compute.sorted()[expected / 2]) / 1e6,
            roleSum: role.reduce(0.0) { $0 + Double($1) } / 1e6,
            span: Double(last - first) / 1e6
        )
    }

    func testTimingSummaryRejectsEmptyPartialAndInvalidSamples() {
        var snapshot = StartupRecommendationDiagnostics.Snapshot()
        XCTAssertNil(timingSummary(snapshot, expected: 36))
        snapshot.durations = ["compute": [1_000_000], "roleBatch": [], "wizard": [1_200_000]]
        XCTAssertNil(timingSummary(snapshot, expected: 36))
        snapshot.durations = ["compute": [1_000_000], "roleBatch": [500_000], "wizard": [1_200_000]]
        XCTAssertNil(timingSummary(snapshot, expected: 1))
        snapshot.firstStart = 2
        snapshot.lastEnd = 1
        XCTAssertNil(timingSummary(snapshot, expected: 1))
        snapshot.lastEnd = 1_000_002
        XCTAssertNil(timingSummary(snapshot, expected: 0))
        XCTAssertEqual(timingSummary(snapshot, expected: 1)?.computeSum, 1)
        XCTAssertEqual(timingSummary(snapshot, expected: 1)?.roleSum, 0.5)
        XCTAssertEqual(timingSummary(snapshot, expected: 1)?.span, 1)
    }

    /// Role resolution reads these standard keys even when its profile store is isolated.
    private struct StandardEffortDefaultsFixture {
        private static let keys = [
            "claudeCodeEffortLevel", "claudeCodeEffortLevelsByModelSlug",
            "codexAgent.reasoning.lastUsedEffort", "agentMode.codex.lastUsedReasoningEffort",
            "codexAgent.reasoning.lastUsedEffortByModelSlug"
        ]
        private let saved: [(String, Any?)]

        init() {
            saved = Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
            UserDefaults.standard.set("high", forKey: Self.keys[0])
            UserDefaults.standard.set([String: String](), forKey: Self.keys[1])
            UserDefaults.standard.set("", forKey: Self.keys[2])
            UserDefaults.standard.set("", forKey: Self.keys[3])
            UserDefaults.standard.set([String: String](), forKey: Self.keys[4])
        }

        func restore() {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }

        static func snapshot() -> NSDictionary {
            NSDictionary(dictionary: UserDefaults.standard.dictionaryRepresentation().filter { keys.contains($0.key) })
        }
    }

    private struct StaticWork {
        let options: Int
        let parsers: Int
        let loads: Int
    }

    private func staticWorkPerProduction() -> StaticWork {
        let models = AgentModel.modelsForAgent(.codexExec)
        let effortCount = models.count(where: { CodexModelSpecifier(raw: $0.rawValue).reasoningEffort != nil })
        return StaticWork(
            options: models.count,
            parsers: models.count + effortCount,
            loads: models.count(where: { $0 != .defaultModel }) + effortCount
        )
    }

    func testStaticCatalogParserPathMatchesOriginalDefaultOverload() throws {
        try withConflictingCodexCatalog {
            let models: [AgentModel] = [.gpt54MiniMedium, .gpt61SolMax, .gpt6LunaMax]
            for collision in [false, true] {
                CodexDynamicModelStore.save(collision ? models.map { remote($0.rawValue, efforts: []) } : [])
                let work = staticWorkPerProduction()
                StartupRecommendationDiagnostics.begin()
                let options = AgentModelCatalog.options(for: .codexExec)
                let counts = StartupRecommendationDiagnostics.snapshot()
                StartupRecommendationDiagnostics.end()
                XCTAssertEqual(counts["staticOption"], work.options)
                XCTAssertEqual(counts["staticParser"], work.parsers)
                XCTAssertEqual(counts["staticPersistedLoad"], work.loads)
                for model in models {
                    // This is the original default-autoclosure expression, independent of the new helper.
                    let original = CodexModelSpecifier(raw: model.rawValue).reasoningEffort.flatMap { effort in
                        CodexModelSpecifier(raw: model.rawValue).baseModel.map {
                            AgentModelEffortVariant(baseModelRaw: $0, reasoningEffort: effort)
                        }
                    }
                    let actual = try XCTUnwrap(options.first { $0.rawValue == model.rawValue }, model.rawValue)
                    XCTAssertEqual(actual.effortVariant, original, "\(model.rawValue), collision=\(collision)")
                    XCTAssertEqual(original == nil, collision, model.rawValue)
                }
            }
        }
    }

    private func withConflictingCodexCatalog(_ body: () throws -> Void) rethrows {
        let efforts = StandardEffortDefaultsFixture()
        defer { efforts.restore() }
        let registry = AgentCodexModelRegistry.shared
        let originalLive = registry.currentLiveModels()
        let originalPersisted = UserDefaults.standard.object(forKey: "CodexDynamicModelRecords")
        defer {
            StartupRecommendationDiagnostics.end()
            registry.updateLiveModels(originalLive)
            UserDefaults.standard.set(originalPersisted, forKey: "CodexDynamicModelRecords")
            AgentAdvertisedModelCatalog.shared.invalidate(.codexExec)
        }
        registry.updateLiveModels([
            remote("gpt-6-luna", efforts: ["low"], isDefault: true),
            remote("gpt-6.1-sol", efforts: ["low", "medium", "high"])
        ])
        CodexDynamicModelStore.save([
            CodexAppServerClient.RemoteModel(id: "gpt-6.1-sol", model: "gpt-6.1-sol", displayName: "Persisted Sol", description: "Conflicting persistence", isDefault: true, supportedReasoningEfforts: [.init(reasoningEffort: "low", description: "")], defaultReasoningEffort: "low"),
            remote("gpt-6.1-sol-medium", efforts: [])
        ])
        try body()
    }

    func testRealSubscriptionBaselineIsRepeatable() async throws {
        let first = try await runCohort(timing: false)
        let second = try await runCohort(timing: false)
        XCTAssertEqual(first, second)
    }

    func testRepeatedWarmTimings() async throws {
        guard ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "1" else {
            throw XCTSkip("Set RPCE_RUN_SCALE_TESTS=1 after freezing the count baseline")
        }
        _ = try await runCohort(timing: true)
    }

    private struct Result: Equatable {
        var phases: [String: StartupRecommendationDiagnostics.Snapshot] = [:]
        var outputs: [String] = []
    }

    private func runCohort(timing: Bool) async throws -> Result {
        let efforts = StandardEffortDefaultsFixture()
        defer { efforts.restore() }
        let registry = AgentCodexModelRegistry.shared
        let originalLive = registry.currentLiveModels()
        let originalPersisted = UserDefaults.standard.object(forKey: "CodexDynamicModelRecords")
        defer {
            StartupRecommendationDiagnostics.end()
            registry.updateLiveModels(originalLive)
            UserDefaults.standard.set(originalPersisted, forKey: "CodexDynamicModelRecords")
            AgentAdvertisedModelCatalog.shared.invalidate(.codexExec)
        }
        let live = [remote("gpt-6-luna", efforts: ["low"], isDefault: true), remote("gpt-6.1-sol", efforts: ["low", "medium", "high"])]
        registry.updateLiveModels(live)
        // The registry projects live records while implicit parsing sees conflicting persisted exact IDs.
        CodexDynamicModelStore.save([
            remote("gpt-6-luna", efforts: ["high"]),
            remote("gpt-6.1-sol", efforts: ["low"]),
            remote("gpt-6.1-sol-medium", efforts: [])
        ])
        XCTAssertEqual(registry.currentLiveModels(), live)
        let seededPersistence = UserDefaults.standard.data(forKey: "CodexDynamicModelRecords")
        AgentAdvertisedModelCatalog.shared.invalidate(.codexExec)

        let suite = "StartupRecommendationBaselineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: directory.appendingPathComponent("settings.json")))
        store.installApplicationEventBridge()
        store.setGlobalRecommendationProviderFilter([.codex, .claudeCode])
        store.setMCPShowModelPresets(true)
        store.setMCPTemporarilyDisablePresets(true)
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: "codex:gpt-6.1-sol-high",
            contextBuilderAgentRaw: "codexExec",
            contextBuilderModelsByAgent: ["codexExec": "gpt-6-luna-low"],
            mcpAgentRoleOverrides: ["pair": "codexExec:gpt-6.1-sol-medium"]
        )
        store.setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .automaticSeed)
        XCTAssertFalse(store.hasUserSetGlobalContextBuilderAgentDefaults)
        var owners: [Owner] = []
        for index in 0 ..< 36 {
            let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1)))
            let workspace = WorkspaceModel(id: id, name: String(format: "Startup Owner %02d", index), repoPaths: [])
            store.setWorkspaceAgentModelsProfile(workspaceID: id, profile: profile)
            store.setWorkspaceAgentModelsInheritanceMode(workspaceID: id, mode: .useWorkspaceOverrides)
            let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
            let queries = AIQueriesService(keyManager: keys)
            let api = APISettingsViewModel(aiQueriesService: queries, keyManager: keys, loadStoredDataOnInit: false, antigravityRuntimeInstalledProvider: { false }, devinRuntimeInstalledProvider: { false })
            api.isCodexConnected = true
            api.isClaudeCodeConnected = true
            api.isCursorConnected = false
            api.isGrokBuildConnected = false
            api.isOpenCodeConnected = false
            api.isOpenAIKeyValid = false
            api.test_completeContextBuilderProviderValidation(verifiedProviders: [.codexExec, .claudeCode])
            let files = WorkspaceFilesViewModel()
            let windowID = -8000 - index
            let settings = WindowSettingsManager(windowID: windowID, store: store)
            let prompt = PromptViewModel(fileManager: files, aiQueriesService: queries, apiSettingsViewModel: api, windowID: windowID, settingsManager: settings, refreshAvailableModelsOnInit: false)
            let manager = WorkspaceManagerViewModel(fileManager: files, promptViewModel: prompt, performInitialWorkspaceActivation: false)
            manager.workspaces = [workspace]
            manager.activeWorkspace = workspace
            let engine = AutoRecommendationEngine(settingsStore: store, profileSettingsManager: store, apiSettingsViewModel: api)
            owners.append(Owner(workspace: workspace, manager: manager, api: api, engine: engine))
        }
        defer { owners.forEach { $0.api.prepareForWindowClose() } }
        await drain()
        let staticWork = staticWorkPerProduction()
        let globalBefore = store.globalAgentModelsProfile()
        let workspacesBefore = owners.map { store.workspaceAgentModelsSettings(for: $0.workspace.id) }
        var result = Result()
        let initializationStart = ContinuousClock.now
        StartupRecommendationDiagnostics.begin(scopeCatalogCounts: true, scope: store)
        for index in owners.indices {
            owners[index].wizard = RecommendationWizardViewModel(engine: owners[index].engine, settingsStore: store, workspaceManager: owners[index].manager, windowID: -8000 - index)
        }
        try await settle("initialization", key: "delivery.provider", count: 36, startedAt: initializationStart)
        result.phases["initialization"] = StartupRecommendationDiagnostics.snapshot()
        assertGolden(result.phases["initialization"], phase: "initialization", staticWork: staticWork)
        result.outputs = try owners.map { try output($0) }
        for value in result.outputs {
            XCTAssertEqual(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined(), "b9016f352407a47cde2501ea372bc82161fc91148db18390810dc9d4fc27c52d")
        }
        for owner in owners {
            XCTAssertEqual(owner.wizard?.providerStatus?.codexCLI, .ready)
            XCTAssertEqual(owner.wizard?.providerStatus?.claudeCodeCLI, .ready)
            XCTAssertEqual(owner.wizard?.recommendations.mcpAgentDefaults?.recommendedRoleDefaults.count, 4)
            XCTAssertTrue(owner.wizard?.recommendations.contextBuilder?.alreadySatisfied == true)
            XCTAssertFalse(owner.api.test_hasCodexModelsSubscriptionTask)
        }
        for phase in timing ? [] : ["provider", "validation", "settings", "didApply", "shouldRefresh", "workspaceCreation", "workspaceSwitch"] {
            let phaseStart = ContinuousClock.now
            StartupRecommendationDiagnostics.begin(scopeCatalogCounts: true, scope: store)
            switch phase {
            case "provider": owners.forEach { $0.api.isCodexConnected = true }
            case "validation": owners.forEach { $0.api.test_completeContextBuilderProviderValidation(verifiedProviders: [.codexExec, .claudeCode]) }
            case "settings": NotificationCenter.default.post(name: .agentModelsSettingsDidChange, object: nil, userInfo: AgentModelsSettingsNotification.userInfo(scope: .global))
            case "didApply": NotificationCenter.default.post(name: .recommendationsDidApply, object: nil)
            case "shouldRefresh": NotificationCenter.default.post(name: .recommendationsShouldRefresh, object: nil)
            case "workspaceCreation": NotificationCenter.default.post(name: .workspaceDidCreate, object: nil, userInfo: ["workspaceID": owners[0].workspace.id])
            default:
                owners.forEach { $0.manager.activeWorkspace = nil }
                await drain()
                owners.forEach { $0.manager.activeWorkspace = $0.workspace }
            }
            let key = phase == "workspaceSwitch" ? "refresh.workspaceTarget" : "refresh.\(phase)"
            try await settle(phase, key: key, count: 36, startedAt: phaseStart)
            result.phases[phase] = StartupRecommendationDiagnostics.snapshot()
            assertGolden(result.phases[phase], phase: phase, staticWork: staticWork)
            XCTAssertEqual(UserDefaults.standard.data(forKey: "CodexDynamicModelRecords"), seededPersistence, phase)
            XCTAssertEqual(registry.currentLiveModels(), live, phase)
            XCTAssertEqual(try owners.map { try output($0) }, result.outputs, phase)
            XCTAssertEqual(store.globalAgentModelsProfile(), globalBefore, phase)
            XCTAssertEqual(owners.map { store.workspaceAgentModelsSettings(for: $0.workspace.id) }, workspacesBefore, phase)
            XCTAssertFalse(store.hasUserSetGlobalContextBuilderAgentDefaults, phase)
        }
        if timing {
            for iteration in 0 ..< 10 {
                StartupRecommendationDiagnostics.begin(timings: true, scopeCatalogCounts: true, counts: false, scope: store)
                let sentinel = ResponsivenessSentinel()
                let sentinelTask = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                        sentinel.tick()
                    }
                }
                defer { sentinelTask.cancel() }
                await drain()
                let phaseStart = ContinuousClock.now
                let start = DispatchTime.now().uptimeNanoseconds
                NotificationCenter.default.post(name: .recommendationsShouldRefresh, object: nil)
                try await settle("timing", key: "wizard", count: 36, startedAt: phaseStart, timings: true)
                let end = DispatchTime.now().uptimeNanoseconds
                sentinel.tick()
                let snapshot = StartupRecommendationDiagnostics.snapshot()
                XCTAssertEqual(snapshot.counts, [:], "Timing must not collect operation counts")
                let summary = try XCTUnwrap(timingSummary(snapshot, expected: 36), "Incomplete or invalid timing samples")
                XCTAssertEqual(try owners.map { try output($0) }, result.outputs)
                XCTAssertEqual(store.globalAgentModelsProfile(), globalBefore)
                XCTAssertEqual(owners.map { store.workspaceAgentModelsSettings(for: $0.workspace.id) }, workspacesBefore)
                if iteration > 0 {
                    print("STARTUP_RECOMMENDATION_TIMING \(iteration) computeSumMs=\(summary.computeSum) computeUpperMiddleMs=\(summary.computeUpperMiddle) roleSumMs=\(summary.roleSum) mainActorSpanMs=\(summary.span) sentinelGapMs=\(Double(sentinel.maximumGap) / 1e6) endToEndMs=\(Double(end - start) / 1e6)")
                }
            }
        }
        return result
    }

    private func assertGolden(_ snapshot: StartupRecommendationDiagnostics.Snapshot?, phase: String, staticWork: StaticWork) {
        // Frozen counts for the unchanged populated, Codex+Claude fixture.
        let computes = phase == "initialization" ? 180 : (["provider", "workspaceCreation"].contains(phase) ? 72 : 36)
        var expected = [
            "compute": 1, "mcpCompute": 1, "roleBatch": 1,
            "candidateChain": 4, "family": 14, "codexValidation": 3, "codexLabel": 7,
            "codexOperationCapture": 2, "codexOperationHit": 11,
            "codexOptionsRequest": 5, "codexOptionsProduction": 5,
            "codexRecordAttempt": 5, "codexRecordAccepted": 5,
            "staticOption": 5 * staticWork.options,
            "staticParser": 5 * staticWork.parsers,
            "staticPersistedLoad": 5 * staticWork.loads
        ].mapValues { $0 * computes }
        if phase == "initialization" {
            expected.merge([
                "wizardInit": 36, "delivery.workspaceSelection": 36,
                "refresh.workspaceTarget": 36, "refresh.initializer": 36,
                "delivery.validation": 36, "refresh.validation": 36,
                "delivery.provider": 36, "refresh.provider": 36,
                "autoApplyEligibility": 36, "autoApplyCompute": 36
            ]) { _, new in new }
        } else if phase == "workspaceSwitch" {
            expected["delivery.workspaceSelection"] = 72
            expected["refresh.workspaceTarget"] = 36
        } else {
            expected["refresh.\(phase)"] = 36
            if phase == "settings" {
                expected["delivery.settingsImmediate"] = 36
                expected["delivery.settingsDebounced"] = 36
            } else {
                expected["delivery.\(phase)"] = 36
            }
            if ["provider", "workspaceCreation"].contains(phase) {
                expected["autoApplyEligibility"] = 36
                expected["autoApplyCompute"] = 36
            }
        }
        XCTAssertEqual(snapshot?.counts, expected, phase)
    }

    private func output(_ owner: Owner) throws -> String {
        let wizard = try XCTUnwrap(owner.wizard)
        XCTAssertEqual(wizard.target?.sourceWorkspaceID, owner.workspace.id)
        XCTAssertEqual(wizard.target?.scope, .workspace(owner.workspace.id))
        XCTAssertFalse(owner.engine.hasCompletedRecently(workspaceID: owner.workspace.id))
        for kind in RecommendationKind.allCases {
            XCTAssertFalse(owner.engine.isMuted(kind, workspaceID: owner.workspace.id))
        }
        // These value-only DTOs contain no unordered dictionaries or generated identities.
        return String(reflecting: wizard.recommendations) + String(reflecting: wizard.providerStatus)
            + String(reflecting: wizard.steps) + String(reflecting: wizard.currentStep)
            + wizard.selectedChatBackend.rawValue + String(wizard.hasActiveRecommendations)
    }

    @MainActor
    private final class ResponsivenessSentinel {
        private var lastTick = DispatchTime.now().uptimeNanoseconds
        private(set) var maximumGap: UInt64 = 0

        func tick() {
            let now = DispatchTime.now().uptimeNanoseconds
            maximumGap = max(maximumGap, now - lastTick)
            lastTick = now
        }
    }

    private func settle(_ phase: String, key: String, count: Int, startedAt: ContinuousClock.Instant, timings: Bool = false) async throws {
        // Slow baseline phases may complete, but each phase must stay within a bounded window.
        let deadline = startedAt.advanced(by: .seconds(60))
        func observedCount() -> Int {
            let snapshot = StartupRecommendationDiagnostics.snapshot()
            return timings ? snapshot.durations[key, default: []].count : snapshot[key]
        }
        while observedCount() < count {
            guard ContinuousClock.now < deadline else {
                XCTFail("Watchdog \(phase): \(StartupRecommendationDiagnostics.snapshot())")
                throw NSError(domain: "StartupRecommendationBaseline", code: 1)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard ContinuousClock.now < deadline else {
            XCTFail("Watchdog exceeded after delivery: \(phase)")
            throw NSError(domain: "StartupRecommendationBaseline", code: 2)
        }
        await drain()
        let snapshot = StartupRecommendationDiagnostics.snapshot()
        await drain()
        XCTAssertEqual(StartupRecommendationDiagnostics.snapshot(), snapshot, phase)
        XCTAssertEqual(observedCount(), count, phase)
    }

    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func remote(_ id: String, efforts: [String], isDefault: Bool = false) -> CodexAppServerClient.RemoteModel {
        CodexAppServerClient.RemoteModel(id: id, model: id, displayName: id, description: "Deterministic baseline", isDefault: isDefault, supportedReasoningEfforts: efforts.map { .init(reasoningEffort: $0, description: "") }, defaultReasoningEffort: efforts.first)
    }
}
