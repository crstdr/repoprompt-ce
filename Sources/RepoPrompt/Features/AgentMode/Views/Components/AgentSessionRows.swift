import AppKit
import OSLog
import RepoPromptDomainRuntime
import SwiftUI

// MARK: - Sidebar tap diagnostics

@MainActor
enum AgentSidebarTapModifierReader {
    /// Flags from `NSApp.currentEvent` when the tap handler runs.
    ///
    /// This is not captured from the mouse-down that started the click. A later
    /// flags-changed or key event can be current, and a command or shift bit on
    /// that event reinterprets the click. A nil app or a nil current event is a
    /// plain click. `NSApp` is an implicitly unwrapped optional, so a test
    /// process that has not created the shared application must not touch it.
    static func currentFlags() -> NSEvent.ModifierFlags {
        guard NSApp != nil else { return [] }
        return NSApp.currentEvent?.modifierFlags ?? []
    }

    static func gesture(for flags: NSEvent.ModifierFlags) -> AgentSidebarSelectionGesture {
        var modifiers: AgentSidebarSelectionModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return AgentSidebarSelectionGesture(modifiers: modifiers)
    }
}

@MainActor
enum AgentSidebarTapDiagnostics {
    static let logger = Logger(subsystem: "com.repoprompt.agents", category: "sidebar-tap")

    #if DEBUG
        static var recordForTests = false
        static var testLines: [String] = []
    #endif

    static func log(
        disposition: AgentSidebarSelectionGestureDisposition,
        reason: String?,
        modifierFlags: NSEvent.ModifierFlags,
        selectionCount: Int,
        workspaceMatched: Bool,
        rowID: UUID?
    ) {
        let outcome = switch disposition {
        case .activate:
            "activate"
        case .selectionChanged:
            "selectionChanged"
        case .ignored:
            "ignored"
        }
        var fields = ["outcome=\(outcome)"]
        if let reason, reason != outcome {
            fields.append("reason=\(reason)")
        }
        fields.append(contentsOf: [
            "flags=\(modifierFlags.rawValue)",
            "selection=\(selectionCount)",
            "workspaceMatched=\(workspaceMatched)",
            "row=\(rowID?.uuidString ?? "none")"
        ])
        let line = fields.joined(separator: " ")
        logger.log("\(line, privacy: .public)")
        #if DEBUG
            if recordForTests {
                testLines.append(line)
            }
        #endif
    }
}

@MainActor
enum AgentSidebarRowTap {
    static func handle(
        isInteractionEnabled: Bool,
        tapRowID: UUID?,
        tapSelectionCount: Int,
        tapWorkspaceMatched: Bool,
        onSelectionGesture: (AgentSidebarSelectionGesture) -> AgentSidebarSelectionGestureResult,
        onActivate: () -> Void
    ) {
        let flags = AgentSidebarTapModifierReader.currentFlags()
        guard isInteractionEnabled else {
            AgentSidebarTapDiagnostics.log(
                disposition: .ignored,
                reason: "interaction-disabled",
                modifierFlags: flags,
                selectionCount: tapSelectionCount,
                workspaceMatched: tapWorkspaceMatched,
                rowID: tapRowID
            )
            return
        }
        let result = onSelectionGesture(AgentSidebarTapModifierReader.gesture(for: flags))
        AgentSidebarTapDiagnostics.log(
            disposition: result.disposition,
            reason: result.reason,
            modifierFlags: flags,
            selectionCount: result.selectionCount,
            workspaceMatched: result.workspaceMatched,
            rowID: result.rowID
        )
        if result.disposition == .activate {
            onActivate()
        }
    }
}

// MARK: - Agent Session Row

/// Which presentation the unified oversight mark wears on a row, derived from the two
/// independent facts "currently overseen" (inbound links) and "created by an overseer"
/// (provenance). Colour is never the only signal — the tooltip names both facts.
enum AgentSessionOversightMarkKind: Equatable {
    /// Active inbound links and no creator provenance: linked by the user. Purple, same as
    /// the overseer eye.
    case linkedByUser
    /// Overseer-created lane with at least one active inbound link. Orange.
    case createdLinked
    /// Overseer-created lane whose links are all gone. Dim orange provenance cue.
    case createdUnlinked

    static func kind(hasInbound: Bool, creatorSessionID: UUID?) -> Self? {
        if hasInbound {
            return creatorSessionID == nil ? .linkedByUser : .createdLinked
        }
        return creatorSessionID == nil ? nil : .createdUnlinked
    }
}

struct AgentSessionRow: View {
    let title: String
    let isActive: Bool
    var isOverseer = false
    /// Revalidates and navigates to the lane's creator for the `Open creator "{name}"` item.
    /// The label itself comes from the shared menu model.
    var onOpenCreator: (() -> Void)?
    let isPinned: Bool
    let isMCPControlled: Bool
    let runState: AgentSessionRunState
    /// When non-nil, the session raised a completed/failed/waiting transition
    /// while the user was NOT viewing it. Drives a persistent attention badge
    /// that survives re-renders until the session is selected/resumed or the
    /// user dismisses the badge explicitly.
    var attentionRunState: AgentSessionRunState?
    /// Bound-worktree visual identity for this session (Item 10). When non-nil,
    /// a small colored dot/ring is overlaid at the bottom-right of the status
    /// plate without shifting the title — see `worktreeMarker`.
    var worktree: AgentWorktreeIndicator?
    /// Active worktree merge attention for this session (Item 8). When non-nil
    /// the row paints a compact merge marker after the title slot and exposes
    /// it through the row's hover tooltip and accessibility label without
    /// shifting layout — see `mergeAttentionBadge`.
    var worktreeMergeAttention: AgentWorktreeMergeAttention?
    let threadDepth: Int
    var hasThreadChildren: Bool = false
    var isThreadCollapsed: Bool = false
    var hiddenThreadDescendantCount: Int = 0
    /// Number of descendants hidden under this collapsed parent that carry
    /// an unseen run-state attention badge. When > 0 the hidden-count chip is
    /// tinted to mirror the mcp-status-style "something happened" cue.
    var hiddenThreadDescendantAttentionCount: Int = 0
    var onToggleThreadCollapse: (() -> Void)?
    var isSelected = false
    var showsSelectionPresentation = false
    var isInteractionEnabled = true
    var tapRowID: UUID?
    var tapSelectionCount = 0
    var tapWorkspaceMatched = false
    var commandProgressKind: AgentSidebarBulkActionKind?
    let onSelectionGesture: (AgentSidebarSelectionGesture) -> AgentSidebarSelectionGestureResult
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    var onStash: (() -> Void)?
    let onDelete: () -> Void
    let onRename: (String) -> Void
    var onDismissAttention: (() -> Void)?
    /// Copies this row's exact canonical session UUID.
    ///
    /// Non-nil only for live, exactly-bound, top-level sessions. The closure revalidates the captured
    /// generation-bearing target immediately before writing and returns `false` when it went stale,
    /// so a stale row performs zero clipboard writes and shows no false success.
    var onCopySessionID: (() -> Bool)?
    /// Re-resolves the exact current target projection whenever SwiftUI materializes either menu.
    /// A frozen props value would make an available observer actionable after it closed or rebound.
    var resolveSidebarOversightMenu: (@MainActor () -> AgentSidebarOversightMenuProps?)?
    /// Resolves the row's current exact target even when lifecycle eligibility makes its menu nil.
    /// This fences feedback from a system menu that stayed open across an in-place rebind.
    var resolveSidebarOversightTargetEndpoint:
        (@MainActor () -> DomainAgentSessionLinkEndpointIdentity?)?
    /// Exact Add and Stop callbacks. They never focus either endpoint's window and never mutate row
    /// presentation optimistically; the next projection publication supplies relationship state.
    var onAddSidebarOversight: (@MainActor (
        DomainAgentSessionLinkEndpointIdentity,
        DomainAgentSessionLinkEndpointIdentity
    ) async -> AgentSidebarOversightActionOutcome)?
    var onStopSidebarOversight: (@MainActor (
        DomainAgentSessionLinkEndpointIdentity,
        DomainAgentSessionLinkEndpointIdentity,
        DomainAgentSessionLinkReference
    ) async -> AgentSidebarOversightActionOutcome)?
    /// General exact-endpoint Add for the inverse direction (this row as observer). Unlike
    /// `onAddSidebarOversight` it may create the row's *first* outbound link.
    var onAddOutboundOversight: (@MainActor (
        DomainAgentSessionLinkEndpointIdentity,
        DomainAgentSessionLinkEndpointIdentity
    ) async -> AgentSidebarOversightActionOutcome)?
    /// Read-only pasted-ID resolution for the row's Session-ID sheets. Inbound resolves the
    /// prospective overseer (existing-overseer rule); outbound resolves the prospective target.
    var resolveOverseerSessionIDCandidate: (@MainActor (
        String
    ) async -> Result<AgentOversightSessionIDResolution, AgentOversightResolutionMessage>)?
    var resolveTargetSessionIDCandidate: (@MainActor (
        String
    ) async -> Result<AgentOversightSessionIDResolution, AgentOversightResolutionMessage>)?
    /// Navigates to a linked peer's exact route (the `Open "{name}"` menu items).
    var onOpenLinkedSession: (@MainActor (AgentSessionDeepLinkRoute) -> Void)?
    let sessionIDCopyAction: AgentSidebarSessionIDCopyAction

