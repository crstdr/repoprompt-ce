import AppKit
import RepoPromptDomainRuntime
import SwiftUI

/// Labeled **Oversee** pill, placed between Workflow and Interview.
///
/// It opens a management popover rather than acting as a one-shot toggle: oversight is
/// session-scoped and survives until explicit or lifecycle revocation, so the user needs a surface
/// that lists both directions and offers Unlink at either end.
struct AgentMonitorPill: View {
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    @State private var showPopover = false

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var props: AgentMonitorPillProps {
        statusPillsUI.snapshot.monitor
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.statusPills.monitor")
        #endif
        let cornerRadius = AgentPillMetrics.cornerRadius()
        let height = AgentPillMetrics.height()
        let horizontalPadding = AgentPillMetrics.horizontalPadding()
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                // Status is carried by the glyph and the count text, never by colour alone.
                Image(systemName: props.isActive ? "eye.fill" : "eye")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                Text("Oversee")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                if props.isActive {
                    Text("\(props.outbound.count)")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        .monospacedDigit()
                }
                if props.hasInbound {
                    // Distinct directional inbound indicator: another session is observing this one.
                    HStack(spacing: 1) {
                        Image(systemName: "arrow.down.left")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .bold))
                        Text("\(props.inbound.count)")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.orange)
                }
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
            }
            .foregroundStyle(props.isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    props.isActive || props.hasInbound
                        ? Color.accentColor.opacity(0.4)
                        : Color.secondary.opacity(0.15),
                    lineWidth: props.isActive || props.hasInbound ? 1 : 0.5
                )
        )
        .hoverTooltip("Oversee other Agent sessions in any window", .top)
        .accessibilityLabel("Oversee")
        .accessibilityValue(props.accessibilityValue)
        .accessibilityHint("Opens cross-window session oversight")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            AgentMonitorPopoverView(props: props)
        }
    }
}

// MARK: - Popover

struct AgentMonitorPopoverView: View {
    let props: AgentMonitorPillProps

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @AppStorage(AgentMonitorDashboardSortMode.preferenceKey)
    private var sortModeRawValue = AgentMonitorDashboardSortMode.smart.rawValue
    @State private var identifierText = ""
    @State private var preview: AgentMonitorResolvedPreview?
    /// Persistent validation text. Errors are never conveyed by transient colour alone.
    @State private var validationMessage: String?
    @State private var isWorking = false
    /// One busy gate per generation-qualified row. Navigation, triage, acknowledgement, and durable
    /// Unlink must not race from the same stale projection.
    @State private var busyLinkIDs: Set<UUID> = []
    /// Persistent per-row feedback for routing, triage, acknowledgement, and durable Unlink failures.
    @State private var actionFailureByLinkID: [UUID: String] = [:]
    @State private var isRetryingSave = false
    /// Observer-level, deliberately not part of `busyLinkIDs`: the passive preference covers every
    /// outbound link at once, so gating it on a row would disable an unrelated row's actions.
    @State private var isChangingPassiveUpdates = false
    @State private var passiveUpdatesFailureMessage: String?
    /// The most recent successful Unlink, recoverable for a bounded window. One slot per open
    /// popover: a second Unlink replaces it, and closing the popover drops it.
    @State private var undoSlot: UndoSlot?
    /// Failure text from a rejected recovery attempt. The banner stays until the retry window ends.
    @State private var undoFailureMessage: String?
    @State private var isUndoing = false
    @State private var undoExpiryTask: Task<Void, Never>?
    /// Anchored once per open popover rather than recomputed in `body`, so an unrelated repaint
    /// cannot keep restarting the minute schedule and starve the tick it exists to deliver.
    @State private var freshnessTickAnchor = Date()

    private enum Layout {
        /// Wide enough for identity plus the inline action strip; the plan's starting value for live
        /// visual QA.
        static let baseWidth: CGFloat = 500
        static let baseHeight: CGFloat = 430
    }

