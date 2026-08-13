import Foundation
import RepoPromptDomainRuntime

// MARK: - Identifier formatting

/// Short display form for an overseen session ID.
///
/// The full canonical UUID always remains available in tooltip/accessibility text; the short form is
/// only a visual disambiguator for rows such as `→ Build API (8B91…E572)`.
enum AgentMonitorSessionIDFormatter {
    static func short(_ sessionID: UUID) -> String {
        let raw = sessionID.uuidString
        guard raw.count >= 8 else { return raw }
        return "\(raw.prefix(4))…\(raw.suffix(4))"
    }
}

// MARK: - Status

/// Safe, agent-neutral status projection for one overseen endpoint.
///
/// Status is conveyed by text and symbol as well as color so it survives color-blind and
/// high-contrast presentation.
enum AgentMonitorLinkStatus: String, Equatable {
    case idle
    case running
    case awaitingUser
    /// The bridge has no current published snapshot for this target yet.
    case unavailable

    init(
        status: DomainAgentSessionLinkStatus,
        pendingInteraction: DomainAgentSessionLinkPendingInteractionKind?
    ) {
        if pendingInteraction != nil {
            self = .awaitingUser
            return
        }
        switch status {
        case .idle:
            self = .idle
        case .running:
            self = .running
        case .awaitingUser:
            self = .awaitingUser
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .awaitingUser: "Waiting for input"
        case .unavailable: "Unavailable"
        }
    }

    /// Spoken status keeps the target-window qualification that the compact visible label omits.
    var accessibilityLabel: String {
        switch self {
        case .awaitingUser: "Waiting for input in its window"
        case .idle, .running, .unavailable: label
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "pause.circle"
        case .running: "play.circle"
        case .awaitingUser: "questionmark.circle"
        case .unavailable: "questionmark.circle.dashed"
        }
    }
}

// MARK: - Triage and activity

/// Process-memory dashboard triage. It never changes or replaces the live target status.
enum AgentMonitorTriageState: String, Equatable {
    case active
    case done
}

/// Result of changing one generation-qualified dashboard triage record.
enum AgentMonitorTriageOutcome: Equatable {
    case changed
    case alreadyInRequestedState
    case failed(message: String)

    var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

/// Static localized freshness copy. Absolute timestamps need no timer-driven repaint.
enum AgentMonitorActivityFormatter {
    static let unavailable = "Activity unavailable."

    static func compact(_ date: Date?) -> String {
        guard let date else { return unavailable }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    static func accessibility(_ date: Date?) -> String {
        guard let date else { return "Last activity unavailable"
        }
        let value = DateFormatter.localizedString(from: date, dateStyle: .full, timeStyle: .medium)
        return "Last activity \(value)"
    }
}

// MARK: - Location and detail line

/// Resolves the **UI-only** execution-location label carried by one oversight row.
///
/// A session bound to a worktree on its primary root names that worktree. A session with no
/// primary-root worktree binding — including one bound only to a secondary root — produces no
/// indicator at all, and an empty slot in the detail line is indistinguishable from "location
/// unknown" — which is the exact question this popover exists to answer for a user working across
/// many windows. It therefore falls back to the workspace name
/// qualified with `(main)`: the workspace name is what distinguishes rows across windows and
/// workspaces, and the qualifier keeps it from reading as a worktree that does not exist.
///
/// Resolved in the endpoint's **own** window, so a row describing another window names that window's
/// workspace rather than the viewer's. Like every other location value on this surface it is UI only
/// and never enters an agent-facing snapshot, inventory, or prompt.
enum AgentMonitorLocationLabelFormatter {
    static func label(worktreeLabel: String?, workspaceName: String?) -> String {
        if let worktree = worktreeLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !worktree.isEmpty
        {
            return worktree
        }
        guard let workspace = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspace.isEmpty
        else {
            return "main"
        }
        return "\(workspace) (main)"
    }
}

/// Builds the secondary line under an oversight row, e.g. `feature-219 · Codex CLI · Idle`.
///
/// Location leads deliberately: across many sessions spanning two providers the provider name
/// distinguishes almost nothing, while the worktree/workspace distinguishes strongly.
///
/// Lives on the model rather than inline in the view so the ordering and separator stay under test
/// and cannot drift between the three surfaces that render it.
enum AgentMonitorDetailLineFormatter {
    static func line(
        location: String?,
        provider: String?,
        status: AgentMonitorLinkStatus?,
        activity: String? = nil
    ) -> String {
        [location, provider, status?.label, activity].compactMap(\.self).joined(separator: " · ")
    }
}

/// Spoken form of the location slot, e.g. `" in feature-219"`.
///
/// Location is the primary visual discriminator on these rows, so a VoiceOver user who hears only a
/// full UUID is materially worse off than a sighted one. Shared by every accessible surface that
/// names a session so the phrasing cannot drift between them.
enum AgentMonitorAccessibilityLocationPhrase {
    static func clause(_ location: String?) -> String {
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty
        else {
            return ""
        }
        return " in \(location)"
    }
}

// MARK: - Pill props

/// Equatable rendering contract for the Oversee pill and its management popover.
///
/// Workspace/worktree labels here are **UI only**; they are never placed in agent-facing snapshots,
/// inventories, or prompts.
struct AgentMonitorPillProps: Equatable {
    struct Outbound: Equatable, Identifiable {
        let linkID: UUID
        let generation: UInt64
        let targetSessionID: UUID
        let displayName: String
        let providerDisplayName: String?
        let locationLabel: String?
        let status: AgentMonitorLinkStatus
        let lastActivityAt: Date?
        let triageState: AgentMonitorTriageState
        let targetRoute: AgentSessionDeepLinkRoute?

