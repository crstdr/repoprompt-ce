import Foundation
import RepoPromptDomainRuntime

// MARK: - Prompt inventory

/// One overseen target as the agent-facing prompt sees it.
///
/// Deliberately narrower than `DomainAgentSessionLinkInventoryItem`: link IDs, generations, and the
/// observer's own session ID are authority bookkeeping the model never needs, and workspace,
/// worktree, path, provider, and status data are forbidden in agent-facing prompt text entirely.
struct AgentSessionLinkPromptInventoryItem: Hashable {
    let targetSessionID: UUID
    let displayName: String?
    let capabilityNames: [String]

    init(targetSessionID: UUID, displayName: String?, capabilityNames: [String]) {
        self.targetSessionID = targetSessionID
        // Re-normalized here rather than trusted from the authority: the renderer's byte budget is
        // only meaningful if the caps hold at the exact value it renders.
        self.displayName = DomainAgentSessionLinkTextBudget.normalized(
            displayName,
            maxBytes: DomainAgentSessionLinkTextBudget.displayNameMaxBytes
        )
        self.capabilityNames = capabilityNames.sorted()
    }
}

/// The observer-scoped inventory an oversight supplement renders from.
///
/// `linkSetRevision` advances **only** when this observer's grant membership changes. Target status
/// transitions and display-name refreshes advance the authority revision instead, so they can never
/// re-inject a supplement.
struct AgentSessionLinkPromptInventory: Hashable {
    let observerSessionID: UUID
    let linkSetRevision: UInt64
    /// Sorted by target UUID so two renders of the same membership are byte-identical.
    let items: [AgentSessionLinkPromptInventoryItem]

    init(
        observerSessionID: UUID,
        linkSetRevision: UInt64,
        items: [AgentSessionLinkPromptInventoryItem]
    ) {
        self.observerSessionID = observerSessionID
        self.linkSetRevision = linkSetRevision
        self.items = items.sorted { $0.targetSessionID.uuidString < $1.targetSessionID.uuidString }
    }

    init(_ inventory: DomainAgentSessionLinkInventory) {
        self.init(
            observerSessionID: inventory.sessionID,
            linkSetRevision: inventory.linkSetRevision,
            items: inventory.items.map { item in
                AgentSessionLinkPromptInventoryItem(
                    targetSessionID: item.targetSessionID,
                    displayName: item.displayName,
                    capabilityNames: item.capabilityNames
                )
            }
        )
    }

    /// An observer that has never held a link. Rendering never happens from this value; it exists so
    /// a session with no published inventory has a well-defined revision to compare against.
    static func empty(observerSessionID: UUID) -> AgentSessionLinkPromptInventory {
        AgentSessionLinkPromptInventory(
            observerSessionID: observerSessionID,
            linkSetRevision: 0,
            items: []
        )
    }

    var isEmpty: Bool {
        items.isEmpty
    }
}

// MARK: - Logical dispatch identity

/// Identifies one **logical** outbound dispatch, not one physical send attempt.
///
/// Transport retries of the same logical dispatch reuse the same ID, which is what makes a
/// revision-stable retry reuse its already-rendered fragment instead of racing a membership change
/// mid-retry. Each provider family builds its ID from the most stable identifier it owns for a
/// single user-visible turn: a queue entry ID where one exists, otherwise the run/attempt identity.
struct AgentSessionLinkPromptDispatchID: Hashable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    private init(_ family: String, _ identifier: String) {
        rawValue = "\(family):\(identifier)"
    }

    var description: String {
        rawValue
    }

    // MARK: Codex

    /// One call of `sendCodexNativeMessage`, stable across its internal auth-retry attempts.
    static func codexNativeSend(_ id: UUID) -> Self {
        .init("codex.send", id.uuidString)
    }

    /// One queued Codex fallback entry, stable across queue draining and redispatch.
    static func codexFallback(queueID: UUID) -> Self {
        .init("codex.fallback", queueID.uuidString)
    }

    // MARK: Claude-compatible

    /// One call of `sendClaudeNativeMessage`, stable across its bounded controller-retry loop.
    static func claudeNativeSend(_ id: UUID) -> Self {
        .init("claude.native", id.uuidString)
    }

    // MARK: Headless (Claude headless and generic providers)

    static func headlessRun(runID: UUID) -> Self {
        .init("headless.run", runID.uuidString)
    }

    // MARK: ACP

    static func acpPromptTurn(runAttemptID: UUID) -> Self {
        .init("acp.prompt", runAttemptID.uuidString)
    }

    static func acpActiveSteering(runAttemptID: UUID) -> Self {
        .init("acp.steer", runAttemptID.uuidString)
    }

    // MARK: Waiting-instruction continuation

    static func waitingContinuation(waitID: UUID) -> Self {
        .init("waiting.continuation", waitID.uuidString)
    }
}

// MARK: - Claim epoch

/// Opaque, never-reused identifier for one epoch of one observer's claim state.
///
/// Deliberately not a counter and not the `AgentSessionLinkPromptEpoch` identity: both are reusable
/// after the store forgets an observer — a counter restarts, and an identity repeats whenever the
/// same incarnation is republished to. Only a fresh value per epoch makes a stale claim from a
/// forgotten incarnation unmatchable by construction.
struct AgentSessionLinkPromptEpochToken: Hashable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

/// Exhaustive, nonlocalized identity of the **provider context** a supplement is rendered for.
///
/// Deliberately one case per `AgentProviderKind` rather than a collapsed "renders the same today"
/// grouping, and deliberately not derived from a provider's localized display name. Two things ride
/// on it: the model-visible tool reference the fragment names, and the fact that switching providers
/// rebuilds the conversation the fragment was rendered into. Both are cheaper to over-report — one
/// redundant supplement — than to miss, and the exhaustive switch below forces a new provider kind
/// to state its own answer instead of inheriting one.
enum AgentSessionLinkPromptProviderContext: String, Hashable, CaseIterable {
    /// No provider has been selected for this session yet.
    case unselected
    case codexExec
    case claudeCode
    case claudeCodeGLM
    case kimiCode
    case customClaudeCompatible
    case openCode
    case cursor

    init(agentKind: AgentProviderKind?) {
        guard let agentKind else {
            self = .unselected
            return
        }
        switch agentKind {
        case .codexExec: self = .codexExec
        case .claudeCode: self = .claudeCode
        case .claudeCodeGLM: self = .claudeCodeGLM
        case .kimiCode: self = .kimiCode
        case .customClaudeCompatible: self = .customClaudeCompatible
        case .openCode: self = .openCode
        case .cursor: self = .cursor
        }
    }
}

