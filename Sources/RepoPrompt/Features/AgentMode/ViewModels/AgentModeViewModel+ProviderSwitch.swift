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
    func providerSwitchInstructionStrings(_ session: TabSession, includeSupplement: Bool = true) -> [String] {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: session.selectedAgent, taskLabelKind: session.mcpControlContext?.taskLabelKind,
            codeMapsDisabled: GlobalSettingsStore.shared.globalCodeMapsDisabled()
        )
        let packagedPrompt = session.selectedAgent.usesClaudeNativeRuntime
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
        guard session.pendingHandoff.providerSwitchDelivery == .ready else { return false }
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

    private func providerSwitchHistoryToolAllowed(_ session: TabSession) -> Bool {
        guard AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: "history", taskLabelKind: session.mcpControlContext?.taskLabelKind) else { return false }
        if session.selectedAgent.usesClaudeNativeRuntime {
            return !MCPIntegrationHelper.claudeDisallowedTools(for: .agentRun).contains("mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__history")
        }
        return true
    }

    private func providerSwitchReadReferenceIsCurrent(_ descriptor: ProviderSwitchCarrierDescriptor, session: TabSession) -> Bool {
        guard !descriptor.readableMarkers.isEmpty else { return true }
        guard let sessionID = session.activeAgentSessionID,
              providerSwitchHistoryToolAllowed(session)
        else { return false }
        let server = session.selectedAgent == .grokBuild
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

/// Parse persisted M1 as data, never instructions. No external entity/network resolution.
private final class ProviderSwitchCarrierDescriptor: NSObject, XMLParserDelegate {
    struct Marker {
        let attributes: [String: String]
        var text: String
    }

    private(set) var mode = ""
    private(set) var readableMarkers: [Marker] = []
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
            validRoot = elementName == "repoprompt_provider_handover" && attributes["version"] == "1"
                && ["history", "newest_turns", "summary"].contains(mode)
                && attributes["source_provider"]?.isEmpty == false && attributes["source_model"]?.isEmpty == false
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
