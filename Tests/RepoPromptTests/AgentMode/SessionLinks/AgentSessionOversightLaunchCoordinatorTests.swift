import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Bounded, reason-aware automatic reauthorization of the launch snapshot.
///
/// The contracts pinned here are the ones a wrong implementation gets *silently* wrong: reserving
/// before a barrier, leaving a saved pair dormant because its background tab was never opened,
/// deleting a saved link because a window that was abandoned rather than observed did not come back,
/// requeueing an entry after the user watched oversight end, and dropping the user's saved
/// management / auto-approval delegation across a relaunch.
@MainActor
final class AgentSessionOversightLaunchCoordinatorTests: XCTestCase {
    // MARK: - Fake host

    /// Endpoint host with a full window topology: descriptors, discovery levels, and a restore
    /// topology reason. The focused bridge tests elsewhere rely on the protocol defaults instead.
    private final class FakeHost: AgentSessionLinkEndpointHost {
        var candidates: [AgentSessionLinkEndpointCandidate] = []
        /// Drift only after the coordinator's descriptor-backed classification snapshot. Bootstrap
        /// presentation reads candidates too, so a raw call index is not an establishment boundary.
        var candidatesAfterClassification: [AgentSessionLinkEndpointCandidate]?
        private var classificationSnapshotPending = false
        private(set) var classificationHandoffCount = 0
        var descriptors: [AgentSessionLinkComposeTabDescriptor] = []
        var discovery: [AgentSessionLinkDiscoveryState] = []
        var topology: AgentSessionOversightRestoreTopologyState = .completeAllEntriesConsumed
        private(set) var publishedPresentations: [AgentSessionOversightPersistencePresentation] = []
        var laneCreatorByEndpoint: [DomainAgentSessionLinkEndpointIdentity: UUID] = [:]
        private(set) var providerTaskRequests = 0

        func agentSessionLinkLaneProvenance(for endpoint: DomainAgentSessionLinkEndpointIdentity) -> UUID? {
            laneCreatorByEndpoint[endpoint]
        }

        private(set) var hydrationRequests: [Set<UUID>] = []
        var hydrationHandler: ((Set<UUID>) -> Void)?

        func agentSessionLinkRequestRestorationHydration(sessionIDs: Set<UUID>) {
            hydrationRequests.append(sessionIDs)
            hydrationHandler?(sessionIDs)
        }

        func agentSessionLinkCandidates() -> [AgentSessionLinkEndpointCandidate] {
            let snapshot = candidates
            if classificationSnapshotPending, let successor = candidatesAfterClassification {
                classificationSnapshotPending = false
                candidatesAfterClassification = nil
                classificationHandoffCount += 1
                candidates = successor
            }
            return snapshot
        }

        func agentSessionLinkComposeTabDescriptors() -> [AgentSessionLinkComposeTabDescriptor] {
            classificationSnapshotPending = candidatesAfterClassification != nil
            return descriptors
        }

        func agentSessionLinkDiscoveryStates() -> [AgentSessionLinkDiscoveryState] {
            discovery
        }

        func agentSessionLinkRestoreTopologyState() -> AgentSessionOversightRestoreTopologyState {
            topology
        }

        func agentSessionLinkPublishPersistencePresentation(
            _ presentation: AgentSessionOversightPersistencePresentation
        ) {
            publishedPresentations.append(presentation)
        }

        func agentSessionLinkObservationSnapshot(
            for candidate: AgentSessionLinkEndpointCandidate
        ) -> DomainAgentSessionObservationSnapshot {
            DomainAgentSessionObservationSnapshot(
                sessionID: candidate.sessionID,
                displayName: candidate.displayName,
                providerDisplayName: candidate.providerDisplayName,
                status: .idle,
                board: .empty,
                idleForSend: true,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: nil,
                visibleRowCount: 0,
                lastActivityAt: Date(timeIntervalSince1970: 100)
            )
        }

        func agentSessionLinkStatusProjection(
            for _: AgentSessionLinkEndpointCandidate
        ) -> AgentSessionLinkStatusProjection? {
            AgentSessionLinkStatusProjection(status: .idle, pendingInteractionKind: nil)
        }

        func agentSessionLinkInstallObservation(
            for _: AgentSessionLinkEndpointCandidate,
            onChange _: @escaping @MainActor () -> Void
        ) -> AgentSessionLinkObservationToken? {
            AgentSessionLinkObservationToken {}
        }

        func agentSessionLinkPublishProjection(
            _: AgentMonitorPillProps,
            to _: DomainAgentSessionLinkEndpointIdentity
        ) {}

        func agentSessionLinkPublishPromptInventory(
            _: AgentSessionLinkPromptInventory,
            to _: DomainAgentSessionLinkEndpointIdentity
        ) {}

        func agentSessionLinkPublishPassiveStatusNotices(
            _: AgentSessionLinkPassiveStatusNotices.Snapshot,
            to _: DomainAgentSessionLinkEndpointIdentity
        ) {}

        func agentSessionLinkWithholdPromptInventory(
            for _: DomainAgentSessionLinkEndpointIdentity
        ) -> UInt64? {
            nil
        }

        func agentSessionLinkReleasePromptInventoryHold(
            _: UInt64?,
            for _: DomainAgentSessionLinkEndpointIdentity,
            publishing _: AgentSessionLinkPromptInventory?
        ) {}

        func agentSessionLinkTranscriptPage(
            for _: AgentSessionLinkEndpointCandidate,
            anchor _: AgentSessionLinkTranscriptAnchor?,
            direction _: AgentSessionLinkReadDirectionInput,
            maxItems _: Int,
            maxOutputBytes _: Int,
            readerSessionID _: UUID?
        ) async -> Result<AgentSessionLinkTranscriptPage, AgentSessionLinkReadUnavailableReason> {
            .failure(.endpointInvalidated)
        }

        func agentSessionLinkSendLiveness(
            observer _: DomainAgentSessionLinkEndpointIdentity,
            target _: DomainAgentSessionLinkEndpointIdentity
        ) -> AgentSessionLinkSendLiveness {
            .unavailable
        }

        func agentSessionLinkPerformSend(
            to _: AgentSessionLinkEndpointCandidate,
            request _: AgentSessionLinkSendRequest,
            liveness _: @escaping AgentSessionLinkSendLivenessProbe,
            commitAuthorization _: @MainActor () async -> AgentSessionLinkSendCommitOutcome
        ) async -> AgentSessionLinkSendTransactionOutcome {
            providerTaskRequests += 1
            return .blocked(.shuttingDown)
        }

        func agentSessionLinkPerformCompact(
            to _: AgentSessionLinkEndpointCandidate,
            request _: AgentSessionLinkCompactRequest,
            liveness _: @escaping AgentSessionLinkSendLivenessProbe,
            commitAuthorization _: @MainActor () async -> AgentSessionLinkSendCommitOutcome
        ) async -> AgentSessionLinkSendTransactionOutcome {
            .blocked(.endpointInvalidated)
        }
    }

    private final class WriteGate: @unchecked Sendable {
        private let lock = NSLock()
        private var shouldFail = false

        var failsNextWrites: Bool {
            get { lock.withLock { shouldFail } }
            set { lock.withLock { shouldFail = newValue } }
        }

