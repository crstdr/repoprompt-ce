import Foundation

struct AgentQuietTranscriptDisplayCache {
    struct Key: Equatable {
        let session: ObjectIdentifier
        let binding: AgentSessionRestorationBindingToken?
        let tabID: UUID?
        let presentationRevision: Int
        let maskRevision: UInt64
    }

    let key: Key
    let result: AgentTranscriptProjectionBuilder.DisplayMaskResult
}

@MainActor
extension AgentModeViewModel {
    private func quietDisplayKey(_ session: AgentTabSession, base: AgentTranscriptPresentationSnapshot) -> AgentQuietTranscriptDisplayCache.Key {
        .init(
            session: ObjectIdentifier(session),
            binding: session.currentRestorationBindingToken,
            tabID: base.tabID,
            presentationRevision: base.revision,
            maskRevision: session.quietLedger.displayMaskRevision
        )
    }

    /// Owning UI sync only. Snapshot getters never populate/invalidate this cache.
    @discardableResult
    func prepareQuietTranscriptDisplay() -> Bool {
        guard let session = activeSession else { return true }
        let base = scopedActiveTranscriptPresentation(for: currentTabID)
        let key = quietDisplayKey(session, base: base)
        guard session.quietTranscriptDisplayCache?.key != key else { return true }
        // Inline run-state publication can reenter UI sync while the terminal barrier owns the
        // actor. Its existing phase-end callback requests the scoped refresh after that phase.
        if session.terminalCommitInProgress, !session.quietLedger.hiddenSourceIDs.isEmpty {
            session.quietTranscriptDisplayCache = nil
            return false
        }
        let result = AgentTranscriptProjectionBuilder.maskForLocalDisplay(
            base, archivedBlocks: session.archivedTranscriptSnapshot.blocks, hiddenSourceIDs: session.quietLedger.hiddenSourceIDs
        )
        session.quietTranscriptDisplayCache = .init(key: key, result: result)
        #if DEBUG
            perfRecorder.increment("quiet.display.cache.build", tabID: session.tabID)
            perfRecorder.event("quiet.display.work", tabID: session.tabID, fields: [
                "blocks": String(result.blockVisits), "rows": String(result.rowVisits), "anchors": String(result.anchorVisits)
            ])
        #endif
        return true
    }

    func makeTranscriptUISnapshot() -> AgentTranscriptUISnapshot {
        let tabID = currentTabID
        let session = activeSession
        let paneInput = transcriptPaneInput(tabID: tabID, session: session)
        let scopedBase = scopedActiveTranscriptPresentation(for: tabID)
        let cached = session.flatMap { session in
            session.quietTranscriptDisplayCache.flatMap { $0.key == quietDisplayKey(session, base: scopedBase) ? $0.result : nil }
        }
        let scopedPresentation = cached?.presentation ?? scopedBase
        // Existing rows/history survive a rejected operation, not a content-identity replacement.
        let canPresentExistingTranscript = paneInput.content?.canPresentExistingTranscript(for: paneInput.target) == true
        let contentScopeMismatches = activeTranscriptContentScopeMismatches(paneInput.target)
        let presentation = contentScopeMismatches && !canPresentExistingTranscript
            ? AgentTranscriptPresentationSnapshot(revision: scopedPresentation.revision)
            : scopedPresentation
        return AgentTranscriptUISnapshot(
            currentTabID: tabID,
            presentation: presentation,
            isHydrated: isActiveTranscriptPresentationHydrated(for: tabID),
            presentationRevision: activeTranscriptPresentationRevision(for: tabID),
            displayMaskRevision: session?.quietLedger.displayMaskRevision ?? 0,
            followBindingState: activeTranscriptFollowBindingState,
            activeSessionLoadInProgressTabID: activeSessionLoadInProgressTabID,
            activeBashLiveExecutionByItemID: activeBashLiveExecutionByItemID,
            runtimeFooterByItemID: agentMessageRuntimeFooters(for: tabID),
            fallbackFollowArmingState: session?.transcriptAutoFollowArmingState ?? .armed,
            archivedBlocks: canPresentExistingTranscript ? cached?.archivedBlocks ?? session?.archivedTranscriptSnapshot.blocks ?? [] : [],
            panePresentation: AgentTranscriptPanePresentation.resolve(paneInput)
                // Nil rejects stale candidate evidence; it never authorizes welcome (§4.5).
                ?? .restoring,
            paneTarget: paneInput.target
        )
    }
}