    @State private var isHovered = false
    @State private var isCopySessionIDHovered = false
    @State private var isSidebarOversightMenuHovered = false
    /// One generation-qualified busy marker per relationship. Different observers of the same target
    /// remain independently actionable.
    @State private var sidebarOversightBusyKeys: Set<AgentSidebarOversightActionKey> = []
    /// Survives hover loss and system-menu dismissal. Only a later action, success, exact target
    /// replacement, or row removal clears it.
    @State private var sidebarOversightFailureMessage: String?
    /// Invalidates every in-flight presentation outcome only when the row's exact target changes.
    /// Unrelated exact action keys may finish independently and update feedback in completion order.
    @State private var sidebarOversightTargetRevision: UInt64 = 0
    @State private var copiedFeedbackGeneration: UInt64 = 0
    @State private var showsCopiedFeedback = false
    @State private var isPinHovered = false
    @State private var isDeleteHovered = false
    @State private var isRenameHovered = false
    @State private var isStashHovered = false
    @State private var isDisclosureHovered = false
    @State private var isDismissAttentionHovered = false
    @State private var showRenameAlert = false
    @State private var showDeleteConfirmation = false
    @State private var renameText = ""
    /// Presented Session-ID sheet request, carrying the direction and the exact row endpoint
    /// captured when the menu item was chosen.
    @State private var oversightSessionIDSheet: OversightIDSheetRequest?

    private struct OversightIDSheetRequest: Identifiable {
        enum Direction {
            /// The pasted ID names the prospective overseer of this row.
            case chooseOverseer
            /// The pasted ID names the prospective target for this row.
            case chooseTarget
        }

        let direction: Direction
        let rowEndpoint: DomainAgentSessionLinkEndpointIdentity
        let rowDisplayName: String
        let id = UUID()
    }

    // MARK: - Context Menu Snapshot

    /// Snapshot of the conditions that control context menu item visibility,
    /// captured on hover. Using a snapshot prevents AppKit from observing a
    /// mid-layout item-count change (which triggers an NSRangeException when
    /// NSContextMenuImpl measures row heights for items that were just removed).
    private struct ContextMenuSnapshot {
        var isInteractionEnabled: Bool
        var showsSelectionPresentation: Bool
        var hasAttentionRunState: Bool
        var hasOnStash: Bool
        var hasOnDismissAttention: Bool
        /// Frozen for the same reason as the flags above: the oversight section's item count
        /// depends on this list, so resolving it live while the menu is open reintroduces the
        /// removed-item measurement crash.
        var sidebarOversightMenu: AgentSidebarOversightMenuProps?
    }

    @State private var menuSnapshot = ContextMenuSnapshot(
        isInteractionEnabled: true,
        showsSelectionPresentation: false,
        hasAttentionRunState: false,
        hasOnStash: false,
        hasOnDismissAttention: false,
        sidebarOversightMenu: nil
    )

    /// The oversight menu as it should appear, or nil when the section must not be offered.
    /// Evaluated at hover so the context menu's item count cannot change while it is open.
    ///
    /// Ineligible or empty directions render a greyed reason inside the menu rather than hiding
    /// it, so a non-nil projection is always presentable when the action callbacks exist.
    private var presentableSidebarOversightMenu: AgentSidebarOversightMenuProps? {
        guard allowsDirectMutations,
              let menu = resolveSidebarOversightMenu?(),
              onAddSidebarOversight != nil,
              onStopSidebarOversight != nil
        else { return nil }
        return menu
    }

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var rowMinHeight: CGFloat {
        fontPreset.scaledClamped(28, min: 28, max: 38)
    }

    private var rowHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var rowVerticalPadding: CGFloat {
        fontPreset.scaledClamped(4, max: 7)
    }

    private var rowCornerRadius: CGFloat {
        fontPreset.scaledClamped(14, max: 18)
    }

    private var rowSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var titlePinSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var titleVStackSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var pinFontSize: CGFloat {
        fontPreset.scaledClamped(10, max: 13)
    }

    private var overseerBadgeFontSize: CGFloat {
        fontPreset.scaledClamped(9, min: 9, max: 12)
    }