/// Identity of one observer *incarnation, provider context, and eligibility state*.
///
/// Acknowledgement bookkeeping keyed by session UUID alone is wrong three times over. An in-place
/// rebind or a reopened tab reusing the same UUID is a different agent that must be taught oversight
/// from scratch; a provider change hands the same agent a differently named tool inside a
/// reconstructed context; and an eligibility flip changes what the observer is allowed to be told at
/// an unchanged membership revision. Every one of those transitions mints a new epoch, and a claim
/// rendered in a prior epoch can never be acknowledged.
struct AgentSessionLinkPromptEpoch: Hashable {
    /// The exact live incarnation this claim state belongs to.
    let endpoint: DomainAgentSessionLinkEndpointIdentity
    /// Whether this incarnation may currently be told about its links at all.
    let allowsSupplement: Bool
    /// Which provider runtime this incarnation is currently bound to.
    let providerContext: AgentSessionLinkPromptProviderContext
    /// The model-visible oversight tool name for `providerContext`.
    ///
    /// Carried on the epoch rather than recomputed at render time so the reference a fragment names
    /// and the reference its cache is keyed by cannot disagree.
    let toolReference: String

    /// The defaults are the exact pair `agentKind: nil` produces, so an epoch built without provider
    /// context is self-consistent rather than a mismatched discriminator/reference combination.
    init(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        allowsSupplement: Bool,
        providerContext: AgentSessionLinkPromptProviderContext = .unselected,
        toolReference: String = MCPWindowToolName.agentSessionLink
    ) {
        self.endpoint = endpoint
        self.allowsSupplement = allowsSupplement
        self.providerContext = providerContext
        self.toolReference = toolReference
    }

    /// Derives both provider-context fields from one agent kind, which is the only supported way to
    /// build them in production.
    init(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        allowsSupplement: Bool,
        agentKind: AgentProviderKind?
    ) {
        self.init(
            endpoint: endpoint,
            allowsSupplement: allowsSupplement,
            providerContext: AgentSessionLinkPromptProviderContext(agentKind: agentKind),
            toolReference: AgentSessionLinkPrompts.toolReference(agentKind: agentKind)
        )
    }

    /// Whether `other` names the same agent *and* the same provider context, differing at most in the
    /// reversible eligibility bit.
    ///
    /// This is the line between a reset that clears acknowledgement bookkeeping and one that only
    /// retires rendered fragments: eligibility flips back, an incarnation or provider change does not.
    func hasSameProviderIncarnation(as other: AgentSessionLinkPromptEpoch) -> Bool {
        endpoint == other.endpoint
            && providerContext == other.providerContext
            && toolReference == other.toolReference
    }
}

// MARK: - Supplement decision

/// What, if anything, the next accepted logical dispatch owes this observer **about its membership**.
///
/// Deliberately not extended with a passive-status case. Membership context and a coalesced status
/// batch can both be owed on one dispatch, so they are separate optional components of a single
/// claim rather than mutually exclusive kinds.
enum AgentSessionLinkPromptSupplementKind: String, Hashable {
    /// The current overseen-session inventory and its usage guidance.
    case inventory
    /// The closing notice for an observer that is allowed to see its inventory and has none left:
    /// membership is genuinely empty, so the end is real and the notice may say so.
    case revocation
    /// The closing notice for an observer that is currently barred from being told about its links,
    /// with or without a membership change behind that suppressed window. Deliberately says nothing
    /// about membership: the grants behind the retracted list may or may not still exist.
    case suspension
}

/// Pure decision over membership revisions and current eligibility.
///
/// Kept free of view-model, authority, and provider types so the whole injection policy — including
/// the "never inject twice for one revision" and "at most one final revocation supplement" rules —
/// is a truth table rather than an integration behaviour.
///
/// Every input is a fact the caller states outright. Nothing here reconstructs *why* an inventory is
/// empty from the shape of the other arguments: the one time it did, it inferred a terminal
/// revocation from revision movement and announced the end of oversight to an observer whose
/// remaining links were live.
enum AgentSessionLinkPromptSupplementDecision {
    /// - Parameters:
    ///   - currentRevision: this observer's live link-set membership revision.
    ///   - hasLinks: whether the **effective** inventory — what this observer may be told about — is
    ///     non-empty.
    ///   - isEligibilitySuppressed: whether this observer is currently barred from being told about
    ///     its links at all, which is the one reason an effective inventory can be empty while
    ///     authoritative membership is not. Deliberately has no default: it is the fact whose loss at
    ///     this boundary produced a terminal notice for a reversible state, and a caller that cannot
    ///     say which kind of empty it holds has no business classifying the closing notice.
    ///   - lastAcceptedRevision: the membership revision most recently acknowledged by an accepted
    ///     dispatch, or `nil` when this observer has never accepted a supplement.
    ///   - lastAcceptedHadLinks: whether that acknowledged supplement named at least one target.
    ///   - possiblyDeliveredLinkRevision: the newest revision whose link-naming fragment was handed
    ///     to a dispatch and never acknowledged, or `nil` when no such ambiguity exists. Defaults to
    ///     `nil` so a caller reasoning purely about acknowledged state reads the same truth table it
    ///     always did.
    static func decide(
        currentRevision: UInt64,
        hasLinks: Bool,
        isEligibilitySuppressed: Bool,
        lastAcceptedRevision: UInt64?,
        lastAcceptedHadLinks: Bool,
        possiblyDeliveredLinkRevision: UInt64? = nil
    ) -> AgentSessionLinkPromptSupplementKind? {
        // Already acknowledged for this exact membership *state*: later turns are quiet. Status
        // changes and renames never reach here because they do not advance the membership revision.
        //
        // The acknowledged state is `(revision, hadLinks)` rather than the revision alone. Eligibility
        // loss empties the effective inventory while deliberately preserving the revision
        // (`AgentSessionLinkPromptEligibility.effectiveInventory`), so a revision-only comparison
        // would silence the one closing notice that contract promises and leave the model believing
        // it can still oversee.
        //
        // An acknowledged *empty* state settles only while nothing naming a target may have reached
        // the model since. Same-revision eligibility can flip repeatedly, so an acknowledged
        // suspension followed by a restored inventory whose acceptance signal was lost lands back on
        // this identical pair: the state matches, yet the model may now hold an inventory that
        // postdates the notice. `possiblyDeliveredLinkRevision` is the only witness to that, and an
        // acknowledged closing notice is what clears it — so requiring it to be absent keeps the
        // empty state settled after exactly one notice while still erring toward over-notifying.
        if let lastAcceptedRevision,
           lastAcceptedRevision == currentRevision,
           lastAcceptedHadLinks == hasLinks,
           hasLinks || possiblyDeliveredLinkRevision == nil
        {
            return nil
        }
        if hasLinks { return .inventory }
        // No links now. A closing notice is only meaningful to an agent that was actually told it was
        // overseeing something: an add-then-revoke that never reached a dispatch leaves the model with
        // no oversight context to retract, and announcing one would be pure noise.
        //
        // "Told" deliberately includes *may have been told*. An acknowledgement proves a fragment
        // landed, but its absence proves nothing: a dispatch the provider accepted whose acceptance
        // signal never made it back leaves no acknowledged state at all, and the membership change
        // that retires its pending claim erases the last trace of it. Closing on the union of the two
        // costs an agent that never saw the inventory one stray sentence; closing on the
        // acknowledgement alone strands an agent that did see it believing it still oversees a
        // session it can no longer reach.
        guard hasExposedLinkInventory(
            lastAcceptedRevision: lastAcceptedRevision,
            lastAcceptedHadLinks: lastAcceptedHadLinks,
            possiblyDeliveredLinkRevision: possiblyDeliveredLinkRevision
        ) else { return nil }
        // Two different empties reach this point and the model must not be told the same thing about
        // them. Which one this is, is *stated* rather than inferred: `isEligibilitySuppressed` is the
        // same eligibility bit that emptied the effective inventory in the first place
        // (`AgentSessionLinkPromptEligibility.effectiveInventory`), carried down instead of being
        // reconstructed here.
        //
        // It used to be reconstructed as `exposedRevision == currentRevision`, on the theory that a
        // real revocation always arrives at a newer revision than the inventory the model holds. That
        // premise is true but not sufficient: the authority advances this observer's revision on
        // *every* membership mutation, including revoking one target while others remain
        // (`DomainAgentSessionLinkAuthority`, revoke path). A partial change during a suppressed
        // window was therefore indistinguishable from "your last link is gone", and the observer was
        // handed the terminal "re-add it through the Oversee control" wording while the rest of its
        // links were live and about to reappear.
        //
        // The replacement rule has no arithmetic in it: **while an observer is suppressed, no notice
        // may be terminal**, because eligibility can return at any moment and re-teach whatever
        // membership is authoritative then. Terminal revocation is reserved for an observer that is
        // allowed to see its inventory and whose inventory is genuinely empty — the only state in
        // which "you are no longer overseeing any session" is both true and complete.
        //
        // Where the two coincide — suppressed *and* authoritatively empty — the notice is
        // deliberately still the suspension. The terminal wording names re-adding through Oversee as
        // the remedy, which would restore nothing while this session remains ineligible, so it is the
        // overclaiming half of the pair.
        //
        // What that costs is stated rather than hidden, because the state machine does not guarantee
        // a terminal notice ever follows. If that suspension is acknowledged and eligibility later
        // returns to empty membership, the restoration re-owe
        // (`ObserverState.reoweInventoryOnRestoredEligibility`) clears the acknowledgement, but the
        // acknowledged closing notice already cleared the exposure mark — so `hasExposedLinkInventory`
        // finds nothing to close out and the observer is never told oversight ended for good. That is
        // survivable only because the suspension wording is true in that state too: it retracts the
        // list and forbids every use of oversight without claiming the grants survived, so the model
        // is left conservative rather than misinformed.
        //
        // Consequence worth naming: the closing kind is now a function of the *epoch*, and an
        // eligibility flip already mints a new epoch. Within one epoch it can no longer change under a
        // pending claim's feet — which is exactly the drift the revision-derived version allowed, and
        // why `kind` still does not need to be part of the acknowledged state.
        return isEligibilitySuppressed ? .suspension : .revocation
    }