        init(
            linkID: UUID,
            generation: UInt64,
            targetSessionID: UUID,
            displayName: String,
            providerDisplayName: String?,
            locationLabel: String?,
            status: AgentMonitorLinkStatus,
            lastActivityAt: Date? = nil,
            triageState: AgentMonitorTriageState = .active,
            targetRoute: AgentSessionDeepLinkRoute? = nil
        ) {
            self.linkID = linkID
            self.generation = generation
            self.targetSessionID = targetSessionID
            self.displayName = displayName
            self.providerDisplayName = providerDisplayName
            self.locationLabel = locationLabel
            self.status = status
            self.lastActivityAt = lastActivityAt
            self.triageState = triageState
            self.targetRoute = targetRoute
        }

        var id: UUID {
            linkID
        }

        var shortID: String {
            AgentMonitorSessionIDFormatter.short(targetSessionID)
        }

        var fullID: String {
            targetSessionID.uuidString
        }

        var rowLabel: String {
            "→ \(displayName) (\(shortID))"
        }

        /// Complete secondary detail retained for tooltips and non-layout consumers.
        var detailLine: String {
            AgentMonitorDetailLineFormatter.line(
                location: locationLabel,
                provider: providerDisplayName,
                status: status,
                activity: AgentMonitorActivityFormatter.compact(lastActivityAt)
            )
        }

        /// Truncatable execution context. The row renders this separately so long workspace or
        /// provider text can never displace live status or absolute freshness.
        var locationProviderLine: String {
            AgentMonitorDetailLineFormatter.line(
                location: locationLabel,
                provider: providerDisplayName,
                status: nil
            )
        }

        /// Protected, event-driven status and absolute freshness line. It intentionally contains no
        /// unbounded workspace, worktree, or provider text.
        var statusActivityLine: String {
            AgentMonitorDetailLineFormatter.line(
                location: nil,
                provider: nil,
                status: status,
                activity: AgentMonitorActivityFormatter.compact(lastActivityAt)
            )
        }

        var activityAccessibilityLabel: String {
            AgentMonitorActivityFormatter.accessibility(lastActivityAt)
        }

        var accessibilityDescription: String {
            let location = AgentMonitorAccessibilityLocationPhrase.clause(locationLabel)
            let triage = triageState == .done ? ", Done" : ""
            return "Overseeing \(displayName)\(location), session \(fullID), "
                + "\(status.accessibilityLabel), \(activityAccessibilityLabel)\(triage)"
        }

        /// VoiceOver label for this row's Unlink control.
        ///
        /// Lives on the model rather than inline in the view so the wording stays under test and
        /// cannot drift from `accessibilityDescription`; a bare "Unlink" button repeated per row is
        /// indistinguishable in the rotor.
        var unlinkActionLabel: String {
            "Unlink oversight of \(displayName)"
        }
    }

