import Foundation
import RepoPromptDomainRuntime

/// Window-local seam between the authoritative link inventory and the provider dispatch adapters.
///
/// The adapters (Codex start/steer/fallback, Claude native, Claude/generic headless, ACP prompt and
/// active steering, waiting-instruction continuation) all reduce to two synchronous MainActor calls:
/// compose immediately before the physical dispatch, acknowledge at the provider's acceptance
/// signal. Keeping the actor hop out of the dispatch path matters — every one of those sites runs
/// while a user turn is already committed, and none of them may block on the domain actor.
/// The authoritative outbound inventory published to one exact incarnation.
///
/// The endpoint is stored alongside the value rather than implied by the map key: an in-place rebind
/// keeps the session UUID while advancing the binding generations, so a UUID-keyed read alone would
/// hand a fresh incarnation the targets the previous one was granted.
struct AgentSessionLinkPublishedPromptInventory: Equatable {
    let endpoint: DomainAgentSessionLinkEndpointIdentity
    let inventory: AgentSessionLinkPromptInventory
}

/// One endpoint's publication fence, raised for the duration of *every* overlapping membership write.
///
/// The fence is shared, not owned: activations for the same observer can overlap (the Add sheet's
/// `isWorking` single-flight is per-view `@State`, so dismissing and reopening it mid-flight yields a
/// fresh control), and it must stay raised until the last participant has settled. A fence that only
/// the newest writer could lower let a *rejected* newest writer restore the pre-hop inventory over a
/// sibling that had already committed but not yet published — the same false terminal notice the
/// fence exists to prevent, reachable in the other release order.
struct AgentSessionLinkPromptInventoryHold: Equatable {
    /// Every writer that has raised this fence and not yet settled. While it is non-empty the
    /// endpoint stays withheld, so no release order can expose a partially-settled membership.
    let outstanding: Set<UInt64>
    /// What this endpoint had published when the *first* participant fenced it, restored only if no
    /// participant commits. `nil` when the endpoint had nothing published, which is itself the
    /// correct state to return to.
    let retracted: AgentSessionLinkPromptInventory?
    /// The highest-`linkSetRevision` inventory reported by a participant that committed, or `nil`
    /// while none has. This is what the last release publishes: it is a comparison of values each
    /// read inside the body that committed it, so it does not depend on which continuation resumes
    /// first.
    let committed: AgentSessionLinkPromptInventory?
}

/// One incarnation's claim inputs: what it may be told, and the epoch that scopes the telling.
struct AgentSessionLinkPromptContext: Equatable {
    let epoch: AgentSessionLinkPromptEpoch
    let inventory: AgentSessionLinkPromptInventory
    /// This session's latest published passive status queue, unfiltered.
    ///
    /// Deliberately handed over raw rather than pre-screened here: every condition that may join a
    /// batch to a dispatch — endpoint match, eligibility, enablement, deliverability, revision match,
    /// and grant membership — lives in one truth table inside the claim store, where it is testable
    /// without a view model.
    let passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot?

    init(
        epoch: AgentSessionLinkPromptEpoch,
        inventory: AgentSessionLinkPromptInventory,
        passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot? = nil
    ) {
        self.epoch = epoch
        self.inventory = inventory
        self.passiveNotices = passiveNotices
    }
}

extension AgentModeViewModel {
    // MARK: - Inventory publication

    /// Stores the authoritative outbound inventory for one exact endpoint incarnation.
    ///
    /// The ordinary publication path: the runtime bridge's projection refresh, which rebuilds this
    /// alongside Oversee's UI rows. The two are emitted from the same pass, but they are *not* one
    /// atomic update — see `agentSessionLinkWithholdPromptInventory(for:)`: a membership write fences
    /// this value and republishes it from the write's own disposition, ahead of the refresh that
    /// later rebuilds the pill. For a brief interval the prompt inventory can therefore be newer than
    /// the pill. That direction is deliberate: the pill lagging costs one stale row, whereas the
    /// prompt lagging costs a false statement to a model.
    func agentSessionLinkPublishPromptInventory(
        _ inventory: AgentSessionLinkPromptInventory,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        agentSessionLinkWritePromptInventory(inventory, to: endpoint, releasing: nil)
    }

