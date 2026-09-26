import Foundation

final class DevinACPHeadlessAgentProvider: HeadlessAgentProvider {
    typealias ProviderFactory = @Sendable (_ config: DevinAgentConfig) -> any ACPAgentProvider
    typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    private let config: DevinAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    init(
        config: DevinAgentConfig,
        workspacePath: String? = nil,
        // Test-only override. `nil` keeps the production behaviour of resolving the stored
        // level inside `makeRequest` -- once per run, not once per provider -- so a level
        // change still takes effect on the next run of a reused provider.
        configuredPermissionLevel: DevinAgentToolPreferences.PermissionLevel? = nil,
        providerFactory: ProviderFactory? = nil,
        controllerFactory: @escaping ControllerFactory = { provider, request, diagnosticSink in
            try ACPAgentSessionController(
                provider: provider,
                runRequest: request,
                diagnosticSink: diagnosticSink
            )
        }
    ) {
        self.config = config
        let resolvedProviderFactory = providerFactory ?? { config in
            DevinACPAgentProvider(config: config)
        }
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Devin",
            makeProvider: { resolvedProviderFactory(config) },
            makeRequest: { message, _ in
                Self.makeRunRequest(
                    config: config,
                    workspacePath: workspacePath,
                    message: message,
                    // Resolved per request, not captured at init.
                    configuredPermissionLevel: configuredPermissionLevel
                        ?? DevinAgentToolPreferences.permissionLevel()
                )
            },
            makeController: controllerFactory,
            beforePrompt: { controller, request in
                // The bridge has no session-mode step of its own, so apply it here.
                //
                // Model and parameter selections first, mode last -- the same order the
                // interactive runner uses. Setting the mode last means no later
                // configuration call can accept a response that carries a different one.
                if let model = request.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !model.isEmpty,
                   model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
                {
                    try await controller.setSessionModel(model, forceRPC: !request.modelParameterSelections.isEmpty)
                }
                let report = try await controller.applySessionModelParameterSelections(request.modelParameterSelections)
                try report.validateNoSkippedSelections()
                guard let mode = request.sessionModeID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !mode.isEmpty
                else { return }
                try await controller.setSessionMode(mode)
            },
            approvalPolicy: .declineUnsupported
        )
    }

    /// Headless runs are unattended: the bridge declines any permission request the
    /// controller does not auto-approve, so a mid-run prompt fails the whole run. The
    /// configured level is applied as the ACP session mode (`sessionModeID`), sent only
    /// when the RepoPrompt MCP server is injected; model discovery keeps the provider
    /// default. A level that maps to no mode sends nothing: on a fresh session that
    /// leaves Devin's own default, and on a resumed session the controller's
    /// resume-permission guard refuses the prompt rather than run at an inherited mode.
    static func makeRunRequest(
        config: DevinAgentConfig,
        workspacePath: String?,
        message: AgentMessage,
        configuredPermissionLevel: DevinAgentToolPreferences.PermissionLevel =
            DevinAgentToolPreferences.permissionLevel()
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .devin,
            modelString: config.modelString,
            workspacePath: workspacePath,
            resumeSessionID: message.resumeSessionID,
            attachments: [],
            taskLabelKind: nil,
            sessionModeID: config.includeRepoPromptMCPServer
                ? configuredPermissionLevel.sessionModeID
                : nil,
            modelParameterSelections: config.modelParameterSelections
        )
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        try await bridge.streamAgentMessage(message, runID: runID)
    }

    func dispose() async {
        await bridge.dispose()
    }
}
