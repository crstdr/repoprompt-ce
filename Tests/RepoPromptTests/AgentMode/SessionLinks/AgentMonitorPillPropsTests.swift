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
        targetRoute: AgentSessionDeepLinkRoute? = nil
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
            targetRoute: targetRoute
        )
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
        canAddReason: String? = nil
    ) -> AgentMonitorPillProps {
        AgentMonitorPillProps(
            sessionID: observerID,
            outbound: outbound,
            inbound: inbound,
            recentNotices: notices,
            canAddReason: canAddReason
        )
    }

    // MARK: - Identifiers

    func testShortIDKeepsBothEndsSoRowsStayDistinguishable() {
        XCTAssertEqual(AgentMonitorSessionIDFormatter.short(targetID), "8B91…E572")
        XCTAssertEqual(AgentMonitorSessionIDFormatter.short(observerID), "04CF…1A00")
    }

    func testRowsCarryDirectionAndExposeTheFullUUID() {
        let out = outbound()
        XCTAssertEqual(out.rowLabel, "→ Build API (8B91…E572)")
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
            "worktree/feature · Codex CLI · Idle · Activity unavailable."
        )
        XCTAssertEqual(outbound.locationProviderLine, "worktree/feature · Codex CLI")
        XCTAssertEqual(
            outbound.statusActivityLine,
            "Idle · Activity unavailable.",
            "status and absolute freshness must render independently of unbounded location/provider text"
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
            "worktree/feature · Codex CLI · Running"
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
        // Only eligibility is recomputed; link membership and notices stay authority-owned.
        let notice = AgentMonitorPillProps.Notice(linkID: UUID(), generation: 3, message: "ended")
        let published = makeProps(
            outbound: [outbound(status: .running)],
            inbound: [inbound()],
            notices: [notice],
            canAddReason: "Load this thread before adding sessions to oversee."
        )

        let overlaid = AgentModeViewModel.monitorPillProps(
            sessionID: observerID,
            published: published,
            eligibility: eligibility(),
            roleAllowsOutboundMonitoring: true
        )
        XCTAssertEqual(overlaid.outbound, published.outbound)
        XCTAssertEqual(overlaid.inbound, published.inbound)
        XCTAssertEqual(overlaid.recentNotices, published.recentNotices)
        XCTAssertNil(overlaid.canAddReason)
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

    func testEveryStatusCarriesTextAndASymbolSoColourIsNeverTheOnlyCue() {
        for status in [
            AgentMonitorLinkStatus.idle,
            .running,
            .awaitingUser,
            .unavailable
        ] {
            XCTAssertFalse(status.label.isEmpty, "\(status) has no label")
            XCTAssertFalse(status.symbolName.isEmpty, "\(status) has no symbol")
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

    /// Symbols must stay distinct per status; two statuses sharing a glyph would make the row
    /// unreadable for anyone relying on shape rather than colour.
    func testStatusSymbolsAreDistinctPerStatus() {
        let symbols = [
            AgentMonitorLinkStatus.idle,
            .running,
            .awaitingUser,
            .unavailable
        ].map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count, "statuses share a symbol: \(symbols)")
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
}
