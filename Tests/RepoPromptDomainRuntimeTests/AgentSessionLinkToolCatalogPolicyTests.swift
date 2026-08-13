import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// Canonical catalog + policy contract for `agent_session_link`.
///
/// The tool must exist in every window catalog (so the catalog stays complete and no ungated window
/// can appear), while being invisible and uncallable unless the caller currently holds a monitor
/// grant. Advertisement is never authority, so both the list filter and the call gate are asserted.
final class AgentSessionLinkToolCatalogPolicyTests: XCTestCase {
    private let toolName = MCPWindowToolName.agentSessionLink

    // MARK: - Canonical catalog

    func testCanonicalEntryDeclaresItsOwnCapabilityAndControlAdmission() throws {
        let entry = try XCTUnwrap(MCPDomainToolCatalog.entry(named: toolName))
        XCTAssertEqual(entry.scope, .window)
        XCTAssertEqual(entry.admissionClass, .control)
        // A dedicated capability, not a reuse of agentExternalControl: an oversight grant must never
        // widen `agent_run` / `agent_manage`, and their orchestrator override must not widen this.
        XCTAssertEqual(entry.capability, .agentSessionLinkControl)
        XCTAssertNotEqual(entry.capability, .agentExternalControl)
    }

    func testCanonicalDefinitionExistsInCatalogOrderWithTheAdvertisedOperations() throws {
        let names = MCPDomainCanonicalToolDefinitions.definitions.map(\.name)
        XCTAssertEqual(names, MCPDomainToolCatalog.orderedToolNames)
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
        let schema = try XCTUnwrap(definition.inputSchema.objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        let op = try XCTUnwrap(properties["op"]?.objectValue)
        XCTAssertEqual(
            op["enum"]?.arrayValue?.compactMap(\.stringValue),
            ["list", "poll", "wait", "read", "send", "mark_done"]
        )
        XCTAssertEqual(schema["required"]?.arrayValue?.compactMap(\.stringValue), ["op"])
        // `send` is the only target-mutating operation, so its two required inputs must be
        // advertised. `mark_done` reuses only session_id for observer-local dashboard triage. A schema
        // that omits `idempotency_key` would invite exactly-once violations from callers that never
        // learn the key exists.
        XCTAssertNotNil(properties["message"])
        XCTAssertNotNil(properties["idempotency_key"])
        XCTAssertTrue(definition.description.contains("mark_done"))
        XCTAssertTrue(definition.description.contains("observer’s dashboard"))
    }

    /// The description is the only place a model learns the send contract before calling it.
    ///
    /// Send-readiness is part of that contract, not a detail: `status: "idle"` is satisfied by targets
    /// `send` still refuses, so a description that stops at "idle" teaches the
    /// `send` -> `target_not_idle` -> `wait until idle` -> `send` loop.
    func testDescriptionStatesTheSendReadyIdempotentSendContract() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
        XCTAssertTrue(definition.description.contains("only while the target is idle **and** ready to accept work"))
        XCTAssertTrue(definition.description.contains("idle_for_send"))
        XCTAssertTrue(definition.description.contains("until: \"sendable\""))
        XCTAssertTrue(definition.description.contains("idempotency_conflict"))
        XCTAssertTrue(definition.description.contains("target_not_idle"))
        XCTAssertTrue(
            definition.description.contains("cross_session_reply_requires_user_instruction")
        )
    }

