import Foundation
import MCP
import RepoPromptSettingsCore

/// Ephemeral exact-parent producer authority. Saved purpose never reconstructs this proof.
@MainActor
final class ComputerUseChildProof: Equatable {
    nonisolated static func == (lhs: ComputerUseChildProof, rhs: ComputerUseChildProof) -> Bool {
        lhs === rhs
    }

    static let denied = "Enable Computer Use and Other chats in Settings, then allow it in the calling chat."
    static let humanOnly = "Computer Use approvals require a human in the child chat. No response was applied."
    static let busy = "Another Computer Use task is running. Wait for it to settle; this request was not started or queued."
    private(set) static var holder: ComputerUseChildProof?
    private struct CreationKey: Hashable { let workspaceID: UUID
        let parentID: UUID
    }

    private static var creationClaims: [CreationKey: ComputerUseChildProof] = [:]
    private let creationKey: CreationKey
    let owner: AgentModeViewModel
    let parent: AgentTabSession
    let grant: UUID
    let fence: AgentRunStartStopFence
    let generation: UInt64
    let runID: UUID?
    let attemptID: UUID?
    var child: AgentTabSession? {
        didSet {
            if retiring, retirementOperation == nil, let child {
                retirementOperation = owner.captureComputerUseChildRetirement(child)
            }
        }
    }

    private var retirementOperation: (@MainActor () async -> Bool)?
    private(set) var retiring = false
    var producerActive = true
    private var nativeAttemptID: UUID?
    private var nativeControllerID: ObjectIdentifier?
    private var retirementTask: Task<Bool, Never>?
    var creationTarget: AgentModeViewModel.MCPSessionTarget?
    let modelID: String
    struct Configuration: Equatable {
        let enabled: Bool
        let modelID: String
        let modelAvailable: Bool
    }

    private let configuration: @MainActor () -> Configuration

    static func capture(owner: AgentModeViewModel) throws -> ComputerUseChildProof {
        guard let context = MCPInvocationContextBridge.current, case .network = context.origin,
              let route = context.dispatchAuthorization?.windowIdentity?.modelRouteToken,
              route.observerEndpoint == owner.agentSessionLinkObserverEndpoint(tabID: route.observerEndpoint.tabID),
              let parent = owner.sessions[route.observerEndpoint.tabID], parent.runID == route.runID else { throw MCPError.invalidParams(denied) }
        return try ComputerUseChildProof(owner: owner, parent: parent)
    }

    static var enabled: Bool {
        GlobalSettingsStore.shared.computerUsePolicy.subagent
    }

    static var currentConfiguration: Configuration {
        let model = GlobalSettingsStore.shared.scalarPreferences.agentMode?.computerUseModel ?? "codexExec:gpt-6.1-terra-high"
        let available = model == "codexExec:gpt-6.1-sol-high" || AgentCodexModelRegistry.shared.resolvedOptions(staticOptions: []).contains { model == "codexExec:\($0.rawValue)" }
        return .init(enabled: enabled, modelID: model, modelAvailable: available)
    }

    init(owner: AgentModeViewModel, parent: AgentTabSession, configuration: @escaping @MainActor () -> Configuration = { currentConfiguration }) throws {
        let configured = configuration()
        guard let grant = parent.computerUseParentGrant, parent.parentSessionID == nil,
              !parent.isComputerUseChild, parent.selectedAgent != .codexExec,
              owner.sessions[parent.tabID] === parent, parent.activeAgentSessionID != nil,
              parent.persistentSessionBindingIdentity != nil,
              let endpoint = owner.agentSessionLinkObserverEndpoint(tabID: parent.tabID), configured.enabled, configured.modelAvailable,
              ["codexExec:gpt-6.1-terra-high", "codexExec:gpt-6.1-sol-high"].contains(configured.modelID) else { throw MCPError.invalidParams(Self.denied) }
        creationKey = CreationKey(workspaceID: endpoint.workspaceID, parentID: endpoint.sessionID)
        self.configuration = configuration
        modelID = configured.modelID
        self.owner = owner
        self.parent = parent
        self.grant = grant
        fence = AgentRunStartStopFence(session: parent)
        generation = parent.bindingTransitionGeneration
        runID = parent.runID
        attemptID = parent.activeRunAttemptID
    }

