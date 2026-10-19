import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

extension AgentModeViewModel {
    /// Request-local composition evidence, not a persisted preview or a second admission owner.
    struct ProviderSwitchSendPreparation {
        let binding: AgentSessionRestorationBindingToken?
        let handoff: PendingHandoffState
        let agent: AgentProviderKind
        let model: String
        let rawInput: String
        let augmentedInput: String
        let initialThreadInput: String
        let instructions: [String]
        let inputAlreadyIncludesSupplement: Bool
        let historyToolAllowed: Bool
        let computerUseArmed: Bool
        var acceptedInputID: UUID?

        func accepting(_ itemID: UUID) -> Self {
            var copy = self
            copy.acceptedInputID = itemID
            return copy
        }
    }

    /// ONE admission implementation for every input producer. Composition finishes before any
    /// input row/receipt is accepted. Start consumes this evidence; it never re-expands or re-fits.
    func providerSwitchSendAdmission(
        session: TabSession,
        input: String,
        attachments: [AgentImageAttachment] = [],
        taggedFiles: [AgentTaggedFileAttachment] = [],
        skipsAugmentation: Bool = false,
        inputAlreadyIncludesSupplement: Bool = false,
        supplementalInput: String? = nil,
        isCurrent: @MainActor () -> Bool = { !Task.isCancelled }
    ) async -> Result<ProviderSwitchSendPreparation?, AgentSessionLinkSendFailure> {
        guard let delivery = session.pendingHandoff.providerSwitchDelivery else { return .success(nil) }
        guard delivery == .ready else { return .failure(.providerSwitchUnconfirmed) }
        guard !Self.providerSwitchNeedsReview(session) else { return .failure(.providerHandoverNeedsReview) }
        guard !session.runState.isActive, session.activeRunOwnership == nil else { return .failure(.targetNotIdle) }
        let handoff = session.pendingHandoff
        let binding = session.currentRestorationBindingToken
        let agent = session.selectedAgent
        let model = session.selectedModelRaw
        let computerUseArmed = session.isCodexComputerUseArmed
        let augmented = skipsAugmentation ? input : await augmentUserMessageForProviderSend(
            input, attachments: attachments, taggedFileAttachments: taggedFiles,
            agent: agent, session: session, ignoresPendingHandoff: true
        )
        let initial = await buildInitialThreadMessageIfNeeded(
            tabID: session.tabID, session: session, initialMessage: augmented
        )
        guard isCurrent(), !Task.isCancelled else { return .failure(.targetStopped) }
        guard !session.runState.isActive, session.activeRunOwnership == nil else { return .failure(.targetNotIdle) }
        guard sessions[session.tabID] === session,
              session.currentRestorationBindingToken == binding,
              session.pendingHandoff == handoff,
              session.selectedAgent == agent, session.selectedModelRaw == model,
              session.isCodexComputerUseArmed == computerUseArmed,
              !Self.providerSwitchNeedsReview(session)
        else { return .failure(.providerHandoverNeedsReview) }
        let instructions = providerSwitchInstructionStrings(session, includeSupplement: !inputAlreadyIncludesSupplement)
        guard let payload = handoff.payload, !payload.isEmpty else { return .failure(.providerHandoverNeedsReview) }
        let bytes = payload.utf8.count
        guard bytes <= AgentProviderHandover.maximumBytes else { return .failure(.providerHandoverDoesNotFit) }
        guard let descriptor = ProviderSwitchCarrierDescriptor(payload),
              providerSwitchReadReferenceIsCurrent(descriptor, session: session)
        else { return .failure(.providerHandoverNeedsReview) }
        var budgetInstructions = instructions
        if let supplementalInput, let current = budgetInstructions.last,
           supplementalInput.utf8.count > current.utf8.count { budgetInstructions[budgetInstructions.count - 1] = supplementalInput }
        let budget = AgentProviderHandover.Budget(
            catalogWindow: providerSwitchCatalogWindow(agent: agent, model: model),
            instructions: budgetInstructions, composedInput: "\n\n" + initial, isPreview: false
        )
        guard descriptor.mode != "summary" || bytes <= AgentProviderHandover.maximumSummaryBytes,
              AgentProviderHandover.estimate(payload) <= budget.remainingCarrierTokens
        else { return .failure(.providerHandoverDoesNotFit) }
        return .success(ProviderSwitchSendPreparation(
            binding: binding, handoff: handoff, agent: agent, model: model, rawInput: input,
            augmentedInput: augmented, initialThreadInput: initial, instructions: instructions,
            inputAlreadyIncludesSupplement: inputAlreadyIncludesSupplement,
            historyToolAllowed: providerSwitchHistoryToolAllowed(session), computerUseArmed: computerUseArmed
        ))
    }

    func providerSwitchCatalogWindow(agent: AgentProviderKind, model: String) -> Int? {
        if agent.usesClaudeNativeRuntime {
            return ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(forRequestedModelRaw: model, agentKind: agent)
                ?? AgentModel.resolvedModel(forRaw: model, agentKind: agent)?.contextWindowTokens
        }
        return AgentModel.resolvedModel(forRaw: model, agentKind: agent)?.contextWindowTokens
    }