    private var popoverWidth: CGFloat {
        fontPreset.scaledClamped(Layout.baseWidth, max: 660)
    }

    private var popoverHeight: CGFloat {
        fontPreset.scaledClamped(Layout.baseHeight, max: 580)
    }

    private var existingOutboundTargetIDs: Set<UUID> {
        Set(props.outbound.map(\.targetSessionID))
    }

    private var sortMode: AgentMonitorDashboardSortMode {
        AgentMonitorDashboardSortMode.resolved(preferenceRawValue: sortModeRawValue)
    }

    private var sortedOutbound: [AgentMonitorPillProps.Outbound] {
        AgentMonitorDashboardSortPolicy.sorted(props.outbound, mode: sortMode)
    }

    /// Fixed, collision-free identity tokens computed across the whole visible set, so two rows
    /// carrying the same display name are still told apart without a permanent full-UUID line.
    private var shortTokensByTargetID: [UUID: String] {
        AgentMonitorSessionIDFormatter.distinctShortTokens(for: props.outbound.map(\.targetSessionID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    addSection
                    if hasPersistenceContent {
                        Divider()
                        persistenceSection
                    }
                    if !props.outbound.isEmpty {
                        Divider()
                        outboundSection
                    }
                    if !props.inbound.isEmpty {
                        Divider()
                        inboundSection
                    }
                    if !props.recentNotices.isEmpty {
                        Divider()
                        noticesSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Pinned below the scroll area: the row it belongs to is already gone, so the recovery
            // must not depend on where the user happens to be scrolled.
            if let undoSlot {
                Divider()
                undoBanner(undoSlot)
            }
        }
        .frame(width: popoverWidth, height: popoverHeight)
        .accessibilityElement(children: .contain)
        .onDisappear {
            // Presentation only. The revocation itself already committed and stays committed.
            undoExpiryTask?.cancel()
            undoExpiryTask = nil
        }
    }

    // MARK: Add

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Oversee a session")

            TextField("Session ID", text: $identifierText)
                .textFieldStyle(.roundedBorder)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .accessibilityLabel("Session ID to oversee")
                .onChange(of: identifierText) { _, _ in refreshPreview() }
                .onSubmit { submit() }

            HStack(spacing: 6) {
                Button("Paste from Clipboard") { pasteFromClipboard() }
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .accessibilityHint("Pastes a copied session ID")

                Spacer(minLength: 0)

                Button("Oversee session") { submit() }
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                    .disabled(!props.canAdd || preview == nil || isWorking)
            }

            if let reason = props.canAddReason {
                messageText(reason)
            } else if let validationMessage {
                messageText(validationMessage)
            }

            if let preview {
                previewRow(preview)
            }
        }
    }