    /// Whether this observer holds, or may hold, an inventory that names a target.
    ///
    /// `false` means nothing naming a target has ever reached a dispatch, so there is nothing to
    /// close out. The two inputs are unioned rather than ranked: an acknowledged inventory and an
    /// unacknowledged one can coexist at different revisions, and either one is enough to owe the
    /// model a closing notice.
    ///
    /// Deliberately a `Bool` and not the newest exposed revision. It *was* the revision, and
    /// comparing that number against the current one is precisely how a reversible suspension came to
    /// be announced as a terminal revocation. Nothing needs the number, so nothing is offered it.
    private static func hasExposedLinkInventory(
        lastAcceptedRevision: UInt64?,
        lastAcceptedHadLinks: Bool,
        possiblyDeliveredLinkRevision: UInt64?
    ) -> Bool {
        let acknowledged = lastAcceptedHadLinks ? lastAcceptedRevision : nil
        return acknowledged != nil || possiblyDeliveredLinkRevision != nil
    }

    /// Whether acknowledging `claim` moves the observer's accepted state forward.
    ///
    /// A strictly newer revision always does. At an unchanged revision, either direction of the
    /// `hadLinks` flip does, because those are exactly the supplements `decide` newly emits for an
    /// unchanged revision: `true → false` is the eligibility-loss suspension — an unchanged revision
    /// can only empty by way of suppression, so it is never the terminal notice — and `false → true`
    /// is the restoration that follows when eligibility returns before membership changes again.
    /// Leaving either unacknowledged re-emits it on every subsequent accepted dispatch forever.
    ///
    /// This function deliberately does **not** try to distinguish a legitimate restoration from a
    /// late in-flight retry carrying pre-loss state — at a fixed revision and epoch the two are
    /// identical values. That distinction is the epoch's job:
    /// `AgentSessionLinkOutboundPromptClaimStore.accept(_:)` refuses any claim minted in a prior
    /// incarnation/eligibility epoch before it ever reaches this rule.
    static func isForwardAcknowledgement(
        lastAcceptedRevision: UInt64?,
        lastAcceptedHadLinks: Bool,
        claimRevision: UInt64,
        claimHasLinks: Bool
    ) -> Bool {
        guard let lastAcceptedRevision else { return true }
        if claimRevision > lastAcceptedRevision { return true }
        guard claimRevision == lastAcceptedRevision else { return false }
        return lastAcceptedHadLinks != claimHasLinks
    }
}

// MARK: - Outbound claim

/// What one render was asked to produce for a single logical dispatch.
///
/// Membership context and a passive status batch can both be owed on one dispatch, so this is a pair
/// of optionals rather than a single mutually exclusive kind. At least one is always present: the
/// store never calls a renderer for a dispatch that owes nothing.
struct AgentSessionLinkPromptRenderRequest {
    /// The membership supplement owed, or `nil` when only passive status is owed.
    let membershipKind: AgentSessionLinkPromptSupplementKind?
    /// The membership this render may name. Always the *effective* inventory.
    let inventory: AgentSessionLinkPromptInventory
    /// The deliverable passive batch offered to this render, or `nil` when none is owed. Already
    /// fenced by the store against endpoint, eligibility, revision, and grant membership.
    let passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot?
    /// The model-visible tool name this fragment must use, taken from the epoch that keys its cache.
    ///
    /// Handed to the renderer rather than resolved by it, so the reference a fragment names and the
    /// provider context that decides when that fragment goes stale are the same value by construction.
    let toolReference: String

    init(
        membershipKind: AgentSessionLinkPromptSupplementKind?,
        inventory: AgentSessionLinkPromptInventory,
        passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot?,
        toolReference: String = MCPWindowToolName.agentSessionLink
    ) {
        self.membershipKind = membershipKind
        self.inventory = inventory
        self.passiveNotices = passiveNotices
        self.toolReference = toolReference
    }
}

