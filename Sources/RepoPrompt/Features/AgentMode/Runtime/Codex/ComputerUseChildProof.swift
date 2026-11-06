import Foundation
import MCP
import RepoPromptSettingsCore

/// CU-local transport fence. The network actor revokes before authority writes; submission
/// and revocation share a lock. It stops owning route validity after instruction submission.
final class ComputerUseRunRouteFence: @unchecked Sendable {
    let token: AgentSessionLinkRunCatalogRouteToken
    private let identity: MCPWindowToolDispatchIdentity
    private let connectionIdentity: ObjectIdentifier
    private let lock = NSLock()
    private var valid = true
    private var submitted = false

    init(token: AgentSessionLinkRunCatalogRouteToken, identity: MCPWindowToolDispatchIdentity, connectionIdentity: ObjectIdentifier) {
        self.token = token
        self.identity = identity
        self.connectionIdentity = connectionIdentity
    }

    var hasSubmitted: Bool {
        lock.withLock { submitted }
    }

    func invalidate() {
        lock.withLock { if !submitted { valid = false } }
    }

    func matches(_ invocation: ToolInvocationContext) -> Bool {
        guard case .network = invocation.origin, invocation.toolName == "agent_run",
              invocation.connectionID == token.connectionID,
              invocation.metadata.windowID == token.observerEndpoint.windowID,
              let authorization = invocation.dispatchAuthorization,
              authorization.connectionID == token.connectionID,
              authorization.connectionIdentity == connectionIdentity,
              authorization.lifecycleGeneration == token.connectionLifecycleGeneration,
              let window = authorization.windowIdentity,
              window.windowID == identity.windowID,
              window.windowStateIdentity == identity.windowStateIdentity,
              window.serverViewModelIdentity == identity.serverViewModelIdentity,
              window.catalogRegistrationHandle == identity.catalogRegistrationHandle,
              window.computerUseRunRouteCandidate === self else { return false }
        return true
    }

    @MainActor
    func requireCurrent() throws {
        let endpoint = token.observerEndpoint
        guard !Task.isCancelled, lock.withLock({ valid }),
              let window = WindowStatesManager.shared.window(withID: endpoint.windowID), !window.isClosing,
              ObjectIdentifier(window) == identity.windowStateIdentity,
              ObjectIdentifier(window.mcpServer) == identity.serverViewModelIdentity,
              window.mcpServer.hasCurrentRunRouteMapping(runID: token.runID, connectionID: token.connectionID, expectedTabID: endpoint.tabID),
              window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint
        else { throw MCPError.invalidParams(ComputerUseChildProof.denied) }
    }

    @MainActor
    func withInstructionSubmission<T>(_ submit: () throws -> T) throws -> T {
        try requireCurrent()
        return try lock.withLock {
            guard valid, !submitted, !Task.isCancelled else { throw MCPError.invalidParams(ComputerUseChildProof.denied) }
            let result = try submit()
            submitted = true
            return result
        }
    }
}

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
    private(set) var instructionDispatchEntered = false
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
    private var runRouteFence: ComputerUseRunRouteFence?
    var hasNetworkRunRouteFence: Bool {
        runRouteFence != nil
    }

    static func capture(owner: AgentModeViewModel, configuration: @escaping @MainActor () -> Configuration = { currentConfiguration }) throws -> ComputerUseChildProof {
        guard let context = MCPInvocationContextBridge.current, case .network = context.origin,
              let candidate = context.dispatchAuthorization?.windowIdentity?.computerUseRunRouteCandidate,
              candidate.matches(context) else { throw MCPError.invalidParams(denied) }
        try candidate.requireCurrent()
        let route = candidate.token
        guard route.observerEndpoint == owner.agentSessionLinkObserverEndpoint(tabID: route.observerEndpoint.tabID),
              let parent = owner.sessions[route.observerEndpoint.tabID], parent.runID == route.runID else { throw MCPError.invalidParams(denied) }
        let proof = try ComputerUseChildProof(owner: owner, parent: parent, configuration: configuration)
        proof.runRouteFence = candidate
        return proof
    }

    func requireCurrentRoute() throws {
        try runRouteFence?.requireCurrent()
    }

    func withInstructionSubmission<T>(_ session: AgentTabSession, _ submit: () throws -> T) throws -> T {
        @MainActor func operation() throws -> T {
            try markInstructionDispatch(session)
            return try submit()
        }
        if let runRouteFence { return try runRouteFence.withInstructionSubmission(operation) }
        return try operation()
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
        guard !retiring || nativeAttemptID != nil else { throw MCPError.invalidParams(Self.denied) }
        if let creationTarget { owner.mcpAcceptSessionTarget(creationTarget) }
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

    func markInstructionDispatch(_ session: AgentTabSession) throws {
        guard permits(session) else { throw MCPError.invalidParams(Self.denied) }
        instructionDispatchEntered = true
    }

    func claimNativeAttempt(_ session: AgentTabSession) -> Bool {
        guard permits(session), let attemptID = session.activeRunAttemptID else { return false }
        nativeAttemptID = attemptID
        // Native admission ends provisional rollback ownership before dispatch can suspend.
        try? acceptCreation()
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
    func producerSettled(retireUnacceptedStart: Bool = false) -> Task<Void, Never>? {
        producerActive = false
        if retireUnacceptedStart, !instructionDispatchEntered || runRouteFence?.hasSubmitted == false { retire() }
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
