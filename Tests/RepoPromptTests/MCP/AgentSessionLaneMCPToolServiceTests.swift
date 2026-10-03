import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

final class AgentSessionLaneMCPToolServiceTests: XCTestCase {
    func testCreationReceiptIsFlatAndAllocationRefusalHasNoSessionID() {
        let sessionID = UUID()
        let receipt = AgentSessionLaneCreateReceipt(
            result: .created,
            sessionID: sessionID,
            sessionName: "Review",
            linked: true,
            reason: nil,
            firstTask: .queued,
            laneCount: 3,
            duplicate: true
        )
        let payload = AgentSessionLaneMCPToolService.render(receipt).objectValue
        XCTAssertEqual(payload?["result"]?.stringValue, "created")
        XCTAssertEqual(payload?["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertEqual(payload?["first_task"]?.stringValue, "queued")
        XCTAssertEqual(payload?["lanes"]?.stringValue, "3/8")
        XCTAssertEqual(payload?["duplicate"], .bool(true))
        XCTAssertNil(payload?["link_reason"])

        let refused = AgentSessionLaneMCPToolService.render(
            AgentSessionLaneCreateReceipt.refused(.laneLimitReached, laneCount: 8)
        ).objectValue
        XCTAssertEqual(refused?["result"]?.stringValue, "lane_limit_reached")
        XCTAssertEqual(refused?["lanes"]?.stringValue, "8/8")
        XCTAssertNil(refused?["session_id"])
    }

    func testRetirementReceiptsRemainNonDestructiveAndExplainPartialOutcome() {
        let sessionID = UUID()
        let partial = AgentSessionLaneMCPToolService.render(
            .unlinkedNotStashed(sessionID: sessionID)
        ).objectValue
        XCTAssertEqual(partial?["result"]?.stringValue, "unlinked_not_stashed")
        XCTAssertEqual(partial?["session_id"]?.stringValue, sessionID.uuidString)
        let denied = AgentSessionLaneMCPToolService.render(
            .notRetired(sessionID: sessionID, reason: .laneInUse)
        ).objectValue
        XCTAssertEqual(denied?["reason"]?.stringValue, "lane_in_use")
    }

    func testPromptInventoryCarriesCreatedByYouWithoutChangingGrantCapabilities() {
        let observerID = UUID()
        let targetID = UUID()
        let inventory = DomainAgentSessionLinkInventory(
            sessionID: observerID,
            linkSetRevision: 1,
            authorityRevision: 1,
            items: [DomainAgentSessionLinkInventoryItem(
                linkID: UUID(),
                generation: 1,
                observerSessionID: observerID,
                targetSessionID: targetID,
                displayName: "Lane",
                capabilities: DomainAgentSessionLinkCapability.version1,
                createdAt: Date(timeIntervalSince1970: 0)
            )]
        )
        let annotated = AgentSessionLinkPromptInventory(inventory) { $0 == targetID }
        XCTAssertEqual(annotated.items.first?.createdByYou, true)
        XCTAssertEqual(annotated.items.first?.capabilityNames, inventory.items.first?.capabilityNames)
        XCTAssertEqual(AgentSessionLinkPromptInventory(inventory).items.first?.createdByYou, false)
    }
}

#if DEBUG
    final class RetirementDiagnosticRecordCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [AgentSessionLinkCatalogDiagnostics.RetirementRecord] = []

        func append(_ record: AgentSessionLinkCatalogDiagnostics.RetirementRecord) {
            lock.withLock { storage.append(record) }
        }

        var records: [AgentSessionLinkCatalogDiagnostics.RetirementRecord] {
            lock.withLock { storage }
        }
    }

