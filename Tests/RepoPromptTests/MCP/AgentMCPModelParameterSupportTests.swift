import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AgentMCPModelParameterSupportTests: XCTestCase {
    func testCursorDefinitionsPreserveExactWireIdentifiersAndChoices() {
        let definitions = AgentMCPModelParameterSupport.definitions(agent: .cursor, modelRaw: "grok-4.6")

        XCTAssertEqual(definitions.count, 2)
        XCTAssertEqual(definitions[0].configID, "effort")
        XCTAssertEqual(definitions[0].choices.map(\.rawValue), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(definitions[1].configID, "fast")
        XCTAssertEqual(definitions[1].choices.map(\.rawValue), ["false", "true"])
    }

    func testCursorDefinitionValuesPreserveListAgentsWireShape() {
        let values = AgentMCPModelParameterSupport.definitionValues(agent: .cursor, modelRaw: "grok-4.6")

        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].objectValue?["kind"]?.stringValue, "thinking")
        XCTAssertEqual(values[0].objectValue?["config_id"]?.stringValue, "effort")
        XCTAssertEqual(values[0].objectValue?["name"]?.stringValue, "Effort")
        XCTAssertEqual(values[0].objectValue?["current_value"]?.stringValue, "high")
        XCTAssertEqual(
            values[0].objectValue?["choices"]?.arrayValue?.compactMap { $0.objectValue?["value"]?.stringValue },
            ["low", "medium", "high", "xhigh"]
        )
        XCTAssertEqual(values[1].objectValue?["kind"]?.stringValue, "speed")
        XCTAssertEqual(values[1].objectValue?["config_id"]?.stringValue, "fast")
        XCTAssertEqual(values[1].objectValue?["name"]?.stringValue, "Speed")
        XCTAssertEqual(values[1].objectValue?["current_value"]?.stringValue, "true")
        XCTAssertEqual(
            values[1].objectValue?["choices"]?.arrayValue?.compactMap { $0.objectValue?["value"]?.stringValue },
            ["false", "true"]
        )
    }

    func testOpenCodeDefinitionsAdvertiseEffortWhenMetadataExists() {
        installOpenCodeEffortMetadata()
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

        let definitions = AgentMCPModelParameterSupport.definitions(
            agent: .openCode,
            modelRaw: "ollama-cloud/kimi-k3"
        )
        XCTAssertEqual(definitions.map(\.configID), ["effort"])
        XCTAssertEqual(definitions[0].choices.map(\.rawValue), ["low", "high"])

        let values = AgentMCPModelParameterSupport.definitionValues(
            agent: .openCode,
            modelRaw: "ollama-cloud/kimi-k3"
        )
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].objectValue?["config_id"]?.stringValue, "effort")
        XCTAssertEqual(
            values[0].objectValue?["choices"]?.arrayValue?.compactMap { $0.objectValue?["value"]?.stringValue },
            ["low", "high"]
        )
    }

    func testOpenCodeDefinitionsEmptyWithoutDiscoveryMetadata() {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

        XCTAssertTrue(
            AgentMCPModelParameterSupport.definitions(
                agent: .openCode,
                modelRaw: "anthropic/claude-sonnet"
            ).isEmpty
        )
        XCTAssertTrue(
            AgentMCPModelParameterSupport.definitionValues(
                agent: .openCode,
                modelRaw: "anthropic/claude-sonnet"
            ).isEmpty
        )
    }

    func testNonACPDefinitionsReturnEmpty() {
        XCTAssertTrue(AgentMCPModelParameterSupport.definitions(agent: .codexExec, modelRaw: "gpt-5").isEmpty)
        XCTAssertTrue(AgentMCPModelParameterSupport.definitionValues(agent: .codexExec, modelRaw: "gpt-5").isEmpty)
    }

    func testResolveRejectsUnknownConfigBeforeProducingSelections() throws {
        let requested: Value = .array([
            .object(["config_id": .string("unknown"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("unknown"))
        }
    }

    func testResolveRejectsUnknownValueBeforeProducingSelections() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("maximum")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("maximum"))
        }
    }

    func testResolvePreservesExactProviderWireValueAndCanonicalBase() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("HIGH")]),
            .object(["config_id": .string("fast"), "value": .string("true")])
        ])

        let selections = try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "Cursor Grok 4.6"
        )

        XCTAssertEqual(selections.map(\.configID), ["effort", "fast"])
        XCTAssertEqual(selections.map(\.valueRaw), ["high", "true"])
        XCTAssertEqual(selections.map(\.baseModelRaw), ["grok-4.6", "grok-4.6"])
    }

    func testResolveCanonicalizesLegacyComposer2BaseModel() throws {
        let selections = try AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string("fast"), "value": .string("true")])
            ]),
            agent: .cursor,
            modelRaw: "composer-2"
        )

        XCTAssertEqual(selections.map(\.baseModelRaw), ["composer-2.5"])
        XCTAssertEqual(selections.map(\.configID), ["fast"])
        XCTAssertEqual(selections.map(\.valueRaw), ["true"])
    }

    func testResolveRejectsWhitespaceBearingProviderConfigID() throws {
        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string(" effort "), "value": .string("high")])
            ]),
            agent: .cursor,
            modelRaw: "grok-4.6"
        ))
    }

    func testResolveRejectsDuplicateConfigIDs() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("low")]),
            .object(["config_id": .string("effort"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok-4.6"
        ))
    }

    func testNonACPProviderRejectsModelParameters() throws {
        let requested: Value = .array([
            .object(["config_id": .string("effort"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .codexExec,
            modelRaw: "gpt-5"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("ACP"))
        }
    }

    func testOpenCodeResolveAcceptsSupportedEffort() throws {
        installOpenCodeEffortMetadata()
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

        let selections = try AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string("effort"), "value": .string("high")])
            ]),
            agent: .openCode,
            modelRaw: "ollama-cloud/kimi-k3"
        )

        XCTAssertEqual(selections.map(\.providerID), [.openCode])
        XCTAssertEqual(selections.map(\.valueRaw), ["high"])
        XCTAssertEqual(selections.map(\.baseModelRaw), ["ollama-cloud/kimi-k3"])
    }

    func testOpenCodeResolveRejectsMissingMetadata() throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string("effort"), "value": .string("high")])
            ]),
            agent: .openCode,
            modelRaw: "anthropic/claude-sonnet"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("metadata is unavailable"))
        }
    }

    func testEffectiveSelectionsIncludeOpenCodeProvider() {
        installOpenCodeEffortMetadata()
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

        let selections = [
            ACPModelParameterSelection(
                providerID: .openCode,
                baseModelRaw: "ollama-cloud/kimi-k3",
                kind: .thinking,
                configID: "effort",
                valueRaw: "high"
            )
        ]

        XCTAssertEqual(
            AgentMCPModelParameterSupport.effectiveSelections(
                selections,
                agentRaw: AgentProviderKind.openCode.rawValue,
                modelRaw: "ollama-cloud/kimi-k3"
            ),
            selections
        )
    }

    func testAgentRunSnapshotPublishesEffectiveModelParameterSelections() throws {
        let snapshot = AgentRunMCPSnapshot(
            sessionID: UUID(),
            tabID: UUID(),
            sessionName: "Cursor run",
            agentRaw: AgentProviderKind.cursor.rawValue,
            agentDisplayName: "Cursor",
            modelRaw: "grok",
            reasoningEffortRaw: nil,
            modelParameterSelections: [
                .init(
                    providerID: ACPProviderID.cursor.rawValue,
                    baseModelRaw: "grok",
                    kind: ACPModelParameterKind.thinking.rawValue,
                    configID: "thought_level",
                    valueRaw: "high"
                )
            ],
            status: .running,
            statusText: nil,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )

        let parameter = try XCTUnwrap(
            snapshot.asObject()["agent"]?.objectValue?["model_parameters"]?.arrayValue?.first?.objectValue
        )
        XCTAssertEqual(parameter["provider_id"]?.stringValue, "cursor")
        XCTAssertEqual(parameter["base_model"]?.stringValue, "grok")
        XCTAssertEqual(parameter["kind"]?.stringValue, "thinking")
        XCTAssertEqual(parameter["config_id"]?.stringValue, "thought_level")
        XCTAssertEqual(parameter["value"]?.stringValue, "high")
    }

    func testEffectiveSelectionsExcludeOtherCursorBaseModels() {
        let selections = [
            ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: "grok-4.6",
                kind: .thinking,
                configID: "Cursor.Thought-Level",
                valueRaw: "high"
            ),
            ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: "composer-2",
                kind: .speed,
                configID: "model_config",
                valueRaw: "fast"
            )
        ]

        XCTAssertEqual(
            AgentMCPModelParameterSupport.effectiveSelections(
                selections,
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "Grok 4.6"
            ),
            [
                ACPModelParameterSelection(
                    providerID: .cursor,
                    baseModelRaw: "grok-4.6",
                    kind: .thinking,
                    configID: "Cursor.Thought-Level",
                    valueRaw: "high"
                )
            ]
        )
    }

    private func installOpenCodeEffortMetadata() {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        let parameterSet = ACPModelParameterSet(
            baseModelRaw: "ollama-cloud/kimi-k3",
            parameters: [
                .init(
                    kind: .thinking,
                    configID: "effort",
                    displayName: "Effort",
                    choices: [
                        .init(rawValue: "low", displayName: "Low"),
                        .init(rawValue: "high", displayName: "High")
                    ],
                    currentValueRaw: "low"
                )
            ]
        )
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            .init(
                options: [
                    .init(
                        rawValue: "ollama-cloud/kimi-k3",
                        displayName: "Kimi K3",
                        description: nil,
                        isDefault: true
                    )
                ],
                currentModelRaw: "ollama-cloud/kimi-k3",
                modelParameterSets: [parameterSet]
            ),
            for: .openCode
        )
    }
}
