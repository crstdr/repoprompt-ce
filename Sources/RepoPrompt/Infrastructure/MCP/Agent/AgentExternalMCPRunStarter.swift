import Foundation
import MCP
import RepoPromptDomainRuntime

@MainActor
enum AgentExternalMCPRunStarter {
    struct StartOutcome: Equatable {
        let snapshot: AgentRunMCPSnapshot
        let delivery: AgentModeViewModel.MCPInstructionDispatch
    }

    typealias RequestMetadata = MCPRequestMetadata
    typealias BindCurrentRequestToTab = (_ tabID: UUID, _ metadata: MCPRequestMetadata) async throws -> Void
    typealias DispatchInstruction = @MainActor (
        _ sessionID: UUID,
        _ tabID: UUID,
        _ message: String,
        _ workflow: AgentWorkflowDefinition?,
        _ agentModeVM: AgentModeViewModel
    ) async throws -> AgentModeViewModel.MCPInstructionDispatch

    private enum RequestBindingDisposition {
        case preserveCallerBinding
        case applyRequestBindingPolicy(BindCurrentRequestToTab)
    }

    /// Extracts a reasoning effort suffix from a model string if present.
    /// Supports Codex variants such as "gpt-5.4-high" and Claude variants such as
    /// "claude-opus-5-5:low" without changing the model selection.
    /// The model string is passed through unchanged (preserving service tier and other modifiers);
    /// only the effort is extracted separately.
    static func extractReasoningEffort(from modelRaw: String?) -> (model: String?, effort: String?) {
        guard let modelRaw, !modelRaw.isEmpty else { return (modelRaw, nil) }
        let specifier = CodexModelSpecifier(raw: modelRaw)
        if let effort = specifier.reasoningEffort {
            return (modelRaw, effort.rawValue)
        }
        if let effort = ClaudeModelSpecifier(raw: modelRaw).explicitEffortLevel {
            return (modelRaw, effort.rawValue)
        }
        return (modelRaw, nil)
    }

    static func startPreservingCallerBinding(
        target: AgentModeViewModel.MCPSessionTarget,
        message: String,
        metadata: MCPRequestMetadata,
        agentModeVM: AgentModeViewModel,
        agentRaw: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        workflow: AgentWorkflowDefinition? = nil,
        expectedParentSessionID: UUID? = nil,
        oracleReviewSource: AgentRunOracleReviewSource? = nil,
        preserveRoutedInitialEffort: Bool = false,
        dispatchInstruction: DispatchInstruction? = nil
    ) async throws -> StartOutcome {
        try await startWithBindingDisposition(
            target: target,
            message: message,
            metadata: metadata,
            bindingDisposition: .preserveCallerBinding,
            agentModeVM: agentModeVM,
            agentRaw: agentRaw,
            modelRaw: modelRaw,
            reasoningEffortRaw: reasoningEffortRaw,
            taskLabelKind: taskLabelKind,
            workflow: workflow,
            expectedParentSessionID: expectedParentSessionID,
            oracleReviewSource: oracleReviewSource,
            preserveRoutedInitialEffort: preserveRoutedInitialEffort,
            dispatchInstruction: dispatchInstruction
        )
    }

    static func startApplyingRequestBindingPolicy(
        target: AgentModeViewModel.MCPSessionTarget,
        message: String,
        metadata: MCPRequestMetadata,
        bindCurrentRequestToTab: @escaping BindCurrentRequestToTab,
        agentModeVM: AgentModeViewModel,
        agentRaw: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        workflow: AgentWorkflowDefinition? = nil,
        expectedParentSessionID: UUID? = nil,
        oracleReviewSource: AgentRunOracleReviewSource? = nil,
        preserveRoutedInitialEffort: Bool = false,
        dispatchInstruction: DispatchInstruction? = nil
    ) async throws -> StartOutcome {
        try await startWithBindingDisposition(
            target: target,
            message: message,
            metadata: metadata,
            bindingDisposition: .applyRequestBindingPolicy(bindCurrentRequestToTab),
            agentModeVM: agentModeVM,
            agentRaw: agentRaw,
            modelRaw: modelRaw,
            reasoningEffortRaw: reasoningEffortRaw,
            taskLabelKind: taskLabelKind,
            workflow: workflow,
            expectedParentSessionID: expectedParentSessionID,
            oracleReviewSource: oracleReviewSource,
            preserveRoutedInitialEffort: preserveRoutedInitialEffort,
            dispatchInstruction: dispatchInstruction
        )
    }

