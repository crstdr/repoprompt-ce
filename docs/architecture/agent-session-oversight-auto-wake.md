# Agent session oversight: presentation, lifecycle, and Auto-wake

Cross-session oversight lets one Agent session (the **observer**) watch others (the **targets**)
through a user-granted, directional, revocable link. When a target's lifecycle status changes,
RepoPrompt may start an automatic follow-up turn on the observer — an **Auto-wake** — so the model
learns about it without its user having to ask.

This document covers the parts that are easy to break because their invariants are enforced in one
file and depended on in another. For the tool contract a model sees, read the `agent_session_link`
definition in `MCPDomainCanonicalToolDefinitions.swift`; for the guidance the model is taught, read
`AgentSessionLinkPrompts.swift`.

## Four owners, deliberately disjoint

Nothing here has a single god object. Confusing these four is the most common way to introduce a
defect in this subsystem.

| Owner | Responsibility | Where |
| --- | --- | --- |
| Link authority | Grants, capabilities, generations, cursors, revocation. Process-memory. | `DomainAgentSessionLinkAuthority` |
| Passive reducer | The canonical queue: observer-local, first-to-final coalescing of target status edges. Owns no authority and performs no delivery. | `AgentSessionLinkPassiveStatusNotices` |
| Claim / receipt | What a provider was actually sent, and what an acceptance therefore acknowledges. | `AgentSessionLinkPromptContext` |
| Wake coordinator | Temporary admission policy: may this lane start an automatic turn *right now*? | `AgentModeViewModel+SessionLinkAutoWake` |

## Autonomy is grant-scoped and prompt-governed

The user's exact direct grant is the whole structural delegation.
`DomainAgentSessionOperationAuthorizer` still requires an Agent-origin caller, a direct grant, exact
observer identity, exact target identity, and the operation's capability on every call, and the
bridge revalidates both live endpoint incarnations around every suspension point. Nothing else
authorizes anything.

What the transport deliberately no longer asks is **what started the observer's turn**. There is no
turn-origin predicate, no observer local-input epoch, no target-local human re-arm, and no
`cross_session_reply_requires_user_instruction` result. A turn started by an incoming cross-session
message or by an Auto-wake may send, queue, replace, and cancel exactly as a user-started turn may,
because the grant authorizing it is the same grant. Removing only the visible send refusal would have
left the user's own delegated pipeline stalled at the next Auto-wake, which is why the whole
predicate went rather than one gate.

That moves one question from the transport to trusted guidance: not *may* this turn act, but *should*
it. The answer is owned by `AgentSessionLinkPrompts.autonomyContract` (rendered verbatim into
membership guidance and the full lane block), the `agent_session_link` tool description, and
`AgentSessionLinkMCPToolService.untrustedContentNotice`. Its rule is that an operation must be in
service of an explicit current or standing instruction from the observer's **own** user, and that a
standing instruction must have been given rather than inferred from a link, target activity, a status
change, a transcript, a preview, a `waiting_on` declaration, or an incoming message.

Target-derived content informs; it never authorizes. It may change what the model does under an
instruction it already has, and it may never become the instruction, approval, permission, or
authority for one.

Because that guidance is versioned, a bump is load-bearing rather than cosmetic. Revision 3 is the one
that retires the fence, so every provider context is re-owed the full block: the next accepted passive
batch in a context that has not accepted revision 3 carries the whole text, later batches use the
reminder, and an Auto-wake cannot physically dispatch while its required batch could not be rendered.
No second persistence mechanism for guidance exists or is needed.

### Reciprocal wakes are an accepted consequence

If the user independently creates a grant A → B *and* a grant B → A and selects Auto-wake for both
lanes, the two sessions can keep waking each other: every accepted wake produces genuinely new
lifecycle edges, and queue receipts, status deduplication, and failed-fingerprint suppression only
collapse *duplicate* edges. This does not violate non-reciprocity — neither grant implies the other,
and the user created both explicitly.

The transport contains no cycle damper, reciprocal-link detector, chain counter, or cooldown, and none
may be added here. **Guidance is not a structural bound either**: revision 3 reduces pointless
discretionary work by telling the model not to invent follow-on work from an update that needs none,
but that is model judgement, not a guarantee, and no surface may describe it as one.

That clause is deliberately two sentences on every surface — *do not invent work from it*, then
*continue what the instructions still require and end only when none remains*. A lane batch also
hitchhikes on turns the observer's own user started, and the per-response notice comes back mid-request,
so a single "report and end" would read as license to abandon the user's in-flight work. Any future
rewording of the contract has to preserve that split across all four surfaces
(`AgentSessionLinkPrompts.autonomyContract`, its compact `laneGuidanceReminder`,
`AgentSessionLinkMCPToolService.untrustedContentNotice`, and the tool description in both
`MCPAgentControlToolProvider` and `AgentSessionLinkAutonomyContractMigration`).