    /// Applies one publication, subject to the two rules every publisher shares.
    ///
    /// 1. **A fenced endpoint stays fenced.** An ordinary publication carries an inventory read from
    ///    the authority at some earlier instant; if a membership write raised the fence after that
    ///    read, the value in hand is already known to be about to stop being true. Only the write
    ///    that raised a fence may publish through it.
    /// 2. **No incarnation moves backwards.** `linkSetRevision` advances on every membership change
    ///    for this observer and is never reset, so a lower revision for the same endpoint is stale by
    ///    construction. Equal revisions are accepted: display names refresh without a membership
    ///    change, and those must still land.
    ///
    /// Rule 2 protects an *already published* value from a stale write, which is exactly what it
    /// cannot do while the endpoint is withheld: the retraction removed the entry there is nothing
    /// left to compare against. Overlapping writes are therefore not made safe here — they are made
    /// safe by the fence outliving all of them and by the highest-revision comparison the hold itself
    /// carries (see `AgentSessionLinkPromptInventoryHold.committed`). Both are comparisons; neither
    /// assumes a resumption order.
    private func agentSessionLinkWritePromptInventory(
        _ inventory: AgentSessionLinkPromptInventory,
        to endpoint: DomainAgentSessionLinkEndpointIdentity,
        releasing token: UInt64?
    ) {
        if token == nil, agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint] != nil { return }
        let existing = agentSessionLinkPromptInventoryBySessionID[endpoint.sessionID]
        if let existing,
           existing.endpoint == endpoint,
           existing.inventory.linkSetRevision > inventory.linkSetRevision
        {
            return
        }
        let published = AgentSessionLinkPublishedPromptInventory(
            endpoint: endpoint,
            inventory: inventory
        )
        if existing == published { return }
        agentSessionLinkPromptInventoryBySessionID[endpoint.sessionID] = published
        // An accepted publication names the incarnation this session UUID currently *is*, so a passive
        // queue filed under that UUID for any other incarnation belongs to a retired one. Collected
        // here rather than in the prune sweep because a rebind keeps the UUID alive: the sweep would
        // never drop it, and the replacement incarnation starts with no queue of its own to overwrite
        // it with.
        if let passive = agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID],
           passive.observerEndpoint != endpoint
        {
            agentSessionLinkPassiveNoticesBySessionID.removeValue(forKey: endpoint.sessionID)
        }
    }

    /// Stores one exact incarnation's passive status-notice queue.
    ///
    /// Endpoint-matched twice, because the snapshot is the input to an agent-facing payload: it has
    /// to name the incarnation it was reduced for, and that incarnation has to still be the one this
    /// tab holds. A rebound tab reusing the same session UUID is therefore refused the previous
    /// incarnation's queue rather than inheriting it.
    ///
    /// Queue revisions are monotonic within one epoch, so a late publication carrying an older
    /// revision of the same epoch is dropped rather than allowed to resurrect entries a receipt has
    /// already removed.
    func agentSessionLinkPublishPassiveStatusNotices(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard snapshot.observerEndpoint == endpoint,
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint
        else {
            return
        }
        if let existing = agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID],
           existing.observerEndpoint == endpoint,
           existing.queueEpoch == snapshot.queueEpoch,
           existing.queueRevision > snapshot.queueRevision
        {
            return
        }
        agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID] = snapshot
    }

    /// Fences one exact incarnation's prompt inventory and retracts its published value.
    ///
    /// The bridge raises this immediately before an authority membership write and lowers it from the
    /// write's own disposition. While it is up, `agentSessionLinkPromptContext` fails its existing
    /// `published` guard and every claim returns `nil` — no new suppression concept, and in
    /// particular nothing that reaches `AgentSessionLinkPromptSupplementDecision`, whose
    /// `isEligibilitySuppressed` stays the sole classifier of *why* an inventory is empty. A window
    /// with no published inventory is not an empty inventory; it is the absence of an answer, and the
    /// supplement simply stays owed to the next dispatch.
    ///
    /// Retraction alone is not the fence, which is the correction this round makes: the map is
    /// repopulated by whichever publisher runs next, and the ordinary projection refresh can be
    /// suspended on the authority hop holding an inventory it read *before* the retraction. Removing
    /// the value fences the reader; the recorded hold is what fences the writers.
    ///
    /// Endpoint-matched before retracting: a stale bridge call naming a superseded incarnation must
    /// not take the current one's inventory. The fence itself is still recorded for the named
    /// endpoint — that endpoint is the one about to gain a grant, and it is the one whose stale
    /// publication would lie.
    func agentSessionLinkWithholdPromptInventory(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UInt64 {
        agentSessionLinkNextPromptInventoryHoldToken &+= 1
        let token = agentSessionLinkNextPromptInventoryHoldToken
        // An overlapping write *joins* the existing fence rather than replacing it: the baseline to
        // restore is still the value actually published before any of them started, and a sibling's
        // already-recorded commit must not be forgotten by the writer that arrives after it.
        if let existing = agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint] {
            agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint] = AgentSessionLinkPromptInventoryHold(
                outstanding: existing.outstanding.union([token]),
                retracted: existing.retracted,
                committed: existing.committed
            )
            return token
        }
        var retracted: AgentSessionLinkPromptInventory?
        if let published = agentSessionLinkPromptInventoryBySessionID[endpoint.sessionID],
           published.endpoint == endpoint
        {
            retracted = published.inventory
            agentSessionLinkPromptInventoryBySessionID.removeValue(forKey: endpoint.sessionID)
        }
        agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint] = AgentSessionLinkPromptInventoryHold(
            outstanding: [token],
            retracted: retracted,
            committed: nil
        )
        return token
    }

    /// Settles `token`'s participation in the fence, lowering it only once every participant has
    /// settled.
    ///
    /// `inventory` is the membership the write itself observed, read inside the same actor-isolated
    /// body that committed it; `nil` means the write did not commit.
    ///
    /// The last release decides what the endpoint publishes, and it decides it by revision, not by
    /// arrival: the highest-revision inventory any participant committed, or — if none committed —
    /// the value the first withhold retracted. That is what makes both release orders safe. A
    /// rejection landing *after* a sibling's commit cannot restore the pre-hop inventory, because the
    /// sibling's commit is recorded in the hold; a rejection landing *before* it cannot either,
    /// because the fence stays up and the sibling's own release publishes through it. Neither path
    /// assumes which continuation the MainActor resumes first — Swift guarantees no such order for
    /// resumptions after separate `await`s.
    ///
    /// A release whose token the fence no longer tracks (the endpoint was pruned mid-write, or the
    /// same token is released twice) still publishes a committed inventory, which is exact as of its
    /// own commit and bounded by rule 2 of `agentSessionLinkWritePromptInventory`. It restores
    /// nothing: with no fence left to speak for, its baseline is not the current truth.
    func agentSessionLinkReleasePromptInventoryHold(
        _ token: UInt64?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        publishing inventory: AgentSessionLinkPromptInventory?
    ) {
        guard let token else { return }
        guard let hold = agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint],
              hold.outstanding.contains(token)
        else {
            if let inventory {
                agentSessionLinkWritePromptInventory(inventory, to: endpoint, releasing: token)
            }
            return
        }
        var outstanding = hold.outstanding
        outstanding.remove(token)
        let committed = agentSessionLinkNewerCommittedInventory(hold.committed, inventory)
        guard outstanding.isEmpty else {
            agentSessionLinkPromptInventoryHoldsByEndpoint[endpoint] = AgentSessionLinkPromptInventoryHold(
                outstanding: outstanding,
                retracted: hold.retracted,
                committed: committed
            )
            return
        }
        agentSessionLinkPromptInventoryHoldsByEndpoint.removeValue(forKey: endpoint)
        guard let value = committed ?? hold.retracted else { return }
        agentSessionLinkWritePromptInventory(value, to: endpoint, releasing: token)
    }

    /// The committed candidate the fence should carry forward, by revision.
    ///
    /// Ties go to `new`: equal revisions mean the same membership, and the later report of it is the
    /// one whose display names are current — the same reason rule 2 accepts an equal revision.
    private func agentSessionLinkNewerCommittedInventory(
        _ existing: AgentSessionLinkPromptInventory?,
        _ new: AgentSessionLinkPromptInventory?
    ) -> AgentSessionLinkPromptInventory? {
        guard let new else { return existing }
        guard let existing else { return new }
        return new.linkSetRevision >= existing.linkSetRevision ? new : existing
    }

    /// Drops prompt state for sessions whose live binding disappeared.
    ///
    /// A re-opened session reusing the same UUID is a new incarnation: it must start from "never
    /// acknowledged" so it is taught oversight again rather than inheriting a stale acknowledgement.
    func agentSessionLinkPrunePromptState(liveSessionIDs: Set<UUID>) {
        for sessionID in agentSessionLinkPromptInventoryBySessionID.keys
            where !liveSessionIDs.contains(sessionID)
        {
            agentSessionLinkPromptInventoryBySessionID.removeValue(forKey: sessionID)
        }
        // A fence outlives its writer only if the endpoint died mid-write, where the claim path
        // already fails closed on endpoint resolution. Dropping it keeps a dead endpoint from
        // permanently withholding a supplement from a session that reuses its slot.
        for endpoint in agentSessionLinkPromptInventoryHoldsByEndpoint.keys
            where !liveSessionIDs.contains(endpoint.sessionID)
        {
            agentSessionLinkPromptInventoryHoldsByEndpoint.removeValue(forKey: endpoint)
        }
        // Pruned on the same schedule as the inventory it is joined to: a queue left behind for a
        // dead session would be matched against a later incarnation's revision by coincidence rather
        // than by proof.
        for sessionID in agentSessionLinkPassiveNoticesBySessionID.keys
            where !liveSessionIDs.contains(sessionID)
        {
            agentSessionLinkPassiveNoticesBySessionID.removeValue(forKey: sessionID)
        }
        agentSessionLinkPromptClaimStore.retainOnly(observerSessionIDs: liveSessionIDs)
    }

    // MARK: - Effective inventory

    /// The compose tab currently holding *this exact* session object, or `nil`.
    ///
    /// Object identity, not session UUID: the epoch below has to name one exact incarnation, and a
    /// tab whose session was replaced can still carry the same UUID.
    private func agentSessionLinkTabID(for session: TabSession) -> UUID? {
        let tabID = session.tabID
        guard sessions[tabID] === session else { return nil }
        return tabID
    }

    /// The inventory this exact incarnation may be told about, plus the epoch scoping its claims.
    ///
    /// Three fail-closed gates, in order: the tab must still hold this session object, the endpoint
    /// must still resolve, and the published inventory must have been addressed to *that* endpoint.
    /// The last one is what stops a rebound tab from inheriting the previous incarnation's targets
    /// during the window before the bridge republishes.
    ///
    /// A session whose effective role could never be advertised `agent_session_link` is reported as
    /// having no links, so it can never receive a supplement that names a tool it cannot call. The
    /// revision is preserved, which keeps the closing path intact: an observer that already accepted a
    /// real inventory and then lost eligibility still gets exactly one closing notice.
    ///
    /// The eligibility bit travels with the epoch rather than being left implicit in the emptied
    /// inventory, and both are computed from the single `input` below. That pairing is load-bearing:
    /// this function is the layer that collapses a non-empty authoritative membership to an empty
    /// effective one, so without the bit the claim store cannot tell "hidden because ineligible" from
    /// "actually empty" — and it used to guess, from revision movement, that a partial membership
    /// change during a suppressed window meant the observer's last link was gone.
    func agentSessionLinkPromptContext(for session: TabSession) -> AgentSessionLinkPromptContext? {
        guard let sessionID = session.activeAgentSessionID,
              let tabID = agentSessionLinkTabID(for: session),
              let endpoint = agentSessionLinkObserverEndpoint(tabID: tabID),
              endpoint.sessionID == sessionID,
              let published = agentSessionLinkPromptInventoryBySessionID[sessionID],
              published.endpoint == endpoint
        else {
            return nil
        }
        let input = AgentSessionLinkPromptEligibility.Input(
            isChildSession: session.parentSessionID != nil,
            isMCPControlled: session.mcpControlContext != nil,
            isMCPOriginated: session.isMCPOriginated,
            roleAllowsOutboundMonitoring: AgentSessionLinkToolPolicy.allowsOutboundMonitoring(
                taskLabelKind: session.mcpControlContext?.taskLabelKind
            )
        )
        return AgentSessionLinkPromptContext(
            epoch: AgentSessionLinkPromptEpoch(
                endpoint: endpoint,
                allowsSupplement: AgentSessionLinkPromptEligibility.allowsSupplement(input),
                // Computed once, here, and carried on the epoch: the provider decides the
                // model-visible tool name a fragment must use, and it is also what makes a cached
                // fragment stale when the session is rebound to a different runtime. Deriving it
                // separately at render time is how the two could disagree.
                agentKind: session.selectedAgent
            ),
            inventory: AgentSessionLinkPromptEligibility.effectiveInventory(
                published.inventory,
                input: input
            ),
            passiveNotices: agentSessionLinkPassiveNoticesBySessionID[sessionID]
        )
    }

    /// The inventory this session may actually be told about, without its epoch.
    func agentSessionLinkEffectivePromptInventory(
        for session: TabSession
    ) -> AgentSessionLinkPromptInventory? {
        agentSessionLinkPromptContext(for: session)?.inventory
    }

    // MARK: - Claim and acceptance

    /// Reserves the supplement owed to `session` for one logical dispatch, rendering it against the
    /// **current** membership revision.
    ///
    /// A revision-stable retry of the same `dispatchID` gets its existing claim back; a membership
    /// change since the claim was made abandons it and renders the current one instead.
    func agentSessionLinkPromptClaim(
        for session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) -> AgentSessionLinkOutboundPromptClaim? {
        guard let context = agentSessionLinkPromptContext(for: session) else { return nil }
        return agentSessionLinkPromptClaimStore.claim(
            dispatchID: dispatchID,
            epoch: context.epoch,
            inventory: context.inventory,
            passiveNotices: context.passiveNotices,
            render: AgentSessionLinkPrompts.rendered
        )
    }

    /// Re-owes the supplement to a session whose **provider context** is being rebuilt from the app
    /// transcript.
    ///
    /// Called from the non-resuming turn path. That path reconstructs the entire conversation from
    /// transcript items, and the supplement is never one of them, so the context about to be sent has
    /// not been taught oversight regardless of what an earlier context acknowledged. Without this the
    /// claim store stays "acknowledged" for the unchanged endpoint and epoch, and no later turn ever
    /// owes the supplement again.
    ///
    /// A no-op for sessions that never held a claim, so it is safe on every rebuild.
    func agentSessionLinkReoweSupplementForRebuiltProviderContext(for session: TabSession) {
        guard let sessionID = session.activeAgentSessionID else { return }
        agentSessionLinkPromptClaimStore.invalidateAcknowledgedContext(observerSessionID: sessionID)
    }

    /// Composes the final provider-bound string for one logical dispatch.
    ///
    /// Returns the (possibly unchanged) text plus the claim the caller must acknowledge at its
    /// provider's acceptance signal. When the dispatch fails or its outcome is unknown, the caller
    /// simply does not acknowledge and the still-current claim stays pending for the retry.
    func agentSessionLinkDecoratedProviderText(
        _ providerText: String,
        session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) -> (text: String, claim: AgentSessionLinkOutboundPromptClaim?) {
        guard let claim = agentSessionLinkPromptClaim(for: session, dispatchID: dispatchID) else {
            return (providerText, nil)
        }
        return (AgentSessionLinkPromptComposer.decorated(providerText, with: claim), claim)
    }

    /// Acknowledges one accepted dispatch. Idempotent and safe with `nil`.
    ///
    /// The two components settle with their own owners and neither can block the other. Membership
    /// goes to the claim store, which refuses a claim minted in a superseded epoch. The passive
    /// receipt goes to the bridge-owned queue, which is deliberately *not* epoch-token gated: the
    /// provider physically accepted that batch, and the queue's own epoch/revision fencing is what
    /// decides whether it still applies. Gating it on the store's token instead would re-deliver a
    /// batch the model already holds whenever a provider or eligibility flip raced the acceptance.
    func acceptAgentSessionLinkPromptClaim(_ claim: AgentSessionLinkOutboundPromptClaim?) {
        guard let claim else { return }
        agentSessionLinkPromptClaimStore.accept(claim)
        guard let passive = claim.passive else { return }
        AgentSessionLinkRuntimeBridge.shared.applyPassiveMonitorNoticeReceipt(
            passive.receipt,
            observerEndpoint: passive.observerEndpoint
        )
    }

    /// Releases the claim of a definitively terminal logical dispatch. Idempotent and safe with
    /// `nil`.
    ///
    /// This is *not* an acknowledgement: the supplement stays owed to the next dispatch. Use it only
    /// when the dispatch will never be retried under the same logical ID, so its rendered fragment
    /// is not retained until some unrelated dispatch happens to be accepted.
    ///
    /// A passive batch the claim carried stays queued for exactly the same reason: an abandoned or
    /// ambiguous pre-acceptance outcome acknowledges nothing at all.
    func abandonAgentSessionLinkPromptClaim(_ claim: AgentSessionLinkOutboundPromptClaim?) {
        guard let claim else { return }
        agentSessionLinkPromptClaimStore.abandon(claim)
    }
}