    private var chipHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(5, max: 7)
    }

    private var chipVerticalPadding: CGFloat {
        fontPreset.scaledClamped(1, max: 2)
    }

    private var leadingIndent: CGFloat {
        CGFloat(threadDepth) * fontPreset.scaledClamped(14, min: 14, max: 20)
    }

    private var showsDisclosureChevron: Bool {
        hasThreadChildren && onToggleThreadCollapse != nil
    }

    private var hiddenCountTooltip: String {
        let base = hiddenThreadDescendantCount == 1
            ? "1 sub-agent chat hidden"
            : "\(hiddenThreadDescendantCount) sub-agent chats hidden"
        guard hiddenThreadDescendantAttentionCount > 0 else { return base }
        let suffix = hiddenThreadDescendantAttentionCount == 1
            ? "1 needs attention"
            : "\(hiddenThreadDescendantAttentionCount) need attention"
        return base + " — " + suffix
    }

    private var disclosureAccessibilityLabel: String {
        isThreadCollapsed ? "Expand sub-agent chats" : "Collapse sub-agent chats"
    }

    private var pinActionLabel: String {
        isPinned ? "Unpin chat" : "Pin chat"
    }

    private var copySessionIDActionLabel: String {
        AgentOversightUICopy.copySessionIDTitle
    }

    private var copySessionIDIconColor: Color {
        if showsCopiedFeedback { return .green }
        return isCopySessionIDHovered ? .accentColor : .secondary
    }

    /// Revision-guarded transient confirmation: a later copy always supersedes an in-flight reset.
    private func performCopySessionID() {
        guard let onCopySessionID, onCopySessionID() else { return }
        copiedFeedbackGeneration &+= 1
        let generation = copiedFeedbackGeneration
        showsCopiedFeedback = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard copiedFeedbackGeneration == generation else { return }
            showsCopiedFeedback = false
        }
    }

    private func sidebarOversightMenuAccessibilityValue(
        _ menu: AgentSidebarOversightMenuProps
    ) -> String {
        AgentOversightUICopy.overseeByMenuAccessibilityValue(
            overseenByCount: menu.linkedObservers.count,
            availableCount: menu.availableObservers.count
        )
    }

    private func sidebarOversightInverseMenuAccessibilityValue(
        _ menu: AgentSidebarOversightMenuProps
    ) -> String {
        AgentOversightUICopy.overseeMenuAccessibilityValue(
            overseeingCount: menu.linkedTargets.count,
            availableCount: menu.availableTargets.count
        )
    }

    /// Builds the Oversee-by lane menu items from the supplied value rather than resolving them
    /// live, so the context menu can pass a snapshot frozen at hover and keep its item count
    /// stable while open. This is also the menu the overseen/provenance mark and the hover
    /// affordance open.
    @ViewBuilder
    private func sidebarOversightMenuContent(
        _ menu: AgentSidebarOversightMenuProps
    ) -> some View {
        if let reason = menu.targetIneligibleReason {
            Button(reason) {}
                .disabled(true)
        }
        if menu.observerOptions.isEmpty, menu.targetIneligibleReason == nil {
            Button(AgentOversightUICopy.noEligibleOverseers) {}
                .disabled(true)
        } else {
            ForEach(menu.observerOptions) { option in
                sidebarOversightInboundItem(option, menu: menu)
            }
        }

        if !menu.linkedObservers.isEmpty || menu.createdByLabel != nil {
            Divider()
            ForEach(menu.linkedObservers) { option in
                Button(AgentOversightUICopy.openLabel(option.menuLabel)) {
                    openLinkedSession(option.peerEndpoint)
                }
                .accessibilityHint(option.fullIdentityDescription)
            }
            if let creatorLabel = menu.createdByLabel, menu.creatorSessionID != nil {
                Button(AgentOversightUICopy.openCreatorLabel(creatorLabel)) {
                    onOpenCreator?()
                }
            }
        }

        Divider()
        Button(AgentOversightUICopy.sessionIDMenuItem) {
            presentOversightSessionIDSheet(.chooseOverseer, menu: menu)
        }
        .disabled(menu.targetIneligibleReason != nil)
    }

    /// The inverse "Make overseer of" / "Oversee" submenu: one checked list of sessions this row
    /// oversees or could oversee (ticked first), then the Session-ID escape hatch.
    @ViewBuilder
    private func sidebarOversightInverseMenuContent(
        _ menu: AgentSidebarOversightMenuProps
    ) -> some View {
        if let reason = menu.observerIneligibleReason {
            Button(reason) {}
                .disabled(true)
        }
        if menu.targetOptions.isEmpty, menu.observerIneligibleReason == nil {
            Button(AgentOversightUICopy.noSessionsToOversee) {}
                .disabled(true)
        } else {
            ForEach(menu.targetOptions) { option in
                sidebarOversightOutboundItem(option, menu: menu)
            }
        }

        Divider()
        Button(AgentOversightUICopy.sessionIDMenuItem) {
            presentOversightSessionIDSheet(.chooseTarget, menu: menu)
        }
        .disabled(menu.observerIneligibleReason != nil)
    }

    /// One checkmark row in the Oversee-by list. Checked = linked; selecting an unchecked row
    /// goes through the shared confirmation before linking; selecting a checked row unlinks
    /// without further confirmation, exactly like the old Stop item.
    private func sidebarOversightInboundItem(
        _ option: AgentSidebarOversightMenuProps.ObserverOption,
        menu: AgentSidebarOversightMenuProps
    ) -> some View {
        switch option.relationship {
        case .available:
            let key = AgentSidebarOversightActionKey.add(
                observerEndpoint: option.peerEndpoint,
                targetEndpoint: menu.targetEndpoint
            )
            return AnyView(
                Toggle(isOn: Binding(
                    get: { false },
                    set: { _ in addSidebarOversight(option, menu: menu) }
                )) {
                    inboundItemLabel(option, busy: sidebarOversightBusyKeys.contains(key))
                }
                .disabled(sidebarOversightBusyKeys.contains(key))
                .accessibilityLabel(option.menuLabel)
                .accessibilityHint(option.fullIdentityDescription)
                .accessibilityValue(sidebarOversightBusyKeys.contains(key) ? "In progress" : "")
            )
        case let .linked(reference, _):
            let key = AgentSidebarOversightActionKey.unlink(
                observerEndpoint: option.peerEndpoint,
                targetEndpoint: menu.targetEndpoint,
                reference: reference
            )
            return AnyView(
                Toggle(isOn: Binding(
                    get: { true },
                    set: { _ in
                        stopSidebarOversightLink(
                            observerEndpoint: option.peerEndpoint,
                            targetEndpoint: menu.targetEndpoint,
                            reference: reference
                        )
                    }
                )) {
                    inboundItemLabel(option, busy: sidebarOversightBusyKeys.contains(key))
                }
                .disabled(sidebarOversightBusyKeys.contains(key))
                .accessibilityLabel(AgentOversightUICopy.unlinkAccessibilityLabel(option.menuLabel))
                .accessibilityHint(option.fullIdentityDescription)
                .accessibilityValue(sidebarOversightBusyKeys.contains(key) ? "In progress" : "")
            )
        }
    }

    /// One checkmark row in the inverse Oversee list. Same toggle contract as the inbound item:
    /// checked = this row already oversees it, selecting toggles the link.
    private func sidebarOversightOutboundItem(
        _ option: AgentSidebarOversightMenuProps.TargetOption,
        menu: AgentSidebarOversightMenuProps
    ) -> some View {
        switch option.relationship {
        case .available:
            let key = AgentSidebarOversightActionKey.add(
                observerEndpoint: menu.targetEndpoint,
                targetEndpoint: option.peerEndpoint
            )
            return AnyView(
                Toggle(isOn: Binding(
                    get: { false },
                    set: { _ in addOutboundOversight(option, menu: menu) }
                )) {
                    outboundItemLabel(option, busy: sidebarOversightBusyKeys.contains(key))
                }
                .disabled(
                    sidebarOversightBusyKeys.contains(key)
                        || menu.observerIneligibleReason != nil
                )
                .accessibilityLabel(option.menuLabel)
                .accessibilityHint(option.fullIdentityDescription)
                .accessibilityValue(sidebarOversightBusyKeys.contains(key) ? "In progress" : "")
            )
        case let .linked(reference, _):
            let key = AgentSidebarOversightActionKey.unlink(
                observerEndpoint: menu.targetEndpoint,
                targetEndpoint: option.peerEndpoint,
                reference: reference
            )
            return AnyView(
                Toggle(isOn: Binding(
                    get: { true },
                    set: { _ in
                        stopSidebarOversightLink(
                            observerEndpoint: menu.targetEndpoint,
                            targetEndpoint: option.peerEndpoint,
                            reference: reference
                        )
                    }
                )) {
                    outboundItemLabel(option, busy: sidebarOversightBusyKeys.contains(key))
                }
                .disabled(sidebarOversightBusyKeys.contains(key))
                .accessibilityLabel(AgentOversightUICopy.unlinkAccessibilityLabel(option.menuLabel))
                .accessibilityHint(option.fullIdentityDescription)
                .accessibilityValue(sidebarOversightBusyKeys.contains(key) ? "In progress" : "")
            )
        }
    }

    @ViewBuilder
    private func inboundItemLabel(
        _ option: AgentSidebarOversightMenuProps.ObserverOption,
        busy: Bool
    ) -> some View {
        if busy {
            Label(option.menuLabel, systemImage: "hourglass")
        } else {
            Text(option.menuLabel)
        }
    }

    @ViewBuilder
    private func outboundItemLabel(
        _ option: AgentSidebarOversightMenuProps.TargetOption,
        busy: Bool
    ) -> some View {
        if busy {
            Label(option.menuLabel, systemImage: "hourglass")
        } else {
            Text(option.menuLabel)
        }
    }

    private func addSidebarOversight(
        _ option: AgentSidebarOversightMenuProps.ObserverOption,
        menu: AgentSidebarOversightMenuProps
    ) {
        let key = AgentSidebarOversightActionKey.add(
            observerEndpoint: option.peerEndpoint,
            targetEndpoint: menu.targetEndpoint
        )
        guard let revision = beginSidebarOversightAction(key) else { return }
        guard let current = resolveSidebarOversightMenu?(),
              current.targetEndpoint == menu.targetEndpoint,
              current.availableObservers.contains(where: {
                  $0.peerEndpoint == option.peerEndpoint
              }),
              let onAddSidebarOversight
        else {
            sidebarOversightBusyKeys.remove(key)
            setSynchronousSidebarOversightFailure(
                AgentOversightUICopy.staleSelectionMessage,
                revision: revision,
                targetEndpoint: menu.targetEndpoint
            )
            return
        }

        // Deliberately unstructured: dismissing the system menu or losing hover must not cancel an
        // authority transaction that already started.
        Task { @MainActor in
            // Shared UI confirmation gate. The dialog captures these exact endpoints; the bridge
            // revalidates them again on acceptance inside the durable Add transaction.
            let confirmed = await AgentOversightLinkConfirmation.confirm(
                observerLabel: option.displayName,
                targetLabel: menu.targetDisplayName,
                windowID: menu.targetEndpoint.windowID
            )
            guard confirmed else {
                sidebarOversightBusyKeys.remove(key)
                return
            }
            let outcome = await onAddSidebarOversight(
                option.peerEndpoint,
                menu.targetEndpoint
            )
            guard sidebarOversightBusyKeys.remove(key) != nil else { return }
            finishSidebarOversightAction(
                outcome,
                revision: revision,
                targetEndpoint: menu.targetEndpoint
            )
        }
    }

    /// Inverse-direction Add: this row becomes the observer of the chosen target. Uses the general
    /// exact-endpoint Add so a row can acquire its *first* outbound link — the inbound menu's
    /// existing-overseer precondition does not apply to this direction.
    private func addOutboundOversight(
        _ option: AgentSidebarOversightMenuProps.TargetOption,
        menu: AgentSidebarOversightMenuProps
    ) {
        let key = AgentSidebarOversightActionKey.add(
            observerEndpoint: menu.targetEndpoint,
            targetEndpoint: option.peerEndpoint
        )
        guard let revision = beginSidebarOversightAction(key) else { return }
        guard let current = resolveSidebarOversightMenu?(),
              current.targetEndpoint == menu.targetEndpoint,
              current.observerIneligibleReason == nil,
              current.availableTargets.contains(where: {
                  $0.peerEndpoint == option.peerEndpoint
              }),
              let onAddOutboundOversight
        else {
            sidebarOversightBusyKeys.remove(key)
            setSynchronousSidebarOversightFailure(
                AgentOversightUICopy.staleSelectionMessage,
                revision: revision,
                targetEndpoint: menu.targetEndpoint
            )
            return
        }

        // Deliberately unstructured: dismissing the system menu or losing hover must not cancel an
        // authority transaction that already started.
        Task { @MainActor in
            let confirmed = await AgentOversightLinkConfirmation.confirm(
                observerLabel: menu.targetDisplayName,
                targetLabel: option.displayName,
                windowID: menu.targetEndpoint.windowID
            )
            guard confirmed else {
                sidebarOversightBusyKeys.remove(key)
                return
            }
            let outcome = await onAddOutboundOversight(
                menu.targetEndpoint,
                option.peerEndpoint
            )
            guard sidebarOversightBusyKeys.remove(key) != nil else { return }
            finishSidebarOversightAction(
                outcome,
                revision: revision,
                targetEndpoint: menu.targetEndpoint
            )
        }
    }

    /// Unlinks one generation-qualified relationship in either direction. The row endpoint used for
    /// feedback fencing is always `menu.targetEndpoint` — the row this view renders.
    private func stopSidebarOversightLink(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
        reference: DomainAgentSessionLinkReference
    ) {
        let key = AgentSidebarOversightActionKey.unlink(
            observerEndpoint: observerEndpoint,
            targetEndpoint: targetEndpoint,
            reference: reference
        )
        let rowEndpoint = resolveSidebarOversightTargetEndpoint?() ?? targetEndpoint
        guard let revision = beginSidebarOversightAction(key) else { return }
        guard let onStopSidebarOversight else {
            sidebarOversightBusyKeys.remove(key)
            setSidebarOversightFailure(
                "That oversight relationship is no longer active.",
                revision: revision,
                targetEndpoint: rowEndpoint
            )
            return
        }

        // Stop intentionally does not re-resolve the peer option. Its captured authority reference
        // is the proof that lets a row unlink a peer whose live candidate has disappeared.
        Task { @MainActor in
            let outcome = await onStopSidebarOversight(
                observerEndpoint,
                targetEndpoint,
                reference
            )
            guard sidebarOversightBusyKeys.remove(key) != nil else { return }
            finishSidebarOversightAction(
                outcome,
                revision: revision,
                targetEndpoint: rowEndpoint
            )
        }
    }

    private func openLinkedSession(_ peerEndpoint: DomainAgentSessionLinkEndpointIdentity) {
        onOpenLinkedSession?(AgentSessionDeepLinkRoute(
            windowID: peerEndpoint.windowID,
            workspaceID: peerEndpoint.workspaceID,
            tabID: peerEndpoint.tabID,
            sessionID: peerEndpoint.sessionID
        ))
    }

    // MARK: - Session-ID sheets

    private func presentOversightSessionIDSheet(
        _ direction: OversightIDSheetRequest.Direction,
        menu: AgentSidebarOversightMenuProps
    ) {
        oversightSessionIDSheet = OversightIDSheetRequest(
            direction: direction,
            rowEndpoint: menu.targetEndpoint,
            rowDisplayName: menu.targetDisplayName
        )
    }

    @ViewBuilder
    private func oversightSessionIDSheetView(
        for request: OversightIDSheetRequest
    ) -> some View {
        switch request.direction {
        case .chooseOverseer:
            AgentOversightSessionIDSheet(
                title: AgentOversightUICopy.inboundSessionIDSheetTitle(
                    session: request.rowDisplayName
                ),
                fieldAccessibilityLabel: AgentOversightUICopy
                    .overseerSessionIDFieldAccessibilityLabel,
                submitLabel: AgentOversightUICopy.addOverseerButton,
                resolve: { raw in
                    guard let resolveOverseerSessionIDCandidate else {
                        return .failure(AgentOversightResolutionMessage(
                            message: AgentOversightUICopy.oversightUnavailableMessage
                        ))
                    }
                    return await resolveOverseerSessionIDCandidate(raw)
                },
                submit: { peer in
                    await submitOversightSessionID(peer, direction: .chooseOverseer, request: request)
                },
                onDismiss: { oversightSessionIDSheet = nil }
            )
        case .chooseTarget:
            AgentOversightSessionIDSheet(
                title: AgentOversightUICopy.sessionIDSheetTitle(
                    observer: request.rowDisplayName
                ),
                fieldAccessibilityLabel: AgentOversightUICopy.sessionIDFieldAccessibilityLabel,
                submitLabel: AgentOversightUICopy.overseeSessionButton,
                resolve: { raw in
                    guard let resolveTargetSessionIDCandidate else {
                        return .failure(AgentOversightResolutionMessage(
                            message: AgentOversightUICopy.oversightUnavailableMessage
                        ))
                    }
                    return await resolveTargetSessionIDCandidate(raw)
                },
                submit: { peer in
                    await submitOversightSessionID(peer, direction: .chooseTarget, request: request)
                },
                onDismiss: { oversightSessionIDSheet = nil }
            )
        }
    }

    /// Confirms and submits a Session-ID-sheet link. The exact row endpoint captured when the menu
    /// item was chosen is revalidated here — if the row rebound while the sheet or dialog was open,
    /// the request fails instead of retargeting a replacement incarnation.
    private func submitOversightSessionID(
        _ peer: AgentOversightSessionIDSheet.ResolvedPeer,
        direction: OversightIDSheetRequest.Direction,
        request: OversightIDSheetRequest
    ) async -> AgentOversightSessionIDSubmitOutcome {
        guard resolveSidebarOversightTargetEndpoint?() == request.rowEndpoint else {
            return .failed(AgentOversightUICopy.staleSelectionMessage)
        }
        let confirmed: Bool
        let outcome: AgentSidebarOversightActionOutcome
        switch direction {
        case .chooseOverseer:
            confirmed = await AgentOversightLinkConfirmation.confirm(
                observerLabel: peer.displayName,
                targetLabel: request.rowDisplayName,
                windowID: request.rowEndpoint.windowID
            )
            guard confirmed else { return .cancelled }
            guard let onAddSidebarOversight else {
                return .failed(AgentOversightUICopy.staleSelectionMessage)
            }
            outcome = await onAddSidebarOversight(peer.endpoint, request.rowEndpoint)
        case .chooseTarget:
            confirmed = await AgentOversightLinkConfirmation.confirm(
                observerLabel: request.rowDisplayName,
                targetLabel: peer.displayName,
                windowID: request.rowEndpoint.windowID
            )
            guard confirmed else { return .cancelled }
            guard let onAddOutboundOversight else {
                return .failed(AgentOversightUICopy.staleSelectionMessage)
            }
            outcome = await onAddOutboundOversight(request.rowEndpoint, peer.endpoint)
        }
        switch outcome {
        case .changed, .alreadyInRequestedState:
            return .succeeded
        case let .failed(message):
            return .failed(message)
        }
    }

    private func beginSidebarOversightAction(
        _ key: AgentSidebarOversightActionKey
    ) -> UInt64? {
        guard sidebarOversightBusyKeys.insert(key).inserted else { return nil }
        sidebarOversightFailureMessage = nil
        return sidebarOversightTargetRevision
    }

    private func finishSidebarOversightAction(
        _ outcome: AgentSidebarOversightActionOutcome,
        revision: UInt64,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        switch outcome {
        case .changed, .alreadyInRequestedState:
            setSidebarOversightFailure(nil, revision: revision, targetEndpoint: targetEndpoint)
        case let .failed(message):
            setSidebarOversightFailure(message, revision: revision, targetEndpoint: targetEndpoint)
        }
    }

    /// Stores a failure discovered by the synchronous Add re-resolution. The menu may have become
    /// `nil` precisely because the captured target or observer just became ineligible, so requiring a
    /// currently resolvable target here would suppress the stale-option feedback. If the row actually
    /// rebound, its endpoint `onChange` clears this state before any later presentation can retain it.
    private func setSynchronousSidebarOversightFailure(
        _ message: String,
        revision: UInt64,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard sidebarOversightTargetRevision == revision,
              resolveSidebarOversightTargetEndpoint?() == targetEndpoint,
              sidebarOversightFailureMessage != message
        else {
            return
        }
        sidebarOversightFailureMessage = message
        announceSidebarOversightFailure(message)
    }

    /// Writes post-await feedback only for an action on the row's still-current exact target.
    /// Unrelated action keys remain independent and update the single feedback line in completion
    /// order; endpoint replacement invalidates every captured revision at once.
    private func setSidebarOversightFailure(
        _ message: String?,
        revision: UInt64,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard sidebarOversightTargetRevision == revision,
              resolveSidebarOversightTargetEndpoint?() == targetEndpoint,
              sidebarOversightFailureMessage != message
        else {
            return
        }
        sidebarOversightFailureMessage = message
        if let message {
            announceSidebarOversightFailure(message)
        }
    }

    private func resetSidebarOversightPresentation() {
        sidebarOversightTargetRevision &+= 1
        sidebarOversightBusyKeys.removeAll()
        sidebarOversightFailureMessage = nil
    }

    /// Announces a newly stored failure once. Keeping this out of `body` prevents a hover, scroll, or
    /// projection repaint from repeating the VoiceOver announcement.
    private func announceSidebarOversightFailure(_ message: String) {
        let element: Any = if let window = NSApplication.shared.keyWindow {
            window
        } else {
            NSApplication.shared
        }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    private var renameActionLabel: String {
        "Rename chat"
    }

    private var stashActionLabel: String {
        "Stash chat for later"
    }

    private var dismissAttentionActionLabel: String {
        "Dismiss status badge"
    }

    private var deleteActionLabel: String {
        "Delete chat"
    }

    private var allowsDirectMutations: Bool {
        isInteractionEnabled && !showsSelectionPresentation
    }

    private var rowAccessibilityValue: String {
        var parts = [isSelected ? "Selected" : "Not selected"]
        // VoiceOver reads the same text as the mark tooltips (approved copy matrix).
        if let menu = resolveSidebarOversightMenu?() {
            if !menu.outboundTargetNames.isEmpty {
                parts.append(
                    AgentOversightUICopy.overseeingTooltip(targetNames: menu.outboundTargetNames)
                )
            }
            if let text = oversightMarkTooltip(menu: menu) {
                parts.append(text)
            }
        }
        if let sidebarOversightFailureMessage {
            parts.append("Oversight action failed: \(sidebarOversightFailureMessage)")
        }
        return parts.joined(separator: "; ")
    }

    private func beginRename() {
        guard allowsDirectMutations else { return }
        renameText = title
        showRenameAlert = true
    }

    private func requestDeleteConfirmation() {
        guard allowsDirectMutations else { return }
        showDeleteConfirmation = true
    }

    private func handleRowTap() {
        AgentSidebarRowTap.handle(
            isInteractionEnabled: isInteractionEnabled,
            tapRowID: tapRowID,
            tapSelectionCount: tapSelectionCount,
            tapWorkspaceMatched: tapWorkspaceMatched,
            onSelectionGesture: onSelectionGesture,
            onActivate: onSelect
        )
    }

    private func toggleSelection() {
        guard isInteractionEnabled else { return }
        _ = onSelectionGesture(.toggle)
    }

    /// Grey hover affordance on rows with no persistent oversight mark. It opens the same
    /// Oversee-by lane menu the overseen/provenance mark opens.
    private func sidebarOversightHoverMenu(
        _ menu: AgentSidebarOversightMenuProps
    ) -> some View {
        Menu {
            sidebarOversightMenuContent(menu)
        } label: {
            Image(systemName: AgentOversightUICopy.relationshipMarkIcon)
                .font(.system(size: 11))
                .foregroundColor(
                    isSidebarOversightMenuHovered || !sidebarOversightBusyKeys.isEmpty
                        ? .accentColor
                        : .secondary
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isSidebarOversightMenuHovered = $0 }
        .hoverTooltip(AgentOversightUICopy.manageOversightTooltip)
        .accessibilityLabel(AgentOversightUICopy.manageOversightTooltip)
        .accessibilityValue(sidebarOversightMenuAccessibilityValue(menu))
        .accessibilityHint("Choose exact Agent sessions that oversee this session.")
    }

    /// The two oversight submenus in the right-click context menu, sharing the frozen snapshot's
    /// menu model with the mark and hover affordances.
    private func sidebarOversightContextMenu(
        _ menu: AgentSidebarOversightMenuProps
    ) -> some View {
        Group {
            Menu {
                sidebarOversightMenuContent(menu)
            } label: {
                Label(
                    AgentOversightUICopy.overseeByTitle,
                    systemImage: AgentOversightUICopy.relationshipMarkIcon
                )
            }
            .accessibilityLabel(AgentOversightUICopy.overseeByTitle)
            .accessibilityValue(sidebarOversightMenuAccessibilityValue(menu))

            Menu {
                sidebarOversightInverseMenuContent(menu)
            } label: {
                Label(
                    menu.isOverseer
                        ? AgentOversightUICopy.overseeTitle
                        : AgentOversightUICopy.makeOverseerOfTitle,
                    systemImage: AgentOversightUICopy.relationshipMarkIcon
                )
            }
            .accessibilityLabel(
                menu.isOverseer
                    ? AgentOversightUICopy.overseeTitle
                    : AgentOversightUICopy.makeOverseerOfTitle
            )
            .accessibilityValue(sidebarOversightInverseMenuAccessibilityValue(menu))
        }
    }

    // MARK: - Overseen / provenance mark

    /// Which mark the row shows next to its title, or `nil` for none. Provenance (created by an
    /// overseer) and active inbound oversight are independent facts; both come from the same
    /// frozen menu model the mark opens.
    private func oversightMarkKind(
        menu: AgentSidebarOversightMenuProps
    ) -> AgentSessionOversightMarkKind? {
        AgentSessionOversightMarkKind.kind(
            hasInbound: menu.hasInbound,
            creatorSessionID: menu.creatorSessionID
        )
    }

    private func oversightMarkTooltip(menu: AgentSidebarOversightMenuProps) -> String? {
        let hasInbound = menu.hasInbound
        let creator = menu.createdByLabel
        let names = menu.inboundObserverNames
        let creatorIsSoleOverseer = hasInbound && names.count == 1
            && menu.inboundObserverSessionIDs.first == menu.creatorSessionID

        switch oversightMarkKind(menu: menu) {
        case .linkedByUser:
            return AgentOversightUICopy.overseenByTooltip(observerNames: names)
        case .createdLinked:
            guard let creator else { return nil }
            return creatorIsSoleOverseer
                ? AgentOversightUICopy.createdAndOverseenTooltip(creator: creator)
                : AgentOversightUICopy.createdByOverseenByTooltip(
                    creator: creator,
                    observerNames: names
                )
        case .createdUnlinked:
            guard let creator else { return nil }
            return AgentOversightUICopy.createdByUnlinkedTooltip(creator: creator)
        case .none:
            return nil
        }
    }

    /// The always-visible overseen/provenance mark. When mutations are allowed, clicking opens the
    /// Oversee-by lane menu — the same menu model as the hover affordance and the context submenu.
    /// Otherwise it stays a passive state marker so it can never offer a mutation the row forbids.
    @ViewBuilder
    private func overseenMark(
        menu: AgentSidebarOversightMenuProps,
        tooltip: String,
        interactive: Bool
    ) -> some View {
        let kind = oversightMarkKind(menu: menu)
        let color: Color = switch kind {
        case .linkedByUser, nil:
            // Same purple as the overseer eye: linked by the user.
            Color(nsColor: .systemPurple)
        case .createdLinked:
            .orange
        case .createdUnlinked:
            .orange.opacity(0.45)
        }
        if interactive {
            Menu {
                sidebarOversightMenuContent(menu)
            } label: {
                overseenMarkGlyph(menu: menu, color: color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverTooltip(tooltip)
            .accessibilityLabel(tooltip)
            .accessibilityValue(sidebarOversightMenuAccessibilityValue(menu))
        } else {
            overseenMarkGlyph(menu: menu, color: color)
                .fixedSize()
                .hoverTooltip(tooltip)
                .accessibilityLabel(tooltip)
        }
    }

    private func overseenMarkGlyph(
        menu: AgentSidebarOversightMenuProps,
        color: Color
    ) -> some View {
        HStack(spacing: 1) {
            Image(systemName: AgentOversightUICopy.relationshipMarkIcon)
                .font(.system(size: 10))
            if menu.inboundObserverNames.count > 1 {
                Text("\(menu.inboundObserverNames.count)")
                    .font(.system(size: 8, weight: .semibold))
            }
        }
        .foregroundStyle(color)
    }

    @ViewBuilder
    private var sidebarOversightFailureLine: some View {
        if let sidebarOversightFailureMessage {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(sidebarOversightFailureMessage)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
            .foregroundStyle(Color.red)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Oversight action failed")
            .accessibilityValue(sidebarOversightFailureMessage)
        }
    }

    var body: some View {
        let sidebarOversightMenu = resolveSidebarOversightMenu?()
        let sidebarOversightTargetEndpoint = resolveSidebarOversightTargetEndpoint?()
        HStack(spacing: rowSpacing) {
            if showsSelectionPresentation {
                Button(action: toggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-6) // Keep the row layout unchanged around the larger hit target.
                .disabled(!isInteractionEnabled)
                .accessibilityLabel("\(isSelected ? "Deselect" : "Select") \(title)")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }

            if threadDepth > 0 {
                Spacer()
                    .frame(width: leadingIndent)
            }

            // MCP-controlled cue is folded into the existing status plate
            // (orange-tinted dot/chevron + orange running arc) so it no
            // longer pushes the title sideways. See `mcpAccentColor`,
            // `plateGlyph`, and `AgentRowActivityArc(tint:)` below.

            // Unified 14pt status plate.
            //
            // One slot carries both the row's identity glyph (chevron for
            // expandable roots, arrow for sub-agents, anchor dot or attention
            // glyph for leaf roots) AND its run-state status (plate fill +
            // optional halo + optional running arc). Folding both into a
            // single slot keeps the title's leading X stable regardless of
            // run state — previously the title shifted ~14pt sideways when a
            // row transitioned in/out of running/waiting/failed.
            statusPlate

            // Session name
            VStack(alignment: .leading, spacing: titleVStackSpacing) {
                HStack(spacing: titlePinSpacing) {
                    Text(title)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)

                    if isOverseer {
                        overseerBadge(names: sidebarOversightMenu?.outboundTargetNames)
                    }

                    if let sidebarOversightMenu,
                       let markTooltip = oversightMarkTooltip(menu: sidebarOversightMenu)
                    {
                        overseenMark(
                            menu: sidebarOversightMenu,
                            tooltip: markTooltip,
                            interactive: allowsDirectMutations
                                && onAddSidebarOversight != nil
                                && onStopSidebarOversight != nil
                        )
                    }

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: pinFontSize))
                            .foregroundStyle(.secondary)
                    }

                    if let attention = worktreeMergeAttention {
                        mergeAttentionBadge(for: attention)
                    }

                    if isThreadCollapsed, hiddenThreadDescendantCount > 0 {
                        hiddenCountChip
                    }
                }

                sidebarOversightFailureLine
            }

            Spacer()

            // Trailing command progress or hover actions.
            if let commandProgressKind {
                commandProgressIndicator(for: commandProgressKind)
            } else if isHovered {
                if !showsSelectionPresentation, attentionRunState != nil, let onDismissAttention {
                    Button(action: onDismissAttention) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 11))
                            .foregroundColor(isDismissAttentionHovered ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isDismissAttentionHovered = $0 }
                    .hoverTooltip(dismissAttentionActionLabel)
                    .accessibilityLabel(dismissAttentionActionLabel)
                }

                // The grey hover affordance uses the same glyph as the overseen mark. Once the
                // mark is persistent — active inbound oversight or creator provenance — it already
                // opens the same lane menu, so the hover icon stays hidden on those rows.
                if allowsDirectMutations,
                   let sidebarOversightMenu,
                   oversightMarkKind(menu: sidebarOversightMenu) == nil,
                   onAddSidebarOversight != nil,
                   onStopSidebarOversight != nil
                {
                    sidebarOversightHoverMenu(sidebarOversightMenu)
                }

                if !showsSelectionPresentation, onCopySessionID != nil {
                    Button(action: performCopySessionID) {
                        Image(systemName: showsCopiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(copySessionIDIconColor)
                    }
                    .buttonStyle(.plain)
                    .onHover { isCopySessionIDHovered = $0 }
                    .hoverTooltip(showsCopiedFeedback ? "Session ID copied" : copySessionIDActionLabel)
                    .accessibilityLabel(copySessionIDActionLabel)
                    .accessibilityValue(showsCopiedFeedback ? "Session ID copied" : "")
                }

                if allowsDirectMutations {
                    Button(action: onTogglePin) {
                        Image(systemName: isPinned ? "pin.slash" : "pin")
                            .font(.system(size: 11))
                            .foregroundColor(isPinHovered ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isPinHovered = $0 }
                    .hoverTooltip(pinActionLabel)

                    Button(action: beginRename) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundColor(isRenameHovered ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isRenameHovered = $0 }
                    .hoverTooltip(renameActionLabel)

                    if let onStash {
                        Button(action: onStash) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 11))
                                .foregroundColor(isStashHovered ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .onHover { isStashHovered = $0 }
                        .hoverTooltip(stashActionLabel)
                    }

                    Button(action: requestDeleteConfirmation) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(isDeleteHovered ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isDeleteHovered = $0 }
                    .hoverTooltip(deleteActionLabel)
                }
            }
            // Selected state is already signaled by the accent-tinted background +
            // semibold title weight; a trailing checkmark was redundant.
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, rowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(isActive ? 0.28 : 0.18))
                } else if isActive {
                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                } else if isHovered {
                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .stroke(Color(NSColor.systemGray).opacity(0.5), lineWidth: 1)
                }
            }
        )
        .contentShape(Rectangle())
        .contextMenu {
            if let sidebarOversightMenu = menuSnapshot.sidebarOversightMenu {
                sidebarOversightContextMenu(sidebarOversightMenu)
                Divider()
            }

            if !menuSnapshot.showsSelectionPresentation {
                if menuSnapshot.isInteractionEnabled {
                    Button("Select chat", action: toggleSelection)

                    Divider()

                    Button(pinActionLabel, action: onTogglePin)

                    Button(renameActionLabel, action: beginRename)
                }

                if onCopySessionID != nil {
                    Button(copySessionIDActionLabel, action: performCopySessionID)
                } else {
                    Button(AgentSidebarSessionIDCopyAction.menuTitle) {
                        sessionIDCopyAction.perform()
                    }
                    .disabled(!sessionIDCopyAction.isEnabled)
                }

                if menuSnapshot.isInteractionEnabled, menuSnapshot.hasOnStash {
                    Button(stashActionLabel, action: { onStash?() })
                }

                if menuSnapshot.hasAttentionRunState, menuSnapshot.hasOnDismissAttention {
                    Button(dismissAttentionActionLabel, action: { onDismissAttention?() })
                }

                if menuSnapshot.isInteractionEnabled {
                    Divider()

                    Button(deleteActionLabel, role: .destructive, action: requestDeleteConfirmation)
                }
            }
        }
        .onHover { hovered in
            isHovered = hovered
            if hovered {
                menuSnapshot = ContextMenuSnapshot(
                    isInteractionEnabled: isInteractionEnabled,
                    showsSelectionPresentation: showsSelectionPresentation,
                    hasAttentionRunState: attentionRunState != nil,
                    hasOnStash: onStash != nil,
                    hasOnDismissAttention: onDismissAttention != nil,
                    sidebarOversightMenu: presentableSidebarOversightMenu
                )
            }
        }
        // Deliberately does not refresh `menuSnapshot`: an endpoint rebind while the menu is open
        // would change its item count, which is the crash the snapshot exists to prevent. Stale
        // presentation is safe because Add re-resolves current eligibility, while Stop is
        // exact-endpoint and generation-reference qualified.
        .onChange(of: sidebarOversightTargetEndpoint) { previous, current in
            guard previous != current else { return }
            resetSidebarOversightPresentation()
        }
        .onTapGesture(perform: handleRowTap)
        .focusable()
        .onKeyPress(.space) {
            toggleSelection()
            return .handled
        }
        .accessibilityLabel(title)
        .accessibilityValue(rowAccessibilityValue)
        .accessibilityAction(named: Text(isSelected ? "Deselect chat" : "Select chat"), toggleSelection)
        .popover(isPresented: $showDeleteConfirmation, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Delete chat?")
                    .font(.headline)
                Text("This permanently deletes this chat.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        showDeleteConfirmation = false
                    }
                    Button("Delete") {
                        guard allowsDirectMutations else { return }
                        showDeleteConfirmation = false
                        onDelete()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allowsDirectMutations)
                }
            }
            .padding()
            .frame(width: 280)
        }
        .sheet(isPresented: $showRenameAlert) {
            AgentSessionRenameSheet(
                renameText: $renameText,
                onConfirm: { newName in
                    guard allowsDirectMutations else { return }
                    showRenameAlert = false
                    onRename(newName)
                },
                onCancel: {
                    showRenameAlert = false
                }
            )
        }
        .sheet(item: $oversightSessionIDSheet) { request in
            oversightSessionIDSheetView(for: request)
        }
        .onChange(of: isInteractionEnabled) { _, isEnabled in
            guard !isEnabled else { return }
            showDeleteConfirmation = false
            showRenameAlert = false
            oversightSessionIDSheet = nil
        }
    }

    /// Non-clickable purple eye: "this session oversees others". The tooltip names the exact
    /// outbound lanes (up to three, then "+N more") from the shared in-memory projection.
    private func overseerBadge(names: [String]?) -> some View {
        Image(systemName: AgentOversightUICopy.overseerIcon)
            .font(.system(size: overseerBadgeFontSize, weight: .semibold))
            .foregroundStyle(Color(nsColor: .systemPurple))
            .fixedSize()
            .layoutPriority(1)
            .hoverTooltip(
                names?.isEmpty == false
                    ? AgentOversightUICopy.overseeingTooltip(targetNames: names ?? [])
                    : nil
            )
            .accessibilityHidden(true)
    }

    /// True when this row should advertise that it was opened by an
    /// external MCP client. Only root rows wear this cue — sub-agent
    /// rows are always MCP-driven by their parent, so the indent + arrow
    /// glyph already convey the same meaning.
    private var isMCPControlledRoot: Bool {
        isMCPControlled && threadDepth == 0
    }

    /// Compact merge-attention marker shown after the title for sessions with
    /// an active worktree merge operation in `awaiting_approval`,
    /// `conflicted`, or `awaiting_commit` state. Sized to match the existing
    /// pin glyph so layout does not jitter when attention attaches/detaches.
    private func mergeAttentionBadge(for attention: AgentWorktreeMergeAttention) -> some View {
        let tint: Color = switch attention.kind {
        case .conflicted: .orange
        case .awaitingApproval: .purple
        case .awaitingCommit: .yellow
        }
        let glyph = switch attention.kind {
        case .conflicted: "exclamationmark.triangle.fill"
        case .awaitingApproval: "arrow.triangle.merge"
        case .awaitingCommit: "checkmark.circle"
        }
        return Image(systemName: glyph)
            .font(.system(size: pinFontSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: pinFontSize + 2, height: pinFontSize + 2)
            .accessibilityLabel(attention.tooltipText)
            .hoverTooltip(attention.tooltipText)
    }

    private var hiddenCountChip: some View {
        let hasHiddenAttention = hiddenThreadDescendantAttentionCount > 0
        return Text("\(hiddenThreadDescendantCount)")
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: hasHiddenAttention ? .semibold : .medium))
            .foregroundStyle(hasHiddenAttention ? Color.orange : Color.secondary)
            .padding(.horizontal, chipHorizontalPadding)
            .padding(.vertical, chipVerticalPadding)
            .background(
                Capsule()
                    .fill(
                        hasHiddenAttention
                            ? Color.orange.opacity(0.18)
                            : Color(NSColor.systemGray).opacity(0.18)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(Color.orange.opacity(hasHiddenAttention ? 0.6 : 0), lineWidth: 1)
            )
            .hoverTooltip(hiddenCountTooltip)
            .accessibilityLabel(hiddenCountTooltip)
    }

    /// The state the status slot should visually reflect.
    ///
    /// Rules:
    /// - Running always wins (live activity outranks any stale attention).
    /// - Otherwise prefer the unseen attention state (mirrors the MCP status
    ///   "inactive/active/attention" pattern — attention is the "look at me"
    ///   signal and trumps steady-state).
    /// - Fall back to the current run state.
    private var effectiveStatusState: AgentSessionRunState {
        if runState == .running { return .running }
        if let attentionRunState { return attentionRunState }
        return runState
    }

    /// True when the current signal is a background transition the user
    /// hasn't acknowledged yet. Drives the stronger "badge" treatment.
    private var isUnseenAttention: Bool {
        guard let attentionRunState else { return false }
        // If the row is currently running we prefer to show the running arc
        // rather than a stale attention ring — attention will re-raise when
        // this run terminates.
        if runState == .running { return false }
        return AgentSessionSidebarUIStore.isAttentionEligible(attentionRunState)
    }

    /// Shared accent used to flag MCP-controlled root rows in the status
    /// plate. Orange is the same hue used elsewhere for MCP affordances
    /// (file drawer chips, in-progress streaming badge, etc).
    private static let mcpAccentColor = Color.orange

    // MARK: - Unified status plate

    ///
    /// Single 14pt leading slot that carries BOTH row identity (chevron /
    /// arrow / anchor dot / attention glyph) AND run-state status (plate
    /// fill tint + optional halo stroke + optional running arc overlay).
    ///
    /// Status vocabulary:
    ///   - idle / cancelled     → clear plate, leaf rows show a hairline dot
    ///   - running              → accent-tinted plate + rotating arc overlay,
    ///                            identity glyph remains inside
    ///   - waiting (*)          → green-tinted plate; unseen raises to a
    ///                            louder halo stroke ("needs you" cue)
    ///   - completed + unseen   → green-tinted plate + checkmark glyph
    ///   - failed               → red-tinted plate; unseen swaps the glyph
    ///                            for an exclamation mark
    ///
    /// The identity glyph (chevron / arrow / dot) is preserved except when
    /// a strong background-attention cue requires a dedicated state glyph
    /// (checkmark for unseen-completed, exclamationmark for unseen-failed).
    /// This way the plate always reserves 14pt of leading width and the
    /// title's X offset is a pure function of threadDepth.
    private var statusPlate: some View {
        ZStack {
            // Status-encoding fill tint. Stays decorative so the chevron
            // button's hit test isn't blocked.
            Circle()
                .fill(plateFillColor)
                .allowsHitTesting(false)

            // Louder halo for unseen waiting states — preserves the pre-
            // refactor "green halo ring" cue that tells the user a
            // background session is waiting on them.
            if showsWaitingHalo {
                Circle()
                    .stroke(Color.green.opacity(0.55), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }

            // Spinning arc overlay while a run is live. Sits between the
            // plate fill and the identity glyph so the chevron/arrow/dot
            // remains visually centered while the ring conveys motion.
            if runState == .running {
                AgentRowRunningIndicator(tint: runningAccentColor)
                    .allowsHitTesting(false)
            }

            // Foreground glyph — identity for normal states, attention
            // glyph when an unseen background transition demands it.
            plateGlyph
        }
        .frame(width: 16, height: 16)
        .overlay(alignment: .bottomTrailing) {
            worktreeMarker
        }
        .hoverTooltip(plateTooltip)
        .accessibilityLabel(plateAccessibilityLabel)
    }

    /// Compact bound-worktree marker overlaid on the status plate's
    /// bottom-right corner. Purely decorative for hit-testing so it never
    /// blocks the disclosure chevron, and layout-neutral so the title's
    /// leading X stays a pure function of `threadDepth`. Its identity is
    /// folded into `plateTooltip` / `plateAccessibilityLabel`.
    @ViewBuilder
    private var worktreeMarker: some View {
        if let worktree {
            worktreeMarkerShape(for: worktree)
                .frame(width: 7, height: 7)
                .padding(1.3)
                .background(
                    Circle().fill(Color(NSColor.controlBackgroundColor))
                )
                .offset(x: 2.5, y: 2.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Marker geometry. Available worktrees use the persisted marker style
    /// (filled dot for dot/capsule, hollow ring for ring); missing worktrees
    /// always render a muted dashed ring so a stale binding reads as such.
    @ViewBuilder
    private func worktreeMarkerShape(for worktree: AgentWorktreeIndicator) -> some View {
        if !worktree.isAvailable {
            Circle()
                .strokeBorder(
                    Color.secondary,
                    style: StrokeStyle(lineWidth: 1.3, dash: [1.6, 1.4])
                )
        } else if worktree.markerStyle == .ring {
            Circle()
                .strokeBorder(worktree.color, lineWidth: 1.7)
        } else {
            Circle()
                .fill(worktree.color)
                .overlay(
                    Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                )
        }
    }

    /// Tint used for the running arc and the running plate fill. Orange
    /// for MCP-controlled root rows so the running cue rhymes with the
    /// rest of the MCP indicators; default accent everywhere else.
    private var runningAccentColor: Color {
        isMCPControlledRoot ? Self.mcpAccentColor : Color.accentColor
    }

    /// Background tint that encodes the row's effective run state. Kept
    /// at low alpha so the plate reads as a tint, not a loud chip.
    private var plateFillColor: Color {
        switch effectiveStatusState {
        case .running:
            // No disc behind the running arc — the rotating arc reads cleanly
            // on its own and the faint accent fill clashed with the centered
            // dot. Keep the plate transparent so only the arc + glyph show.
            .clear
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            Color.green.opacity(isUnseenAttention ? 0.22 : 0.15)
        case .completed:
            isUnseenAttention ? Color.green.opacity(0.18) : .clear
        case .failed:
            Color.red.opacity(isUnseenAttention ? 0.18 : 0.12)
        case .cancelled, .idle:
            .clear
        }
    }

    /// True only for unseen-attention waiting states — the one case where
    /// we still want a crisp stroke ring, because the user needs to
    /// notice that a backgrounded session is waiting on them.
    private var showsWaitingHalo: Bool {
        guard isUnseenAttention else { return false }
        switch effectiveStatusState {
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            return true
        default:
            return false
        }
    }

    /// Foreground glyph inside the plate. Attention states (unseen
    /// completed / unseen failed) get a dedicated state glyph; everything
    /// else falls back to the row's identity glyph (chevron / arrow /
    /// anchor dot).
    @ViewBuilder
    private var plateGlyph: some View {
        let state = effectiveStatusState

        if isUnseenAttention, state == .completed {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.green)
                .accessibilityLabel("Completed in background")
        } else if isUnseenAttention, state == .failed {
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.red)
                .accessibilityLabel("Failed in background")
        } else if showsDisclosureChevron, let onToggleThreadCollapse {
            // Expandable thread identity glyph — tappable disclosure affordance.
            // Nested expandable rows reuse this status slot instead of drawing
            // a second leading sub-agent arrow; leaf children keep the arrow.
            // MCP-controlled roots tint the chevron orange when idle so the
            // row still signals "opened by an MCP client" without needing a
            // dedicated leading rail.
            let chevronColor: Color = {
                if isDisclosureHovered { return .accentColor }
                return isMCPControlledRoot ? Self.mcpAccentColor : .secondary
            }()
            Button {
                onToggleThreadCollapse()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(chevronColor)
                    .rotationEffect(.degrees(isThreadCollapsed ? 0 : 90))
                    .animation(.easeInOut(duration: 0.15), value: isThreadCollapsed)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isDisclosureHovered = $0 }
            .hoverTooltip(disclosureAccessibilityLabel)
            .accessibilityLabel(disclosureAccessibilityLabel)
        } else if threadDepth > 0 {
            // Leaf sub-agent identity glyph.
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.55))
                .accessibilityHidden(true)
        } else if isMCPControlledRoot {
            // MCP-controlled leaf root — keeps the existing anchor-dot
            // design but recolors it orange and bumps the size a hair so
            // it reads as a deliberate "this chat came from an MCP client"
            // marker instead of a generic idle dot.
            Circle()
                .fill(Self.mcpAccentColor.opacity((isHovered || isActive) ? 0.95 : 0.8))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        } else {
            // Leaf root anchor dot — reacts with hover/active to rhyme
            // with the row's outline highlight. While the row is running the
            // dot also adopts the running accent (blue / MCP-orange) at full
            // opacity so the spinner reads with contrast against the arc.
            let isRunningRow = runState == .running
            let dotColor: Color = isRunningRow
                ? runningAccentColor
                : Color.secondary
            let dotOpacity: Double = {
                if isRunningRow { return 1.0 }
                return (isHovered || isActive) ? 0.55 : 0.22
            }()
            Circle()
                .fill(dotColor.opacity(dotOpacity))
                .frame(width: 3, height: 3)
                .accessibilityHidden(true)
        }
    }

    /// Tooltip for the plate. Combines the run-state / MCP status portion
    /// (`statusPlateTooltip`) with the bound-worktree identity line so a
    /// single hover surfaces both. Either portion may be absent.
    private var plateTooltip: String? {
        let status = statusPlateTooltip
        guard let worktreeTooltip = worktree?.tooltipText else { return status }
        guard let status else { return worktreeTooltip }
        return status + "\n" + worktreeTooltip
    }

    /// Run-state / MCP portion of the plate tooltip, before worktree identity
    /// is folded in. Expandable roots rely on the chevron button's own
    /// tooltip, so this stays nil there to avoid two competing bubbles.
    private var statusPlateTooltip: String? {
        if showsDisclosureChevron { return nil }

        let state = effectiveStatusState
        let stateTooltip: String? = switch state {
        case .running:
            "Running"
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            waitingTooltip(for: state, unseen: isUnseenAttention)
        case .completed:
            isUnseenAttention
                ? "Completed in background — select or dismiss to clear"
                : nil
        case .failed:
            isUnseenAttention
                ? "Failed in background — select or dismiss to clear"
                : "Last run failed"
        case .cancelled, .idle:
            nil
        }

        switch (stateTooltip, isMCPControlledRoot) {
        case (let tip?, true):
            return tip + " — MCP Controlled"
        case (nil, true):
            return "MCP Controlled"
        case (let tip, false):
            return tip
        }
    }

    /// Accessibility companion to `plateTooltip`. Always returns a
    /// non-empty label for MCP-controlled roots so VoiceOver still
    /// announces the affordance after the rail was removed.
    private var plateAccessibilityLabel: String {
        if let tip = plateTooltip { return tip }
        return isMCPControlledRoot ? "MCP controlled" : ""
    }

    private func commandProgressIndicator(
        for kind: AgentSidebarBulkActionKind
    ) -> some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
            .allowsHitTesting(false)
            .accessibilityLabel(kind.rowProgressAccessibilityLabel)
    }

    private func waitingTooltip(
        for state: AgentSessionRunState,
        unseen: Bool
    ) -> String {
        let base = switch state {
        case .waitingForApproval:
            "Waiting for approval"
        case .waitingForQuestion:
            "Waiting for your answer"
        default:
            "Waiting for your input"
        }
        return unseen ? base + " — select or dismiss to clear" : base
    }
}