        func write(_ data: Data, to url: URL) throws {
            if failsNextWrites { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Fixture

    private var directory: URL!
    private var observerSessionID = UUID()
    private var targetSessionID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oversight-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        observerSessionID = UUID()
        targetSessionID = UUID()
        AgentSessionDeletionRegistry.shared.test_reset()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        AgentSessionDeletionRegistry.shared.test_reset()
        try super.tearDownWithError()
    }

    private var pair: AgentSessionOversightIntent {
        AgentSessionOversightIntent(
            observerSessionID: observerSessionID,
            targetSessionID: targetSessionID
        )
    }

    /// Seeds the durable manifest so the launch load produces exactly this one saved pair.
    private func seedSavedPair(_ additionalPairs: [AgentSessionOversightIntent] = []) throws {
        let document = AgentSessionOversightIntentDocument(links: [pair] + additionalPairs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(
            to: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename),
            options: .atomic
        )
    }

    /// A live, eligible candidate whose hydration proof matches its own current binding, which is
    /// the only shape automatic restoration accepts.
    private func makeReadyCandidate(
        windowID: Int, sessionID: UUID, workspaceID: UUID = UUID()
    ) -> AgentSessionLinkEndpointCandidate {
        let tabID = UUID()
        return AgentSessionLinkEndpointCandidate(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            isTopLevel: true,
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: false,
            isMCPControlled: false,
            isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true,
            displayName: "Session \(windowID)",
            providerDisplayName: "Codex CLI",
            locationLabel: "worktree/main",
            restorationReadiness: .authoritative(
                AgentSessionRestorationBindingToken(
                    bindingIdentity: AgentPersistentSessionBindingIdentity(
                        tabID: tabID,
                        sessionID: sessionID
                    ),
                    bindingTransitionGeneration: 1
                ),
                .persistedPayloadApplied
            )
        )
    }

    /// The same live incarnation with a different hydration proof.
    ///
    /// Byte-for-byte identical endpoint identity is the whole point: the resolver cannot tell these
    /// apart, because it gates on the legacy `hasLoadedPersistedState` latch, which stays `true`.
    private func withReadiness(
        _ candidate: AgentSessionLinkEndpointCandidate,
        _ readiness: AgentSessionRestorationReadiness
    ) -> AgentSessionLinkEndpointCandidate {
        var copy = candidate
        copy.restorationReadiness = readiness
        return copy
    }

    private func descriptor(for candidate: AgentSessionLinkEndpointCandidate) -> AgentSessionLinkComposeTabDescriptor {
        AgentSessionLinkComposeTabDescriptor(
            windowID: candidate.windowID,
            workspaceID: candidate.workspaceID,
            tabID: candidate.tabID,
            sessionID: candidate.sessionID
        )
    }

    private struct Fixture {
        let bridge: AgentSessionLinkRuntimeBridge
        let authority: DomainAgentSessionLinkAuthority
        let host: FakeHost
        let store: AgentSessionOversightIntentStore
        let gate: WriteGate
    }

    private func makeFixture(mode: AgentSessionOversightPersistenceMode = .enabled) -> Fixture {
        let authority = DomainAgentSessionLinkAuthority(
            identity: DomainRuntimeIdentity(
                runtimeID: UUID(),
                lifecycleGeneration: 1,
                processID: 1,
                mode: .app,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            now: { Date(timeIntervalSince1970: 1000) }
        )
        let host = FakeHost()
        host.discovery = [
            AgentSessionLinkDiscoveryState(
                epoch: AgentSessionLinkDiscoveryEpoch(windowID: 1, workspaceID: UUID(), generation: 1),
                isComplete: true
            )
        ]
        let gate = WriteGate()
        let store = AgentSessionOversightIntentStore(
            fileURL: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename),
            backupsDirectoryURL: directory.appendingPathComponent("Backups", isDirectory: true),
            mode: mode,
            writer: { data, url in try gate.write(data, to: url) }
        )
        let bridge = AgentSessionLinkRuntimeBridge(
            authority: authority,
            host: host,
            toolAdvertisementInvalidator: { _ in }
        )
        return Fixture(bridge: bridge, authority: authority, host: host, store: store, gate: gate)
    }

    private func isRestored(_ fixture: Fixture) async -> Bool {
        let inventory = await fixture.authority.links(forObserver: observerSessionID)
        return inventory.items.contains { $0.targetSessionID == targetSessionID }
    }

    private func makeRestoredFixture() async throws -> (
        Fixture, AgentSessionLinkEndpointCandidate, AgentSessionLinkEndpointCandidate
    ) {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        return (fixture, observer, target)
    }

    private func liveReference(_ fixture: Fixture) async -> DomainAgentSessionLinkReference? {
        let inventory = await fixture.authority.links(forObserver: observerSessionID)
        guard let item = inventory.items.first(where: { $0.targetSessionID == targetSessionID }) else { return nil }
        return DomainAgentSessionLinkReference(linkID: item.linkID, generation: item.generation)
    }

    private func replaceTopology(_ fixture: Fixture, with candidates: [AgentSessionLinkEndpointCandidate]) {
        fixture.host.candidates = candidates
        fixture.host.descriptors = candidates.map { descriptor(for: $0) }
    }

    func testThreeHundredChatsRestoreTenLinksAcrossReopenAndRestartWithinBudget() async throws {
        var ids = (0 ..< 300).map { _ in UUID() }
        ids[0] = observerSessionID
        ids[1] = targetSessionID
        let workspaceIDs = (0 ..< 3).map { _ in UUID() }
        let pairs = (0 ..< 10).map { index in
            AgentSessionOversightIntent(
                observerSessionID: ids[(index % 3) * 100],
                targetSessionID: ids[1 + index * 29]
            )
        }
        try seedSavedPair(Array(pairs.dropFirst()))
        let linkedIDs = Set(pairs.flatMap { [$0.observerSessionID, $0.targetSessionID] })
        let clock = ContinuousClock()
        let budget: Duration = .seconds(5)

        func candidates(firstWindowID: Int) -> [AgentSessionLinkEndpointCandidate] {
            ids.enumerated().map { index, id in
                makeReadyCandidate(
                    windowID: firstWindowID + index / 100,
                    sessionID: id, workspaceID: workspaceIDs[index / 100]
                )
            }
        }

        func installColdTopology(_ fixture: Fixture, _ ready: [AgentSessionLinkEndpointCandidate]) {
            fixture.host.candidates = []
            fixture.host.descriptors = ready.map { descriptor(for: $0) }
            fixture.host.discovery = (0 ..< 3).map { index in
                .init(epoch: .init(
                    windowID: ready[index * 100].windowID,
                    workspaceID: workspaceIDs[index],
                    generation: 1
                ), isComplete: true)
            }
            fixture.host.hydrationHandler = { requested in
                fixture.host.candidates += ready.filter { candidate in
                    requested.contains(candidate.sessionID)
                        && !fixture.host.candidates.contains(where: { $0.sessionID == candidate.sessionID })
                }
                fixture.bridge.noteCandidateReadinessChanged()
            }
        }

        func assertLinks(_ fixture: Fixture) async -> [AgentSessionOversightIntent: DomainAgentSessionLinkReference] {
            var references: [AgentSessionOversightIntent: DomainAgentSessionLinkReference] = [:]
            for observerID in Set(pairs.map(\.observerSessionID)) {
                let inventory = await fixture.authority.links(forObserver: observerID)
                let expected = pairs.filter { $0.observerSessionID == observerID }
                XCTAssertEqual(Set(inventory.items.map(\.targetSessionID)), Set(expected.map(\.targetSessionID)))
                for item in inventory.items {
                    XCTAssertEqual(item.capabilities, DomainAgentSessionLinkCapability.managed)
                    references[.init(observerSessionID: observerID, targetSessionID: item.targetSessionID)] =
                        .init(linkID: item.linkID, generation: item.generation)
                }
            }
            XCTAssertEqual(references.count, 10)
            XCTAssertEqual(fixture.host.providerTaskRequests, 0)
            return references
        }

        let fixture = makeFixture()
        installColdTopology(fixture, candidates(firstWindowID: 1))
        let launchStart = clock.now
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        let launchTime = launchStart.duration(to: clock.now)
        let original = await assertLinks(fixture)
        XCTAssertEqual(Set(fixture.host.hydrationRequests.flatMap(\.self)), linkedIDs)
        XCTAssertLessThan(launchTime, budget)

        let reopenStart = clock.now
        for windowID in 1 ... 3 {
            fixture.bridge.noteOversightWindowClosing(windowID: windowID)
            fixture.host.candidates.removeAll { $0.windowID == windowID }
            fixture.host.descriptors.removeAll { $0.windowID == windowID }
            fixture.host.discovery.removeAll { $0.epoch.windowID == windowID }
            await fixture.bridge.invalidateWindow(windowID, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
        }
        installColdTopology(fixture, candidates(firstWindowID: 4))
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let reopenTime = reopenStart.duration(to: clock.now)
        let reopened = await assertLinks(fixture)
        for pair in pairs {
            XCTAssertNotEqual(reopened[pair], original[pair])
            let token = await fixture.store.token(for: pair)
            XCTAssertNotNil(token)
        }
        XCTAssertLessThan(reopenTime, budget)
        fixture.host.hydrationHandler = nil

        // Fresh authority, bridge and disk-backed store model process restart, not a reused cache.
        let restarted = makeFixture()
        installColdTopology(restarted, candidates(firstWindowID: 7))
        let restartStart = clock.now
        await restarted.bridge.bootstrapIntentStore(restarted.store)
        await restarted.bridge.test_settleLaunchReconciliation()
        let restartTime = restartStart.duration(to: clock.now)
        let restored = await assertLinks(restarted)
        for pair in pairs {
            XCTAssertNotEqual(restored[pair], reopened[pair])
        }
        XCTAssertEqual(Set(restarted.host.hydrationRequests.flatMap(\.self)), linkedIDs)
        XCTAssertLessThan(restartTime, budget)
        restarted.host.hydrationHandler = nil
        print("RESTORE_SCALE chats=300 windows=3 overseers=3 links=10 launch=\(launchTime) reopen=\(reopenTime) restart=\(restartTime) budget=5s/phase")
    }

    // MARK: - Same-process window reopen

    func testCapturedObserverTargetAndBothWindowClosesRestoreOneFreshManagedGrant() async throws {
        let closingWindows: [Set<Int>] = [[1], [2], [1, 2]]
        for windows in closingWindows {
            let (fixture, observer, target) = try await makeRestoredFixture()
            let originalReference = await liveReference(fixture)
            let oldReference = try XCTUnwrap(originalReference)
            let originalToken = await fixture.store.token(for: pair)
            for windowID in windows {
                fixture.bridge.noteOversightWindowClosing(windowID: windowID)
            }
            replaceTopology(fixture, with: [observer, target].filter { !windows.contains($0.windowID) })
            for windowID in windows {
                await fixture.bridge.invalidateWindow(windowID, reason: .windowClosed)
            }
            await fixture.bridge.test_settleLaunchReconciliation()

            let parkedToken = await fixture.store.token(for: pair)
            let retiredGrant = await fixture.authority.activeGrant(for: oldReference)
            XCTAssertEqual(parkedToken, originalToken)
            XCTAssertNil(retiredGrant)
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.lifecycleRevoked))

            let reopenedObserver = windows.contains(1)
                ? makeReadyCandidate(windowID: 3, sessionID: observerSessionID) : observer
            let reopenedTarget = windows.contains(2)
                ? makeReadyCandidate(windowID: 4, sessionID: targetSessionID) : target
            replaceTopology(fixture, with: [reopenedObserver, reopenedTarget])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let replacement = await liveReference(fixture)
            XCTAssertNotNil(replacement)
            XCTAssertNotEqual(replacement, oldReference)
            let inventory = await fixture.authority.links(forObserverEndpoint: reopenedObserver.domainEndpoint)
            XCTAssertEqual(inventory.items.map(\.targetSessionID), [targetSessionID])
            XCTAssertEqual(inventory.items.first?.capabilities, DomainAgentSessionLinkCapability.managed)
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let repeated = await liveReference(fixture)
            XCTAssertEqual(repeated, replacement, "An ordinary event must not reserve again.")
            XCTAssertEqual(fixture.host.providerTaskRequests, 0)
        }
    }

