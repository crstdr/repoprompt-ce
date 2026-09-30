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
        let rejectFirst: Bool
        private var calls = 0
        init(gate: ApplicationGate, rejectFirst: Bool = false) {
            self.gate = gate
            self.rejectFirst = rejectFirst
        }

        func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCodeLaunchEnvironment {
            calls += 1
            let reject = rejectFirst && calls == 1
            _ = await gate.respond()
            if reject { throw ResolverError.unsupportedModel }
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

    func testSupersededResolutionErrorReturnsSuperseded() async throws {
        let gate = ApplicationGate()
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: GatedResolver(gate: gate, rejectFirst: true)
        )
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        let first = Task { try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .low) }
        await gate.waitUntilEntered()
        _ = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .low)
        await gate.resume()
        let result = try await first.value
        XCTAssertEqual(result, .superseded, "Resolution failures must be generation-fenced too")
        XCTAssertEqual(writes.count, 0)
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

    @MainActor
    func testParkedNoteProofRefusalIsUnattemptedAndRetryableButWriteFailureIsUnknown() async throws {
        // Only the typed entry refusal is definitely unsent; a writer's CancellationError is not.
        for (invalidateProof, cancelBeforeWrite, writerThrowsCancellation) in [
            (true, false, false), (false, true, false), (false, false, false), (false, false, true)
        ] {
            let isPreWriteRefusal = invalidateProof || cancelBeforeWrite
            let controller = applicationController()
            let gate = ApplicationGate()
            let writes = WrittenLines()
            await controller.test_installConfigurationTransport(initialized: true, write: {
                writes.append($0)
                if writerThrowsCancellation { throw CancellationError() }
                if !isPreWriteRefusal { throw NativeAgentRuntimeControllerError.inputWriteFailed("uncertain write") }
            })
            await controller.test_setBeforeConfigurationSend { _ = await gate.respond() }
            let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
            var notAttempted = 0
            var failed = 0
            var accepted = 0
            coordinator.installHostCapabilities(.init(
                isSessionCurrent: { $0 === session }, requestUIRefresh: { _, _ in }, scheduleSave: { _ in },
                stageClaudeResumeRecoveryHandoff: { _ in }, prependPendingHandoff: { text, _ in text },
                decorateAgentSessionLinkPrompt: { text, _, _ in .init(text: text, claim: nil, mustAbortDispatch: false) },
                acquireAgentSessionLinkPhysicalDispatch: { _, _ in true },
                recordAgentSessionLinkPhysicalDispatchNotAttempted: { _, _ in notAttempted += 1 },
                recordAgentSessionLinkPhysicalDispatchFailure: { _, _ in failed += 1 },
                acceptAgentSessionLinkPromptClaim: { _, _, _ in accepted += 1 }
            ), providerBindingService: AgentModeProviderBindingService())
            var state = session.selfCompactState
            guard case let .scheduled(noteAttempt) = state.reserve(note: "keep this exact note", idempotencyKey: "proof-race")
            else { return XCTFail("Expected parked note reservation") }
            let noteID = noteAttempt.id
            state.active?.phase = .parked
            state.active?.compactTurnSucceeded = true
            session.selfCompactState = state
            let auditID = UUID()
            session.pendingTurnRuntimeAnchors.append(.init(userItemID: auditID, userSequenceIndex: 0, startedAt: Date()))
            let disabled = AgentAutomationTurnAudit.Feature(configured: false, eligible: false, judgmentRequested: false, decision: .disabled)
            session.appendAutomationAudit(.init(turnID: auditID, createdAt: Date(), router: disabled, autoEffort: disabled))
            let send = Task {
                await coordinator.sendClaudeNativeMessage(
                    session: session, text: "ordinary", attachments: [], intent: intent,
                    allowsCatalogRouteControllerRecovery: false
                )
            }
            await gate.waitUntilEntered()
            XCTAssertEqual(session.selfCompactState.active?.noteDispatchStarted, true)
            XCTAssertEqual(writes.count, 0)
            if invalidateProof {
                _ = try await controller.applyModelAndEffortWithProof(model: session.selectedModelRaw, effortLevel: .high)
            }
            if cancelBeforeWrite { send.cancel() }
            await gate.resume()
            let outcome = await send.value
            guard case .failed = outcome else { return XCTFail("Expected send refusal/failure") }
            XCTAssertEqual(accepted, 0)
            XCTAssertEqual(notAttempted, isPreWriteRefusal ? 1 : 0)
            XCTAssertEqual(failed, isPreWriteRefusal ? 0 : 1)
            XCTAssertEqual(writes.count, isPreWriteRefusal ? 0 : 1)
            XCTAssertEqual(session.automationTurnAudit.last?.providerDispatchAttempted, !isPreWriteRefusal)
            XCTAssertEqual(session.automationTurnAudit.last?.providerTurnAccepted, false)
            if isPreWriteRefusal {
                XCTAssertEqual(session.selfCompactState.parkedNote?.dispatchID.requestID, noteID)
                XCTAssertEqual(session.selfCompactState.active?.noteDispatchStarted, false)
                XCTAssertEqual(session.selfCompactState.active?.note, "keep this exact note")
                XCTAssertNil(session.selfCompactState.latest)
                let retry = await coordinator.sendClaudeNativeMessage(
                    session: session, text: "retry", attachments: [], intent: intent,
                    allowsCatalogRouteControllerRecovery: false
                )
                XCTAssertEqual(retry, .sent)
                XCTAssertEqual(writes.count, 1)
                XCTAssertEqual(accepted, 1)
                XCTAssertEqual(session.selfCompactState.latest?.requestID, noteID)
                XCTAssertEqual(session.selfCompactState.latest?.noteDelivery, .prepended)
            } else {
                XCTAssertNil(session.selfCompactState.parkedNote)
                XCTAssertEqual(session.selfCompactState.latest?.outcome, .deliveryUnknown)
                XCTAssertEqual(session.selfCompactState.latest?.recoveryNote, "keep this exact note")
            }
        }
    }

    @MainActor
    func testSupersededAutoErrorDoesNotFallbackForIdenticalOrABAConfiguration() async throws {
        for interveningModels in [["claude-opus-5-5:high"], ["claude-sonnet-4-6:high", "claude-opus-5-5:high"]] {
            let controller = applicationController()
            let gate = ApplicationGate()
            let controls = WrittenLines()
            let writes = WrittenLines()
            await controller.test_installConfigurationTransport(initialized: true, controlRequest: { request in
                controls.append(Data())
                if (request["settings"] as? [String: Any])?["effortLevel"] as? String == "low" {
                    _ = await gate.respond()
                    throw NativeAgentRuntimeControllerError.invalidControlResponse("late Auto rejection")
                }
                return [:]
            }, write: { writes.append($0) })
            let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
            let send = Task {
                await coordinator.sendClaudeNativeMessage(
                    session: session, text: "ordinary", attachments: [], intent: intent,
                    allowsCatalogRouteControllerRecovery: false,
                    autoEffortSelection: .init(
                        provider: .claudeCode,
                        selectedModelRaw: session.selectedModelRaw,
                        manualEffortRaw: "high",
                        effortRaw: "low"
                    )
                )
            }
            await gate.waitUntilEntered()
            for model in interveningModels {
                _ = try await controller.applyModelAndEffortWithProof(model: model, effortLevel: .high)
            }
            await gate.resume()
            let outcome = await send.value
            guard case .failed = outcome else { return XCTFail("Stale Auto error must refuse, not fall back and send") }
            XCTAssertEqual(controls.count, 1 + interveningModels.count, "No manual fallback from a superseded application")
            XCTAssertEqual(writes.count, 0)
            XCTAssertEqual(session.providerSessionID, "application-proof-session")
        }
    }

    func testProductionResolverAndControlResponseGateConfigurationProof() async throws {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: { nil }, backendSecretProvider: { _ in nil })
        )
        let (frames, continuation) = AsyncStream<Data>.makeStream()
        defer { continuation.finish() }
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, controlRequest: nil, write: {
            writes.append($0)
            continuation.yield($0)
        })
        var iterator = frames.makeAsyncIterator()
        for reject in [true, false] {
            let application = Task {
                try await controller.applyModelAndEffortWithProof(model: "claude-opus-5-5:high", effortLevel: .low)
            }
            let frame = await iterator.next()
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(frame)) as? [String: Any])
            XCTAssertEqual(request["type"] as? String, "control_request")
            let body = try XCTUnwrap(request["request"] as? [String: Any])
            XCTAssertEqual(body["subtype"] as? String, "apply_flag_settings")
            let settings = try XCTUnwrap(body["settings"] as? [String: Any])
            XCTAssertEqual(settings["model"] as? String, "claude-opus-5-5")
            XCTAssertEqual(settings["effortLevel"] as? String, "low")
            let requestID = try XCTUnwrap(request["request_id"] as? String)
            let response = try (
                reject
                    ? ClaudeSDKProtocolCodec.encodeControlResponseError(requestID: requestID, error: "rejected")
                    : ClaudeSDKProtocolCodec.encodeControlResponseSuccess(requestID: requestID)
            )
            await controller.test_receiveConfigurationResponseLine(response)
            if reject {
                do {
                    _ = try await application.value
                    XCTFail("A production error response cannot certify application")
                } catch NativeAgentRuntimeControllerError.invalidControlResponse {}
                XCTAssertEqual(writes.count, 1, "Only the settings request was written")
            } else {
                guard case let .applied(proof) = try await application.value else { return XCTFail("Missing ACK proof") }
                _ = try await controller.sendUserMessage("ordinary", configuration: proof)
                let userFrame = await iterator.next()
                let user = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(userFrame)) as? [String: Any])
                XCTAssertEqual(user["type"] as? String, "user")
                XCTAssertEqual(writes.count, 3, "Two settings requests followed by one user write")
            }
        }
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
