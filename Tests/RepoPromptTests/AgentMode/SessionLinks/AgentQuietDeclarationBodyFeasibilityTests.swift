#if DEBUG
    import Foundation
    import MCP
    import RepoPromptDomainRuntime
    import XCTest
    @_spi(TestSupport) @testable import RepoPromptApp

    /// Injected W0 handler body. It is not registered, described to a model, or production-certified.
    /// Entry calls the real attempt ledger before validation or authorization can refuse/suspend.
    @MainActor
    final class AgentQuietDeclarationBodyFeasibilityTests: XCTestCase {
        @MainActor
        private final class Fixture {
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session: AgentTabSession
            let owner: AgentRunOwnership
            let wakeID = UUID()
            let origin: AgentSelfMCPCallOrigin
            var endpoint: DomainAgentSessionLinkEndpointIdentity
            let context = ToolInvocationContext.trustedLocal(toolName: "read_file", metadata: .init(connectionID: nil, clientName: nil, windowID: nil))

            init() {
                session = harness.makeSession(agent: .claudeCode)
                session.testInstallPersistentSessionBinding(sessionID: UUID())
                session.installRunID(UUID())
                session.runState = .running
                owner = session.beginRunAttempt(source: "W0-injected-declaration-body")
                endpoint = .init(
                    windowID: 1,
                    workspaceID: UUID(),
                    tabID: owner.binding.tabID,
                    sessionID: owner.binding.persistentSessionID!,
                    persistentBindingGeneration: owner.binding.persistentBindingGeneration,
                    bindingTransitionGeneration: owner.binding.bindingTransitionGeneration
                )
                origin = .init(endpoint: endpoint, runID: session.runID!, runAttemptID: owner.attemptID)
                session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID)
            }

            func body(
                valid: Bool = true,
                capturedOrigin: AgentSelfMCPCallOrigin? = nil,
                authorize: () async -> Void = {}
            ) async -> Value? {
                guard session.quietLedger.enterDeclarationBody(owner: owner, hostInvocationID: context.invocationID) else { return nil }
                // Refusal happens after body-entry accounting, never at wrapper registration.
                guard valid else { session.quietLedger.noteOccurrence(owner: owner)
                    return nil
                }
                let captured = capturedOrigin ?? origin
                await authorize()
                guard session.quietLedger.acceptDeclarationBody(
                    owner: owner,
                    hostInvocationID: context.invocationID,
                    wakeID: wakeID,
                    origin: captured,
                    currentEndpoint: endpoint,
                    currentRunID: session.runID
                ) else { return nil }
                return .object(["result": .string("done")])
            }

            var eligible: Bool {
                session.quietLedger.declarationMaySeal(owner: owner, canonicalInvocations: [context.invocationID])
            }
        }

        func testBodyEntryPrecedesRefusalAndSaturatesIndependentlyOfCanonicalIdentity() async {
            let refused = Fixture()
            let refusal = await refused.body(valid: false)
            XCTAssertNil(refusal)
            XCTAssertEqual(refused.session.quietLedger.declarationBodyEntryCardinality(owner: refused.owner), 1)
            XCTAssertFalse(refused.eligible)
            let repeated = Fixture()
            let first = await repeated.body()
            XCTAssertEqual(first, .object(["result": .string("done")]))
            XCTAssertTrue(repeated.eligible)
            for _ in 0 ..< 3 {
                _ = await repeated.body()
            }
            XCTAssertEqual(repeated.session.quietLedger.declarationBodyEntryCardinality(owner: repeated.owner), 2)
            XCTAssertFalse(repeated.eligible, "One deduplicated canonical UUID cannot hide repeated body execution")
        }

        func testTransportCacheWithoutBodyReentryNeedsNoExceptionAndTextPolicyIsDirectional() async {
            let fixture = Fixture()
            var cached: Value?
            @MainActor
            func transport() async -> Value? {
                if let cached { return cached }
                cached = await fixture.body()
                return cached
            }
            let first = await transport()
            let replay = await transport()
            XCTAssertEqual(first, replay)
            XCTAssertEqual(fixture.session.quietLedger.declarationBodyEntryCardinality(owner: fixture.owner), 1)
            fixture.session.quietLedger.noteDeclarationAssistantText(owner: fixture.owner, text: "Done.")
            XCTAssertTrue(fixture.eligible, "Approved trailing text-only close does not add a tool/body")
            let leading = Fixture()
            leading.session.quietLedger.noteDeclarationAssistantText(owner: leading.owner, text: "I will close.")
            _ = await leading.body()
            XCTAssertFalse(leading.eligible, "Text before the declaration remains irreversible ordinary")
        }

        func testSiblingArrivingDuringAuthorizationSuspensionCannotBeErasedByAcceptance() async throws {
            let fixture = Fixture()
            let gate = TestReleaseFence(name: "W0 declaration authorization")
            let task = Task { await fixture.body(authorize: { await gate.enterAndWait() }) }
            guard await gate.waitUntilEntered() else { gate.release()
                _ = await task.value
                return
            }
            try await fixture.harness.host.test_handleStreamResult(
                .init(type: "tool_call", text: nil, toolName: "file_search", toolInvocationID: UUID()),
                session: fixture.session,
                runID: XCTUnwrap(fixture.session.runID),
                runAttemptID: fixture.owner.attemptID
            )
            gate.release()
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertFalse(fixture.eligible)
            XCTAssertNil(fixture.session.quietLedger.candidateStartKey(owner: fixture.owner))
        }

        func testCapturedEndpointRunAttemptAndWakeAreExactAndCancellationOrSuccessorCannotBorrowAcceptance() async {
            for variant in 0 ..< 5 {
                let fixture = Fixture()
                var endpoint = fixture.endpoint
                if variant == 0 {
                    endpoint = .init(
                        windowID: endpoint.windowID,
                        workspaceID: UUID(),
                        tabID: endpoint.tabID,
                        sessionID: endpoint.sessionID,
                        persistentBindingGeneration: endpoint.persistentBindingGeneration,
                        bindingTransitionGeneration: endpoint.bindingTransitionGeneration
                    )
                }
                let origin = AgentSelfMCPCallOrigin(
                    endpoint: endpoint,
                    runID: variant == 1 ? UUID() : fixture.origin.runID,
                    runAttemptID: variant == 2 ? UUID() : fixture.owner.attemptID
                )
                let gate = TestReleaseFence(name: "W0 stale declaration origin")
                let task = Task { await fixture.body(capturedOrigin: origin, authorize: { await gate.enterAndWait() }) }
                guard await gate.waitUntilEntered() else { gate.release()
                    _ = await task.value
                    continue
                }
                if variant == 3 { fixture.session.sealQuietCheckIn(owner: fixture.owner, terminalState: .cancelled, normal: false, hasSuccessor: false) }
                if variant == 4 {
                    _ = fixture.session.endRunAttempt(ifCurrent: fixture.owner, source: "W0 successor")
                    let successor = fixture.session.beginRunAttempt(source: "W0 successor")
                    fixture.session.quietLedger.markRoutineWake(owner: successor, wakeID: UUID())
                }
                let facts = fixture.session.quietLedger.facts
                gate.release()
                let result = await task.value
                XCTAssertNil(result, "variant \(variant)")
                XCTAssertFalse(fixture.eligible)
                if variant >= 3 { XCTAssertEqual(fixture.session.quietLedger.facts, facts, "Late acceptance cannot mutate sealed/cancelled settlement or successor") }
            }
            let fixture = Fixture()
            XCTAssertTrue(fixture.session.quietLedger.enterDeclarationBody(owner: fixture.owner, hostInvocationID: fixture.context.invocationID))
            XCTAssertFalse(fixture.session.quietLedger.acceptDeclarationBody(
                owner: fixture.owner,
                hostInvocationID: fixture.context.invocationID,
                wakeID: UUID(),
                origin: fixture.origin,
                currentEndpoint: fixture.endpoint,
                currentRunID: fixture.session.runID
            ))
        }
    }
#endif