    var parentIsCurrent: Bool {
        let configured = configuration()
        return !Task.isCancelled && configured.enabled && configured.modelAvailable && owner.sessions[parent.tabID] === parent
            && parent.computerUseParentGrant == grant && fence.permitsStart(of: parent)
            && parent.bindingTransitionGeneration == generation
            && (
                (parent.runID == runID && parent.activeRunAttemptID == attemptID)
                    || (child?.codexAuthoritativeActiveTurn != nil && child?.activeRunAttemptID == nativeAttemptID && nativeControllerID != nil)
            )
            && parent.parentSessionID == nil
            && parent.selectedAgent != .codexExec
            && configured.modelID == modelID
    }

    static func existingChildMessage(_ childID: UUID) -> String {
        "This chat already has a Computer Use child (session_id \(childID.uuidString)). Use steer with that session_id instead of start."
    }

    func claimCreation() throws {
        guard !retiring, parentIsCurrent else { throw MCPError.invalidParams(Self.denied) }
        if let existing = Self.creationClaims[creationKey] {
            if existing.creationTarget == nil, let id = existing.child?.activeAgentSessionID {
                throw MCPError.invalidParams(Self.existingChildMessage(id))
            }
            throw MCPError.invalidParams(Self.busy)
        }
        Self.creationClaims[creationKey] = self
    }

    func acceptCreation() throws {
        guard !retiring else { throw MCPError.invalidParams(Self.denied) }
        creationTarget = nil
    }

    func reserve() throws {
        guard !retiring, parentIsCurrent else { throw MCPError.invalidParams(Self.denied) }
        guard Self.holder == nil,
              !WindowStatesManager.shared.allWindows.contains(where: \.agentModeViewModel.computerUseControllerOrRetirementExists) else { throw MCPError.invalidParams(Self.busy) }
        Self.holder = self
    }

    func permits(_ session: AgentTabSession) -> Bool {
        !retiring && Self.holder === self && parentIsCurrent && child === session
            && owner.sessions[session.tabID] === session && session.purpose == "computerUse"
            && session.computerUseChildProof === self
            && session.parentSessionID == parent.activeAgentSessionID && session.selectedAgent == .codexExec
            && session.selectedReasoningEffortRaw == "high"
            && CodexModelSpecifier(raw: session.selectedModelRaw).baseModel == CodexModelSpecifier(raw: String(modelID.dropFirst("codexExec:".count))).baseModel
            && (nativeAttemptID == nil || nativeAttemptID == session.activeRunAttemptID)
            && (nativeControllerID == nil || nativeControllerID == session.codexController.map(ObjectIdentifier.init))
    }

    func claimNativeAttempt(_ session: AgentTabSession) -> Bool {
        guard permits(session), let attemptID = session.activeRunAttemptID else { return false }
        nativeAttemptID = attemptID
        return true
    }

    func claimController(_ controller: any CodexSessionControlling, session: AgentTabSession) -> Bool {
        guard permits(session), session.codexController.map(ObjectIdentifier.init) == ObjectIdentifier(controller),
              nativeControllerID == nil || nativeControllerID == ObjectIdentifier(controller) else { return false }
        nativeControllerID = ObjectIdentifier(controller)
        return true
    }

    func retire() {
        guard !retiring else { return }
        retiring = true
        // Capture the operation before a binding transition can install its successor.
        // Startup/response sinks also require !retiring.
        if let child { retirementOperation = owner.captureComputerUseChildRetirement(child) }
        if child != nil || !producerActive { finishRetirement() }
    }

    @discardableResult
    private func finishRetirement() -> Task<Void, Never> {
        if retirementTask == nil {
            let operation = retirementOperation
            let creationTarget = creationTarget
            retirementTask = Task { @MainActor [self] in
                guard await operation?() != false else { return false }
                if let creationTarget { return await owner.mcpDiscardSessionTarget(creationTarget) == .complete }
                return true
            }
        }
        return Task { @MainActor [self] in
            let retired = await retirementTask?.value
            // Unknown rollback/teardown retains the slot; timeouts never unlock it.
            guard retired == true, !producerActive else { return }
            release()
        }
    }

    @discardableResult
    func producerSettled() -> Task<Void, Never>? {
        producerActive = false
        if retiring {
            return finishRetirement()
        } else if child?.runState.isTerminalForCommit == true {
            retire()
            return finishRetirement()
        } else if child == nil {
            release()
        }
        return nil
    }

    private func release() {
        if Self.holder === self { Self.holder = nil }
        if Self.creationClaims[creationKey] === self { Self.creationClaims.removeValue(forKey: creationKey) }
        if child?.computerUseChildProof === self { child?.computerUseChildProof = nil }
        child = nil
    }
}
