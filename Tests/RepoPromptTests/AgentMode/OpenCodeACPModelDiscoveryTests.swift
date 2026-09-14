import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class OpenCodeACPModelDiscoveryTests: XCTestCase {
    func testControllerDiscoveryReturnsLiveParameterizedOpenCodeSnapshotWithoutRegistryPublication() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

        let workspace = try makeTestDirectory(name: "OpenCodeACPModelDiscoveryTests")
        let scriptURL = try makeServerScript(in: workspace)
        let provider = OpenCodeDiscoveryFakeProvider(commandPath: scriptURL.path)
        let client = OpenCodeACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in provider },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request)
            }
        )

        let discovered = try await client.discoverModels(workspacePath: workspace.path)
        let snapshot = try XCTUnwrap(discovered)

        XCTAssertEqual(snapshot.currentModelRaw, "ollama-cloud/kimi-k3")
        XCTAssertEqual(snapshot.options.map(\.rawValue), ["ollama-cloud/kimi-k3", "anthropic/claude-sonnet"])
        XCTAssertEqual(snapshot.modelParameterSets.map(\.baseModelRaw), ["ollama-cloud/kimi-k3"])
        XCTAssertEqual(snapshot.modelParameterSets.first?.parameters.map(\.configID), ["effort"])
        XCTAssertEqual(
            snapshot.modelParameterSets.first?.parameters.first?.choices.map(\.rawValue),
            ["low", "high", "max", "default"]
        )
        XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .openCode))
    }

    func testPollingServicePublishesDiscoveryResultToRegistryAfterColdStart() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

        let workspace = try makeTestDirectory(name: "OpenCodeACPModelPollingTests")
        let scriptURL = try makeServerScript(in: workspace)
        let provider = OpenCodeDiscoveryFakeProvider(commandPath: scriptURL.path)
        let client = OpenCodeACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in provider },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request)
            }
        )
        let service = OpenCodeACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }

        XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .openCode))

        let snapshot = try await service.discoverOnce(workspacePath: workspace.path)
        let published = try XCTUnwrap(snapshot)
        XCTAssertEqual(published.models.currentModelRaw, "ollama-cloud/kimi-k3")
        XCTAssertEqual(published.models.modelParameterSets.first?.parameters.map(\.configID), ["effort"])
        XCTAssertEqual(
            AgentACPModelRegistry.shared.currentSnapshot(for: .openCode)?.currentModelRaw,
            "ollama-cloud/kimi-k3"
        )
    }

    func testOpenCodeClassifierRecognizesEffortAndRejectsUnrelatedOptions() {
        let provider = OpenCodeACPAgentProvider(
            config: OpenCodeAgentConfig(
                modelString: nil,
                enableDebugLogging: false,
                includeRepoPromptMCPServer: false,
                includeManagedConfigOverlay: false,
                cleanupLegacyPersistentConfig: false,
                toolProfile: .noTools
            )
        )
        XCTAssertTrue(provider.supportsParameterizedModelPicker)
        let effortChoices = [
            ACPModelParameterChoice(rawValue: "low", displayName: "Low"),
            ACPModelParameterChoice(rawValue: "high", displayName: "High")
        ]

        XCTAssertEqual(
            provider.modelParameterKind(for: .init(
                configID: "effort",
                category: "thought_level",
                displayName: "Effort",
                choices: effortChoices
            )),
            .thinking
        )
        XCTAssertEqual(
            provider.modelParameterKind(for: .init(
                configID: "effort",
                category: nil,
                displayName: "Effort",
                choices: effortChoices
            )),
            .thinking
        )
        XCTAssertEqual(
            provider.modelParameterKind(for: .init(
                configID: "mode",
                category: "thought_level",
                displayName: "Mode",
                choices: effortChoices
            )),
            .thinking
        )
        XCTAssertNil(
            provider.modelParameterKind(for: .init(
                configID: "fast",
                category: "model_config",
                displayName: "Fast",
                choices: [
                    ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
                    ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
                ]
            ))
        )
    }

    func testParameterSetLookupMatchesCanonicalOpenCodeIdentityAndMissingModelReturnsNil() {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

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

        XCTAssertEqual(
            ACPModelParameterResolver.parameterSet(
                providerID: .openCode,
                selectedModelRaw: " Ollama-Cloud/Kimi-K3 "
            )?.parameters.map(\.configID),
            ["effort"]
        )
        XCTAssertNil(
            ACPModelParameterResolver.parameterSet(
                providerID: .openCode,
                selectedModelRaw: "anthropic/claude-sonnet"
            )
        )
    }

    private func makeServerScript(in directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("opencode_discovery_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        model = "ollama-cloud/kimi-k3"
        effort = "low"

        def selector(id, name, category, current, choices):
            return {"id": id, "name": name, "category": category, "type": "select",
                    "currentValue": current, "options": [{"value": v, "name": n} for v, n in choices]}

        def options():
            return [
                selector("model", "Model", "model", model, [
                    ("ollama-cloud/kimi-k3", "Kimi K3"),
                    ("anthropic/claude-sonnet", "Claude Sonnet"),
                ]),
                selector("effort", "Effort", "thought_level", effort, [
                    ("low", "Low"),
                    ("high", "High"),
                    ("max", "Max"),
                    ("default", "Default"),
                ]),
            ]

        for line in sys.stdin:
            request = json.loads(line)
            request_id = request.get("id")
            if request_id is None:
                continue
            method = request.get("method")
            if method == "initialize":
                result = {"agentCapabilities": {}}
            elif method == "session/new":
                result = {"sessionId": "opencode-discovery", "configOptions": options()}
            elif method == "session/set_config_option":
                params = request.get("params", {})
                if params.get("configId") == "model":
                    model = params.get("value", model)
                elif params.get("configId") == "effort":
                    effort = params.get("value", effort)
                result = {"configOptions": options()}
            else:
                result = {}
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

private struct OpenCodeDiscoveryFakeProvider: ACPAgentProvider {
    let commandPath: String
    var environment: [String: String] = [:]

    let providerID: ACPProviderID = .openCode
    private var productionProvider: OpenCodeACPAgentProvider {
        OpenCodeACPAgentProvider(
            config: OpenCodeAgentConfig(
                modelString: nil,
                enableDebugLogging: false,
                includeRepoPromptMCPServer: false,
                includeManagedConfigOverlay: false,
                cleanupLegacyPersistentConfig: false,
                toolProfile: .noTools
            )
        )
    }

    var supportsParameterizedModelPicker: Bool {
        productionProvider.supportsParameterizedModelPicker
    }

    func modelParameterKind(for input: ACPModelParameterClassificationInput) -> ACPModelParameterKind? {
        productionProvider.modelParameterKind(for: input)
    }

    func support(for _: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(
        _: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}
