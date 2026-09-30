import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeNativeApprovalAndResumeTests: XCTestCase {
    enum ResolverError: Error {
        case unsupportedModel
    }

    actor RecordingLaunchEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
        private(set) var requestedModels: [String?] = []

        func resolve(
            variant _: ClaudeCodeRuntimeVariant,
            requestedModel: String?
        ) async throws -> ClaudeCodeLaunchEnvironment {
            requestedModels.append(requestedModel)
            guard requestedModel != "glm-5-turbo:xhigh" else {
                throw ResolverError.unsupportedModel
            }
            return ClaudeCodeLaunchEnvironment(
                effectiveModel: "sonnet",
                environmentOverrides: [:],
                backend: .compatible(.glmZAI)
            )
        }
    }

    func testNativeFlagResolutionPassesEncodedGLMModelToResolver() async throws {
        let resolver = RecordingLaunchEnvironmentResolver()
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            ),
            environmentResolver: resolver
        )

        do {
            _ = try await controller.test_resolveApplyFlagSettingsRequest(model: "glm-5-turbo:xhigh")
            XCTFail("Expected encoded unsupported GLM XHigh model to be rejected by the resolver")
        } catch ResolverError.unsupportedModel {
            // Expected.
        }

        let requestedModels = await resolver.requestedModels
        XCTAssertEqual(requestedModels, ["glm-5-turbo:xhigh"])
    }

    func testNativeLiveModelSwitchRequiresRestartWhenLaunchEnvironmentChanges() async {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            )
        )
        let directGLM = ClaudeCodeLaunchEnvironment(
            effectiveModel: "sonnet",
            environmentOverrides: [
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5-turbo",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5-turbo"
            ],
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )
        let slotGLM = ClaudeCodeLaunchEnvironment(
            effectiveModel: "sonnet",
            environmentOverrides: [
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-4.7",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-4.7"
            ],
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )
        let sameEnvironmentDifferentFlagModel = ClaudeCodeLaunchEnvironment(
            effectiveModel: "opus",
            environmentOverrides: directGLM.environmentOverrides,
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )

        let directToSlotRequiresRestart = await controller.test_liveFlagSettingsRequiresProcessRestart(
            activeLaunchEnvironment: directGLM,
            nextLaunchEnvironment: slotGLM
        )
        let sameEnvironmentRequiresRestart = await controller.test_liveFlagSettingsRequiresProcessRestart(
            activeLaunchEnvironment: directGLM,
            nextLaunchEnvironment: sameEnvironmentDifferentFlagModel
        )

        XCTAssertTrue(directToSlotRequiresRestart)
        XCTAssertFalse(sameEnvironmentRequiresRestart)
    }

    private actor ApplicationGate {
        private var entry: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        private var entered = false
        private var hold = true

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entry = $0 }
        }

        func respond() async -> [String: Any] {
            if hold {
                hold = false
                entered = true
                entry?.resume()
                entry = nil
                await withCheckedContinuation { release = $0 }
            }
            return [:]
        }

        func resume() {
            release?.resume()
            release = nil
        }
    }

    private final class WrittenLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        func append(_ line: Data) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return lines.count
        }
    }

    private actor PassthroughResolver: ClaudeCodeLaunchEnvironmentResolving {
        func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCodeLaunchEnvironment {
            ClaudeCodeLaunchEnvironment(effectiveModel: requestedModel, environmentOverrides: [:], backend: .defaultClaude)
        }
    }

    private func applicationController() -> ClaudeNativeProcessSessionController {
        ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: PassthroughResolver()
        )
    }

    func testApplicationProofRequiresReadyTransportIncludingNilSettings() async throws {
        let controller = applicationController()
        let absent = try await controller.applyModelAndEffortWithProof(model: nil, effortLevel: nil)
        XCTAssertEqual(absent, .notReady)
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: false, write: { writes.append($0) })
        let pending = try await controller.applyModelAndEffortWithProof(model: nil, effortLevel: nil)
        XCTAssertEqual(pending, .notReady)
        XCTAssertEqual(writes.count, 0)
        await controller.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        let ready = try await controller.applyModelAndEffortWithProof(model: nil, effortLevel: nil)
        guard case let .applied(proof) = ready else { return XCTFail("Ready no-override policy must be proven") }
        _ = try await controller.sendUserMessage("ordinary", configuration: proof)
        XCTAssertEqual(writes.count, 1)
    }

    func testApplicationACKSupersessionCannotReleasePromptEvenForSameValueOrABA() async throws {
        for interveningModels in [["A"], ["B", "A"]] {
            let controller = applicationController()
            let gate = ApplicationGate()
            let writes = WrittenLines()
            await controller.test_installConfigurationTransport(
                initialized: true, controlRequest: { _ in await gate.respond() }, write: { writes.append($0) }
            )
            let first = Task { try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high) }
            await gate.waitUntilEntered()
            var latest: NativeAgentRuntimeConfigurationApplication = .notReady
            for model in interveningModels {
                latest = try await controller.applyModelAndEffortWithProof(model: model, effortLevel: .high)
            }
            await gate.resume()
            let superseded = try await first.value
            XCTAssertEqual(superseded, .superseded)
            XCTAssertEqual(writes.count, 0)
            guard case let .applied(proof) = latest else { return XCTFail("Latest application must be current") }
            _ = try await controller.sendUserMessage("current", configuration: proof)
            XCTAssertEqual(writes.count, 1)
        }
    }

    func testPhysicalWriteRejectsProofAfterSameValueIntentAndProcessReplacement() async throws {
        let controller = applicationController()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        guard case let .applied(first) = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        else { return XCTFail("Missing initial proof") }
        guard case let .applied(second) = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        else { return XCTFail("Missing replacement proof") }
        do {
            _ = try await controller.sendUserMessage("stale", configuration: first)
            XCTFail("Same values do not make an older proof current")
        } catch NativeAgentRuntimeControllerError.configurationNotCurrent {}
        await controller.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        _ = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        _ = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        do {
            _ = try await controller.sendUserMessage("old process", configuration: second)
            XCTFail("A prior transport proof must not survive generation reset")
        } catch NativeAgentRuntimeControllerError.configurationNotCurrent {}
        XCTAssertEqual(writes.count, 0)
    }

    private actor GatedResolver: ClaudeCodeLaunchEnvironmentResolving {
        let gate: ApplicationGate
        init(gate: ApplicationGate) {
            self.gate = gate
        }

        func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCodeLaunchEnvironment {
            _ = await gate.respond()
            return ClaudeCodeLaunchEnvironment(effectiveModel: requestedModel, environmentOverrides: [:], backend: .defaultClaude)
        }
    }

    func testSupersessionDuringResolutionNeverWritesStaleSettings() async throws {
        let gate = ApplicationGate()
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: GatedResolver(gate: gate)
        )
        let writes = WrittenLines()
        let controls = WrittenLines()
        await controller.test_installConfigurationTransport(
            initialized: true,
            controlRequest: { _ in controls.append(Data())
                return [:]
            },
            write: { writes.append($0) }
        )
        let first = Task { try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high) }
        await gate.waitUntilEntered()
        _ = try await controller.applyModelAndEffortWithProof(model: "B", effortLevel: .high)
        let latest = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        await gate.resume()
        let stale = try await first.value
        XCTAssertEqual(stale, .superseded)
        XCTAssertEqual(controls.count, 2, "The delayed A intent must not write settings after B→A")
        XCTAssertEqual(writes.count, 0)
        guard case let .applied(proof) = latest else { return XCTFail("Missing latest proof") }
        _ = try await controller.sendUserMessage("current", configuration: proof)
        XCTAssertEqual(writes.count, 1)
    }

    func testRejectedApplicationInvalidatesEarlierProofWithoutChangingSessionIdentity() async throws {
        let controller = applicationController()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        guard case let .applied(proof) = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        else { return XCTFail("Missing proof") }
        await controller.test_setConfigurationControlRequest { _ in throw ResolverError.unsupportedModel }
        do {
            _ = try await controller.applyModelAndEffortWithProof(model: "B", effortLevel: .high)
            XCTFail("Expected rejection")
        } catch ResolverError.unsupportedModel {}
        do {
            _ = try await controller.sendUserMessage("stale after rejection", configuration: proof)
            XCTFail("Rejected intent still invalidates prior application")
        } catch NativeAgentRuntimeControllerError.configurationNotCurrent {}
        let identity = await controller.currentSessionRef()
        XCTAssertEqual(identity.sessionID, "application-proof-session")
        XCTAssertEqual(writes.count, 0)
    }

    @MainActor
    private func ordinaryTurnFixture(
        controller: ClaudeNativeProcessSessionController
    ) -> (ClaudeAgentModeCoordinator, AgentTabSession, ClaudeAgentModeCoordinator.NativeSessionIntent) {
        let coordinator = ClaudeAgentModeCoordinator(
            windowID: 1,
            workspacePathProvider: { _ in nil },
            claudeControllerFactory: { _, _, _, _ in controller },
            autoEffortEnabledProvider: { true }
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-opus-5-5:high"
        session.hasLoadedPersistedState = true
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.native-application-proof")
        return (coordinator, session, .runAttempt(ownership: ownership, runID: runID))
    }

    @MainActor
    func testOrdinarySendWaitsForModelAndEffortACKAndRejectsChangedModelWithSameEffort() async {
        for changeModel in [false, true] {
            let controller = applicationController()
            let gate = ApplicationGate()
            let writes = WrittenLines()
            await controller.test_installConfigurationTransport(
                initialized: true, controlRequest: { _ in await gate.respond() }, write: { writes.append($0) }
            )
            let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
            let send = Task {
                await coordinator.sendClaudeNativeMessage(
                    session: session, text: "ordinary", attachments: [], intent: intent,
                    allowsCatalogRouteControllerRecovery: false
                )
            }
            await gate.waitUntilEntered()
            XCTAssertEqual(writes.count, 0, "An ordinary turn must await application even without Auto")
            if changeModel { session.selectedModelRaw = "claude-sonnet-4-6:high" }
            await gate.resume()
            let outcome = await send.value
            XCTAssertEqual(outcome, changeModel ? .superseded : .sent)
            XCTAssertEqual(writes.count, changeModel ? 0 : 1)
            XCTAssertEqual(session.providerSessionID, "application-proof-session")
            XCTAssertTrue(session.claudeController === controller)
        }
    }

    @MainActor
    func testOrdinarySendRejectsSameValueSupersessionDuringACK() async throws {
        let controller = applicationController()
        let gate = ApplicationGate()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(
            initialized: true, controlRequest: { _ in await gate.respond() }, write: { writes.append($0) }
        )
        let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
        let send = Task {
            await coordinator.sendClaudeNativeMessage(
                session: session, text: "ordinary", attachments: [], intent: intent,
                allowsCatalogRouteControllerRecovery: false
            )
        }
        await gate.waitUntilEntered()
        _ = try await controller.applyModelAndEffortWithProof(model: session.selectedModelRaw, effortLevel: .high)
        await gate.resume()
        let outcome = await send.value
        guard case .failed = outcome else { return XCTFail("Superseded application cannot release the prompt") }
        XCTAssertEqual(writes.count, 0)
        XCTAssertEqual(session.providerSessionID, "application-proof-session")
    }

    @MainActor
    func testOrdinaryApplicationFailurePreservesIdentityAndDoesNotPrompt() async {
        for failure in [NativeAgentRuntimeControllerError.invalidControlResponse("rejected"), .liveModelSwitchRequiresRestart] {
            let controller = applicationController()
            let writes = WrittenLines()
            await controller.test_installConfigurationTransport(
                initialized: true, controlRequest: { _ in throw failure }, write: { writes.append($0) }
            )
            let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
            let outcome = await coordinator.sendClaudeNativeMessage(
                session: session, text: "ordinary", attachments: [], intent: intent,
                allowsCatalogRouteControllerRecovery: false
            )
            guard case .failed = outcome else { return XCTFail("Expected pre-prompt failure, got \(outcome)") }
            XCTAssertEqual(writes.count, 0)
            XCTAssertEqual(session.providerSessionID, "application-proof-session")
            XCTAssertTrue(session.claudeController === controller)
        }
    }

    private actor EffortRequests {
        private(set) var models: [String?] = []
        private(set) var efforts: [String?] = []
        func respond(_ request: [String: Any]) throws -> [String: Any] {
            let settings = request["settings"] as? [String: Any]
            models.append(settings?["model"] as? String)
            efforts.append(settings?["effortLevel"] as? String)
            if efforts.count == 1 { throw ResolverError.unsupportedModel }
            return [:]
        }
    }

    @MainActor
    func testOptionalAutoFailureReestablishesSameModelManualProofBeforePrompt() async {
        let controller = applicationController()
        let requests = EffortRequests()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(
            initialized: true, controlRequest: { try await requests.respond($0) }, write: { writes.append($0) }
        )
        let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
        let outcome = await coordinator.sendClaudeNativeMessage(
            session: session, text: "ordinary", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false,
            autoEffortSelection: .init(
                provider: .claudeCode, selectedModelRaw: session.selectedModelRaw,
                manualEffortRaw: "high", effortRaw: "low"
            )
        )
        XCTAssertEqual(outcome, .sent)
        let models = await requests.models
        let efforts = await requests.efforts
        XCTAssertEqual(models, ["claude-opus-5-5:high", "claude-opus-5-5:high"])
        XCTAssertEqual(efforts, ["low", "high"])
        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(session.isMCPOriginated)
        XCTAssertEqual(session.providerSessionID, "application-proof-session")
    }

    func testRepoPromptPermissionAutoApprovalAndAllowPayloadPreserveToolUseID() throws {
        let repoPromptPayload: [String: Any] = [
            "tool_name": "mcp__RepoPromptCE__read_file",
            "tool_use_id": "toolu_read_1",
            "input": ["path": "Sources/App.swift"],
            "permission_suggestions": [["type": "tool", "name": "mcp__RepoPromptCE__read_file"]]
        ]

        let match = try XCTUnwrap(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "mcp__RepoPromptCE__read_file",
            requestPayload: repoPromptPayload
        ))
        XCTAssertEqual(match.source, .topLevelToolName)
        XCTAssertEqual(match.normalizedToolName, "read_file")

        let allowOnce = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
            pendingRequest: repoPromptPayload,
            includeUpdatedPermissions: false
        )
        XCTAssertEqual(allowOnce["behavior"] as? String, "allow")
        XCTAssertEqual(allowOnce["toolUseID"] as? String, "toolu_read_1")
        XCTAssertNil(allowOnce["updatedPermissions"])
        XCTAssertEqual((allowOnce["updatedInput"] as? [String: Any])?["path"] as? String, "Sources/App.swift")

        let allowForSession = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
            pendingRequest: repoPromptPayload,
            includeUpdatedPermissions: true
        )
        XCTAssertEqual((allowForSession["updatedPermissions"] as? [[String: Any]])?.first?["name"] as? String, "mcp__RepoPromptCE__read_file")

        let nestedMatch = try XCTUnwrap(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "Bash",
            requestPayload: [
                "permission_suggestions": [["rules": [["toolName": "mcp__RepoPromptCE__read_file"]]]]
            ]
        ))
        XCTAssertEqual(nestedMatch.source, .nestedToolName)
        XCTAssertEqual(nestedMatch.normalizedToolName, "read_file")

        XCTAssertNil(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "Bash",
            requestPayload: ["input": ["command": "rm -rf /tmp/example"]]
        ))
    }
}