    struct Inbound: Equatable, Identifiable {
        let linkID: UUID
        let generation: UInt64
        let observerSessionID: UUID
        let displayName: String
        let providerDisplayName: String?

        var id: UUID {
            linkID
        }

        var shortID: String {
            AgentMonitorSessionIDFormatter.short(observerSessionID)
        }

        var fullID: String {
            observerSessionID.uuidString
        }

        var rowLabel: String {
            "← \(displayName) (\(shortID))"
        }

        /// Secondary line for this row.
        ///
        /// Carries neither status nor location. Nothing installs an observation on an *observer's*
        /// session — observations are installed per overseen target — so no observer-side change
        /// schedules a refresh of this projection, and both values would freeze at whatever the last
        /// link event happened to record.
        ///
        /// Status is obviously live. Location is too: `commitWorktreeBindings` is the only mutation
        /// point for `worktreeBindings`, and it neither bumps `bindingTransitionGeneration` (so the
        /// endpoint identity does not drift and the link is not revoked or rebound) nor feeds
        /// `monitorObservationSignal`. An observer can therefore change execution location while this
        /// link is live and leave a location rendered here permanently wrong. Provider is different in
        /// kind rather than in refresh: it is locked once a session has sent its first message, which
        /// is a precondition of having the durable binding oversight requires.
        var detailLine: String {
            AgentMonitorDetailLineFormatter.line(
                location: nil,
                provider: providerDisplayName,
                status: nil
            )
        }

        var accessibilityDescription: String {
            "Overseen by \(displayName), session \(fullID)"
        }

        /// VoiceOver label for this row's Unlink control, phrased from the overseen session's side.
        var unlinkActionLabel: String {
            "Unlink \(displayName) from overseeing this session"
        }
    }

    struct Notice: Equatable, Identifiable {
        let linkID: UUID
        let generation: UInt64
        let message: String

        var id: String {
            "\(linkID.uuidString)-\(generation)"
        }
    }

    /// The observing session this projection belongs to, or `nil` while the tab has no durable
    /// top-level binding.
    let sessionID: UUID?
    /// The exact incarnation this projection was published to, or `nil` for a locally synthesized
    /// placeholder that carries no authority state.
    ///
    /// Notices are recorded per incarnation, so dismissing them needs the identity rather than the
    /// session UUID: a duplicate live incarnation of the same UUID must not clear another's notices.
    var endpoint: DomainAgentSessionLinkEndpointIdentity?
    let outbound: [Outbound]
    let inbound: [Inbound]
    let recentNotices: [Notice]
    /// Non-nil when Add must stay disabled, carrying the exact user-facing reason.
    let canAddReason: String?
    /// Process-wide durable-oversight state, overlaid by the owning window rather than published by
    /// the bridge's per-endpoint projection.
    ///
    /// It is deliberately not part of the authority projection: a tab with no links at all never
    /// receives one, and that is exactly the tab whose Add button has to explain why saving is
    /// unavailable.
    var persistence: AgentSessionOversightPersistencePresentation

    init(
        sessionID: UUID?,
        endpoint: DomainAgentSessionLinkEndpointIdentity? = nil,
        outbound: [Outbound],
        inbound: [Inbound],
        recentNotices: [Notice],
        canAddReason: String?,
        persistence: AgentSessionOversightPersistencePresentation = AgentSessionOversightPersistencePresentation.noDurableLayer
    ) {
        self.sessionID = sessionID
        self.endpoint = endpoint
        self.outbound = outbound
        self.inbound = inbound
        self.recentNotices = recentNotices
        self.canAddReason = canAddReason
        self.persistence = persistence
    }

    static let empty = AgentMonitorPillProps(
        sessionID: nil,
        outbound: [],
        inbound: [],
        recentNotices: [],
        canAddReason: "Send a first message to start this session, then add sessions to oversee."
    )

    /// Overlays a freshly recomputed Add-eligibility reason onto an authoritative link projection.
    ///
    /// Link membership and notices come from the authority and change only on an authority event;
    /// eligibility depends on live session state that produces no such event, so the two are
    /// deliberately refreshed on different schedules.
    func withCanAddReason(_ reason: String?) -> AgentMonitorPillProps {
        guard reason != canAddReason else { return self }
        return AgentMonitorPillProps(
            sessionID: sessionID,
            endpoint: endpoint,
            outbound: outbound,
            inbound: inbound,
            recentNotices: recentNotices,
            canAddReason: reason,
            persistence: persistence
        )
    }