    func testReferenceBackedInteractivePairEnrollsWithItsActualAssertionOnClose() async {
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        replaceTopology(fixture, with: [observer, target])
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        let added = await fixture.bridge.addMonitorLink(
            observerSessionID: observerSessionID, rawTargetSessionID: targetSessionID.uuidString
        )
        guard case .added = added else { return XCTFail("Expected interactive Add") }
        XCTAssertNil(fixture.bridge.test_launchEntryState(for: pair))
        let assertion = await fixture.store.assertionGeneration(for: pair)
        XCTAssertGreaterThan(assertion, 0)
        let original = await liveReference(fixture)
        fixture.bridge.noteOversightWindowClosing(windowID: 2)
        replaceTopology(fixture, with: [observer])
        await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
        await fixture.bridge.test_settleLaunchReconciliation()
        replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let replacement = await liveReference(fixture)
        XCTAssertNotNil(replacement)
        XCTAssertNotEqual(replacement, original)
        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token)
    }

    func testSuccessfulUnlinkBeforeCloseCannotRestoreOnReopen() async throws {
        let (fixture, observer, target) = try await makeRestoredFixture()
        let originalReference = await liveReference(fixture)
        let reference = try XCTUnwrap(originalReference)
        let stopped = await fixture.bridge.stopMonitorLink(
            observerEndpoint: observer.domainEndpoint, targetEndpoint: target.domainEndpoint,
            expectedReference: reference
        )
        XCTAssertEqual(stopped, .stopped)
        fixture.bridge.noteOversightWindowClosing(windowID: 2)
        replaceTopology(fixture, with: [observer])
        await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
        await fixture.bridge.test_settleLaunchReconciliation()
        replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let restored = await isRestored(fixture)
        let token = await fixture.store.token(for: pair)
        XCTAssertFalse(restored)
        XCTAssertNil(token)
    }

    private enum UnlinkSurface: CaseIterable {
        case exact, legacy, reference
    }

    private func unlink(
        _ fixture: Fixture,
        observer: AgentSessionLinkEndpointCandidate,
        target: AgentSessionLinkEndpointCandidate,
        reference: DomainAgentSessionLinkReference,
        surface: UnlinkSurface
    ) async -> AgentMonitorStopOutcome? {
        switch surface {
        case .exact:
            return await fixture.bridge.stopMonitorLink(
                observerEndpoint: observer.domainEndpoint, targetEndpoint: target.domainEndpoint,
                expectedReference: reference
            )
        case .legacy:
            return await fixture.bridge.stopMonitorLink(
                observerSessionID: observer.sessionID, targetSessionID: target.sessionID,
                linkID: reference.linkID, generation: reference.generation
            )
        case .reference:
            await fixture.bridge.revokeLink(linkID: reference.linkID, generation: reference.generation)
            return nil
        }
    }

    func testUnlinkAdmittedBeforeCloseRetiresItsParkedIntentAfterGrantRemoval() async throws {
        for surface in UnlinkSurface.allCases {
            let (fixture, observer, target) = try await makeRestoredFixture()
            let original = await liveReference(fixture)
            let reference = try XCTUnwrap(original)
            let fence = TestReleaseFence(name: "Unlink admitted before close")
            fixture.bridge.test_afterStopAdmission = { await fence.enterAndWait() }
            let stop = Task { @MainActor in
                await unlink(fixture, observer: observer, target: target, reference: reference, surface: surface)
            }
            await fence.waitUntilEntered()
            fixture.bridge.noteOversightWindowClosing(windowID: 2)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            let retired = await fixture.authority.activeGrant(for: reference)
            let parkedToken = await fixture.store.token(for: pair)
            XCTAssertNil(retired)
            XCTAssertNotNil(parkedToken)
            fixture.bridge.test_afterStopAdmission = nil
            fence.release()
            let outcome = await stop.value
            XCTAssertNil(outcome?.failureMessage)
            let token = await fixture.store.token(for: pair)
            XCTAssertNil(token, "An admitted Unlink must forget its exact parked ownership: \(surface)")
            replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let restored = await isRestored(fixture)
            XCTAssertFalse(restored)
        }
    }

    func testUnlinkFirstInvokedAfterCloseDoesNotCreateSavedOnlyRetirement() async throws {
        for surface in UnlinkSurface.allCases {
            let (fixture, observer, target) = try await makeRestoredFixture()
            let original = await liveReference(fixture)
            let reference = try XCTUnwrap(original)
            let savedToken = await fixture.store.token(for: pair)
            fixture.bridge.noteOversightWindowClosing(windowID: 2)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            _ = await unlink(fixture, observer: observer, target: target, reference: reference, surface: surface)
            let token = await fixture.store.token(for: pair)
            XCTAssertEqual(token, savedToken, "No live/admitted relationship exists to unlink: \(surface)")
            replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let restored = await isRestored(fixture)
            XCTAssertTrue(restored)
        }
    }

    func testSuspendedPreCloseUnlinkCannotRetireReopenedSuccessor() async throws {
        for surface in UnlinkSurface.allCases {
            let (fixture, observer, target) = try await makeRestoredFixture()
            let original = await liveReference(fixture)
            let reference = try XCTUnwrap(original)
            let originalToken = await fixture.store.token(for: pair)
            let fence = TestReleaseFence(name: "old Unlink before successor")
            fixture.bridge.test_afterStopAdmission = { await fence.enterAndWait() }
            let stop = Task { @MainActor in
                await unlink(fixture, observer: observer, target: target, reference: reference, surface: surface)
            }
            await fence.waitUntilEntered()
            fixture.bridge.noteOversightWindowClosing(windowID: 2)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let replacement = await liveReference(fixture)
            XCTAssertNotNil(replacement)
            XCTAssertNotEqual(replacement, reference)
            fixture.bridge.test_afterStopAdmission = nil
            fence.release()
            _ = await stop.value
            let current = await liveReference(fixture)
            let token = await fixture.store.token(for: pair)
            XCTAssertEqual(current, replacement)
            XCTAssertEqual(token, originalToken, "A stale Unlink cannot retire a same-token successor: \(surface)")
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        }
    }