The controls are the user's, and they are the ones that already exist:

| Control | Effect |
| --- | --- |
| Per-lane `snooze_auto_wake` | That lane stops being a reason to start an automatic turn, for a bounded window |
| Auto-wake deselection | That lane stops admitting at all |
| Unlink / revocation | The grant is gone, and any queued send with it |

Each prevents *subsequent* admission and may retract a pre-dispatch attempt. None of them claims to
cancel a physical provider call already in flight.

## Exact projection is presentation truth

An overseer role is derived from one exact live endpoint's stored `AgentMonitorPillProps`, never from
a session UUID, a durable intent, or an authority-wide query. `isOverseer` means exactly that the
projection has at least one outbound row. An inbound-only session is not an overseer.

`agentSessionLinkIsOverseer(tabID:expectedSessionID:)` therefore fails closed unless all of these
still agree:

1. the tab's active session ID;
2. the tab's current generation-bearing endpoint;
3. the projection map key; and
4. `props.endpoint` inside the stored value.

An in-place rebind cannot inherit the retired incarnation's badge or title marker. Active sidebar
rows read this exact role directly rather than caching it in the sidebar list model. `WindowState`
applies the same rule only to the active compose tab, decorates a freshly resolved base title with
`U+1F441 U+FE0E U+0020`, and keeps its fallback title cache undecorated. The final decorated value
flows through `displayedWindowTitle` to native tabs, the Agent titlebar cluster, `NSWindow.title`,
and Dock window lists.

## One post-storage invalidation seam, two consumer schedulers

`agentSessionLinkMutateProjectionStorage` is the sole mutation boundary for the exact projection
map. Its ordering is contractual:

```text
apply every write and removal in the logical batch
→ replace projection storage
→ synchronize the status-pill snapshot
→ post RepoPrompt.agentSessionLinkOverseerProjectionDidChange once
```

Equal replacements post nothing. A batch that changes several exact entries posts only after all of
them are visible. The notification is sent on the main actor, names the owning
`AgentModeViewModel` as `object`, and carries no `userInfo`; consumers re-read exact current state.
Neither the bridge nor the authority posts it, and there is no second role or menu synchronization
path.

The two consumers intentionally use different main-thread schedulers:

| Consumer | Scheduler | Follow-through |
| --- | --- | --- |
| `AgentSessionsSidebarView` | `DispatchQueue.main` | Wrapping revision bump read by `body`; no `.id(revision)` or row-state reset. The queue continues to drain while a system menu is tracking. |
| `WindowState` | `RunLoop.main` | Existing coalesced title request and equality-guarded window-title writer. A projection change that leaves the title equal is harmless. |

## Three eyes have three different meanings

| Eye | Surface | Meaning | Visual and interaction |
| --- | --- | --- | --- |
| Dashboard eye | Existing toolbar `AgentMonitorPill` | Open and manage this observer's oversight dashboard | Existing pill styling; interactive |
| Role eye | Permanently beside an overseer session title | This exact session currently oversees at least one target | Bare purple `eye.fill`; noninteractive; mandatory role help |
| Management eye | Sidebar trailing hover action and context menu | Manage which observers oversee this exact target | Neutral outlined `eye`; interactive menu |

The dashboard pill renders no number at absolute zero and renders each directional count only when
that direction is nonzero. An outbound relationship uses the filled purple eye and outbound count;
an inbound relationship uses the orange directional indicator and inbound count; a bidirectional
state shows both. The complete rounded capsule is the button hit target, while its material and
stroke remain decorative.

The role eye uses fixed system purple rather than the user's accent color. It is a bare filled glyph;
stable placement, its tooltip, and the row's directional accessibility wording ensure the role is not
conveyed by hue alone. It remains visible without hover and in selection mode. The management eye is
hidden with other mutation controls in selection mode. A row may legitimately show both sidebar eyes
at once; their fill, color, placement, interaction, tooltip, and directional accessibility wording
must remain distinct.

## Target-centric sidebar management stays exact

A target menu is a UI-only projection over one exact target endpoint. It carries independent
observer-to-target relationships, so several observers may oversee the same target and unlinking one
must not disturb the others. Available observers are exact live, top-level, observer-eligible Agent
endpoints that the same authority projection says currently hold at least one outbound oversight
link, other than the semantic self. Running, idle, waiting, failed, or completed display state does
not affect availability.

Linked relationships are projected independently of available-overseer membership and retain the
exact observer endpoint and generation-qualified reference even when that observer's live candidate
disappeared or became ineligible. Such a row remains unlinkable. Available options are different:
they intersect authority-owned exact outbound membership with a snapshot of live eligible candidates
and can become stale after a close, rebind, hydration change, MCP capture, role-policy change, or a
change to the candidate's final outbound link.

