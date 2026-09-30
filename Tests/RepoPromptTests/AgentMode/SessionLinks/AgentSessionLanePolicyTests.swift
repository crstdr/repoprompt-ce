import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentSessionLanePolicyTests: XCTestCase {
    func testExplicitModelUsesAdvertisedFullIDWithoutRoleSubstitution() throws {
        let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true, grokBuildAvailable: true)
        // Use the production producer, not another list of accepted models.
        for entry in AgentModelCatalog.discoveryAgents(availability: availability) where entry.available {
            guard AgentModelCatalog.AgentSelectionSurface.headless.allows(entry.agent) else { continue }
            for model in entry.models {
                for target in model.startTargets {
                    let selected = try AgentSessionLanePolicy.resolveModel(target.selectionID.rawValue, availability: availability)
                    XCTAssertEqual(selected.agentRaw, entry.agent.rawValue)
                    XCTAssertEqual(selected.modelRaw, target.modelRaw)
                    XCTAssertTrue(selected.modelParameterSelections.isEmpty)
                }
            }
        }
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveModel("pair", availability: availability))
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveModel("codexExec:unadvertised-future-model-high", availability: availability))
        XCTAssertNotNil(
            AgentModelCatalog.resolveSelectionID("codexExec:unadvertised-future-model-high", availability: availability),
            "Legacy launch resolver remains permissive"
        )
    }

    func testMemoryOnlyAdmissionDoesNotDiscoverOrSubstituteMissingCatalogue() throws {
        let catalogue = AgentAdvertisedModelCatalog()
        let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true)
        XCTAssertThrowsError(try catalogue.selection("cursor:auto", availability: availability)) { error in
            XCTAssertEqual(error as? AgentAdvertisedModelCatalog.AdmissionError, .catalogueUnavailable)
        }
        let dynamic = AgentModelOption(
            rawValue: "future-model-high",
            displayName: "Future",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false
        )
        catalogue.record([dynamic], for: .codexExec)
        let selected = try catalogue.selection("codexExec:future-model-high", availability: availability)
        XCTAssertEqual(selected.storedModelRaw, "future-model-high")
        XCTAssertEqual(selected.reasoningEffortRaw, "high")
        XCTAssertThrowsError(try catalogue.selection("codexExec:future-model-low", availability: availability))
        XCTAssertThrowsError(try catalogue.selection("codexExec:future-model-high", availability: .none))
        catalogue.invalidate(.codexExec)
        XCTAssertThrowsError(try catalogue.selection("codexExec:future-model-high", availability: availability)) { error in
            XCTAssertEqual(error as? AgentAdvertisedModelCatalog.AdmissionError, .catalogueUnavailable)
        }
        let colon = AgentModelOption(
            rawValue: "vendor:model:variant",
            displayName: "Colon",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false
        )
        catalogue.record([colon], for: .openCode)
        XCTAssertEqual(
            try catalogue.selection("openCode:vendor:model:variant", availability: availability).storedModelRaw,
            "vendor:model:variant"
        )
    }

    func testCreateLaneDigestDistinguishesExplicitModelFromRoleAndDefault() {
        let original = AgentSessionLaneCreateRequest(
            idempotencyKey: "key",
            role: nil,
            sessionName: nil,
            message: nil,
            workflowReference: nil
        )
        let role = AgentSessionLaneCreateRequest(
            idempotencyKey: "key",
            role: "pair",
            sessionName: nil,
            message: nil,
            workflowReference: nil
        )
        var explicit = original
        explicit.modelID = "codexExec:gpt-5.4-high"
        XCTAssertEqual(original.digest, role.digest, "Preserve default role retry identity")
        XCTAssertNotEqual(original.digest, explicit.digest)
        var changed = explicit
        changed.modelID = "codexExec:gpt-5.4-low"
        XCTAssertNotEqual(explicit.digest, changed.digest)
    }

    @MainActor
    func testEveryRoleUsesItsEffectiveRoleDefaultAndMappedEffort() throws {
        let workspaceID = UUID()
        let overrides = Dictionary(
            uniqueKeysWithValues: AgentModelCatalog.TaskLabelKind.allCases.map {
                ($0.rawValue, "codexExec:gpt-5.4-high")
            }
        )
        let settings = AgentModelsProfileRoleDefaultsStore(overrides: overrides)
        let availability = AgentModelCatalog.AvailabilityContext()
        for role in AgentModelCatalog.TaskLabelKind.allCases {
            let selected = try AgentSessionLanePolicy.resolveRole(
                role.rawValue,
                availability: availability,
                workspaceID: workspaceID,
                settingsStore: settings
            )
            XCTAssertEqual(selected.role, role)
            XCTAssertEqual(selected.agentRaw, AgentProviderKind.codexExec.rawValue)
            XCTAssertEqual(selected.modelRaw, "gpt-5.4-high")
            XCTAssertEqual(selected.reasoningEffortRaw, "high")
        }
    }

    @MainActor
    func testFreshHandoffDestinationDoesNotInheritCreatorProvenance() {
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let destination = viewModel.session(for: UUID())
        destination.createdByOverseerSessionID = UUID()
        viewModel.markSessionAsFreshlyCreated(destination)
        XCTAssertNil(destination.createdByOverseerSessionID)
        XCTAssertNil(AgentSession(id: UUID()).createdByOverseerSessionID)
    }

    @MainActor
    func testHandoffBuiltAgentSessionDoesNotCopySourceCreatorProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let cleanup: @MainActor () async -> Void = {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        do {
            await window.workspaceManager.awaitInitialized()
            let workspace = window.workspaceManager.createWorkspace(
                name: "Lane handoff provenance", repoPaths: [root.path], ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace, saveState: false, reason: "laneHandoffProvenanceTest"
            )
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let sourceTab = ComposeTabState(id: sourceTabID, name: "Source", activeAgentSessionID: sourceSessionID)
            let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex {
                $0.id == workspace.id
            })
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [sourceTab]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = sourceTabID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex], syncPromptText: true
            )
            let viewModel = window.agentModeViewModel
            let source = viewModel.session(for: sourceTabID)
            source.hasLoadedPersistedState = true
            source.createdByOverseerSessionID = UUID()
            source.setItemsSilently([
                .user("Source user", sequenceIndex: 0),
                .assistant("Source assistant", sequenceIndex: 1)
            ], reason: .testOverride)
            viewModel.refreshDerivedTranscriptState(for: source)
            viewModel.setAgentModeActive(true)
            var savedCreator: UUID?
            var saveWasCalled = false
            viewModel.test_setAgentSessionSaver { session, _, _ in
                savedCreator = session.createdByOverseerSessionID
                saveWasCalled = true
                return root.appendingPathComponent("handoff-session.json")
            }
            let cutoff = try XCTUnwrap(source.items.last?.id)
            let destinationTabID = try await viewModel.prepareHandoffToNewTab(
                upToItemID: cutoff,
                destinationAgent: source.selectedAgent,
                destinationModelRaw: source.selectedModelRaw,
                destinationReasoningEffortRaw: source.selectedReasoningEffortRaw
            )
            XCTAssertTrue(saveWasCalled)
            XCTAssertNil(savedCreator)
            XCTAssertNil(viewModel.sessions[destinationTabID]?.createdByOverseerSessionID)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @MainActor
    func testUnmappedOrUnusableRolesFailClosedWithoutSubstitution() {
        let availability = AgentModelCatalog.AvailabilityContext()
        let workspaceID = UUID()
        let badOverride = AgentModelsProfileRoleDefaultsStore(overrides: ["pair": "no-such-provider:model"])
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveRole(
            "pair",
            availability: availability,
            workspaceID: workspaceID,
            settingsStore: badOverride
        )) { error in
            XCTAssertEqual(error as? AgentSessionLanePolicy.RoleResolutionError, .roleUnavailable)
        }
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveRole(
            "unrecognized",
            availability: availability,
            workspaceID: workspaceID
        )) { error in
            XCTAssertEqual(error as? AgentSessionLanePolicy.RoleResolutionError, .roleUnavailable)
        }
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveRole(
            "pair",
            availability: AgentModelCatalog.AvailabilityContext(
                claudeCodeAvailable: false,
                codexAvailable: false,
                openCodeAvailable: false
            ),
            workspaceID: workspaceID
        )) { error in
            XCTAssertEqual(error as? AgentSessionLanePolicy.RoleResolutionError, .roleUnavailable)
        }
    }
}