    /// Overlays the process-wide persistence level onto an authoritative or synthesized projection.
    ///
    /// The persistence blocker wins over the live eligibility reason: an eligible session still
    /// cannot be granted oversight while the durable record refuses to change, and telling the user
    /// to “load this thread” in that state sends them to fix the wrong thing.
    func withPersistence(
        _ presentation: AgentSessionOversightPersistencePresentation,
        eligibilityReason: String?
    ) -> AgentMonitorPillProps {
        let reason = presentation.addBlockerMessage ?? eligibilityReason
        guard reason != canAddReason || presentation != persistence else { return self }
        return AgentMonitorPillProps(
            sessionID: sessionID,
            endpoint: endpoint,
            outbound: outbound,
            inbound: inbound,
            recentNotices: recentNotices,
            canAddReason: reason,
            persistence: presentation
        )
    }

    var isActive: Bool {
        !outbound.isEmpty
    }

    var hasInbound: Bool {
        !inbound.isEmpty
    }

    var canAdd: Bool {
        canAddReason == nil
    }

    /// VoiceOver value, e.g. "Overseeing 2 sessions; overseen by 1."
    var accessibilityValue: String {
        var parts: [String] = []
        if outbound.isEmpty {
            parts.append("Not overseeing any sessions")
        } else {
            parts.append("Overseeing \(outbound.count) \(outbound.count == 1 ? "session" : "sessions")")
        }
        if !inbound.isEmpty {
            parts.append("overseen by \(inbound.count)")
        }
        return parts.joined(separator: "; ") + "."
    }
}

// MARK: - Revocation notices

/// Renders bounded, endpoint-relative revocation notices such as
/// "Oversight of Build API ended: the window closed."
///
/// Notices are explanatory UI only: they are never persisted and never reach an agent-facing
/// payload, so they may safely name the local display names of both endpoints.
enum AgentMonitorNoticeFormatter {
    static func reasonPhrase(_ reason: DomainAgentSessionLinkRevocationReason) -> String {
        switch reason {
        case .userRequested:
            "the relationship was unlinked"
        case .observerEndpointInvalidated, .targetEndpointInvalidated:
            "the session ended"
        case .observerIdentityDrift, .targetIdentityDrift:
            "the session changed"
        case .observerNoLongerEligible:
            "this session can no longer oversee other sessions"
        case .tabClosed:
            "the chat closed"
        case .windowClosed:
            "the window closed"
        case .workspaceSwitched:
            "the workspace changed"
        case .bindingChanged:
            "the session was rebound"
        case .sessionDeleted:
            "the session was deleted"
        case .activationSeedFailed:
            "the session could not be observed"
        case .runtimeShutdown, .appTerminating:
            "RepoPrompt is shutting down"
        }
    }

    /// - Parameter endpointSessionID: the session this notice is being rendered *for*. The same
    ///   revocation reads differently at each end of the link.
    static func message(
        for notice: DomainAgentSessionLinkRevocationNotice,
        endpointSessionID: UUID,
        observerDisplayName: String?,
        targetDisplayName: String?
    ) -> String {
        let phrase = reasonPhrase(notice.reason)
        if endpointSessionID == notice.observerSessionID {
            let name = targetDisplayName
                ?? notice.targetDisplayName
                ?? AgentMonitorSessionIDFormatter.short(notice.targetSessionID)
            return "Oversight of \(name) ended: \(phrase)."
        }
        let name = observerDisplayName
            ?? notice.observerDisplayName
            ?? AgentMonitorSessionIDFormatter.short(notice.observerSessionID)
        return "\(name) no longer oversees this session: \(phrase)."
    }
}

// MARK: - Resolved preview

/// Preview shown after a UUID resolves but before the user authorizes the link.
///
/// Building this never focuses, activates, or switches the target window.
struct AgentMonitorResolvedPreview: Equatable {
    let sessionID: UUID
    let displayName: String
    let providerDisplayName: String?
    let locationLabel: String?
    let status: AgentMonitorLinkStatus

    var shortID: String {
        AgentMonitorSessionIDFormatter.short(sessionID)
    }

