import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeNativeEffortResolutionTests: XCTestCase {
    private actor FixedModelResolver: ClaudeCodeLaunchEnvironmentResolving {
        func resolve(
            variant _: ClaudeCodeRuntimeVariant,
            requestedModel _: String?
        ) async throws -> ClaudeCodeLaunchEnvironment {
            ClaudeCodeLaunchEnvironment(
                effectiveModel: "claude-opus-5-5",
                environmentOverrides: [:],
                backend: .defaultClaude
            )
        }
    }

    func testTurnScopedEffortOverridesEncodedModelEffortInFlagSettings() async throws {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: FixedModelResolver()
        )

        let overridden = try await controller.test_resolveApplyFlagSettingsRequest(
            model: "claude-opus-5-5:high",
            effortLevel: .low
        )
        XCTAssertEqual((overridden?["settings"] as? [String: Any])?["effortLevel"] as? String, "low")

        let baseline = try await controller.test_resolveApplyFlagSettingsRequest(
            model: "claude-opus-5-5:high",
            effortLevel: nil
        )
        XCTAssertEqual((baseline?["settings"] as? [String: Any])?["effortLevel"] as? String, "high")
    }

    @MainActor
    func testMCPExplicitClaudeEffortPinWinsOverStoredPreference() {
        let extracted = AgentExternalMCPRunStarter.extractReasoningEffort(from: "claude-opus-5-5:low")
        XCTAssertEqual(extracted.model, "claude-opus-5-5:low")
        XCTAssertEqual(extracted.effort, "low")
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: extracted.effort,
            isMCPOriginated: true,
            stored: .high
        ), .low)
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: extracted.effort,
            isMCPOriginated: false,
            stored: .high
        ), .low)
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5",
            agentKind: .claudeCode,
            pinnedEffortRaw: nil,
            isMCPOriginated: true,
            stored: .high
        ), .high)
        XCTAssertEqual(ClaudeAgentModeCoordinator.validatedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: "low",
            isMCPOriginated: true
        ), .low)
        XCTAssertNil(ClaudeAgentModeCoordinator.validatedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5",
            agentKind: .claudeCode,
            pinnedEffortRaw: "low",
            isMCPOriginated: false
        ))
    }

    @MainActor
    func testEncodedManualEffortIsBaselineButValidMCPPinStillWins() {
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: "high",
            isMCPOriginated: false,
            stored: .high
        ), .low)
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: "high",
            isMCPOriginated: true,
            stored: .medium
        ), .high)
    }

    @MainActor
    func testMCPConfigurationPreservesClaudePinAndClearsItForUnpinnedModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-claude-effort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        defer {
            WindowStatesManager.shared.unregisterWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        }
        let workspace = window.workspaceManager.createWorkspace(
            name: "Claude MCP effort pin",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "claudeEffortPinTests")
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        let tabID = try XCTUnwrap(activeWorkspace.activeComposeTabID)
        let viewModel = window.agentModeViewModel
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.isMCPOriginated = true

        try await viewModel.mcpConfigureSession(
            tabID: tabID,
            agentRaw: AgentProviderKind.claudeCode.rawValue,
            modelRaw: "claude-opus-5-5:low",
            reasoningEffortRaw: "low"
        )
        XCTAssertEqual(session.selectedReasoningEffortRaw, "low")
        XCTAssertEqual(viewModel.claudeCoordinator.currentClaudeEffortLevel(for: session), .low)

        try await viewModel.mcpConfigureSession(
            tabID: tabID,
            agentRaw: AgentProviderKind.claudeCode.rawValue,
            modelRaw: "claude-opus-5-5",
            reasoningEffortRaw: nil
        )
        XCTAssertNil(session.selectedReasoningEffortRaw)
    }
}