struct AgentStashedSessionRow: View {
    let stashed: StashedTab
    var createdByLabel: String?
    var onOpenCreator: (() -> Void)?
    var isSelected = false
    var showsSelectionPresentation = false
    var isInteractionEnabled = true
    var tapRowID: UUID?
    var tapSelectionCount = 0
    var tapWorkspaceMatched = false
    var commandProgressKind: AgentSidebarBulkActionKind?
    let onSelectionGesture: (AgentSidebarSelectionGesture) -> AgentSidebarSelectionGestureResult
    let onRestore: () -> Void
    let onDelete: () -> Void
    let sessionIDCopyAction: AgentSidebarSessionIDCopyAction

    @State private var isHovered = false
    @State private var isRestoreHovered = false
    @State private var isDeleteHovered = false

    // MARK: - Context Menu Snapshot

    /// Snapshot of conditions controlling context menu item visibility, captured
    /// on hover to prevent NSRangeException from AppKit measuring stale item counts.
    private struct ContextMenuSnapshot {
        var isInteractionEnabled: Bool
        var showsSelectionPresentation: Bool
    }

    @State private var menuSnapshot = ContextMenuSnapshot(
        isInteractionEnabled: true,
        showsSelectionPresentation: false
    )

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var rowMinHeight: CGFloat {
        fontPreset.scaledClamped(30, min: 30, max: 40)
    }

