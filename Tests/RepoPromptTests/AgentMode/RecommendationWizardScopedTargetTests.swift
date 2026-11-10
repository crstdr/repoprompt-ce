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

        /// Preserve the M1 two-read algorithm as an output oracle for fixed catalog inputs.
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
        let globalBefore = store.globalAgentModelsProfile()
        let workspacesBefore = owners.map { store.workspaceAgentModelsSettings(for: $0.workspace.id) }
        var result = Result()
        let cohortStart = DispatchTime.now().uptimeNanoseconds
        let initializationStart = ContinuousClock.now
        StartupRecommendationDiagnostics.begin(scopeCatalogCounts: true)
        for index in owners.indices {
            owners[index].wizard = RecommendationWizardViewModel(engine: owners[index].engine, settingsStore: store, workspaceManager: owners[index].manager, windowID: -8000 - index)
        }
        try await settle("initialization", key: "delivery.provider", count: 36, startedAt: initializationStart)
        result.phases["initialization"] = StartupRecommendationDiagnostics.snapshot()
        assertGolden(result.phases["initialization"], phase: "initialization")
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
        for phase in ["provider", "validation", "settings", "didApply", "shouldRefresh", "workspaceCreation", "workspaceSwitch"] {
            let phaseStart = ContinuousClock.now
            StartupRecommendationDiagnostics.begin(scopeCatalogCounts: true)
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
            assertGolden(result.phases[phase], phase: phase)
            XCTAssertEqual(UserDefaults.standard.data(forKey: "CodexDynamicModelRecords"), seededPersistence, phase)
            XCTAssertEqual(registry.currentLiveModels(), live, phase)
            XCTAssertEqual(try owners.map { try output($0) }, result.outputs, phase)
            XCTAssertEqual(store.globalAgentModelsProfile(), globalBefore, phase)
            XCTAssertEqual(owners.map { store.workspaceAgentModelsSettings(for: $0.workspace.id) }, workspacesBefore, phase)
            XCTAssertFalse(store.hasUserSetGlobalContextBuilderAgentDefaults, phase)
        }
        for phase in result.phases.keys.sorted() {
            let counts = try XCTUnwrap(result.phases[phase]).counts.sorted { $0.key < $1.key }
            print("M2_COUNTS \(phase) \(counts)")
        }
        print("M2_COHORT_MS \(Double(DispatchTime.now().uptimeNanoseconds - cohortStart) / 1e6)")
        print("M2_OUTPUT_SHA256 \(SHA256.hash(data: Data(result.outputs[0].utf8)).map { String(format: "%02x", $0) }.joined())")
        if timing {
            for iteration in 0 ..< 10 {
                StartupRecommendationDiagnostics.begin(timings: true, scopeCatalogCounts: true)
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
                try await settle("timing", key: "refresh.shouldRefresh", count: 36, startedAt: phaseStart)
                let end = DispatchTime.now().uptimeNanoseconds
                sentinel.tick()
                let snapshot = StartupRecommendationDiagnostics.snapshot()
                XCTAssertEqual(snapshot["compute"], 36)
                let compute = snapshot.durations["compute", default: []].sorted()
                let role = snapshot.durations["roleBatch", default: []]
                print("M2_TIMING \(iteration) computeSumMs=\(Double(compute.reduce(0, +)) / 1e6) computeUpperMiddleMs=\(Double(compute[compute.count / 2]) / 1e6) roleSumMs=\(Double(role.reduce(0, +)) / 1e6) mainActorSpanMs=\(Double((snapshot.lastEnd ?? 0) - (snapshot.firstStart ?? 0)) / 1e6) sentinelGapMs=\(Double(sentinel.maximumGap) / 1e6) endToEndMs=\(Double(end - start) / 1e6)")
            }
        }
        return result
    }

    private func assertGolden(_ snapshot: StartupRecommendationDiagnostics.Snapshot?, phase: String) {
        // M2 production counts for the unchanged populated, Codex+Claude fixture.
        let computes = phase == "initialization" ? 180 : (["provider", "workspaceCreation"].contains(phase) ? 72 : 36)
        var expected = [
            "compute": 1, "mcpCompute": 1, "roleBatch": 1,
            "candidateChain": 4, "family": 14, "codexValidation": 3, "codexLabel": 7,
            "codexOptionsRequest": 24, "codexOptionsProduction": 24,
            "codexRecordAttempt": 24, "codexRecordAccepted": 24,
            "staticOption": 1320, "staticParser": 2568, "staticPersistedLoad": 2544
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

    private func settle(_ phase: String, key: String, count: Int, startedAt: ContinuousClock.Instant) async throws {
        // Slow baseline phases may complete, but each phase must stay within a bounded window.
        let deadline = startedAt.advanced(by: .seconds(60))
        while StartupRecommendationDiagnostics.snapshot()[key] < count {
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
        XCTAssertEqual(snapshot[key], count, phase)
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