final class ClaudeNativeAutoFallbackTests: XCTestCase {
    private actor ApplicationGate {
        private let fence = TestReleaseFence(name: "native Auto application error")
        func waitUntilEntered() async throws {
            guard await fence.waitUntilEntered(timeout: 3) else { fence.release()
                throw CancellationError()
            }
        }

        func pause() async {
            await fence.enterAndWait()
        }

        nonisolated func resume() {
            fence.release()
        }
    }

    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        func append(_ line: Data) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        func line(at index: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return lines.indices.contains(index) ? lines[index] : nil
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return lines.count
        }
    }

    private actor PassthroughResolver: ClaudeCodeLaunchEnvironmentResolving {
        func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCodeLaunchEnvironment {
            .init(effectiveModel: requestedModel, environmentOverrides: [:], backend: .defaultClaude)
        }
    }

    private func controller() -> ClaudeNativeProcessSessionController {
        .init(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: PassthroughResolver()
        )
    }

    @MainActor
    private func fixture(_ controller: ClaudeNativeProcessSessionController) -> (ClaudeAgentModeCoordinator, AgentTabSession, ClaudeAgentModeCoordinator.NativeSessionIntent) {
        let coordinator = ClaudeAgentModeCoordinator(
            windowID: 1, workspacePathProvider: { _ in nil },
            claudeControllerFactory: { _, _, _, _ in controller }, autoEffortEnabledProvider: { true }
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-opus-5-5:high"
        session.hasLoadedPersistedState = true
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.native-auto-fallback")
        return (coordinator, session, .runAttempt(ownership: ownership, runID: runID))
    }

    @MainActor
    func testStaleAutoErrorCannotOverwriteNewerIdenticalOrABASelection() async throws {
        for afterClassification in [false, true] {
            for newerModels in [["claude-opus-5-5:high"], ["claude-sonnet-4-6:high", "claude-opus-5-5:high"]] {
                let controller = controller()
                let gate = ApplicationGate()
                let controls = Writes()
                let writes = Writes()
                await controller.test_installConfigurationTransport(controlRequest: { request in
                    controls.append(Data())
                    if (request["settings"] as? [String: Any])?["effortLevel"] as? String == "low" {
                        if !afterClassification { await gate.pause() }
                        throw NativeAgentRuntimeControllerError.invalidControlResponse("Auto rejected")
                    }
                    return [:]
                }, write: { writes.append($0) })
                if afterClassification { await controller.test_setBeforeApplicationErrorReturn { await gate.pause() } }
                let (coordinator, session, intent) = fixture(controller)
                let send = Task {
                    await coordinator.sendClaudeNativeMessage(
                        session: session, text: "older ordinary turn", attachments: [], intent: intent,
                        allowsCatalogRouteControllerRecovery: false,
                        autoEffortSelection: .init(
                            provider: .claudeCode,
                            selectedModelRaw: session.selectedModelRaw,
                            manualEffortRaw: "high",
                            effortRaw: "low"
                        )
                    )
                }
                defer { send.cancel()
                    gate.resume()
                }
                try await gate.waitUntilEntered()
                for model in newerModels {
                    try await controller.applyModelAndEffort(model: model, effortLevel: .high)
                }
                gate.resume()
                let outcome = await send.value
                guard case .failed = outcome else { XCTFail("Stale Auto failure must refuse the older prompt: \(outcome)")
                    continue
                }
                XCTAssertEqual(controls.count, 1 + newerModels.count, "A stale failure cannot issue manual fallback settings")
                XCTAssertEqual(writes.count, 0, "The older prompt must not dispatch")
                XCTAssertEqual(session.providerSessionID, "application-proof-session")
                XCTAssertTrue(session.claudeController === controller)
            }
        }
    }

    @MainActor
    func testCurrentAutoFailureRestoresManualEffortAndDelivers() async throws {
        let controller = controller()
        let controls = Writes()
        let writes = Writes()
        await controller.test_installConfigurationTransport(controlRequest: { request in
            try controls.append(JSONSerialization.data(withJSONObject: request))
            if (request["settings"] as? [String: Any])?["effortLevel"] as? String == "low" {
                throw NativeAgentRuntimeControllerError.invalidControlResponse("Auto rejected")
            }
            return [:]
        }, write: { writes.append($0) })
        let (coordinator, session, intent) = fixture(controller)
        let outcome = await coordinator.sendClaudeNativeMessage(
            session: session, text: "current ordinary turn", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false,
            autoEffortSelection: .init(
                provider: .claudeCode,
                selectedModelRaw: session.selectedModelRaw,
                manualEffortRaw: "high",
                effortRaw: "low"
            )
        )
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(controls.count, 2)
        XCTAssertEqual(writes.count, 1)
        let restoredRequest = try XCTUnwrap(controls.line(at: 1))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: restoredRequest) as? [String: Any])
        let settings = try XCTUnwrap(request["settings"] as? [String: Any])
        XCTAssertEqual(settings["model"] as? String, session.selectedModelRaw)
        XCTAssertEqual(settings["effortLevel"] as? String, "high")
    }

    func testFailureTokenCannotBeReusedAfterFallbackOrTransportReplacement() async throws {
        for replaceTransport in [false, true] {
            let controller = controller()
            let controls = Writes()
            let accept: @Sendable ([String: Any]) async throws -> [String: Any] = { request in
                controls.append(Data())
                if (request["settings"] as? [String: Any])?["effortLevel"] as? String == "low" {
                    throw NativeAgentRuntimeControllerError.invalidControlResponse("Auto rejected")
                }
                return [:]
            }
            await controller.test_installConfigurationTransport(controlRequest: accept, write: { _ in })
            var captured: NativeAgentRuntimeConfigurationFailure?
            do {
                _ = try await controller.applyModelAndEffortForTurn(model: "A", effortLevel: .low, replacingFailure: nil)
                XCTFail("Expected failed Auto application")
            } catch let failure as NativeAgentRuntimeConfigurationFailure { captured = failure }
            let failure = try XCTUnwrap(captured)
            if replaceTransport {
                await controller.test_installConfigurationTransport(controlRequest: accept, write: { _ in })
                try await controller.applyModelAndEffort(model: "A", effortLevel: .high)
            } else {
                let restored = try await controller.applyModelAndEffortForTurn(model: "A", effortLevel: .high, replacingFailure: failure)
                XCTAssertTrue(restored)
            }
            let stale = try await controller.applyModelAndEffortForTurn(model: "A", effortLevel: .high, replacingFailure: failure)
            XCTAssertFalse(stale)
            XCTAssertEqual(controls.count, 2, "Consumed or foreign-lifetime failures authorize no provider IO")
        }
    }
}