    /// Existing prompt owners author all these strings. Rendering current inventory in full is
    /// conservative for a pending fresh context and neither reserves nor acknowledges a claim.
    func providerSwitchInstructionStrings(_ session: TabSession, includeSupplement: Bool = true, destination: AgentProviderKind? = nil) -> [String] {
        let agent = destination ?? session.selectedAgent
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: agent, taskLabelKind: session.mcpControlContext?.taskLabelKind,
            codeMapsDisabled: GlobalSettingsStore.shared.globalCodeMapsDisabled()
        )
        let packagedPrompt = agent.usesClaudeNativeRuntime
            ? ClaudeCompatiblePluginBridge.providerBoundUserMessage("", instructions: prompt, delivery: ClaudeAgentToolPreferences.agentModePromptDelivery()) : ""
        var strings = [packagedPrompt.isEmpty ? prompt : packagedPrompt]
        if let note = session.selfCompactState.parkedNote { strings.append(note.frame) }
        var supplement = ""
        if includeSupplement, let context = agentSessionLinkPromptContext(for: session), context.epoch.allowsSupplement {
            let baseline = AgentSessionLinkPrompts.rendered(.init(
                membershipKind: context.inventory.isEmpty ? nil : .inventory,
                inventory: context.inventory, passiveNotices: context.passiveNotices,
                toolReference: context.epoch.toolReference
            ))
            supplement = AgentSessionLinkRuntimeBridge.shared.localInputDecoration(
                observer: context.epoch.endpoint, inventory: context.inventory, baseline: baseline
            )?.fragment ?? baseline.fragment
        }
        strings.append(supplement)
        return strings
    }

    static func providerSwitchUnconfirmed(_ session: TabSession) -> Bool {
        session.pendingHandoff.providerSwitchDelivery == .sending
            && (!session.pendingHandoff.isStagedForSend || session.activeRunOwnership == nil)
    }

    /// Accepted input after the saved cutoff invalidates the ready seed. The exact input currently
    /// being started is excluded, never arbitrary equal text. Missing retained cutoff fails closed.
    static func providerSwitchNeedsReview(_ session: TabSession, excluding inputID: UUID? = nil) -> Bool {
        guard session.pendingHandoff.providerSwitchDelivery != nil else { return false }
        var positions: [UUID: Int] = [:]
        var inputs: [UUID: Int] = [:]
        func record(_ id: UUID, _ sequence: Int, input: Bool) {
            positions[id] = sequence
            if input, id != inputID { inputs[id] = sequence }
        }
        for turn in session.transcript.turns {
            if let request = turn.request { record(request.id, request.sequenceIndex, input: true) }
            for activity in turn.allActivities {
                record(
                    activity.id,
                    activity.sequenceIndex,
                    input: activity.itemKind == .user
                        || activity.text == AgentLaneUpdateDisplayAttribution.canonicalSystemText
                        || activity.text == AgentChatItem.overseerCompactionRequestText
                )
            }
            for diagnostic in turn.summary?.recoveryDiagnostics ?? [] {
                record(diagnostic.id, diagnostic.sequenceIndex, input: false)
            }
        }
        for item in session.items {
            record(
                item.id,
                item.sequenceIndex,
                input: item.kind == .user
                    || item.text == AgentLaneUpdateDisplayAttribution.canonicalSystemText
                    || item.text == AgentChatItem.overseerCompactionRequestText
            )
        }
        guard let cutoffID = session.pendingHandoff.sourceItemID else { return !inputs.isEmpty }
        guard let cutoff = positions[cutoffID] else { return true }
        return inputs.values.contains { $0 > cutoff }
    }

    /// Sole M1 insertion point. Required-save sending before invoking any runner. Currency failure
    /// after acceptance withholds start; it is not a second fit/admission decision.
    func prepareProviderSwitchHandoverForSend(
        _ preparation: ProviderSwitchSendPreparation?, session: TabSession,
        stopFence: AgentRunStartStopFence
    ) async -> (user: String, initial: String)? {
        guard let preparation else { return nil }
        guard providerSwitchPreparationIsCurrent(preparation, session: session),
              stopFence.permitsStart(of: session),
              let payload = preparation.handoff.payload,
              let workspaceID = workspaceManager?.activeWorkspaceID
        else { return nil }
        session.pendingHandoff.providerSwitchDelivery = .sending
        session.pendingHandoff.isStagedForSend = true
        session.pendingHandoff.providerSwitchDispatch = nil
        let sending = session.pendingHandoff
        session.isDirty = true
        guard case .success = await flushSaveRequired(for: session.tabID, workspaceID: workspaceID) else {
            // Even a failed save may have committed. Never dispatch or claim a safe resend.
            if sessions[session.tabID] === session, session.currentRestorationBindingToken == preparation.binding,
               session.pendingHandoff == sending
            {
                session.pendingHandoff.isStagedForSend = false
            }
            return nil
        }
        guard sessions[session.tabID] === session, session.currentRestorationBindingToken == preparation.binding,
              session.pendingHandoff == sending else { return nil }
        guard !Task.isCancelled, stopFence.permitsStart(of: session),
              !session.runState.isActive, session.activeRunOwnership == nil,
              session.selectedAgent == preparation.agent, session.selectedModelRaw == preparation.model,
              session.isCodexComputerUseArmed == preparation.computerUseArmed,
              providerSwitchHistoryToolAllowed(session) == preparation.historyToolAllowed,
              providerSwitchInstructionStrings(session, includeSupplement: !preparation.inputAlreadyIncludesSupplement) == preparation.instructions
        else {
            // Only this VM path proves the runner has not been invoked. A failed ready re-save
            // restores sending; controller-specific Boolean/typed failures never enter this path.
            await providerSwitchRestoreReadyBeforeDispatch(session: session, sending: sending, workspaceID: workspaceID)
            return nil
        }
        return (payload + "\n\n" + preparation.augmentedInput, payload + "\n\n" + preparation.initialThreadInput)
    }

    func providerSwitchPreparationIsCurrent(_ preparation: ProviderSwitchSendPreparation, session: TabSession) -> Bool {
        sessions[session.tabID] === session && session.currentRestorationBindingToken == preparation.binding
            && session.selectedAgent == preparation.agent && session.selectedModelRaw == preparation.model
            && !session.runState.isActive && session.activeRunOwnership == nil
            && session.pendingHandoff == preparation.handoff
            && providerSwitchHistoryToolAllowed(session) == preparation.historyToolAllowed
            && session.isCodexComputerUseArmed == preparation.computerUseArmed
            && !Self.providerSwitchNeedsReview(session, excluding: preparation.acceptedInputID)
            && providerSwitchInstructionStrings(session, includeSupplement: !preparation.inputAlreadyIncludesSupplement) == preparation.instructions
    }

    func providerSwitchRestoreReadyBeforeDispatch(
        session: TabSession, sending: PendingHandoffState, workspaceID: UUID
    ) async {
        guard sessions[session.tabID] === session, session.pendingHandoff == sending else { return }
        let binding = session.currentRestorationBindingToken
        session.pendingHandoff.providerSwitchDelivery = .ready
        session.pendingHandoff.isStagedForSend = false
        let ready = session.pendingHandoff
        session.isDirty = true
        if case .failure = await flushSaveRequired(for: session.tabID, workspaceID: workspaceID),
           sessions[session.tabID] === session, session.currentRestorationBindingToken == binding,
           session.pendingHandoff == ready
        {
            session.pendingHandoff = sending
            session.pendingHandoff.isStagedForSend = false
            session.isDirty = true
        }
    }

    /// Called at the existing physical acquisition hook, not pipeline admission. Binding one exact
    /// logical dispatch is transient evidence; losing it on restart leaves durable sending inert.
    func providerSwitchAcquirePhysicalDispatch(session: TabSession, dispatchID: AgentSessionLinkPromptDispatchID) -> Bool {
        guard session.pendingHandoff.providerSwitchDelivery != nil else { return true }
        guard session.pendingHandoff.providerSwitchDelivery == .sending,
              session.pendingHandoff.isStagedForSend else { return false }
        let effectiveID = agentSessionLinkEffectiveDispatchID(for: session, dispatchID: dispatchID)
        let proof = ProviderSwitchPhysicalDispatch(dispatchID: effectiveID, binding: session.currentRestorationBindingToken)
        if let staged = session.pendingHandoff.providerSwitchDispatch { return staged == proof }
        session.pendingHandoff.providerSwitchDispatch = proof
        return true
    }

    /// Existing physical acceptance context is stronger than the legacy handoff Boolean (ACP's
    /// Boolean is earlier than its actual prompt return). Late/foreign contexts cannot clear M1.
    func providerSwitchRecordPhysicalAcceptance(session: TabSession, context: AgentSessionLinkDispatchContext?) {
        guard sessions[session.tabID] === session,
              let context, session.pendingHandoff.providerSwitchDelivery == .sending,
              session.pendingHandoff.isStagedForSend,
              let staged = session.pendingHandoff.providerSwitchDispatch,
              staged.dispatchID == context.dispatchID, staged.binding == session.currentRestorationBindingToken,
              let workspaceID = workspaceManager?.activeWorkspaceID else { return }
        let sending = session.pendingHandoff
        let binding = session.currentRestorationBindingToken
        session.pendingHandoff.clearAfterSend()
        let cleared = session.pendingHandoff
        let model = inputBarModelDisplayName(rawModel: session.selectedModelRaw, agentKind: session.selectedAgent)
        let text = "Handover sent to \(session.selectedAgent.displayName) / \(model)."
        session.appendItem(.system(text, sequenceIndex: session.nextSequenceIndex, recoveryDiagnostic: .init(
            reason: "providerSwitch", outcome: "sent", text: text
        )))
        session.isDirty = true
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            if case .failure = await flushSaveRequired(for: session.tabID, workspaceID: workspaceID),
               sessions[session.tabID] === session, session.currentRestorationBindingToken == binding,
               session.pendingHandoff == cleared
            {
                session.pendingHandoff = sending
                session.pendingHandoff.isStagedForSend = false
                session.pendingHandoff.providerSwitchDispatch = nil
                session.isDirty = true
                scheduleSave(for: session.tabID)
            }
        }
    }

    /// Item 3's idle-only transition reads existing owners, ignoring only its own exact claim/slot.
    /// No saved idle bit, waiting worker, binding transition or provider action is introduced here.
    func providerSwitchTransitionBlocker(
        _ session: TabSession, ownsComposerClaim: Bool = false, resolvingHandoff: PendingHandoffState? = nil
    ) -> String? {
        if session.pendingSelfWorktreeRelocation != nil { return SendBlocker.changingExecutionLocation.rawValue }
        if claudeCoordinator.hasPendingResumeTransfer(for: session) { return AgentSessionLinkSendFailure.targetBusy.rawValue }
        if session.selfCompactState.active != nil
            || session.selfCompactState.latest?.outcome == .recoveryRequired
            || session.selfCompactState.latest?.outcome == .deliveryUnknown
            || session.selfCompactState.latest?.noteDelivery == .deliveryUnknown
        {
            return SendBlocker.pendingSelfCompact.rawValue
        }
        var snapshot = Self.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: sessions[session.tabID] === session, isClosing: false,
            ignoresComposerSubmissionInFlight: ownsComposerClaim
        )
        if let resolvingHandoff, session.pendingHandoff == resolvingHandoff {
            snapshot.providerSwitchUnconfirmed = false
            snapshot.providerHandoverNeedsReview = false
        }
        if let failure = AgentSessionLinkDeliveryReadiness.failure(snapshot: snapshot) { return failure.wireResult }
        if session.pendingHandoff.hasPayload, session.pendingHandoff.providerSwitchDelivery == nil,
           !providerSwitchCanReplaceResumeRecovery(session) { return AgentSessionLinkSendFailure.targetBusy.rawValue }
        if !providerSwitchTerminalIsSettled(session) { return SendBlocker.terminalCommitInProgress.rawValue }
        return nil
    }

    /// Recognize only the existing app-authored recovery shape. Fork/unknown legacy slots remain
    /// protected. Item 3 may replace this slot through its ordinary claimed Review/apply transaction.
    func providerSwitchCanReplaceResumeRecovery(_ session: TabSession) -> Bool {
        guard session.pendingHandoff.providerSwitchDelivery == nil,
              !session.pendingHandoff.defersProviderLockUntilSend,
              let payload = session.pendingHandoff.payload else { return false }
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.hasPrefix("<forked_session source=\""),
              first.contains("\" delivery_id=\""), first.hasSuffix("\">"), lines.count > 2,
              lines[1].hasPrefix("You are continuing a session that was restarted after a native resume failed for "),
              lines[1].hasSuffix(". Use the recovered transcript below, plus any preserved thread context, to continue seamlessly."),
              lines.last == "</forked_session>" else { return false }
        return true
    }

    private func providerSwitchHistoryToolAllowed(_ session: TabSession, destination: AgentProviderKind? = nil) -> Bool {
        guard AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: "history", taskLabelKind: session.mcpControlContext?.taskLabelKind) else { return false }
        if (destination ?? session.selectedAgent).usesClaudeNativeRuntime {
            return !MCPIntegrationHelper.claudeDisallowedTools(for: .agentRun).contains("mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__history")
        }
        return true
    }

    private func providerSwitchReadReferenceIsCurrent(_ descriptor: ProviderSwitchCarrierDescriptor, session: TabSession, destination: AgentProviderKind? = nil) -> Bool {
        guard !descriptor.readableMarkers.isEmpty else { return true }
        guard let sessionID = session.activeAgentSessionID,
              providerSwitchHistoryToolAllowed(session, destination: destination)
        else { return false }
        let server = (destination ?? session.selectedAgent) == .grokBuild
            ? RepoPromptMCPServerConfiguration.grokBuildRuntimeServerName : MCPIntegrationHelper.repoPromptMCPServerName
        return descriptor.readableMarkers.allSatisfy { marker in
            guard let first = Int(marker.attributes["first"] ?? ""), let last = Int(marker.attributes["last"] ?? ""),
                  first >= 0, last >= first, last < session.transcript.turns.count else { return false }
            guard let reference = try? AgentProviderHandover.HistoryReference(server: server, sessionID: sessionID, historyAllowed: true, indicesMatch: true) else { return false }
            let expected = AgentProviderHandover.readableHistoryInstruction(first ... last, reference: reference)
            return marker.text.trimmingCharacters(in: .whitespacesAndNewlines) == expected
        }
    }
}