    func testOldAdmittedUnlinkCannotRetireSuccessorThatHasAlsoClosed() async throws {
        for surface in UnlinkSurface.allCases {
            let (fixture, observer, target) = try await makeRestoredFixture()
            let original = await liveReference(fixture)
            let reference = try XCTUnwrap(original)
            let originalToken = await fixture.store.token(for: pair)
            let originalAssertion = await fixture.store.assertionGeneration(for: pair)
            let fence = TestReleaseFence(name: "predecessor Unlink through successor close")
            fixture.bridge.test_afterStopAdmission = { await fence.enterAndWait() }
            let stop = Task { @MainActor in
                await unlink(fixture, observer: observer, target: target, reference: reference, surface: surface)
            }
            await fence.waitUntilEntered()
            fixture.bridge.noteOversightWindowClosing(windowID: 2)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            let reopened = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
            replaceTopology(fixture, with: [observer, reopened])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let replacement = await liveReference(fixture)
            XCTAssertNotNil(replacement)
            XCTAssertNotEqual(replacement, reference)
            let reopenedAssertion = await fixture.store.assertionGeneration(for: pair)
            XCTAssertEqual(reopenedAssertion, originalAssertion, "Automatic relink uses the same assertion.")

            // Park the successor before releasing the original Unlink. Historical membership of
            // the old reference remains, but only the successor's current capture may retire it.
            fixture.bridge.noteOversightWindowClosing(windowID: 3)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(3, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            fixture.bridge.test_afterStopAdmission = nil
            fence.release()
            _ = await stop.value
            let token = await fixture.store.token(for: pair)
            XCTAssertEqual(token, originalToken, "A predecessor Unlink cannot consume the successor's park: \(surface)")
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.lifecycleRevoked))
            replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 4, sessionID: targetSessionID)])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let next = await liveReference(fixture)
            XCTAssertNotNil(next)
            XCTAssertNotEqual(next, replacement)
        }
    }

    func testAdmittedCloseUnlinkCannotCompensateAwayNewerSameTokenAssertion() async throws {
        for surface in UnlinkSurface.allCases {
            let (fixture, observer, target) = try await makeRestoredFixture()
            let original = await liveReference(fixture)
            let reference = try XCTUnwrap(original)
            let originalToken = await fixture.store.token(for: pair)
            let originalAssertion = await fixture.store.assertionGeneration(for: pair)
            let fence = TestReleaseFence(name: "old Unlink before same-token assertion")
            fixture.bridge.test_afterStopAdmission = { await fence.enterAndWait() }
            let stop = Task { @MainActor in
                await unlink(fixture, observer: observer, target: target, reference: reference, surface: surface)
            }
            await fence.waitUntilEntered()
            fixture.bridge.noteOversightWindowClosing(windowID: 2)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            // Model the assertion committing before its interactive notification arrives. The store
            // assertion fence itself must deny this stale retirement, without a compensation retry.
            let reassertion = await fixture.store.insert(pair)
            XCTAssertEqual(reassertion.outcome, .unchanged)
            let assertion = await fixture.store.assertionGeneration(for: pair)
            XCTAssertGreaterThan(assertion, originalAssertion)
            fixture.bridge.test_afterStopAdmission = nil
            fence.release()
            _ = await stop.value
            let token = await fixture.store.token(for: pair)
            XCTAssertEqual(token, originalToken)
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.lifecycleRevoked))
            XCTAssertFalse(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
        }
    }

    func testAdmittedUnlinkCannotRetireSameReferenceReassertedBeforeClose() async throws {
        for surface in UnlinkSurface.allCases {
            let (fixture, observer, target) = try await makeRestoredFixture()
            let original = await liveReference(fixture)
            let reference = try XCTUnwrap(original)
            let originalToken = await fixture.store.token(for: pair)
            let originalAssertion = await fixture.store.assertionGeneration(for: pair)
            let fence = TestReleaseFence(name: "admitted Unlink before successful reassertion")
            fixture.bridge.test_afterStopAdmission = { await fence.enterAndWait() }
            let stop = Task { @MainActor in
                await unlink(fixture, observer: observer, target: target, reference: reference, surface: surface)
            }
            await fence.waitUntilEntered()
            let readded = await fixture.bridge.addMonitorLink(
                observerSessionID: observerSessionID, rawTargetSessionID: targetSessionID.uuidString
            )
            guard case .alreadyLinked = readded else {
                fixture.bridge.test_afterStopAdmission = nil
                fence.release()
                _ = await stop.value
                return XCTFail("Expected same-reference explicit reassertion")
            }
            let assertion = await fixture.store.assertionGeneration(for: pair)
            let reassertedReference = await liveReference(fixture)
            XCTAssertGreaterThan(assertion, originalAssertion)
            XCTAssertEqual(reassertedReference, reference)
            fixture.bridge.noteOversightWindowClosing(windowID: 2)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            fixture.bridge.test_afterStopAdmission = nil
            fence.release()
            _ = await stop.value
            let token = await fixture.store.token(for: pair)
            XCTAssertEqual(token, originalToken)
            replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let restored = await isRestored(fixture)
            XCTAssertTrue(restored, "Only the newer assertion owns this close capture: \(surface)")
        }
    }

    func testRawUnlinkAdmittedBeforeCloseReportsFailedRemovalAndRetriesExactIntent() async throws {
        let (fixture, observer, _) = try await makeRestoredFixture()
        let original = await liveReference(fixture)
        let reference = try XCTUnwrap(original)
        let savedToken = await fixture.store.token(for: pair)
        let fence = TestReleaseFence(name: "raw Unlink before close and failed write")
        fixture.bridge.test_afterStopAdmission = { await fence.enterAndWait() }
        let stop = Task { @MainActor in
            await fixture.bridge.revokeLink(linkID: reference.linkID, generation: reference.generation)
        }
        await fence.waitUntilEntered()
        fixture.bridge.noteOversightWindowClosing(windowID: 2)
        replaceTopology(fixture, with: [observer])
        await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
        await fixture.bridge.test_settleLaunchReconciliation()
        fixture.gate.failsNextWrites = true
        fixture.bridge.test_afterStopAdmission = nil
        fence.release()
        await stop.value
        let afterFailure = await fixture.store.token(for: pair)
        XCTAssertEqual(afterFailure, savedToken)
        XCTAssertTrue(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
        XCTAssertEqual(
            fixture.bridge.currentPersistencePresentation.warnings.map(\.id),
            [AgentSessionOversightWarningID.cleanupFailed]
        )
        let reopened = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
        replaceTopology(fixture, with: [observer, reopened])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let beforeRetry = await isRestored(fixture)
        XCTAssertFalse(beforeRetry, "Explicit Unlink cleanup must not reauthorize on reopen")
        fixture.gate.failsNextWrites = false
        await fixture.bridge.retryPendingIntentCleanup()
        let afterRetry = await fixture.store.token(for: pair)
        XCTAssertNil(afterRetry)
        XCTAssertFalse(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        XCTAssertEqual(fixture.host.providerTaskRequests, 0)
    }

    func testReopenedPendingCandidateRetainsParkingAcrossAnotherClose() async throws {
        for unbound in [false, true] {
            let (fixture, observer, _) = try await makeRestoredFixture()
            let original = await liveReference(fixture)
            let savedToken = await fixture.store.token(for: pair)
            fixture.bridge.noteOversightWindowClosing(windowID: 2)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            let reopened = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
            guard case let .authoritative(bindingToken, _) = reopened.restorationReadiness else {
                return XCTFail("Expected an authoritative fixture")
            }
            let pending = withReadiness(reopened, unbound ? .unbound : .pending(bindingToken))
            replaceTopology(fixture, with: [observer, pending])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID]])
            let beforeClose = await isRestored(fixture)
            XCTAssertFalse(beforeClose)
            fixture.bridge.noteOversightWindowClosing(windowID: 3)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(3, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            let afterClose = await fixture.store.token(for: pair)
            XCTAssertEqual(afterClose, savedToken)
            let final = makeReadyCandidate(windowID: 4, sessionID: targetSessionID)
            fixture.host.descriptors = [descriptor(for: observer), descriptor(for: final)]
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID], [targetSessionID]])
            replaceTopology(fixture, with: [observer, final])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let replacement = await liveReference(fixture)
            XCTAssertNotNil(replacement)
            XCTAssertNotEqual(replacement, original)
            let inventory = await fixture.authority.links(forObserver: observerSessionID)
            XCTAssertEqual(inventory.items.map(\.targetSessionID), [targetSessionID])
            XCTAssertEqual(fixture.host.providerTaskRequests, 0)
        }
    }

    func testSequentialClosesRearmBothPreviouslyHydratedAndReopenedBackgroundTabs() async throws {
        for order in [[1, 2], [2, 1]] {
            try seedSavedPair()
            let fixture = makeFixture()
            let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
            let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
            fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
            await fixture.bridge.bootstrapIntentStore(fixture.store)
            await fixture.bridge.test_settleLaunchReconciliation()
            let bothSessions: Set<UUID> = [observerSessionID, targetSessionID]
            XCTAssertEqual(fixture.host.hydrationRequests, [bothSessions])
            replaceTopology(fixture, with: [observer, target])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let original = await liveReference(fixture)
            XCTAssertNotNil(original)
            for windowID in order {
                fixture.bridge.noteOversightWindowClosing(windowID: windowID)
                let surviving = fixture.host.candidates.filter { $0.windowID != windowID }
                replaceTopology(fixture, with: surviving)
                await fixture.bridge.invalidateWindow(windowID, reason: .windowClosed)
                await fixture.bridge.test_settleLaunchReconciliation()
            }
            let reopenedObserver = makeReadyCandidate(windowID: 3, sessionID: observerSessionID)
            let reopenedTarget = makeReadyCandidate(windowID: 4, sessionID: targetSessionID)
            fixture.host.descriptors = [descriptor(for: reopenedObserver), descriptor(for: reopenedTarget)]
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            XCTAssertEqual(fixture.host.hydrationRequests, [bothSessions, bothSessions])

            // A background tab can close again while parked; both still-cold endpoints stay eligible.
            fixture.bridge.noteOversightWindowClosing(windowID: 3)
            fixture.host.descriptors = [descriptor(for: reopenedTarget)]
            await fixture.bridge.invalidateWindow(3, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            let finalObserver = makeReadyCandidate(windowID: 5, sessionID: observerSessionID)
            fixture.host.descriptors = [descriptor(for: finalObserver), descriptor(for: reopenedTarget)]
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            XCTAssertEqual(fixture.host.hydrationRequests, [bothSessions, bothSessions, bothSessions])
            replaceTopology(fixture, with: [finalObserver, reopenedTarget])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let replacement = await liveReference(fixture)
            XCTAssertNotNil(replacement)
            XCTAssertNotEqual(replacement, original)
            let inventory = await fixture.authority.links(forObserver: observerSessionID)
            XCTAssertEqual(inventory.items.map(\.targetSessionID), [targetSessionID])
            XCTAssertEqual(fixture.host.providerTaskRequests, 0)
        }
    }

    func testParkedDeletionCannotRestoreAndFailedCleanupRemainsRetryable() async throws {
        for failsWrite in [false, true] {
            AgentSessionDeletionRegistry.shared.test_reset()
            let (fixture, observer, _) = try await makeRestoredFixture()
            fixture.bridge.attach(host: fixture.host)
            fixture.bridge.noteOversightWindowClosing(windowID: 2)
            replaceTopology(fixture, with: [observer])
            await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()
            fixture.gate.failsNextWrites = failsWrite
            let deletion = AgentSessionDeletionRegistry.shared.beginDurableDeletion(sessionID: targetSessionID)
            await AgentSessionDeletionRegistry.shared.didCommitDurableDeletion(deletion)
            replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let restored = await isRestored(fixture)
            XCTAssertFalse(restored)
            XCTAssertEqual(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry, failsWrite)
            fixture.gate.failsNextWrites = false
            await fixture.bridge.retryPendingIntentCleanup()
            let token = await fixture.store.token(for: pair)
            XCTAssertNil(token)
            XCTAssertFalse(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
        }
    }

    func testReopenedDescriptorOnlyTabRearmsHydrationAndDuplicatesStayParked() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID]])
        replaceTopology(fixture, with: [observer, target])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        fixture.bridge.noteOversightWindowClosing(windowID: 2)
        replaceTopology(fixture, with: [observer])
        await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
        await fixture.bridge.test_settleLaunchReconciliation()

        let reopened = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: reopened)]
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID], [targetSessionID]])
        let duplicate = makeReadyCandidate(windowID: 4, sessionID: targetSessionID)
        replaceTopology(fixture, with: [observer, reopened, duplicate])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let whileDuplicated = await isRestored(fixture)
        let saved = await fixture.store.token(for: pair)
        XCTAssertFalse(whileDuplicated)
        XCTAssertNotNil(saved)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.lifecycleRevoked))
        replaceTopology(fixture, with: [observer, reopened])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let restored = await isRestored(fixture)
        XCTAssertTrue(restored)
        XCTAssertEqual(fixture.host.hydrationRequests.count, 2)
    }

    func testLatePreCloseInvalidationCannotRemoveSameTokenReopenedGrant() async throws {
        let (fixture, observer, target) = try await makeRestoredFixture()
        let originalToken = await fixture.store.token(for: pair)
        let fence = TestReleaseFence(name: "old lifecycle settlement")
        fixture.bridge.test_beforeDurableIntentSettlement = { _ in await fence.enterAndWait() }
        let invalidation = Task { @MainActor in
            await fixture.bridge.invalidate(endpoint: target.domainEndpoint, reason: .targetEndpointInvalidated)
        }
        await fence.waitUntilEntered()
        fixture.bridge.noteOversightWindowClosing(windowID: 2)
        replaceTopology(fixture, with: [observer])
        await fixture.bridge.test_settleLaunchReconciliation()
        let reopened = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
        replaceTopology(fixture, with: [observer, reopened])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let replacement = await liveReference(fixture)
        XCTAssertNotNil(replacement)
        fixture.bridge.test_beforeDurableIntentSettlement = nil
        fence.release()
        await invalidation.value
        let token = await fixture.store.token(for: pair)
        let current = await liveReference(fixture)
        XCTAssertEqual(token, originalToken)
        XCTAssertEqual(current, replacement)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
    }

    func testAlreadySubmittedRemovalCannotBeAdoptedByLateWindowClose() async throws {
        let (fixture, observer, target) = try await makeRestoredFixture()
        let fence = TestReleaseFence(name: "committed removal before receipt callback")
        fixture.bridge.test_afterDurableIntentRemoval = { await fence.enterAndWait() }
        let invalidation = Task { @MainActor in
            await fixture.bridge.invalidate(endpoint: target.domainEndpoint, reason: .targetEndpointInvalidated)
        }
        await fence.waitUntilEntered()
        let removedToken = await fixture.store.token(for: pair)
        XCTAssertNil(removedToken, "This removal was already submitted before close and cannot be retracted.")
        fixture.bridge.noteOversightWindowClosing(windowID: 2)
        replaceTopology(fixture, with: [observer])
        fixture.bridge.test_afterDurableIntentRemoval = nil
        fence.release()
        await invalidation.value
        await fixture.bridge.test_settleLaunchReconciliation()
        replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.lifecycleRevoked))
        XCTAssertTrue(fixture.bridge.currentPersistencePresentation.warnings.isEmpty)
    }

    func testSuspendedActiveAuditCannotRetireCloseParkedOwnership() async throws {
        let (fixture, observer, _) = try await makeRestoredFixture()
        let originalToken = await fixture.store.token(for: pair)
        let fence = TestReleaseFence(name: "audit before exact runtime revocation")
        fixture.bridge.test_beforeLaunchAuditRevocation = { await fence.enterAndWait() }
        replaceTopology(fixture, with: [observer])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fence.waitUntilEntered()
        fixture.bridge.noteOversightWindowClosing(windowID: 2)
        fixture.bridge.test_beforeLaunchAuditRevocation = nil
        fence.release()
        await fixture.bridge.test_settleLaunchReconciliation()
        let parkedToken = await fixture.store.token(for: pair)
        XCTAssertEqual(parkedToken, originalToken)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.lifecycleRevoked))
        XCTAssertTrue(fixture.bridge.currentPersistencePresentation.warnings.isEmpty)
        replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let restored = await isRestored(fixture)
        XCTAssertTrue(restored)
    }

    func testCloseDuringReservationOrActivationCannotLetProofRollbackForgetIntent() async throws {
        for afterActivation in [false, true] {
            try seedSavedPair()
            let fixture = makeFixture()
            let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
            let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
            replaceTopology(fixture, with: [observer, target])
            let fence = TestReleaseFence(name: "establishment before close")
            if afterActivation {
                fixture.bridge.test_afterActivationBeforeDeletionFence = { _ in await fence.enterAndWait() }
            } else {
                fixture.bridge.test_afterReservationBeforeActivation = { _ in await fence.enterAndWait() }
            }
            await fixture.bridge.bootstrapIntentStore(fixture.store)
            await fence.waitUntilEntered()
            fixture.bridge.noteOversightWindowClosing(windowID: 2)
            replaceTopology(fixture, with: [observer])
            fixture.bridge.test_afterReservationBeforeActivation = nil
            fixture.bridge.test_afterActivationBeforeDeletionFence = nil
            fence.release()
            await fixture.bridge.test_settleLaunchReconciliation()
            let parked = await fixture.store.token(for: pair)
            XCTAssertNotNil(parked)
            let whileClosed = await isRestored(fixture)
            XCTAssertFalse(whileClosed, "Captured ownership preserves intent, never reservation/grant authority.")
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.lifecycleRevoked))
            replaceTopology(fixture, with: [observer, makeReadyCandidate(windowID: 3, sessionID: targetSessionID)])
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            let restored = await isRestored(fixture)
            XCTAssertTrue(restored)
        }
    }

    func testCloseDuringEarlierPairsSuspendedPassRestartsBeforeRearmingLaterPair() async throws {
        observerSessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        targetSessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let earlierTargetID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let earlierPair = AgentSessionOversightIntent(
            observerSessionID: observerSessionID, targetSessionID: earlierTargetID
        )
        try seedSavedPair([earlierPair])
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        let earlierTarget = makeReadyCandidate(windowID: 3, sessionID: earlierTargetID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [observer, target, earlierTarget].map { descriptor(for: $0) }
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: earlierPair), .waiting)

        let fence = TestReleaseFence(name: "earlier pair establishing")
        fixture.bridge.test_afterReservationBeforeActivation = { reservedPair in
            if reservedPair == earlierPair { await fence.enterAndWait() }
        }
        replaceTopology(fixture, with: [observer, target, earlierTarget])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fence.waitUntilEntered()
        fixture.bridge.noteOversightWindowClosing(windowID: 2)
        replaceTopology(fixture, with: [observer, earlierTarget])
        fixture.bridge.test_afterReservationBeforeActivation = nil
        fence.release()
        await fixture.bridge.test_settleLaunchReconciliation()
        let parkedToken = await fixture.store.token(for: pair)
        XCTAssertNotNil(parkedToken, "The pre-close pass snapshot must not spend the reopen allowance.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.lifecycleRevoked))
        replaceTopology(fixture, with: [
            observer, earlierTarget, makeReadyCandidate(windowID: 4, sessionID: targetSessionID)
        ])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let restored = await isRestored(fixture)
        XCTAssertTrue(restored)
    }

    func testFailedReopenEstablishmentDoesNotRetryOnOrdinaryEvents() async throws {
        let (fixture, observer, _) = try await makeRestoredFixture()
        fixture.bridge.noteOversightWindowClosing(windowID: 2)
        replaceTopology(fixture, with: [observer])
        await fixture.bridge.invalidateWindow(2, reason: .windowClosed)
        await fixture.bridge.test_settleLaunchReconciliation()
        let reopened = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
        replaceTopology(fixture, with: [observer, reopened])
        fixture.bridge.test_beforeSynchronousSeed = { fixture.host.candidates = [observer] }
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.activationFailed))
        fixture.bridge.test_beforeSynchronousSeed = nil
        replaceTopology(fixture, with: [observer, reopened])
        fixture.bridge.noteTopologyMayHaveChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        let restored = await isRestored(fixture)
        let token = await fixture.store.token(for: pair)
        XCTAssertFalse(restored)
        XCTAssertNil(token)
    }

    func testCleanupAndSameTokenReassertionDisplaceCloseOwnership() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let loadResult = await fixture.store.loadForLaunch()
        guard case let .ready(load) = loadResult else { return XCTFail("Expected a ready manifest") }
        let token = try XCTUnwrap(load.tokenByPair[pair])
        let reference = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
        let coordinator = AgentSessionOversightLaunchCoordinator()
        coordinator.loadLaunchEntries(load, automaticRestoreEnabled: true)
        coordinator.noteWindowClose(
            pair: pair, token: token, assertedAt: 0, reference: reference
        )
        XCTAssertFalse(coordinator.permitsRemoval(pair: pair, token: token))
        coordinator.noteCleanupPending(pair: pair, token: token, assertedAt: 0)
        XCTAssertTrue(coordinator.permitsRemoval(pair: pair, token: token), "Committed deletion must remain retryable.")
        XCTAssertFalse(coordinator.preservesClosedReference(reference, pair: pair, token: token, assertedAt: 0))
        coordinator.noteWindowClose(
            pair: pair, token: token, assertedAt: 0, reference: reference
        )
        XCTAssertEqual(coordinator.state(for: pair), .cleanupPending(token), "Close cannot adopt an unrelated cleanup.")
        coordinator.noteInteractiveTokenChange(pair: pair, token: token, assertedAt: 1)
        coordinator.noteCleanupPending(pair: pair, token: token, assertedAt: 0)
        coordinator.noteRevocation(pair: pair, assertedAt: 0, preservesIntent: false)
        XCTAssertEqual(coordinator.state(for: pair), .active, "Old callbacks cannot replace a same-token successor.")
        XCTAssertFalse(coordinator.preservesClosedReference(reference, pair: pair, token: token, assertedAt: 1))
        await coordinator.settle()
    }

    // MARK: - Barriers

    func testCreatorLaneRestoresAsOrdinaryManagedLinkWithoutStartingAProviderTask() async throws {
        try seedSavedPair()
        let originalFile = try Data(contentsOf: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename))
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let lane = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, lane]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: lane)]
        fixture.host.laneCreatorByEndpoint[lane.domainEndpoint] = observerSessionID

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let inventory = await fixture.authority.links(forObserverEndpoint: observer.domainEndpoint)
        XCTAssertEqual(inventory.items.map(\.targetSessionID), [targetSessionID])
        XCTAssertEqual(inventory.items.first?.capabilities, DomainAgentSessionLinkCapability.managed)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
        XCTAssertEqual(fixture.host.providerTaskRequests, 0)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(AgentSessionOversightIntentStore.filename)), originalFile)
    }

    func testNothingIsReservedWhileTheRestoreTopologyIsStillPending() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        fixture.host.topology = .pending
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let restored = await isRestored(fixture)
        XCTAssertFalse(restored, "Automatic restore may not reserve before the outer topology settles.")
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 0)
    }

    func testNothingIsReservedWhileAWindowsDiscoveryLevelIsIncomplete() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        fixture.host.discovery = [
            AgentSessionLinkDiscoveryState(
                epoch: AgentSessionLinkDiscoveryEpoch(windowID: 1, workspaceID: UUID(), generation: 2),
                isComplete: false
            )
        ]
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
    }

    func testSameWindowReopenRestoresAfterPassiveHydrationIsInterruptedByDiscoveryChange() async throws {
        for interrupted in [false, true] {
            try seedSavedPair()
            let fixture = makeFixture()
            let workspaceID = UUID()
            let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID, workspaceID: workspaceID)
            let target = makeReadyCandidate(windowID: 1, sessionID: targetSessionID, workspaceID: workspaceID)
            replaceTopology(fixture, with: [observer, target])
            await fixture.bridge.bootstrapIntentStore(fixture.store)
            await fixture.bridge.test_settleLaunchReconciliation()
            let original = await liveReference(fixture)
            XCTAssertNotNil(original)
            let token = await fixture.store.token(for: pair)

            fixture.bridge.noteOversightWindowClosing(windowID: 1)
            replaceTopology(fixture, with: [])
            await fixture.bridge.invalidateWindow(1, reason: .windowClosed)
            await fixture.bridge.test_settleLaunchReconciliation()

            let reopenedObserver = makeReadyCandidate(windowID: 2, sessionID: observerSessionID, workspaceID: workspaceID)
            let reopenedTarget = makeReadyCandidate(windowID: 2, sessionID: targetSessionID, workspaceID: workspaceID)
            fixture.host.candidates = [reopenedObserver]
            fixture.host.descriptors = [descriptor(for: reopenedObserver), descriptor(for: reopenedTarget)]
            let epoch = AgentSessionLinkDiscoveryEpoch(windowID: 2, workspaceID: workspaceID, generation: 1)
            fixture.host.discovery = [.init(epoch: epoch, isComplete: true)]

            // Gate the host's passive load, not a provider: delivery can be abandoned by its owner.
            let completeHydration = {
                fixture.host.candidates = [reopenedObserver, reopenedTarget]
                fixture.bridge.noteCandidateReadinessChanged()
            }
            var pendingHydration: (() -> Void)?
            fixture.host.hydrationHandler = { _ in pendingHydration = completeHydration }
            defer { fixture.host.hydrationHandler = nil }
            fixture.bridge.noteTopologyMayHaveChanged()
            await fixture.bridge.test_settleLaunchReconciliation()
            XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID]])
            XCTAssertNotNil(pendingHydration)
            let beforeHydration = await fixture.authority.links(forObserver: observerSessionID)
            XCTAssertTrue(beforeHydration.items.isEmpty)

            if interrupted {
                // Model a workspace activation discarding that request. The saved bindings survive.
                let successor = AgentSessionLinkDiscoveryEpoch(windowID: 2, workspaceID: workspaceID, generation: 2)
                fixture.host.discovery = [.init(epoch: successor, isComplete: false)]
                pendingHydration = nil
                fixture.bridge.noteTopologyMayHaveChanged()
                await fixture.bridge.test_settleLaunchReconciliation()
                fixture.host.hydrationHandler = { _ in completeHydration() }
                fixture.host.discovery = [.init(epoch: successor, isComplete: true)]
                fixture.bridge.noteCandidateReadinessChanged()
            } else {
                pendingHydration?()
                pendingHydration = nil
            }
            await fixture.bridge.test_settleLaunchReconciliation()

            let restored = await fixture.authority.links(forObserverEndpoint: reopenedObserver.domainEndpoint)
            XCTAssertEqual(
                restored.items.map(\.targetSessionID), [targetSessionID],
                "Same-window reopen must restore without a user turn; interrupted=\(interrupted)."
            )
            if let link = restored.items.first {
                XCTAssertNotEqual(DomainAgentSessionLinkReference(linkID: link.linkID, generation: link.generation), original)
                XCTAssertEqual(link.capabilities, DomainAgentSessionLinkCapability.managed)
            }
            let retainedToken = await fixture.store.token(for: pair)
            XCTAssertEqual(retainedToken, token)
            XCTAssertEqual(fixture.host.providerTaskRequests, 0)
        }
    }

    // MARK: - Lazy background tabs

    /// A saved session that is *present* but unhydrated is waited for — never declared missing — and
    /// passive loading is owned by the host, so the pair comes back without the user opening every
    /// endpoint's tab. The already-hydrated observer is never asked to reload.
    func testALazyBackgroundTabWaitsAndThenActivatesExactlyOnceWhenItHydrates() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let lazyTabID = UUID()
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [
            descriptor(for: observer),
            AgentSessionLinkComposeTabDescriptor(
                windowID: 2,
                workspaceID: UUID(),
                tabID: lazyTabID,
                sessionID: targetSessionID
            )
        ]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        var restored = await isRestored(fixture)
        XCTAssertFalse(restored, "A described-but-unhydrated tab must be waited for, not resolved.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        let tokenWhileWaiting = await fixture.store.token(for: pair)
        XCTAssertNotNil(tokenWhileWaiting, "Waiting must never delete the saved intent.")
        XCTAssertEqual(
            fixture.host.hydrationRequests,
            [[targetSessionID]],
            "Only the unhydrated endpoint of the saved pair is asked to load."
        )

        // A still-cold endpoint is requested again; the host loader owns in-flight deduplication.
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID], [targetSessionID]])

        // The requested load lands: the tab becomes a live authoritative candidate.
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        restored = await isRestored(fixture)
        XCTAssertTrue(restored)
        let restoredInventory = await fixture.authority.links(forObserverEndpoint: observer.domainEndpoint)
        XCTAssertEqual(restoredInventory.items.first?.capabilities, DomainAgentSessionLinkCapability.managed)
        let managedLease = try await fixture.authority.authorize(
            operation: .monitorRespond,
            observerEndpoint: observer.domainEndpoint,
            targetSessionID: target.sessionID
        ).get()
        XCTAssertEqual(managedLease.capability, .manage, "restoration follows the same managed Add path")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
    }

    /// A bound-but-still-pending candidate (a tab whose session object exists but whose payload has
    /// not loaded) is also asked to load; an authoritative one is not.
    func testAPendingCandidateIsAskedToHydrateButAnAuthoritativeOneIsNot() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let ready = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        guard case let .authoritative(bindingToken, _) = ready.restorationReadiness else {
            return XCTFail("Expected an authoritative fixture")
        }
        let pending = withReadiness(ready, .pending(bindingToken))
        fixture.host.candidates = [observer, pending]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: pending)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID]])
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
    }

    func testInProgressDeletionKeepsLaunchIntentWaitingAndFailureRestoresIt() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        var target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        let attempt = AgentSessionDeletionRegistry.shared
            .beginDurableDeletion(sessionID: targetSessionID)
        target.isDeletionInProgress = true
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 0)
        let tokenWhileDeleting = await fixture.store.token(for: pair)
        XCTAssertNotNil(tokenWhileDeleting, "A reversible attempt must not retire durable intent.")

        AgentSessionDeletionRegistry.shared.didFailDurableDeletion(attempt)
        target.isDeletionInProgress = false
        fixture.host.candidates = [observer, target]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
        let tokenAfterFailure = await fixture.store.token(for: pair)
        XCTAssertEqual(tokenAfterFailure, tokenWhileDeleting)
        let restored = await isRestored(fixture)
        XCTAssertTrue(restored)
    }

    // MARK: - Absence

    func testAMissingSessionIsRemovedOnlyWhenTheTopologyProvesAbsence() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        fixture.host.topology = .incompleteLeftoversAbandoned(count: 1)
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [descriptor(for: observer)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let survived = await fixture.store.token(for: pair)
        XCTAssertNotNil(survived, "Abandoned leftovers cannot prove absence, so the intent must survive.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
    }

    func testAMissingSessionIsTerminalUnderAllEntriesConsumed() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [descriptor(for: observer)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.missing))
    }

    /// A duplicate is a positive fact even under an uncertain topology.
    func testADuplicateLiveIncarnationTerminatesEvenWhenAbsenceIsUncertain() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        fixture.host.topology = .incompleteLeftoversAbandoned(count: 2)
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        let duplicate = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target, duplicate]
        fixture.host.descriptors = [
            descriptor(for: observer),
            descriptor(for: target),
            descriptor(for: duplicate)
        ]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.ambiguousDuplicate))
        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
    }

    func testATerminalHydrationProofTerminatesTheEntryDespiteALiveCandidate() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let failedTabID = UUID()
        let failed = AgentSessionLinkEndpointCandidate(
            windowID: 2,
            workspaceID: UUID(),
            tabID: failedTabID,
            sessionID: targetSessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            isTopLevel: true,
            // The legacy completion latch is true; only the binding-qualified proof knows better.
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: false,
            isMCPControlled: false,
            isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true,
            displayName: "Build API",
            providerDisplayName: "Codex CLI",
            locationLabel: "worktree/main",
            restorationReadiness: .terminal(
                AgentSessionRestorationBindingToken(
                    bindingIdentity: AgentPersistentSessionBindingIdentity(
                        tabID: failedTabID,
                        sessionID: targetSessionID
                    ),
                    bindingTransitionGeneration: 1
                ),
                .missingPayload
            )
        )
        fixture.host.candidates = [observer, failed]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: failed)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.hydrationFailed))
        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
    }

    /// A source revision can change while a passive background load is preparing. That does not
    /// prove the saved relationship is gone; a later authoritative save may safely restore it.
    func testSupersededHydrationKeepsIntentUntilAuthoritativeRecovery() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        guard case let .authoritative(bindingToken, _) = target.restorationReadiness else {
            return XCTFail("Expected an authoritative fixture")
        }
        fixture.host.candidates = [observer, withReadiness(target, .pending(bindingToken))]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.host.hydrationRequests, [[targetSessionID]])

        fixture.host.candidates = [
            observer,
            withReadiness(target, .terminal(bindingToken, .sourceRevisionSuperseded))
        ]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        var token = await fixture.store.token(for: pair)
        var restored = await isRestored(fixture)
        XCTAssertNotNil(token)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        XCTAssertFalse(restored)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 0)

        fixture.host.candidates = [observer, withReadiness(target, .terminal(bindingToken, .loadFailed))]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "A failed load may be transient and must not discard the intent.")
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        let requestCount = fixture.host.hydrationRequests.count
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.host.hydrationRequests.count, requestCount)

        fixture.host.candidates = [observer, target]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        restored = await isRestored(fixture)
        XCTAssertTrue(restored)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .active)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
    }

    // MARK: - At most once

    /// The user watched oversight end. It must not silently come back on the next readiness event.
    func testALaterRevocationTerminalizesTheEntryAndIsNeverRequeued() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        var restored = await isRestored(fixture)
        XCTAssertTrue(restored)

        // The observer's window closes.
        await fixture.bridge.invalidateWindow(1, reason: .windowClosed)
        fixture.host.candidates = [target]
        fixture.host.descriptors = [descriptor(for: target)]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token, "An ordinary window close ends the saved relationship.")
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)

        // Everything comes back. The retired entry must not reserve a second time.
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
    }

    // MARK: - Proof carried through establishment

    /// Classification proving `.authoritative` is not enough on its own.
    ///
    /// The shared establishment path re-resolves with the resolver, which gates on the legacy
    /// `hasLoadedPersistedState` latch — also `true` for a missing payload, a superseded revision,
    /// and a thrown load error. Without the proof travelling into that path, an endpoint that
    /// rehydrates in place between classification and reservation is silently reauthorized.
    func testAProofThatStopsHoldingAfterClassificationBlocksTheAutomaticRestore() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        let rehydrating = withReadiness(
            target,
            .pending(
                AgentSessionRestorationBindingToken(
                    bindingIdentity: AgentPersistentSessionBindingIdentity(
                        tabID: target.tabID,
                        sessionID: target.sessionID
                    ),
                    bindingTransitionGeneration: 1
                )
            )
        )
        XCTAssertEqual(
            rehydrating.domainEndpoint,
            target.domainEndpoint,
            "The identity must be unchanged, or the resolver would have caught this on its own."
        )
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        fixture.host.candidates = [observer, target]
        fixture.host.candidatesAfterClassification = [observer, rehydrating]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let restored = await isRestored(fixture)
        XCTAssertFalse(restored, "An unproven incarnation must never be reauthorized.")
        XCTAssertEqual(fixture.host.classificationHandoffCount, 1)
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
        XCTAssertEqual(
            fixture.bridge.test_launchEntryState(for: pair),
            .terminal(.activationFailed)
        )
        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
    }

    func testSupersessionDuringEstablishmentKeepsIntentWithoutGranting() async throws {
        for bothEndpoints in [false, true] {
            try seedSavedPair()
            let fixture = makeFixture()
            let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
            let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
            guard case let .authoritative(targetToken, _) = target.restorationReadiness,
                  case let .authoritative(observerToken, _) = observer.restorationReadiness
            else {
                return XCTFail("Expected authoritative fixtures")
            }
            let superseded = withReadiness(target, .terminal(targetToken, .sourceRevisionSuperseded))
            let currentObserver = bothEndpoints
                ? withReadiness(observer, .terminal(observerToken, .loadFailed)) : observer
            fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
            // Classification sees completed payloads; the shared path sees their supersession.
            fixture.host.candidates = [observer, target]
            fixture.host.candidatesAfterClassification = [currentObserver, superseded]

            await fixture.bridge.bootstrapIntentStore(fixture.store)
            await fixture.bridge.test_settleLaunchReconciliation()

            let restored = await isRestored(fixture)
            let token = await fixture.store.token(for: pair)
            XCTAssertFalse(restored)
            XCTAssertEqual(fixture.host.classificationHandoffCount, 1)
            XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
            XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 1)
            XCTAssertNotNil(token)
        }
    }

    func testTransientObserverFailureDoesNotMaskMissingTargetPayload() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        guard case let .authoritative(observerToken, _) = observer.restorationReadiness,
              case let .authoritative(targetToken, _) = target.restorationReadiness
        else {
            return XCTFail("Expected authoritative fixtures")
        }
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        fixture.host.candidates = [
            withReadiness(observer, .terminal(observerToken, .loadFailed)),
            withReadiness(target, .terminal(targetToken, .missingPayload))
        ]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .terminal(.hydrationFailed))
        XCTAssertEqual(fixture.bridge.test_launchReservationStartCount(), 0)
    }

    // MARK: - Active-entry audit

    /// A restored grant is re-audited, not left alone for the rest of the launch.
    func testALateDuplicateIncarnationRevokesARestoredGrantAndNeverRequeuesIt() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        var restored = await isRestored(fixture)
        XCTAssertTrue(restored)

        // The saved UUID opens a second time. Neither incarnation may be granted from here on.
        let duplicate = makeReadyCandidate(windowID: 3, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target, duplicate]
        fixture.host.descriptors = [
            descriptor(for: observer),
            descriptor(for: target),
            descriptor(for: duplicate)
        ]
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        XCTAssertEqual(
            fixture.bridge.test_launchEntryState(for: pair),
            .terminal(.ambiguousDuplicate)
        )
        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
        XCTAssertEqual(
            fixture.bridge.test_launchReservationStartCount(),
            1,
            "An audited entry is finished, never requeued."
        )
    }

    /// An ordinary close of a described-but-unhydrated tab ends the saved relationship.
    ///
    /// Nothing was ever granted, so no authority notice mentions this pair and the durable-intent
    /// settlement has nothing to remove. Under a topology that cannot prove absence the intent would
    /// otherwise survive the close and reactivate later.
    func testClosingADescribedButUnhydratedTabEndsTheWaitingIntent() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        fixture.host.topology = .incompleteLeftoversAbandoned(count: 1)
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let lazyTabID = UUID()
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [
            descriptor(for: observer),
            AgentSessionLinkComposeTabDescriptor(
                windowID: 2,
                workspaceID: UUID(),
                tabID: lazyTabID,
                sessionID: targetSessionID
            )
        ]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertEqual(fixture.bridge.test_launchEntryState(for: pair), .waiting)
        let whileWaiting = await fixture.store.token(for: pair)
        XCTAssertNotNil(whileWaiting)

        fixture.bridge.noteOversightWindowClosing(windowID: 2)
        fixture.host.descriptors = [descriptor(for: observer)]
        await fixture.bridge.invalidateBinding(windowID: 2, tabID: lazyTabID, reason: .tabClosed)
        await fixture.bridge.test_settleLaunchReconciliation()

        XCTAssertEqual(
            fixture.bridge.test_launchEntryState(for: pair),
            .terminal(.bindingDrift),
            "An endpoint observed and then torn down is a fact, not the uncertainty of an abandoned restore."
        )
        let token = await fixture.store.token(for: pair)
        XCTAssertNil(token)
    }

    // MARK: - Launch policy

    func testAutoRestoreDisabledLoadsTheManifestWithoutReauthorizingAnything() async throws {
        try seedSavedPair()
        let fixture = makeFixture(mode: .dormant)
        fixture.host.topology = .dormantAutoRestoreDisabled
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        await fixture.bridge.bootstrapIntentStore(fixture.store)
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "Dormant intent must survive a launch with restoration turned off.")
        let restored = await isRestored(fixture)
        XCTAssertFalse(restored)
        XCTAssertEqual(
            fixture.bridge.currentPersistencePresentation.noticeMessage,
            AgentSessionOversightPersistenceCopy.autoRestoreDisabled
        )
    }

    // MARK: - Cleanup failure

    func testACleanupWriteFailureSuppressesTheEntryAndSurfacesRetrySaving() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        // Only the observer is present, under a topology that proves absence: the entry is terminal
        // and owes a durable removal, which the gate then refuses.
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [descriptor(for: observer)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        fixture.gate.failsNextWrites = true

        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()

        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "A failed cleanup preserves the row; it must not be silently dropped.")
        XCTAssertTrue(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
        XCTAssertEqual(
            fixture.bridge.currentPersistencePresentation.warnings.map(\.id),
            [AgentSessionOversightWarningID.cleanupFailed]
        )

        // Retry saving is one of the few permitted retry triggers.
        fixture.gate.failsNextWrites = false
        await fixture.bridge.retryPendingIntentCleanup()

        let afterRetry = await fixture.store.token(for: pair)
        XCTAssertNil(afterRetry)
        XCTAssertFalse(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)
    }

    /// **Retry saving** racing an explicit Add of the same pair.
    ///
    /// Both are durable mutations of one pair, so both take its retirement lane and the outcome is
    /// an invariant rather than a coin flip: whichever runs first, the user ends up with a live grant
    /// backed by a durable row. Outside the lane, a cleanup already suspended on the store actor
    /// would commit its expected-token removal *after* the Add reused that very token, deleting the
    /// intent the user just recreated.
    func testRetrySavingRacingAnExplicitAddLeavesTheReassertedPairGrantedAndDurable() async throws {
        try seedSavedPair()
        let fixture = makeFixture()
        let observer = makeReadyCandidate(windowID: 1, sessionID: observerSessionID)
        fixture.host.candidates = [observer]
        fixture.host.descriptors = [descriptor(for: observer)]
        await fixture.bridge.bootstrapIntentStore(fixture.store)
        fixture.gate.failsNextWrites = true
        fixture.bridge.noteCandidateReadinessChanged()
        await fixture.bridge.test_settleLaunchReconciliation()
        XCTAssertTrue(fixture.bridge.currentPersistencePresentation.hasPendingCleanupRetry)

        // The target comes back and the user explicitly re-adds the pair, while the failed cleanup
        // is retried at the same moment.
        fixture.gate.failsNextWrites = false
        let target = makeReadyCandidate(windowID: 2, sessionID: targetSessionID)
        fixture.host.candidates = [observer, target]
        fixture.host.descriptors = [descriptor(for: observer), descriptor(for: target)]

        async let retry: Void = fixture.bridge.retryPendingIntentCleanup()
        let outcome = await fixture.bridge.addMonitorLink(
            observerSessionID: observerSessionID,
            rawTargetSessionID: targetSessionID.uuidString
        )
        await retry

        guard case .added = outcome else {
            return XCTFail("Expected the explicit Add to succeed, got \(outcome)")
        }
        let token = await fixture.store.token(for: pair)
        XCTAssertNotNil(token, "A stale cleanup must never delete what the user just recreated.")
        let restored = await isRestored(fixture)
        XCTAssertTrue(restored, "The grant and the durable row must agree.")
    }
}