    private var rowHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var rowVerticalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var rowCornerRadius: CGFloat {
        fontPreset.scaledClamped(16, max: 20)
    }

    private var rowSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var titlePinSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var titleVStackSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var leadingIconSize: CGFloat {
        fontPreset.scaledClamped(12, max: 15)
    }

    private var pinIconSize: CGFloat {
        fontPreset.scaledClamped(10, max: 13)
    }

    private var allowsDirectMutations: Bool {
        isInteractionEnabled && !showsSelectionPresentation
    }

    private var restoreActionLabel: String {
        "Restore tab"
    }

    private var deleteActionLabel: String {
        "Delete stashed tab"
    }

    private func handleRowTap() {
        AgentSidebarRowTap.handle(
            isInteractionEnabled: isInteractionEnabled,
            tapRowID: tapRowID,
            tapSelectionCount: tapSelectionCount,
            tapWorkspaceMatched: tapWorkspaceMatched,
            onSelectionGesture: onSelectionGesture,
            onActivate: onRestore
        )
    }

    private func toggleSelection() {
        guard isInteractionEnabled else { return }
        _ = onSelectionGesture(.toggle)
    }

    var body: some View {
        HStack(spacing: rowSpacing) {
            if showsSelectionPresentation {
                Button(action: toggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-6) // Keep the row layout unchanged around the larger hit target.
                .disabled(!isInteractionEnabled)
                .accessibilityLabel("\(isSelected ? "Deselect" : "Select") \(stashed.tab.name)")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }

            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: leadingIconSize))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: titleVStackSpacing) {
                HStack(spacing: titlePinSpacing) {
                    Text(stashed.tab.name)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let createdByLabel {
                        // Archived lanes have no live endpoint, so the provenance mark is a plain
                        // navigation button rather than a lane-menu opener.
                        let tooltip = AgentOversightUICopy.createdByUnlinkedTooltip(
                            creator: createdByLabel
                        )
                        Button(action: { onOpenCreator?() }) {
                            Image(systemName: AgentOversightUICopy.relationshipMarkIcon)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange.opacity(0.45))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverTooltip(tooltip)
                        .accessibilityLabel(tooltip)
                    }
                    if stashed.tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: pinIconSize))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let commandProgressKind {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                    .allowsHitTesting(false)
                    .accessibilityLabel(commandProgressKind.rowProgressAccessibilityLabel)
            } else if isHovered, allowsDirectMutations {
                Button(action: onRestore) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 11))
                        .foregroundColor(isRestoreHovered ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isRestoreHovered = $0 }
                .hoverTooltip(restoreActionLabel)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(isDeleteHovered ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isDeleteHovered = $0 }
                .hoverTooltip(deleteActionLabel)
            }
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, rowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                } else if isHovered {
                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .stroke(Color(NSColor.systemGray).opacity(0.4), lineWidth: 1)
                }
            }
        )
        .contentShape(Rectangle())
        .contextMenu {
            if !menuSnapshot.showsSelectionPresentation {
                if menuSnapshot.isInteractionEnabled {
                    Button("Select chat", action: toggleSelection)
                    Divider()
                    Button(restoreActionLabel, action: onRestore)
                }
                Button(AgentSidebarSessionIDCopyAction.menuTitle) {
                    sessionIDCopyAction.perform()
                }
                .disabled(!sessionIDCopyAction.isEnabled)
                if menuSnapshot.isInteractionEnabled {
                    Divider()
                    Button(deleteActionLabel, role: .destructive, action: onDelete)
                }
            }
        }
        .onHover { hovered in
            isHovered = hovered
            if hovered {
                menuSnapshot = ContextMenuSnapshot(
                    isInteractionEnabled: isInteractionEnabled,
                    showsSelectionPresentation: showsSelectionPresentation
                )
            }
        }
        .onTapGesture(perform: handleRowTap)
        .focusable()
        .onKeyPress(.space) {
            toggleSelection()
            return .handled
        }
        .accessibilityLabel("\(stashed.tab.name), archived session")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAction(named: Text(isSelected ? "Deselect chat" : "Select chat"), toggleSelection)
    }
}