extension AgentModeViewModel {
    struct ProviderSwitchChoice {
        let mode: AgentProviderHandover.Mode
        var carrier: AgentProviderHandover.Carrier?
        var retainedPayload: String?
        var unavailable: String?
        var bytes: Int {
            retainedPayload?.utf8.count ?? carrier?.utf8Bytes ?? 0
        }

        var label: String {
            switch mode { case .history: "Full history"
            case .newestTurns: "Recent turns"
            case .summary: "Summary" }
        }

        var omissions: String? {
            if let retainedPayload, let descriptor = ProviderSwitchCarrierDescriptor(retainedPayload) {
                return descriptor.omissions.isEmpty ? nil : descriptor.omissions.joined(separator: ", ")
            }
            guard let carrier else { return nil }
            var parts: [String] = []
            if let range = carrier.omittedOlderTurns { parts.append("\(range.count) older turns") }
            if carrier.hasToolOutputOmission { parts.append("tool outputs") }
            if carrier.hasImageOmission { parts.append("images") }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    /// UI-only captured evidence. Neither its lifetime nor a completed projection authorizes a send.
    enum ProviderSwitchCursorParameterIntent {
        case select(ACPModelParameterSelection)
        case clear(ACPModelParameterIdentity)

        func applying(to selections: [ACPModelParameterSelection], model: String) -> [ACPModelParameterSelection]? {
            guard let parameters = ACPModelParameterResolver.parameterSet(providerID: .cursor, selectedModelRaw: model) else { return nil }
            switch self {
            case let .select(selection):
                guard selection.providerID == .cursor,
                      selection.identity.canonicalBaseModelRaw == ACPModelParameterIdentity.canonicalBaseModelRaw(model, providerID: .cursor),
                      let definition = parameters.definition(configID: selection.configID), definition.kind == selection.kind,
                      definition.choice(matching: selection.valueRaw) != nil else { return nil }
                return ACPModelParameterSelection.normalized(selections + [selection])
            case let .clear(identity):
                guard identity.providerID == .cursor,
                      identity.canonicalBaseModelRaw == ACPModelParameterIdentity.canonicalBaseModelRaw(model, providerID: .cursor),
                      parameters.definition(kind: identity.kind) != nil else { return nil }
                return selections.filter { $0.identity != identity }
            }
        }
    }

    struct ProviderSwitchPreview: Identifiable {
        let id: UUID
        let session: TabSession
        let binding: AgentSessionRestorationBindingToken?
        let workspaceID: UUID?
        let stopFence: AgentRunStartStopFence
        let sourceAgent: AgentProviderKind
        let sourceModel: String
        let sourceReasoningEffort: String?
        let sourceClaudeEffort: String?
        let source: AgentProviderHandover.Source
        let originalHandoff: PendingHandoffState
        let destination: AgentProviderKind
        let model: String
        let cursorParameterIntent: ProviderSwitchCursorParameterIntent?
        let sourceParameters: [ACPModelParameterSelection]
        var sourceRevision: Int
        var draftRevision: UInt64
        var instructions: [String]
        var cutoff: UUID?
        var projection: AgentProviderHandover.Projection?
        var budget: AgentProviderHandover.Budget?
        var choices: [ProviderSwitchChoice] = []
        var selected: AgentProviderHandover.Mode?
        var wordLimit: Int?
        var building = true
        var updated = false
        var failure: String?
        var generationItemID: UUID?
        var generationFinished = false
        var isReview: Bool {
            originalHandoff.providerSwitchDelivery != nil
        }

        var chosen: ProviderSwitchChoice? {
            choices.first { $0.mode == selected }
        }
    }

    struct ProviderSwitchMutation {
        let id: UUID
        let session: TabSession
        var allowsSave = false
    }

    @MainActor
    struct ProviderSwitchRollback {
        let agent: AgentProviderKind
        let model: String
        let effort: String?
        let claudeEffort: String?
        let parameters: [ACPModelParameterSelection]
        let providerID: String?
        let cleanup: ProviderConversationCleanupHandle?
        let codexID: String?
        let rollout: String?
        let codexModel: String?
        let codexEffort: String?
        let computerUseActivation: CodexComputerUseActivation?
        let computerUseArming: UUID?
        let context: TabSession.ProviderSwitchContextSnapshot
        let handoff: PendingHandoffState

        init(_ session: TabSession) {
            agent = session.selectedAgent
            model = session.selectedModelRaw
            effort = session.selectedReasoningEffortRaw
            claudeEffort = session.selectedClaudeEffortRaw
            parameters = session.acpModelParameterSelections
            providerID = session.providerSessionID
            cleanup = session.providerCleanupHandle
            codexID = session.codexConversationID
            rollout = session.codexRolloutPath
            codexModel = session.codexModel
            codexEffort = session.codexReasoningEffort
            computerUseActivation = session.pendingCodexComputerUseActivation
            computerUseArming = session.codexComputerUseArmingRequestID
            context = session.captureProviderSwitchContext()
            handoff = session.pendingHandoff
        }

        func restore(_ session: TabSession) {
            session.selectedAgent = agent
            session.selectedModelRaw = model
            session.selectedReasoningEffortRaw = effort
            session.selectedClaudeEffortRaw = claudeEffort
            session.acpModelParameterSelections = parameters
            session.providerSessionID = providerID
            session.providerCleanupHandle = cleanup
            session.codexConversationID = codexID
            session.codexRolloutPath = rollout
            session.codexModel = codexModel
            session.codexReasoningEffort = codexEffort
            session.pendingCodexComputerUseActivation = computerUseActivation
            session.codexComputerUseArmingRequestID = computerUseArming
            session.restoreProviderSwitchContext(context)
            session.pendingHandoff = handoff
            session.isDirty = true
        }
    }

    /// UI-only interception. The shared picker/MCP selection predicate deliberately stays locked.
    func providerSwitchPickerRequiresPreview(_ agent: AgentProviderKind, session: TabSession) -> Bool {
        session.pendingHandoff.providerSwitchDelivery != nil || !canSelectAgentInCurrentChat(agent)
    }

    @discardableResult
    func requestProviderSwitchSelection(agent: AgentProviderKind, model: String, tabID: UUID?, cursorParameterIntent: ProviderSwitchCursorParameterIntent? = nil) -> Bool {
        guard let tabID, let session = sessions[tabID], currentTabID == tabID else { return false }
        guard providerSwitchPickerRequiresPreview(agent, session: session) else { return false }
        Task { @MainActor [weak self] in
            guard let self, sessions[tabID] === session else { return }
            await openProviderSwitchPreview(agent: agent, model: model, tabID: tabID, cursorParameterIntent: cursorParameterIntent)
        }
        return true
    }

    @discardableResult
    func openProviderSwitchPreview(agent: AgentProviderKind, model: String, tabID: UUID, updated: Bool = false, cursorParameterIntent: ProviderSwitchCursorParameterIntent? = nil) async -> UUID? {
        guard providerSwitchMutation == nil, let session = sessions[tabID] else { return nil }
        let descriptor = session.pendingHandoff.providerSwitchDelivery != nil
            ? session.pendingHandoff.payload.flatMap(ProviderSwitchCarrierDescriptor.init) : nil
        guard let source = try? AgentProviderHandover.Source(
            provider: descriptor?.sourceProvider ?? session.selectedAgent.displayName,
            model: descriptor?.sourceModel ?? inputBarModelDisplayName(rawModel: session.selectedModelRaw, agentKind: session.selectedAgent)
        ) else { return nil }
        let destinationModel = model.isEmpty ? defaultModelRaw(for: agent) : model
        let preview = ProviderSwitchPreview(
            id: UUID(), session: session, binding: session.currentRestorationBindingToken,
            workspaceID: workspaceManager?.activeWorkspaceID,
            stopFence: AgentRunStartStopFence(session: session), sourceAgent: session.selectedAgent,
            sourceModel: session.selectedModelRaw, sourceReasoningEffort: session.selectedReasoningEffortRaw,
            sourceClaudeEffort: session.selectedClaudeEffortRaw, source: source, originalHandoff: session.pendingHandoff,
            destination: agent, model: destinationModel, cursorParameterIntent: cursorParameterIntent,
            sourceParameters: session.acpModelParameterSelections, sourceRevision: session.sourceItemsRevision,
            draftRevision: session.draftMutationGeneration,
            instructions: providerSwitchInstructionStrings(session, destination: agent), updated: updated
        )
        providerSwitchPreview = preview
        await buildProviderSwitchPreview(preview.id)
        // A caller may act only on the preview this request opened, never a later rebuild/owner.
        return preview.id
    }

    private func providerSwitchPreviewIsCurrent(_ preview: ProviderSwitchPreview, content: Bool = true) -> Bool {
        let session = preview.session
        return sessions[session.tabID] === session && session.currentRestorationBindingToken == preview.binding
            && workspaceManager?.activeWorkspaceID == preview.workspaceID
            && session.selectedAgent == preview.sourceAgent && session.selectedModelRaw == preview.sourceModel
            && session.selectedReasoningEffortRaw == preview.sourceReasoningEffort
            && session.selectedClaudeEffortRaw == preview.sourceClaudeEffort
            && session.pendingHandoff == preview.originalHandoff && preview.stopFence.permitsStart(of: session)
            && session.acpModelParameterSelections == preview.sourceParameters
            && (!content || (
                session.sourceItemsRevision == preview.sourceRevision
                    && session.draftMutationGeneration == preview.draftRevision
                    && providerSwitchInstructionStrings(session, destination: preview.destination) == preview.instructions
            ))
    }

    func providerSwitchDiscardBlocker(_ preview: ProviderSwitchPreview) -> String? {
        guard providerSwitchPreviewIsCurrent(preview) else { return AgentSessionLinkSendFailure.providerHandoverNeedsReview.rawValue }
        if providerSwitchMutation != nil { return AgentSessionLinkSendFailure.targetBusy.rawValue }
        return providerSwitchTransitionBlocker(preview.session, resolvingHandoff: preview.originalHandoff)
    }

    func providerSwitchPreviewBlocker(_ preview: ProviderSwitchPreview) -> String? {
        guard providerSwitchPreviewIsCurrent(preview) else { return AgentSessionLinkSendFailure.providerHandoverNeedsReview.rawValue }
        if providerSwitchMutation != nil { return AgentSessionLinkSendFailure.targetBusy.rawValue }
        if let intent = preview.cursorParameterIntent,
           preview.destination != .cursor || intent.applying(to: preview.sourceParameters, model: preview.model) == nil
        {
            return AgentSessionLinkSendFailure.providerHandoverNeedsReview.rawValue
        }
        if preview.isReview, preview.originalHandoff.payload.flatMap(ProviderSwitchCarrierDescriptor.init) == nil {
            return AgentSessionLinkSendFailure.providerHandoverNeedsReview.rawValue
        }
        return preview.failure ?? providerSwitchTransitionBlocker(preview.session, resolvingHandoff: preview.originalHandoff)
    }

    private func buildProviderSwitchPreview(_ id: UUID) async {
        guard var preview = providerSwitchPreview, preview.id == id else { return }
        let session = preview.session
        let transcript = session.transcript
        let items = session.items
        let nextSequence = session.nextSequenceIndex
        let state = session.runState
        let originalSlot = preview.originalHandoff
        let stale = Self.providerSwitchNeedsReview(session)
        let initial = await augmentUserMessageForProviderSend(
            session.draftText, attachments: session.pendingImageAttachments,
            taggedFileAttachments: session.pendingTaggedFileAttachments, agent: preview.destination,
            session: session, ignoresPendingHandoff: true
        )
        let composed = await buildInitialThreadMessageIfNeeded(tabID: session.tabID, session: session, initialMessage: initial)
        guard providerSwitchPreview?.id == id else { return }
        guard providerSwitchPreviewIsCurrent(preview) else {
            refreshProviderSwitchPreviewAfterDrift(preview)
            return
        }
        let budget = AgentProviderHandover.Budget(
            catalogWindow: providerSwitchCatalogWindow(agent: preview.destination, model: preview.model),
            instructions: preview.instructions, composedInput: "\n\n" + composed, isPreview: true
        )
        let server = preview.destination == .grokBuild ? RepoPromptMCPServerConfiguration.grokBuildRuntimeServerName : MCPIntegrationHelper.repoPromptMCPServerName
        let reference = try? session.activeAgentSessionID.flatMap {
            try AgentProviderHandover.HistoryReference(
                server: server,
                sessionID: $0,
                historyAllowed: providerSwitchHistoryToolAllowed(session, destination: preview.destination),
                indicesMatch: true
            )
        }
        let source = preview.source
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                var canonical = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                    existingTranscript: transcript, workingItems: items, terminalState: state,
                    nextSequenceIndex: nextSequence, policy: .canonical
                )
                let cutoff = (!stale && originalSlot.providerSwitchDelivery != nil) ? originalSlot.sourceItemID
                    : items.last?.id ?? canonical.turns.last?.allActivities.last?.id ?? canonical.turns.last?.request?.id
                var cutoffSequence: Int?
                if let cutoff {
                    cutoffSequence = items.first(where: { $0.id == cutoff })?.sequenceIndex
                    for turn in canonical.turns {
                        if turn.request?.id == cutoff { cutoffSequence = turn.request?.sequenceIndex }
                        if let activity = turn.allActivities.first(where: { $0.id == cutoff }) { cutoffSequence = activity.sequenceIndex }
                        if let diagnostic = turn.summary?.recoveryDiagnostics?.first(where: { $0.id == cutoff }) { cutoffSequence = diagnostic.sequenceIndex }
                    }
                }
                // Keep original ordinals. Remove only this pending switch's own post-cutoff notices;
                // completed older transitions remain ordinary retained events.
                let originalSequence = originalSlot.sourceItemID.flatMap { oldID in
                    items.first(where: { $0.id == oldID })?.sequenceIndex
                        ?? canonical.turns.compactMap { $0.request?.id == oldID ? $0.request?.sequenceIndex : $0.allActivities.first(where: { $0.id == oldID })?.sequenceIndex }.first
                }
                if let cutoffSequence {
                    canonical.turns = canonical.turns.filter { turn in
                        (turn.request?.sequenceIndex ?? turn.allActivities.first?.sequenceIndex ?? turn.summary?.recoveryDiagnostics?.first?.sequenceIndex ?? 0) <= cutoffSequence
                    }
                    for t in canonical.turns.indices {
                        for s in canonical.turns[t].responseSpans.indices {
                            canonical.turns[t].responseSpans[s].activities.removeAll { activity in
                                activity.sequenceIndex > cutoffSequence || (
                                    originalSlot.providerSwitchDelivery != nil
                                        && activity.recoveryDiagnostic?.reason == "providerSwitch"
                                        && activity.sequenceIndex > (originalSequence ?? -1)
                                )
                            }
                        }
                        canonical.turns[t].summary?.recoveryDiagnostics?.removeAll { diagnostic in
                            diagnostic.sequenceIndex > cutoffSequence || (
                                originalSlot.providerSwitchDelivery != nil
                                    && diagnostic.reason == "providerSwitch" && diagnostic.sequenceIndex > (originalSequence ?? -1)
                            )
                        }
                    }
                }
                let projection = try AgentProviderHandover.project(canonical)
                let full = AgentProviderHandover.history(projection, source: source, historyReference: reference)
                let recent = AgentProviderHandover.newestCompleteTurns(projection, source: source, historyReference: reference, budget: budget)
                let words = AgentProviderHandover.summaryWordLimit(for: projection, source: source, historyReference: reference, budget: budget)
                return (projection, full, recent, words, cutoff)
            }.value
            guard providerSwitchPreview?.id == id else { return }
            guard providerSwitchPreviewIsCurrent(preview) else {
                refreshProviderSwitchPreviewAfterDrift(preview)
                return
            }
            preview.projection = result.0
            preview.budget = budget
            preview.cutoff = result.4
            preview.wordLimit = preview.isReview ? nil : result.3
            preview.choices = [
                .init(mode: .history, carrier: result.1, unavailable: budget.fits(result.1) ? nil : "Full history doesn't fit."),
                .init(mode: .newestTurns, carrier: result.2, unavailable: result.2 == nil ? "the last turn alone doesn't fit" : nil),
                .init(mode: .summary, unavailable: preview.isReview ? AgentSessionLinkSendFailure.providerHandoverNeedsReview.rawValue : (result.3 == nil ? "no room for a summary" : nil))
            ]
            if !stale, let payload = originalSlot.payload, let descriptor = ProviderSwitchCarrierDescriptor(payload),
               providerSwitchReadReferenceIsCurrent(descriptor, session: session, destination: preview.destination),
               let mode = AgentProviderHandover.Mode(rawValue: descriptor.mode),
               let index = preview.choices.firstIndex(where: { $0.mode == mode }),
               AgentProviderHandover.estimate(payload) <= budget.remainingCarrierTokens,
               payload.utf8.count <= AgentProviderHandover.maximumBytes,
               mode != .summary || payload.utf8.count <= AgentProviderHandover.maximumSummaryBytes
            {
                preview.choices[index].retainedPayload = payload
                preview.choices[index].unavailable = nil
                preview.selected = mode
            } else if !preview.isReview, budget.fits(result.1) { preview.selected = .history }
            preview.building = false
            providerSwitchPreview = preview
        } catch {
            guard providerSwitchPreview?.id == id else { return }
            providerSwitchPreview?.building = false
            providerSwitchPreview?.failure = error.localizedDescription
        }
    }

    private func refreshProviderSwitchPreviewAfterDrift(_ preview: ProviderSwitchPreview) {
        providerSwitchPreview?.building = false
        providerSwitchPreview?.failure = AgentSessionLinkSendFailure.providerHandoverNeedsReview.rawValue
        guard sessions[preview.session.tabID] === preview.session,
              preview.session.currentRestorationBindingToken == preview.binding else { return }
        Task { @MainActor [weak self] in
            guard let self, providerSwitchPreview?.id == preview.id else { return }
            await openProviderSwitchPreview(agent: preview.destination, model: preview.model, tabID: preview.session.tabID, updated: true, cursorParameterIntent: preview.cursorParameterIntent)
        }
    }

    func providerSwitchPreviewDidChange(_ session: TabSession) {
        guard let preview = providerSwitchPreview, preview.session === session,
              !preview.building, preview.generationItemID == nil, providerSwitchMutation == nil,
              !providerSwitchPreviewIsCurrent(preview) else { return }
        providerSwitchPreview?.building = true
        Task { @MainActor [weak self] in
            guard let self, providerSwitchPreview?.id == preview.id else { return }
            await openProviderSwitchPreview(agent: preview.destination, model: preview.model, tabID: session.tabID, updated: true, cursorParameterIntent: preview.cursorParameterIntent)
        }
    }

    func cancelProviderSwitchPreview() {
        guard providerSwitchMutation == nil else { return }
        providerSwitchPreview = nil
    }

    func providerSwitchPayload(_ id: UUID, mode: AgentProviderHandover.Mode) async -> String? {
        guard let preview = providerSwitchPreview, preview.id == id,
              let choice = preview.choices.first(where: { $0.mode == mode }) else { return nil }
        if let payload = choice.retainedPayload { return payload }
        guard let carrier = choice.carrier else { return nil }
        let payload = await Task.detached(priority: .userInitiated) { AgentProviderHandover.render(carrier) }.value
        guard providerSwitchPreview?.id == id, providerSwitchPreviewIsCurrent(preview) else { return nil }
        return payload
    }

    private func providerSwitchHasExactOwner(_ session: TabSession) -> Bool {
        guard let id = session.activeAgentSessionID else { return false }
        let census = AgentSessionCarrierResolver.capture(
            windows: WindowStatesManager.shared.allWindows,
            sessionIDs: [id],
            includeRuntimeOwners: true
        )
        return census.isCurrent() && !census.ambiguousSessionIDs.contains(id)
            && !census.placementConflictSessionIDs.contains(id) && census.uniqueRuntimeOwners[id]?.session === session
    }

    private func providerSwitchClaim(_ preview: ProviderSwitchPreview) -> AgentComposerSubmitClaim? {
        guard providerSwitchPreviewIsCurrent(preview), providerSwitchHasExactOwner(preview.session),
              let target = makeComposerSubmitTarget(tabID: preview.session.tabID, session: preview.session) else { return nil }
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 0,
            noticeRevision: 0,
            rawDraftSnapshot: preview.session.draftText
        )
        guard case let .claimed(claim) = claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false) else { return nil }
        return claim
    }

    /// Explicit Generate is one ordinary source run. It never consumes the composer's workflow or
    /// attachments, never claims local authorship, and never applies or queues a provider switch.
    func generateProviderSwitchHandover(_ id: UUID) async {
        guard let preview = providerSwitchPreview, preview.id == id, !preview.isReview,
              let words = preview.wordLimit, let request = AgentProviderHandover.summaryRequest(wordLimit: words),
              providerSwitchPreviewBlocker(preview) == nil, let claim = providerSwitchClaim(preview) else { return }
        defer { releaseComposerSubmitClaim(claim) }
        let session = preview.session
        do { try await requireIdleProviderForWorktreeBindingTransition(session) } catch {
            providerSwitchPreview?.failure = error.localizedDescription
            return
        }
        guard providerSwitchPreview?.id == id, providerSwitchPreviewIsCurrent(preview), composerSubmitClaimIsCurrent(claim),
              providerSwitchTransitionBlocker(session, ownsComposerClaim: true) == nil,
              let workspaceID = workspaceManager?.activeWorkspaceID else { return }
        // Publish the exact row identity before dispatch, including synchronous fake completions.
        let row = AgentChatItem.user(request, sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        providerSwitchPreview?.generationItemID = row.id
        providerSwitchPreview?.selected = .summary
        session.isDirty = true
        guard case .success = await flushSaveRequired(for: session.tabID, workspaceID: workspaceID),
              composerSubmitClaimIsCurrent(claim), preview.stopFence.permitsStart(of: session),
              sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding
        else {
            if providerSwitchPreview?.id == id {
                providerSwitchPreview?.generationItemID = nil
                providerSwitchPreview?.choices[2].unavailable = AgentSessionLinkSendFailure.persistenceIndeterminate.rawValue
            }
            return
        }
        #if DEBUG
            if let test_providerSwitchGeneration {
                await test_providerSwitchGeneration(session, row.id, request)
                providerSwitchGenerationSettled(session)
                return
            }
        #endif
        let outcome = AgentRunStartOutcomeRecorder()
        _ = await startAgentRun(
            tabID: session.tabID,
            initialMessage: request,
            directStartOptions: .init(ignoresPendingHandoff: true, stopFence: preview.stopFence),
            startOutcome: outcome
        )
        if !outcome.outcome.didStart {
            providerSwitchPreview?.generationItemID = nil
            providerSwitchPreview?.choices[2].unavailable = AgentSessionLinkSendFailure.targetNotIdle.rawValue
        } else { agentSessionLinkClearWaitingOnAfterAcceptedTurn(session) }
    }

    func providerSwitchGenerationSettled(_ session: TabSession) {
        guard let preview = providerSwitchPreview, preview.session === session,
              sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding,
              workspaceManager?.activeWorkspaceID == preview.workspaceID,
              session.selectedAgent == preview.sourceAgent, session.selectedModelRaw == preview.sourceModel,
              session.pendingHandoff == preview.originalHandoff,
              let rowID = preview.generationItemID, !preview.generationFinished else { return }
        refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
        guard let turn = session.transcript.turns.first(where: { $0.request?.id == rowID }),
              turn.completedAt != nil, !(turn.terminalState?.isActive ?? false) else { return }
        providerSwitchPreview?.generationFinished = true
        let usedTools = !AgentProviderHandover.isZeroEffectfulToolControlTurn(turn)
        let conclusion = turn.allActivities.first { $0.id == turn.conclusionActivityID }?.text
        let settledRevision = session.sourceItemsRevision
        Task { @MainActor [weak self] in
            guard let self, providerSwitchPreview?.id == preview.id,
                  sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding,
                  workspaceManager?.activeWorkspaceID == preview.workspaceID,
                  session.selectedAgent == preview.sourceAgent, session.selectedModelRaw == preview.sourceModel,
                  session.pendingHandoff == preview.originalHandoff else { return }
            await openProviderSwitchPreview(agent: preview.destination, model: preview.model, tabID: session.tabID, updated: true, cursorParameterIntent: preview.cursorParameterIntent)
            guard var current = providerSwitchPreview, current.session === session,
                  current.originalHandoff == preview.originalHandoff, !current.isReview,
                  session.sourceItemsRevision == settledRevision, current.binding == preview.binding,
                  let projection = current.projection, let budget = current.budget else { return }
            if usedTools {
                current.choices[2].unavailable = "the model used tools"
            } else if turn.terminalState == .completed, let conclusion, !conclusion.isEmpty,
                      let carrier = try? AgentProviderHandover.summary(
                          conclusion,
                          of: projection,
                          source: current.source,
                          historyReference: current.choices[0].carrier?.historyReference
                      )
            {
                current.choices[2].carrier = budget.fits(carrier) ? carrier : nil
                current.choices[2].unavailable = budget.fits(carrier) ? nil : "the summary is too large"
                if budget.fits(carrier) { current.selected = .summary }
            } else { current.choices[2].unavailable = session.items.last(where: { $0.kind == .error })?.text ?? AgentSessionLinkSendFailure.targetNotIdle.rawValue }
            providerSwitchPreview = current
        }
    }

    /// One claimed, same-identity mutation for Switch/Replace and Discard. Native retirement is
    /// irreversible; rollback restores resumable references, never resurrects shutdown controllers.
    @discardableResult
    func applyProviderSwitch(_ id: UUID, discard: Bool = false) async -> Bool {
        guard let preview = providerSwitchPreview, preview.id == id, !preview.building,
              preview.generationItemID == nil,
              (discard ? providerSwitchDiscardBlocker(preview) : providerSwitchPreviewBlocker(preview)) == nil,
              discard ? preview.isReview : (preview.chosen != nil && preview.chosen?.unavailable == nil),
              let claim = providerSwitchClaim(preview), let workspaceID = workspaceManager?.activeWorkspaceID else { return false }
        defer { releaseComposerSubmitClaim(claim) }
        let session = preview.session
        let rollback = ProviderSwitchRollback(session)
        let mutation = ProviderSwitchMutation(id: UUID(), session: session)
        providerSwitchMutation = mutation
        defer { if providerSwitchMutation?.id == mutation.id { providerSwitchMutation = nil } }
        func current() -> Bool {
            composerSubmitClaimIsCurrent(claim) && providerSwitchMutation?.id == mutation.id
                && providerSwitchPreview?.id == id && providerSwitchPreviewIsCurrent(preview)
                && workspaceManager?.activeWorkspaceID == workspaceID && providerSwitchHasExactOwner(session)
                && providerSwitchTransitionBlocker(session, ownsComposerClaim: true, resolvingHandoff: preview.originalHandoff) == nil
        }
        var noticeID: UUID?
        var phase: RequiredSavePhase = .beforeWrite
        do {
            guard current() else { return false }
            let payload = discard ? nil : await providerSwitchPayload(id, mode: preview.selected ?? .history)
            guard discard || payload != nil, current() else { return false }
            if !discard {
                try await requireIdleProviderForWorktreeBindingTransition(session)
                guard current() else { return false }
                await retireProviderContextForProviderSwitch(session)
                guard current() else {
                    if sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding,
                       composerSubmitClaimIsCurrent(claim), session.pendingHandoff == preview.originalHandoff,
                       session.selectedAgent == preview.sourceAgent, session.selectedModelRaw == preview.sourceModel,
                       session.selectedReasoningEffortRaw == preview.sourceReasoningEffort,
                       session.selectedClaudeEffortRaw == preview.sourceClaudeEffort,
                       session.acpModelParameterSelections == preview.sourceParameters
                    {
                        rollback.restore(session)
                        updateBindingsFromSession(session)
                    }
                    return false
                }
                // No suspension is permitted between clearing any native family and staging context.
                clearProviderContextForProviderSwitch(session)
                session.selectedAgent = preview.destination
                session.selectedModelRaw = preview.model
                if preview.destination.usesClaudeTooling, let effort = ClaudeModelSpecifier(raw: preview.model).explicitEffortLevel {
                    session.selectedClaudeEffortRaw = effort.rawValue
                }
                session.selectedReasoningEffortRaw = nil
                if let intent = preview.cursorParameterIntent,
                   let selections = intent.applying(to: preview.sourceParameters, model: preview.model)
                {
                    // The model-menu variant is intent until this synchronous Switch staging.
                    // Use existing parameter persistence; never mutate on open or Cancel.
                    let writes: [ACPModelParameterSelection] = switch intent {
                    case let .select(selection): [selection]
                    case let .clear(identity): preview.sourceParameters.filter { $0.identity == identity }
                    }
                    session.recordAcceptedACPModelParameterWrite(writes)
                    session.acpModelParameterSelections = selections
                }
                session.pendingHandoff = .init(
                    payload: payload,
                    createdAt: Date(),
                    sourceItemID: preview.cutoff,
                    providerSwitchDelivery: .ready
                )
                agentSessionLinkReoweSupplementForRebuiltProviderContext(for: session)
            } else { session.pendingHandoff.clearAfterSend() }
            let text = discard ? "Pending handover discarded; chat history unchanged."
                : "Provider changed from \(preview.source.provider) / \(preview.source.model) to \(preview.destination.displayName) / \(inputBarModelDisplayName(rawModel: preview.model, agentKind: preview.destination)); handover: \(preview.chosen?.label ?? "Full history")."
            let notice = AgentChatItem.system(
                text,
                sequenceIndex: session.nextSequenceIndex,
                recoveryDiagnostic: .init(reason: "providerSwitch", outcome: discard ? "discarded" : "applied", text: text)
            )
            noticeID = notice.id
            session.appendItem(notice)
            session.isDirty = true
            providerSwitchMutation?.allowsSave = true
            updateBindingsFromSession(session)
            let staged = session.pendingHandoff
            #if DEBUG
                test_providerSwitchBeforeSave?(session)
            #endif
            let result = await flushSaveRequired(for: session.tabID, workspaceID: workspaceID, observingSavePhase: { phase = $0 })
            guard case .success = result else {
                if phase == .beforeWrite, sessions[session.tabID] === session,
                   session.currentRestorationBindingToken == preview.binding, composerSubmitClaimIsCurrent(claim),
                   session.pendingHandoff == staged
                {
                    rollback.restore(session)
                    if let index = session.items.firstIndex(where: { $0.id == noticeID }) { _ = session.removeItem(at: index) }
                    for t in session.transcript.turns.indices {
                        for s in session.transcript.turns[t].responseSpans.indices {
                            session.transcript.turns[t].responseSpans[s].activities.removeAll { $0.id == noticeID }
                        }
                        session.transcript.turns[t].summary?.recoveryDiagnostics?.removeAll { $0.id == noticeID }
                    }
                    refreshDerivedTranscriptState(for: session)
                }
                if case let .failure(failure) = result { providerSwitchPreview?.failure = failure.message }
                updateBindingsFromSession(session)
                return false
            }
            guard sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding,
                  composerSubmitClaimIsCurrent(claim), session.pendingHandoff == staged else { return false }
            providerSwitchPreview = nil
            updateBindingsFromSession(session)
            return true
        } catch {
            if sessions[session.tabID] === session, session.currentRestorationBindingToken == preview.binding,
               composerSubmitClaimIsCurrent(claim), phase == .beforeWrite { rollback.restore(session) }
            providerSwitchPreview?.failure = error.localizedDescription
            updateBindingsFromSession(session)
            return false
        }
    }
}