    var fullID: String {
        sessionID.uuidString
    }

    /// Secondary line for the preview row.
    var detailLine: String {
        AgentMonitorDetailLineFormatter.line(
            location: locationLabel,
            provider: providerDisplayName,
            status: status
        )
    }

    /// VoiceOver label for the combined preview element.
    ///
    /// Reads the full canonical UUID because the visible short form is ambiguous by construction,
    /// and this is the value the user is about to authorize. It also names the location, which is the
    /// row's primary visual discriminator and the one thing a UUID alone cannot convey.
    var accessibilityLabel: String {
        let location = AgentMonitorAccessibilityLocationPhrase.clause(locationLabel)
        return "Resolved \(displayName)\(location), session \(fullID), \(status.accessibilityLabel)"
    }
}

// MARK: - Durable persistence copy

/// User-facing copy for durable oversight persistence.
///
/// Deliberately free of session names, UUIDs, backup paths, and internal reasons: these strings are
/// rendered next to a control the user just used, and the only actionable content is what they can
/// do about it.
enum AgentSessionOversightPersistenceCopy {
    static let loading = "Saved oversight links are still loading."
    static let suppressedLaunch = "Saved oversight links are unavailable in this launch mode."
    static let autoRestoreDisabled = "Saved oversight links will remain dormant while window restoration is turned off."
    static let futureSchema = "Saved oversight links were created by a newer RepoPrompt version. The file was preserved, so oversight can’t be changed in this version."
    static let unreadable = "RepoPrompt couldn’t read or back up saved oversight links. The file was preserved, so oversight can’t be changed."
    static let quarantined = "RepoPrompt couldn’t read saved oversight links. It backed up the file and started with no saved links."
    static let terminalRestorationSummary = "Some saved oversight links couldn’t be restored and were removed."
    static let addWriteFailed = "Oversight couldn’t be saved, so it wasn’t started. Check disk space and Application Support permissions, then try again."
    static let addCompensationFailed = "Oversight didn’t start, and RepoPrompt couldn’t clear its saved request. It won’t retry again this launch; check disk space and permissions before relaunching."
    static let stopWriteFailed = "Oversight couldn’t be removed from saved state, so the link is still active. Check disk space and Application Support permissions, then try again."
    static let automaticCleanupFailed = "Oversight ended, but RepoPrompt couldn’t update saved oversight links. It may be restored after relaunch."
    static let shutdownBeforeInsert = "RepoPrompt is shutting down, so oversight wasn’t changed."
    static let shutdownAfterInsert = "RepoPrompt is shutting down. Oversight wasn’t started, but its saved request can be reconsidered next launch."

    static func message(for reason: AgentSessionOversightPersistenceBlockReason) -> String {
        switch reason {
        case .unsupportedFutureSchema:
            futureSchema
        // A preserved oversized or over-long file reads to the user exactly like an unreadable one:
        // RepoPrompt kept the file and refuses to change it. Naming the limit would be diagnostics,
        // not something they can act on.
        case .unreadable, .fileTooLarge, .tooManyRows:
            unreadable
        }
    }
}

// MARK: - Persistence presentation

/// One bounded, dismissible app-level warning about durable oversight state.
///
/// Identifiers are runtime-stable strings derived from the *kind* of warning, never from a session
/// name or UUID: these strings are rendered in every window, and the whole point of the aggregate
/// surface is that it says nothing about which sessions were involved.
struct AgentSessionOversightWarning: Equatable, Identifiable {
    let id: String
    let message: String
}

/// Process-wide durable-oversight state, overlaid onto every window's Oversee props.
///
/// The bridge owns exactly one of these and broadcasts it; a tab with no links at all still has to
/// render it, because "saved oversight links can’t be changed" is precisely the state in which the
/// user is about to try to create their first one.
struct AgentSessionOversightPersistencePresentation: Equatable {
    enum Availability: Equatable {
        /// The launch load has not settled yet.
        case loading
        /// The store is readable and writable, and automatic restore ran.
        case ready
        /// Readable and writable, but window restoration is off so saved intent stays dormant.
        case dormant
        /// Deterministic or persistence-suppressed launch: no production file I/O at all.
        case suppressed
        /// The file was preserved and mutation is refused. Carries the exact user-facing reason.
        case blocked(String)
    }