/// One rendered fragment plus a truthful account of what of the passive batch it actually contains.
///
/// The renderer, not the store, owns the shared byte budget, so only the renderer can say whether the
/// passive component fit. Reporting a `nil` `passiveBatch` is how it leaves that batch owed instead of
/// letting an acceptance acknowledge content the model never received.
struct AgentSessionLinkPromptRenderResult {
    /// What one render actually put in front of the model for the batch it was offered.
    ///
    /// Empty `entries` with a non-`nil` value is a real, deliverable state — the overflow-only
    /// envelope — which is why presence is modelled by the optional rather than by the entry count.
    struct RenderedPassiveBatch: Equatable {
        /// Entries actually rendered into `fragment`, in the order they appear.
        let entries: [AgentSessionLinkPassiveStatusNotices.PendingEntry]
        /// The absolute producer-side overflow watermark the rendered envelope accounted for. Never
        /// the displayed omitted delta, which cannot be acknowledged without under-counting.
        let overflowProducedThrough: UInt64
    }

    let fragment: String
    /// The passive component of `fragment`, or `nil` when the render carried none at all.
    let passiveBatch: RenderedPassiveBatch?

    init(
        fragment: String,
        passiveBatch: RenderedPassiveBatch? = nil
    ) {
        self.fragment = fragment
        self.passiveBatch = passiveBatch
    }
}

/// A rendered supplement reserved for one logical dispatch.
///
/// The claim is provider-neutral: adapters differ only in *when* they compose and *what signal*
/// counts as acceptance, never in what the fragment says.
///
/// One claim can carry a membership component, a passive status component, or both, because both can
/// be owed on the same dispatch. They are acknowledged independently and by different owners: the
/// claim store settles membership, while the bridge-owned queue settles the passive receipt.
struct AgentSessionLinkOutboundPromptClaim: Hashable {
    /// The membership half: what this fragment told the model about its overseen-session list.
    struct MembershipComponent: Hashable {
        let linkSetRevision: UInt64
        let kind: AgentSessionLinkPromptSupplementKind
        let hasLinks: Bool
    }

    /// Identity of the passive queue state one fragment was rendered *against*.
    ///
    /// Recorded even when the batch did not fit the byte budget, because it is what decides whether a
    /// retry of the same dispatch may reuse this fragment: the fragment is only current while the
    /// queue it was rendered against still is.
    struct PassiveQueueFingerprint: Hashable {
        let queueEpoch: UUID
        let queueRevision: UInt64
    }

    /// The acknowledgement owed to the passive queue once the provider accepts this dispatch.
    ///
    /// Present only when the batch was actually rendered into `fragment`. It names the exact observer
    /// incarnation whose queue produced it, so a receipt can never be applied to a replacement.
    struct PassiveStatusComponent: Hashable {
        let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
        let receipt: AgentSessionLinkPassiveStatusNotices.Receipt
    }

    let observerSessionID: UUID
    let dispatchID: AgentSessionLinkPromptDispatchID
    /// Store-minted, never-reused token for the incarnation/provider/eligibility epoch this fragment
    /// was rendered in. Any membership acknowledgement or abandonment carrying a superseded token is
    /// refused.
    ///
    /// A freshly minted `UUID` rather than a counter: `forget`/`retainOnly` delete an observer's whole
    /// state, so a counter would restart at the same value for the next incarnation of that session
    /// UUID and a late claim from the previous one would compare equal again.
    let epochToken: AgentSessionLinkPromptEpochToken
    /// `nil` for a passive-only claim: nothing about membership was said, so nothing about membership
    /// may be acknowledged.
    let membership: MembershipComponent?
    /// Present whenever a deliverable batch was offered to the renderer, even if the budget omitted
    /// it.
    let passiveQueue: PassiveQueueFingerprint?
    /// Present only when the batch was actually rendered into `fragment`.
    let passive: PassiveStatusComponent?
    let fragment: String

    // MARK: Membership readers

    /// The membership supplement this claim carries, or `nil` for a passive-only claim.
    var kind: AgentSessionLinkPromptSupplementKind? {
        membership?.kind
    }

    /// The membership revision this claim was rendered against, or `nil` for a passive-only claim.
    var linkSetRevision: UInt64? {
        membership?.linkSetRevision
    }

    /// Whether this claim's membership component named at least one target.
    ///
    /// `false` for a passive-only claim: it names sessions, but it does not hand the model an
    /// inventory, so it is not what a closing notice would be closing out.
    var hasLinks: Bool {
        membership?.hasLinks ?? false
    }
}

// MARK: - Claim store

/// Ephemeral, observer-scoped claim bookkeeping for the oversight supplement.
///
/// Responsibilities, in the order the plan defines them:
/// 1. Queues persist undecorated provider text; only this store ever holds a rendered fragment.
/// 2. A retry of the same logical dispatch at an unchanged membership revision reuses its claim, so
///    the fragment is byte-equivalent across transport retries.
/// 3. A membership change before any acceptance abandons the stale unaccepted claim and renders the
///    current revision instead — a queued turn never ships enqueue-time inventory.
/// 4. Acceptance consumes the claim exactly once and acknowledges its revision.
/// 5. A failed pre-acceptance attempt leaves the still-current claim pending.
/// 6. A claim may also carry a passive status batch, whose acknowledgement this store deliberately
///    does not own — the bridge-owned queue fences its receipt on its own epoch and revision.
///
/// The pending table is explicitly bounded. A logical dispatch that fails before acceptance and is
/// never retried under the same ID leaves its claim behind, and acceptance-driven pruning only runs
/// when some *other* dispatch is eventually accepted — so without a bound and a terminal-abandon
/// rule an observer that never completes a turn could retain one rendered fragment per attempt.
///
/// Nothing here is persisted: links do not survive a restart, so neither may an owed supplement.
@MainActor
final class AgentSessionLinkOutboundPromptClaimStore {
    /// Hard per-observer ceiling on unaccepted claims. Eviction is oldest-first: a claim that has sat
    /// unaccepted through this many later dispatches is not coming back, and the current dispatch's
    /// claim is always the one worth keeping.
    static let pendingClaimsPerObserverLimit = 16

