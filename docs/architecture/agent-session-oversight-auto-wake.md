# Agent session oversight: Auto-wake admission and lane snooze

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

## Snooze suppresses admission, never delivery

A snooze is observer-local policy on one exact lane. It is keyed by
`(observer endpoint, generation-qualified link reference)`, held only in process memory on the
owning `AgentTabSession`, and dies with that incarnation — a rebind, unlink/relink, or relaunch
always starts unsnoozed.

What it does: stops that lane from being the reason an automatic turn starts.

What it deliberately does **not** do, and must never be changed to do:

- filter, receipt, baseline, or discard the canonical queue;
- change link authority, durable Auto-wake selection, turn origin, or failure suppression;
- consume a target-local human epoch;
- read, write, resume, or notify the overseen session.

Consequences that follow from that, and are intended rather than bugs:

- a snoozed lane's updates keep coalescing and still ride along on a turn the observer's own user
  starts, or on a wake another unsnoozed lane admitted (a *hitchhiker*);
- expiry promises **one ordinary re-evaluation**, not a turn. The usual readiness, authority,
  anti-chain and suppression gates still decide, so content already delivered naturally, or a lane
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

Clear the tombstone while a provider path is still preparing and
`agentSessionLinkAcquirePhysicalDispatch` takes its `autoWakeID == nil` early return: the call goes
through unfenced, and the snoozed lane wakes the model with no provenance row and no anti-chain.

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
   before physical acquisition is absorbed into `attemptedFingerprint` and `humanRearmEpochs`
   without being in the sent text, so acceptance can consume an epoch for undelivered content. The
   sent *content* stays correct: the claim store re-renders rather than reusing a parked claim once
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
