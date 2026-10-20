import Combine
import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Handoff must not expose a child tab before the child is durable and its direct oversight grants
/// have been inherited. A failed first save remains recoverable, but cannot authorize inheritance.
@MainActor
final class AgentSessionLinkHandoffInheritanceTests: XCTestCase {
    func testHandoffDurablySavesBeforeInheritanceAndActivation() async throws {
        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            let parentEndpoint = try XCTUnwrap(
                fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.sourceTabID)
            )
            var events: [String] = []

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                // The source may also persist an adopted default; only the child's save fences inheritance.
                guard session.id != fixture.sourceSession.activeAgentSessionID else {
                    return fixture.rootURL.appendingPathComponent("source-session.json")
                }
                XCTAssertEqual(
                    fixture.window.promptManager.activeComposeTabID,
                    fixture.sourceTabID,
                    "the child must remain inactive until its first durable save completes"
                )
                events.append("save")
                return fixture.rootURL.appendingPathComponent("handoff-session.json")
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { parent, child in
                XCTAssertEqual(parent, parentEndpoint)
                XCTAssertNotEqual(child, parent)
                XCTAssertEqual(
                    fixture.window.promptManager.activeComposeTabID,
                    fixture.sourceTabID,
                    "inheritance must settle before child activation"
                )
                events.append("inherit")
                return .empty
            }

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sourceSession.selectedAgent,
                destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
            )

            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            let bindingToken = try XCTUnwrap(destinationSession.currentRestorationBindingToken)
            XCTAssertEqual(events, ["save", "inherit"])
            XCTAssertEqual(
                destinationSession.restorationReadiness,
                .authoritative(bindingToken, .freshBindingDurablyCreated)
            )
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)
        }
    }

    func testHandoffSaveFailureRetainsBlockedDestinationUntilExplicitRetry() async throws {
        enum ExpectedSaveFailure: Error { case failed }

        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            var inheritanceWasCalled = false
            var failedSaveSessionIDs: [UUID] = []

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                failedSaveSessionIDs.append(session.id)
                throw ExpectedSaveFailure.failed
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in
                inheritanceWasCalled = true
                return .empty
            }

            var partialFailure: SessionAdminPartialForkError?
            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: cutoffItemID,
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
                )
                XCTFail("An unacknowledged first save must not report a completed Handoff.")
            } catch let failure as SessionAdminPartialForkError {
                partialFailure = failure
            }
            let failure = try XCTUnwrap(partialFailure)
            XCTAssertEqual(failure.code, "persist_failed")
            let destination = try XCTUnwrap(fixture.viewModel.sessions.values.first {
                $0.activeAgentSessionID == failure.sessionID
            })
            XCTAssertNotEqual(destination.tabID, fixture.sourceTabID)
            XCTAssertEqual(failedSaveSessionIDs.filter { $0 == failure.sessionID }, [failure.sessionID])
            XCTAssertEqual(
                fixture.window.workspaceManager.activeAgentSessionID(forTabID: destination.tabID),
                failure.sessionID
            )
            XCTAssertFalse(inheritanceWasCalled)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
            XCTAssertTrue(destination.qualifiedRestorationReadiness.isCreating)
            XCTAssertFalse(destination.permitsBoundOperationAndSave)
            XCTAssertNotNil(destination.operationAdmissionFailureMessage)
            XCTAssertNil(destination.saveDebounceTask, "Generic autosave cannot complete a failed configured creation.")
            let retry = try XCTUnwrap(fixture.viewModel.captureSessionCreationRetry(for: destination))
            XCTAssertTrue(retry.session === destination)
            XCTAssertEqual(retry.bindingToken.bindingIdentity.sessionID, failure.sessionID)
            XCTAssertEqual(retry.bindingToken, destination.currentRestorationBindingToken)
            XCTAssertNotNil(retry.expectedConfigurationStamp)

            let workspaceID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspaceID)
            let genericSave = await fixture.viewModel.flushSaveRequired(for: destination.tabID, workspaceID: workspaceID)
            guard case .failure = genericSave else {
                return XCTFail("Only the captured creation owner may retry its configured first save.")
            }
            XCTAssertEqual(failedSaveSessionIDs.filter { $0 == failure.sessionID }, [failure.sessionID])
            let retryFile = fixture.rootURL.appendingPathComponent("handoff-retry.json")
            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                guard session.id != fixture.sourceSession.activeAgentSessionID else {
                    return fixture.rootURL.appendingPathComponent("source-session.json")
                }
                XCTAssertEqual(session.id, failure.sessionID)
                try JSONEncoder().encode(session).write(to: retryFile, options: .atomic)
                return retryFile
            }
            let retried = await fixture.viewModel.retrySessionInitialSave(retry)
            XCTAssertTrue(retried)
            let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: retryFile))
            XCTAssertEqual(saved.id, failure.sessionID)
            XCTAssertEqual(saved.composeTabID, destination.tabID)
            XCTAssertEqual(saved.toLiveItems().map(\.text), destination.items.map(\.text))
            XCTAssertEqual(destination.qualifiedRestorationReadiness, .authoritative(retry.bindingToken, .freshBindingDurablyCreated))
            XCTAssertNil(fixture.viewModel.captureSessionCreationRetry(for: destination))
            XCTAssertFalse(inheritanceWasCalled, "Retrying persistence cannot manufacture oversight grants.")
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
        }
    }

    #if DEBUG
        func testSwitchExpandedSkillAndTaggedFileRefusalsRetainClaimedComposer() async throws {
            for skill in [true, false] {
                try await withFixture { fixture in
                    let session = fixture.sourceSession
                    session.selectedAgent = .openCode
                    session.selectedModelRaw = "unknown-window"
                    let content = String(repeating: "expanded context ", count: 1000) + "END_FIXTURE"
                    let text: String
                    if skill {
                        let directory = fixture.rootURL.appendingPathComponent(".agents/skills/large", isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try "---\nname: large\ndescription: Fixture\n---\n\(content)".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                        text = "/large short"
                    } else {
                        let file = fixture.rootURL.appendingPathComponent("large.txt")
                        try content.write(to: file, atomically: true, encoding: .utf8)
                        session.pendingTaggedFileAttachments = [.init(relativePath: file.path, displayName: "large.txt")]
                        session.selectedWorkflow = .init(customID: UUID(), displayName: "Keep workflow")
                        text = "short"
                    }
                    let initial = await fixture.viewModel.buildInitialThreadMessageIfNeeded(tabID: session.tabID, session: session, initialMessage: text)
                    let budget = AgentProviderHandover.Budget(catalogWindow: nil, instructions: fixture.viewModel.providerSwitchInstructionStrings(session), composedInput: initial, isPreview: false)
                    let empty = try switchCarrier()
                    let padding = Int((budget.remainingCarrierTokens - 1000) * 4 / 1.05) - empty.utf8.count
                    try installSwitch(fixture, padding: padding)
                    // Raw text fits; the actual existing skill/file expansion must be measured instead.
                    guard case .success = await fixture.viewModel.providerSwitchSendAdmission(session: session, input: text, skipsAugmentation: true) else { return XCTFail("Raw input should fit") }
                    let expanded = await fixture.viewModel.augmentUserMessageForProviderSend(text, taggedFileAttachments: session.pendingTaggedFileAttachments, session: session, ignoresPendingHandoff: true)
                    XCTAssertTrue(expanded.contains(content), "The fixture must really expand the skill/tagged file")
                    fixture.viewModel.storeDraftText(for: session.tabID, text)
                    let workflow = session.selectedWorkflow
                    let files = session.pendingTaggedFileAttachments
                    let rows = session.items
                    let claim = try composerClaim(fixture, text: text)
                    let result = await fixture.viewModel.executeComposerSubmitAttempt(text: text, claim: claim)
                    XCTAssertEqual(result, .blocked(message: "Too long to send with the handover."))
                    XCTAssertEqual(session.draftText, text)
                    XCTAssertEqual(session.selectedWorkflow, workflow)
                    XCTAssertEqual(session.pendingTaggedFileAttachments, files)
                    XCTAssertEqual(session.items.map(\.id), rows.map(\.id))
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                    XCTAssertNil(session.agentTask)
                    XCTAssertNil(session.acpController)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                }
            }
        }

        func testSwitchCompositionAwaitsStopAndBindingCurrencyBeforeAcceptance() async throws {
            for drift in ["stop", "binding", "owner"] {
                try await withFixture { fixture in
                    let session = fixture.sourceSession
                    session.selectedAgent = .openCode
                    try installSwitch(fixture)
                    fixture.viewModel.storeDraftText(for: session.tabID, "keep draft")
                    var didEnterAugmentation = false
                    let release = AgentSessionLinkStopSignal<Void>()
                    defer { release.finish(()) }
                    fixture.viewModel.test_afterProviderInputAugmentation = { didEnterAugmentation = true
                        await release.value()
                    }
                    defer { fixture.viewModel.test_afterProviderInputAugmentation = nil }
                    let rows = session.items.map(\.id)
                    let claim = try composerClaim(fixture, text: "keep draft")
                    var completed: AgentModeViewModel.UserTurnSubmissionResult?
                    let submission = Task {
                        let result = await fixture.viewModel.executeComposerSubmitAttempt(text: "keep draft", claim: claim)
                        completed = result
                        return result
                    }
                    defer { submission.cancel() }
                    try await AsyncTestWait.waitUntil("composition enters its gate or refuses") { didEnterAugmentation || completed != nil }
                    guard didEnterAugmentation else { return XCTFail("Expected asynchronous composition, received \(String(describing: completed))") }
                    XCTAssertNotNil(session.activeComposerSubmitAttempt)
                    XCTAssertEqual(session.draftText, "keep draft")
                    if drift == "stop" {
                        session.stopState.invalidateScheduledStarts()
                    } else if drift == "binding" {
                        session.testInstallPersistentSessionBinding(sessionID: UUID())
                    } else {
                        fixture.viewModel.test_replaceSessionForDeferredHydration(tabID: session.tabID, with: .init(tabID: session.tabID))
                    }
                    release.finish(())
                    let result = await submission.value
                    guard case .blocked = result else { return XCTFail("Drift during composition must refuse") }
                    XCTAssertEqual(session.items.map(\.id), rows)
                    XCTAssertEqual(session.draftText, "keep draft")
                    XCTAssertNil(session.agentTask)
                    XCTAssertNil(session.acpController)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                }
            }
        }

        func testSwitchSendingSaveAndVMOnlyReadyResaveFaults() async throws {
            enum Fault: Error { case save }
            for fault in ["sending", "ready", "none"] {
                try await withFixture { fixture in
                    let session = fixture.sourceSession
                    try installSwitch(fixture)
                    let preparation = try await switchPreparation(fixture)
                    let payload = session.pendingHandoff.payload
                    let accepted = AgentChatItem.user("accepted but not dispatched", sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(accepted)
                    let fence = AgentRunStartStopFence(session: session)
                    var saves: [AgentProviderSwitchDelivery?] = []
                    fixture.viewModel.test_setAgentSessionSaver { saved, _, _ in
                        saves.append(saved.pendingHandoffProviderSwitchDelivery)
                        XCTAssertEqual(saved.pendingHandoffPayload, payload)
                        if fault == "sending" || (fault == "ready" && saves.count == 2) {
                            throw Fault.save
                        }
                        if saves.count == 1 {
                            session.stopState.invalidateScheduledStarts()
                        }
                        return fixture.rootURL.appendingPathComponent("switch.json")
                    }
                    let messages = await fixture.viewModel.prepareProviderSwitchHandoverForSend(preparation.accepting(accepted.id, session: session), session: session, stopFence: fence)
                    XCTAssertNil(messages)
                    XCTAssertEqual(saves, fault == "sending" ? [.sending] : [.sending, .ready])
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, fault == "none" ? .ready : .sending)
                    XCTAssertFalse(session.pendingHandoff.isStagedForSend)
                    XCTAssertEqual(session.pendingHandoff.payload, payload)
                    let later = await fixture.viewModel.providerSwitchSendAdmission(session: session, input: "a later input")
                    guard case let .failure(refusal) = later else { return XCTFail("A later input cannot spend the accepted row's carrier") }
                    XCTAssertEqual(refusal, fault == "none" ? .providerHandoverNeedsReview : .providerSwitchUnconfirmed)
                    XCTAssertTrue(session.items.contains { $0.id == accepted.id })
                    XCTAssertNil(session.agentTask)
                    XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.reason == "providerSwitch" })
                }
            }
        }

        func testSwitchExactStagedPhysicalSendClearsOnceAndClearSaveFailureRestoresUncertainty() async throws {
            enum Fault: Error { case clear }
            for clearFails in [false, true] {
                try await withFixture { fixture in
                    let session = fixture.sourceSession
                    try installSwitch(fixture)
                    let preparation = try await switchPreparation(fixture)
                    let payload = try XCTUnwrap(session.pendingHandoff.payload)
                    var saves: [AgentSession] = []
                    fixture.viewModel.test_setAgentSessionSaver { saved, _, _ in
                        saves.append(saved)
                        if clearFails, saved.pendingHandoffProviderSwitchDelivery == nil {
                            throw Fault.clear
                        }
                        return fixture.rootURL.appendingPathComponent("switch.json")
                    }
                    let messages = await fixture.viewModel.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                    XCTAssertEqual(messages?.user, payload + "\n\n" + preparation.augmentedInput)
                    XCTAssertEqual(messages?.initial, payload + "\n\n" + preparation.initialThreadInput)
                    XCTAssertEqual(saves.map(\.pendingHandoffProviderSwitchDelivery), [.sending])
                    XCTAssertEqual(fixture.viewModel.prependPendingHandoffIfNeeded("ordinary", session: session), "ordinary")
                    let runID = UUID()
                    session.installRunID(runID)
                    session.beginRunAttempt(source: "test.switch.physical")
                    let dispatch = AgentSessionLinkPromptDispatchID.headlessRun(runID: runID)
                    XCTAssertTrue(fixture.viewModel.providerSwitchAcquirePhysicalDispatch(session: session, dispatchID: dispatch))
                    let other = AgentSessionLinkDispatchContext(session: session, dispatchID: .headlessRun(runID: UUID()))
                    fixture.viewModel.providerSwitchRecordPhysicalAcceptance(session: session, context: other)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                    let context = AgentSessionLinkDispatchContext(session: session, dispatchID: dispatch)
                    fixture.viewModel.providerSwitchRecordPhysicalAcceptance(session: session, context: context)
                    fixture.viewModel.providerSwitchRecordPhysicalAcceptance(session: session, context: context)
                    try await AsyncTestWait.waitUntil("clear save settles") {
                        saves.count >= 2 && (clearFails ? session.pendingHandoff.providerSwitchDelivery == .sending : session.pendingHandoff.providerSwitchDelivery == nil)
                    }
                    session.saveDebounceTask?.cancel()
                    session.saveDebounceTask = nil
                    XCTAssertEqual(session.items.filter { $0.recoveryDiagnostic?.reason == "providerSwitch" }.map(\.text), ["Handover sent to \(session.selectedAgent.displayName) / \(fixture.viewModel.inputBarModelDisplayName(rawModel: session.selectedModelRaw, agentKind: session.selectedAgent))."])
                    XCTAssertEqual(session.pendingHandoff.payload, clearFails ? payload : nil)
                    XCTAssertFalse(session.pendingHandoff.isStagedForSend)
                    XCTAssertNil(session.agentTask)
                }
            }
        }

        func testSwitchLatePhysicalAcceptanceCannotClearReboundSlot() async throws {
            try await withFixture { fixture in
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let preparation = try await switchPreparation(fixture)
                fixture.viewModel.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("switch.json") }
                _ = await fixture.viewModel.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                let runID = UUID()
                session.installRunID(runID)
                session.beginRunAttempt(source: "test.switch.latePhysical")
                let dispatch = AgentSessionLinkPromptDispatchID.headlessRun(runID: runID)
                XCTAssertTrue(fixture.viewModel.providerSwitchAcquirePhysicalDispatch(session: session, dispatchID: dispatch))
                let context = AgentSessionLinkDispatchContext(session: session, dispatchID: dispatch)
                let staged = session.pendingHandoff
                let rows = session.items.map(\.id)
                session.testInstallPersistentSessionBinding(sessionID: UUID())
                fixture.viewModel.providerSwitchRecordPhysicalAcceptance(session: session, context: context)
                XCTAssertEqual(session.pendingHandoff, staged)
                XCTAssertEqual(session.items.map(\.id), rows)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
            }
        }

        func testSwitchSaveEvidenceDistinguishesPrewriteFromPossibleCommit() async throws {
            enum Fault: Error { case write }
            try await withFixture { fixture in
                let session = fixture.sourceSession
                let workspaceID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspaceID)
                var phases: [AgentModeViewModel.RequiredSavePhase] = []
                let prewrite = await fixture.viewModel.flushSaveRequired(for: session.tabID, workspaceID: UUID(), observingSavePhase: { phases.append($0) })
                guard case .failure = prewrite else { return XCTFail("Wrong workspace must refuse before write") }
                XCTAssertEqual(phases, [.beforeWrite])
                fixture.viewModel.test_setAgentSessionSaver { _, _, _ in throw Fault.write }
                phases = []
                session.isDirty = true
                let write = await fixture.viewModel.flushSaveRequired(for: session.tabID, workspaceID: workspaceID, observingSavePhase: { phases.append($0) })
                guard case .failure = write else { return XCTFail("Scripted write must fail") }
                XCTAssertEqual(phases, [.beforeWrite, .writeMayHaveCommitted])
            }
        }

        func testSwitchLinkedPostAuthorizationFitDriftAndOrphanIngressRefuseBeforeAcceptance() async throws {
            try await withFixture { fixture in
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let endpoint = try XCTUnwrap(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: session.tabID))
                let candidate = try XCTUnwrap(fixture.viewModel.agentSessionLinkCandidate(tabID: session.tabID, sessionID: endpoint.sessionID, tabName: "Target", isWindowClosing: false))
                let request = AgentSessionLinkSendRequest(linkID: UUID(), linkGeneration: 1, observerEndpoint: endpoint, observerDisplayName: "Observer", message: "assigned task", workflow: nil)
                let rows = session.items.map(\.id)
                var commits = 0
                let refused = await fixture.viewModel.agentSessionLinkPerformSend(to: candidate, request: request, liveness: {
                    .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false)
                }, commitAuthorization: {
                    commits += 1
                    session.pendingHandoff.payload = String(repeating: "x", count: AgentProviderHandover.maximumBytes + 1)
                    return .committed
                })
                XCTAssertEqual(refused, .blocked(.providerHandoverDoesNotFit))
                XCTAssertEqual(commits, 1)
                XCTAssertEqual(session.items.map(\.id), rows)
                XCTAssertNil(session.activeComposerSubmitAttempt)
                session.pendingHandoff.providerSwitchDelivery = .sending
                fixture.viewModel.storeDraftText(for: session.tabID, "retained")
                XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "retained", tabID: session.tabID), .blocked(message: AgentSessionLinkSendFailure.providerSwitchUnconfirmed.message))
                let recorder = AgentRunStartOutcomeRecorder()
                _ = await fixture.viewModel.startAgentRun(tabID: session.tabID, initialMessage: "forbidden", startOutcome: recorder)
                XCTAssertFalse(recorder.outcome.didStart)
                let orphan = await fixture.viewModel.agentSessionLinkPerformSend(to: candidate, request: request, liveness: {
                    .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false)
                }, commitAuthorization: { commits += 1
                    return .committed
                })
                XCTAssertEqual(orphan, .blocked(.providerSwitchUnconfirmed))
                XCTAssertEqual(commits, 1)
                XCTAssertEqual(session.items.map(\.id), rows)
                XCTAssertEqual(session.draftText, "retained")
                XCTAssertNil(session.agentTask)
                XCTAssertNil(session.claudeController)
            }
        }

        func testSwitchAutoWakeContinuationAndPeriodicRefuseOnceWithoutDispatchOrRows() async throws {
            for periodic in [false, true] {
                for unconfirmed in [false, true] {
                    try await withFixture { fixture in
                        let session = fixture.sourceSession
                        session.selectedAgent = .openCode
                        try installSwitch(fixture)
                        if unconfirmed {
                            session.pendingHandoff.providerSwitchDelivery = .sending
                        } else {
                            session.appendItem(.user("accepted after cutoff", sequenceIndex: session.nextSequenceIndex))
                        }
                        session.installRunID(UUID())
                        let endpoint = try XCTUnwrap(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: session.tabID))
                        var rows = session.items.map(\.id)
                        var settlements = 0
                        var sawAttempt = false
                        let observation = session.monitorReadinessChangePublisher.sink { _ in
                            MainActor.assumeIsolated {
                                if session.oversight.pendingAutoWake != nil {
                                    sawAttempt = true
                                } else if sawAttempt {
                                    settlements += 1
                                    sawAttempt = false
                                }
                            }
                        }
                        defer { observation.cancel() }
                        if periodic {
                            let attempt = AgentSessionLinkAutoWakeAttempt(
                                wakeID: UUID(), observerEndpoint: endpoint, queueEpoch: nil, queueRevision: 0,
                                wakeFingerprint: nil, admissionBasis: .periodic, attemptedFingerprint: nil,
                                physicalOutcome: .notAttempted, phase: .scheduled, task: nil,
                                stopFence: .init(session: session)
                            )
                            session.oversight.pendingAutoWake = attempt
                            sawAttempt = true
                            await fixture.viewModel.agentSessionLinkRunPeriodicAttempt(attempt, session: session)
                            // A stale scheduled callback cannot reserve another attempt or start a loop.
                            fixture.viewModel.agentSessionLinkScheduleAutoWakeReevaluation(wakeID: attempt.wakeID, endpoint: endpoint)
                        } else {
                            let waiting = Task { try await fixture.viewModel.waitForNextUserInstruction(tabID: session.tabID, timeoutSeconds: 10) }
                            try await AsyncTestWait.waitUntil("waiting continuation installed") { session.instructionContinuation != nil }
                            // The existing wait owner publishes its prompt row before wake admission.
                            rows = session.items.map(\.id)
                            defer {
                                session.instructionTimeoutTask?.cancel()
                                session.instructionTimeoutTask = nil
                                session.instructionContinuation?.resume(throwing: CancellationError())
                                session.instructionContinuation = nil
                                session.instructionWaitID = nil
                                session.waitingPrompt = nil
                                waiting.cancel()
                            }
                            try publishSwitchWake(fixture, endpoint: endpoint)
                            let attempt = try XCTUnwrap(session.oversight.pendingAutoWake)
                            sawAttempt = true
                            await attempt.task?.value
                            XCTAssertNotNil(session.instructionContinuation, "Refusal must not resume the provider's held input")
                            fixture.viewModel.agentSessionLinkScheduleAutoWakeReevaluation(wakeID: attempt.wakeID, endpoint: endpoint)
                            session.oversight.autoWakeOnUpdates = false
                            session.instructionTimeoutTask?.cancel()
                            session.instructionTimeoutTask = nil
                            let continuation = session.instructionContinuation
                            session.instructionContinuation = nil
                            session.instructionWaitID = nil
                            continuation?.resume(throwing: CancellationError())
                            _ = try? await waiting.value
                        }
                        XCTAssertEqual(settlements, 1)
                        XCTAssertNil(session.oversight.pendingAutoWake)
                        XCTAssertEqual(session.items.map(\.id), rows)
                        XCTAssertNil(session.agentTask)
                        XCTAssertNil(session.acpController)
                        XCTAssertNil(session.activeComposerSubmitAttempt)
                    }
                }
            }
        }

        func testSwitchReviewRefreshesAcceptedUndispatchedInputAndNextCarrierConsumesItOnce() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let original = session.pendingHandoff
                let preparation = try await switchPreparation(fixture)
                let attributed = AgentChatItem.user(
                    "accepted linked request, never executed",
                    sequenceIndex: session.nextSequenceIndex,
                    crossSessionAttribution: .init(sourceSessionID: UUID(), sourceName: "Observer", linkID: UUID())
                )
                session.appendItem(attributed)
                let fence = AgentRunStartStopFence(session: session)
                vm.test_setAgentSessionSaver { _, _, _ in
                    session.stopState.invalidateScheduledStarts()
                    return fixture.rootURL.appendingPathComponent("source.json")
                }
                let withheld = await vm.prepareProviderSwitchHandoverForSend(preparation.accepting(attributed.id, session: session), session: session, stopFence: fence)
                XCTAssertNil(withheld)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                guard case .failure(.providerHandoverNeedsReview) = await vm.providerSwitchSendAdmission(session: session, input: "later input") else { return XCTFail("A later input cannot consume the old carrier") }
                vm.test_setAgentSessionSaver { saved, _, _ in
                    XCTAssertTrue(saved.pendingHandoffPayload?.contains("accepted linked request, never executed") == true)
                    return fixture.rootURL.appendingPathComponent("source.json")
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let review = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(review.cutoff, attributed.id)
                XCTAssertEqual(try XCTUnwrap(review.source).provider, "source")
                vm.providerSwitchPreview?.selected = .history
                let applied = await vm.applyProviderSwitch(review.id)
                XCTAssertTrue(applied)
                XCTAssertEqual(session.pendingHandoff.sourceItemID, attributed.id)
                XCTAssertNotEqual(session.pendingHandoff.payload, original.payload)
                XCTAssertNil(session.providerSessionID)
                XCTAssertNil(session.codexConversationID)
                let next = try await switchPreparation(fixture)
                let inserted = await vm.prepareProviderSwitchHandoverForSend(next, session: session, stopFence: .init(session: session))
                let user = try XCTUnwrap(inserted?.user)
                XCTAssertEqual(user.components(separatedBy: "<repoprompt_provider_handover ").count - 1, 1)
                XCTAssertTrue(user.contains("accepted linked request, never executed"))
                XCTAssertTrue(user.hasSuffix("\n\nordinary input"))
                XCTAssertNil(session.agentTask)
            }
        }

        func testOrphanReviewCancelThenSwitchStartsFreshWithUncertainInputOnlyAsHistory() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                session.pendingHandoff.providerSwitchDelivery = .sending
                session.providerSessionID = "uncertain-native"
                session.codexConversationID = "stale-other-family"
                session.codexRolloutPath = "/retained/native.jsonl"
                let uncertain = AgentChatItem.user("uncertain previous input", sequenceIndex: session.nextSequenceIndex)
                session.appendItem(uncertain)
                let slot = session.pendingHandoff
                await vm.openProviderSwitchPreview(agent: session.selectedAgent, model: session.selectedModelRaw, tabID: session.tabID)
                vm.cancelProviderSwitchPreview()
                XCTAssertEqual(session.pendingHandoff, slot)
                XCTAssertTrue(AgentModeViewModel.providerSwitchUnconfirmed(session))
                await vm.openProviderSwitchPreview(agent: session.selectedAgent, model: session.selectedModelRaw, tabID: session.tabID)
                let review = try XCTUnwrap(vm.providerSwitchPreview)
                vm.providerSwitchPreview?.selected = .history
                var retirements = 0
                vm.test_providerSwitchRetirement = { outgoing in
                    XCTAssertEqual(outgoing.providerSessionID, "uncertain-native")
                    retirements += 1
                }
                var saves = 0
                vm.test_setAgentSessionSaver { saved, _, _ in
                    saves += 1
                    XCTAssertNil(saved.providerSessionID)
                    XCTAssertNil(saved.codexConversationID)
                    XCTAssertNil(saved.codexRolloutPath)
                    XCTAssertEqual(saved.pendingHandoffProviderSwitchDelivery, saves == 1 ? .ready : .sending)
                    return fixture.rootURL.appendingPathComponent("fresh.json")
                }
                let applied = await vm.applyProviderSwitch(review.id)
                XCTAssertTrue(applied)
                XCTAssertEqual(retirements, 1)
                XCTAssertEqual(session.pendingHandoff.sourceItemID, uncertain.id)
                XCTAssertTrue(session.pendingHandoff.payload?.contains("<message role=\"user\">uncertain previous input</message>") == true)
                let next = try await switchPreparation(fixture)
                let payload = await vm.prepareProviderSwitchHandoverForSend(next, session: session, stopFence: .init(session: session))
                XCTAssertTrue(payload?.user.hasSuffix("\n\nordinary input") == true)
                XCTAssertFalse(payload?.user.hasSuffix("\n\nuncertain previous input") == true)
                XCTAssertNil(session.agentTask)
            }
        }

        func testSwitchApplyPreservesAllKindIdentityAndSavesCompleteTupleOnce() async throws {
            for kind in ["standalone", "overseer", "linked"] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    if kind == "linked" { session.parentSessionID = UUID()
                        session.createdByOverseerSessionID = UUID()
                        session.isMCPOriginated = true
                    }
                    session.organizationalParentID = UUID()
                    session.delegationScopeID = UUID()
                    let parent = session.parentSessionID
                    let creator = session.createdByOverseerSessionID
                    let organization = session.organizationalParentID
                    let delegation = session.delegationScopeID
                    let endpoint = vm.agentSessionLinkObserverEndpoint(tabID: session.tabID)
                    let worktrees = session.worktreeBindings
                    let merges = session.worktreeMergeOperations
                    let usage = session.providerTokenUsageByTurn
                    let audit = session.automationTurnAudit
                    let binding = session.currentRestorationBindingToken
                    session.providerSessionID = "source-native"
                    session.codexConversationID = "old-codex"
                    session.codexRolloutPath = "/unchanged-on-disk/rollout"
                    session.codexModel = "old"
                    session.codexReasoningEffort = "high"
                    session.contextUsageSnapshot = .init(used: 123, window: 200_000, confidence: .exact, source: .claudeUsageEvent)
                    var saves = 0
                    vm.test_setAgentSessionSaver { saved, _, _ in
                        saves += 1
                        XCTAssertEqual(saved.pendingHandoffProviderSwitchDelivery, .ready)
                        XCTAssertNotNil(saved.pendingHandoffPayload)
                        XCTAssertNil(saved.providerSessionID)
                        XCTAssertNil(saved.codexConversationID)
                        return fixture.rootURL.appendingPathComponent("applied.json")
                    }
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let preview = try XCTUnwrap(vm.providerSwitchPreview)
                    let applied = await vm.applyProviderSwitch(preview.id)
                    XCTAssertTrue(applied)
                    XCTAssertEqual(saves, 1)
                    XCTAssertEqual(session.currentRestorationBindingToken, binding)
                    XCTAssertEqual(vm.agentSessionLinkObserverEndpoint(tabID: session.tabID), endpoint)
                    XCTAssertEqual(session.parentSessionID, parent)
                    XCTAssertEqual(session.createdByOverseerSessionID, creator)
                    XCTAssertEqual(session.organizationalParentID, organization)
                    XCTAssertEqual(session.delegationScopeID, delegation)
                    XCTAssertEqual(session.worktreeBindings, worktrees)
                    XCTAssertEqual(session.worktreeMergeOperations, merges)
                    XCTAssertEqual(session.providerTokenUsageByTurn, usage)
                    XCTAssertEqual(session.automationTurnAudit, audit)
                    XCTAssertNil(session.contextUsageSnapshot)
                    XCTAssertNil(session.vouchedContextCount)
                    XCTAssertNil(session.codexRolloutPath)
                    XCTAssertNil(session.codexModel)
                    XCTAssertNil(session.codexReasoningEffort)
                    let notices = session.items.filter { $0.recoveryDiagnostic?.reason == "providerSwitch" }
                    XCTAssertEqual(notices.count, 1)
                    XCTAssertEqual(notices[0].text, try "Provider changed from \(XCTUnwrap(preview.source).provider) / \(XCTUnwrap(preview.source).model) to OpenCode / unknown-window; handover: Full history.")
                    XCTAssertNil(session.agentTask)
                }
            }
        }

        func testSwitchRollbackRequiresPrewriteEvidenceAndRetirementCannotSaveEmptyContext() async throws {
            enum Fault: Error { case possibleWrite }
            for fault in ["prewrite", "possibleWrite"] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.providerSessionID = "restore-source"
                    session.codexConversationID = "restore-codex"
                    session.codexRolloutPath = "/restore/path"
                    session.codexModel = "restore-model"
                    session.codexReasoningEffort = "high"
                    session.contextUsageSnapshot = .init(used: 4321, window: 200_000, confidence: .exact, source: .claudeUsageEvent)
                    session.noteLiveContextUsageReport(contextUsedTokens: 4321, promptTokens: nil, modelContextWindow: 200_000)
                    let countVouch = session.vouchedContextCount
                    let windowVouch = session.vouchedContextWindow
                    let context = session.contextUsageSnapshot
                    let rows = session.items.map(\.id)
                    let workspaceID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspaceID)
                    var saves = 0
                    vm.test_setAgentSessionSaver { _, _, _ in saves += 1
                        throw Fault.possibleWrite
                    }
                    vm.test_providerSwitchRetirement = { outgoing in
                        let result = await vm.flushSaveRequired(for: outgoing.tabID, workspaceID: workspaceID)
                        guard case .failure = result else { return XCTFail("Retirement must gate all incidental saves") }
                        XCTAssertEqual(outgoing.providerSessionID, "restore-source")
                        XCTAssertEqual(saves, 0)
                    }
                    vm.test_providerSwitchBeforeSave = { outgoing in
                        if fault == "prewrite" { outgoing.isInstallingHandoffWorktreeBindings = true }
                    }
                    defer { session.isInstallingHandoffWorktreeBindings = false }
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    let applied = await vm.applyProviderSwitch(id)
                    XCTAssertFalse(applied)
                    if fault == "prewrite" {
                        XCTAssertEqual(saves, 0)
                        XCTAssertEqual(session.providerSessionID, "restore-source")
                        XCTAssertEqual(session.codexConversationID, "restore-codex")
                        XCTAssertEqual(session.codexRolloutPath, "/restore/path")
                        XCTAssertEqual(session.codexModel, "restore-model")
                        XCTAssertEqual(session.codexReasoningEffort, "high")
                        XCTAssertEqual(session.contextUsageSnapshot, context)
                        XCTAssertEqual(session.vouchedContextCount, countVouch)
                        XCTAssertEqual(session.vouchedContextWindow, windowVouch)
                        XCTAssertNil(session.pendingHandoff.payload)
                        XCTAssertEqual(session.items.map(\.id), rows)
                    } else {
                        XCTAssertEqual(saves, 1)
                        XCTAssertEqual(session.selectedAgent, .openCode)
                        XCTAssertNil(session.providerSessionID)
                        XCTAssertNotNil(session.pendingHandoff.payload)
                        XCTAssertEqual(session.items.count(where: { $0.recoveryDiagnostic?.reason == "providerSwitch" }), 1)
                    }
                }
            }
        }

        func testSwitchBusyPreviewPendingPickerAndDiscardAreExplicitOnly() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let agent = session.selectedAgent
                session.mcpFollowUpRunPending = true
                await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                let busy = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertNotNil(vm.providerSwitchPreviewBlocker(busy))
                let applied = await vm.applyProviderSwitch(busy.id)
                XCTAssertFalse(applied)
                XCTAssertEqual(session.selectedAgent, agent)
                vm.cancelProviderSwitchPreview()
                session.mcpFollowUpRunPending = false
                XCTAssertTrue(vm.canSelectAgentInCurrentChat(.claudeCodeGLM), "Existing Claude-family continuity remains allowed")
                try installSwitch(fixture)
                XCTAssertTrue(vm.providerSwitchPickerRequiresPreview(agent, session: session))
                XCTAssertTrue(vm.providerSwitchPickerRequiresPreview(.claudeCodeGLM, session: session))
                let slot = session.pendingHandoff
                await vm.openProviderSwitchPreview(agent: agent, model: session.selectedModelRaw, tabID: session.tabID)
                XCTAssertNil(vm.providerSwitchPreview?.wordLimit)
                let oldID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                await vm.generateProviderSwitchHandover(oldID)
                XCTAssertEqual(session.pendingHandoff, slot)
                vm.cancelProviderSwitchPreview()
                XCTAssertEqual(session.pendingHandoff, slot)
                let firstOpen = await vm.openProviderSwitchPreview(agent: agent, model: session.selectedModelRaw, tabID: session.tabID)
                let replacementOpen = await vm.openProviderSwitchPreview(agent: agent, model: session.selectedModelRaw, tabID: session.tabID)
                let staleDiscard = try await vm.applyProviderSwitch(XCTUnwrap(firstOpen), discard: true)
                XCTAssertFalse(staleDiscard, "A banner click's captured ID cannot discard a newer preview")
                XCTAssertEqual(session.pendingHandoff, slot)
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("discard.json") }
                let discarded = try await vm.applyProviderSwitch(XCTUnwrap(replacementOpen), discard: true)
                XCTAssertTrue(discarded)
                XCTAssertNil(session.pendingHandoff.payload)
                XCTAssertEqual(session.items.last?.text, "Pending handover discarded; chat history unchanged.")
                XCTAssertEqual(session.selectedAgent, agent)
            }
        }

        func testCursorModelMenuVariantsStayTransientUntilSwitchAndRollbackWithTuple() async throws {
            GlobalSettingsStore.installApplicationModelIdentityPolicy()
            AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
            defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
            let model = "grok-4.6"
            let definition = ACPModelParameterDefinition(
                kind: .thinking, configID: "effort", displayName: "Effort",
                choices: [.init(rawValue: "low", displayName: "Low"), .init(rawValue: "high", displayName: "High")],
                currentValueRaw: "low"
            )
            _ = AgentACPModelRegistry.shared.updateDiscoveredModels(.init(
                options: [.init(rawValue: model, displayName: "Grok 4.6", description: nil, isDefault: false)],
                currentModelRaw: model, modelParameterSets: [.init(baseModelRaw: model, parameters: [definition])]
            ), for: .cursor)
            let low = ACPModelParameterSelection(providerID: .cursor, baseModelRaw: model, kind: .thinking, configID: "effort", valueRaw: "low")
            let high = ACPModelParameterSelection(providerID: .cursor, baseModelRaw: model, kind: .thinking, configID: "effort", valueRaw: "high")
            for clear in [false, true] {
                for prewrite in [false, true] {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        try installSwitch(fixture)
                        session.acpModelParameterSelections = [low]
                        let sourceAgent = session.selectedAgent
                        let sourceModel = session.selectedModelRaw
                        let slot = session.pendingHandoff
                        let intent: AgentModeViewModel.ProviderSwitchCursorParameterIntent = clear ? .clear(low.identity) : .select(high)
                        XCTAssertTrue(vm.requestProviderSwitchSelection(agent: .cursor, model: model, tabID: session.tabID, cursorParameterIntent: intent))
                        try await AsyncTestWait.waitUntil("Cursor variant Review prepared") { vm.providerSwitchPreview?.building == false }
                        XCTAssertEqual(session.acpModelParameterSelections, [low])
                        XCTAssertEqual(session.selectedAgent, sourceAgent)
                        XCTAssertEqual(vm.providerSwitchPreview?.model, model)
                        vm.cancelProviderSwitchPreview()
                        XCTAssertEqual(session.pendingHandoff, slot)
                        XCTAssertEqual(session.acpModelParameterSelections, [low], "Cancel never writes variant intent")
                        await vm.openProviderSwitchPreview(agent: .cursor, model: model, tabID: session.tabID, cursorParameterIntent: intent)
                        vm.providerSwitchPreview?.selected = .history
                        let expected = clear ? [] : [high]
                        var savedTuples: [AgentSession] = []
                        let saveURL = fixture.rootURL.appendingPathComponent("cursor-variant.json")
                        vm.test_setAgentSessionSaver { saved, _, _ in
                            savedTuples.append(saved)
                            return saveURL
                        }
                        // Teardown may save the restored source after a prewrite refusal. Retire
                        // this assertion/capture boundary before fixture teardown can suspend.
                        defer { vm.test_setAgentSessionSaver { _, _, _ in saveURL } }
                        vm.test_providerSwitchBeforeSave = { if prewrite { $0.isInstallingHandoffWorktreeBindings = true } }
                        defer { session.isInstallingHandoffWorktreeBindings = false }
                        let applied = try await vm.applyProviderSwitch(XCTUnwrap(vm.providerSwitchPreview?.id))
                        XCTAssertEqual(applied, !prewrite)
                        XCTAssertEqual(savedTuples.count, prewrite ? 0 : 1)
                        if !prewrite {
                            let saved = try XCTUnwrap(savedTuples.first)
                            XCTAssertEqual(saved.agentKind, AgentProviderKind.cursor.rawValue)
                            XCTAssertEqual(saved.agentModel, model)
                            XCTAssertEqual(saved.acpModelParameterSelections, expected)
                        }
                        XCTAssertEqual(session.acpModelParameterSelections, prewrite ? [low] : expected)
                        if prewrite {
                            XCTAssertEqual(session.selectedAgent, sourceAgent)
                            XCTAssertEqual(session.selectedModelRaw, sourceModel)
                            XCTAssertEqual(session.pendingHandoff, slot)
                        } else {
                            let ready = session.pendingHandoff
                            vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("separate-parameter.json") }
                            vm.selectACPModelParameter(low)
                            XCTAssertEqual(session.acpModelParameterSelections, [low], "Separate ACP control keeps its existing immediate behavior")
                            XCTAssertNil(vm.providerSwitchPreview)
                            XCTAssertEqual(session.pendingHandoff, ready)
                        }
                    }
                }
            }
        }

        func testSourceGenerationCompletionNeverRetargetsReboundSession() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("generation-drift.json") }
                vm.test_providerSwitchGeneration = { outgoing, _, _ in
                    outgoing.appendItem(.assistant("late source result", sequenceIndex: outgoing.nextSequenceIndex))
                    outgoing.runState = .completed
                    outgoing.testInstallPersistentSessionBinding(sessionID: UUID())
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                await vm.generateProviderSwitchHandover(preview.id)
                // The synchronous terminal guard must refuse before scheduling a rebuild.
                XCTAssertFalse(vm.providerSwitchPreview?.generationFinished ?? true)
                XCTAssertEqual(vm.providerSwitchPreview?.id, preview.id)
                XCTAssertEqual(vm.providerSwitchPreview?.binding, preview.binding)
                XCTAssertNil(vm.providerSwitchPreview?.choices.first { $0.mode == .summary }?.carrier)
                XCTAssertNotNil(vm.providerSwitchPreviewBlocker(preview))
                XCTAssertNil(session.pendingHandoff.payload)
            }
        }

        func testSwitchSourceGenerationUsesOrdinaryUnauthoredTurnWithoutConsumingComposer() async throws {
            for tools in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.draftText = "keep composer"
                    session.selectedWorkflow = .init(customID: UUID(), displayName: "Keep workflow")
                    let workflow = session.selectedWorkflow
                    vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("generation.json") }
                    vm.test_providerSwitchGeneration = { outgoing, rowID, request in
                        guard let row = outgoing.items.first(where: { $0.id == rowID }) else { return XCTFail("Generation row missing") }
                        XCTAssertEqual(row.text, request)
                        XCTAssertNil(row.userInputOrigin)
                        XCTAssertNil(row.crossSessionAttribution)
                        if tools { outgoing.appendItem(.init(kind: .toolCall, text: "effect", toolName: "read_file", sequenceIndex: outgoing.nextSequenceIndex)) }
                        outgoing.appendItem(.assistant("source-written summary", sequenceIndex: outgoing.nextSequenceIndex))
                        outgoing.runState = .completed
                    }
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    await vm.generateProviderSwitchHandover(id)
                    try await AsyncTestWait.waitUntil("source generation has a measured preview") {
                        vm.providerSwitchPreview?.id != id && vm.providerSwitchPreview?.building == false
                    }
                    let summary = try XCTUnwrap(vm.providerSwitchPreview?.choices.first { $0.mode == .summary })
                    if tools { XCTAssertEqual(summary.unavailable, "the model used tools")
                        XCTAssertNil(summary.carrier)
                    } else { XCTAssertNil(summary.unavailable)
                        XCTAssertNotNil(summary.carrier)
                    }
                    XCTAssertEqual(session.draftText, "keep composer")
                    XCTAssertEqual(session.selectedWorkflow, workflow)
                    XCTAssertNil(session.pendingHandoff.payload, "Generate must never auto-apply")
                    XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.reason == "providerSwitch" })
                }
            }
        }

        func testSwitchCutoffUsesCanonicalTailAndSurvivesActualSaveRestore() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let durableTail = try XCTUnwrap(session.items.last?.id)
                let meta = AgentChatItem(kind: .toolCall, text: "filtered harness status", toolName: "set_status", sequenceIndex: session.nextSequenceIndex)
                session.appendItem(meta)
                vm.test_setAgentSessionSaver { saved, workspace, _ in
                    try await AgentSessionDataService.shared.saveAgentSession(saved, for: workspace)
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                try await AsyncTestWait.waitUntil("canonical cutoff preview settled") { vm.providerSwitchPreview?.building == false }
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(preview.cutoff, durableTail)
                XCTAssertNotEqual(preview.cutoff, meta.id)
                let applied = await vm.applyProviderSwitch(preview.id)
                XCTAssertTrue(applied)
                session.hasLoadedPersistedState = false
                let restored = await vm.ensureSessionReady(tabID: session.tabID, reconnectActiveProviders: false)
                XCTAssertTrue(restored === session)
                XCTAssertFalse(restored.items.contains { $0.id == meta.id })
                XCTAssertEqual(restored.pendingHandoff.sourceItemID, durableTail)
                XCTAssertFalse(AgentModeViewModel.providerSwitchNeedsReview(restored))
                guard case .success(.some) = await vm.providerSwitchSendAdmission(session: restored, input: "new ordinary input") else {
                    return XCTFail("A canonical tail must not become stale after normalization and restore")
                }
            }
        }

        func testReviewNoticeFilteringKeepsEarlierCompactedEventsAndExcludesOwnEmptyHistoryNotice() async throws {
            for empty in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.setItemsSilently([], reason: .testOverride)
                    session.transcript = .empty
                    session.nextSequenceIndex = 0
                    var cutoff: UUID?
                    if !empty {
                        let olderApplied = AgentTranscriptRecoveryDiagnostic(sequenceIndex: 2, reason: "providerSwitch", outcome: "applied", text: "older completed switch applied")
                        let olderSent = AgentTranscriptRecoveryDiagnostic(sequenceIndex: 3, reason: "providerSwitch", outcome: "sent", text: "older completed switch sent")
                        let anchor = AgentTranscriptRecoveryDiagnostic(sequenceIndex: 10, reason: "resume", outcome: "freshThreadStarted", text: "retained cutoff event")
                        cutoff = anchor.id
                        let request = AgentChatItem.user("compacted original task", sequenceIndex: 0)
                        var turn = AgentTranscriptTurn(request: .init(from: request), responseSpans: [], conclusionActivityID: nil, terminalState: .completed, startedAt: request.timestamp, completedAt: request.timestamp)
                        turn.retentionTier = .condensed
                        turn.summary = .init(requestText: nil, conclusionText: "retained conclusion", compactConclusionText: nil, middleSummaryText: "retained middle", toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false, recoveryDiagnostics: [olderApplied, olderSent, anchor])
                        session.transcript = AgentTranscript(turns: [turn])
                    }
                    session.pendingHandoff = try .init(payload: switchCarrier(), createdAt: Date(), sourceItemID: cutoff, providerSwitchDelivery: .ready)
                    session.nextSequenceIndex = empty ? 0 : 11
                    session.appendItem(.system("own pending switch notice", sequenceIndex: empty ? 0 : 11, recoveryDiagnostic: .init(reason: "providerSwitch", outcome: "applied", text: "own pending switch notice")))
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    try await AsyncTestWait.waitUntil("pending notice review settled") { vm.providerSwitchPreview?.building == false }
                    let preview = try XCTUnwrap(vm.providerSwitchPreview)
                    let payload = await vm.providerSwitchPayload(preview.id, mode: .newestTurns)
                    let recent = try XCTUnwrap(payload)
                    XCTAssertFalse(recent.contains("own pending switch notice"))
                    if !empty {
                        XCTAssertTrue(recent.contains("older completed switch applied"))
                        XCTAssertTrue(recent.contains("older completed switch sent"))
                        XCTAssertTrue(recent.contains("retained cutoff event"))
                    }
                    XCTAssertEqual(session.pendingHandoff.sourceItemID, cutoff)
                }
            }
        }

        func testGeneratedSummaryKeepsReadableHistoryAndRefitsOnlyDraftOrWorkflowChanges() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("readable-summary.json") }
                var generations = 0
                vm.test_providerSwitchGeneration = { outgoing, _, _ in
                    generations += 1
                    outgoing.appendItem(.assistant("validated source summary", sequenceIndex: outgoing.nextSequenceIndex))
                    outgoing.runState = .completed
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let originalID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                await vm.generateProviderSwitchHandover(originalID)
                try await AsyncTestWait.waitUntil("generated readable summary") { vm.providerSwitchPreview?.generatedSummary != nil && vm.providerSwitchPreview?.building == false }
                var preview = try XCTUnwrap(vm.providerSwitchPreview)
                let sourceRevision = preview.sourceRevision
                let cutoff = preview.cutoff
                let summary = try XCTUnwrap(preview.choices.first(where: { $0.mode == .summary })?.carrier)
                XCTAssertEqual(summary.historyReference?.sessionID, session.activeAgentSessionID)
                let rendered = AgentProviderHandover.render(summary)
                XCTAssertTrue(rendered.contains("availability=\"readable\""))
                XCTAssertTrue(rendered.contains("validated source summary"))
                for workflowChange in [false, true] {
                    let oldID = preview.id
                    if workflowChange {
                        vm.selectWorkflow(.init(customID: UUID(), displayName: "New workflow", template: String(repeating: "wrapper ", count: 2000) + "$ARGUMENTS"))
                    } else {
                        vm.storeDraftText(for: session.tabID, String(repeating: "draft ", count: 2000))
                        vm.updateBindingsFromSession(session)
                    }
                    try await AsyncTestWait.waitUntil("composition-only summary refit") { vm.providerSwitchPreview?.id != oldID && vm.providerSwitchPreview?.building == false }
                    let current = try XCTUnwrap(vm.providerSwitchPreview)
                    XCTAssertEqual(current.sourceRevision, sourceRevision)
                    XCTAssertEqual(current.cutoff, cutoff)
                    XCTAssertEqual(current.generatedSummary?.text, "validated source summary")
                    XCTAssertEqual(current.choices.first(where: { $0.mode == .summary })?.carrier?.historyReference?.sessionID, session.activeAgentSessionID)
                    XCTAssertNotNil(current.choices.first(where: { $0.mode == .summary })?.carrier)
                    XCTAssertGreaterThan(try XCTUnwrap(current.budget).inputTokens, 2048)
                    XCTAssertEqual(generations, 1, "Refitting must never rerun Generate")
                    preview = current
                }
                session.appendItem(.user("later accepted source input", sequenceIndex: session.nextSequenceIndex))
                vm.updateBindingsFromSession(session)
                try await AsyncTestWait.waitUntil("source change invalidates summary") { vm.providerSwitchPreview?.id != preview.id && vm.providerSwitchPreview?.building == false }
                XCTAssertNil(vm.providerSwitchPreview?.generatedSummary)
                XCTAssertNil(vm.providerSwitchPreview?.choices.first(where: { $0.mode == .summary })?.carrier)
                XCTAssertEqual(generations, 1)
                XCTAssertNil(session.pendingHandoff.payload)
            }
        }

        func testMalformedSwitchCarrierStillPermitsDirectClaimedDiscardWithoutSourceOrReset() async throws {
            for malformed in [
                "<repoprompt_provider_handover version=\"1\" mode=\"history\" source_provider=\" \" source_model=\"model\"></repoprompt_provider_handover>",
                "<repoprompt_provider_handover version=\"1\" mode=\"history\" source_provider=\"source\" source_model=\"model\"><omitted kind=\"older_turns\" first=\"0\" last=\"\(Int.max)\" /></repoprompt_provider_handover>"
            ] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.providerSessionID = "native-context-must-survive-discard"
                    session.pendingHandoff = .init(payload: malformed, createdAt: Date(), sourceItemID: session.items.last?.id, providerSwitchDelivery: .sending)
                    let rows = session.items.map(\.id)
                    var retirements = 0
                    var saves = 0
                    vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                    vm.test_setAgentSessionSaver { saved, _, _ in
                        XCTAssertNil(saved.pendingHandoffPayload)
                        XCTAssertNil(saved.pendingHandoffProviderSwitchDelivery)
                        saves += 1
                        return fixture.rootURL.appendingPathComponent("discard-corrupt.json")
                    }
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                    let review = try XCTUnwrap(vm.providerSwitchPreview)
                    XCTAssertNil(review.source, "Corrupt source XML must never acquire the selected provider as its author")
                    XCTAssertEqual(vm.providerSwitchPreviewBlocker(review), AgentSessionLinkSendFailure.providerHandoverNeedsReview.message)
                    let switched = await vm.applyProviderSwitch(review.id)
                    XCTAssertFalse(switched)
                    vm.cancelProviderSwitchPreview()
                    let discarded = await vm.discardProviderSwitchHandover(tabID: session.tabID)
                    XCTAssertTrue(discarded)
                    XCTAssertNil(vm.providerSwitchPreview, "Banner Discard must not publish or render a Review")
                    XCTAssertEqual(session.pendingHandoff, .init())
                    XCTAssertEqual(session.providerSessionID, "native-context-must-survive-discard")
                    XCTAssertEqual(retirements, 0)
                    XCTAssertEqual(saves, 1)
                    XCTAssertEqual(Array(session.items.dropLast()).map(\.id), rows)
                    XCTAssertEqual(session.items.last?.text, "Pending handover discarded; chat history unchanged.")
                    XCTAssertEqual(session.items.last?.recoveryDiagnostic?.outcome, "discarded")
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                }
            }
        }

        func testGenerationStartupFailureCannotMutateReplacementBuildingPreview() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("generation-startup.json") }
                let startEntered = AgentSessionLinkStopSignal<Void>()
                let startRelease = AgentSessionLinkStopSignal<Void>()
                let buildEntered = AgentSessionLinkStopSignal<Void>()
                let buildRelease = AgentSessionLinkStopSignal<Void>()
                defer { startRelease.finish(())
                    buildRelease.finish(())
                    vm.test_providerSwitchGenerationStart = nil
                    vm.test_afterProviderInputAugmentation = nil
                }
                vm.test_providerSwitchGenerationStart = { _, _, _ in
                    startEntered.finish(())
                    await startRelease.value() // Default recorder outcome is the real failed-start branch.
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "first", tabID: session.tabID)
                let first = try XCTUnwrap(vm.providerSwitchPreview?.id)
                let generation = Task { await vm.generateProviderSwitchHandover(first) }
                await startEntered.value()
                vm.cancelProviderSwitchPreview()
                vm.test_afterProviderInputAugmentation = { buildEntered.finish(())
                    await buildRelease.value()
                }
                let replacement = Task { await vm.openProviderSwitchPreview(agent: .openCode, model: "replacement", tabID: session.tabID) }
                await buildEntered.value()
                let replacementID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                XCTAssertTrue(vm.providerSwitchPreview?.choices.isEmpty == true)
                startRelease.finish(())
                await generation.value
                XCTAssertEqual(vm.providerSwitchPreview?.id, replacementID)
                XCTAssertTrue(vm.providerSwitchPreview?.choices.isEmpty == true)
                XCTAssertNil(vm.providerSwitchPreview?.failure)
                XCTAssertNil(vm.providerSwitchPreview?.generationItemID)
                buildRelease.finish(())
                _ = await replacement.value
            }
        }

        func testGenerationSettlementCannotWriteIntoNewerCompletedPreview() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("generation-settlement.json") }
                vm.test_providerSwitchGeneration = { outgoing, _, _ in
                    outgoing.appendItem(.assistant("old generated summary", sequenceIndex: outgoing.nextSequenceIndex))
                    outgoing.runState = .completed
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "first", tabID: session.tabID)
                let first = try XCTUnwrap(vm.providerSwitchPreview?.id)
                let rebuildEntered = AgentSessionLinkStopSignal<Void>()
                let rebuildRelease = AgentSessionLinkStopSignal<Void>()
                let rebuildFinished = AgentSessionLinkStopSignal<Void>()
                defer { rebuildRelease.finish(())
                    vm.test_afterProviderInputAugmentation = nil
                    vm.test_providerSwitchGenerationRebuildDidFinish = nil
                }
                vm.test_providerSwitchGenerationRebuildDidFinish = { rebuildFinished.finish(()) }
                vm.test_afterProviderInputAugmentation = { rebuildEntered.finish(())
                    await rebuildRelease.value()
                }
                await vm.generateProviderSwitchHandover(first)
                await rebuildEntered.value()
                vm.cancelProviderSwitchPreview()
                vm.test_afterProviderInputAugmentation = nil
                await vm.openProviderSwitchPreview(agent: .openCode, model: "newer", tabID: session.tabID)
                let newer = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertFalse(newer.building)
                rebuildRelease.finish(())
                await rebuildFinished.value()
                XCTAssertEqual(vm.providerSwitchPreview?.id, newer.id)
                XCTAssertEqual(vm.providerSwitchPreview?.selected, newer.selected)
                XCTAssertNil(vm.providerSwitchPreview?.generatedSummary)
                XCTAssertNil(vm.providerSwitchPreview?.choices.first(where: { $0.mode == .summary })?.carrier)
                XCTAssertNil(session.pendingHandoff.payload)
            }
        }

        func testConfiguredWindowDriftAfterAdmissionRefusesAtPhysicalFence() async throws {
            let store = ClaudeCodeCompatibleBackendStore.shared
            let original = store.config(for: .glmZAI)
            defer { store.saveConfig(original) }
            var config = original
            config.modelBehavior = .claudeSlotMapping(.init(haiku: "glm-5.2", sonnet: "glm-5.2", opus: "glm-5.2[1m]"))
            for drift in [false, true] {
                store.saveConfig(config)
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .claudeCodeGLM
                    session.selectedModelRaw = "opus"
                    try installSwitch(fixture)
                    let preparation = try await switchPreparation(fixture)
                    XCTAssertEqual(preparation.catalogWindow, 1_000_000)
                    vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("window.json") }
                    let prepared = await vm.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                    XCTAssertNotNil(prepared)
                    session.installRunID(UUID())
                    session.beginRunAttempt(source: "test.switch.windowFence")
                    let sending = session.pendingHandoff
                    if drift {
                        var changed = config
                        changed.modelBehavior = .claudeSlotMapping(.init(haiku: "glm-5.2", sonnet: "glm-5.2", opus: "glm-5.2"))
                        store.saveConfig(changed)
                        XCTAssertNotEqual(vm.providerSwitchCatalogWindow(agent: session.selectedAgent, model: session.selectedModelRaw), preparation.catalogWindow)
                    }
                    XCTAssertEqual(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .headlessRun(runID: UUID())), !drift)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                    XCTAssertEqual(session.pendingHandoff.payload, sending.payload)
                    XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.outcome == "sent" })
                    if drift { XCTAssertNil(session.pendingHandoff.providerSwitchDispatch?.dispatchID) }
                }
            }
        }

        func testCompositionDriftAfterAdmissionRefusesAtPhysicalFence() async throws {
            for drift in ["unchanged", "computerUse", "taskRole"] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .codexExec
                    session.selectedModelRaw = "unknown-window"
                    try installSwitch(fixture)
                    let preparation = try await switchPreparation(fixture)
                    XCTAssertTrue(preparation.historyToolAllowed)
                    vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("physical-policy.json") }
                    let prepared = await vm.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                    XCTAssertNotNil(prepared)
                    session.installRunID(UUID())
                    session.beginRunAttempt(source: "test.switch.compositionFence")
                    if drift == "computerUse" { session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date()) }
                    if drift == "taskRole" {
                        let id = try XCTUnwrap(session.activeAgentSessionID)
                        let registration = await AgentRunSessionStore.register(sessionID: id)
                        session.mcpControlContext = .init(sessionID: id, activationID: UUID(), registration: registration, currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil, originatingConnectionID: nil, interactionTransport: .mcp(sessionID: id, originatingConnectionID: nil), suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: session.autoEditEnabled, taskLabelKind: .explore)
                        XCTAssertNotEqual(vm.providerSwitchInstructionStrings(session), preparation.instructions)
                        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: "history", taskLabelKind: session.mcpControlContext?.taskLabelKind), "This role change affects composition, not history availability")
                    }
                    XCTAssertEqual(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .codexNativeSend(UUID())), drift == "unchanged")
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                    XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.outcome == "sent" })
                    if drift != "unchanged" { XCTAssertNil(session.pendingHandoff.providerSwitchDispatch?.dispatchID) }
                }
            }
        }

        func testOwnedSwitchCarryingAttemptIsBusyUntilTerminalSettlementThenOrphan() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: session.tabID, session: session))
                let attempt = AgentComposerSubmitAttempt(id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: "")
                guard case let .claimed(claim) = vm.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false) else { return XCTFail("Expected exact composer claim") }
                defer { vm.releaseComposerSubmitClaim(claim) }
                let preparation = try await switchPreparation(fixture)
                let input = AgentChatItem.user("accepted carrying input", sequenceIndex: session.nextSequenceIndex)
                let accepted = preparation.accepting(input.id, session: session)
                session.appendItem(input)
                let entered = AgentSessionLinkStopSignal<Void>()
                let release = AgentSessionLinkStopSignal<Void>()
                defer { release.finish(()) }
                vm.test_setAgentSessionSaver { saved, _, _ in
                    if saved.pendingHandoffProviderSwitchDelivery == .sending { entered.finish(())
                        await release.value()
                    }
                    return fixture.rootURL.appendingPathComponent("owned-carrier.json")
                }
                let prepare = Task {
                    let messages = await vm.prepareProviderSwitchHandoverForSend(accepted, session: session, stopFence: .init(session: session))
                    if messages == nil { entered.finish(()) }
                    return messages
                }
                await entered.value()
                @MainActor func failure() -> AgentSessionLinkSendFailure? {
                    AgentSessionLinkDeliveryReadiness.failure(snapshot: AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(session: session, endpointMatchesGrant: true, isClosing: false))
                }
                XCTAssertEqual(failure(), .targetNotIdle, "The owned sending-save gap is ordinary busy, not uncertainty or stale history")
                XCTAssertFalse(AgentModeViewModel.providerSwitchNeedsReview(session))
                release.finish(())
                let messages = await prepare.value
                XCTAssertNotNil(messages)
                session.installRunID(UUID())
                let ownership = session.beginRunAttempt(source: "test.switch.owned")
                session.runState = .running
                vm.releaseComposerSubmitClaim(claim)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDispatch?.runOwnership, ownership)
                XCTAssertEqual(failure(), .targetNotIdle)
                XCTAssertFalse(AgentModeViewModel.providerSwitchUnconfirmed(session))
                XCTAssertFalse(AgentModeViewModel.providerSwitchNeedsReview(session))
                guard case .failure(.targetNotIdle) = await vm.providerSwitchSendAdmission(session: session, input: "later") else { return XCTFail("Owned input must use existing busy refusal") }
                session.appendItem(.user("a genuinely different later accepted input", sequenceIndex: session.nextSequenceIndex))
                XCTAssertEqual(failure(), .providerHandoverNeedsReview, "The exact owned input exception cannot exempt another accepted row")
                guard case .failure(.providerHandoverNeedsReview) = await vm.providerSwitchSendAdmission(session: session, input: "later") else { return XCTFail("Different later input must still be stale") }
                XCTAssertFalse(try vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .headlessRun(runID: XCTUnwrap(session.runID))))
                await vm.test_publishNaturalCompletion(session)
                XCTAssertNil(session.pendingHandoff.providerSwitchDispatch, "Only the existing terminal publication callback retires retained sending proof")
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                XCTAssertEqual(failure(), .providerSwitchUnconfirmed)
                XCTAssertTrue(session.items.contains { $0.id == input.id })
                guard case .failure(.providerSwitchUnconfirmed) = await vm.providerSwitchSendAdmission(session: session, input: "later") else { return XCTFail("Settled retained sending is a true orphan") }
            }
        }

        func testEarlierSwitchProofCannotAssociateOrDispatchSuccessorRun() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let preparation = try await switchPreparation(fixture)
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("old-proof.json") }
                _ = await vm.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                let originalRun = UUID()
                session.installRunID(originalRun)
                let original = session.beginRunAttempt(source: "test.switch.original")
                session.runState = .running
                let proof = try XCTUnwrap(session.pendingHandoff.providerSwitchDispatch)
                XCTAssertEqual(proof.runOwnership, original)
                XCTAssertTrue(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .headlessRun(runID: originalRun)))
                // A foreign successor is installed before the old publication arrives. No new
                // ordinary admission is asserted here: this is the stale-owner transport fence.
                session.endRunAttempt(ifCurrent: original, source: "test.switch.foreignSuccessor")
                let successorRun = UUID()
                session.installRunID(successorRun)
                let successor = session.beginRunAttempt(source: "test.switch.successor")
                XCTAssertNil(proof.associatingRun(successor))
                XCTAssertEqual(session.pendingHandoff.providerSwitchDispatch?.runOwnership, original)
                XCTAssertFalse(session.pendingHandoff.isStagedForSend)
                XCTAssertTrue(AgentModeViewModel.providerSwitchUnconfirmed(session), "An unrelated active run must not mask a true orphan")
                XCTAssertFalse(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .headlessRun(runID: successorRun)))
                XCTAssertEqual(session.pendingHandoff.payload, preparation.handoff.payload)
                XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.outcome == "sent" })
            }
        }

        func testNativeCodexSharedPhysicalBoundaryConfirmsExactlyOnceForNativeAndFallback() async throws {
            for dispatch in [AgentSessionLinkPromptDispatchID.codexNativeSend(UUID()), .codexFallback(queueID: UUID())] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .codexExec
                    session.selectedModelRaw = "unknown-window"
                    try installSwitch(fixture)
                    let preparation = try await switchPreparation(fixture)
                    var saves: [AgentProviderSwitchDelivery?] = []
                    vm.test_setAgentSessionSaver { saved, _, _ in
                        saves.append(saved.pendingHandoffProviderSwitchDelivery)
                        return fixture.rootURL.appendingPathComponent("native.json")
                    }
                    _ = await vm.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                    XCTAssertEqual(saves, [.sending])
                    session.installRunID(UUID())
                    session.beginRunAttempt(source: "test.switch.nativePhysical")
                    XCTAssertTrue(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: dispatch))
                    let context = AgentSessionLinkDispatchContext(session: session, dispatchID: dispatch)
                    vm.acceptAgentSessionLinkDispatch(session: session, context: context, claim: nil)
                    vm.acceptAgentSessionLinkDispatch(session: session, context: context, claim: nil)
                    try await AsyncTestWait.waitUntil("native physical acceptance clear save") { saves.count == 2 }
                    XCTAssertNil(session.pendingHandoff.providerSwitchDelivery)
                    XCTAssertEqual(session.items.count(where: { $0.recoveryDiagnostic?.outcome == "sent" }), 1)
                    guard case .success(nil) = await vm.providerSwitchSendAdmission(session: session, input: "next") else { return XCTFail("Positive native acceptance must not wedge the next input") }
                }
            }
        }

        func testResidentAndFirstIdleDelegationInputCarryReadySeedWithoutReviewingOwnRow() async throws {
            for resident in [true, false] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .openCode
                    session.selectedModelRaw = "unknown-window"
                    try installSwitch(fixture)
                    session.draftText = "untouched draft"
                    var starts: [String] = []
                    vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("resident.json") }
                    vm.test_providerSwitchStart = { _, user, _ in starts.append(user) }
                    let rows = session.items.count
                    if resident {
                        let target = try XCTUnwrap(try vm.mcpResidentTarget(sessionID: XCTUnwrap(session.activeAgentSessionID), requiringLoadedState: true))
                        let result = try await vm.mcpSubmitResidentTask(target, text: "resident assigned task", workflow: nil, windowIsAvailable: { true })
                        XCTAssertEqual(result, .startedRun)
                    } else {
                        let result = try await vm.submitDelegationDecision(
                            "first idle decision",
                            tabID: session.tabID,
                            expectedSessionID: XCTUnwrap(session.activeAgentSessionID),
                            stopFence: .init(session: session)
                        )
                        XCTAssertEqual(result, .submitted)
                    }
                    XCTAssertEqual(starts.count, 1)
                    XCTAssertTrue(starts[0].hasPrefix("<repoprompt_provider_handover "))
                    XCTAssertTrue(starts[0].contains(resident ? "resident assigned task" : "first idle decision"))
                    XCTAssertEqual(session.items.count, rows + 1)
                    XCTAssertNotNil(session.items.last?.dispatchedProviderText)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                    XCTAssertEqual(session.draftText, "untouched draft")
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                }
            }
        }

        func testOrdinarySendArmingChangeReachesExistingPersistenceBoundary() async throws {
            for initiallyArmed in [false, true] {
                try await withFixture { fixture in
                    enum Fault: Error { case write }
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .codexExec
                    session.pendingCodexComputerUseActivation = initiallyArmed ? .init(id: UUID(), createdAt: Date()) : nil
                    XCTAssertNil(session.pendingHandoff.providerSwitchDelivery)
                    let rows = session.items.map(\.id)
                    let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(tabID: session.tabID, sessionID: XCTUnwrap(session.activeAgentSessionID), tabName: "Target", isWindowClosing: false))
                    let observer = DomainAgentSessionLinkEndpointIdentity(windowID: 2, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(), persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1)
                    let request = AgentSessionLinkSendRequest(linkID: UUID(), linkGeneration: 1, observerEndpoint: observer, observerDisplayName: "Planning", message: "ordinary SEND", workflow: nil)
                    var saves = 0
                    var starts = 0
                    vm.test_providerSwitchStart = { _, _, _ in starts += 1 }
                    vm.test_setAgentSessionSaver { _, _, _ in
                        saves += 1
                        if saves == 1 { throw Fault.write }
                        return fixture.rootURL.appendingPathComponent("ordinary-send-rollback.json")
                    }
                    let result = await vm.agentSessionLinkPerformSend(to: candidate, request: request, liveness: {
                        .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false)
                    }, commitAuthorization: {
                        session.pendingCodexComputerUseActivation = initiallyArmed ? nil : .init(id: UUID(), createdAt: Date())
                        return .committed
                    })
                    XCTAssertEqual(result, .blocked(.persistenceFailed), "Ordinary SEND must reach its existing save boundary, not the switch-only arming refusal")
                    XCTAssertGreaterThan(saves, 0)
                    XCTAssertEqual(starts, 0)
                    XCTAssertNil(session.codexController)
                    XCTAssertEqual(session.items.map(\.id), rows)
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                }
            }
        }

        func testOrdinaryUnloadedSubmissionConsumesOnlyCapturedAttachmentsAndWorkflow() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                let loaded = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: fixture.workspace)
                var saved = try XCTUnwrap(loaded)
                saved.agentKind = AgentProviderKind.openCode.rawValue
                saved.agentModel = "unknown-window"
                _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: fixture.workspace)
                fixture.window.promptManager.apiSettingsViewModel?.isOpenCodeConnected = true
                session.selectedAgent = .openCode
                session.selectedModelRaw = "unknown-window"
                let a = fixture.rootURL.appendingPathComponent("submitted.txt")
                let b = fixture.rootURL.appendingPathComponent("later.txt")
                try "submitted file content".write(to: a, atomically: true, encoding: .utf8)
                try "later file content".write(to: b, atomically: true, encoding: .utf8)
                let imageA = AgentImageAttachment(source: .localFile(path: a.path), title: "A")
                let imageB = AgentImageAttachment(source: .localFile(path: b.path), title: "B")
                let fileA = AgentTaggedFileAttachment(relativePath: a.path, displayName: "A")
                let fileB = AgentTaggedFileAttachment(relativePath: b.path, displayName: "B")
                let workflowA = AgentWorkflowDefinition(customID: UUID(), displayName: "W1", template: "W1 $ARGUMENTS")
                let workflowB = AgentWorkflowDefinition(customID: UUID(), displayName: "W2", template: "W2 $ARGUMENTS")
                session.pendingImageAttachments = [imageA]
                session.pendingTaggedFileAttachments = [fileA]
                vm.selectWorkflow(workflowA)
                session.hasLoadedPersistedState = false
                let entered = AgentSessionLinkStopSignal<Void>()
                let release = AgentSessionLinkStopSignal<Void>()
                defer { release.finish(()) }
                addTeardownBlock { await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook(nil) }
                await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook { id in
                    guard id == sessionID else { return }
                    await entered.finish(())
                    await release.value()
                }
                var pending: Task<AgentModeViewModel.UserTurnSubmissionResult, Never>?
                var starts: [String] = []
                vm.test_providerSwitchStart = { _, user, _ in starts.append(user) }
                let immediate = vm.submitUserTurn(text: "submitted draft", tabID: session.tabID, scheduledProviderSwitchSubmission: { pending = $0 })
                XCTAssertEqual(immediate, .submitted)
                let deferred = try XCTUnwrap(pending)
                await entered.value()
                session.pendingImageAttachments.append(imageB)
                session.pendingTaggedFileAttachments.append(fileB)
                vm.selectWorkflow(workflowB)
                release.finish(())
                let result = await deferred.value
                XCTAssertEqual(result, .submitted)
                try await AsyncTestWait.waitUntil("ordinary hydrated input reaches owned start seam") { !starts.isEmpty }
                let row = try XCTUnwrap(session.items.last(where: { $0.kind == .user }))
                XCTAssertEqual(row.attachments.map(\.id), [imageA.id])
                XCTAssertEqual(row.taggedFileAttachments.map(\.id), [fileA.id])
                XCTAssertEqual(row.workflow, workflowA)
                XCTAssertEqual(session.pendingImageAttachments.map(\.id), [imageB.id])
                XCTAssertEqual(session.pendingTaggedFileAttachments.map(\.id), [fileB.id])
                XCTAssertEqual(session.selectedWorkflow, workflowB)
                XCTAssertTrue(starts[0].contains("W1 submitted draft"))
                XCTAssertFalse(starts[0].contains("W2 submitted draft"))
                await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook(nil)
            }
        }

        func testRestoredPendingSwitchRefusalIsAwaitedAndPreservesLocalOrMCPInputState() async throws {
            for ingress in ["localDeferred", "localClaimed", "controlled"] {
                let controlled = ingress == "controlled"
                for kind in ["sending", "stale", "oversize"] {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                        let loaded = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: fixture.workspace)
                        var saved = try XCTUnwrap(loaded)
                        saved.agentKind = AgentProviderKind.openCode.rawValue
                        saved.agentModel = "unknown-window"
                        saved.pendingHandoffPayload = try switchCarrier(padding: kind == "oversize" ? AgentProviderHandover.maximumBytes : 0)
                        saved.pendingHandoffCreatedAt = Date()
                        saved.pendingHandoffSourceItemID = session.items.last?.id
                        saved.pendingHandoffProviderSwitchDelivery = kind == "sending" ? .sending : .ready
                        if kind == "stale" {
                            let later = AgentChatItem.user("accepted later input", sequenceIndex: session.nextSequenceIndex)
                            saved.items.append(.init(from: later))
                            saved.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                                existingTranscript: saved.transcript ?? .empty,
                                workingItems: session.items + [later], terminalState: .completed,
                                nextSequenceIndex: later.sequenceIndex + 1
                            )
                        }
                        _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: fixture.workspace)
                        fixture.window.promptManager.apiSettingsViewModel?.isOpenCodeConnected = true
                        session.selectedAgent = .openCode
                        session.selectedModelRaw = "unknown-window"
                        session.hasLoadedPersistedState = false
                        vm.storeDraftText(for: session.tabID, "retained local draft")
                        let workflow = AgentWorkflowDefinition(customID: UUID(), displayName: "Retained workflow", template: "W $ARGUMENTS")
                        vm.selectWorkflow(workflow)
                        var starts = 0
                        vm.test_providerSwitchStart = { _, _, _ in starts += 1 }
                        let failure: AgentSessionLinkSendFailure = kind == "sending" ? .providerSwitchUnconfirmed : (kind == "stale" ? .providerHandoverNeedsReview : .providerHandoverDoesNotFit)
                        let expected = !controlled && kind == "oversize" ? "Too long to send with the handover." : failure.message
                        if controlled {
                            let registration = await AgentRunSessionStore.register(sessionID: sessionID)
                            session.mcpControlContext = .init(sessionID: sessionID, activationID: UUID(), registration: registration, currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil, originatingConnectionID: nil, interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil), suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: session.autoEditEnabled, taskLabelKind: .explore)
                            vm.test_setMCPControlledTabIDs([session.tabID])
                            do {
                                _ = try await vm.mcpDispatchInstruction(sessionID: sessionID, text: "MCP retained request", allowStartingRun: true)
                                XCTFail("The actual controlled MCP call must await and surface the restored refusal")
                            } catch { XCTAssertTrue(String(describing: error).contains(expected), "\(error)") }
                        } else if ingress == "localClaimed" {
                            let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: session.tabID, session: session))
                            let result = await vm.submitUserTurnCreatingSessionIfNeeded(text: "retained local draft", target: target)
                            XCTAssertEqual(result, .blocked(message: expected))
                        } else {
                            var pending: Task<AgentModeViewModel.UserTurnSubmissionResult, Never>?
                            XCTAssertEqual(vm.submitUserTurn(text: "retained local draft", tabID: session.tabID, scheduledProviderSwitchSubmission: { pending = $0 }), .submitted)
                            let task = try XCTUnwrap(pending)
                            let result = await task.value
                            XCTAssertEqual(result, .blocked(message: expected))
                            XCTAssertEqual(vm.draftRestorationEvent?.message, expected)
                        }
                        XCTAssertEqual(starts, 0)
                        XCTAssertFalse(session.items.contains { $0.kind == .user && ($0.text == "retained local draft" || $0.text == "MCP retained request") })
                        XCTAssertEqual(session.draftText, "retained local draft")
                        XCTAssertEqual(session.selectedWorkflow, workflow)
                        XCTAssertEqual(session.pendingHandoff.payload, saved.pendingHandoffPayload)
                        XCTAssertNil(session.activeComposerSubmitAttempt)
                    }
                }
            }
        }

        func testScheduledLocalAndControlledMCPArmingDriftRefusesBeforeAdmission() async throws {
            for controlled in [false, true] {
                for initiallyArmed in [false, true] {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        fixture.window.promptManager.apiSettingsViewModel?.isCodexConnected = true
                        XCTAssertTrue(vm.agentAvailabilityContext.codexAvailable)
                        session.selectedAgent = .codexExec
                        session.selectedModelRaw = vm.defaultModelRaw(for: .codexExec)
                        try installSwitch(fixture)
                        session.pendingCodexComputerUseActivation = initiallyArmed ? .init(id: UUID(), createdAt: Date()) : nil
                        vm.storeDraftText(for: session.tabID, "keep current draft")
                        let file = fixture.rootURL.appendingPathComponent("kept.txt")
                        try "keep attachment".write(to: file, atomically: true, encoding: .utf8)
                        session.pendingImageAttachments = [.init(source: .localFile(path: file.path), title: "kept image")]
                        session.pendingTaggedFileAttachments = [.init(relativePath: file.path, displayName: "kept.txt")]
                        let workflow = AgentWorkflowDefinition(customID: UUID(), displayName: "Kept workflow", template: "workflow $ARGUMENTS")
                        session.selectedWorkflow = workflow
                        let images = session.pendingImageAttachments
                        let files = session.pendingTaggedFileAttachments
                        let rows = session.items.map(\.id)
                        let slot = session.pendingHandoff
                        let entered = AgentSessionLinkStopSignal<Void>()
                        let release = AgentSessionLinkStopSignal<Void>()
                        defer { release.finish(())
                            vm.test_beforeProviderSwitchScheduledAdmission = nil
                        }
                        var didEnter = false
                        vm.test_beforeProviderSwitchScheduledAdmission = { _ in didEnter = true
                            entered.finish(())
                            await release.value()
                        }
                        var starts = 0
                        var saves = 0
                        vm.test_providerSwitchStart = { _, _, _ in starts += 1 }
                        vm.test_setAgentSessionSaver { _, _, _ in saves += 1
                            return fixture.rootURL.appendingPathComponent("no-write.json")
                        }
                        if controlled {
                            let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                            let registration = await AgentRunSessionStore.register(sessionID: sessionID)
                            session.mcpControlContext = AgentModeViewModel.AgentMCPControlContext(
                                sessionID: sessionID, activationID: UUID(), registration: registration,
                                currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
                                originatingConnectionID: nil,
                                interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
                                suppressUserNotifications: true, forceAutoEditEnabled: false,
                                autoEditEnabledBeforeOverride: session.autoEditEnabled, taskLabelKind: .explore
                            )
                            vm.test_setMCPControlledTabIDs([session.tabID])
                            var finished = false
                            let dispatch = Task { defer { finished = true }
                                return try await vm.mcpDispatchInstruction(sessionID: sessionID, text: "MCP instruction", allowStartingRun: true, workflow: workflow)
                            }
                            defer { dispatch.cancel() }
                            try await AsyncTestWait.waitUntil("controlled MCP reaches the scheduled task gate or refuses") { didEnter || finished }
                            guard didEnter else { return XCTFail("Controlled MCP refused before its scheduled-ingress gate") }
                            await entered.value()
                            session.pendingCodexComputerUseActivation = initiallyArmed ? nil : .init(id: UUID(), createdAt: Date())
                            release.finish(())
                            do { _ = try await dispatch.value
                                XCTFail("Controlled MCP must surface the preacceptance refusal")
                            } catch { XCTAssertTrue(String(describing: error).contains(AgentModeViewModel.staleComposerSubmitTargetMessage)) }
                        } else {
                            var task: Task<AgentModeViewModel.UserTurnSubmissionResult, Never>?
                            let scheduled = vm.submitUserTurn(text: "local instruction", tabID: session.tabID, scheduledProviderSwitchSubmission: { task = $0 })
                            XCTAssertEqual(scheduled, .submitted, "The synchronous ingress means scheduled, not accepted")
                            let submission = try XCTUnwrap(task)
                            defer { submission.cancel() }
                            await entered.value()
                            session.pendingCodexComputerUseActivation = initiallyArmed ? nil : .init(id: UUID(), createdAt: Date())
                            release.finish(())
                            let result = await submission.value
                            XCTAssertEqual(result, .blocked(message: AgentModeViewModel.staleComposerSubmitTargetMessage))
                        }
                        XCTAssertEqual(starts, 0)
                        XCTAssertEqual(saves, 0)
                        XCTAssertEqual(session.items.map(\.id), rows)
                        XCTAssertEqual(session.draftText, "keep current draft")
                        XCTAssertEqual(session.selectedWorkflow, workflow)
                        XCTAssertEqual(session.pendingImageAttachments, images)
                        XCTAssertEqual(session.pendingTaggedFileAttachments, files)
                        XCTAssertEqual(session.pendingHandoff, slot)
                        XCTAssertNil(session.activeComposerSubmitAttempt)
                    }
                }
            }
        }

        func testPreviewRefreshNeverAdoptsReboundOrReplacedChat() async throws {
            for origin in ["bindings", "queued-bindings", "queued-build"] {
                for replacement in [false, true] where origin != "bindings" || !replacement {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                        let original = try XCTUnwrap(vm.providerSwitchPreview)
                        let refreshEntered = AgentSessionLinkStopSignal<Void>()
                        let refreshRelease = AgentSessionLinkStopSignal<Void>()
                        defer { refreshRelease.finish(())
                            vm.test_beforeProviderSwitchPreviewRefresh = nil
                            vm.test_afterProviderInputAugmentation = nil
                        }
                        vm.test_beforeProviderSwitchPreviewRefresh = { _ in refreshEntered.finish(())
                            await refreshRelease.value()
                        }
                        if origin == "queued-bindings" {
                            session.appendItem(.assistant("same-chat content change", sequenceIndex: session.nextSequenceIndex))
                            vm.updateBindingsFromSession(session)
                            await refreshEntered.value()
                        } else if origin == "queued-build" {
                            let buildEntered = AgentSessionLinkStopSignal<Void>()
                            let buildRelease = AgentSessionLinkStopSignal<Void>()
                            defer { buildRelease.finish(()) }
                            vm.test_afterProviderInputAugmentation = { buildEntered.finish(())
                                await buildRelease.value()
                            }
                            let build = Task { await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID) }
                            await buildEntered.value()
                            session.appendItem(.assistant("drift during read-only preview build", sequenceIndex: session.nextSequenceIndex))
                            vm.test_afterProviderInputAugmentation = nil
                            buildRelease.finish(())
                            _ = await build.value
                            await refreshEntered.value()
                        }
                        let captured = try XCTUnwrap(vm.providerSwitchPreview)
                        let successor: AgentTabSession
                        if replacement {
                            successor = AgentTabSession(tabID: session.tabID)
                            successor.testInstallPersistentSessionBinding(sessionID: UUID())
                            vm.test_replaceSessionForDeferredHydration(tabID: session.tabID, with: successor)
                        } else {
                            successor = session
                            session.testInstallPersistentSessionBinding(sessionID: UUID())
                        }
                        successor.providerSessionID = "successor-native-context"
                        if origin == "bindings" { vm.updateBindingsFromSession(session) }
                        refreshRelease.finish(())
                        try await AsyncTestWait.waitUntil("captured refresh refuses identity loss") { vm.providerSwitchPreview?.building == false || vm.providerSwitchPreview?.id != captured.id }
                        XCTAssertEqual(vm.providerSwitchPreview?.id, captured.id)
                        XCTAssertEqual(vm.providerSwitchPreview?.binding, captured.binding)
                        if origin != "queued-build" { XCTAssertEqual(captured.id, original.id) }
                        XCTAssertNotNil(vm.providerSwitchPreviewBlocker(captured))
                        let applied = await vm.applyProviderSwitch(captured.id)
                        XCTAssertFalse(applied)
                        XCTAssertEqual(successor.providerSessionID, "successor-native-context")
                        XCTAssertNil(successor.pendingHandoff.payload)
                        XCTAssertFalse(successor.items.contains { $0.recoveryDiagnostic?.reason == "providerSwitch" })
                    }
                }
            }
        }

        func testPreviewUsesDestinationImageRenderingAndNativeUserTurnWrapping() async throws {
            for native in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    let destination: AgentProviderKind = native ? .codexExec : .openCode
                    session.selectedAgent = native ? .openCode : .codexExec
                    let arguments = String(repeating: "current draft ", count: 1000)
                    vm.storeDraftText(for: session.tabID, native ? "/computer-use " + arguments : arguments)
                    if !native {
                        session.pendingImageAttachments = [.init(source: .localFile(path: fixture.rootURL.appendingPathComponent("image.png").path), title: "destination image")]
                    }
                    await vm.openProviderSwitchPreview(agent: destination, model: "unknown-window", tabID: session.tabID)
                    let preview = try XCTUnwrap(vm.providerSwitchPreview)
                    let wrapped = vm.composeOrdinaryUserTurnText(
                        native ? CodexComputerUseWorkflow.renderProviderPrompt(userInstructions: arguments.trimmingCharacters(in: .whitespacesAndNewlines)) : arguments.trimmingCharacters(in: .whitespacesAndNewlines),
                        computerUseArmed: false, includesInterview: !native && preview.composition.includesInterview,
                        workflow: nil, includeBuiltInCleanupGuidance: preview.composition.includeCleanupGuidance
                    )
                    let expected = vm.renderProviderMessage(text: wrapped, attachments: preview.composition.images, agent: destination)
                    let actual = await vm.augmentUserMessageForProviderSend(wrapped, attachments: preview.composition.images, agent: destination, session: session, ignoresPendingHandoff: true)
                    XCTAssertEqual(actual, expected, "Explicit destination must win over the still-selected source")
                    if !native {
                        XCTAssertNotEqual(actual, vm.renderProviderMessage(text: wrapped, attachments: preview.composition.images, agent: session.selectedAgent))
                    }
                    XCTAssertEqual(try XCTUnwrap(preview.budget).inputTokens, max(2048, AgentProviderHandover.estimate("\n\n" + expected)), accuracy: 0.000001)
                    XCTAssertEqual(session.draftText, native ? "/computer-use " + arguments : arguments)
                    XCTAssertNil(session.pendingHandoff.payload)
                }
            }
        }

        func testPreviewBudgetsComposedWorkflowAndRefreshesWorkflowOnlyDrift() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                vm.storeDraftText(for: session.tabID, "tiny")
                let rawBudget = AgentProviderHandover.Budget(catalogWindow: nil, instructions: vm.providerSwitchInstructionStrings(session, destination: .openCode), composedInput: "tiny", isPreview: true)
                let historyBytes = Int((rawBudget.remainingCarrierTokens - 1000) * 4 / 1.05)
                XCTAssertGreaterThan(historyBytes, 0)
                session.appendItem(.assistant(String(repeating: "h", count: max(0, historyBytes)), sequenceIndex: session.nextSequenceIndex))
                let large = AgentWorkflowDefinition(customID: UUID(), displayName: "Large", template: String(repeating: "workflow ", count: 9000) + "$ARGUMENTS")
                session.selectedWorkflow = large
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                let full = try XCTUnwrap(preview.choices.first?.carrier)
                let budget = try XCTUnwrap(preview.budget)
                XCTAssertTrue(rawBudget.fits(full), "History is between raw-floor and composed-workflow allowances")
                XCTAssertFalse(budget.fits(full))
                XCTAssertGreaterThanOrEqual(budget.inputTokens, AgentProviderHandover.estimate(large.wrapUserText("tiny")))
                XCTAssertNotNil(preview.choices.first?.unavailable)
                XCTAssertNil(preview.selected)
                vm.cancelProviderSwitchPreview()
                let small = AgentWorkflowDefinition(customID: UUID(), displayName: "Small", template: "small $ARGUMENTS")
                session.selectedWorkflow = small
                let entered = AgentSessionLinkStopSignal<Void>()
                let release = AgentSessionLinkStopSignal<Void>()
                defer { release.finish(())
                    vm.test_afterProviderInputAugmentation = nil
                }
                vm.test_afterProviderInputAugmentation = { entered.finish(())
                    await release.value()
                }
                let build = Task { await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID) }
                await entered.value()
                let staleID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                session.selectedWorkflow = large
                session.userWorkflowSelectionMutationGeneration &+= 1
                vm.test_afterProviderInputAugmentation = nil
                release.finish(())
                _ = await build.value
                try await AsyncTestWait.waitUntil("workflow-only drift refreshes the same chat") { vm.providerSwitchPreview?.id != staleID && vm.providerSwitchPreview?.building == false }
                let refreshed = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertTrue(refreshed.updated)
                XCTAssertEqual(refreshed.composition.workflow, large)
                XCTAssertEqual(refreshed.binding, preview.binding)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(refreshed.budget).inputTokens, AgentProviderHandover.estimate(large.wrapUserText("tiny")))
                XCTAssertEqual(session.draftText, "tiny")
                XCTAssertEqual(session.selectedWorkflow, large)
                XCTAssertNil(session.pendingHandoff.payload)
            }
        }

        func testSendComputerUseArmingDriftDuringAuthorizationRefusesBeforeAnyRow() async throws {
            for initiallyArmed in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .codexExec
                    session.selectedModelRaw = "unknown-window"
                    try installSwitch(fixture)
                    session.pendingCodexComputerUseActivation = initiallyArmed ? .init(id: UUID(), createdAt: Date()) : nil
                    let endpoint = try XCTUnwrap(vm.agentSessionLinkObserverEndpoint(tabID: session.tabID))
                    let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(tabID: session.tabID, sessionID: endpoint.sessionID, tabName: "Target", isWindowClosing: false))
                    let request = AgentSessionLinkSendRequest(
                        linkID: UUID(),
                        linkGeneration: 1,
                        observerEndpoint: endpoint,
                        observerDisplayName: "Observer",
                        message: "ordinary request",
                        workflow: nil
                    )
                    let rows = session.items.map(\.id)
                    var starts = 0
                    var saves = 0
                    vm.test_providerSwitchStart = { _, _, _ in starts += 1 }
                    vm.test_setAgentSessionSaver { _, _, _ in saves += 1
                        return fixture.rootURL.appendingPathComponent("no-write.json")
                    }
                    let outcome = await vm.agentSessionLinkPerformSend(
                        to: candidate,
                        request: request,
                        liveness: { .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false) },
                        commitAuthorization: {
                            session.pendingCodexComputerUseActivation = initiallyArmed ? nil : .init(id: UUID(), createdAt: Date())
                            return .committed
                        }
                    )
                    XCTAssertEqual(outcome, .blocked(.endpointPostReadiness))
                    XCTAssertEqual(session.items.map(\.id), rows)
                    XCTAssertEqual(starts, 0)
                    XCTAssertEqual(saves, 0)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                }
            }
        }

        func testDeferredUserSaveResumesAfterSameOwnerRetirementDrift() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                vm.test_setAgentSessionSaver { saved, workspace, _ in
                    try await AgentSessionDataService.shared.saveAgentSession(saved, for: workspace)
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                let entered = AgentSessionLinkStopSignal<Void>()
                let release = AgentSessionLinkStopSignal<Void>()
                defer { release.finish(()) }
                vm.test_providerSwitchRetirement = { _ in entered.finish(())
                    await release.value()
                }
                let apply = Task { await vm.applyProviderSwitch(id) }
                await entered.value()
                vm.renameSession(tabID: session.tabID, to: "User title during retirement")
                let sourceAgent = session.selectedAgent
                let requestedGeneration = session.saveRequestGeneration
                let deferred = try XCTUnwrap(session.saveDebounceTask)
                await deferred.value // Exercise the actual scheduled save's mutation gate.
                vm.storeDraftText(for: session.tabID, "new draft invalidates the same-owner preview")
                release.finish(())
                let applied = await apply.value
                XCTAssertFalse(applied)
                XCTAssertNil(vm.providerSwitchMutation)
                XCTAssertGreaterThan(session.saveRequestGeneration, requestedGeneration, "An existing user save deferred by this mutation must be resumed, not dropped")
                await session.saveDebounceTask?.value
                let loaded = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: fixture.workspace)
                XCTAssertEqual(loaded?.name, "User title during retirement")
                XCTAssertNil(loaded?.pendingHandoffProviderSwitchDelivery)
                XCTAssertEqual(session.selectedAgent, sourceAgent)
            }
        }

        func testSwitchRetirementRechecksStopBindingAndExactOwnerWithoutOverwritingSuccessor() async throws {
            for drift in ["stop", "binding", "owner"] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.providerSessionID = "old-native"
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                    let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    let gate = AgentSessionLinkStopSignal<Void>()
                    defer { gate.finish(()) }
                    var retiring = false
                    var saves = 0
                    vm.test_providerSwitchRetirement = { _ in retiring = true
                        await gate.value()
                    }
                    vm.test_setAgentSessionSaver { _, _, _ in saves += 1
                        return fixture.rootURL.appendingPathComponent("unexpected.json")
                    }
                    let apply = Task { await vm.applyProviderSwitch(id) }
                    try await AsyncTestWait.waitUntil("outgoing retirement gate") { retiring }
                    let successor = AgentTabSession(tabID: session.tabID)
                    successor.selectedModelRaw = "successor-selection"
                    if drift == "stop" { session.stopState.invalidateScheduledStarts() }
                    else if drift == "binding" { session.testInstallPersistentSessionBinding(sessionID: UUID()) }
                    else { vm.test_replaceSessionForDeferredHydration(tabID: session.tabID, with: successor) }
                    gate.finish(())
                    let applied = await apply.value
                    XCTAssertFalse(applied)
                    XCTAssertEqual(saves, 0)
                    XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.reason == "providerSwitch" })
                    XCTAssertNil(session.pendingHandoff.payload)
                    if drift == "owner" {
                        XCTAssertTrue(vm.sessions[session.tabID] === successor)
                        XCTAssertEqual(successor.selectedModelRaw, "successor-selection")
                    }
                }
            }
        }

        func testProviderSwitchScaleThreeHundredSavedChatsThreeWindowsTenLinks() async throws {
            let clock = ContinuousClock()
            let started = clock.now
            let reads = ProviderSwitchScaleReads()
            await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook { id in await reads.record(id) }
            var fixtures: [Fixture] = []
            do {
                for _ in 0 ..< 3 {
                    try await fixtures.append(makeFixture())
                }
                // Each real window fixture owns an explicit private catalog. Reinstall those
                // captured catalogs after construction notifications settle; this is not coverage
                // of the still-open #1422 new-window canonical-selection change.
                for fixture in fixtures {
                    fixture.window.workspaceManager.workspaces = [fixture.workspace]
                    fixture.window.workspaceManager.activeWorkspace = fixture.workspace
                }
                let first = fixtures[0]
                let manager = first.window.workspaceManager
                let workspaceID = try XCTUnwrap(manager.activeWorkspaceID)
                let workspaceIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceID })
                var preparedIDs: [UUID] = []
                var preparedTabs: [UUID] = []
                for index in 0 ..< 297 {
                    let id = UUID()
                    let tab = UUID()
                    let saved = AgentSession(
                        id: id,
                        workspaceID: workspaceID,
                        composeTabID: tab,
                        name: "Saved \(index)",
                        items: [
                            AgentChatItemPersist(from: .user("saved request \(index)", sequenceIndex: 0)),
                            AgentChatItemPersist(from: .assistant("retained reply \(index)", sequenceIndex: 1))
                        ],
                        parentSessionID: index < 7 ? first.sourceSession.activeAgentSessionID : nil,
                        createdByOverseerSessionID: index < 7 ? first.sourceSession.activeAgentSessionID : nil,
                        isMCPOriginated: index < 7
                    )
                    _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: manager.workspaces[workspaceIndex])
                    manager.workspaces[workspaceIndex].composeTabs.append(.init(id: tab, name: "Saved \(index)", activeAgentSessionID: id))
                    if index < 7 { preparedIDs.append(id)
                        preparedTabs.append(tab)
                    }
                }
                for (id, tab) in zip(preparedIDs, preparedTabs) {
                    let prepared = await first.viewModel.prepareSavedOversightSession(
                        tabID: tab,
                        sessionID: id,
                        workspaceID: workspaceID,
                        isStillAuthorized: { true }
                    )
                    XCTAssertTrue(prepared)
                }
                // An agreeing recovered catalog replica does not become a second payload writer.
                fixtures[2].window.workspaceManager.workspaces.append(manager.workspaces[workspaceIndex])
                let sourceID = try XCTUnwrap(first.sourceSession.activeAgentSessionID)
                let replica = AgentSessionCarrierResolver.capture(windows: fixtures.map(\.window), sessionIDs: [sourceID], includeRuntimeOwners: true)
                XCTAssertFalse(replica.ambiguousSessionIDs.contains(sourceID))
                XCTAssertTrue(replica.uniqueRuntimeOwners[sourceID]?.session === first.sourceSession)
                let host = WindowStatesManager.shared
                let authority = DomainAgentSessionLinkAuthority(identity: .init(runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()))
                let bridge = AgentSessionLinkRuntimeBridge(authority: authority, host: host, toolAdvertisementInvalidator: { _ in })
                bridge.attach(host: host)
                defer { bridge.freezeForTermination()
                    AgentSessionLinkRuntimeBridge.shared.attach(host: host)
                }
                let nodes = fixtures.map { ($0.viewModel, $0.sourceSession) }
                    + preparedTabs.compactMap { tab in first.viewModel.sessions[tab].map { (first.viewModel, $0) } }
                XCTAssertEqual(nodes.count, 10)
                for node in nodes.prefix(2) {
                    let endpoint = try XCTUnwrap(node.0.agentSessionLinkObserverEndpoint(tabID: node.1.tabID))
                    let activation = await bridge.becomeOverseer(endpoint: endpoint, isEnabled: { true }, revalidateRoute: { true }, commitIfCurrent: { $0() })
                    XCTAssertNotNil(activation)
                }
                for target in nodes.dropFirst() {
                    let result = try await bridge.addMonitorLink(
                        observerSessionID: sourceID,
                        rawTargetSessionID: XCTUnwrap(target.1.activeAgentSessionID).uuidString
                    )
                    guard case .added = result else { XCTFail("Expected direct grant, got \(result)")
                        throw CancellationError()
                    }
                }
                let reverse = try await bridge.addMonitorLink(observerSessionID: XCTUnwrap(nodes[1].1.activeAgentSessionID), rawTargetSessionID: sourceID.uuidString)
                guard case .added = reverse else { XCTFail("Expected independent reverse grant")
                    throw CancellationError()
                }
                let grants = await authority.links(forObserver: sourceID)
                let reverseGrants = try await authority.links(forObserver: XCTUnwrap(nodes[1].1.activeAgentSessionID))
                XCTAssertEqual(grants.items.count + reverseGrants.items.count, 10)
                let endpoints = nodes.map { $0.0.agentSessionLinkObserverEndpoint(tabID: $0.1.tabID) }
                let parents = nodes.map(\.1.parentSessionID)
                let worktrees = nodes.map(\.1.worktreeBindings)
                let activations = nodes.prefix(2).map(\.1.oversight.overseerActivation)
                var providerCalls = 0
                for fixture in fixtures {
                    fixture.viewModel.test_providerSwitchStart = { _, _, _ in providerCalls += 1 }
                }
                let target = nodes[3]
                for node in [nodes[0], target] {
                    await node.0.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: node.1.tabID)
                    let id = try XCTUnwrap(node.0.providerSwitchPreview?.id)
                    let applied = await node.0.applyProviderSwitch(id)
                    XCTAssertTrue(applied)
                }
                // Simulate the durable possible-write fault, then restore through the ordinary exact
                // saved-session loader, not a preview/seed ledger or a provider probe.
                target.1.pendingHandoff.providerSwitchDelivery = .sending
                target.1.appendItem(.user("uncertain input", sequenceIndex: target.1.nextSequenceIndex))
                target.1.isDirty = true
                let persisted = await target.0.flushSaveRequired(for: target.1.tabID, workspaceID: workspaceID)
                guard case .success = persisted else { XCTFail("Uncertainty fixture must be durable")
                    throw CancellationError()
                }
                target.1.hasLoadedPersistedState = false
                let restored = await target.0.ensureSessionReady(tabID: target.1.tabID, reconnectActiveProviders: false)
                XCTAssertTrue(restored === target.1)
                guard case .failure(.providerSwitchUnconfirmed) = await target.0.providerSwitchSendAdmission(session: restored, input: "not replayed") else { XCTFail("Restore must block every new input")
                    throw CancellationError()
                }
                await target.0.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: restored.tabID)
                let orphan = restored.pendingHandoff
                target.0.cancelProviderSwitchPreview()
                XCTAssertEqual(restored.pendingHandoff, orphan)
                await target.0.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: restored.tabID)
                target.0.providerSwitchPreview?.selected = .history
                let reviewed = try await target.0.applyProviderSwitch(XCTUnwrap(target.0.providerSwitchPreview?.id))
                XCTAssertTrue(reviewed)
                XCTAssertTrue(restored.pendingHandoff.payload?.contains("uncertain input") == true)
                guard case .success(.some) = await target.0.providerSwitchSendAdmission(session: restored, input: "new ordinary input") else { XCTFail("Reviewed carrier should admit new input")
                    throw CancellationError()
                }
                await first.viewModel.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: first.sourceTabID)
                let discarded = try await first.viewModel.applyProviderSwitch(XCTUnwrap(first.viewModel.providerSwitchPreview?.id), discard: true)
                XCTAssertTrue(discarded)
                XCTAssertEqual(nodes.map { $0.0.agentSessionLinkObserverEndpoint(tabID: $0.1.tabID) }, endpoints)
                XCTAssertEqual(nodes.map(\.1.parentSessionID), parents)
                XCTAssertEqual(nodes.map(\.1.worktreeBindings), worktrees)
                XCTAssertEqual(nodes.prefix(2).map(\.1.oversight.overseerActivation), activations)
                let after = await authority.links(forObserver: sourceID)
                let afterReverse = try await authority.links(forObserver: XCTUnwrap(nodes[1].1.activeAgentSessionID))
                XCTAssertEqual(after.items.map(\.linkID), grants.items.map(\.linkID))
                XCTAssertEqual(after.items.map(\.generation), grants.items.map(\.generation))
                XCTAssertEqual(afterReverse.items.map(\.linkID), reverseGrants.items.map(\.linkID))
                let expectedReadIDs = Set(nodes.compactMap(\.1.activeAgentSessionID))
                let pointReads = await reads.snapshot()
                XCTAssertTrue(Set(pointReads).isSubset(of: expectedReadIDs), "No unrelated saved transcript may hydrate")
                XCTAssertEqual(Set(pointReads), expectedReadIDs)
                XCTAssertEqual(providerCalls, 0)
                XCTAssertTrue(nodes.allSatisfy { $0.1.agentTask == nil && $0.1.codexController == nil && $0.1.claudeController == nil && $0.1.acpController == nil })
                XCTAssertEqual(first.viewModel.sessions.values.count(where: { $0.hasLoadedPersistedState && $0.activeAgentSessionID != nil }), 8)
                let elapsed = started.duration(to: clock.now)
                print("PROVIDER_SWITCH_SCALE saved=300 windows=3 links=10 prepared=7 pointReads=\(pointReads.count) providerCalls=\(providerCalls) elapsed=\(elapsed)")
                XCTAssertLessThan(elapsed, .seconds(10))
            } catch {
                await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook(nil)
                for fixture in fixtures.reversed() {
                    await cleanup(fixture)
                }
                throw error
            }
            await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook(nil)
            for fixture in fixtures.reversed() {
                await cleanup(fixture)
            }
        }

        private func publishSwitchWake(_ fixture: Fixture, endpoint: DomainAgentSessionLinkEndpointIdentity) throws {
            let session = fixture.sourceSession
            let runID = try XCTUnwrap(session.runID)
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(.init(
                runID: runID, routeToken: .init(runID: runID, observerEndpoint: endpoint, connectionID: UUID(), routingAuthorityGeneration: 1, connectionLifecycleGeneration: 1),
                projectionRevision: 1, hasAgentSessionLink: true, hasAnyActiveLink: true
            ), to: endpoint)
            let target = DomainAgentSessionLinkEndpointIdentity(windowID: 99, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(), persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1)
            let reference = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
            fixture.viewModel.agentSessionLinkPublishPromptInventory(.init(
                observerSessionID: endpoint.sessionID, linkSetRevision: 1,
                items: [.init(targetSessionID: target.sessionID, displayName: "Lane", capabilityNames: ["poll", "read", "send_when_idle", "wait"], reference: reference)]
            ), to: endpoint)
            session.oversight.autoWakeOnUpdates = true
            fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(.init(
                observerEndpoint: endpoint, queueEpoch: UUID(), queueRevision: 1, linkSetRevision: 1,
                isEnabled: true, isDeliverable: true,
                entries: [.init(reference: reference, targetEndpoint: target, targetSessionID: target.sessionID, displayName: "Lane", fromStatus: .running, toStatus: .idle, observedAt: Date(), idleForSend: true, latestVisibleAssistantPreview: "Done.", changeSequence: 1, edgeSequence: 1)],
                unacknowledgedOverflowCount: 0, overflowProduced: 0,
                autoWakeLanes: [.init(reference: reference, targetEndpoint: target, targetSessionID: target.sessionID, isEffectivelySelected: true)]
            ), to: endpoint)
        }

        private func composerClaim(_ fixture: Fixture, text: String) throws -> AgentModeViewModel.AgentComposerSubmitClaim {
            let target = try XCTUnwrap(fixture.viewModel.makeComposerSubmitTarget(tabID: fixture.sourceTabID, session: fixture.sourceSession))
            let attempt = AgentComposerSubmitAttempt(id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: text)
            guard case let .claimed(claim) = fixture.viewModel.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false) else { throw CancellationError() }
            return claim
        }

        private func switchCarrier(padding: Int = 0) throws -> String {
            let request = AgentChatItem.user(String(repeating: "h", count: max(0, padding)), sequenceIndex: 0)
            let turn = AgentTranscriptTurn(request: .init(from: request), responseSpans: [], conclusionActivityID: nil, terminalState: .completed, startedAt: request.timestamp, completedAt: request.timestamp)
            let projection = try AgentProviderHandover.project(AgentTranscript(turns: [turn]))
            let source = try AgentProviderHandover.Source(provider: "source", model: "source-model")
            return AgentProviderHandover.render(AgentProviderHandover.history(projection, source: source, historyReference: nil))
        }

        private func installSwitch(_ fixture: Fixture, padding: Int = 0) throws {
            // Fixture-local availability only: never call a connect/login/provider API or write defaults.
            fixture.window.promptManager.apiSettingsViewModel?.isOpenCodeConnected = true
            XCTAssertTrue(fixture.viewModel.agentAvailabilityContext.openCodeAvailable)
            fixture.sourceSession.pendingHandoff = try .init(payload: switchCarrier(padding: padding), createdAt: Date(), sourceItemID: fixture.sourceSession.items.last?.id, providerSwitchDelivery: .ready)
        }

        private func switchPreparation(_ fixture: Fixture) async throws -> AgentModeViewModel.ProviderSwitchSendPreparation {
            let outcome = await fixture.viewModel.providerSwitchSendAdmission(session: fixture.sourceSession, input: "ordinary input")
            guard case let .success(preparation) = outcome else { throw CancellationError() }
            return try XCTUnwrap(preparation)
        }
    #endif

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture() async throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionLinkHandoffInheritanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        let defaultsDomain = "ProviderSwitchTests.\(UUID())"
        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Handoff inheritance \(UUID().uuidString.prefix(8))",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentSessionLinkHandoffInheritanceTests"
            )

            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let sourceTab = ComposeTabState(
                id: sourceTabID,
                name: "Source",
                activeAgentSessionID: sourceSessionID
            )
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == activeWorkspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].customStoragePath = rootURL.appendingPathComponent("sessions", isDirectory: true)
            let persistedSource = AgentSession(
                id: sourceSessionID,
                workspaceID: activeWorkspace.id,
                composeTabID: sourceTabID,
                name: "Source",
                items: [
                    AgentChatItemPersist(from: .user("Source user", sequenceIndex: 0)),
                    AgentChatItemPersist(from: .assistant("Source assistant", sequenceIndex: 1))
                ],
                autoEditEnabled: false
            )
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                persistedSource, for: window.workspaceManager.workspaces[workspaceIndex]
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [sourceTab]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = sourceTabID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let viewModel = window.agentModeViewModel
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsDomain))
            let settings = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: rootURL.appendingPathComponent("settings.json")))
            settings.setAutoEffortEnabled(false)
            settings.setUsageBalancingEnabled(false)
            viewModel.modelRouterSettingsStore = settings
            let sourceSession = await viewModel.ensureSessionReady(tabID: sourceTabID)
            XCTAssertEqual(sourceSession.activeAgentSessionID, sourceSessionID)
            XCTAssertEqual(
                window.workspaceManager.activeAgentSessionID(forTabID: sourceTabID),
                sourceSessionID
            )
            let sourceToken = try XCTUnwrap(
                sourceSession.permitsBoundOperationAndSave ? sourceSession.currentRestorationBindingToken : nil,
                "Handoff requires a restored source payload."
            )
            XCTAssertEqual(sourceSession.qualifiedRestorationReadiness, .authoritative(sourceToken, .persistedPayloadApplied))
            XCTAssertEqual(sourceSession.items.count, 2)
            viewModel.setAgentModeActive(true)

            return Fixture(
                window: window,
                rootURL: rootURL,
                defaultsDomain: defaultsDomain,
                viewModel: viewModel,
                sourceTabID: sourceTabID,
                sourceSession: sourceSession,
                workspace: window.workspaceManager.workspaces[workspaceIndex]
            )
        } catch {
            UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func cleanup(_ fixture: Fixture) async {
        UserDefaults.standard.removePersistentDomain(forName: fixture.defaultsDomain)
        fixture.window.beginClose()
        await fixture.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private actor ProviderSwitchScaleReads {
        private var ids: [UUID] = []
        func record(_ id: UUID) {
            ids.append(id)
        }

        func snapshot() -> [UUID] {
            ids
        }
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let defaultsDomain: String
        let viewModel: AgentModeViewModel
        let sourceTabID: UUID
        let sourceSession: AgentModeViewModel.TabSession
        let workspace: WorkspaceModel
    }
}