    /// Cap and dedupe are both deliberate: a repeated disk failure must not turn the popover into a
    /// log, and five is already more than a user can act on at once.
    static let maxWarnings = 5

    var availability: Availability
    var warnings: [AgentSessionOversightWarning]
    /// A token-qualified cleanup that failed to write. Surfaces **Retry saving**, which is one of the
    /// few permitted retry triggers — ordinary topology events never retry disk cleanup.
    var hasPendingCleanupRetry: Bool

    init(
        availability: Availability = .loading,
        warnings: [AgentSessionOversightWarning] = [],
        hasPendingCleanupRetry: Bool = false
    ) {
        self.availability = availability
        self.warnings = warnings
        self.hasPendingCleanupRetry = hasPendingCleanupRetry
    }

    /// Neutral value for a process with no durable layer installed (focused tests, headless runs).
    ///
    /// Deliberately `.ready` rather than `.loading`: with no store there is nothing to wait for, and
    /// reporting “still loading” forever would disable Add in every context that never wanted
    /// persistence in the first place.
    static let noDurableLayer = AgentSessionOversightPersistencePresentation(availability: .ready)

    /// Why Add must stay disabled for persistence reasons, or `nil`.
    ///
    /// Composed ahead of live endpoint eligibility: a session that is perfectly eligible still cannot
    /// be granted oversight while the durable record cannot be written.
    var addBlockerMessage: String? {
        switch availability {
        case .loading:
            AgentSessionOversightPersistenceCopy.loading
        case .ready, .dormant:
            nil
        case .suppressed:
            AgentSessionOversightPersistenceCopy.suppressedLaunch
        case let .blocked(message):
            message
        }
    }

    /// Informational line rendered even when Add is permitted.
    var noticeMessage: String? {
        guard case .dormant = availability else { return nil }
        return AgentSessionOversightPersistenceCopy.autoRestoreDisabled
    }

    /// Appends a warning under the cap, collapsing an existing entry with the same identity.
    ///
    /// Returns `false` when nothing changed, so a caller can skip a broadcast that would repaint
    /// every window for an identical value.
    @discardableResult
    mutating func appendWarning(id: String, message: String) -> Bool {
        if let existing = warnings.first(where: { $0.id == id }), existing.message == message {
            return false
        }
        warnings.removeAll { $0.id == id }
        warnings.append(AgentSessionOversightWarning(id: id, message: message))
        if warnings.count > Self.maxWarnings {
            // Oldest first: the newest failure is the one the user is currently reacting to.
            warnings.removeFirst(warnings.count - Self.maxWarnings)
        }
        return true
    }

    @discardableResult
    mutating func dismissWarnings(ids: Set<String>) -> Bool {
        guard warnings.contains(where: { ids.contains($0.id) }) else { return false }
        warnings.removeAll { ids.contains($0.id) }
        return true
    }
}

/// Stable warning identities. Kept as an enum so the dedupe key can never drift from the copy.
enum AgentSessionOversightWarningID {
    static let quarantined = "oversight.persistence.quarantined"
    static let terminalRestoration = "oversight.persistence.terminalRestoration"
    static let cleanupFailed = "oversight.persistence.cleanupFailed"
    static let compensationFailed = "oversight.persistence.compensationFailed"
}

/// Outcome of stopping one oversight row.
///
/// Distinguishes "the link is gone" from "it was already gone" from "nothing changed, and here is
/// why": a Stop that could not commit its durable removal must never render as success, because the
/// link is still live and will still be restored next launch.
enum AgentMonitorStopOutcome: Equatable {
    case stopped
    case alreadyStopped
    case failed(message: String)

    var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

/// Outcome of the popover's resolve/add flow.
enum AgentMonitorAddOutcome: Equatable {
    case added(linkID: UUID, targetSessionID: UUID)
    /// The exact endpoint pair already has an active link; no second generation is created.
    case alreadyLinked(linkID: UUID, targetSessionID: UUID)
    case failed(AgentSessionLinkResolveFailure)
    /// The authority refused the reservation or activation for a non-resolution reason.
    case rejected(message: String)

    var failureMessage: String? {
        switch self {
        case .added, .alreadyLinked:
            nil
        case let .failed(failure):
            failure.uiMessage
        case let .rejected(message):
            message
        }
    }
}