    private func previewRow(_ preview: AgentMonitorResolvedPreview) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AgentMonitorStatusIndicator(status: preview.status, fontPreset: fontPreset)
                Text(preview.displayName)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    .lineLimit(1)
                Text(preview.shortID)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Text(preview.detailLine)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .hoverTooltip(preview.fullID, .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preview.accessibilityLabel)
    }

    // MARK: Lists

    private var outboundSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                sectionHeader("Overseeing")
                Spacer(minLength: 0)
                passiveUpdatesToggle
                sortMenu
            }
            if let passiveUpdatesFailureMessage {
                messageText(passiveUpdatesFailureMessage)
            }
            // One popover-scoped minute tick drives every row's relative timestamp from the same
            // instant. It exists only while the popover is open and performs no authority work.
            TimelineView(.periodic(from: freshnessTickAnchor, by: 60)) { timeline in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sortedOutbound) { row in
                        outboundRow(row, now: timeline.date)
                    }
                }
            }
        }
    }

    private func outboundRow(_ row: AgentMonitorPillProps.Outbound, now: Date) -> some View {
        let isBusy = busyLinkIDs.contains(row.linkID)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AgentMonitorStatusIndicator(status: row.status, fontPreset: fontPreset)
                    .hoverTooltip(row.status.tooltip, .top)
                HStack(spacing: 5) {
                    Text(row.displayName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Fixed width and never truncated: it is the only at-a-glance identity breaker
                    // between two rows that share a display name.
                    Text(shortTokensByTargetID[row.targetSessionID] ?? row.shortID)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.secondary)
                        .monospaced()
                        .fixedSize()
                }
                .hoverTooltip(row.identityTooltip, .top)
                Spacer(minLength: 6)
                outboundActions(row, isBusy: isBusy)
            }
            if !row.locationProviderLine.isEmpty {
                Text(row.locationProviderLine)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 5) {
                Text(row.statusActivityLine(now: now))
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .hoverTooltip(row.activityTooltip, .top)
                if row.hasUnreadActivity {
                    unreadBadge(row, isBusy: isBusy)
                }
                Spacer(minLength: 0)
            }
            if let message = actionFailureByLinkID[row.linkID] {
                messageText(message)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(row.accessibilityDescription)
    }

    /// The row's common actions, promoted out of an overflow menu.
    ///
    /// They share `busyLinkIDs`, so View, New, Done, and Unlink can never act concurrently against
    /// one stale row.
    private func outboundActions(_ row: AgentMonitorPillProps.Outbound, isBusy: Bool) -> some View {
        HStack(spacing: 8) {
            inlineActionButton(
                title: "View",
                systemImage: "arrow.up.right.square",
                accessibilityLabel: row.viewActionLabel,
                tooltip: row.targetRoute == nil
                    ? AgentMonitorRowActionCopy.viewDisabledTooltip
                    : AgentMonitorRowActionCopy.viewTooltip,
                isDisabled: isBusy || row.targetRoute == nil
            ) {
                viewAgent(row)
            }

            // Native checkbox rather than a badge plus a menu item: Done is a state the user sets,
            // and it must read as one. The binding is authoritative — the check follows the
            // republished projection rather than flipping optimistically.
            Toggle("Done", isOn: Binding(
                get: { row.triageState == .done },
                set: { _ in toggleTriage(row) }
            ))
            .toggleStyle(.checkbox)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
            .disabled(isBusy)
            .hoverTooltip(AgentMonitorRowActionCopy.doneTooltip, .top)
            .accessibilityLabel(row.doneActionLabel)
            .accessibilityHint(AgentMonitorRowActionCopy.doneHint)

            inlineActionButton(
                title: "Unlink",
                systemImage: "link.badge.minus",
                accessibilityLabel: row.unlinkActionLabel,
                tooltip: AgentMonitorRowActionCopy.unlinkTooltip,
                isDisabled: isBusy
            ) {
                unlinkOutbound(row)
            }
        }
        .fixedSize()
    }

    /// Explicit acknowledgement of new activity.
    ///
    /// Deliberately the *only* way unread clears besides Done: opening, hovering, or scrolling this
    /// dashboard proves nothing was reviewed, and View Agent proves only that the target opened.
    private func unreadBadge(_ row: AgentMonitorPillProps.Outbound, isBusy: Bool) -> some View {
        Button {
            markSeen(row)
        } label: {
            Text(AgentMonitorRowActionCopy.unreadBadge)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.18))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .hoverTooltip(AgentMonitorRowActionCopy.unreadTooltip, .top)
        .accessibilityLabel(row.markSeenActionLabel)
    }

    private func inlineActionButton(
        title: String,
        systemImage: String,
        accessibilityLabel: String,
        tooltip: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .labelStyle(.titleAndIcon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isDisabled)
        .hoverTooltip(tooltip, .top)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The observer-level passive status-update switch.
    ///
    /// The binding reads `props`, never local state: the bridge is authoritative, and the same
    /// preference can be changed by this session's own agent through `agent_session_link`. A checkbox
    /// that flipped optimistically would show the user a preference the authority had refused, or
    /// hide one the agent had just changed underneath them.
    private var passiveUpdatesToggle: some View {
        Toggle(AgentMonitorPassiveUpdatesCopy.label, isOn: Binding(
            get: { props.passiveNoticesEnabled },
            set: { setPassiveUpdates($0) }
        ))
        .toggleStyle(.checkbox)
        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
        .disabled(isChangingPassiveUpdates)
        .fixedSize()
        .hoverTooltip(AgentMonitorPassiveUpdatesCopy.tooltip, .top)
        .accessibilityLabel(AgentMonitorPassiveUpdatesCopy.accessibilityLabel)
        .accessibilityHint(AgentMonitorPassiveUpdatesCopy.accessibilityHint)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(AgentMonitorDashboardSortMode.allCases) { mode in
                Button {
                    sortModeRawValue = mode.rawValue
                } label: {
                    if mode == sortMode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            Label(sortMode.label, systemImage: "arrow.up.arrow.down")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Sort overseen sessions")
        .accessibilityValue(sortMode.label)
    }

    private var inboundSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Overseen by")
            ForEach(props.inbound) { row in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.left")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.rowLabel)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                            .lineLimit(1)
                        Text(row.detailLine)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // Either endpoint may revoke; both windows update from one authority transition.
                    // On an inbound row this projection's session is the *target*, so the pair is
                    // built the other way around.
                    unlinkButton(
                        label: row.unlinkActionLabel,
                        linkID: row.linkID,
                        // Inbound recovery re-establishes the direct grant on behalf of the other
                        // session through the same user-level authority that just removed it. It
                        // grants nothing beyond the relationship the user themselves ended.
                        undo: props.sessionID.map { targetSessionID in
                            UndoSlot(
                                direction: .inbound,
                                observerSessionID: row.observerSessionID,
                                targetSessionID: targetSessionID,
                                displayName: row.displayName
                            )
                        }
                    ) {
                        guard let targetSessionID = props.sessionID else { return .alreadyStopped }
                        return await AgentSessionLinkRuntimeBridge.shared.stopMonitorLink(
                            observerSessionID: row.observerSessionID,
                            targetSessionID: targetSessionID,
                            linkID: row.linkID,
                            generation: row.generation
                        )
                    }
                }
                .hoverTooltip(row.fullID, .top)
                .accessibilityElement(children: .contain)
                .accessibilityValue(row.accessibilityDescription)
                if let message = actionFailureByLinkID[row.linkID] {
                    messageText(message)
                }
            }
        }
    }

    private var noticesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                sectionHeader("Recent endings")
                Spacer(minLength: 0)
                // Addressed by exact incarnation: notices belong to the endpoint they were recorded
                // for, so a duplicate live incarnation of this UUID must not dismiss another's.
                dismissButton(label: "Dismiss recent oversight endings")
            }
            ForEach(props.recentNotices) { notice in
                Text(notice.message)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func messageText(_ message: String) -> some View {
        Text(message)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isStaticText)
    }

    private func unlinkButton(
        label: String,
        linkID: UUID,
        undo: UndoSlot?,
        action: @escaping () async -> AgentMonitorStopOutcome
    ) -> some View {
        Button("Unlink") {
            performUnlink(linkID: linkID, undo: undo, action: action)
        }
        .buttonStyle(.plain)
        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .disabled(busyLinkIDs.contains(linkID))
        .accessibilityLabel(label)
    }

    // MARK: Persistence

    private var hasPersistenceContent: Bool {
        props.persistence.noticeMessage != nil
            || !props.persistence.warnings.isEmpty
            || props.persistence.hasPendingCleanupRetry
    }

    /// Aggregate durable-oversight state. Deliberately names no session and shows no identifier:
    /// this text is broadcast to every window, and the only actionable content is what the user can
    /// do about it.
    private var persistenceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                sectionHeader("Saved oversight")
                Spacer(minLength: 0)
                if !props.persistence.warnings.isEmpty {
                    dismissButton(label: "Dismiss saved oversight warnings")
                }
            }
            if let notice = props.persistence.noticeMessage {
                messageText(notice)
            }
            ForEach(props.persistence.warnings) { warning in
                messageText(warning.message)
            }
            if props.persistence.hasPendingCleanupRetry {
                Button("Retry saving") {
                    guard !isRetryingSave else { return }
                    isRetryingSave = true
                    Task {
                        await AgentSessionLinkRuntimeBridge.shared.retryPendingIntentCleanup()
                        isRetryingSave = false
                    }
                }
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .disabled(isRetryingSave)
                .accessibilityHint("Retries updating saved oversight links")
            }
        }
    }

    /// Clears this endpoint's authority notices **and** the app warnings currently on screen.
    ///
    /// It deliberately does not discard pending cleanup: the disk work is still owed, and **Retry
    /// saving** is how the user asks for it. Clearing the message must not clear the obligation.
    private func dismissButton(label: String) -> some View {
        let endpoint = props.endpoint
        let warningIDs = Set(props.persistence.warnings.map(\.id))
        return Button("Dismiss") {
            AgentSessionLinkRuntimeBridge.shared.dismissPersistenceWarnings(ids: warningIDs)
            guard let endpoint else { return }
            // Addressed by exact incarnation: notices belong to the endpoint they were recorded for,
            // so a duplicate live incarnation of this UUID must not dismiss another's.
            Task { await AgentSessionLinkRuntimeBridge.shared.dismissNotices(forEndpoint: endpoint) }
        }
        .buttonStyle(.plain)
        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }

    // MARK: Unlink recovery

    /// UI-only capture of the relationship a successful Unlink just removed.
    ///
    /// It deliberately carries the canonical session pair and nothing else. The old link ID and
    /// generation are inputs to Stop only: recovery runs the ordinary Add transaction and mints a
    /// *fresh* link, so naming the retired reference here would imply a resurrection that never
    /// happens.
    private struct UndoSlot: Identifiable, Equatable {
        let id = UUID()
        let direction: AgentMonitorUnlinkUndo.Direction
        let observerSessionID: UUID
        let targetSessionID: UUID
        let displayName: String

        var message: String {
            AgentMonitorUnlinkUndo.message(direction: direction, displayName: displayName)
        }

        var undoAccessibilityLabel: String {
            AgentMonitorUnlinkUndo.undoAccessibilityLabel(direction: direction, displayName: displayName)
        }
    }

    private func undoBanner(_ slot: UndoSlot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.message)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .fixedSize(horizontal: false, vertical: true)
                if let undoFailureMessage {
                    messageText(undoFailureMessage)
                }
            }
            Spacer(minLength: 0)
            if isUndoing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Re-linking")
            }
            Button("Undo") {
                performUndo(slot)
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
            .disabled(isUndoing)
            .hoverTooltip(AgentMonitorUnlinkUndo.undoTooltip, .top)
            .accessibilityLabel(slot.undoAccessibilityLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
    }

    /// Offers one bounded recovery window, replacing any earlier one.
    ///
    /// The clock starts when Stop *completed*, not when the user clicked: a slow durable removal
    /// must not silently consume the window it earned.
    private func presentUndo(_ slot: UndoSlot) {
        undoExpiryTask?.cancel()
        undoFailureMessage = nil
        isUndoing = false
        undoSlot = slot
        startUndoExpiry(for: slot.id)
    }

    private func startUndoExpiry(for slotID: UUID) {
        undoExpiryTask?.cancel()
        undoExpiryTask = Task {
            // Monotonic by construction: a wall-clock change cannot shorten or extend the window.
            try? await Task.sleep(for: AgentMonitorUnlinkUndo.window)
            guard !Task.isCancelled, undoSlot?.id == slotID else { return }
            undoSlot = nil
            undoFailureMessage = nil
            undoExpiryTask = nil
        }
    }

    /// Recovers by creating a new link through the ordinary Add entry point.
    ///
    /// Nothing about the retired grant is restored: it has a new reference and generation, and Done,
    /// unread, cursors, and delivery state all start fresh. `.alreadyLinked` counts as recovered
    /// because the user's goal — the relationship exists again — is satisfied.
    private func performUndo(_ slot: UndoSlot) {
        guard !isUndoing else { return }
        isUndoing = true
        undoFailureMessage = nil
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        Task {
            let outcome = await AgentSessionLinkRuntimeBridge.shared.addMonitorLink(
                observerSessionID: slot.observerSessionID,
                rawTargetSessionID: slot.targetSessionID.uuidString
            )
            isUndoing = false
            guard undoSlot?.id == slot.id else { return }
            switch outcome {
            case .added, .alreadyLinked:
                undoSlot = nil
                undoFailureMessage = nil
            case .failed, .rejected:
                // The endpoint may have closed or become ineligible in the meantime. Report it
                // honestly and give the user one more bounded window to retry.
                undoFailureMessage = outcome.failureMessage
                startUndoExpiry(for: slot.id)
            }
        }
    }

    // MARK: Actions

    private func pasteFromClipboard() {
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        identifierText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolution is pure and read-only: it scans live windows without focusing, activating, or
    /// switching the target. Knowing or pasting a UUID still grants nothing.
    private func refreshPreview() {
        let trimmed = identifierText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            preview = nil
            validationMessage = nil
            return
        }
        switch AgentSessionLinkRuntimeBridge.shared.resolvePreview(
            observerSessionID: props.sessionID,
            rawTargetSessionID: trimmed,
            existingOutboundTargetIDs: existingOutboundTargetIDs
        ) {
        case let .success(resolved):
            preview = resolved
            validationMessage = nil
        case let .failure(failure):
            preview = nil
            validationMessage = failure.uiMessage
        }
    }

    private func viewAgent(_ row: AgentMonitorPillProps.Outbound) {
        guard !busyLinkIDs.contains(row.linkID) else { return }
        guard let route = row.targetRoute else {
            actionFailureByLinkID[row.linkID] = "That Agent session’s location is unavailable."
            return
        }
        busyLinkIDs.insert(row.linkID)
        actionFailureByLinkID.removeValue(forKey: row.linkID)
        Task {
            let result = await AppDeepLinkRouter.shared.route(agentSession: route)
            busyLinkIDs.remove(row.linkID)
            switch result {
            case .routed:
                actionFailureByLinkID.removeValue(forKey: row.linkID)
            case let .workspaceSwitchBlocked(message):
                let message = message?.trimmingCharacters(in: .whitespacesAndNewlines)
                actionFailureByLinkID[row.linkID] = if let message, !message.isEmpty {
                    message
                } else {
                    "RepoPrompt couldn’t switch to that Agent session’s workspace."
                }
            case .blockedByActiveDifferentSession:
                actionFailureByLinkID[row.linkID] =
                    "That tab is actively running another Agent session. Try again after it finishes."
            case .workspaceUnavailable, .tabUnavailable, .sessionUnavailable, .sessionMismatch:
                actionFailureByLinkID[row.linkID] = "That Agent session is no longer available."
            }
        }
    }

    /// Acknowledges new activity without touching Done, status, or authority.
    private func markSeen(_ row: AgentMonitorPillProps.Outbound) {
        guard !busyLinkIDs.contains(row.linkID) else { return }
        guard let observerEndpoint = props.endpoint else {
            actionFailureByLinkID[row.linkID] = "That oversight link is no longer active."
            return
        }
        busyLinkIDs.insert(row.linkID)
        actionFailureByLinkID.removeValue(forKey: row.linkID)
        let reference = DomainAgentSessionLinkReference(
            linkID: row.linkID,
            generation: row.generation
        )
        Task {
            let outcome = await AgentSessionLinkRuntimeBridge.shared.markMonitorActivitySeen(
                observerEndpoint: observerEndpoint,
                targetSessionID: row.targetSessionID,
                expectedReference: reference
            )
            busyLinkIDs.remove(row.linkID)
            actionFailureByLinkID[row.linkID] = outcome.failureMessage
        }
    }

    /// Requests a passive-preference change and renders whatever the bridge settles on.
    ///
    /// Addressed to the exact incarnation this projection was published to: a duplicate live
    /// incarnation of the same session UUID must not have its preference changed from another
    /// window's dashboard. Nothing here touches link authority — turning narration off is not
    /// unlinking — and nothing starts a turn.
    private func setPassiveUpdates(_ enabled: Bool) {
        guard !isChangingPassiveUpdates else { return }
        guard let observerEndpoint = props.endpoint else {
            passiveUpdatesFailureMessage = AgentMonitorPassiveUpdatesCopy.unavailableMessage
            return
        }
        isChangingPassiveUpdates = true
        passiveUpdatesFailureMessage = nil
        Task {
            let outcome = await AgentSessionLinkRuntimeBridge.shared.setPassiveMonitorNoticesEnabled(
                enabled,
                observerEndpoint: observerEndpoint
            )
            isChangingPassiveUpdates = false
            passiveUpdatesFailureMessage = outcome.failureMessage
        }
    }

    private func toggleTriage(_ row: AgentMonitorPillProps.Outbound) {
        guard !busyLinkIDs.contains(row.linkID) else { return }
        guard let observerEndpoint = props.endpoint else {
            actionFailureByLinkID[row.linkID] = "That oversight link is no longer active."
            return
        }
        busyLinkIDs.insert(row.linkID)
        actionFailureByLinkID.removeValue(forKey: row.linkID)
        let requestedState: AgentMonitorTriageState = row.triageState == .done ? .active : .done
        let reference = DomainAgentSessionLinkReference(
            linkID: row.linkID,
            generation: row.generation
        )
        Task {
            let outcome = await AgentSessionLinkRuntimeBridge.shared.setMonitorTriageState(
                observerEndpoint: observerEndpoint,
                targetSessionID: row.targetSessionID,
                expectedReference: reference,
                state: requestedState
            )
            busyLinkIDs.remove(row.linkID)
            actionFailureByLinkID[row.linkID] = outcome.failureMessage
        }
    }

    private func unlinkOutbound(_ row: AgentMonitorPillProps.Outbound) {
        performUnlink(
            linkID: row.linkID,
            undo: props.sessionID.map { observerSessionID in
                UndoSlot(
                    direction: .outbound,
                    observerSessionID: observerSessionID,
                    targetSessionID: row.targetSessionID,
                    displayName: row.displayName
                )
            }
        ) {
            // The durable pair is derived from the row's owner and peer rather than duplicated on the
            // row, because this projection is already addressed to the exact observer incarnation.
            guard let observerSessionID = props.sessionID else { return .alreadyStopped }
            return await AgentSessionLinkRuntimeBridge.shared.stopMonitorLink(
                observerSessionID: observerSessionID,
                targetSessionID: row.targetSessionID,
                linkID: row.linkID,
                generation: row.generation
            )
        }
    }

    /// Revokes immediately, then offers recovery only for the outcome that proves this action
    /// performed the removal.
    ///
    /// `.failed` keeps the relationship, so there is nothing to undo; `.alreadyStopped` means some
    /// other path removed it, and offering to recreate a link this click did not end would be a
    /// different decision than the one the user made.
    private func performUnlink(
        linkID: UUID,
        undo: UndoSlot?,
        action: @escaping () async -> AgentMonitorStopOutcome
    ) {
        guard !busyLinkIDs.contains(linkID) else { return }
        busyLinkIDs.insert(linkID)
        actionFailureByLinkID.removeValue(forKey: linkID)
        Task {
            let outcome = await action()
            busyLinkIDs.remove(linkID)
            // A failed durable removal is still live and still saved, so it must remain visible.
            actionFailureByLinkID[linkID] = outcome.failureMessage
            if outcome == .stopped, let undo {
                presentUndo(undo)
            }
        }
    }

    private func submit() {
        guard props.canAdd, preview != nil, !isWorking, let observerSessionID = props.sessionID else { return }
        let raw = identifierText.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        Task {
            let outcome = await AgentSessionLinkRuntimeBridge.shared.addMonitorLink(
                observerSessionID: observerSessionID,
                rawTargetSessionID: raw
            )
            isWorking = false
            if let message = outcome.failureMessage {
                validationMessage = message
                preview = nil
            } else {
                identifierText = ""
                preview = nil
                validationMessage = nil
            }
        }
    }
}

