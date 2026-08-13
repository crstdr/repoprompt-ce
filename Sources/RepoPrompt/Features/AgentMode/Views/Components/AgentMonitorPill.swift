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
    /// One busy gate per generation-qualified row. Navigation, triage, and durable Unlink must not
    /// race from the same stale projection.
    @State private var busyLinkIDs: Set<UUID> = []
    /// Persistent per-row feedback for routing, triage, and durable Unlink failures.
    @State private var actionFailureByLinkID: [UUID: String] = [:]
    @State private var isRetryingSave = false

    private enum Layout {
        static let baseWidth: CGFloat = 360
        static let baseHeight: CGFloat = 430
    }

    private var popoverWidth: CGFloat {
        fontPreset.scaledClamped(Layout.baseWidth, max: 480)
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
        }
        .frame(width: popoverWidth, height: popoverHeight)
        .accessibilityElement(children: .contain)
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
                Image(systemName: preview.status.symbolName)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
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
                sortMenu
            }
            ForEach(sortedOutbound) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.status.symbolName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(row.rowLabel)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                                .lineLimit(1)
                            if row.triageState == .done {
                                Text("Done")
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())
                                    .accessibilityHidden(true)
                            }
                        }
                        if !row.locationProviderLine.isEmpty {
                            Text(row.locationProviderLine)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Text(row.statusActivityLine)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                    outboundActionsMenu(row)
                }
                .hoverTooltip("\(row.fullID)\n\(row.activityAccessibilityLabel)", .top)
                .accessibilityElement(children: .contain)
                .accessibilityValue(row.accessibilityDescription)
                if let message = actionFailureByLinkID[row.linkID] {
                    messageText(message)
                }
            }
        }
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

    private func outboundActionsMenu(_ row: AgentMonitorPillProps.Outbound) -> some View {
        Menu {
            Button {
                viewAgent(row)
            } label: {
                Label("View Agent", systemImage: "arrow.up.right.square")
            }
            .disabled(row.targetRoute == nil)
            .hoverTooltip(
                row.targetRoute == nil
                    ? "This Agent session’s location is unavailable."
                    : "Open this Agent session"
            )

            Button {
                toggleTriage(row)
            } label: {
                Label(
                    row.triageState == .done ? "Mark Active" : "Mark Done",
                    systemImage: row.triageState == .done ? "arrow.uturn.backward.circle" : "checkmark.circle"
                )
            }

            Divider()

            Button(role: .destructive) {
                unlinkOutbound(row)
            } label: {
                Label("Unlink", systemImage: "link.badge.minus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(busyLinkIDs.contains(row.linkID))
        .accessibilityLabel("Actions for \(row.displayName)")
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
                    unlinkButton(label: row.unlinkActionLabel, linkID: row.linkID) {
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
        action: @escaping () async -> AgentMonitorStopOutcome
    ) -> some View {
        Button("Unlink") {
            performUnlink(linkID: linkID, action: action)
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
        performUnlink(linkID: row.linkID) {
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

    private func performUnlink(
        linkID: UUID,
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
