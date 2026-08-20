import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Monitor pill rendering contract: directional row labels, accessibility text, status mapping, and
/// endpoint-relative revocation notices.
final class AgentMonitorPillPropsTests: XCTestCase {
    private let targetID = UUID(uuidString: "8B910000-0000-0000-0000-00000000E572")!
    private let observerID = UUID(uuidString: "04CF0000-0000-0000-0000-000000771A00")!

    private func outbound(
        status: AgentMonitorLinkStatus = .idle,
        displayName: String = "Build API",
        lastActivityAt: Date? = nil,
        triageState: AgentMonitorTriageState = .active,
        hasUnreadActivity: Bool = false,
        targetRoute: AgentSessionDeepLinkRoute? = nil,
        autoWakeSnooze: AgentMonitorAutoWakeSnoozeState? = nil,
        isAutoWakeEffectivelySelected: Bool = false
    ) -> AgentMonitorPillProps.Outbound {
        AgentMonitorPillProps.Outbound(
            linkID: UUID(),
            generation: 1,
            targetSessionID: targetID,
            displayName: displayName,
            providerDisplayName: "Codex CLI",
            locationLabel: "worktree/feature",
            status: status,
            lastActivityAt: lastActivityAt,
            triageState: triageState,
            hasUnreadActivity: hasUnreadActivity,
            targetRoute: targetRoute,
            autoWakeSnooze: autoWakeSnooze,
            isAutoWakeEffectivelySelected: isAutoWakeEffectivelySelected
        )
    }

    // MARK: - Fixed reference clock

    /// Freshness is calendar-aware, so the tests pin a calendar, time zone, and locale rather than
    /// inheriting the machine's. Bucket selection is the contract; the rendered clock/date text is
    /// compared against an independently constructed formatter.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private let locale = Locale(identifier: "en_US_POSIX")