    private struct ObserverState {
        var pending: [AgentSessionLinkPromptDispatchID: AgentSessionLinkOutboundPromptClaim] = [:]
        /// Insertion order of `pending`, oldest first, so the bound evicts deterministically.
        var pendingOrder: [AgentSessionLinkPromptDispatchID] = []
        var lastAcceptedRevision: UInt64?
        var lastAcceptedHadLinks = false
        /// Newest revision whose link-naming fragment was handed to a dispatch without ever being
        /// acknowledged.
        ///
        /// Handing the fragment out is the last instant at which RepoPrompt can prove nothing was
        /// delivered. After it, a provider may accept the turn and lose the acceptance signal, and the
        /// membership change that retires the pending claim erases every other trace of the attempt.
        /// Recording the ambiguity is what lets `decide` still close out an observer whose inventory
        /// was dispatched but never acknowledged.
        var possiblyDeliveredLinkRevision: UInt64?
        /// Token for the current epoch. Fresh on creation and on every transition, so it is never
        /// reused — including by the next incarnation created after this state is forgotten.
        var epochToken = AgentSessionLinkPromptEpochToken()
        /// The incarnation/eligibility pair `epochToken` currently stands for.
        var epochIdentity: AgentSessionLinkPromptEpoch?
        /// The single rendered result for the current claim fingerprint.
        ///
        /// Every claim with that fingerprint stores this exact `String` instance, so N concurrent
        /// dispatches share one buffer instead of duplicating a fragment that may approach the
        /// renderer's byte budget. The fingerprint now includes the passive queue identity, so a queue
        /// revision change invalidates the cache exactly as a membership revision change does.
        var renderedFingerprint: ClaimFingerprint?
        var renderedResult: AgentSessionLinkPromptRenderResult?

        mutating func removePending(_ dispatchID: AgentSessionLinkPromptDispatchID) {
            guard pending.removeValue(forKey: dispatchID) != nil else { return }
            pendingOrder.removeAll { $0 == dispatchID }
        }

        mutating func setPending(_ claim: AgentSessionLinkOutboundPromptClaim) {
            if pending.updateValue(claim, forKey: claim.dispatchID) == nil {
                pendingOrder.append(claim.dispatchID)
            }
            while pendingOrder.count > AgentSessionLinkOutboundPromptClaimStore
                .pendingClaimsPerObserverLimit
            {
                let evicted = pendingOrder.removeFirst()
                pending.removeValue(forKey: evicted)
            }
        }

        /// Moves this observer's state onto `identity`, minting a new epoch token when anything
        /// changed.
        ///
        /// Two different resets are deliberately distinguished:
        ///
        /// - **Any** transition retires every pending claim and the cached fragment: they were
        ///   rendered for a state that no longer exists and can never ship.
        /// - Only an **incarnation** change clears the acknowledgement *and* the possibly-delivered
        ///   mark. A new incarnation is a new agent and must be taught oversight from scratch,
        ///   whereas an eligibility flip on the same incarnation must keep the possibly-delivered
        ///   mark so the single closing notice that `decide` promises still fires instead of being
        ///   swallowed as "never acknowledged".
        /// - An eligibility **restoration** on the same incarnation clears the acknowledgement only.
        ///   See `reoweInventoryOnRestoredEligibility()`.
        mutating func rebase(to identity: AgentSessionLinkPromptEpoch) {
            guard epochIdentity != identity else { return }
            let previous = epochIdentity
            epochToken = AgentSessionLinkPromptEpochToken()
            epochIdentity = identity
            pending.removeAll()
            pendingOrder.removeAll()
            renderedFingerprint = nil
            renderedResult = nil
            guard let previous else { return }
            // A provider change is treated exactly like an incarnation change, and deliberately so.
            // The fragment names a provider-specific tool reference, and the turn that carries it is
            // assembled into a context the previous provider's history never entered — so nothing the
            // old context acknowledged is evidence about the new one. The bridge-owned passive queue
            // is untouched by this: it lives outside the store and is simply re-rendered against the
            // new epoch.
            guard previous.hasSameProviderIncarnation(as: identity) else {
                lastAcceptedRevision = nil
                lastAcceptedHadLinks = false
                // Cleared on exactly the condition that clears the acknowledgement, and for the same
                // reason: a new incarnation is a new agent, so nothing was ever delivered to *it* and
                // it has no oversight context to close out.
                possiblyDeliveredLinkRevision = nil
                return
            }
            if !previous.allowsSupplement, identity.allowsSupplement {
                reoweInventoryOnRestoredEligibility()
            }
        }

        /// Re-owes whatever the live membership says, because a suspension notice may have reached
        /// the model while this observer was ineligible.
        ///
        /// This is the mirror of the ambiguity `possiblyDeliveredLinkRevision` resolves, and it does
        /// not fall out of that mark: `recordPossibleDelivery(of:)` only tracks *link-naming*
        /// fragments, so a handed-out suspension leaves no trace at all. Without one, an inventory
        /// acknowledged at revision R, a suspension dispatched at R whose acceptance signal was lost,
        /// and eligibility returning at that same R land back on the acknowledged pair
        /// `(R, hadLinks: true)` — `decide`'s exact-state early return then stays silent forever and
        /// the model keeps the last thing it was told: that oversight is unavailable and its list is
        /// stale.
        ///
        /// Clearing the acknowledgement rather than widening the recorded state is the deliberate
        /// choice. An empty effective inventory can only become non-empty at an unchanged revision by
        /// way of eligibility returning, so this transition is exactly co-extensive with the hole;
        /// and the store only ever observes the ineligible epoch when a dispatch was actually claimed
        /// during it, which is the only way a suspension could have been rendered. The residual cost
        /// is one redundant inventory when that suspension provably never landed — the harmless
        /// direction for a mechanism whose whole purpose is to over-notify rather than under-notify.
        ///
        /// The possibly-delivered mark is deliberately kept: the model may still hold the inventory,
        /// so a later revocation must still close it out.
        private mutating func reoweInventoryOnRestoredEligibility() {
            lastAcceptedRevision = nil
            lastAcceptedHadLinks = false
        }

        /// Records that `claim`'s fragment has been handed to a dispatch and may reach the model.
        ///
        /// Monotone: an older revision never lowers the mark, so a late retry of a superseded
        /// dispatch cannot rewind what the model may already hold.
        ///
        /// A passive-only claim deliberately records nothing here. The mark tracks *link-naming*
        /// membership fragments, and a status envelope hands the model no inventory to retract. In
        /// practice the distinction never fires: a dispatch that owes the inventory renders it in the
        /// same claim, so a passive-only claim can only exist once membership was already settled.
        mutating func recordPossibleDelivery(of claim: AgentSessionLinkOutboundPromptClaim) {
            guard let membership = claim.membership, membership.hasLinks else { return }
            possiblyDeliveredLinkRevision = max(
                possiblyDeliveredLinkRevision ?? membership.linkSetRevision,
                membership.linkSetRevision
            )
        }

