import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class AgentSidebarOversightMenuModelsTests: XCTestCase {
    private struct Linked {
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        let linkID: UUID
        let generation: UInt64
    }

    private func id(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private func candidate(
        windowID: Int,
        workspaceID: UUID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        tabID: UUID = UUID(),
        sessionID: UUID = UUID(),
        bindingID: UUID? = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        transitionGeneration: UInt64 = 1,
        isTopLevel: Bool = true,
        hasLoadedPersistedState: Bool = true,
        bindingTransitionInProgress: Bool = false,
        isClosing: Bool = false,
        isMCPControlled: Bool = false,
        isMCPOriginated: Bool = false,
        roleAllowsOutboundMonitoring: Bool = true,
        displayName: String? = "Agent",
        providerDisplayName: String? = "Codex CLI",
        locationLabel: String? = nil,
        isDeletionInProgress: Bool = false
    ) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: bindingID,
            bindingTransitionGeneration: transitionGeneration,
            isTopLevel: isTopLevel,
            hasLoadedPersistedState: hasLoadedPersistedState,
            bindingTransitionInProgress: bindingTransitionInProgress,
            isClosing: isClosing,
            isMCPControlled: isMCPControlled,
            isMCPOriginated: isMCPOriginated,
            roleAllowsOutboundMonitoring: roleAllowsOutboundMonitoring,
            displayName: displayName,
            providerDisplayName: providerDisplayName,
            locationLabel: locationLabel,
            isDeletionInProgress: isDeletionInProgress
        )
    }

    /// Builds projection inputs for a row. `linked` are inbound (the row is the target);
    /// `linkedTargets` are outbound (the row is the observer).
    private func inputs(
        target: AgentSessionLinkEndpointCandidate,
        linked: [Linked] = [],
        linkedTargets: [Linked] = [],
        activeOutboundObserverEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
    ) -> DomainAgentSessionLinkEndpointProjectionInputs {
        let inboundItems = linked.map { relationship in
            DomainAgentSessionLinkInventoryItem(
                linkID: relationship.linkID,
                generation: relationship.generation,
                observerSessionID: relationship.endpoint.sessionID,
                targetSessionID: target.sessionID,
                displayName: nil,
                capabilities: DomainAgentSessionLinkCapability.version1
            )
        }
        let outboundItems = linkedTargets.map { relationship in
            DomainAgentSessionLinkInventoryItem(
                linkID: relationship.linkID,
                generation: relationship.generation,
                observerSessionID: target.sessionID,
                targetSessionID: relationship.endpoint.sessionID,
                displayName: nil,
                capabilities: DomainAgentSessionLinkCapability.version1
            )
        }
        return DomainAgentSessionLinkEndpointProjectionInputs(
            outbound: DomainAgentSessionLinkInventory(
                sessionID: target.sessionID,
                linkSetRevision: UInt64(linkedTargets.count),
                authorityRevision: 1,
                items: outboundItems
            ),
            inbound: DomainAgentSessionLinkInventory(
                sessionID: target.sessionID,
                linkSetRevision: UInt64(linked.count),
                authorityRevision: 1,
                items: inboundItems
            ),
            outboundTargetEndpoints: Dictionary(
                uniqueKeysWithValues: linkedTargets.map { ($0.linkID, $0.endpoint) }
            ),
            inboundObserverEndpoints: Dictionary(
                uniqueKeysWithValues: linked.map { ($0.linkID, $0.endpoint) }
            ),
            activeOutboundObserverEndpoints: activeOutboundObserverEndpoints,
            notices: []
        )
    }

    func testProjectionPartitionsAvailableAndRetainsUnavailableAndIneligibleLinkedObservers() {
        let target = candidate(windowID: 10, displayName: "Target")
        let ineligibleLinked = candidate(
            windowID: 2,
            roleAllowsOutboundMonitoring: false,
            displayName: "Éclair"
        )
        let unavailableEndpoint = candidate(
            windowID: 3,
            sessionID: id("F0000000-0000-0000-0000-000000000003"),
            displayName: "Gone"
        ).domainEndpoint
        let available = candidate(windowID: 4, displayName: "alpha", providerDisplayName: "   ")
        let linked = [
            Linked(endpoint: unavailableEndpoint, linkID: UUID(), generation: 7),
            Linked(endpoint: ineligibleLinked.domainEndpoint, linkID: UUID(), generation: 2)
        ]

        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: linked,
                activeOutboundObserverEndpoints: Set(
                    linked.map(\.endpoint) + [available.domainEndpoint]
                )
            ),
            candidates: [available, target, ineligibleLinked]
        )

        XCTAssertEqual(menu.targetEndpoint, target.domainEndpoint)
        XCTAssertEqual(menu.targetSessionID, target.sessionID)
        XCTAssertEqual(menu.targetDisplayName, "Target")
        XCTAssertEqual(menu.linkedObservers.map(\.displayName), ["Éclair", AgentMonitorSessionIDFormatter.short(
            unavailableEndpoint.sessionID
        )])
        XCTAssertEqual(menu.availableObservers.map(\.peerEndpoint), [available.domainEndpoint])
        XCTAssertNil(menu.availableObservers.first?.providerDisplayName)
        XCTAssertEqual(
            menu.inboundObserverNames,
            [AgentMonitorSessionIDFormatter.short(unavailableEndpoint.sessionID), "Éclair"]
        )
        XCTAssertFalse(menu.isEmpty)

        guard case let .linked(ineligibleReference, ineligibleEligible) = menu.linkedObservers[0].relationship,
              case let .linked(goneReference, goneEligible) = menu.linkedObservers[1].relationship
        else {
            return XCTFail("expected linked relationship options")
        }
        XCTAssertFalse(ineligibleEligible)
        XCTAssertFalse(goneEligible)
        XCTAssertEqual(ineligibleReference.generation, 2)
        XCTAssertEqual(goneReference.generation, 7)
        XCTAssertTrue(menu.linkedObservers[1].fullIdentityDescription.contains(unavailableEndpoint.tabID.uuidString))
    }

    func testAvailableProjectionRequiresActiveOverseerAndExcludesIneligibleSelfAndLinkedEndpoints() {
        let target = candidate(windowID: 10, displayName: "Target")
        let linked = candidate(windowID: 2, displayName: "Linked")
        let eligibleOverseer = candidate(windowID: 3, displayName: "Eligible overseer")
        let ordinaryEligibleLane = candidate(windowID: 4, displayName: "Ordinary eligible lane")
        let sameSessionIncarnation = candidate(
            windowID: 5,
            sessionID: target.sessionID,
            displayName: "Target duplicate"
        )
        let ineligible = [
            candidate(windowID: 6, isTopLevel: false, displayName: "Child"),
            candidate(windowID: 7, isMCPControlled: true, displayName: "Controlled"),
            candidate(windowID: 8, isMCPOriginated: true, displayName: "Originated"),
            candidate(windowID: 9, roleAllowsOutboundMonitoring: false, displayName: "Denied"),
            candidate(windowID: 11, hasLoadedPersistedState: false, displayName: "Loading")
        ]
        let relationship = Linked(endpoint: linked.domainEndpoint, linkID: UUID(), generation: 1)
        let activeOverseers = [sameSessionIncarnation, linked, eligibleOverseer] + ineligible

        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: [relationship],
                activeOutboundObserverEndpoints: Set(activeOverseers.map(\.domainEndpoint))
            ),
            candidates: [
                target,
                sameSessionIncarnation,
                linked,
                eligibleOverseer,
                ordinaryEligibleLane
            ] + ineligible
        )

        XCTAssertEqual(menu.linkedObservers.map(\.peerEndpoint), [linked.domainEndpoint])
        XCTAssertEqual(menu.availableObservers.map(\.peerEndpoint), [eligibleOverseer.domainEndpoint])
    }

    /// Ordering contract: the row's own workspace cohort first, then folded name — flat across
    /// linked and available observers in the inbound list.
    func testInboundListOrdersOwnWorkspaceFirstThenName() {
        let ownWorkspace = id("10000000-0000-0000-0000-000000000001")
        let otherWorkspace = id("20000000-0000-0000-0000-000000000002")
        let target = candidate(windowID: 10, workspaceID: ownWorkspace, displayName: "Target")
        // In the row's workspace but sorts last by name; a linked observer elsewhere sorts first
        // among the other-workspace group but still after every same-workspace option.
        let linkedRemote = candidate(
            windowID: 2,
            workspaceID: otherWorkspace,
            displayName: "AAA linked remote"
        )
        let availableLocal = candidate(windowID: 3, workspaceID: ownWorkspace, displayName: "Zeta local")
        let availableRemote = candidate(
            windowID: 4,
            workspaceID: otherWorkspace,
            displayName: "BBB remote"
        )
        let relationship = Linked(endpoint: linkedRemote.domainEndpoint, linkID: UUID(), generation: 3)

        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: [relationship],
                activeOutboundObserverEndpoints: [
                    linkedRemote.domainEndpoint,
                    availableLocal.domainEndpoint,
                    availableRemote.domainEndpoint
                ]
            ),
            candidates: [target, linkedRemote, availableLocal, availableRemote]
        )

        XCTAssertEqual(
            menu.observerOptions.map(\.displayName),
            ["Zeta local", "AAA linked remote", "BBB remote"]
        )
        guard case .linked = menu.observerOptions[1].relationship else {
            return XCTFail("expected the remote option to stay linked after sorting")
        }
    }

    /// The inverse list keeps ticked (linked) targets first, then applies the same
    /// own-workspace/name ordering inside each group.
    func testOutboundListKeepsLinkedFirstThenWorkspaceThenName() {
        let ownWorkspace = id("10000000-0000-0000-0000-000000000001")
        let otherWorkspace = id("20000000-0000-0000-0000-000000000002")
        let observer = candidate(windowID: 10, workspaceID: ownWorkspace, displayName: "Observer")
        let linkedRemote = candidate(
            windowID: 2,
            workspaceID: otherWorkspace,
            displayName: "Linked target"
        )
        let availableLocal = candidate(windowID: 3, workspaceID: ownWorkspace, displayName: "Alpha local")
        let selfSession = candidate(windowID: 5, sessionID: observer.sessionID, displayName: "Self")
        let ineligibleTarget = candidate(
            windowID: 6,
            hasLoadedPersistedState: false,
            displayName: "Loading target"
        )
        let relationship = Linked(endpoint: linkedRemote.domainEndpoint, linkID: UUID(), generation: 9)

        let menu = AgentSidebarOversightMenuProjection.make(
            target: observer,
            inputs: inputs(target: observer, linkedTargets: [relationship]),
            candidates: [observer, linkedRemote, availableLocal, selfSession, ineligibleTarget]
        )

        XCTAssertEqual(
            menu.targetOptions.map(\.peerEndpoint),
            [linkedRemote.domainEndpoint, availableLocal.domainEndpoint]
        )
        XCTAssertTrue(menu.isOverseer)
        XCTAssertEqual(menu.outboundTargetNames, ["Linked target"])
        XCTAssertNil(menu.observerIneligibleReason)
    }

    /// An ineligible target keeps its menu with a greyed reason and retains linked observers for
    /// unlinking; an ineligible observer gets the inverse reason and an empty available list.
    func testIneligibleDirectionsSurfaceReasonsInsteadOfHidingMenus() {
        let loadingRow = candidate(
            windowID: 1,
            hasLoadedPersistedState: false,
            displayName: "Loading row"
        )
        let overseer = candidate(windowID: 2, displayName: "Overseer")
        let linked = Linked(endpoint: overseer.domainEndpoint, linkID: UUID(), generation: 4)

        let menu = AgentSidebarOversightMenuProjection.make(
            target: loadingRow,
            inputs: inputs(target: loadingRow, linked: [linked]),
            candidates: [loadingRow, overseer]
        )

        XCTAssertEqual(
            menu.targetIneligibleReason,
            AgentSessionLinkResolveFailure.loading.uiMessage
        )
        XCTAssertTrue(menu.availableObservers.isEmpty)
        // The linked observer stays reachable so the relationship remains unlinkable.
        XCTAssertEqual(menu.linkedObservers.map(\.peerEndpoint), [overseer.domainEndpoint])
        XCTAssertEqual(menu.inboundObserverNames, ["Overseer"])
        XCTAssertTrue(menu.hasInbound)
        // The same row cannot observe while still loading, either.
        XCTAssertEqual(
            menu.observerIneligibleReason,
            AgentSessionLinkEndpointEligibility.addDisabledReason(
                loadingRow.eligibilityInput,
                roleAllowsOutboundMonitoring: loadingRow.roleAllowsOutboundMonitoring
            )
        )
        XCTAssertTrue(menu.targetOptions.isEmpty)
    }

    func testCreatorBadgeCopyMovedToTheUnifiedCopyOwner() {
        XCTAssertEqual(AgentOversightUICopy.relationshipMarkIcon, "rectangle.connected.to.line.below")
        XCTAssertEqual(
            AgentOversightUICopy.createdByUnlinkedTooltip(creator: "RepoPrompt PM"),
            "Created by: RepoPrompt PM (unlinked)"
        )
        XCTAssertEqual(
            AgentOversightUICopy.createdAndOverseenTooltip(creator: "RepoPrompt PM"),
            "Created and overseen by: RepoPrompt PM"
        )
        XCTAssertEqual(
            AgentOversightUICopy.createdByOverseenByTooltip(
                creator: "RepoPrompt PM",
                observerNames: ["RepoPrompt PM", "Second"]
            ),
            "Created by: RepoPrompt PM; overseen by: RepoPrompt PM, Second"
        )
    }

    func testCreatorLabelSurvivesAnEmptyUnlinkedMenuWithoutChangingEligibility() {
        let target = candidate(windowID: 1, isMCPControlled: false, isMCPOriginated: false)
        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(target: target),
            candidates: [target],
            createdByLabel: "Overseer",
            creatorSessionID: UUID()
        )
        XCTAssertTrue(menu.isEmpty)
        XCTAssertFalse(menu.hasInbound)
        XCTAssertEqual(menu.createdByLabel, "Overseer")
        XCTAssertNotNil(menu.creatorSessionID)
        XCTAssertNil(AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(target: target),
            candidates: [target]
        ).createdByLabel)
        XCTAssertFalse(target.isMCPControlled)
    }

    func testMenuLabelsPrefixLiveObserverLocationAndFallBackWhenUnavailable() {
        let target = candidate(windowID: 10, displayName: "Target")
        let linked = candidate(
            windowID: 2,
            displayName: "Existing overseer",
            locationLabel: "release-main"
        )
        let available = candidate(
            windowID: 3,
            displayName: "Coordinate PIN-boundary design review",
            locationLabel: " kidfriendly-nova "
        )
        let unavailableEndpoint = candidate(
            windowID: 4,
            sessionID: id("F0000000-0000-0000-0000-000000000004"),
            displayName: "Unavailable"
        ).domainEndpoint
        let relationships = [
            Linked(endpoint: linked.domainEndpoint, linkID: UUID(), generation: 1),
            Linked(endpoint: unavailableEndpoint, linkID: UUID(), generation: 2)
        ]

        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                linked: relationships,
                activeOutboundObserverEndpoints: [linked.domainEndpoint, available.domainEndpoint]
            ),
            candidates: [target, linked, available]
        )

        XCTAssertEqual(
            menu.linkedObservers.first { $0.peerEndpoint == linked.domainEndpoint }?.menuLabel,
            "release-main: Existing overseer"
        )
        XCTAssertEqual(
            menu.availableObservers.first?.menuLabel,
            "kidfriendly-nova: Coordinate PIN-boundary design review"
        )
        XCTAssertEqual(
            menu.linkedObservers.first { $0.peerEndpoint == unavailableEndpoint }?.menuLabel,
            AgentMonitorSessionIDFormatter.short(unavailableEndpoint.sessionID)
        )
    }

    func testUnlinkVoiceOverLabelQuotesThePeerName() {
        let observer = "release-main: Existing overseer"
        XCTAssertEqual(
            AgentOversightUICopy.unlinkAccessibilityLabel(observer),
            "Unlink \"release-main: Existing overseer\""
        )
    }

    func testTooltipNameListsCapAtThreeWithPlusNMore() {
        XCTAssertEqual(
            AgentOversightUICopy.overseeingTooltip(targetNames: ["A"]),
            "Overseeing: A"
        )
        XCTAssertEqual(
            AgentOversightUICopy.overseenByTooltip(observerNames: ["A", "B", "C"]),
            "Overseen by: A, B, C"
        )
        XCTAssertEqual(
            AgentOversightUICopy.overseenByTooltip(observerNames: ["A", "B", "C", "D", "E"]),
            "Overseen by: A, B, C +2 more"
        )
    }

    func testConfirmationCopyMatchesTheApprovedGrantShape() {
        XCTAssertEqual(
            AgentOversightUICopy.confirmationTitle(observer: "Overseer", target: "Lane"),
            "Allow \"Overseer\" to oversee \"Lane\"?"
        )
        let body = AgentOversightUICopy.confirmationBody(observer: "Overseer", target: "Lane")
        XCTAssertTrue(body.contains("“Overseer” will be able to:"))
        XCTAssertTrue(body.contains("read Lane’s status and conversation"))
        XCTAssertTrue(body.contains("send it instructions, steer it and stop its current run"))
        XCTAssertTrue(body.contains("answer its questions and one-time approval requests"))
        XCTAssertTrue(body.contains("compact its context, and be woken up by its updates"))
        XCTAssertTrue(body.contains("You can unlink anytime."))
        XCTAssertEqual(AgentOversightUICopy.confirmationSuppressionCheckbox, "Don’t ask again")
        XCTAssertEqual(AgentOversightUICopy.confirmationAllowButton, "Allow oversight")
    }

    /// Approved 2026-09-30 copy decisions for the Session-ID sheets and stale/menu strings.
    func testSheetAndStaleCopyMatchesApproval() {
        XCTAssertEqual(
            AgentOversightUICopy.sessionIDSheetTitle(observer: "Lane A"),
            "Choose a session for \"Lane A\" to oversee"
        )
        XCTAssertEqual(
            AgentOversightUICopy.inboundSessionIDSheetTitle(session: "Lane A"),
            "Choose an overseer for \"Lane A\""
        )
        XCTAssertEqual(AgentOversightUICopy.addOverseerButton, "Add overseer")
        XCTAssertEqual(AgentOversightUICopy.overseeSessionButton, "Oversee session")
        XCTAssertEqual(AgentOversightUICopy.staleSelectionMessage, "Sessions changed. Please choose again.")
        XCTAssertEqual(
            AgentOversightUICopy.overseeMenuAccessibilityValue(overseeingCount: 2, availableCount: 3),
            "Overseeing 2; 3 available"
        )
        XCTAssertEqual(
            AgentOversightUICopy.overseeByMenuAccessibilityValue(overseenByCount: 1, availableCount: 4),
            "Overseen by 1; 4 available"
        )
    }

    func testCollisionLabelsWidenThroughSessionWindowTabAndFullExactIdentity() throws {
        let target = candidate(windowID: 99, displayName: "Target")
        let sessionA = id("AAAA0000-0000-0000-0000-00000000AAAA")
        let sessionB = id("BBBB0000-0000-0000-0000-00000000BBBB")
        let sharedTab = id("CCCC0000-0000-0000-0000-00000000CCCC")
        let otherTab = id("DDDD0000-0000-0000-0000-00000000DDDD")
        let first = candidate(windowID: 1, sessionID: sessionA, displayName: "Duplicate")
        let differentSession = candidate(windowID: 2, sessionID: sessionB, displayName: "Duplicate")
        let sameSession = candidate(windowID: 3, sessionID: sessionA, displayName: "Duplicate")
        let sameWindowFirstTab = candidate(
            windowID: 4,
            tabID: sharedTab,
            sessionID: sessionA,
            displayName: "Duplicate"
        )
        let sameWindowOtherTab = candidate(
            windowID: 4,
            tabID: otherTab,
            sessionID: sessionA,
            displayName: "Duplicate"
        )
        let pathological = candidate(
            windowID: 4,
            workspaceID: id("EEEE0000-0000-0000-0000-00000000EEEE"),
            tabID: sharedTab,
            sessionID: sessionA,
            bindingID: id("FFFF0000-0000-0000-0000-00000000FFFF"),
            transitionGeneration: 8,
            displayName: "Duplicate"
        )
        let unique = candidate(windowID: 5, displayName: "Unique")
        let candidates = [
            target,
            first,
            differentSession,
            sameSession,
            sameWindowFirstTab,
            sameWindowOtherTab,
            pathological,
            unique
        ]

        let menu = AgentSidebarOversightMenuProjection.make(
            target: target,
            inputs: inputs(
                target: target,
                activeOutboundObserverEndpoints: Set(candidates.map(\.domainEndpoint))
            ),
            candidates: candidates
        )
        let byEndpoint = Dictionary(
            uniqueKeysWithValues: menu.availableObservers.map { ($0.peerEndpoint, $0) }
        )

        XCTAssertEqual(byEndpoint[unique.domainEndpoint]?.menuLabel, "Unique")
        XCTAssertTrue(try XCTUnwrap(byEndpoint[first.domainEndpoint]?.menuLabel).contains("AAAA…AAAA"))
        XCTAssertTrue(try XCTUnwrap(byEndpoint[differentSession.domainEndpoint]?.menuLabel).contains("BBBB…BBBB"))
        XCTAssertTrue(try XCTUnwrap(byEndpoint[sameSession.domainEndpoint]?.menuLabel).contains("window 3"))
        XCTAssertTrue(try XCTUnwrap(byEndpoint[sameWindowOtherTab.domainEndpoint]?.menuLabel).contains("tab DDDD…DDDD"))
        let full = try XCTUnwrap(byEndpoint[pathological.domainEndpoint]?.menuLabel)
        XCTAssertTrue(full.contains(pathological.workspaceID.uuidString))
        XCTAssertTrue(try full.contains(XCTUnwrap(pathological.persistentBindingGeneration?.uuidString)))
        XCTAssertEqual(Set(menu.availableObservers.map(\.menuLabel)).count, menu.availableObservers.count)
    }

    func testCreatorNavigationRequiresOneLiveMatchingRoute() {
        let creatorID = UUID()
        let route = AgentSessionDeepLinkRoute(
            workspaceID: UUID(), tabID: UUID(), sessionID: creatorID
        )
        XCTAssertNil(AgentSidebarCreatorNavigation.uniqueRoute(for: creatorID, candidates: []))
        XCTAssertEqual(
            AgentSidebarCreatorNavigation.uniqueRoute(for: creatorID, candidates: [route]), route
        )
        let sameTabInAnotherWindow = AgentSessionDeepLinkRoute(
            windowID: 2, workspaceID: route.workspaceID, tabID: route.tabID, sessionID: creatorID
        )
        XCTAssertEqual(AgentSidebarCreatorNavigation.uniqueRoute(
            for: creatorID, candidates: [route, sameTabInAnotherWindow]
        ), route)
        let differentTab = AgentSessionDeepLinkRoute(
            workspaceID: route.workspaceID, tabID: UUID(), sessionID: creatorID
        )
        XCTAssertNil(AgentSidebarCreatorNavigation.uniqueRoute(
            for: creatorID, candidates: [route, differentTab]
        ))
        XCTAssertNil(AgentSidebarCreatorNavigation.uniqueRoute(
            for: UUID(), candidates: [route]
        ))
    }

    func testActionKeysAreExactEndpointAndGenerationQualified() {
        let observer = candidate(windowID: 1).domainEndpoint
        let target = candidate(windowID: 2).domainEndpoint
        let linkID = UUID()
        let reboundObserver = DomainAgentSessionLinkEndpointIdentity(
            windowID: observer.windowID,
            workspaceID: observer.workspaceID,
            tabID: observer.tabID,
            sessionID: observer.sessionID,
            persistentBindingGeneration: observer.persistentBindingGeneration,
            bindingTransitionGeneration: observer.bindingTransitionGeneration + 1
        )
        XCTAssertNotEqual(
            AgentSidebarOversightActionKey.add(observerEndpoint: observer, targetEndpoint: target),
            .add(observerEndpoint: reboundObserver, targetEndpoint: target)
        )
        XCTAssertNotEqual(
            AgentSidebarOversightActionKey.unlink(
                observerEndpoint: observer,
                targetEndpoint: target,
                reference: DomainAgentSessionLinkReference(linkID: linkID, generation: 1)
            ),
            .unlink(
                observerEndpoint: observer,
                targetEndpoint: target,
                reference: DomainAgentSessionLinkReference(linkID: linkID, generation: 2)
            )
        )
    }
}