// MARK: - Agent Row Activity Arc

/// A compact, calm rotating arc used in place of the native `ProgressView`
/// inside the Agent Mode sidebar row's status slot.
///
/// Design goals:
/// - Match the 14pt status slot so titles stay aligned whether the row shows
///   a spinner, a waiting dot, a failed dot, or nothing at all.
/// - Rhyme with the circle-based waiting/failed dots (they all share the same
///   geometric vocabulary).
/// - Read as "actively processing" without competing with the green waiting
///   dot — running is informational, waiting is actionable, so running
///   should not out-shout it.
struct AgentRowActivityArc: View {
    var tint: Color = .accentColor

    var body: some View {
        // Render-server rotation: no per-frame SwiftUI render, window layout, or commit on main.
        AgentRowAnimatedActivityArc(tint: tint)
            .frame(width: AgentRowActivityArcLayerView.diameter, height: AgentRowActivityArcLayerView.diameter)
            .accessibilityElement()
            .accessibilityLabel(AgentRowRunningIndicator.accessibilityLabelText)
    }
}

/// The arc's geometry and accessibility, shared by the animated and still presentations so
/// swapping between them never changes the row's layout or what VoiceOver announces.
private struct AgentRowActivityArcShape: View {
    var tint: Color

    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.7)
            .stroke(
                tint.opacity(0.75),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
            .frame(width: 15, height: 15)
            .accessibilityLabel(AgentRowRunningIndicator.accessibilityLabelText)
    }
}