/// Parse persisted M1 as data, never instructions. No external entity/network resolution.
private final class ProviderSwitchCarrierDescriptor: NSObject, XMLParserDelegate {
    struct Marker {
        let attributes: [String: String]
        var text: String
    }

    private(set) var mode = ""
    private(set) var sourceProvider = ""
    private(set) var sourceModel = ""
    private(set) var readableMarkers: [Marker] = []
    private(set) var omissions: [String] = []
    private var depth = 0
    private var markerDepth: Int?
    private var validRoot = false

    init?(_ payload: String) {
        super.init()
        guard !payload.contains("<!DOCTYPE"), !payload.contains("<!ENTITY") else { return nil }
        let parser = XMLParser(data: Data(payload.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse(), validRoot else { return nil }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth == 1 {
            mode = attributes["mode"] ?? ""
            sourceProvider = attributes["source_provider"] ?? ""
            sourceModel = attributes["source_model"] ?? ""
            validRoot = elementName == "repoprompt_provider_handover" && attributes["version"] == "1"
                && ["history", "newest_turns", "summary"].contains(mode)
                && attributes["source_provider"]?.isEmpty == false && attributes["source_model"]?.isEmpty == false
        }
        if elementName == "omitted" {
            switch attributes["kind"] {
            case "older_turns":
                if let first = Int(attributes["first"] ?? ""), let last = Int(attributes["last"] ?? ""), first >= 0, last >= first {
                    omissions.append("\(last - first + 1) older turns")
                }
            case "tool_output": omissions.append("tool outputs")
            case "image": omissions.append("images")
            default: break
            }
        }
        if elementName == "omitted", attributes["availability"] == "readable" {
            readableMarkers.append(.init(attributes: attributes, text: ""))
            markerDepth = depth
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if markerDepth != nil, !readableMarkers.isEmpty { readableMarkers[readableMarkers.count - 1].text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if markerDepth == depth { markerDepth = nil }
        depth -= 1
    }
}