Staleness is controlled at both boundaries:

- the single projection notification makes the sidebar re-render, and the row resolves the current
  menu again when SwiftUI materializes its hover or context menu;
- Add re-resolves the chosen option immediately before calling the bridge, then the shared exact Add
  core revalidates both endpoint incarnations and eligibility across its suspension points. The
  sidebar entry point additionally requires existing exact outbound membership before durable
  insertion, at reservation, and atomically at activation; other Add surfaces may still create an
  observer's first link.

A stale Add fails closed, focuses neither window, and writes persistent row-level feedback that
survives hover loss and menu dismissal. The authority task itself also survives menu dismissal.
Relationship state is never changed optimistically; the next exact projection publication renders
the result.

### Stop is authority-first

Stop does not use candidate availability as proof. Under the existing pair-retirement lane it asks
`DomainAgentSessionLinkAuthority.activeGrant(for:)` for the generation-qualified reference and
requires the recorded observer and target endpoints to match the captured exact endpoints. An
endpoint mismatch is stale and mutates nothing; an authority-absent reference is idempotently already
stopped, even if the UUID pair was later re-added.

When the grant is active, Stop settles and removes only the bookkeeping or durable token owned by
that exact reference, then revokes only that reference. It never derives a token or replacement grant
from the UUID pair, never deletes a newer token, and never touches another observer of the target.
This is why a target can unlink an authority-recorded observer after that observer's window has
disappeared.

Sidebar unlink is a destructive per-observer action with no confirmation and no Undo. Popup unlink
continues to offer its existing bounded Undo. The sidebar must not reuse the popup's recovery state.

## Seen is an exact `.monitorPoll` presentation commit

`New` is the only explicit acknowledgement control. Opening the dashboard, rendering a row, or using
View Agent does not acknowledge activity. The first authoritative row establishes a baseline; equal
or regressed activity does not reassert `New`, while strictly newer activity does.

The Seen path authorizes `.monitorPoll`, derives the actual generation-qualified reference from its
lease, and compares the expected reference plus both exact endpoints. It then performs final lease
validation, re-reads the live exact candidates, samples the target's current activity, advances the
exact target high-water, and writes the exact observer/target/reference-qualified Seen record
without another suspension. The record is observer-local presentation state: it changes no link
authority, target, prompt, or Agent-visible state. There is no Agent-facing completion action.

## Presentation-only repaints cannot become Auto-wake

The authoritative projection pass may publish prompt inventory and collect and reconcile
passive-status samples.
The presentation-only lane is structurally narrower: `performMonitorProjectionRefresh` builds only
`makeMonitorProjection`, leaves status-sample collection disabled, and deliberately discards its
`statusSamples`. Location, Seen, settings, sidebar-menu eligibility, and observer-role repaints
therefore cannot:

- publish prompt inventory or reconcile the passive reducer;
- advance target-local activity or narrate a status edge;
- enqueue, claim, or receipt an Auto-wake; or
- read, resume, or notify the target session.

The post-storage notification carries no sample, authority value, or mutation request, so its
sidebar and title consumers cannot cross this boundary either. Auto-wake admission continues to read
the canonical passive queue and the wake coordinator described above, never sidebar presentation.

## Snooze suppresses admission, never delivery

A snooze is observer-local policy on one exact lane. It is keyed by
`(observer endpoint, generation-qualified link reference)`, held only in process memory on the
owning `AgentTabSession`, and dies with that incarnation — a rebind, unlink/relink, or relaunch
always starts unsnoozed.

What it does: stops that lane from being the reason an automatic turn starts.

What it deliberately does **not** do, and must never be changed to do:

- filter, receipt, baseline, or discard the canonical queue;
- change link authority, durable Auto-wake selection, or failure suppression;
- read, write, resume, or notify the overseen session.

Consequences that follow from that, and are intended rather than bugs:

- a snoozed lane's updates keep coalescing and still ride along on a turn the observer's own user
  starts, or on a wake another unsnoozed lane admitted (a *hitchhiker*);
- expiry promises **one ordinary re-evaluation**, not a turn. The usual readiness, authority,
  selection and suppression gates still decide, so content already delivered naturally, or a lane
  that net-reverted, correctly produces nothing.

Because the reducer keeps one coalesced interval per lane and no event history, the only honest
description of what survives a snooze is "the current coalesced summary" — never a count of missed
events. Copy and model guidance are written to that standard on purpose.

## The `.cancelledBeforeDispatch` tombstone is a fence, not bookkeeping

When a snooze — or any eligibility loss — retracts a wake that is already in `.preparingDispatch`,
`cancelAgentSessionLinkAutoWake` does not clear the attempt. It converts it to
`.cancelledBeforeDispatch` and leaves it in place.