/// Whether a running row's arc may animate.
///
/// The arc animates only while its window is presented on screen and Reduce Motion is off. A hidden
/// window keeps no animation at all (so other commits never have to walk one), and Reduce Motion asks
/// for none. Otherwise the row shows the same arc standing still: running stays visible and
/// labelled, it just stops spinning.
enum AgentRowActivityIndicatorMode: Equatable {
    case animated
    case still

    static func resolve(isWindowPresentationVisible: Bool, reduceMotion: Bool) -> Self {
        isWindowPresentationVisible && !reduceMotion ? .animated : .still
    }
}

/// The running row's status glyph. Switching modes swaps the view, so the animated arc's layer
/// animation is installed again whenever the window becomes visible.
struct AgentRowRunningIndicator: View {
    static let accessibilityLabelText = "Running"

    var tint: Color = .accentColor
    /// Nil reads the process Reduce Motion setting. Tests pin it so the hosted
    /// indicator does not depend on the runner's accessibility preferences.
    var reduceMotionOverride: Bool?

    init(tint: Color = .accentColor, reduceMotionOverride: Bool? = nil) {
        self.tint = tint
        self.reduceMotionOverride = reduceMotionOverride
    }

    @Environment(\.windowIsPresentationVisible) private var isWindowPresentationVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch AgentRowActivityIndicatorMode.resolve(
            isWindowPresentationVisible: isWindowPresentationVisible,
            reduceMotion: reduceMotionOverride ?? reduceMotion
        ) {
        case .animated:
            AgentRowActivityArc(tint: tint)
        case .still:
            AgentRowActivityArcShape(tint: tint)
        }
    }
}

// MARK: - Agent Kind Extensions

extension AgentProviderKind {
    // displayName is defined in AgentRuntimeProviderService.swift

    var iconName: String {
        switch self {
        case .codexExec: "terminal"
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible: "cpu"
        case .openCode, .antigravity: "curlybraces.square"
        case .cursor: "cursorarrow"
        case .grokBuild: "bolt.circle.fill"
        case .devin: "terminal.fill"
        }
    }
}
