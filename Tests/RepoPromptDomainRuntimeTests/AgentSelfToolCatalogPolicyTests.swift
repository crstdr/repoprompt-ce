import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class AgentSelfToolCatalogPolicyTests: XCTestCase {
    func testCanonicalSelfToolHasOnlyTwoOperationsAndNoTargetSelectors() throws {
        let name = "agent_self"
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

    func testSelfToolGrantedToAllAgentProfilesIncludingExploreButNotDirectOrDiscovery() {
        let name = "agent_self"
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
        let name = "agent_self"
        let revoked = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [], additionalToolNames: [], role: .engineer,
            allowsAgentExternalControlTools: true, hasExactAgentSessionLinkGrant: true
        )
        do {
            try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: name, policy: revoked)
            XCTFail("revoked agent_self grant must deny a named call")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .missingAdditionalGrant(toolName: name))
        }
    }
}