    @MainActor
    final class AgentSessionLaneRetirementDiagnosticsTests: XCTestCase {
        func testRetirementReplyWriteJoinsOpaqueOperationWithoutLoggingWireContent() async throws {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            defer { Darwin.close(descriptors[1]) }
            let connectionID = UUID()
            let transport = try UnixSocketMCPTransport(
                connectedFD: descriptors[0], connectionID: connectionID, connectionGeneration: 1
            )
            do {
                try await transport.connect()
                let registry = MCPExportResponseDeliveryDeadlineRegistry.shared
                let request = Data("""
                {"jsonrpc":"2.0","id":"private-request","method":"tools/call","params":{"name":"agent_session_link","arguments":{"op":"retire_lane","session_id":"private-target"}}}
                """.utf8)
                registry.recordAcceptedClientFrame(request, connectionID: connectionID.uuidString, connectionGeneration: 1)
                let token = try XCTUnwrap(registry.claimToolRequest(
                    connectionID: connectionID.uuidString, connectionGeneration: 1, requestID: .string("private-request")
                ))
                let operationID = try XCTUnwrap(registry.retirementOperation(for: token))
                XCTAssertNil(registry.deadlineForTesting(
                    connectionID: connectionID.uuidString, connectionGeneration: 1, requestID: .string("private-request")
                ), "instrumentation must not create a retirement timeout")
                let capture = RetirementDiagnosticRecordCapture()
                let response = Data("""
                {"jsonrpc":"2.0","id":"private-request","result":{"content":[{"type":"text","text":"private-payload"}]}}
                """.utf8)
                try await AgentSessionLinkCatalogDiagnostics.$retirementTestSink.withValue({ capture.append($0) }) {
                    try await transport.send(response)
                }
                await transport.disconnect()
                XCTAssertEqual(capture.records, [
                    .init(operationID: operationID, stage: .replyWrite, transition: .started),
                    .init(operationID: operationID, stage: .replyWrite, transition: .returned)
                ])
                XCTAssertNil(registry.retirementOperation(for: token), "delivered response must release correlation state")
                let lines = capture.records.map(\.renderedLine).joined(separator: "\n")
                for secret in ["private-request", "private-target", "private-payload", connectionID.uuidString] {
                    XCTAssertFalse(lines.contains(secret))
                }
            } catch {
                await transport.disconnect()
                throw error
            }
        }

        func testRetirementCorrelationIsRequestAndGenerationScopedAndRemovedOnDisconnect() throws {
            let registry = MCPExportResponseDeliveryDeadlineRegistry.shared
            let connectionID = UUID().uuidString
            defer {
                registry.removeConnection(connectionID: connectionID, connectionGeneration: 1)
                registry.removeConnection(connectionID: connectionID, connectionGeneration: 2)
            }
            for generation in [UInt64(1), UInt64(2)] {
                let request = Data("""
                [{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"agent_session_link","arguments":{"op":" ReTiRe_LaNe "}}},
                 {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agent_session_link","arguments":{"op":"poll"}}}]
                """.utf8)
                registry.recordAcceptedClientFrame(request, connectionID: connectionID, connectionGeneration: generation)
            }
            let first = try XCTUnwrap(registry.claimToolRequest(
                connectionID: connectionID, connectionGeneration: 1, requestID: .number(1)
            ))
            let second = try XCTUnwrap(registry.claimToolRequest(
                connectionID: connectionID, connectionGeneration: 2, requestID: .number(1)
            ))
            let firstID = try XCTUnwrap(registry.retirementOperation(for: first))
            let secondID = try XCTUnwrap(registry.retirementOperation(for: second))
            XCTAssertNotEqual(firstID, secondID)
            XCTAssertNil(registry.claimToolRequest(
                connectionID: connectionID, connectionGeneration: 1, requestID: .number(2)
            ), "unrelated operations must not acquire retirement identity")
            let response = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8)
            XCTAssertEqual(registry.retirementOperations(
                forServerFrame: response, connectionID: connectionID, connectionGeneration: 2
            ), [secondID])
            registry.completeServerFrame(response, connectionID: connectionID, connectionGeneration: 2)
            XCTAssertNil(registry.retirementOperation(for: second))
            XCTAssertEqual(registry.retirementOperation(for: first), firstID)
            registry.removeConnection(connectionID: connectionID, connectionGeneration: 1)
            XCTAssertNil(registry.retirementOperation(for: first))
        }
    }
#endif