    private func moment(
        year: Int = 2026,
        month: Int = 8,
        day: Int = 13,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        ) ?? Date(timeIntervalSince1970: 0)
    }

    private func compact(_ date: Date?, now: Date) -> String {
        AgentMonitorActivityFormatter.compact(date, now: now, calendar: calendar, locale: locale)
    }

    private func expectedShortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func expectedCompactDate(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private func inbound(displayName: String = "Planning") -> AgentMonitorPillProps.Inbound {
        AgentMonitorPillProps.Inbound(
            linkID: UUID(),
            generation: 1,
            observerSessionID: observerID,
            displayName: displayName,
            providerDisplayName: "Claude Code"
        )
    }

    private func makeProps(
        outbound: [AgentMonitorPillProps.Outbound] = [],
        inbound: [AgentMonitorPillProps.Inbound] = [],
        notices: [AgentMonitorPillProps.Notice] = [],
        canAddReason: String? = nil,
        autoWakeOnUpdatesEnabled: Bool = false,
        autoWakeTargetSessionIDs: Set<UUID> = []
    ) -> AgentMonitorPillProps {
        AgentMonitorPillProps(
            sessionID: observerID,
            outbound: outbound,
            inbound: inbound,
            recentNotices: notices,
            canAddReason: canAddReason,
            autoWakeOnUpdatesEnabled: autoWakeOnUpdatesEnabled,
            autoWakeTargetSessionIDs: autoWakeTargetSessionIDs
        )
    }

    // MARK: - Identifiers

    func testShortIDKeepsBothEndsSoRowsStayDistinguishable() {
        XCTAssertEqual(AgentMonitorSessionIDFormatter.short(targetID), "8B91…E572")
        XCTAssertEqual(AgentMonitorSessionIDFormatter.short(observerID), "04CF…1A00")
    }

    /// Two overseen sessions can carry the same display name, so the token is the row's only
    /// at-a-glance identity breaker. It must never render two visible rows identically, and it must
    /// not widen rows that are already unambiguous.
    func testShortTokensWidenOnlyForCollidingRowsAndFallBackToTheFullUUID() {
        let first = UUID(uuidString: "8B910000-0000-0000-0000-00000000E572")
        let second = UUID(uuidString: "8B911111-0000-0000-0000-00000000E572")
        let distinct = UUID(uuidString: "04CF0000-0000-0000-0000-000000771A00")
        guard let first, let second, let distinct else { return XCTFail("malformed fixture UUID") }

        let tokens = AgentMonitorSessionIDFormatter.distinctShortTokens(for: [first, second, distinct])
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(Set(tokens.values).count, 3, "two visible rows would render the same token")
        XCTAssertEqual(
            tokens[distinct],
            "04CF…1A00",
            "an unambiguous row must not pay for another row's collision"
        )
        // One extra character at each end is enough to separate this pair, and no more is spent.
        XCTAssertEqual(tokens[first], "8B910…0E572")
        XCTAssertEqual(tokens[second], "8B911…0E572")
        for token in tokens.values {
            XCTAssertTrue(token.contains("…"), "both ends must survive: \(token)")
        }

        // Same input, same output: the token is a function of the visible set, never of ordering.
        XCTAssertEqual(
            AgentMonitorSessionIDFormatter.distinctShortTokens(for: [distinct, second, first]),
            tokens
        )

        // Nothing widens forever. A pair that stays ambiguous at every bounded length falls back to
        // the canonical UUID rather than rendering an ambiguous row.
        let repeated = AgentMonitorSessionIDFormatter.distinctShortTokens(for: [first, first])
        XCTAssertEqual(repeated, [first: "8B91…E572"])
        XCTAssertEqual(AgentMonitorSessionIDFormatter.distinctShortTokens(for: []), [:])
    }

    func testRowsCarryDirectionAndExposeTheFullUUID() {
        let out = outbound()
        // The outbound row renders name and identity token as separate views, so the model carries
        // the hover identity rather than one pre-joined label the layout would have to truncate.
        XCTAssertEqual(out.identityTooltip, "Build API\n\(targetID.uuidString)")
        XCTAssertEqual(out.shortID, "8B91…E572")
        XCTAssertEqual(out.fullID, targetID.uuidString)
        XCTAssertEqual(out.id, out.linkID)

        let inb = inbound()
        XCTAssertEqual(inb.rowLabel, "← Planning (04CF…1A00)")
        XCTAssertEqual(inb.fullID, observerID.uuidString)
    }

    func testAccessibilityDescriptionsCarryTheFullUUIDAndStatusWord() {
        XCTAssertEqual(
            outbound(status: .awaitingUser).accessibilityDescription,
            "Overseeing Build API in worktree/feature, session \(targetID.uuidString), "
                + "Waiting for input in its window, Last activity unavailable"
        )
        XCTAssertEqual(
            inbound().accessibilityDescription,
            "Overseen by Planning, session \(observerID.uuidString)"
        )
    }

    /// Location is the primary visual discriminator on these rows, so a VoiceOver user hearing only a
    /// UUID is materially worse off than a sighted one.
    func testOutboundAccessibilityNamesTheLocationAndDegradesWhenItIsUnknown() {
        XCTAssertEqual(
            outbound().accessibilityDescription,
            "Overseeing Build API in worktree/feature, session \(targetID.uuidString), "
                + "Idle, Last activity unavailable"
        )
        // A row whose target incarnation could not be resolved carries no location; the sentence must
        // stay grammatical rather than speaking an empty slot.
        XCTAssertEqual(
            AgentMonitorPillProps.Outbound(
                linkID: UUID(),
                generation: 1,
                targetSessionID: targetID,
                displayName: "Build API",
                providerDisplayName: nil,
                locationLabel: nil,
                status: .unavailable
            ).accessibilityDescription,
            "Overseeing Build API, session \(targetID.uuidString), "
                + "Unavailable, Last activity unavailable"
        )
    }

    // MARK: - Detail line

    /// Location leads: across many sessions spanning two providers the provider name distinguishes
    /// almost nothing, while the worktree/workspace distinguishes strongly.
    func testDetailLineLeadsWithLocationWhereAvailable() {
        let outbound = outbound()
        XCTAssertEqual(
            outbound.detailLine,
            "worktree/feature · Codex CLI · Activity unavailable"
        )
        XCTAssertEqual(outbound.locationProviderLine, "worktree/feature · Codex CLI")
        XCTAssertEqual(
            outbound.metadataLine(now: moment(hour: 15), calendar: calendar, locale: locale),
            "worktree/feature · Codex CLI · Activity unavailable",
            "metadata stays on one line and visible status remains on the status dot"
        )
        // Inbound carries neither status nor location: nothing observes an observer's session, so
        // neither value has a path that would refresh it. See
        // `testInboundRowsCannotRenderALocationThatNothingRefreshes`.
        XCTAssertEqual(inbound().detailLine, "Claude Code")
        XCTAssertEqual(
            AgentMonitorResolvedPreview(
                sessionID: targetID,
                displayName: "Build API",
                providerDisplayName: "Codex CLI",
                locationLabel: "worktree/feature",
                status: .running
            ).detailLine,
            "worktree/feature · Codex CLI"
        )
    }

    func testOutboundKeepsActivityRouteAndDoneSeparateFromLiveStatus() {
        let activity = Date(timeIntervalSince1970: 123)
        let route = AgentSessionDeepLinkRoute(
            windowID: 7,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: targetID
        )
        let row = outbound(
            status: .running,
            lastActivityAt: activity,
            triageState: .done,
            targetRoute: route
        )

        XCTAssertEqual(row.status, .running)
        XCTAssertEqual(row.lastActivityAt, activity)
        XCTAssertEqual(row.triageState, .done)
        XCTAssertEqual(row.targetRoute, route)
        XCTAssertTrue(row.activityAccessibilityLabel.hasPrefix("Last activity "))
        XCTAssertTrue(row.accessibilityDescription.hasSuffix(", Done"))
    }

    /// A blank location slot is ambiguous between "the main checkout" and "we have no idea", which
    /// defeats the point of a line whose job is telling windows apart.
    func testLocationLabelNamesTheWorkspaceWhenNoWorktreeIsBound() {
        XCTAssertEqual(
            AgentMonitorLocationLabelFormatter.label(
                worktreeLabel: "feature-219",
                workspaceName: "repoprompt-ce"
            ),
            "feature-219"
        )
        // Qualified rather than bare, so the workspace name cannot read as a worktree that does not
        // exist.
        XCTAssertEqual(
            AgentMonitorLocationLabelFormatter.label(worktreeLabel: nil, workspaceName: "repoprompt-ce"),
            "repoprompt-ce (main)"
        )
        XCTAssertEqual(
            AgentMonitorLocationLabelFormatter.label(worktreeLabel: "   ", workspaceName: "  "),
            "main"
        )
        XCTAssertEqual(
            AgentMonitorLocationLabelFormatter.label(worktreeLabel: nil, workspaceName: nil),
            "main"
        )
    }

    /// Every row renders a visually identical Unlink action, so the accessible label is the only
    /// thing that says which link it ends. Each side phrases it from its own perspective.
    func testUnlinkActionLabelsNameTheLinkFromEachEndpointsPerspective() {
        XCTAssertEqual(outbound().unlinkActionLabel, "Unlink oversight of Build API")
        XCTAssertEqual(inbound().unlinkActionLabel, "Unlink Planning from overseeing this session")
    }

    /// An observer can change its own execution location while a link is live, and nothing in the
    /// system tells the overseen session about it: `commitWorktreeBindings` is the only mutation point
    /// for `worktreeBindings` and it neither bumps `bindingTransitionGeneration` (so the endpoint
    /// identity does not drift and the link is neither revoked nor rebound) nor feeds
    /// `monitorObservationSignal`, and observations are installed only on overseen *targets*. A
    /// location on this row would therefore be a value with no refresh path, exactly like the status
    /// this row already omits.
    func testInboundRowsCannotRenderALocationThatNothingRefreshes() {
        let line = inbound().detailLine
        XCTAssertEqual(line, "Claude Code")
        XCTAssertFalse(line.contains("·"), "a second slot here would be a value nothing can refresh")
        // The accessible sentence is the other surface that could reintroduce it.
        XCTAssertEqual(
            inbound().accessibilityDescription,
            "Overseen by Planning, session \(observerID.uuidString)"
        )
    }

    /// The preview is what the user authorizes, so its label must read the full canonical UUID: the
    /// visible short form is ambiguous by construction. It names the location for the same reason the
    /// visible row leads with it.
    func testResolvedPreviewAccessibilityLabelReadsTheFullUUIDLocationAndStatus() {
        let preview = AgentMonitorResolvedPreview(
            sessionID: targetID,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            locationLabel: "repoprompt-ce (main)",
            status: .awaitingUser
        )
        XCTAssertEqual(preview.shortID, "8B91…E572")
        XCTAssertEqual(
            preview.accessibilityLabel,
            "Resolved Build API in repoprompt-ce (main), session \(targetID.uuidString), "
                + "Waiting for input in its window"
        )
        XCTAssertEqual(
            AgentMonitorResolvedPreview(
                sessionID: targetID,
                displayName: "Build API",
                providerDisplayName: nil,
                locationLabel: nil,
                status: .idle
            ).accessibilityLabel,
            "Resolved Build API, session \(targetID.uuidString), Idle"
        )
    }

    // MARK: - Pill state

    func testAccessibilityValueDescribesBothDirections() {
        XCTAssertEqual(makeProps().accessibilityValue, "Not overseeing any sessions.")
        XCTAssertEqual(
            makeProps(outbound: [outbound()]).accessibilityValue,
            "Overseeing 1 session."
        )
        XCTAssertEqual(
            makeProps(outbound: [outbound(), outbound()], inbound: [inbound()]).accessibilityValue,
            "Overseeing 2 sessions; overseen by 1."
        )
        XCTAssertEqual(
            makeProps(inbound: [inbound()]).accessibilityValue,
            "Not overseeing any sessions; overseen by 1."
        )
    }

    func testActiveAndInboundFlagsAreIndependent() {
        XCTAssertFalse(makeProps().isActive)
        XCTAssertFalse(makeProps().hasInbound)
        XCTAssertTrue(makeProps(outbound: [outbound()]).isActive)
        XCTAssertFalse(makeProps(outbound: [outbound()]).hasInbound)
        // Being observed must not make the pill look like it is observing someone.
        XCTAssertFalse(makeProps(inbound: [inbound()]).isActive)
        XCTAssertTrue(makeProps(inbound: [inbound()]).hasInbound)
    }

    func testAddIsDisabledWithAnExplicitReason() {
        XCTAssertTrue(makeProps().canAdd)
        let blocked = makeProps(canAddReason: "This session can’t oversee other sessions.")
        XCTAssertFalse(blocked.canAdd)
        XCTAssertEqual(blocked.canAddReason, "This session can’t oversee other sessions.")

        // A tab with no durable binding may still open the popover; only Add is disabled.
        XCTAssertNil(AgentMonitorPillProps.empty.sessionID)
        XCTAssertFalse(AgentMonitorPillProps.empty.canAdd)
        XCTAssertEqual(
            AgentMonitorPillProps.empty.canAddReason,
            AgentSessionLinkEndpointEligibility.noDurableBindingReason
        )
    }

    // MARK: - Live eligibility overlay

    private func eligibility(
        hasDurableBinding: Bool = true,
        hasLoadedPersistedState: Bool = true,
        isChildSession: Bool = false,
        isMCPControlled: Bool = false,
        isMCPOriginated: Bool = false,
        bindingTransitionInProgress: Bool = false,
        isClosing: Bool = false
    ) -> AgentSessionLinkEndpointEligibility.Input {
        AgentSessionLinkEndpointEligibility.Input(
            hasDurableBinding: hasDurableBinding,
            hasLoadedPersistedState: hasLoadedPersistedState,
            isChildSession: isChildSession,
            isMCPControlled: isMCPControlled,
            isMCPOriginated: isMCPOriginated,
            bindingTransitionInProgress: bindingTransitionInProgress,
            isClosing: isClosing
        )
    }

    func testLinkLessSessionRecoversAddEligibilityAfterHydrationWithoutAnAuthorityEvent() {
        // A link-less session can still have a projection published: a full refresh caused by some
        // *other* session's link activity rebuilds every window. If that happened while this tab was
        // still loading, the stored reason is stale the moment hydration finishes, and hydration
        // produces no authority event that would ever correct it.
        let stalePublished = makeProps(canAddReason: "Load this thread before adding sessions to oversee.")

        let recovered = AgentModeViewModel.monitorPillProps(
            sessionID: observerID,
            published: stalePublished,
            eligibility: eligibility(),
            roleAllowsOutboundMonitoring: true
        )
        XCTAssertNil(recovered.canAddReason)
        XCTAssertTrue(recovered.canAdd)
        XCTAssertEqual(recovered.sessionID, observerID)
    }

    func testAddEligibilityRecoversAfterARebindSettles() {
        let stalePublished = makeProps(
            canAddReason: "This session is changing its binding. Try again in a moment."
        )
        let midRebind = AgentModeViewModel.monitorPillProps(
            sessionID: observerID,
            published: stalePublished,
            eligibility: eligibility(bindingTransitionInProgress: true),
            roleAllowsOutboundMonitoring: true
        )
        XCTAssertFalse(midRebind.canAdd)

        let settled = AgentModeViewModel.monitorPillProps(
            sessionID: observerID,
            published: stalePublished,
            eligibility: eligibility(),
            roleAllowsOutboundMonitoring: true
        )
        XCTAssertTrue(settled.canAdd)
    }

    func testOverlayPreservesAuthoritativeLinkAndNoticeProjection() {
        // Only eligibility is recomputed; link membership, triage, unread, and notices stay
        // authority-owned. A copy helper that dropped unread would silently clear a signal the user
        // has not acknowledged.
        let notice = AgentMonitorPillProps.Notice(linkID: UUID(), generation: 3, message: "ended")
        let published = makeProps(
            outbound: [outbound(status: .running, triageState: .done, hasUnreadActivity: true)],
            inbound: [inbound()],
            notices: [notice],
            canAddReason: "Load this thread before adding sessions to oversee.",
            autoWakeOnUpdatesEnabled: true,
            autoWakeTargetSessionIDs: [targetID]
        )

        let overlaid = AgentModeViewModel.monitorPillProps(
            sessionID: observerID,
            published: published,
            eligibility: eligibility(),
            roleAllowsOutboundMonitoring: true
        )
        XCTAssertEqual(overlaid.outbound, published.outbound)
        XCTAssertTrue(overlaid.outbound.allSatisfy(\.hasUnreadActivity))
        XCTAssertEqual(overlaid.inbound, published.inbound)
        XCTAssertEqual(overlaid.recentNotices, published.recentNotices)
        XCTAssertNil(overlaid.canAddReason)
        XCTAssertTrue(
            overlaid.autoWakeOnUpdatesEnabled,
            "a copy helper that dropped the preference would silently stop the toggle reflecting it"
        )

        // The persistence overlay is the other copy path and must preserve the same fields.
        let withPersistence = published.withPersistence(
            AgentSessionOversightPersistencePresentation(availability: .dormant),
            eligibilityReason: nil
        )
        XCTAssertEqual(withPersistence.outbound, published.outbound)
        XCTAssertEqual(withPersistence.inbound, published.inbound)
        XCTAssertEqual(withPersistence.recentNotices, published.recentNotices)
        XCTAssertTrue(withPersistence.autoWakeOnUpdatesEnabled)
        XCTAssertEqual(withPersistence.autoWakeTargetSessionIDs, [targetID])
        XCTAssertTrue(published.withCanAddReason("changed").autoWakeOnUpdatesEnabled)
        XCTAssertEqual(published.withCanAddReason("changed").autoWakeTargetSessionIDs, [targetID])
    }

    /// The switch is the only place the user learns what auto-wake does, so its copy has to carry the
    /// whole contract — and in particular the three halves that are easy to assume wrongly: updates
    /// arrive either way, a busy agent is never interrupted, and automatic turns do not chain.
    func testAutoWakeCopyStatesTheAlwaysOnAndBoundedFollowUpContract() {
        let tooltip = AgentMonitorAutoWakeCopy.tooltip
        XCTAssertTrue(
            tooltip.contains("always attached"),
            "the user must learn that turning this off does not turn updates off"
        )
        XCTAssertTrue(tooltip.contains("one follow-up turn"))
        XCTAssertTrue(tooltip.contains("already-accepted work first"))
        XCTAssertTrue(tooltip.contains("never chain"))
        XCTAssertTrue(
            tooltip.contains("this session"),
            "the scope is the observer session, not a link and not a global preference"
        )
        XCTAssertTrue(
            tooltip.contains("Off by default"),
            "the default has to be visible where the control is"
        )
        XCTAssertTrue(
            AgentMonitorAutoWakeCopy.accessibilityHint.contains("either way"),
            "VoiceOver users must get the same contract, not just the label"
        )
        // Zero links is a real, saved state, and the note has to say so rather than read as an error.
        XCTAssertTrue(AgentMonitorAutoWakeCopy.noLinksNote.contains("Saved with this session"))
    }

    func testOverlayStillDisablesAddWhenLiveStateSaysSo() {
        // The overlay must be able to *disable* Add too, not only re-enable it: a session that was
        // eligible when published can later become unbound, child-owned, or MCP-controlled.
        let published = makeProps(outbound: [outbound()], canAddReason: nil)

        XCTAssertEqual(
            AgentModeViewModel.monitorPillProps(
                sessionID: observerID,
                published: published,
                eligibility: eligibility(hasDurableBinding: false),
                roleAllowsOutboundMonitoring: true
            ).canAddReason,
            AgentSessionLinkEndpointEligibility.noDurableBindingReason
        )
        XCTAssertEqual(
            AgentModeViewModel.monitorPillProps(
                sessionID: observerID,
                published: published,
                eligibility: eligibility(isMCPControlled: true),
                roleAllowsOutboundMonitoring: true
            ).canAddReason,
            AgentSessionLinkEndpointEligibility.roleDeniedReason
        )
        XCTAssertEqual(
            AgentModeViewModel.monitorPillProps(
                sessionID: observerID,
                published: published,
                eligibility: eligibility(),
                roleAllowsOutboundMonitoring: false
            ).canAddReason,
            AgentSessionLinkEndpointEligibility.roleDeniedReason
        )
    }

    func testOverlayWithNoPublishedProjectionStillReportsLiveEligibility() {
        let fresh = AgentModeViewModel.monitorPillProps(
            sessionID: observerID,
            published: nil,
            eligibility: eligibility(hasLoadedPersistedState: false),
            roleAllowsOutboundMonitoring: true
        )
        XCTAssertEqual(fresh.sessionID, observerID)
        XCTAssertTrue(fresh.outbound.isEmpty)
        XCTAssertEqual(fresh.canAddReason, "Load this thread before adding sessions to oversee.")
    }

    func testWithCanAddReasonIsIdentityPreservingWhenUnchanged() {
        let props = makeProps(outbound: [outbound()], canAddReason: nil)
        XCTAssertEqual(props.withCanAddReason(nil), props)
    }

    // MARK: - Status mapping

    func testPendingInteractionAlwaysOutranksRawRunState() {
        // A running target that is blocked on the user must read as "waiting", never as "running".
        XCTAssertEqual(
            AgentMonitorLinkStatus(status: .running, pendingInteraction: .approval),
            .awaitingUser
        )
        XCTAssertEqual(
            AgentMonitorLinkStatus(status: .idle, pendingInteraction: .question),
            .awaitingUser
        )
        XCTAssertEqual(AgentMonitorLinkStatus(status: .running, pendingInteraction: nil), .running)
        XCTAssertEqual(AgentMonitorLinkStatus(status: .idle, pendingInteraction: nil), .idle)
        XCTAssertEqual(AgentMonitorLinkStatus(status: .awaitingUser, pendingInteraction: nil), .awaitingUser)
    }

    func testEveryStatusCarriesTextAndAShapeSoColourIsNeverTheOnlyCue() {
        for status in [
            AgentMonitorLinkStatus.idle,
            .running,
            .awaitingUser,
            .unavailable
        ] {
            XCTAssertFalse(status.label.isEmpty, "\(status) has no label")
            XCTAssertFalse(status.tooltip.isEmpty, "\(status) has no hover explanation")
            XCTAssertNotEqual(
                status.tooltip,
                status.label,
                "a tooltip that repeats the visible label explains nothing"
            )
        }
    }

    /// Status words are spoken verbatim inside row and preview accessibility text, so they are part
    /// of the user-facing contract rather than incidental strings.
    func testStatusLabelsAreTheExactSpokenWords() {
        XCTAssertEqual(AgentMonitorLinkStatus.idle.label, "Idle")
        XCTAssertEqual(AgentMonitorLinkStatus.running.label, "Running")
        XCTAssertEqual(AgentMonitorLinkStatus.awaitingUser.label, "Waiting for input")
        XCTAssertEqual(
            AgentMonitorLinkStatus.awaitingUser.accessibilityLabel,
            "Waiting for input in its window"
        )
        XCTAssertEqual(AgentMonitorLinkStatus.unavailable.label, "Unavailable")
    }

    /// Shapes and tones must stay distinct per status: two statuses sharing a mark would make the
    /// row unreadable for anyone relying on shape rather than colour, which is exactly the audience
    /// the dot vocabulary exists for.
    func testStatusIndicatorsAreDistinctAndOnlyRunningAsksToPulse() {
        let indicators: [(AgentMonitorLinkStatus, AgentMonitorStatusIndicatorDescriptor)] = [
            (.idle, AgentMonitorStatusIndicatorDescriptor(shape: .hollowRing, tone: .neutral, pulses: false)),
            (.running, AgentMonitorStatusIndicatorDescriptor(shape: .haloedDot, tone: .live, pulses: true)),
            (
                .awaitingUser,
                AgentMonitorStatusIndicatorDescriptor(shape: .attentionDot, tone: .attention, pulses: false)
            ),
            (
                .unavailable,
                AgentMonitorStatusIndicatorDescriptor(shape: .slashedRing, tone: .dimmed, pulses: false)
            )
        ]
        for (status, expected) in indicators {
            XCTAssertEqual(status.indicator, expected, "\(status) renders the wrong mark")
        }
        let shapes = indicators.map(\.1.shape)
        XCTAssertEqual(Set(shapes).count, shapes.count, "statuses share a shape: \(shapes)")
        let tones = indicators.map(\.1.tone)
        XCTAssertEqual(Set(tones).count, tones.count, "statuses share a tone: \(tones)")
        // Motion is reserved for the one state that is actually changing. Everything else must be
        // still, so a glance at the popover finds the working lane rather than four moving dots.
        XCTAssertEqual(indicators.filter(\.1.pulses).map(\.0), [.running])
    }

    /// Reduce Motion may take the animation and nothing else.
    ///
    /// The mark list is what the indicator view actually draws, so this is the rendered structure
    /// rather than the descriptor's enum label. Asserted because the obvious implementation — a lone
    /// filled dot whose only halo is the suppressed pulse — leaves Running and Waiting separated by
    /// colour alone for exactly the users who asked for less motion.
    func testReduceMotionRemovesOnlyThePulseAndNeverTheShapeDistinction() {
        let running = AgentMonitorLinkStatus.running.indicator
        XCTAssertEqual(running.marks(reduceMotion: false), [.pulse, .halo, .dot])
        XCTAssertEqual(running.marks(reduceMotion: true), [.halo, .dot])

        let statuses: [AgentMonitorLinkStatus] = [.idle, .running, .awaitingUser, .unavailable]
        for status in statuses where status != .running {
            XCTAssertEqual(
                status.indicator.marks(reduceMotion: false),
                status.indicator.marks(reduceMotion: true),
                "\(status) has no motion to reduce"
            )
        }

        // The pair the shape vocabulary exists for: with motion off, Running and Waiting must still
        // differ by drawn geometry rather than by tint.
        XCTAssertNotEqual(
            running.marks(reduceMotion: true),
            AgentMonitorLinkStatus.awaitingUser.indicator.marks(reduceMotion: true)
        )
        let reduced = statuses.map { $0.indicator.marks(reduceMotion: true) }
        XCTAssertEqual(
            Set(reduced.map { $0.map(\.rawValue).joined(separator: "+") }).count,
            reduced.count,
            "statuses share a drawn shape under Reduce Motion: \(reduced)"
        )
    }

    // MARK: - Freshness ladder

    /// Bucket selection is the contract. Minutes deliberately outrank the calendar buckets, so
    /// activity shortly before local midnight reads as minutes rather than jumping to `Yesterday`.
    func testCompactFreshnessPicksTheFirstMatchingBucket() {
        let now = moment(hour: 15, minute: 30)

        XCTAssertEqual(compact(nil, now: now), "Activity unavailable")
        XCTAssertEqual(compact(now, now: now), "just now")
        XCTAssertEqual(compact(now.addingTimeInterval(-59), now: now), "just now")
        // A target clock running ahead of this one is skew, not a scheduled future event.
        XCTAssertEqual(compact(now.addingTimeInterval(600), now: now), "just now")
        XCTAssertEqual(compact(now.addingTimeInterval(-60), now: now), "1m ago")
        XCTAssertEqual(compact(now.addingTimeInterval(-59 * 60), now: now), "59m ago")

        let earlierToday = moment(hour: 9, minute: 7)
        XCTAssertEqual(compact(earlierToday, now: now), expectedShortTime(earlierToday))
        // Exactly one hour is already past the minutes bucket.
        XCTAssertEqual(
            compact(now.addingTimeInterval(-3600), now: now),
            expectedShortTime(now.addingTimeInterval(-3600))
        )

        XCTAssertEqual(compact(moment(day: 12, hour: 9), now: now), "Yesterday")
        // Same-day-boundary case: 20 minutes ago is still 20 minutes ago, even across midnight.
        XCTAssertEqual(
            compact(moment(day: 12, hour: 23, minute: 50), now: moment(day: 13, hour: 0, minute: 10)),
            "20m ago"
        )

        let thisYear = moment(month: 3, day: 2, hour: 9)
        XCTAssertEqual(compact(thisYear, now: now), expectedCompactDate(thisYear, template: "MMM d"))
        let lastYear = moment(year: 2025, month: 12, day: 20, hour: 9)
        XCTAssertEqual(
            compact(lastYear, now: now),
            expectedCompactDate(lastYear, template: "MMM d y"),
            "an older year must say which year"
        )
    }

    /// The compact ladder is glanceable but lossy, so both hover and VoiceOver get the full instant.
    func testAbsoluteAndAccessibilityFormsCarryTheFullInstant() {
        let sample = moment(hour: 15, minute: 7)
        let absolute = AgentMonitorActivityFormatter.absolute(sample, calendar: calendar, locale: locale)
        XCTAssertTrue(absolute.contains("2026"), "hover detail must resolve the day: \(absolute)")
        XCTAssertEqual(
            AgentMonitorActivityFormatter.accessibility(sample, calendar: calendar, locale: locale),
            "Last activity \(absolute)"
        )

        XCTAssertEqual(
            AgentMonitorActivityFormatter.absolute(nil, calendar: calendar, locale: locale),
            "Activity unavailable"
        )
        XCTAssertEqual(
            AgentMonitorActivityFormatter.accessibility(nil, calendar: calendar, locale: locale),
            "Last activity unavailable"
        )
        // Rendered inside a `·`-joined line, so the missing-value copy carries no sentence period.
        XCTAssertFalse(AgentMonitorActivityFormatter.unavailable.hasSuffix("."))
    }

    /// The visible line is relative and the hover is absolute, and the row must never mix them up.
    func testRowFreshnessLinesSplitRelativeFromAbsolute() {
        let now = moment(hour: 15, minute: 30)
        let row = outbound(status: .running, lastActivityAt: now.addingTimeInterval(-120))
        XCTAssertEqual(row.locationProviderLine, "worktree/feature · Codex CLI")
        XCTAssertEqual(row.activityLine(now: now, calendar: calendar, locale: locale), "2m ago")
        XCTAssertEqual(
            row.metadataLine(now: now, calendar: calendar, locale: locale),
            "worktree/feature · Codex CLI · 2m ago"
        )
        XCTAssertEqual(row.activityTooltip, AgentMonitorActivityFormatter.absolute(row.lastActivityAt))
        XCTAssertNotEqual(
            row.activityTooltip,
            "2m ago",
            "hover must reveal detail the visible line cannot show"
        )
    }

    // MARK: - Unread

    /// Unread is a separate record from Done, so a row can be triaged complete and still be flagged
    /// when strictly newer activity arrives.
    func testUnreadIsIndependentOfDoneAndIsSpokenInTheRowValue() {
        XCTAssertFalse(outbound().hasUnreadActivity, "rows default to read, never to a false alarm")

        let unread = outbound(status: .running, hasUnreadActivity: true)
        XCTAssertTrue(unread.accessibilityDescription.hasSuffix(", New activity"))
        XCTAssertFalse(outbound().accessibilityDescription.contains("New activity"))

        let reopened = outbound(triageState: .done, hasUnreadActivity: true)
        XCTAssertTrue(reopened.accessibilityDescription.hasSuffix(", New activity, Done"))
    }

    /// Four visually identical controls per row are indistinguishable in the VoiceOver rotor, so
    /// each one names the session it acts on.
    func testInlineActionLabelsNameTheirRow() {
        let row = outbound()
        XCTAssertEqual(row.viewActionLabel, "View Build API")
        XCTAssertEqual(row.doneActionLabel, "Done for Build API")
        XCTAssertEqual(row.markSeenActionLabel, "Mark Build API activity as seen")
        XCTAssertEqual(row.unlinkActionLabel, "Unlink oversight of Build API")
        XCTAssertEqual(
            Set([row.viewActionLabel, row.doneActionLabel, row.markSeenActionLabel, row.unlinkActionLabel]).count,
            4
        )
    }

    // MARK: - Unlink recovery copy

    /// The same revocation reads differently at each end, and neither wording may claim the removed
    /// grant came back: Undo runs the ordinary Add and creates a fresh link.
    func testUndoCopyIsDirectionCorrectAndHonestAboutFreshLinks() {
        XCTAssertEqual(
            AgentMonitorUnlinkUndo.message(direction: .outbound, displayName: "Build API"),
            "Oversight of Build API was unlinked."
        )
        XCTAssertEqual(
            AgentMonitorUnlinkUndo.message(direction: .inbound, displayName: "Planning"),
            "Planning no longer oversees this session."
        )
        XCTAssertNotEqual(
            AgentMonitorUnlinkUndo.undoAccessibilityLabel(direction: .outbound, displayName: "Build API"),
            AgentMonitorUnlinkUndo.undoAccessibilityLabel(direction: .inbound, displayName: "Build API")
        )
        XCTAssertTrue(AgentMonitorUnlinkUndo.undoTooltip.contains("new oversight link"))
        XCTAssertEqual(AgentMonitorUnlinkUndo.window, .seconds(8))
    }

    // MARK: - Notices

    private func notice(
        reason: DomainAgentSessionLinkRevocationReason,
        targetDisplayName: String? = "Build API"
    ) -> DomainAgentSessionLinkRevocationNotice {
        DomainAgentSessionLinkRevocationNotice(
            linkID: UUID(),
            generation: 1,
            observerSessionID: observerID,
            targetSessionID: targetID,
            targetDisplayName: targetDisplayName,
            observerDisplayName: nil,
            reason: reason,
            revokedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testNoticesReadDifferentlyAtEachEndOfTheLink() {
        let raw = notice(reason: .windowClosed)
        XCTAssertEqual(
            AgentMonitorNoticeFormatter.message(
                for: raw,
                endpointSessionID: observerID,
                observerDisplayName: "Planning",
                targetDisplayName: "Build API"
            ),
            "Oversight of Build API ended: the window closed."
        )
        XCTAssertEqual(
            AgentMonitorNoticeFormatter.message(
                for: raw,
                endpointSessionID: targetID,
                observerDisplayName: "Planning",
                targetDisplayName: "Build API"
            ),
            "Planning no longer oversees this session: the window closed."
        )
    }

    func testNoticeFallsBackToTheNoticesOwnNameThenTheShortID() {
        let raw = notice(reason: .userRequested)
        XCTAssertEqual(
            AgentMonitorNoticeFormatter.message(
                for: raw,
                endpointSessionID: observerID,
                observerDisplayName: nil,
                targetDisplayName: nil
            ),
            "Oversight of Build API ended: the relationship was unlinked."
        )

        let anonymous = notice(reason: .userRequested, targetDisplayName: nil)
        XCTAssertEqual(
            AgentMonitorNoticeFormatter.message(
                for: anonymous,
                endpointSessionID: observerID,
                observerDisplayName: nil,
                targetDisplayName: nil
            ),
            "Oversight of 8B91…E572 ended: the relationship was unlinked."
        )
        XCTAssertEqual(
            AgentMonitorNoticeFormatter.message(
                for: anonymous,
                endpointSessionID: targetID,
                observerDisplayName: nil,
                targetDisplayName: nil
            ),
            "04CF…1A00 no longer oversees this session: the relationship was unlinked."
        )
    }

    func testEveryRevocationReasonRendersAPhrase() {
        for reason in DomainAgentSessionLinkRevocationReason.allCases {
            let phrase = AgentMonitorNoticeFormatter.reasonPhrase(reason)
            XCTAssertFalse(phrase.isEmpty, "\(reason) has no phrase")
        }
    }

    func testNoticeIdentityIsGenerationScopedSoARelinkNeverCollides() {
        let linkID = UUID()
        let first = AgentMonitorPillProps.Notice(linkID: linkID, generation: 1, message: "a")
        let second = AgentMonitorPillProps.Notice(linkID: linkID, generation: 2, message: "b")
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: - Auto-wake snooze

    private func snooze(
        minutesFromNow: Double,
        origin: AgentSessionLinkAutoWakeSnoozeOrigin = .user,
        now: Date
    ) -> AgentMonitorAutoWakeSnoozeState {
        AgentMonitorAutoWakeSnoozeState(
            expiresAt: now.addingTimeInterval(minutesFromNow * 60),
            origin: origin
        )
    }

    /// Rows carry snooze *state* and nothing else: no closures, no busy flag, no result to render
    /// optimistically. A default row is unsnoozed and unselected, which is the fail-closed pair.
    func testOutboundRowsCarryOnlySnoozeStateAndDefaultToNeitherSnoozedNorSelected() {
        let row = outbound()
        XCTAssertNil(row.autoWakeSnooze)
        XCTAssertFalse(row.isAutoWakeEffectivelySelected)

        let now = moment(hour: 16, minute: 11)
        let updated = row.withAutoWakeState(
            snooze: snooze(minutesFromNow: 9, origin: .agent, now: now),
            isEffectivelySelected: true
        )
        // Every other field survives the overlay, so a policy repaint cannot drop identity, status,
        // triage, unread, or routing.
        XCTAssertEqual(updated.linkID, row.linkID)
        XCTAssertEqual(updated.generation, row.generation)
        XCTAssertEqual(updated.targetSessionID, row.targetSessionID)
        XCTAssertEqual(updated.displayName, row.displayName)
        XCTAssertEqual(updated.providerDisplayName, row.providerDisplayName)
        XCTAssertEqual(updated.locationLabel, row.locationLabel)
        XCTAssertEqual(updated.status, row.status)
        XCTAssertEqual(updated.lastActivityAt, row.lastActivityAt)
        XCTAssertEqual(updated.triageState, row.triageState)
        XCTAssertEqual(updated.hasUnreadActivity, row.hasUnreadActivity)
        XCTAssertEqual(updated.targetRoute, row.targetRoute)
        XCTAssertEqual(updated.autoWakeSnooze?.origin, .agent)
        XCTAssertTrue(updated.isAutoWakeEffectivelySelected)
        // An unchanged overlay is identity, so repeated publications of the same policy compare equal
        // and repaint nothing.
        XCTAssertEqual(
            updated.withAutoWakeState(
                snooze: updated.autoWakeSnooze,
                isEffectivelySelected: true
            ),
            updated
        )
    }

    /// The subrow names who is responsible for the current deadline and rounds the remainder up, so
    /// a live snooze never reads as `0 min left`.
    func testSubrowNamesTheSetterAndRoundsRemainingMinutesUp() {
        let now = moment(hour: 16, minute: 11)
        XCTAssertEqual(
            AgentMonitorAutoWakeSnoozeCopy.subrow(
                snooze(minutesFromNow: 9, origin: .user, now: now),
                now: now
            ),
            "Auto-wake snoozed by you · 9 min left"
        )
        XCTAssertEqual(
            AgentMonitorAutoWakeSnoozeCopy.subrow(
                snooze(minutesFromNow: 8.2, origin: .agent, now: now),
                now: now
            ),
            "Auto-wake snoozed by this agent · 9 min left"
        )
        // Seconds left is still left.
        XCTAssertEqual(
            AgentMonitorAutoWakeSnoozeCopy.subrow(
                snooze(minutesFromNow: 0.1, origin: .user, now: now),
                now: now
            ),
            "Auto-wake snoozed by you · 1 min left"
        )
    }

    /// Local expiry is a presentation state, and it promises exactly what expiry promises.
    func testExpiredSnoozeSaysEligibilityIsBeingReevaluatedAndNothingStronger() {
        let now = moment(hour: 16, minute: 11)
        let elapsed = snooze(minutesFromNow: -1, now: now)
        XCTAssertTrue(elapsed.hasExpired(now: now))
        XCTAssertEqual(AgentMonitorAutoWakeSnoozeCopy.subrow(elapsed, now: now), "Auto-wake snooze expired · Re-evaluating eligibility…")
        XCTAssertEqual(
            AgentMonitorAutoWakeSnoozeCopy.accessibilityValue(
                elapsed,
                now: now,
                calendar: calendar,
                locale: locale
            ),
            AgentMonitorAutoWakeSnoozeCopy.expired
        )
        for overclaim in ["delivering", "sending", "waking", "starting"] {
            XCTAssertFalse(
                AgentMonitorAutoWakeSnoozeCopy.expired.lowercased().contains(overclaim),
                "expiry buys one re-evaluation, never a turn: \(overclaim)"
            )
        }
        // An elapsed record is not an active snooze for the row either, so the menu goes back to
        // offering every horizon.
        let row = outbound(autoWakeSnooze: elapsed, isAutoWakeEffectivelySelected: true)
        XCTAssertFalse(row.hasActiveAutoWakeSnooze(now: now))
        XCTAssertEqual(
            row.availableSnoozeDurationSeconds(now: now),
            AgentSessionLinkAutoWakeSnooze.uiDurationSeconds
        )
    }

    /// The spoken form carries the three things the visible row cannot: who set it, how much is
    /// left, and the absolute instant a listener cannot glance back at the row to resolve.
    func testSnoozeAccessibilityValueCarriesOriginRoundedTimeAndAbsoluteExpiry() {
        let now = moment(hour: 16, minute: 11)
        let state = snooze(minutesFromNow: 9, origin: .agent, now: now)
        let spoken = AgentMonitorAutoWakeSnoozeCopy.accessibilityValue(
            state,
            now: now,
            calendar: calendar,
            locale: locale
        )
        XCTAssertTrue(spoken.hasPrefix("Set by this agent. 9 minutes remaining."))
        XCTAssertTrue(spoken.contains("Expires today at \(expectedShortTime(state.expiresAt))."))

        let mine = AgentMonitorAutoWakeSnoozeCopy.accessibilityValue(
            snooze(minutesFromNow: 1, origin: .user, now: now),
            now: now,
            calendar: calendar,
            locale: locale
        )
        XCTAssertTrue(mine.hasPrefix("Set by you. 1 minute remaining."))

        // A snooze that lands tomorrow names the day instead of claiming "today".
        let tomorrow = AgentMonitorAutoWakeSnoozeCopy.expiryPhrase(
            now.addingTimeInterval(60 * 60 * 20),
            now: now,
            calendar: calendar,
            locale: locale
        )
        XCTAssertFalse(tomorrow.contains("today"))
    }

    /// Action labels name the target, because four visually identical controls per row are
    /// indistinguishable in the rotor without it.
    func testSnoozeActionLabelsNameTheTargetAndDistinguishSettingFromExtending() {
        let now = moment(hour: 16, minute: 11)
        let fresh = outbound(isAutoWakeEffectivelySelected: true)
        XCTAssertEqual(fresh.snoozeMenuAccessibilityLabel, "Snooze Auto-wake for Build API")
        XCTAssertEqual(fresh.clearSnoozeActionLabel, "Clear Auto-wake snooze for Build API")
        XCTAssertEqual(
            fresh.snoozeActionLabel(seconds: 600, now: now),
            "Snooze Auto-wake for Build API for 10 minutes"
        )
        XCTAssertEqual(fresh.snoozeOptionLabel(seconds: 1200, now: now), "Snooze for 20 minutes")

        let active = outbound(
            autoWakeSnooze: snooze(minutesFromNow: 9, now: now),
            isAutoWakeEffectivelySelected: true
        )
        // `at least`, because the server keeps the later of the two deadlines rather than replacing
        // the current one.
        XCTAssertEqual(
            active.snoozeOptionLabel(seconds: 1200, now: now),
            "Extend to at least 20 minutes from now"
        )
        XCTAssertEqual(
            active.snoozeActionLabel(seconds: 1200, now: now),
            "Extend Auto-wake snooze for Build API to at least 20 minutes from now"
        )
    }

    /// The menu offers only horizons that would actually move the deadline; a deselected lane keeps
    /// Clear but loses set/extend.
    func testSnoozeMenuOffersOnlyDeadlineMovingChoicesAndSurvivesDeselectionOnlyForClear() {
        let now = moment(hour: 16, minute: 11)
        XCTAssertEqual(
            outbound(isAutoWakeEffectivelySelected: true).availableSnoozeDurationSeconds(now: now),
            [600, 1200, 2400, 3600]
        )
        // 25 minutes left: ten and twenty would not move it, forty and sixty would.
        XCTAssertEqual(
            outbound(
                autoWakeSnooze: snooze(minutesFromNow: 25, now: now),
                isAutoWakeEffectivelySelected: true
            ).availableSnoozeDurationSeconds(now: now),
            [2400, 3600]
        )
        // At the cap nothing can move it further, so the menu offers nothing at all.
        XCTAssertTrue(
            outbound(
                autoWakeSnooze: snooze(minutesFromNow: 60, now: now),
                isAutoWakeEffectivelySelected: true
            ).availableSnoozeDurationSeconds(now: now).isEmpty
        )
        // Deselection leaves the state — and therefore Clear — intact; the view gates only the
        // set/extend offers on selection.
        let deselected = outbound(
            autoWakeSnooze: snooze(minutesFromNow: 9, now: now),
            isAutoWakeEffectivelySelected: false
        )
        XCTAssertNotNil(deselected.autoWakeSnooze)
        XCTAssertFalse(deselected.isAutoWakeEffectivelySelected)
    }

    /// The one informational outcome a *successful* set can carry, and the failures that are not it.
    func testRowFeedbackSeparatesTheTooLateNoticeFromRealFailures() {
        XCTAssertEqual(
            AgentMonitorAutoWakeSnoozeCopy.currentDispatchAlreadyStarted,
            "Current Auto-wake already started. This snooze applies to later updates."
        )
        let notice = AgentMonitorRowFeedback.notice(
            AgentMonitorAutoWakeSnoozeCopy.currentDispatchAlreadyStarted
        )
        let failure = AgentMonitorRowFeedback.failure(
            AgentMonitorAutoWakeSnoozeCopy.unavailableMessage
        )
        XCTAssertNotEqual(notice, failure)
        XCTAssertEqual(notice.message, AgentMonitorAutoWakeSnoozeCopy.currentDispatchAlreadyStarted)

        // A retired generation reads as a gone row rather than naming the generation, and the one
        // condition the user can fix says what to fix.
        XCTAssertEqual(
            AgentMonitorAutoWakeSnoozeCopy.failureMessage(.staleReference),
            AgentMonitorAutoWakeSnoozeCopy.unavailableMessage
        )
        XCTAssertEqual(
            AgentMonitorAutoWakeSnoozeCopy.failureMessage(.observerUnavailable),
            AgentMonitorAutoWakeSnoozeCopy.unavailableMessage
        )
        XCTAssertTrue(
            AgentMonitorAutoWakeSnoozeCopy.failureMessage(.laneNotEffectivelySelected)
                .contains("nothing to snooze")
        )
        XCTAssertTrue(
            AgentMonitorAutoWakeSnoozeCopy.failureMessage(.shuttingDown).contains("shutting down")
        )
    }

    /// Row-local view state is expired by generation, so a relink cannot inherit the retired row's
    /// busy marker or feedback.
    func testRowKeyIsGenerationQualified() {
        let linkID = UUID()
        let first = AgentMonitorPillProps.Outbound(
            linkID: linkID,
            generation: 1,
            targetSessionID: targetID,
            displayName: "Build API",
            providerDisplayName: nil,
            locationLabel: nil,
            status: .idle
        )
        let relinked = AgentMonitorPillProps.Outbound(
            linkID: linkID,
            generation: 2,
            targetSessionID: targetID,
            displayName: "Build API",
            providerDisplayName: nil,
            locationLabel: nil,
            status: .idle
        )
        XCTAssertNotEqual(first.rowKey, relinked.rowKey)
        XCTAssertEqual(first.id, relinked.id, "the identifier itself is deliberately unchanged")
    }
}