// MARK: - Status indicator

/// The status mark shared by the resolved preview and every outbound row.
///
/// It is a *status* vocabulary, not a transport control: the former `play.circle`/`pause.circle`
/// pair read as buttons the user could press, and Idle is not “paused”. Shape distinguishes all four
/// states without colour, the adjacent status word remains the primary semantic label, and the mark
/// itself is decorative for VoiceOver so the state is spoken once through the row value.
///
/// Composition is the descriptor's (`marks(reduceMotion:)`); only geometry and colour are the view's.
/// Reduce Motion therefore drops one element — the pulse — and cannot flatten Running into the same
/// bare dot as Waiting.
private struct AgentMonitorStatusIndicator: View {
    let status: AgentMonitorLinkStatus
    let fontPreset: FontScalePreset

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var descriptor: AgentMonitorStatusIndicatorDescriptor {
        status.indicator
    }

    /// Stable layout box, so rows never shift as a target changes state.
    private var frameSize: CGFloat {
        fontPreset.scaledClamped(14, max: 20)
    }

    private var tint: Color {
        switch descriptor.tone {
        case .live: .green
        case .neutral: .secondary
        case .attention: .orange
        case .dimmed: Color.secondary.opacity(0.55)
        }
    }

    /// The static ring Running always wears. Sized so the pulse can start from it rather than cross
    /// it, and so the whole animation stays inside the layout box.
    private var haloDiameter: CGFloat {
        frameSize * 0.78
    }