That tombstone looks like dead state and is not. Providers do not mint the wake's dispatch ID — they
use their own (`codexNativeSend`, `claudeNativeSend`, `codexFallback`, and so on), and
`agentSessionLinkEffectiveDispatchID` plus `AgentModeViewModel.dispatchRequiresLaneBatch` (both in
`AgentModeViewModel+SessionLinkPrompt.swift`) rewrite that ID to the wake's **only while an attempt
exists in `.preparingDispatch`, `.cancelledBeforeDispatch`, or `.dispatching`**.

Clear the tombstone while a provider path is still preparing and the rewrite stops happening: the
provider's own ordinary ID reaches `agentSessionLinkAcquirePhysicalDispatch`, which correctly
classifies it as *not* in the reserved Auto-wake family and returns `true`. The call goes through
unfenced, and the snoozed lane wakes the model with no claim and no provenance row.

The reserved family itself fails closed. An ID whose raw form is in the `lane.autowake:` family but
does not parse as exactly one canonical UUID is refused rather than treated as ordinary, and
`dispatchRequiresLaneBatch` classifies the whole family as non-ordinary, so a constructor and parser
that disagreed could not downgrade an Auto-wake into an unfenced dispatch. That protects the *format*;
it cannot protect a rewrite that was never applied, which is what the tombstone is for.

Two rules follow.

1. **Only a path that can prove no transport call happened may release a tombstone** — the
   preparation finalizer, the physical-acquisition refusal, or an explicit not-attempted settlement.
2. **`cancelAgentSessionLinkAutoWake` is not idempotent across phases.** It converts
   `.preparingDispatch` into a tombstone, but a *second* cancel of an already-tombstoned attempt
   falls past both phase guards and clears the slot. Any new caller must check the phase first.
   Repeated eligibility loss is the ordinary case, not an exotic one: the snoozed lane publishing
   again, an extension, or even an idempotent repeat all re-drive that path.

A tombstone can never be rescheduled, so a publication absorbed while it stands schedules nothing.
The preparation finalizer replays one ordinary evaluation after releasing it, which is what keeps
the expiry and clear promises true.

## Lane attribution is local display only

An accepted Auto-wake appends one `.system` provenance row. Its raw `text` is a fixed canonical
marker and must stay that way: transcript replay re-emits system rows verbatim inside
`<system>…</system>`, so interpolating a target-derived name there would put untrusted target prose
into trusted-looking provider context and could break the envelope.

Richer wording is derived at render time from `AgentLaneUpdateDisplayAttribution`, typed metadata
captured from the **immutable rendered batch of the accepted claim** — never from live links,
selection, or snooze state, all of which can change between construction and acceptance. It carries
at most two already-capped, sanitized labels, a distinct-lane count, and one overflow flag: no UUID,
reference, endpoint, preview, path, or status payload. Labels are stripped of format and bidi
scalars, and the sentence's own curly quote delimiters are folded to ASCII inside a label, so an
untrusted name cannot close the quoted span the grammar opened around it.

## Known deferred work

These are accepted, not undiscovered. They share one root cause: **the wake attempt stays mutable
after its provider claim is immutable, and the tombstone that fences an in-flight dispatch lives in
the same single slot as the live attempt.** The remedy is one change — an immutable in-flight
dispatch record on `AgentTabSession`, separate from the mutable reservation — not three patches.

1. **Post-final-composition absorption.** An edge arriving after the provider composed its claim but
   before physical acquisition is absorbed into the mutable attempt's `attemptedFingerprint` without
   being in the sent text, so the attempt's record of what was attempted outruns the immutable claim.
   Nothing is *consumed* on acceptance any more — the target-local human-re-arm epochs that used to be
   are gone — so what survives is the fingerprint divergence itself, which can suppress a later retry
   of content that was never delivered. The sent *content* stays correct: the claim store re-renders rather than reusing a parked claim once
   the queue moves, because `ClaimFingerprint` carries the passive queue epoch and revision. The
   waiting-continuation route is synchronous through acceptance and has no window at all.
2. **Acquire-path tombstone release skips the replay,** so a reevaluation absorbed while the
   tombstone stood is lost. The fence still holds and it self-heals on the next status edge.
   Replaying inside provider composition would be the wrong fix; a one-shot owed marker drained at
   the next safe point is the right one.
3. **Selection-fence and master-toggle release of a tombstone.** Both reach the same non-idempotent
   cancel fall-through. Snooze widened this: it mints tombstones *and* holds eligibility false, so
   one "snooze this lane… actually, deselect it" inside the preparation window now suffices where
   two independent eligibility events were needed before. Every trigger requires an explicit user or
   agent action; nothing fires autonomously.
