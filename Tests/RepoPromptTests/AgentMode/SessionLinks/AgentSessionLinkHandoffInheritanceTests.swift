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
                    let messages = await fixture.viewModel.prepareProviderSwitchHandoverForSend(preparation.accepting(accepted.id), session: session, stopFence: fence)
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
                    let dispatch = AgentSessionLinkPromptDispatchID.headlessRun(runID: UUID())
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
                let dispatch = AgentSessionLinkPromptDispatchID.headlessRun(runID: UUID())
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
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "ProviderSwitchTests.\(UUID())"))
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
                viewModel: viewModel,
                sourceTabID: sourceTabID,
                sourceSession: sourceSession
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func cleanup(_ fixture: Fixture) async {
        fixture.window.beginClose()
        await fixture.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let viewModel: AgentModeViewModel
        let sourceTabID: UUID
        let sourceSession: AgentModeViewModel.TabSession
    }
}