        /// Retires pending claims that can never be shipped again.
        ///
        /// `claim(_:)` only reuses an existing entry when its revision matches the current one, so a
        /// pending claim rendered against a superseded revision is definitively terminal: even its
        /// own dispatch would re-render on retry.
        ///
        /// A passive-only claim is deliberately kept: it carries no membership revision, so membership
        /// movement alone cannot make it stale. Its own passive fingerprint decides whether a retry
        /// may reuse it, and the pending bound is what collects it if that retry never comes.
        mutating func retirePending(olderThan revision: UInt64) {
            guard pendingOrder.contains(where: { Self.isStale(pending[$0], olderThan: revision) })
            else { return }
            pendingOrder.removeAll { dispatchID in
                guard let claim = pending[dispatchID] else { return true }
                guard Self.isStale(claim, olderThan: revision) else { return false }
                pending.removeValue(forKey: dispatchID)
                return true
            }
        }

        /// `static` so the predicate touches no other stored property while `pendingOrder` is being
        /// mutated exclusively.
        private static func isStale(
            _ claim: AgentSessionLinkOutboundPromptClaim?,
            olderThan revision: UInt64
        ) -> Bool {
            guard let membershipRevision = claim?.membership?.linkSetRevision else { return false }
            return membershipRevision < revision
        }
    }

    /// Everything that decides whether an already-rendered fragment is still the current one.
    ///
    /// Both halves are optional and both participate: a membership change, a queue change, or either
    /// component appearing or disappearing all make a cached fragment stale.
    private struct ClaimFingerprint: Hashable {
        let membershipRevision: UInt64?
        let membershipKind: AgentSessionLinkPromptSupplementKind?
        let passiveQueue: AgentSessionLinkOutboundPromptClaim.PassiveQueueFingerprint?

        init(
            membershipKind: AgentSessionLinkPromptSupplementKind?,
            inventory: AgentSessionLinkPromptInventory,
            passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot?
        ) {
            membershipRevision = membershipKind == nil ? nil : inventory.linkSetRevision
            self.membershipKind = membershipKind
            passiveQueue = passiveNotices.map {
                AgentSessionLinkOutboundPromptClaim.PassiveQueueFingerprint(
                    queueEpoch: $0.queueEpoch,
                    queueRevision: $0.queueRevision
                )
            }
        }

        init(_ claim: AgentSessionLinkOutboundPromptClaim) {
            membershipRevision = claim.membership?.linkSetRevision
            membershipKind = claim.membership?.kind
            passiveQueue = claim.passiveQueue
        }
    }

    private var states: [UUID: ObserverState] = [:]

    init() {}

    /// Reserves (or reuses) the supplement owed to `epoch.endpoint` for one logical dispatch.
    ///
    /// - Parameters:
    ///   - epoch: the caller's exact incarnation, provider context, and current eligibility. A
    ///     transition in any of them mints a new epoch, which retires every fragment rendered for the
    ///     previous one.
    ///   - passiveNotices: the observer's latest published passive queue, if any. Fenced here rather
    ///     than at the call site so every condition that may join a status batch to a dispatch is one
    ///     truth table.
    /// - Returns: `nil` when neither component is owed. Callers must send undecorated text in that
    ///   case.
    func claim(
        dispatchID: AgentSessionLinkPromptDispatchID,
        epoch: AgentSessionLinkPromptEpoch,
        inventory: AgentSessionLinkPromptInventory,
        passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot? = nil,
        render: (AgentSessionLinkPromptRenderRequest) -> AgentSessionLinkPromptRenderResult
    ) -> AgentSessionLinkOutboundPromptClaim? {
        let observerSessionID = inventory.observerSessionID
        // Fail closed on a mismatched pairing rather than filing one incarnation's claim under
        // another session's state.
        guard epoch.endpoint.sessionID == observerSessionID else { return nil }
        var state = states[observerSessionID] ?? ObserverState()
        defer { states[observerSessionID] = state }

        state.rebase(to: epoch)
        // Every pending claim rendered against a superseded revision is terminal by construction, so
        // retire the whole cohort rather than waiting for an unrelated acceptance to prune it.
        state.retirePending(olderThan: inventory.linkSetRevision)

        // `epoch.allowsSupplement` is why the fix for the misclassified closing notice needed no new
        // plumbing: the bit was already here, one line above the call that had to reconstruct it. The
        // caller builds the epoch flag and the effective inventory from a single eligibility
        // evaluation (`AgentModeViewModel.agentSessionLinkPromptContext`), so "suppressed" and
        // "collapsed to empty" cannot disagree.
        let membershipKind = AgentSessionLinkPromptSupplementDecision.decide(
            currentRevision: inventory.linkSetRevision,
            hasLinks: !inventory.isEmpty,
            isEligibilitySuppressed: !epoch.allowsSupplement,
            lastAcceptedRevision: state.lastAcceptedRevision,
            lastAcceptedHadLinks: state.lastAcceptedHadLinks,
            possiblyDeliveredLinkRevision: state.possiblyDeliveredLinkRevision
        )
        let passiveBatch = Self.deliverablePassiveBatch(
            passiveNotices,
            epoch: epoch,
            inventory: inventory
        )
        guard membershipKind != nil || passiveBatch != nil else {
            // Nothing owed: drop any claim still parked against this dispatch so a superseded
            // fragment can never be picked up by a later attempt.
            state.removePending(dispatchID)
            return nil
        }

        let fingerprint = ClaimFingerprint(
            membershipKind: membershipKind,
            inventory: inventory,
            passiveNotices: passiveBatch
        )
        if let existing = state.pending[dispatchID], ClaimFingerprint(existing) == fingerprint {
            state.recordPossibleDelivery(of: existing)
            return existing
        }

        // One rendered result per fingerprint, shared by reference across every dispatch that owes
        // it, so the pending table's cost is its entry count rather than its entry count times the
        // fragment size.
        let rendered: AgentSessionLinkPromptRenderResult
        if state.renderedFingerprint == fingerprint, let cached = state.renderedResult {
            rendered = cached
        } else {
            rendered = render(AgentSessionLinkPromptRenderRequest(
                membershipKind: membershipKind,
                inventory: inventory,
                passiveNotices: passiveBatch,
                toolReference: epoch.toolReference
            ))
            state.renderedFingerprint = fingerprint
            state.renderedResult = rendered
        }

        // A batch the renderer could not fit leaves no receipt, so acceptance acknowledges nothing
        // and the queue keeps it owed to a later dispatch. Partial acknowledgement is never offered.
        var passiveComponent: AgentSessionLinkOutboundPromptClaim.PassiveStatusComponent?
        if let passiveBatch, let renderedPassive = rendered.passiveBatch {
            passiveComponent = AgentSessionLinkOutboundPromptClaim.PassiveStatusComponent(
                observerEndpoint: epoch.endpoint,
                receipt: AgentSessionLinkPassiveStatusNotices.Receipt(
                    queueEpoch: passiveBatch.queueEpoch,
                    queueRevision: passiveBatch.queueRevision,
                    deliveredStatuses: renderedPassive.entries.map(
                        AgentSessionLinkPassiveStatusNotices.DeliveredStatus.init
                    ),
                    overflowProducedThrough: renderedPassive.overflowProducedThrough
                )
            )
        }

        let claim = AgentSessionLinkOutboundPromptClaim(
            observerSessionID: observerSessionID,
            dispatchID: dispatchID,
            epochToken: state.epochToken,
            membership: membershipKind.map {
                AgentSessionLinkOutboundPromptClaim.MembershipComponent(
                    linkSetRevision: inventory.linkSetRevision,
                    kind: $0,
                    hasLinks: !inventory.isEmpty
                )
            },
            passiveQueue: fingerprint.passiveQueue,
            passive: passiveComponent,
            fragment: rendered.fragment
        )
        state.setPending(claim)
        // Recorded at hand-off, not at dispatch: the store never learns whether the caller's transport
        // succeeded, so this is the only point where the possibility is knowable at all.
        state.recordPossibleDelivery(of: claim)
        return claim
    }

