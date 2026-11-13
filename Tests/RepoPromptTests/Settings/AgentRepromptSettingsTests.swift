import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import SwiftUI
import XCTest

@MainActor
final class AgentRepromptSettingsTests: XCTestCase {
    private struct ContextCatalogClient: OpenCodeACPModelDiscoveryClient {
        func discoverModels(workspacePath: String?, modelRaw _: String?) async throws -> OpenCodeACPModelDiscoveryResult? {
            let count = workspacePath?.hasSuffix("-large") == true ? 393 : 38
            let options: [AgentModelOption] = (0 ..< count).map { index in
                .init(rawValue: "model-\(index)", displayName: "Model \(index)", description: nil, isPlaceholderDefault: false, isProviderDefault: index == 0)
            }
            return OpenCodeACPModelDiscoveryResult(catalog: ACPDiscoveredSessionModels(options: options, currentModelRaw: "model-0"), parameterState: nil)
        }
    }

    private actor ReplayGateClient: OpenCodeACPModelDiscoveryClient {
        private var calls = 0
        private var isOpen = false
        private var waiter: CheckedContinuation<Void, Never>?

        func discoverModels(workspacePath _: String?, modelRaw _: String?) async throws -> OpenCodeACPModelDiscoveryResult? {
            calls += 1
            let isFirst = calls == 1
            if !isFirst, !isOpen {
                await withCheckedContinuation { waiter = $0 }
            }
            let name = isFirst ? "replay-model" : "broadcast-model"
            let option = AgentModelOption(rawValue: name, displayName: name, description: nil, isPlaceholderDefault: false, isProviderDefault: true)
            return OpenCodeACPModelDiscoveryResult(catalog: ACPDiscoveredSessionModels(options: [option], currentModelRaw: name), parameterState: nil)
        }

        func open() {
            isOpen = true
            waiter?.resume()
            waiter = nil
        }
    }