    var body: some View {
        ZStack {
            ForEach(descriptor.marks(reduceMotion: reduceMotion), id: \.self) { mark in
                markBody(mark)
            }
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func markBody(_ mark: AgentMonitorStatusIndicatorDescriptor.Mark) -> some View {
        switch mark {
        case .pulse:
            // Absent from the mark list rather than hidden while running, so nothing retains a
            // repeating animation once the target stops running, the row disappears, or Reduce
            // Motion is on.
            AgentMonitorStatusPulse(tint: tint, diameter: haloDiameter)
        case .halo:
            Circle()
                .stroke(tint.opacity(0.5), lineWidth: 1)
                .frame(width: haloDiameter, height: haloDiameter)
        case .dot:
            Circle()
                .fill(tint)
                .frame(width: frameSize * 0.46, height: frameSize * 0.46)
        case .ring:
            Circle()
                .stroke(tint, lineWidth: 1.5)
                .frame(width: frameSize * 0.5, height: frameSize * 0.5)
        case .dashedRing:
            Circle()
                .stroke(tint, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: frameSize * 0.55, height: frameSize * 0.55)
        case .slash:
            Rectangle()
                .fill(tint)
                .frame(width: frameSize * 0.62, height: 1)
                .rotationEffect(.degrees(-45))
        }
    }
}

/// The running halo. Its own view so appearing/disappearing starts and ends the animation, with no
/// timer, task, or bridge state involved.
private struct AgentMonitorStatusPulse: View {
    let tint: Color
    let diameter: CGFloat

    @State private var isExpanded = false

    var body: some View {
        Circle()
            .stroke(tint, lineWidth: 1)
            .frame(width: diameter, height: diameter)
            .scaleEffect(isExpanded ? 1.25 : 1)
            .opacity(isExpanded ? 0 : 0.35)
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: isExpanded)
            .onAppear { isExpanded = true }
            .onDisappear { isExpanded = false }
    }
}