    /// The passive batch, if any, that may ride along with this exact dispatch.
    ///
    /// Every condition fails closed and none of them relaxes authorization. In order: the observer
    /// must currently be allowed a supplement at all; the snapshot must have been reduced for *this*
    /// exact incarnation; passive updates must be on and currently deliverable; there must be
    /// something to say — entries, or unacknowledged overflow on its own, which is how a dropped-change
    /// count reaches the agent and gets acknowledged even when no entry survives to carry it; and the
    /// queue's membership revision must equal the effective inventory's, so
    /// a batch reduced across a membership change waits for the bridge to republish rather than
    /// shipping against a list that has moved. The final grant check is belt-and-braces on top of that
    /// revision match: a status notice may only ever name a session this dispatch is also allowed to
    /// be told it oversees.
    private static func deliverablePassiveBatch(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot?,
        epoch: AgentSessionLinkPromptEpoch,
        inventory: AgentSessionLinkPromptInventory
    ) -> AgentSessionLinkPassiveStatusNotices.Snapshot? {
        guard let snapshot,
              epoch.allowsSupplement,
              snapshot.observerEndpoint == epoch.endpoint,
              snapshot.isEnabled,
              snapshot.isDeliverable,
              snapshot.hasDeliverableContent,
              !inventory.isEmpty,
              snapshot.linkSetRevision == inventory.linkSetRevision
        else { return nil }
        let granted = Set(inventory.items.map(\.targetSessionID))
        guard snapshot.entries.allSatisfy({ granted.contains($0.targetSessionID) }) else { return nil }
        return snapshot
    }

    /// Releases the claim parked against a definitively terminal logical dispatch.
    ///
    /// Use this when a dispatch will never be retried under the same ID (a cancelled turn, a dropped
    /// queue entry, a run that failed terminally). Not acknowledging it: the supplement stays owed to
    /// the next dispatch, which is exactly the pre-acceptance failure contract.
    ///
    /// Epoch-token-gated for the same reason `accept` is. A dispatch ID is only unique within an
    /// epoch, so a late abandonment from a superseded incarnation would otherwise delete the *current*
    /// incarnation's pending claim under the same ID — silently re-rendering a fragment that was
    /// already reserved, or dropping one that a retry was about to reuse.
    func abandon(_ claim: AgentSessionLinkOutboundPromptClaim) {
        guard var state = states[claim.observerSessionID] else { return }
        guard state.epochToken == claim.epochToken else { return }
        state.removePending(claim.dispatchID)
        states[claim.observerSessionID] = state
    }

    /// Acknowledges one accepted dispatch.
    ///
    /// Consumption is exactly-once and revision-monotonic: a late acceptance carrying an older
    /// revision (an in-flight retry that lands after a membership change already shipped) clears its
    /// own claim without regressing the acknowledged revision, so the newer supplement stays owed.
    ///
    /// Two things make it incarnation-safe. It never *creates* state, so an acceptance arriving after
    /// the observer's binding disappeared cannot repopulate an acknowledgement that would silence the
    /// next incarnation reusing that UUID. And it refuses any claim minted in a superseded epoch, so
    /// a retry rendered before an incarnation or eligibility transition can neither be consumed nor
    /// resurrect the state it was rendered against.
    ///
    /// Acceptance also retires every other pending claim at or below the acknowledged revision. That
    /// is what bounds the table: a dispatch that failed, was superseded, or was requeued under a
    /// different logical ID leaves a claim behind, and nothing else would ever collect it.
    func accept(_ claim: AgentSessionLinkOutboundPromptClaim) {
        guard var state = states[claim.observerSessionID] else { return }
        guard state.epochToken == claim.epochToken else { return }
        state.removePending(claim.dispatchID)
        // A passive-only claim settles nothing here. Its receipt belongs to the bridge-owned queue,
        // which fences it on its own epoch and revision, so this store neither applies nor blocks it.
        // That separation is what keeps a stale passive receipt from suppressing a valid membership
        // acknowledgement and vice versa.
        guard let membership = claim.membership else {
            states[claim.observerSessionID] = state
            return
        }
        // Resolving the ambiguity `claim(_:)` recorded cannot wait for the forward-acknowledgement
        // gate below. A closing notice acknowledged at an already-acknowledged empty state is not a
        // forward move — its `(revision, hadLinks)` pair is unchanged — yet that is exactly the
        // notice owed for an inventory that was restored and possibly delivered at the same
        // revision. Leaving the mark set there would re-emit that notice on every later dispatch
        // instead of settling after one.
        //
        // A confirmed closing notice only covers exposure at or below its own revision, so a newer
        // unacknowledged inventory keeps its mark and still earns its own notice.
        if !membership.hasLinks,
           let exposedRevision = state.possiblyDeliveredLinkRevision,
           exposedRevision <= membership.linkSetRevision
        {
            state.possiblyDeliveredLinkRevision = nil
        }
        guard AgentSessionLinkPromptSupplementDecision.isForwardAcknowledgement(
            lastAcceptedRevision: state.lastAcceptedRevision,
            lastAcceptedHadLinks: state.lastAcceptedHadLinks,
            claimRevision: membership.linkSetRevision,
            claimHasLinks: membership.hasLinks
        ) else {
            states[claim.observerSessionID] = state
            return
        }
        state.lastAcceptedRevision = membership.linkSetRevision
        state.lastAcceptedHadLinks = membership.hasLinks
        // A confirmed inventory pins the exposure at its own revision. The closing-notice half of
        // this rule ran above, before the gate, because it must also apply to an acknowledgement
        // that moves nothing else.
        if membership.hasLinks {
            state.possiblyDeliveredLinkRevision = membership.linkSetRevision
        }
        // Retires every other pending claim at or below the acknowledged revision, including the
        // superseded inventory claims of a same-revision eligibility loss. Passive-only claims carry
        // no membership revision and are deliberately left alone: their dispatches are still live.
        for dispatchID in state.pendingOrder
            where (state.pending[dispatchID]?.membership?.linkSetRevision)
            .map({ $0 <= membership.linkSetRevision }) == true
        {
            state.removePending(dispatchID)
        }
        states[claim.observerSessionID] = state
    }

