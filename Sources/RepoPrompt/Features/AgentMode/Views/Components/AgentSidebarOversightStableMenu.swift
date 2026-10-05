import Foundation
import RepoPromptDomainRuntime

extension AgentSessionRow {
    /// Action wiring for one native (`StableMenuButton`) oversight menu presentation. The
    /// closures forward to the row's own handlers, which re-resolve current props and
    /// revalidate exact endpoints at click time — a frozen item tree is safe because every
    /// mutation is authority-checked when it fires, not when the menu opened.
    struct AgentSidebarOversightMenuActions {
        var openLinkedSession: (DomainAgentSessionLinkEndpointIdentity) -> Void = { _ in }
        var openCreator: (() -> Void)?
        var addInbound: (AgentSidebarOversightMenuProps.ObserverOption) -> Void = { _ in }
        var addOutbound: (AgentSidebarOversightMenuProps.TargetOption) -> Void = { _ in }
        var unlink: (
            _ observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
            _ targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
            _ reference: DomainAgentSessionLinkReference
        ) -> Void = { _, _, _ in }
        var presentChooseTargetSheet: () -> Void = {}
        var presentChooseOverseerSheet: () -> Void = {}
    }

    /// The immutable item tree the native (`StableMenuButton`) oversight presentations —
    /// mark click and hover affordance — build once per activation. The retained NSMenu then
    /// owns it for the presentation's lifetime, so sidebar invalidations cannot repopulate
    /// the open menu the way a re-rendered SwiftUI `Menu`'s content can (and did: cross-window
    /// projection publishes collapsed the menu mid-browse). Both available-session pickers share
    /// the same pure project grouping policy.
    static func sidebarOversightMenuItems(
        _ menu: AgentSidebarOversightMenuProps,
        busyKeys: Set<AgentSidebarOversightActionKey>,
        actions: AgentSidebarOversightMenuActions
    ) -> [StableMenuItem] {
        let availableTargets = menu.availableTargets
        let availableObservers = menu.availableObservers
        let hasLinkedSections = !menu.linkedTargets.isEmpty || !menu.linkedObservers.isEmpty
        let hasTopSections = hasLinkedSections || menu.showsCreatedBySection

        func jumpItem(_ option: AgentSidebarOversightMenuProps.PeerOption) -> StableMenuItem {
            .action(
                option.menuLabel,
                imageSystemName: AgentOversightUICopy.jumpItemIcon,
                accessibilityHint: AgentOversightUICopy.openHint(option.menuLabel)
            ) {
                actions.openLinkedSession(option.peerEndpoint)
            }
        }

        func availableItems(
            _ options: [AgentSidebarOversightMenuProps.PeerOption],
            item: (AgentSidebarOversightMenuProps.PeerOption) -> StableMenuItem
        ) -> [StableMenuItem] {
            guard let projects = AgentSidebarOversightPickerPresentation.projects(for: options) else {
                return options.map(item)
            }
            return projects.map { project in
                .submenu(project.title, items: project.options.map(item))
            }
        }

        var items: [StableMenuItem] = []

        if !hasTopSections {
            items.append(.header(AgentOversightUICopy.oversightMenuHeader))
        }

        if !menu.linkedTargets.isEmpty {
            items.append(.header(AgentOversightUICopy.overseeingSectionLabel))
            items += menu.linkedTargets.map(jumpItem)
        }
        if !menu.linkedObservers.isEmpty {
            items.append(.header(
                menu.creatorIsSoleOverseer
                    ? AgentOversightUICopy.createdAndOverseenBySectionLabel
                    : AgentOversightUICopy.overseenBySectionLabel
            ))
            items += menu.linkedObservers.map(jumpItem)
        }
        if menu.showsCreatedBySection, let creatorLabel = menu.createdByLabel {
            items.append(.header(AgentOversightUICopy.createdBySectionLabel))
            items.append(.action(
                creatorLabel,
                imageSystemName: AgentOversightUICopy.jumpItemIcon,
                accessibilityHint: AgentOversightUICopy.openHint(creatorLabel)
            ) {
                actions.openCreator?()
            })
        }

        if hasTopSections {
            items.append(.separator)
        }

        var overseeNewItems: [StableMenuItem] = []
        if let reason = menu.observerIneligibleReason {
            overseeNewItems.append(.message(reason))
        }
        if availableTargets.isEmpty, menu.observerIneligibleReason == nil {
            overseeNewItems.append(.message(AgentOversightUICopy.noSessionsToOversee))
        } else {
            overseeNewItems += availableItems(availableTargets) { option in
                let busy = busyKeys.contains(.add(
                    observerEndpoint: menu.targetEndpoint,
                    targetEndpoint: option.peerEndpoint
                ))
                return .action(
                    option.menuLabel,
                    isEnabled: !busy && menu.observerIneligibleReason == nil,
                    imageSystemName: busy ? "hourglass" : nil,
                    accessibilityLabel: option.menuLabel,
                    accessibilityValue: busy ? "In progress" : nil,
                    accessibilityHint: option.fullIdentityDescription
                ) {
                    actions.addOutbound(option)
                }
            }
        }
        overseeNewItems.append(.separator)
        overseeNewItems.append(.action(
            AgentOversightUICopy.sessionIDMenuItem,
            isEnabled: menu.observerIneligibleReason == nil
        ) {
            actions.presentChooseTargetSheet()
        })
        items.append(.submenu(
            AgentOversightUICopy.overseeNewTitle,
            accessibilityLabel: AgentOversightUICopy.overseeNewTitle,
            accessibilityValue: AgentOversightUICopy.overseeMenuAccessibilityValue(
                overseeingCount: menu.linkedTargets.count,
                availableCount: availableTargets.count
            ),
            items: overseeNewItems
        ))

        var overseeByItems: [StableMenuItem] = []
        if let reason = menu.targetIneligibleReason {
            overseeByItems.append(.message(reason))
        }
        if availableObservers.isEmpty, menu.targetIneligibleReason == nil {
            overseeByItems.append(.message(AgentOversightUICopy.noEligibleOverseers))
        } else {
            overseeByItems += availableItems(availableObservers) { option in
                let busy = busyKeys.contains(.add(
                    observerEndpoint: option.peerEndpoint,
                    targetEndpoint: menu.targetEndpoint
                ))
                return .action(
                    option.menuLabel,
                    isEnabled: !busy,
                    imageSystemName: busy ? "hourglass" : nil,
                    accessibilityLabel: option.menuLabel,
                    accessibilityValue: busy ? "In progress" : nil,
                    accessibilityHint: option.fullIdentityDescription
                ) {
                    actions.addInbound(option)
                }
            }
        }
        overseeByItems.append(.separator)
        overseeByItems.append(.action(
            AgentOversightUICopy.sessionIDMenuItem,
            isEnabled: menu.targetIneligibleReason == nil
        ) {
            actions.presentChooseOverseerSheet()
        })
        items.append(.submenu(
            AgentOversightUICopy.overseeByTitle,
            accessibilityLabel: AgentOversightUICopy.overseeByTitle,
            accessibilityValue: AgentOversightUICopy.overseeByMenuAccessibilityValue(
                overseenByCount: menu.linkedObservers.count,
                availableCount: availableObservers.count
            ),
            items: overseeByItems
        ))

        if hasLinkedSections {
            var unlinkItems: [StableMenuItem] = []
            if !menu.linkedTargets.isEmpty {
                unlinkItems.append(.header(AgentOversightUICopy.overseeingSectionLabel))
                unlinkItems += menu.linkedTargets.compactMap { option in
                    guard case let .linked(reference, _) = option.relationship else { return nil }
                    let busy = busyKeys.contains(.unlink(
                        observerEndpoint: menu.targetEndpoint,
                        targetEndpoint: option.peerEndpoint,
                        reference: reference
                    ))
                    return .action(
                        option.menuLabel,
                        isEnabled: !busy,
                        imageSystemName: busy ? "hourglass" : nil,
                        accessibilityLabel: AgentOversightUICopy.unlinkAccessibilityLabel(option.menuLabel),
                        accessibilityValue: busy ? "In progress" : nil,
                        accessibilityHint: option.fullIdentityDescription
                    ) {
                        actions.unlink(menu.targetEndpoint, option.peerEndpoint, reference)
                    }
                }
            }
            if !menu.linkedObservers.isEmpty {
                unlinkItems.append(.header(AgentOversightUICopy.overseenBySectionLabel))
                unlinkItems += menu.linkedObservers.compactMap { option in
                    guard case let .linked(reference, _) = option.relationship else { return nil }
                    let busy = busyKeys.contains(.unlink(
                        observerEndpoint: option.peerEndpoint,
                        targetEndpoint: menu.targetEndpoint,
                        reference: reference
                    ))
                    return .action(
                        option.menuLabel,
                        isEnabled: !busy,
                        imageSystemName: busy ? "hourglass" : nil,
                        accessibilityLabel: AgentOversightUICopy.unlinkAccessibilityLabel(option.menuLabel),
                        accessibilityValue: busy ? "In progress" : nil,
                        accessibilityHint: option.fullIdentityDescription
                    ) {
                        actions.unlink(option.peerEndpoint, menu.targetEndpoint, reference)
                    }
                }
            }
            items.append(.submenu(
                AgentOversightUICopy.unlinkTitle,
                accessibilityLabel: AgentOversightUICopy.unlinkTitle,
                accessibilityValue: AgentOversightUICopy.unlinkMenuAccessibilityValue(
                    linkCount: menu.linkedTargets.count + menu.linkedObservers.count
                ),
                items: unlinkItems
            ))
        }

        return items
    }
}