    /// Regression: the description promised oversight "never exposes … file paths, or worktree
    /// details". Only *structural* fields are stripped; ordinary transcript prose is redacted for
    /// secrets and home-directory rewriting and nothing else, so a path an agent typed into its own
    /// message survives. A caller that believes the blanket claim mis-reports what it read.
    func testDescriptionDoesNotOverclaimTranscriptPrivacy() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
        XCTAssertFalse(definition.description.contains("never exposes interaction IDs"))
        XCTAssertTrue(definition.description.contains("interaction IDs, prompt and option payloads"))
        XCTAssertTrue(definition.description.contains("can still appear in what you read"))
    }

    func testDescriptionLabelsMonitoredContentUntrustedAndDeniesImplicitDiscovery() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
        XCTAssertTrue(definition.description.contains("untrusted data"))
        XCTAssertTrue(definition.description.contains("Only sessions returned by `list` can be named."))
        XCTAssertTrue(definition.description.contains("knowing a session ID grants nothing"))
    }

    // MARK: - Policy classification

    func testToolIsAdditionalGrantGatedAndGrantedByNoStaticProfile() {
        XCTAssertTrue(MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName))
        for profile in MCPClientToolPolicyProfile.allCases {
            let classification = MCPClientToolPolicyCatalog.classification(for: profile)
            XCTAssertFalse(
                classification.grantedCapabilities.contains(.agentSessionLinkControl),
                "\(profile.rawValue) must not statically grant oversight; the grant is live link state"
            )
            XCTAssertFalse(
                MCPClientToolPolicyCatalog.resolvedToolNames(for: profile).contains(toolName),
                "\(profile.rawValue) must not resolve the tool without an active link"
            )
        }
    }

    func testExploreRoleHidesTheToolAndDirectOrEngineerDoNot() {
        XCTAssertFalse(MCPClientToolPolicyCatalog.shouldAdvertise(
            toolName: toolName,
            role: .explore,
            allowsAgentExternalControlTools: false
        ))
        XCTAssertTrue(MCPClientToolPolicyCatalog.shouldAdvertise(
            toolName: toolName,
            role: .direct,
            allowsAgentExternalControlTools: false
        ))
        XCTAssertTrue(MCPClientToolPolicyCatalog.shouldAdvertise(
            toolName: toolName,
            role: .engineer,
            allowsAgentExternalControlTools: false
        ))
    }

    func testRoleHidingIsMirroredAtExecutionSoByNameCallsFailClosed() {
        XCTAssertTrue(
            MCPDomainHost.executionRoleGatedCapabilities.contains(.agentSessionLinkControl),
            "A hidden tool stays callable by name unless execution mirrors the role filter"
        )
    }

    func testDiscoveryProfileRestrictsTheToolOutright() {
        XCTAssertTrue(MCPClientToolPolicyCatalog.discoveryRestrictedCapabilities.contains(.agentSessionLinkControl))
        let restricted = MCPClientToolPolicyCatalog
            .classification(for: .discovery)
            .restrictedCapabilities
        XCTAssertTrue(restricted.contains(.agentSessionLinkControl))
    }

    // MARK: - Host advertisement and call gate

    func testHostHidesTheToolWithoutAGrantAndAdvertisesItWithOne() async throws {
        let runtime = try await makeRuntime()
        _ = try await runtime.toolRegistry.register(
            registrationID: MCPDomainToolRegistrationID(),
            scope: .window(id: 1),
            bindings: [try binding(toolName: toolName)]
        )

        let ungranted = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [],
            additionalToolNames: [],
            role: .direct,
            allowsAgentExternalControlTools: false
        )
        let hidden = await runtime.domainHost.advertisedCatalog(
            MCPDomainCatalogAdvertisementRequest(
                isGloballyEnabled: true,
                disabledToolNames: [],
                policy: ungranted
            )
        )
        XCTAssertTrue(hidden.definitions.isEmpty)
        XCTAssertEqual(hidden.hiddenReasonsByToolName[toolName], .missingAdditionalToolGrant)

        let granted = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [],
            additionalToolNames: [toolName],
            role: .direct,
            allowsAgentExternalControlTools: false
        )
        let visible = await runtime.domainHost.advertisedCatalog(
            MCPDomainCatalogAdvertisementRequest(
                isGloballyEnabled: true,
                disabledToolNames: [],
                policy: granted
            )
        )
        XCTAssertEqual(visible.definitions.map(\.name), [toolName])
    }

    func testUngrantedCallerIsDeniedAtCallTimeAndGrantedCallerReachesAdmission() async throws {
        let runtime = try await makeRuntime()
        let ungranted = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [],
            additionalToolNames: [],
            role: .direct,
            allowsAgentExternalControlTools: false
        )
        do {
            try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: toolName, policy: ungranted)
            XCTFail("An ungranted caller must not pass the early call gate by naming the tool")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .missingAdditionalGrant(toolName: toolName))
        }

        let granted = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [],
            additionalToolNames: [toolName],
            role: .direct,
            allowsAgentExternalControlTools: false
        )
        try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: toolName, policy: granted)
        let decision = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(
            toolName: toolName,
            policy: granted
        )
        XCTAssertEqual(decision.admissionClass, .control)
    }

    func testExploreCallerIsDeniedEvenWithAGrant() async throws {
        let runtime = try await makeRuntime()
        let grantedExplore = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [],
            additionalToolNames: [toolName],
            role: .explore,
            allowsAgentExternalControlTools: false
        )
        // The early gate only checks the grant, so the role denial must land at pre-admission.
        try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: toolName, policy: grantedExplore)
        do {
            _ = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(
                toolName: toolName,
                policy: grantedExplore
            )
            XCTFail("Explore-role callers must never reach oversight execution")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .roleUnavailable(toolName: toolName))
        }
    }

    func testOrchestratorExternalControlOverrideDoesNotWidenMonitoring() async throws {
        let runtime = try await makeRuntime()
        // `allowsAgentExternalControlTools` is the orchestrator override for agent_run/agent_manage.
        // It must not smuggle an oversight grant in with it.
        let orchestrator = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [],
            additionalToolNames: [],
            role: .engineer,
            allowsAgentExternalControlTools: true
        )
        do {
            try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: toolName, policy: orchestrator)
            XCTFail("Orchestrator external-control authority must not grant oversight")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .missingAdditionalGrant(toolName: toolName))
        }
    }

    // MARK: - Fixtures

    private func makeRuntime() async throws -> MCPDomainRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-link-policy-\(UUID().uuidString)", isDirectory: true)
        let runtime = MCPDomainRuntime(
            configuration: .init(
                mode: .standalone,
                profileIdentifier: "agent-session-link-policy-test",
                storageDirectory: directory,
                eventDirectory: directory,
                temporaryDirectory: directory,
                externalReloadInterval: nil
            )
        )
        try await runtime.start()
        return runtime
    }

    private func binding(toolName: String) throws -> MCPDomainToolBinding {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
        return MCPDomainToolBinding(definition: definition, operation: { _ in .null })
    }
}
