import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class AgentSelfToolCatalogPolicyTests: XCTestCase {
    func testSelfNoopTrialHasNoArgumentsOrAdditionalAgentFacingText() async throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.selfNoop))
        XCTAssertEqual(definition.description, "Quietly close a routine wake that needs nothing.")
        XCTAssertEqual(definition.inputSchema, .object([
            "type": .string("object"), "additionalProperties": .bool(false), "properties": .object([:])
        ]))
        XCTAssertEqual(definition.annotations, .init())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone, profileIdentifier: "self-noop-trial-test",
            storageDirectory: directory, eventDirectory: directory, temporaryDirectory: directory,
            externalReloadInterval: nil
        ))
        try await runtime.start()
        _ = try await runtime.toolRegistry.register(
            registrationID: MCPDomainToolRegistrationID(), scope: .window(id: 1),
            bindings: [AgentSelfNoopTool.binding]
        )
        let name = MCPWindowToolName.selfNoop
        let policy = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [name], additionalToolNames: [name], role: .explore,
            allowsAgentExternalControlTools: false, hasExactAgentSessionLinkGrant: true
        )
        let catalog = await runtime.domainHost.advertisedCatalog(.init(
            isGloballyEnabled: true, disabledToolNames: [], policy: policy
        ))
        XCTAssertEqual(catalog.definitions, [definition])
        try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: name, policy: policy)
        let admission = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(toolName: name, policy: policy)
        XCTAssertEqual(admission.admissionClass, .control)
        for profile in MCPClientToolPolicyProfile.allCases {
            XCTAssertFalse(MCPClientToolPolicyCatalog.resolvedToolNames(for: profile).contains(MCPWindowToolName.selfNoop))
        }
    }

    func testSelfNoopTrialAlwaysReturnsDoneWithoutCallingAnOwner() async throws {
        let expected = Value.object(["result": .string("done")])
        // The production binding has no dependencies, captured session, or mutable state.
        // Repetition and extraneous input cannot schedule work or alter the response.
        for args: [String: Value] in [[:], [:], ["op": .string("compact"), "session_id": .string(UUID().uuidString)]] {
            let result = try await AgentSelfNoopTool.binding(args)
            XCTAssertEqual(result, expected)
        }
    }

    func testCanonicalSelfToolHasOnlyTwoOperationsAndNoTargetSelectors() throws {
        let name = "self_compact"
        XCTAssertEqual(MCPDomainCanonicalToolDefinitions.definitions.filter { $0.name == name }.count, 1)
        XCTAssertNil(MCPDomainToolCatalog.entry(named: "agent_self"))
        let entry = try XCTUnwrap(MCPDomainToolCatalog.entry(named: name))
        XCTAssertEqual(entry.scope, .window)
        XCTAssertEqual(entry.capability, .agentSelfControl)
        XCTAssertEqual(entry.admissionClass, .control)
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: name))
        let schema = try XCTUnwrap(definition.inputSchema.objectValue)
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(schema["required"], .array([.string("op")]))
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        XCTAssertEqual(properties["op"]?.objectValue?["enum"], .array([.string("context"), .string("compact")]))
        XCTAssertEqual(Set(properties.keys), ["op", "note", "idempotency_key"])
        for operation in ["context", "compact"] {
            XCTAssertEqual(MCPDomainToolCatalog.operationIdentity(for: name, input: .value(operation)).normalizedOperation, operation)
        }
        XCTAssertEqual(MCPDomainToolCatalog.operationIdentity(for: name, input: .value("poll")).normalizedOperation, MCPDomainToolOperationIdentity.unknownOperation)
    }

    func testCanonicalSelfDefinitionFitsOneThousandCharactersWithEssentialContract() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "self_compact"))
        let serialized = try String(decoding: JSONEncoder().encode(definition), as: UTF8.self)
        XCTAssertLessThanOrEqual(serialized.count, 1000, "Complete minified definition, not description alone")
        let noteDescription = definition.inputSchema.objectValue?["properties"]?.objectValue?["note"]?.objectValue?["description"]?.stringValue
        XCTAssertEqual(noteDescription, "[compact] Required verbatim note: 10% of window tokens × 4 UTF-8 bytes; 65,536 if unknown.")
        let description = definition.description
        for required in [
            "Agent Mode session", "no target selector", "`context`", "load", "status",
            "`compact`", "nonempty `note`", "~10% of context window in UTF-8 bytes; 65,536 if unknown", "`idempotency_key`",
            "200 UTF-8 bytes", "same note", "New `scheduled`", "finish this turn normally",
            "no new authority"
        ] {
            XCTAssertTrue(description.contains(required), required)
        }
    }

    func testSelfToolGrantedToAllAgentProfilesIncludingExploreButNotDirectOrDiscovery() {
        let name = "self_compact"
        for profile in MCPClientToolPolicyProfile.allCases {
            let visible = MCPClientToolPolicyCatalog.resolvedToolNames(for: profile)
            XCTAssertEqual(visible.contains(name), profile != .direct && profile != .discovery, profile.rawValue)
        }
        XCTAssertFalse(MCPClientToolPolicyCatalog.hiddenToolNames(for: .explore).contains(name))
        XCTAssertFalse(MCPDomainHost.executionRoleGatedCapabilities.contains(.agentSelfControl))
    }

    func testRevokedCapabilityDeniedAtCallTimeEvenWithExactLinkGrant() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone, profileIdentifier: "agent-self-policy-test",
            storageDirectory: directory, eventDirectory: directory, temporaryDirectory: directory,
            externalReloadInterval: nil
        ))
        try await runtime.start()
        let name = "self_compact"
        let revoked = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [], additionalToolNames: [], role: .engineer,
            allowsAgentExternalControlTools: true, hasExactAgentSessionLinkGrant: true
        )
        do {
            try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: name, policy: revoked)
            XCTFail("revoked self_compact grant must deny a named call")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .missingAdditionalGrant(toolName: name))
        }
    }
}