    private final class StartupRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines.filter { $0.contains("phase=availableModelsUpdate ") }
        }

        func jobs() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines.filter { $0.contains("phase=openCodeCatalogJob ") }
        }
    }

    func testAvailableModelMarkersReportTriggersAndExactRepeatedResults() async throws {
        let recorder = StartupRecorder()
        StartupPhaseLog.installForTesting(.init(
            uptime: { ProcessInfo.processInfo.systemUptime },
            processStartUptime: 0,
            emit: { recorder.append($0) }
        ))
        defer { StartupPhaseLog.resetForTesting() }
        let (_, api) = try fixture(window: 19)
        defer { api.prepareForWindowClose() }
        api.isOpenAIKeyValid = true
        api.openAICustomModel = "private-test-model-do-not-log"
        await api.updateAvailableModels(trigger: .apiOwnerInitialLoad)
        await api.updateAvailableModels(trigger: .promptStartupRefresh)
        api.openAICustomModel = "different-private-test-model"
        await api.updateAvailableModels(trigger: .customModelEdit)
        let lines = recorder.snapshot()
        XCTAssertEqual(lines.count, 3)
        guard lines.count == 3 else { return }
        XCTAssertTrue(lines[0].contains("window=19 "))
        XCTAssertTrue(lines[0].contains("sameAsPrevious=0 ") && lines[0].hasSuffix("trigger=1"))
        XCTAssertTrue(lines[1].contains("sameAsPrevious=1 ") && lines[1].hasSuffix("trigger=2"))
        XCTAssertTrue(lines[2].contains("sameAsPrevious=0 ") && lines[2].hasSuffix("trigger=7"))
        XCTAssertTrue(lines[2].contains("models=\(api.availableModels.count) "))
        let groupCount = Set(api.availableModels.map(\.providerType)).count
        XCTAssertTrue(lines[2].contains("groups=\(groupCount) "))
        XCTAssertTrue(lines.allSatisfy { $0.contains("duration_ms=") && $0.contains("models=") && $0.contains("groups=") })
        XCTAssertFalse(lines.joined().contains("private-test-model"))
    }

    func testEveryAvailableModelTriggerHasOneIntegerOnlyMarker() async throws {
        let recorder = StartupRecorder()
        StartupPhaseLog.installForTesting(.init(
            uptime: { 100 }, processStartUptime: 0, emit: { recorder.append($0) }
        ))
        defer { StartupPhaseLog.resetForTesting() }
        let (_, api) = try fixture(window: 20)
        defer { api.prepareForWindowClose() }
        XCTAssertEqual(AvailableModelsUpdateTrigger.allCases.map(\.rawValue), Array(1 ... 25))
        for trigger in AvailableModelsUpdateTrigger.allCases {
            await api.updateAvailableModels(trigger: trigger)
        }
        let lines = recorder.snapshot()
        XCTAssertEqual(lines.count, 25)
        for (line, trigger) in zip(lines, AvailableModelsUpdateTrigger.allCases) {
            let keys = Set(line.split(separator: " ").compactMap { $0.split(separator: "=", maxSplits: 1).first }.map(String.init))
            XCTAssertEqual(keys, ["phase", "boundary", "window", "elapsed_ms", "duration_ms", "groups", "models", "sameAsPrevious", "trigger", "sourceProvider", "openCodeJob", "openCodeModels", "openCodeDelivery"])
            XCTAssertTrue(line.hasSuffix("trigger=\(trigger.rawValue)"))
            XCTAssertNotNil(line.wholeMatch(of: #/^phase=availableModelsUpdate boundary=event window=20 elapsed_ms=\d+( [a-zA-Z0-9_]+=\d+)*$/#))
        }
    }

    func testAvailableModelMarkerFromKeyValidationAndDeletion() async throws {
        let recorder = StartupRecorder()
        StartupPhaseLog.installForTesting(.init(
            uptime: { 100 }, processStartUptime: 0, emit: { recorder.append($0) }
        ))
        defer { StartupPhaseLog.resetForTesting() }
        let (_, api) = try fixture(window: 21)
        defer { api.prepareForWindowClose() }
        let valid = try await api.validateAndSaveKey(key: "test", for: .customProvider) { true }
        XCTAssertTrue(valid)
        try await api.deleteKey(for: .customProvider)
        let lines = recorder.snapshot()
        XCTAssertEqual(lines.count, 2)
        guard lines.count == 2 else { return }
        XCTAssertTrue(lines[0].hasSuffix("trigger=13"))
        XCTAssertTrue(lines[1].hasSuffix("trigger=14"))
    }

    func testAvailableModelAttributionThirtySixOwnerBudget() async throws {
        let recorder = StartupRecorder()
        StartupPhaseLog.installForTesting(.init(
            uptime: { ProcessInfo.processInfo.systemUptime }, processStartUptime: 0,
            emit: { recorder.append($0) }
        ))
        defer { StartupPhaseLog.resetForTesting() }
        var owners: [APISettingsViewModel] = []
        for window in 1 ... 36 {
            let (_, api) = try fixture(window: window)
            api.isOpenAIKeyValid = true
            owners.append(api)
        }
        defer { owners.forEach { $0.prepareForWindowClose() } }
        let start = ProcessInfo.processInfo.systemUptime
        for api in owners {
            for trigger in [
                AvailableModelsUpdateTrigger.apiOwnerInitialLoad, .promptStartupRefresh, .devinDiscovery,
                .customModelEdit, .customModelEdit, .providerModelSubscription, .providerModelSubscription
            ] {
                await api.updateAvailableModels(trigger: trigger)
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let lines = recorder.snapshot()
        XCTAssertEqual(lines.count, 252)
        XCTAssertLessThan(elapsed, 5)
        print("picker attribution fixture: owners=36 updates=252 lines=\(lines.count) wall_ms=\(elapsed * 1000)")
    }

    func testOpenCodeUnionAvoidsFanOutAcrossThirtySevenContexts() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        AgentACPModelRegistry.shared.installOpenCodeCatalogJobRecorder { fields in
            StartupPhaseLog.mark(.openCodeCatalogJob, fields: fields)
        }
        defer {
            AgentACPModelRegistry.shared.installOpenCodeCatalogJobRecorder(nil)
            AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        }
        let recorder = StartupRecorder()
        StartupPhaseLog.installForTesting(.init(
            uptime: { ProcessInfo.processInfo.systemUptime }, processStartUptime: 0,
            emit: { recorder.append($0) }
        ))
        defer { StartupPhaseLog.resetForTesting() }
        let service = OpenCodeACPModelPollingService(client: ContextCatalogClient())
        addTeardownBlock { await service.shutdown() }
        var owners: [APISettingsViewModel] = []
        var iterators: [AsyncStream<OpenCodeACPModelPollingService.Snapshot>.Iterator] = []
        for window in 1 ... 37 {
            let (_, api) = try fixture(window: window)
            api.isOpenCodeConnected = true
            owners.append(api)
            let stream = await service.subscribe(workspacePath: nil)
            iterators.append(stream.makeAsyncIterator())
        }
        defer { owners.forEach { $0.prepareForWindowClose() } }
        _ = try await service.discoverOnce(workspacePath: nil)
        for index in iterators.indices {
            let snapshot = await iterators[index].next()
            XCTAssertEqual(snapshot?.models.options.count, 38)
            await owners[index].updateAvailableModels(trigger: .providerModelSubscription, sourceProvider: .openCode, openCodeDelivery: snapshot?.isReplay == true ? 2 : 1)
        }
        var referenceCount = 38
        var referenceBroadcasts = 1
        let start = ProcessInfo.processInfo.systemUptime
        for context in 0 ..< 36 {
            let suffix = context.isMultiple(of: 2) ? "large" : "small"
            let nextReferenceCount = context.isMultiple(of: 2) ? 393 : 38
            if nextReferenceCount != referenceCount { referenceBroadcasts += 1 }
            referenceCount = nextReferenceCount
            _ = try await service.discoverOnce(workspacePath: "/context-\(context)-\(suffix)")
            XCTAssertEqual(AgentACPModelRegistry.shared.resolvedSnapshot(for: .openCode)?.options.count, 393)
            if context == 0 {
                for index in iterators.indices {
                    let snapshot = await iterators[index].next()
                    XCTAssertEqual(snapshot?.models.options.count, 393)
                    await owners[index].updateAvailableModels(trigger: .providerModelSubscription, sourceProvider: .openCode, openCodeDelivery: 1)
                }
            }
        }
        let lines = recorder.snapshot()
        XCTAssertEqual(lines.count, 74)
        XCTAssertTrue(lines.prefix(37).allSatisfy { $0.split(separator: " ").contains("openCodeModels=38") })
        XCTAssertTrue(lines.suffix(37).allSatisfy { $0.split(separator: " ").contains("openCodeModels=393") })
        XCTAssertTrue(lines.allSatisfy { $0.split(separator: " ").contains("sourceProvider=1") })
        let jobs = recorder.jobs()
        let broadcasts = jobs.filter { $0.split(separator: " ").contains("broadcast=1") }
        XCTAssertEqual(broadcasts.count, 2)
        func field(_ name: String, in line: String) -> String? {
            line.split(separator: " ").first { $0.hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        let initial = try XCTUnwrap(broadcasts.first)
        let expansion = try XCTUnwrap(broadcasts.last)
        XCTAssertEqual(field("canonical", in: initial), "38")
        XCTAssertEqual(field("canonical", in: expansion), "393")
        XCTAssertEqual(field("effectiveChanged", in: initial), "1")
        XCTAssertEqual(field("effectiveChanged", in: expansion), "1")
        let initialJob = try XCTUnwrap(field("job", in: initial))
        let expansionJob = try XCTUnwrap(field("job", in: expansion))
        XCTAssertTrue(lines.prefix(37).allSatisfy { field("openCodeJob", in: $0) == initialJob })
        XCTAssertTrue(lines.suffix(37).allSatisfy { field("openCodeJob", in: $0) == expansionJob })
        XCTAssertEqual(String(AgentACPModelRegistry.shared.openCodeSnapshotWithJobOrdinal().1), expansionJob)
        XCTAssertTrue(jobs.allSatisfy { ["38", "393"].contains(field("canonical", in: $0) ?? "") })
        XCTAssertFalse(jobs.joined().contains("context-"))
        XCTAssertEqual(referenceBroadcasts, 37)
        let elapsedMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print("openCode union fixture: contexts=37 owners=37 reference_last_writer_broadcasts=\(referenceBroadcasts) reference_updates=\(referenceBroadcasts * 37) after_broadcasts=2 after_updates=\(lines.count) wall_ms=\(elapsedMS)")
        await service.shutdown()
    }

    func testOpenCodeSubscriptionRecordsReplayThenBroadcast() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer {
            AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
            StartupPhaseLog.resetForTesting()
        }
        let replay = expectation(description: "subscription replay")
        let broadcast = expectation(description: "changed catalog broadcast")
        let recorder = StartupRecorder()
        StartupPhaseLog.installForTesting(.init(
            uptime: { ProcessInfo.processInfo.systemUptime }, processStartUptime: 0,
            emit: { line in
                recorder.append(line)
                let tokens = line.split(separator: " ")
                guard tokens.contains("phase=availableModelsUpdate") else { return }
                if tokens.contains("openCodeDelivery=2") { replay.fulfill() }
                if tokens.contains("openCodeDelivery=1") { broadcast.fulfill() }
            }
        ))
        let client = ReplayGateClient()
        let service = OpenCodeACPModelPollingService(client: client)
        addTeardownBlock {
            await client.open()
            await service.shutdown()
        }
        _ = try await service.discoverOnce(workspacePath: nil)
        let (_, api) = try fixture(window: 37)
        defer { api.prepareForWindowClose() }
        api.isOpenCodeConnected = true
        api.test_startOpenCodeSubscription(service: service)
        await fulfillment(of: [replay], timeout: 5)
        await client.open()
        await fulfillment(of: [broadcast], timeout: 5)
        let lines = recorder.snapshot()
        XCTAssertEqual(lines.count, 2)
        for (line, delivery) in zip(lines, [2, 1]) {
            let tokens = line.split(separator: " ")
            XCTAssertTrue(tokens.contains("sourceProvider=1"))
            XCTAssertTrue(tokens.contains(Substring("openCodeDelivery=\(delivery)")))
        }
    }

    func testOpenCodeParameterJobLogsBootstrapCatalog() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        AgentACPModelRegistry.shared.installOpenCodeCatalogJobRecorder { fields in
            StartupPhaseLog.mark(.openCodeCatalogJob, fields: fields)
        }
        defer {
            AgentACPModelRegistry.shared.installOpenCodeCatalogJobRecorder(nil)
            AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
            StartupPhaseLog.resetForTesting()
        }
        let recorder = StartupRecorder()
        StartupPhaseLog.installForTesting(.init(
            uptime: { ProcessInfo.processInfo.systemUptime }, processStartUptime: 0,
            emit: { recorder.append($0) }
        ))
        let service = OpenCodeACPModelPollingService(client: ContextCatalogClient())
        addTeardownBlock { await service.shutdown() }
        _ = try await service.discoverModelParametersOnce(workspacePath: "/workspace-b", modelRaw: "private-model", forceRefresh: true)
        let jobs = recorder.jobs()
        XCTAssertEqual(jobs.count, 1)
        let job = try XCTUnwrap(jobs.first)
        XCTAssertTrue(job.contains("kind=2 ") && job.contains("origin=16 "))
        XCTAssertTrue(job.contains("hadPrior=0 ") && job.contains("priorLive=0 "))
        XCTAssertFalse(job.contains("private-model"))
        XCTAssertFalse(job.contains("workspace-b"))
        await service.shutdown()
    }

    func testAvailableModelEqualityCostForLargeIndependentArrays() {
        let left: [AIModel] = (0 ..< 355).map { .openaiCustom(name: "model-\($0)") }
        let right: [AIModel] = (0 ..< 355).map { .openaiCustom(name: "model-\($0)") }
        var equalCount = 0
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0 ..< 252 {
            if left == right { equalCount += 1 }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(equalCount, 252)
        print("picker equality: comparisons=252 models=355 wall_ms=\(elapsed * 1000)")
    }

    func testSavingOnlyModelModeOrHistoryDoesNotFreezeDefaultGuidance() throws {
        for baseline in [nil, "Custom user wording"] as [String?] {
            for field in 0 ..< 3 {
                let (store, api) = try fixture()
                store.setGlobalAgentModelsProfile(.init(agentRepromptGuidance: baseline), contextBuilderWriteIntent: .preserveExistingOwnership)
                let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, settingsManager: store, settingsStore: store)
                switch field {
                case 0: vm.repromptModelDraft = AIModel.gpt61SolLow.rawValue
                case 1: vm.repromptModeDraft = .sendAutomatically
                default: vm.repromptRecentChatDraft = false
                }
                XCTAssertTrue(vm.saveRepromptDraft())
                XCTAssertEqual(store.globalAgentModelsProfile().agentRepromptGuidance, baseline)
                if baseline != nil {
                    vm.repromptGuidanceDraft = " \n" + AgentRepromptGuidance.defaultText + "\n "
                    XCTAssertTrue(vm.saveRepromptDraft())
                    XCTAssertNil(store.globalAgentModelsProfile().agentRepromptGuidance)
                }
                XCTAssertTrue(vm.restoreDefaultRepromptGuidance())
                XCTAssertNil(store.globalAgentModelsProfile().agentRepromptGuidance)
            }
        }
    }

    func testScopedDraftSaveDefaultAndUnrelatedWritesPreserveFields() throws {
        for workspaceID in [nil, UUID()] {
            let (store, api) = try fixture()
            let global = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt61Sol.rawValue, agentRepromptGuidance: "Global wording")
            store.setGlobalAgentModelsProfile(global, contextBuilderWriteIntent: .preserveExistingOwnership)
            if let workspaceID {
                store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: .init())
            }
            let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, workspaceID: workspaceID, settingsManager: store, settingsStore: store, notificationCenter: NotificationCenter())
            vm.repromptGuidanceDraft = "  My voice\nKeep uncertainty. \n"
            vm.repromptModelDraft = "specific-model"
            vm.repromptModeDraft = .sendAutomatically
            vm.repromptRecentChatDraft = false
            XCTAssertTrue(vm.isRepromptDraftDirty)
            XCTAssertNotEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptModelRaw, "specific-model")
            XCTAssertTrue(vm.saveRepromptDraft())
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptGuidance, "My voice\nKeep uncertainty.")
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptModelRaw, "specific-model")
            vm.setOracleModel(raw: AIModel.gpt61Sol.rawValue)
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptModelRaw, "specific-model")
            XCTAssertTrue(vm.restoreDefaultRepromptGuidance())
            XCTAssertEqual(vm.repromptGuidanceDraft, AgentRepromptGuidance.defaultText)
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptModelRaw, "specific-model", "Restoring guidance must not reset model or mode")
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptMode, .sendAutomatically)
            XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).agentRepromptIncludesRecentChat, false)
            if workspaceID != nil {
                XCTAssertEqual(store.globalAgentModelsProfile(), global)
            }
        }
    }

    func testDefaultPickerPresentsConcreteConnectedSubscriptionWithoutPersistingAChoice() async throws {
        let (store, api) = try fixture()
        api.isClaudeCodeConnected = true
        await api.updateAvailableModels(trigger: .customModelToggle)
        let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, settingsManager: store, settingsStore: store)
        XCTAssertEqual(vm.resolvedRepromptDraftModel, AgentRepromptModelPolicy.preferredClaude)
        let picker = AgentRepromptModelPicker(selection: Binding(get: { vm.repromptModelDraft }, set: { vm.repromptModelDraft = $0 }), availableModels: api.availableModels, resolvedModel: vm.resolvedRepromptDraftModel)
        XCTAssertEqual(picker.concreteSelection.wrappedValue, AgentRepromptModelPolicy.preferredClaude.rawValue)
        XCTAssertTrue(vm.repromptModelDraft.isEmpty)
        XCTAssertFalse(vm.isRepromptDraftDirty)
        picker.concreteSelection.wrappedValue = AIModel.gpt61SolLow.rawValue
        XCTAssertEqual(vm.repromptModelDraft, AIModel.gpt61SolLow.rawValue)
        XCTAssertTrue(vm.isRepromptDraftDirty)
    }

    func testModeAndHistoryConflictsRefuseStaleSaves() throws {
        let (store, api) = try fixture()
        let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, settingsManager: store, settingsStore: store)
        XCTAssertEqual(vm.repromptModeDraft, .review)
        XCTAssertTrue(vm.repromptRecentChatDraft)
        vm.repromptModeDraft = .sendAutomatically
        var external = store.globalAgentModelsProfile()
        external.agentRepromptIncludesRecentChat = false
        store.setGlobalAgentModelsProfile(external, contextBuilderWriteIntent: .preserveExistingOwnership)
        XCTAssertFalse(vm.saveRepromptDraft())
        XCTAssertTrue(vm.repromptDraftHasConflict)
        vm.reloadRepromptDraft()
        XCTAssertFalse(vm.repromptRecentChatDraft)
        XCTAssertEqual(vm.repromptModeDraft, .review)
    }

    func testStaleScopeAndExternalGuidanceCannotOverwriteWithoutReload() throws {
        let (store, api) = try fixture()
        let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, settingsManager: store, settingsStore: store, notificationCenter: NotificationCenter())
        vm.repromptGuidanceDraft = "Unsaved draft"
        var external = store.globalAgentModelsProfile()
        external.agentRepromptGuidance = "External edit"
        store.setGlobalAgentModelsProfile(external, contextBuilderWriteIntent: .preserveExistingOwnership)
        XCTAssertFalse(vm.saveRepromptDraft(), "Live/cache guard must refuse a stale click.")
        XCTAssertTrue(vm.repromptDraftHasConflict)
        XCTAssertEqual(vm.repromptGuidanceDraft, "Unsaved draft")
        vm.reloadRepromptDraft()
        XCTAssertEqual(vm.repromptGuidanceDraft, "External edit")
        vm.repromptGuidanceDraft = "Another draft"
        let workspaceID = UUID()
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: .init())
        vm.updateWorkspaceContext(workspaceID: workspaceID, workspaceName: "Different scope")
        XCTAssertTrue(vm.repromptDraftHasConflict)
        XCTAssertFalse(vm.saveRepromptDraft())
        XCTAssertEqual(store.globalAgentModelsProfile().agentRepromptGuidance, "External edit")
    }

    func testOversizedGuidanceRejectedWithoutTruncationAndBlankRestoresDefault() throws {
        let (store, api) = try fixture()
        let vm = AgentModelsSettingsViewModel(apiSettingsVM: api, settingsManager: store, settingsStore: store)
        vm.repromptGuidanceDraft = String(repeating: "x", count: 16 * 1024 + 1)
        XCTAssertFalse(vm.saveRepromptDraft())
        XCTAssertNil(store.globalAgentModelsProfile().agentRepromptGuidance)
        XCTAssertEqual(vm.repromptGuidanceDraft.utf8.count, 16 * 1024 + 1)
        vm.repromptGuidanceDraft = " \t\n"
        XCTAssertTrue(vm.saveRepromptDraft())
        XCTAssertEqual(vm.repromptGuidanceDraft, AgentRepromptGuidance.defaultText)
    }

    private func fixture(window: Int? = nil) throws -> (GlobalSettingsStore, APISettingsViewModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "AgentRepromptSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json")))
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        return (store, APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, recordAvailableModelsUpdate: WindowStateCompositionFactory.availableModelsRecorder(windowID: window ?? 0), loadStoredDataOnInit: false, antigravityRuntimeInstalledProvider: { false }, devinRuntimeInstalledProvider: { false }))
    }
}
