import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSessionLaneFirstSaveTests: XCTestCase {
    private struct Fixture {
        let window: WindowState
        let root: URL
        let workspaceID: UUID
        let selection: AgentSessionLanePolicy.RoleSelection
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-first-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let cleanup: @MainActor () async -> Void = {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            await window.workspaceManager.awaitInitialized()
            let workspace = window.workspaceManager.createWorkspace(
                name: "Lane first save \(UUID().uuidString.prefix(8))",
                repoPaths: [root.path], ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace, saveState: false, reason: "laneFirstSaveTest"
            )
            let selection = try AgentSessionLanePolicy.resolveRole(
                "pair", availability: .current, workspaceID: workspace.id
            )
            try await body(Fixture(
                window: window, root: root, workspaceID: workspace.id, selection: selection
            ))
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    func testDrivenFirstSaveWaitsForPreviouslyEnteredSaveAndPersistsProvenance() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let creatorID = UUID()
            let fileURL = fixture.root.appendingPathComponent("lane.json")
            let firstSaveEntered = expectation(description: "ordinary save entered")
            let completed = expectation(description: "driven lane save settled")
            var provisionRelease: CheckedContinuation<Void, Never>?
            var staleSaveRelease: CheckedContinuation<Void, Never>?
            var saveCount = 0
            viewModel.test_afterOversightLaneProvision = { tabID in
                Task { @MainActor in await viewModel.flushSave(for: tabID) }
                await withCheckedContinuation { provisionRelease = $0 }
            }
            viewModel.test_setAgentSessionSaver { session, _, _ in
                saveCount += 1
                if saveCount == 1 {
                    provisionRelease?.resume()
                    firstSaveEntered.fulfill()
                    await withCheckedContinuation { staleSaveRelease = $0 }
                }
                let data = try JSONEncoder().encode(session)
                try data.write(to: fileURL, options: .atomic)
                return fileURL
            }
            var outcome: AgentModeViewModel.MCPOversightLaneCreationOutcome?
            Task { @MainActor in
                outcome = try? await viewModel.mcpCreateOversightLane(
                    creatorSessionID: creatorID, sessionName: "Persisted lane",
                    selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
                )
                completed.fulfill()
            }
            await fulfillment(of: [firstSaveEntered], timeout: 3)
            XCTAssertEqual(saveCount, 1)
            staleSaveRelease?.resume()
            await fulfillment(of: [completed], timeout: 5)
            guard let outcome, case let .created(sessionID, tabID, bindingToken) = outcome else {
                let lane = viewModel.sessions.values.first(where: {
                    $0.createdByOverseerSessionID == creatorID
                })
                return XCTFail("lane did not establish a durable first-save proof: \(String(describing: outcome)); saves=\(saveCount), readiness=\(String(describing: lane?.restorationReadiness)), model=\(String(describing: lane?.selectedModelRaw)), expected=\(fixture.selection.modelRaw), dirty=\(String(describing: lane?.isDirty))")
            }
            let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
            XCTAssertEqual(saved.id, sessionID)
            XCTAssertEqual(saved.createdByOverseerSessionID, creatorID)
            XCTAssertEqual(
                CodexModelSpecifier(raw: saved.agentModel).baseModel,
                CodexModelSpecifier(raw: fixture.selection.modelRaw).baseModel
            )
            XCTAssertEqual(saved.agentReasoningEffort, fixture.selection.reasoningEffortRaw)
            XCTAssertGreaterThanOrEqual(saveCount, 2)
            let lane = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(lane.restorationReadiness,
                           .authoritative(bindingToken, .freshBindingDurablyCreated))
            XCTAssertFalse(lane.runState.isActive)
            XCTAssertFalse(lane.isMCPOriginated)
        }
    }

    func testFailedFirstSaveKeepsTheLaneForRecoveryWithoutLinkProof() async throws {
        enum SaveFailure: Error { case expected }
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let creatorID = UUID()
            viewModel.test_setAgentSessionSaver { _, _, _ in throw SaveFailure.expected }
            let outcome = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: creatorID, sessionName: "Recoverable lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .creationIncomplete(sessionID, tabID) = outcome else {
                return XCTFail("save failure unexpectedly proved a lane")
            }
            let lane = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(lane.activeAgentSessionID, sessionID)
            XCTAssertEqual(lane.createdByOverseerSessionID, creatorID)
            XCTAssertFalse(lane.restorationReadiness.isAuthoritative)
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == tabID && $0.activeAgentSessionID == sessionID
            } == true)
        }
    }

    func testRebindDuringHydrationDoesNotMarkReplacementAsCreatorOwned() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let originalTabs = Set(fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id) ?? [])
            let replacementID = UUID()
            let creatorID = UUID()
            var reboundTabID: UUID?
            viewModel.test_setAfterDurableChildTabCreation {
                guard let tabID = fixture.window.workspaceManager.activeWorkspace?.composeTabs.first(where: {
                    !originalTabs.contains($0.id)
                })?.id else { return XCTFail("fresh tab was not published") }
                reboundTabID = tabID
                do {
                    _ = try await viewModel.test_rebindPersistentSession(
                        replacementID, to: viewModel.session(for: tabID)
                    )
                } catch { XCTFail("test rebind failed: \(error)") }
            }
            defer { viewModel.test_setAfterDurableChildTabCreation(nil) }
            do {
                _ = try await viewModel.mcpCreateOversightLane(
                    creatorSessionID: creatorID, sessionName: "Rebound lane",
                    selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
                )
                XCTFail("rebound lane unexpectedly received a first-save proof")
            } catch {}
            let tabID = try XCTUnwrap(reboundTabID)
            let replacement = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(replacement.activeAgentSessionID, replacementID)
            XCTAssertNil(replacement.createdByOverseerSessionID)
        }
    }

    func testConfigurationFailureAlsoRetainsTheCreatedLane() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let creatorID = UUID()
            let invalidSelection = AgentSessionLanePolicy.RoleSelection(
                role: .pair, agentRaw: "unavailable-provider", modelRaw: "unavailable-model",
                reasoningEffortRaw: nil, modelParameterSelections: []
            )
            let outcome = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: creatorID, sessionName: "Recoverable configuration",
                selection: invalidSelection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .creationIncomplete(sessionID, tabID) = outcome else {
                return XCTFail("invalid configuration unexpectedly proved a lane")
            }
            let lane = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(lane.activeAgentSessionID, sessionID)
            XCTAssertEqual(lane.createdByOverseerSessionID, creatorID)
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == tabID && $0.activeAgentSessionID == sessionID
            } == true)
        }
    }

    func testBindingCountIncludesInactiveWorkspaceWithoutHydration() async throws {
        try await withFixture { fixture in
            let sessionID = UUID()
            let activeIndex = try XCTUnwrap(fixture.window.workspaceManager.workspaces.firstIndex {
                $0.id == fixture.workspaceID
            })
            fixture.window.workspaceManager.workspaces[activeIndex].composeTabs.append(
                ComposeTabState(id: UUID(), name: "Active", activeAgentSessionID: sessionID)
            )
            let inactive = fixture.window.workspaceManager.createWorkspace(
                name: "Inactive duplicate", repoPaths: [fixture.root.path], ephemeral: true
            )
            let inactiveIndex = try XCTUnwrap(fixture.window.workspaceManager.workspaces.firstIndex {
                $0.id == inactive.id
            })
            let hiddenTabID = UUID()
            fixture.window.workspaceManager.workspaces[inactiveIndex].composeTabs.append(
                ComposeTabState(id: hiddenTabID, name: "Hidden", activeAgentSessionID: sessionID)
            )
            XCTAssertEqual(fixture.window.workspaceManager.activeWorkspaceID, fixture.workspaceID)
            XCTAssertNil(fixture.window.agentModeViewModel.sessions[hiddenTabID])
            XCTAssertEqual(WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: sessionID), 2)
        }
    }

    func testPersistedChildAbsentFromLiveSessionsAndSidebarIndexStillBlocksRetirement() async throws {
        try await withFixture { fixture in
            let dataService = AgentSessionDataService.shared
            await dataService.test_setWorkspaceRootOverride(fixture.root)
            do {
                let parentID = UUID()
                var child = AgentSession(id: UUID(), name: "Unindexed child", savedAt: Date())
                child.parentSessionID = parentID
                let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
                _ = try await dataService.saveAgentSession(child, for: workspace)
                XCTAssertFalse(fixture.window.agentModeViewModel.sessions.values.contains {
                    $0.parentSessionID == parentID
                })
                XCTAssertFalse(fixture.window.agentModeViewModel.test_ownerValidatedSessionIndex.values.contains {
                    $0.parentSessionID == parentID
                })
                let hasPersistedChild = await WindowStatesManager.shared.agentSessionLinkHasPersistedChildSessions(
                    parentSessionID: parentID
                )
                XCTAssertTrue(hasPersistedChild)
            } catch {
                await dataService.test_setWorkspaceRootOverride(nil)
                throw error
            }
            await dataService.test_setWorkspaceRootOverride(nil)
        }
    }
}