    private static func startWithBindingDisposition(
        target: AgentModeViewModel.MCPSessionTarget,
        message: String,
        metadata: MCPRequestMetadata,
        bindingDisposition: RequestBindingDisposition,
        agentModeVM: AgentModeViewModel,
        agentRaw: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        workflow: AgentWorkflowDefinition?,
        expectedParentSessionID: UUID?,
        oracleReviewSource: AgentRunOracleReviewSource?,
        preserveRoutedInitialEffort: Bool,
        dispatchInstruction: DispatchInstruction?
    ) async throws -> StartOutcome {
        let resolvedModel: String?
        let resolvedEffort: String?
        if let reasoningEffortRaw {
            resolvedModel = modelRaw
            resolvedEffort = reasoningEffortRaw
        } else {
            let extracted = extractReasoningEffort(from: modelRaw)
            resolvedModel = extracted.model
            resolvedEffort = extracted.effort
        }
        guard let sessionID = target.sessionID else {
            throw MCPError.internalError("Failed to resolve target agent session ID.")
        }
        #if DEBUG
            agentModeVM.perfRecorder.event("mcp.routing.externalRunStarterActivate", tabID: target.tabID, fields: [
                "sessionID": sessionID.uuidString,
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "clientName": metadata.clientName ?? "nil",
                "windowID": metadata.windowID.map(String.init) ?? "nil",
                "taskLabel": taskLabelKind?.rawValue ?? "nil",
                "agent": agentRaw ?? "nil",
                "model": resolvedModel ?? "nil",
                "workflowID": workflow?.id ?? "nil",
                "workflowName": workflow?.displayName ?? "nil"
            ])
        #endif
        let startScope = MCPAgentRunStartExecutionScope.current
        // A fresh target remains creation-owned through control, model and request setup.
        // Only the complete initial configuration may cross the first durable-save boundary.
        let ownedActivation: AgentModeViewModel.AgentMCPControlContext
        do {
            try startScope?.checkAdmission()
            ownedActivation = try await agentModeVM.mcpActivateControlContext(
                forTabID: target.tabID,
                sessionID: sessionID,
                originatingConnectionID: metadata.connectionID,
                taskLabelKind: taskLabelKind,
                startPending: true,
                creationHandle: target.creationHandle,
                computerUseProof: agentModeVM.session(for: target.tabID, createIfNeeded: false)?.computerUseChildProof
            )
        } catch {
            // Activation owns rollback of its registration. Do not tear down a different
            // context if this attempt failed before returning an owned activation.
            try? startScope?.enterReturn()
            if startScope?.allowsFailureCleanup != false {
                agentModeVM.failSessionCreation(
                    target.creationHandle,
                    message: "This session did not finish preparing its first run. Create a new session."
                )
            }
            throw error
        }

        // All failures after activation may clean up only this exact inactive producer.
        let activatedSession = agentModeVM.session(for: target.tabID, createIfNeeded: false)
        do {
            try startScope?.checkAdmission()
            guard let activatedSession,
                  activatedSession.activeAgentSessionID == sessionID,
                  activatedSession.mcpControlContext == ownedActivation,
                  activatedSession.mcpFollowUpRunPending
            else {
                throw MCPError.invalidParams("The pending agent start was withdrawn or replaced during activation.")
            }
            let pendingStartFence = AgentRunStartStopFence(session: activatedSession)
            let computerUseProof = activatedSession.computerUseChildProof
            func requirePendingStart() throws {
                try startScope?.checkAdmission()
                guard agentModeVM.session(for: target.tabID, createIfNeeded: false) === activatedSession,
                      activatedSession.activeAgentSessionID == sessionID,
                      activatedSession.mcpControlContext == ownedActivation,
                      pendingStartFence.permitsStart(of: activatedSession),
                      !activatedSession.isComputerUseChild || computerUseProof?.permits(activatedSession) == true
                else {
                    throw MCPError.invalidParams("The pending agent start was withdrawn or replaced before dispatch.")
                }
            }
            if let oracleReviewSource {
                try agentModeVM.mcpStageAgentRunOracleReviewSource(
                    oracleReviewSource,
                    targetTabID: target.tabID,
                    targetSessionID: sessionID,
                    expectedParentSessionID: expectedParentSessionID
                )
            }
            try startScope?.checkAdmission()
            try await agentModeVM.mcpConfigureSession(
                tabID: target.tabID,
                agentRaw: agentRaw,
                modelRaw: resolvedModel,
                reasoningEffortRaw: resolvedEffort,
                expectedControlContext: ownedActivation,
                creationHandle: target.creationHandle
            )
            try startScope?.checkAdmission()
            if activatedSession.isComputerUseChild {
                try requirePendingStart()
                guard let computerUseProof else { throw MCPError.invalidParams(ComputerUseChildProof.denied) }
                try await agentModeVM.armComputerUseChild(session: activatedSession, proof: computerUseProof)
                try requirePendingStart()
            }
            switch bindingDisposition {
            case .preserveCallerBinding:
                #if DEBUG
                    agentModeVM.perfRecorder.event("mcp.routing.externalRunStarterPreservedCallerBinding", tabID: target.tabID, fields: [
                        "sessionID": sessionID.uuidString,
                        "connectionID": metadata.connectionID?.uuidString ?? "nil",
                        "windowID": metadata.windowID.map(String.init) ?? "nil"
                    ])
                #endif
            case let .applyRequestBindingPolicy(bindCurrentRequestToTab):
                try await bindCurrentRequestToTab(target.tabID, metadata)
                #if DEBUG
                    agentModeVM.perfRecorder.event("mcp.routing.externalRunStarterBoundRequest", tabID: target.tabID, fields: [
                        "sessionID": sessionID.uuidString,
                        "connectionID": metadata.connectionID?.uuidString ?? "nil",
                        "windowID": metadata.windowID.map(String.init) ?? "nil"
                    ])
                #endif
            }

            try Task.checkCancellation()
            try requirePendingStart()
            guard await agentModeVM.commitConfiguredSessionCreation(target: target) else {
                throw MCPError.internalError("Failed to persist the configured agent session before starting it.")
            }
            try Task.checkCancellation()
            try requirePendingStart()

            try startScope?.checkAdmission()
            try agentModeVM.requireMCPControlOwnership(sessionID: sessionID, expectedContext: ownedActivation)
            let delivery: AgentModeViewModel.MCPInstructionDispatch
            if let dispatchInstruction {
                try startScope?.beginDispatch()
                delivery = try await dispatchInstruction(sessionID, target.tabID, message, workflow, agentModeVM)
                startScope?.recordDispatch(accepted: true)
            } else {
                delivery = try await agentModeVM.mcpDispatchInstruction(
                    sessionID: sessionID,
                    text: message,
                    allowStartingRun: true,
                    workflow: workflow,
                    preserveRoutedInitialEffort: preserveRoutedInitialEffort,
                    expectedControlContext: ownedActivation,
                    validateInitialStart: requirePendingStart,
                    computerUseProof: computerUseProof
                )
            }

            let snapshot = await resolveInitialSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
            #if DEBUG
                agentModeVM.perfRecorder.event("mcp.routing.externalRunStarterDispatched", tabID: target.tabID, fields: [
                    "sessionID": sessionID.uuidString,
                    "connectionID": metadata.connectionID?.uuidString ?? "nil",
                    "snapshotStatus": snapshot.status.rawValue
                ])
            #endif
            return StartOutcome(snapshot: snapshot, delivery: delivery)
        } catch {
            try? startScope?.enterReturn()
            if startScope?.allowsFailureCleanup != false {
                agentModeVM.failSessionCreation(
                    target.creationHandle,
                    message: "This session did not finish preparing its first run. Create a new session."
                )
                if let activatedSession,
                   agentModeVM.session(for: target.tabID, createIfNeeded: false) === activatedSession,
                   activatedSession.mcpControlContext == ownedActivation
                {
                    _ = await agentModeVM.mcpDeactivateOwnedControlContext(
                        sessionID: sessionID,
                        expectedContext: ownedActivation
                    )
                }
            }
            throw error
        }
    }

    private static func resolveInitialSnapshot(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) async -> AgentRunMCPSnapshot {
        guard let registration = agentModeVM.mcpRegistration(sessionID: sessionID) else {
            return .expired(sessionID: sessionID)
        }
        if let liveSnapshot = agentModeVM.mcpSnapshot(registration: registration) {
            return liveSnapshot
        }
        if let storedSnapshot = await AgentRunSessionStore.snapshot(for: registration) {
            return storedSnapshot
        }
        await Task.yield()
        if let liveSnapshot = agentModeVM.mcpSnapshot(registration: registration) {
            return liveSnapshot
        }
        if let storedSnapshot = await AgentRunSessionStore.snapshot(for: registration) {
            return storedSnapshot
        }
        return .expired(sessionID: sessionID)
    }
}