    /// Re-owes the supplement to an observer whose **provider context** was rebuilt from scratch.
    ///
    /// A non-resuming turn reconstructs its entire history from the app transcript, and the transcript
    /// deliberately never contains the supplement — it is a provider-only envelope. Everything the
    /// previous context was taught is therefore gone, even though the incarnation, the endpoint, and
    /// the epoch are all unchanged and the store still reads "acknowledged".
    ///
    /// This is the acknowledgement half of what an incarnation change resets, without minting a new
    /// epoch: the agent is the same and its in-flight claims remain valid, but it must be taught
    /// oversight again. The possibly-delivered mark clears with it — a context that was never taught
    /// the inventory has nothing to close out, so a later empty revision must stay quiet rather than
    /// announce the end of oversight the model never heard about.
    ///
    /// Pending claims are deliberately left alone. They belong to dispatches that are still live and
    /// will be acknowledged or abandoned on their own terms.
    func invalidateAcknowledgedContext(observerSessionID: UUID) {
        guard var state = states[observerSessionID] else { return }
        guard state.lastAcceptedRevision != nil || state.possiblyDeliveredLinkRevision != nil else {
            return
        }
        state.lastAcceptedRevision = nil
        state.lastAcceptedHadLinks = false
        state.possiblyDeliveredLinkRevision = nil
        states[observerSessionID] = state
    }

    /// Forgets an endpoint entirely. Called when a session's live binding disappears: a new
    /// incarnation of the same UUID must start from "never acknowledged".
    ///
    /// Dropping the whole state is safe precisely because the epoch token is never reused: claims
    /// still in flight for the forgotten incarnation can never match the state a later incarnation
    /// of the same session UUID creates.
    func forget(observerSessionID: UUID) {
        states.removeValue(forKey: observerSessionID)
    }

    func retainOnly(observerSessionIDs: Set<UUID>) {
        for sessionID in states.keys where !observerSessionIDs.contains(sessionID) {
            states.removeValue(forKey: sessionID)
        }
    }

    // MARK: Test support

    func test_pendingClaim(
        dispatchID: AgentSessionLinkPromptDispatchID,
        observerSessionID: UUID
    ) -> AgentSessionLinkOutboundPromptClaim? {
        states[observerSessionID]?.pending[dispatchID]
    }

    func test_lastAcceptedRevision(observerSessionID: UUID) -> UInt64? {
        states[observerSessionID]?.lastAcceptedRevision
    }

    func test_lastAcceptedHadLinks(observerSessionID: UUID) -> Bool? {
        states[observerSessionID]?.lastAcceptedHadLinks
    }

    func test_possiblyDeliveredLinkRevision(observerSessionID: UUID) -> UInt64? {
        states[observerSessionID]?.possiblyDeliveredLinkRevision
    }

    func test_pendingClaimCount(observerSessionID: UUID) -> Int {
        states[observerSessionID]?.pending.count ?? 0
    }

    func test_epochToken(observerSessionID: UUID) -> AgentSessionLinkPromptEpochToken? {
        states[observerSessionID]?.epochToken
    }

    func test_hasState(observerSessionID: UUID) -> Bool {
        states[observerSessionID] != nil
    }
}

// MARK: - Supplement eligibility

/// Whether one observing session may be told about its links at all.
///
/// Mirrors Oversee's Add eligibility so a session that could never be advertised
/// `agent_session_link` is never handed a supplement naming it. Pure and value-based so the whole
/// matrix is testable without a view model.
enum AgentSessionLinkPromptEligibility {
    struct Input: Equatable {
        var isChildSession: Bool
        var isMCPControlled: Bool
        var isMCPOriginated: Bool
        var roleAllowsOutboundMonitoring: Bool

        init(
            isChildSession: Bool,
            isMCPControlled: Bool,
            isMCPOriginated: Bool,
            roleAllowsOutboundMonitoring: Bool
        ) {
            self.isChildSession = isChildSession
            self.isMCPControlled = isMCPControlled
            self.isMCPOriginated = isMCPOriginated
            self.roleAllowsOutboundMonitoring = roleAllowsOutboundMonitoring
        }
    }

    static func allowsSupplement(_ input: Input) -> Bool {
        !input.isChildSession
            && !input.isMCPControlled
            && !input.isMCPOriginated
            && input.roleAllowsOutboundMonitoring
    }

    /// The inventory an ineligible observer is allowed to see.
    ///
    /// Membership is emptied but the revision is preserved, which keeps the closing path intact: an
    /// observer that already accepted a real inventory and then lost eligibility still receives
    /// exactly one *suspension* notice rather than being left believing it can still oversee.
    ///
    /// The preserved revision is bookkeeping, not evidence. It is what lets the acknowledged state,
    /// the pending-claim retirement, and the possibly-delivered mark line up across the flip so the
    /// notice settles after exactly one. It deliberately does **not** tell `decide` whether this
    /// emptiness is reversible — the eligibility bit carried on the epoch does, because a partial
    /// membership change during a suppressed window moves the revision without ending oversight.
    static func effectiveInventory(
        _ inventory: AgentSessionLinkPromptInventory,
        input: Input
    ) -> AgentSessionLinkPromptInventory {
        guard !allowsSupplement(input) else { return inventory }
        return AgentSessionLinkPromptInventory(
            observerSessionID: inventory.observerSessionID,
            linkSetRevision: inventory.linkSetRevision,
            items: []
        )
    }
}

// MARK: - Composition

/// Appends the supplement as a distinct, final RepoPrompt envelope.
///
/// It is applied **after** user-controlled attachments, workflow, skill, and file-map composition and
/// never mutates an `AgentChatItem`, the local user-authored text, or persisted pending-instruction
/// text. The provider sees it; the transcript never does.
enum AgentSessionLinkPromptComposer {
    static func decorated(_ providerText: String, with claim: AgentSessionLinkOutboundPromptClaim?) -> String {
        guard let claim else { return providerText }
        return decorated(providerText, fragment: claim.fragment)
    }

    /// Headless and ACP variant.
    ///
    /// `systemPrompt` is deliberately untouched: resumed ACP and headless providers omit it entirely,
    /// so the base instructions are not a valid channel for a changing inventory.
    static func decorated(
        _ message: AgentMessage,
        with claim: AgentSessionLinkOutboundPromptClaim?
    ) -> AgentMessage {
        guard let claim else { return message }
        var decorated = message
        decorated.userMessage = self.decorated(message.userMessage, with: claim)
        return decorated
    }

    static func decorated(_ providerText: String, fragment: String) -> String {
        let trimmedFragment = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFragment.isEmpty else { return providerText }
        guard !providerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return trimmedFragment
        }
        return "\(providerText)\n\n\(trimmedFragment)"
    }
}
