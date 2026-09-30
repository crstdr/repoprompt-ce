import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// The default managed grant and the still-valid restricted internal grant use the same exact-link
/// authority. Changing the creation default must not promote an existing in-memory lease.
final class DomainAgentSessionLinkManagementTests: XCTestCase {
    private enum FixtureError: Error {
        case reservationFailed
        case activationFailed
    }

    private func makeAuthority() -> DomainAgentSessionLinkAuthority {
        DomainAgentSessionLinkAuthority(
            identity: DomainRuntimeIdentity(
                runtimeID: UUID(),
                lifecycleGeneration: 1,
                processID: 1,
                mode: .app,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            now: { Date(timeIntervalSince1970: 1000) }
        )
    }

    private func makeEndpoint(windowID: Int) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: windowID,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        )
    }

    private func activateLink(
        _ authority: DomainAgentSessionLinkAuthority,
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity,
        restrictedCapabilities: Set<DomainAgentSessionLinkCapability>? = nil
    ) async throws -> DomainAgentSessionLinkGrant {
        let disposition: DomainAgentSessionLinkReservationDisposition = if let restrictedCapabilities {
            await authority.reserveLink(
                observer: observer,
                target: target,
                capabilities: restrictedCapabilities
            )
        } else {
            await authority.reserveLink(observer: observer, target: target)
        }
        guard case let .reserved(pending, _) = disposition else { throw FixtureError.reservationFailed }
        let activation = await authority.activateLink(
            reservation: pending,
            initialSnapshot: DomainAgentSessionObservationSnapshot(
                sessionID: target.sessionID,
                displayName: "Target",
                providerDisplayName: "Codex CLI",
                status: .running,
                board: .empty,
                idleForSend: false,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: nil,
                visibleRowCount: 1,
                lastActivityAt: Date(timeIntervalSince1970: 500)
            ),
            sourcePublicationSequence: 1
        )
        guard case let .activated(activated) = activation else { throw FixtureError.activationFailed }
        return activated.grant
    }

    func testAtomicObservationBatchSeparatesManagedAndRestrictedGrantsAndDeniesRevocation() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let managedTarget = makeEndpoint(windowID: 2)
        let restrictedTarget = makeEndpoint(windowID: 3)
        _ = try await activateLink(authority, observer: observer, target: managedTarget)
        let restricted = try await activateLink(
            authority, observer: observer, target: restrictedTarget,
            restrictedCapabilities: DomainAgentSessionLinkCapability.version1
        )
        let managedLease = try await authority.authorize(
            operation: .monitorPoll, observerEndpoint: observer,
            targetSessionID: managedTarget.sessionID
        ).get()
        let restrictedLease = try await authority.authorize(
            operation: .monitorPoll, observerEndpoint: observer,
            targetSessionID: restrictedTarget.sessionID
        ).get()
        let before = await authority.managedObservationTargetsIfValid(
            leases: [managedLease, restrictedLease]
        )
        XCTAssertEqual(before, [managedTarget.sessionID])
        _ = await authority.revoke(
            linkID: restricted.id, generation: restricted.generation, reason: .userRequested
        )
        let after = await authority.managedObservationTargetsIfValid(
            leases: [managedLease, restrictedLease]
        )
        XCTAssertNil(after, "one revoked member must withhold the managed sibling's prompt")
    }

    func testSetModelOriginalManageLeaseCannotSurviveRevokeRelinkOrAuthorizeWatchOnly() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorSetModel, observerEndpoint: observer, targetSessionID: target.sessionID
        ).get()
        XCTAssertEqual(DomainAgentSessionTargetOperation.monitorSetModel.family, .monitor)
        XCTAssertFalse(DomainAgentSessionTargetOperation.monitorSetModel.isObserverScoped)
        XCTAssertTrue(DomainAgentSessionTargetOperation.monitorSetModel.mutatesTarget)
        let initial = await authority.validate(lease: lease)
        XCTAssertNil(initial)
        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .userRequested)
        _ = try await activateLink(
            authority,
            observer: observer,
            target: target,
            restrictedCapabilities: DomainAgentSessionLinkCapability.version1
        )
        let stale = await authority.validate(lease: lease)
        XCTAssertNotNil(stale)
        let restricted = await authority.authorize(
            operation: .monitorSetModel, observerEndpoint: observer, targetSessionID: target.sessionID
        )
        XCTAssertEqual(restricted, .failure(.capabilityDenied))
    }

    func testNewGrantsStartManagedAndKeepWatchOperationsAvailable() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)

        XCTAssertEqual(grant.capabilities, DomainAgentSessionLinkCapability.managed)
        for operation in [DomainAgentSessionTargetOperation.monitorRespond, .monitorSteer, .monitorSetModel] {
            let lease = try await authority.authorize(
                operation: operation,
                observerEndpoint: observer,
                targetSessionID: target.sessionID
            ).get()
            XCTAssertEqual(lease.capability, .manage, operation.rawValue)
        }
        let compact = try await authority.authorize(
            operation: .monitorCompact,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        XCTAssertEqual(compact.capability, .sendWhenIdle, "compact remains watch-level")
        let inventory = await authority.links(forObserverEndpoint: observer)
        XCTAssertEqual(inventory.items.first?.capabilityNames, ["manage", "poll", "read", "send_when_idle", "wait"])
    }

    func testRestrictedExistingGrantDoesNotUpgradeWhenDefaultReservationFindsIt() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(
            authority,
            observer: observer,
            target: target,
            restrictedCapabilities: DomainAgentSessionLinkCapability.version1
        )
        XCTAssertEqual(grant.capabilities, DomainAgentSessionLinkCapability.version1)
        let denied = await authority.authorize(
            operation: .monitorRespond,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        )
        guard case let .failure(denial) = denied else { return XCTFail("Restricted grant authorized respond") }
        XCTAssertEqual(denial, .capabilityDenied)
        let compact = try await authority.authorize(
            operation: .monitorCompact,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        XCTAssertEqual(compact.capability, .sendWhenIdle)

        let repeated = await authority.reserveLink(observer: observer, target: target)
        guard case let .existing(existing) = repeated else { return XCTFail("Expected existing grant") }
        XCTAssertEqual(existing.id, grant.id)
        XCTAssertEqual(existing.capabilities, DomainAgentSessionLinkCapability.version1, "no live upgrade of an existing lease")
    }

    func testManagedAuthorityRequiresExactObserverAndFreshGeneration() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let otherObserver = makeEndpoint(windowID: 3)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)
        let lease = try await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let foreign = await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: otherObserver,
            targetSessionID: target.sessionID
        )
        guard case .failure = foreign else {
            return XCTFail("UUID knowledge is not an exact direct grant")
        }

        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .userRequested)
        let revokedLeaseError = await authority.validate(lease: lease)
        XCTAssertNotNil(revokedLeaseError, "revocation invalidates issued leases")
        let replacement = try await activateLink(authority, observer: observer, target: target)
        XCTAssertNotEqual(replacement.id, grant.id)
        XCTAssertEqual(replacement.capabilities, DomainAgentSessionLinkCapability.managed, "a new generation receives the new default")
        let staleLeaseError = await authority.validate(lease: lease)
        XCTAssertNotNil(staleLeaseError, "a stale generation cannot resurrect")
    }
}
