import RepoPromptSettingsCore
#if DEBUG
    import Foundation
    import MCP
    @testable import RepoPromptApp
    import XCTest

    @MainActor
    final class CodemapGraphStatusDebugDiagnosticsTests: XCTestCase {
        override func setUp() {
            super.setUp()
            GlobalSettingsStore.installApplicationModelIdentityPolicy()
        }

        func testOperationAttachesToCurrentWindowWorkspaceWithoutArm() async throws {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            await window.workspaceManager.awaitInitialized()
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }

            let result = await ServerNetworkManager.shared.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: [
                    "op": .string("codemap_graph_status"),
                    "window_id": .int(window.windowID),
                    "include_events": .bool(true),
                    "event_limit": .int(8)
                ]
            )
            let payload = try diagnosticsPayload(result)
            XCTAssertEqual(payload["ok"] as? Bool, true)
            XCTAssertEqual(payload["op"] as? String, "codemap_graph_status")
            XCTAssertEqual((payload["schema_version"] as? NSNumber)?.intValue, 1)
            XCTAssertEqual((payload["window_id"] as? NSNumber)?.intValue, window.windowID)
            XCTAssertNotNil(payload["roots"] as? [[String: Any]])
            XCTAssertNotNil(payload["totals"] as? [String: Any])
            let storeEvents = try XCTUnwrap(payload["store_events"] as? [String: Any])
            XCTAssertNotNil(storeEvents["next_ordinal"])

            let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
            var pageMeasurement = WorkspaceCodemapManifestMeasurementAggregate()
            pageMeasurement.loadCount = 2
            pageMeasurement.submissionCount = 2
            pageMeasurement.waitCount = 2
            pageMeasurement.storeAttemptCount = 2
            pageMeasurement.writeCount = 2
            pageMeasurement.mutationCountVolume = 2
            pageMeasurement.mutationByteVolume = 128
            pageMeasurement.inputSnapshotRecordVolume = 1
            pageMeasurement.outputSnapshotRecordVolume = 3
            pageMeasurement.inputSnapshotByteVolume = 256
            pageMeasurement.attemptedOutputSnapshotRecordVolume = 3
            pageMeasurement.attemptedOutputSnapshotByteVolume = 768
            pageMeasurement.outputSnapshotByteVolume = 768
            pageMeasurement.atomicReplaceDurationNanoseconds = 11
            pageMeasurement.temporaryFileSyncDurationNanoseconds = 12
            pageMeasurement.manifestDirectorySyncDurationNanoseconds = 13
            let stablePayload = CodemapGraphStatusDebugSupport.payload(
                snapshot: CodemapGraphStatusSnapshot(
                    sampledUptimeNanoseconds: 1,
                    roots: [CodemapGraphStatusRootSnapshot(
                        rootEpoch: rootEpoch,
                        catalogGeneration: 0,
                        ingressGeneration: 0,
                        rootKind: .primaryWorkspace,
                        eligibilityFlightPresent: false,
                        launch: nil,
                        job: nil,
                        admission: nil,
                        manifest: CodemapGraphStatusManifestSnapshot(
                            failureCounts: [.staleAuthority: 3],
                            lastFailure: WorkspaceCodemapManifestFailureDiagnostic(
                                reason: .staleAuthority,
                                operation: nil,
                                currentAuthorityGeneration: 4,
                                observedPredecessorAuthorityGeneration: 7,
                                attemptStartedUptimeNanoseconds: 10,
                                attemptCompletedUptimeNanoseconds: 25,
                                attemptDurationNanoseconds: 15
                            ),
                            measurements: WorkspaceCodemapManifestMeasurementSnapshot(
                                byOrigin: [.page: pageMeasurement]
                            )
                        ),
                        milestones: [],
                        engineEvents: WorkspaceCodemapGraphIndexDebugEventPage(
                            events: [],
                            firstOrdinal: 0,
                            lastOrdinal: 0,
                            nextOrdinal: nil
                        )
                    )],
                    storeEvents: nil,
                    graphIndexJobCount: 0,
                    queuedGraphIndexBatchCount: 0,
                    activeGraphIndexBatchCount: 0,
                    drainingGraphIndexTaskCount: 0
                ),
                op: "codemap_graph_status",
                windowID: window.windowID,
                workspaceID: nil
            )
            let enginePages = try XCTUnwrap(stablePayload["engine_events"] as? [[String: Any]])
            XCTAssertNotNil(try XCTUnwrap(enginePages.first)["next_ordinal"])
            let roots = try XCTUnwrap(stablePayload["roots"] as? [[String: Any]])
            let manifest = try XCTUnwrap(try XCTUnwrap(roots.first)["manifest"] as? [String: Any])
            XCTAssertTrue(manifest["writers"] is NSNull)
            let counts = try XCTUnwrap(manifest["failure_counts"] as? [String: Any])
            XCTAssertEqual((counts["staleAuthority"] as? NSNumber)?.uint64Value, 3)
            let lastFailure = try XCTUnwrap(manifest["last_failure"] as? [String: Any])
            XCTAssertEqual(lastFailure["reason"] as? String, "staleAuthority")
            XCTAssertEqual((lastFailure["current_authority_generation"] as? NSNumber)?.uint64Value, 4)
            XCTAssertEqual(
                (lastFailure["observed_predecessor_authority_generation"] as? NSNumber)?.uint64Value,
                7
            )
            XCTAssertEqual((lastFailure["attempt_duration_ns"] as? NSNumber)?.uint64Value, 15)
            let measurements = try XCTUnwrap(manifest["measurements"] as? [String: Any])
            let page = try XCTUnwrap(measurements["page"] as? [String: Any])
            XCTAssertEqual((page["load_count"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["submission_count"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["wait_count"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["store_attempt_count"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["write_count"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["mutation_count_volume"] as? NSNumber)?.uint64Value, 2)
            XCTAssertEqual((page["mutation_byte_volume"] as? NSNumber)?.uint64Value, 128)
            XCTAssertEqual((page["input_snapshot_record_volume"] as? NSNumber)?.uint64Value, 1)
            XCTAssertEqual((page["output_snapshot_record_volume"] as? NSNumber)?.uint64Value, 3)
            XCTAssertEqual((page["input_snapshot_byte_volume"] as? NSNumber)?.uint64Value, 256)
            XCTAssertEqual(
                (page["attempted_output_snapshot_record_volume"] as? NSNumber)?.uint64Value,
                3
            )
            XCTAssertEqual(
                (page["attempted_output_snapshot_byte_volume"] as? NSNumber)?.uint64Value,
                768
            )
            XCTAssertEqual((page["output_snapshot_byte_volume"] as? NSNumber)?.uint64Value, 768)
            XCTAssertEqual((page["atomic_replace_duration_ns"] as? NSNumber)?.uint64Value, 11)
            XCTAssertEqual((page["temporary_file_sync_duration_ns"] as? NSNumber)?.uint64Value, 12)
            XCTAssertEqual(
                (page["manifest_directory_sync_duration_ns"] as? NSNumber)?.uint64Value,
                13
            )
        }

        func testManifestWriterSerializationKeepsPartialRootScopeUnknown() throws {
            let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
            let otherRootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
            let engineID = UUID()
            let workspaceID = UUID()
            let writerID = UUID()
            let batchID = UUID()
            let cases = [
                (name: "capped busy engine", complete: true, quiet: false, capped: true),
                (name: "empty incomplete accounting", complete: false, quiet: false, capped: false),
                (name: "confirmed idle engine", complete: true, quiet: true, capped: false)
            ]
            for scenario in cases {
                let tasks: [CodemapManifestWriterTaskSnapshot] = scenario.capped ? [
                    CodemapManifestWriterTaskSnapshot(
                        writerID: writerID,
                        namespaceDigest: "namespace-a",
                        rootEpoch: otherRootEpoch,
                        batchID: batchID,
                        origin: "graph_page",
                        phase: "awaiting_publication",
                        taskStartedUptimeNanoseconds: 2_000_000,
                        batchStartedUptimeNanoseconds: 4_000_000,
                        phaseStartedUptimeNanoseconds: 6_000_000
                    ),
                    CodemapManifestWriterTaskSnapshot(
                        writerID: UUID(),
                        namespaceDigest: "namespace-b",
                        rootEpoch: nil,
                        batchID: nil,
                        origin: nil,
                        phase: "scheduled",
                        taskStartedUptimeNanoseconds: 3_000_000,
                        batchStartedUptimeNanoseconds: nil,
                        phaseStartedUptimeNanoseconds: 3_000_000
                    )
                ] : []
                let namespaces: [CodemapManifestWriterQueueSnapshot] = scenario.capped ? [
                    CodemapManifestWriterQueueSnapshot(
                        namespaceDigest: "namespace-a",
                        queuedItemCount: 3,
                        deferredTailItemCount: 2,
                        deferredHeadWaitingItemCount: 1,
                        inFlightItemCount: 4,
                        retryPending: true
                    )
                ] : []
                let activity = CodemapManifestWriterActivitySnapshot(
                    engineInstanceID: engineID,
                    rootEpoch: rootEpoch,
                    sampledUptimeNanoseconds: 10_000_000,
                    liveTaskCount: scenario.capped ? 9 : 0,
                    namespaceCount: scenario.capped ? 10 : 0,
                    accountingComplete: scenario.complete,
                    quiescenceConfirmed: scenario.quiet,
                    omittedLiveTaskCount: scenario.capped ? 7 : 0,
                    tasks: tasks,
                    namespaces: namespaces,
                    omittedNamespaceCount: scenario.capped ? 9 : 0
                )
                let payload = CodemapGraphStatusDebugSupport.payload(
                    snapshot: CodemapGraphStatusSnapshot(
                        sampledUptimeNanoseconds: 10_000_000,
                        roots: [CodemapGraphStatusRootSnapshot(
                            rootEpoch: rootEpoch,
                            catalogGeneration: 0,
                            ingressGeneration: 0,
                            rootKind: .primaryWorkspace,
                            eligibilityFlightPresent: false,
                            launch: nil,
                            job: nil,
                            admission: nil,
                            manifest: CodemapGraphStatusManifestSnapshot(
                                failureCounts: [:],
                                lastFailure: nil,
                                measurements: WorkspaceCodemapManifestMeasurementSnapshot(byOrigin: [:]),
                                writerActivity: activity
                            ),
                            milestones: [],
                            engineEvents: nil
                        )],
                        storeEvents: nil,
                        graphIndexJobCount: 0,
                        queuedGraphIndexBatchCount: 0,
                        activeGraphIndexBatchCount: 0,
                        drainingGraphIndexTaskCount: 0
                    ),
                    op: "codemap_graph_status",
                    windowID: 41,
                    workspaceID: workspaceID
                )
                let encoded = try JSONSerialization.data(withJSONObject: payload)
                let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                XCTAssertEqual(decoded["window_id"] as? Int, 41, scenario.name)
                XCTAssertEqual(decoded["workspace_id"] as? String, workspaceID.uuidString, scenario.name)
                XCTAssertEqual(decoded["schema_version"] as? Int, 1, scenario.name)
                let roots = try XCTUnwrap(decoded["roots"] as? [[String: Any]])
                let manifest = try XCTUnwrap(try XCTUnwrap(roots.first)["manifest"] as? [String: Any])
                let writers = try XCTUnwrap(manifest["writers"] as? [String: Any])
                XCTAssertEqual(writers["scope"] as? String, "manifest_writer_tasks", scenario.name)
                XCTAssertEqual(writers["engine_instance_id"] as? String, engineID.uuidString, scenario.name)
                let root = try XCTUnwrap(writers["root"] as? [String: Any])
                XCTAssertEqual(root["scope"] as? String, "root_epoch", scenario.name)
                XCTAssertEqual(root["root_id"] as? String, rootEpoch.rootID.uuidString, scenario.name)
                XCTAssertEqual(root["root_lifetime_id"] as? String, rootEpoch.rootLifetimeID.uuidString, scenario.name)
                XCTAssertTrue(root["queue_item_count"] is NSNull, scenario.name)
                XCTAssertEqual(root["queue_counts_complete"] as? Bool, false, scenario.name)
                if scenario.quiet {
                    XCTAssertEqual(root["quiescence_confirmed"] as? Bool, true, scenario.name)
                } else {
                    XCTAssertTrue(root["quiescence_confirmed"] is NSNull, scenario.name)
                }
                let engine = try XCTUnwrap(writers["engine"] as? [String: Any])
                XCTAssertEqual(engine["scope"] as? String, "engine_all_root_epochs", scenario.name)
                XCTAssertEqual(engine["accounting_complete"] as? Bool, scenario.complete, scenario.name)
                XCTAssertEqual(engine["quiescence_confirmed"] as? Bool, scenario.quiet, scenario.name)
                XCTAssertEqual(engine["live_task_count"] as? Int, scenario.capped ? 9 : 0, scenario.name)
                XCTAssertEqual(engine["namespace_count"] as? Int, scenario.capped ? 10 : 0, scenario.name)
                XCTAssertEqual(engine["omitted_live_task_count"] as? Int, scenario.capped ? 7 : 0, scenario.name)
                XCTAssertEqual(engine["omitted_namespace_count"] as? Int, scenario.capped ? 9 : 0, scenario.name)
                XCTAssertEqual(engine["queue_counts_complete"] as? Bool, !scenario.capped, scenario.name)
                let serializedTasks = try XCTUnwrap(engine["tasks"] as? [[String: Any]])
                let serializedNamespaces = try XCTUnwrap(engine["namespaces"] as? [[String: Any]])
                XCTAssertEqual(serializedTasks.count, tasks.count, scenario.name)
                XCTAssertEqual(serializedNamespaces.count, namespaces.count, scenario.name)
                if scenario.capped {
                    let bound = try XCTUnwrap(serializedTasks.first)
                    XCTAssertEqual(bound["writer_id"] as? String, writerID.uuidString)
                    XCTAssertEqual(bound["batch_id"] as? String, batchID.uuidString)
                    XCTAssertEqual(bound["root_id"] as? String, otherRootEpoch.rootID.uuidString)
                    XCTAssertEqual(bound["root_lifetime_id"] as? String, otherRootEpoch.rootLifetimeID.uuidString)
                    XCTAssertEqual(bound["phase"] as? String, "awaiting_publication")
                    XCTAssertEqual(bound["origin"] as? String, "graph_page")
                    XCTAssertEqual(bound["task_started_uptime_ns"] as? UInt64, 2_000_000)
                    XCTAssertEqual(bound["task_age_ms"] as? UInt64, 8)
                    XCTAssertEqual(bound["batch_started_uptime_ns"] as? UInt64, 4_000_000)
                    XCTAssertEqual(bound["batch_age_ms"] as? UInt64, 6)
                    XCTAssertEqual(bound["phase_started_uptime_ns"] as? UInt64, 6_000_000)
                    XCTAssertEqual(bound["phase_age_ms"] as? UInt64, 4)
                    let unbound = serializedTasks[1]
                    XCTAssertTrue(unbound["root_id"] is NSNull)
                    XCTAssertTrue(unbound["root_lifetime_id"] is NSNull)
                    XCTAssertTrue(unbound["batch_id"] is NSNull)
                    XCTAssertTrue(unbound["origin"] is NSNull)
                    XCTAssertTrue(unbound["batch_started_uptime_ns"] is NSNull)
                    XCTAssertTrue(unbound["batch_age_ms"] is NSNull)
                    let queue = try XCTUnwrap(serializedNamespaces.first)
                    XCTAssertEqual(queue["queued_item_count"] as? Int, 3)
                    XCTAssertEqual(queue["deferred_tail_item_count"] as? Int, 2)
                    XCTAssertEqual(queue["deferred_head_waiting_item_count"] as? Int, 1)
                    XCTAssertEqual(queue["in_flight_item_count"] as? Int, 4)
                    XCTAssertEqual(queue["retry_pending"] as? Bool, true)
                }
            }
        }

        func testOperationRejectsInvalidRootAndEventCursorParameters() async throws {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            await window.workspaceManager.awaitInitialized()
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            let manager = ServerNetworkManager.shared
            for var arguments: [String: Value] in [
                [
                    "op": .string("codemap_graph_status"),
                    "root_id": .string("not-a-uuid")
                ],
                [
                    "op": .string("codemap_graph_status"),
                    "since_store_ordinal": .int(-1)
                ],
                [
                    "op": .string("codemap_graph_status"),
                    "event_limit": .int(0)
                ]
            ] {
                arguments["window_id"] = .int(window.windowID)
                let result = await manager.handleDebugDiagnosticsTool(
                    connectionID: UUID(),
                    arguments: arguments
                )
                let payload = try diagnosticsPayload(result)
                XCTAssertEqual(payload["ok"] as? Bool, false)
                XCTAssertEqual(payload["op"] as? String, "codemap_graph_status")
                XCTAssertEqual(payload["code"] as? String, "invalid_params")
            }
        }

        private func diagnosticsPayload(
            _ result: CallTool.Result
        ) throws -> [String: Any] {
            let text = try XCTUnwrap(result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content {
                    return text
                }
                return nil
            }.first)
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }
#endif

#if DEBUG
    /// Co-located to avoid another RepoPromptApp test import. No test uses the production
    /// sampler, installed defaults, real app PID, or production cache directory.
    final class CatalogPerfStallWatchdogTests: XCTestCase {
        private typealias State = CatalogPerfStallWatchdog.State

        func testThresholdRecoveryAndThirtySecondAdmissionFence() {
            var state = State()
            XCTAssertEqual(state.configure(active: true, enabled: true), [])
            XCTAssertEqual(state.tick(now: 0), [.heartbeat(1)])
            XCTAssertEqual(state.tick(now: 0.249), [])
            XCTAssertEqual(state.tick(now: 0.250), [.capture(1)])
            state.completed(1) // A failed attempt also consumes this episode.
            for now in stride(from: 0.5, through: 35.0, by: 0.5) {
                XCTAssertEqual(state.tick(now: now), [])
            }
            state.acknowledge(1)
            XCTAssertEqual(state.tick(now: 35.01), [.heartbeat(2)])
            XCTAssertEqual(state.tick(now: 35.261), [.capture(2)])
        }

        func testRecoveryBetweenTicksAndStaleAcknowledgment() {
            var state = State()
            _ = state.configure(active: true, enabled: true)
            _ = state.tick(now: 0)
            _ = state.tick(now: 0.25)
            state.completed(1)
            state.acknowledge(1)
            XCTAssertEqual(state.tick(now: 0.30), [.heartbeat(2)])
            state.acknowledge(1) // An old callback cannot clear the new heartbeat.
            XCTAssertEqual(state.outstanding, 2)
            for now in stride(from: 0.5, through: 30.0, by: 0.5) {
                _ = state.tick(now: now)
            }
            XCTAssertEqual(state.running, nil)
            XCTAssertEqual(state.tick(now: 30.25), [.capture(2)])
        }

        func testDisableLeaseRestartAndUnsettledChildNeverOverlap() {
            var state = State()
            _ = state.configure(active: true, enabled: true)
            _ = state.tick(now: 0)
            _ = state.tick(now: 0.25)
            XCTAssertEqual(state.configure(active: false, enabled: false), [.cancel(1)])
            XCTAssertEqual(state.configure(active: true, enabled: true), [])
            for now in stride(from: 0.5, through: 40.0, by: 0.5) {
                XCTAssertEqual(state.tick(now: now), [])
            }
            state.completed(1)
            XCTAssertEqual(state.tick(now: 40.25), []) // Still the consumed stall.
            state.acknowledge(1)
            XCTAssertEqual(state.tick(now: 40.3), [.heartbeat(2)])
            XCTAssertEqual(state.tick(now: 40.6), [.capture(2)])
            state.completed(1) // Old completion must not release the newer child.
            XCTAssertEqual(state.running, 2)
            XCTAssertEqual(state.configure(active: false, enabled: false, terminate: true), [.cancel(2)])
            _ = state.configure(active: true, enabled: true)
            XCTAssertEqual(state.tick(now: 41), [])
        }

        func testDeadlineAndObserverStarvation() {
            var state = State()
            _ = state.configure(active: true, enabled: true)
            _ = state.tick(now: 0)
            XCTAssertEqual(state.tick(now: 10), []) // Observer suspension is not stall evidence.
            XCTAssertEqual(state.tick(now: 10.249), [])
            XCTAssertEqual(state.tick(now: 10.25), [.capture(1)])
            XCTAssertEqual(state.tick(now: 13.249), [])
            XCTAssertEqual(state.tick(now: 13.25), [.cancel(1)])
            XCTAssertEqual(state.tick(now: 14), [])
            XCTAssertEqual(state.running, 1) // Deadline does not pretend cleanup settled.
        }

        func testAutomaticOffHasNoTimerOrPollingUntilActivation() async {
            let fixture = DriverFixture()
            let watchdog = CatalogPerfStallWatchdog(
                automatic: true, clock: { fixture.now }, enabled: { fixture.readPreference() },
                heartbeat: { _ in }, sample: { _ in XCTFail("unexpected sampling")
                    return nil
                }, publish: { _ in }
            )
            watchdog.setActive(true)
            var hasTimer = await watchdog.hasTimerForTesting()
            XCTAssertFalse(hasTimer)
            XCTAssertEqual(fixture.preferenceReadCount, 1)
            fixture.advance(to: 0.1, enabled: true)
            hasTimer = await watchdog.hasTimerForTesting()
            XCTAssertFalse(hasTimer)
            XCTAssertEqual(fixture.preferenceReadCount, 1) // No polling discovers the new value.
            watchdog.setActive(true)
            hasTimer = await watchdog.hasTimerForTesting()
            XCTAssertTrue(hasTimer)
            XCTAssertEqual(fixture.preferenceReadCount, 2)
            fixture.advance(to: 1, enabled: false)
            _ = await watchdog.tickForTesting()
            hasTimer = await watchdog.hasTimerForTesting()
            XCTAssertFalse(hasTimer) // Opt-out also stops an already-running monitor.
            let readsAtOptOut = fixture.preferenceReadCount
            fixture.advance(to: 2, enabled: true)
            hasTimer = await watchdog.hasTimerForTesting()
            XCTAssertFalse(hasTimer)
            XCTAssertEqual(fixture.preferenceReadCount, readsAtOptOut)
            watchdog.shutdown()
        }

        func testDefaultOffAndCancelledFakeDriverCannotPublishAfterReenable() async {
            let fixture = DriverFixture()
            let watchdog = CatalogPerfStallWatchdog(
                automatic: false, clock: { fixture.now }, enabled: { fixture.enabled },
                heartbeat: { _ in }, sample: { await fixture.sample($0) },
                publish: { fixture.publish($0) }
            )
            watchdog.setActive(true)
            var state = await watchdog.tickForTesting()
            XCTAssertNil(state.outstanding)
            fixture.advance(to: 1, enabled: true)
            state = await watchdog.tickForTesting()
            XCTAssertEqual(state.outstanding, 1)
            fixture.advance(to: 1.25, enabled: true)
            _ = await watchdog.tickForTesting()
            await fulfillment(of: [fixture.started], timeout: 2)
            fixture.advance(to: 2, enabled: false)
            _ = await watchdog.tickForTesting()
            XCTAssertFalse(fixture.ticketIsValid)
            fixture.advance(to: 3, enabled: true)
            state = await watchdog.tickForTesting()
            XCTAssertEqual(state.running, 1)
            fixture.finish()
            await watchdog.joinForTesting()
            XCTAssertEqual(fixture.publicationCount, 0)
            watchdog.shutdown()
            state = await watchdog.tickForTesting()
            XCTAssertTrue(state.terminated)
        }

        func testRecoveryBeforeLaunchRejectsQueuedCaptureButAllowsStartedSample() {
            let queued = CatalogPerfStallWatchdog.Ticket()
            queued.cancelBeforeStart()
            XCTAssertFalse(queued.begin())
            XCTAssertFalse(queued.isValid)
            let started = CatalogPerfStallWatchdog.Ticket()
            XCTAssertTrue(started.begin())
            started.cancelBeforeStart()
            XCTAssertTrue(started.isValid)
            started.cancel() // Explicit opt-out must still invalidate a started sample.
            XCTAssertFalse(started.isValid)
            XCTAssertFalse(started.begin())
        }

        func testFakeDriverPublicationAndTerminalCancellation() async {
            for terminate in [false, true] {
                let fixture = DriverFixture()
                let watchdog = CatalogPerfStallWatchdog(
                    automatic: false, clock: { fixture.now }, enabled: { fixture.enabled },
                    heartbeat: { _ in }, sample: { await fixture.sample($0) },
                    publish: { fixture.publish($0) }
                )
                watchdog.setActive(true)
                fixture.advance(to: 0, enabled: true)
                _ = await watchdog.tickForTesting()
                fixture.advance(to: 0.25, enabled: true)
                _ = await watchdog.tickForTesting()
                await fulfillment(of: [fixture.started], timeout: 2)
                if terminate {
                    watchdog.shutdown()
                    // Complete immediately, without draining the cancellation queue first.
                }
                fixture.finish()
                await watchdog.joinForTesting()
                XCTAssertEqual(fixture.publicationCount, terminate ? 0 : 1)
                watchdog.shutdown()
            }
        }

        func testPreferenceReadTimeDoesNotAgeNewHeartbeat() async {
            let fixture = DriverFixture()
            let watchdog = CatalogPerfStallWatchdog(
                automatic: false, clock: { fixture.now },
                enabled: { fixture.advance(to: fixture.now + 0.3, enabled: true)
                    return true
                },
                heartbeat: { _ in }, sample: { _ in nil }, publish: { _ in }
            )
            watchdog.setActive(true)
            _ = await watchdog.tickForTesting()
            fixture.advance(to: 0.35, enabled: true)
            let state = await watchdog.tickForTesting()
            XCTAssertNil(state.running)
            watchdog.shutdown()
        }

        func testAcknowledgmentDuringPreferenceReadDoesNotConsumeAdmission() async {
            let fixture = DriverFixture()
            let watchdog = CatalogPerfStallWatchdog(
                automatic: false, clock: { fixture.now },
                enabled: {
                    if fixture.now >= 0.5 {
                        fixture.acknowledge()
                        fixture.advance(to: 0.8, enabled: true)
                    }
                    return true
                },
                heartbeat: { fixture.storeHeartbeat($0) }, sample: { _ in nil }, publish: { _ in }
            )
            watchdog.setActive(true)
            _ = await watchdog.tickForTesting()
            fixture.advance(to: 0.5, enabled: true)
            let state = await watchdog.tickForTesting()
            XCTAssertNil(state.running)
            watchdog.shutdown()
        }

        func testOptOutBeforePublicationWithoutAnotherPoll() async {
            let fixture = DriverFixture()
            let watchdog = CatalogPerfStallWatchdog(
                automatic: false, clock: { fixture.now }, enabled: { fixture.enabled },
                heartbeat: { _ in }, sample: { await fixture.sample($0) }, publish: { fixture.publish($0) }
            )
            watchdog.setActive(true)
            fixture.advance(to: 0, enabled: true)
            _ = await watchdog.tickForTesting()
            fixture.advance(to: 0.25, enabled: true)
            _ = await watchdog.tickForTesting()
            await fulfillment(of: [fixture.started], timeout: 2)
            fixture.advance(to: 0.3, enabled: false)
            fixture.finish()
            await watchdog.joinForTesting()
            XCTAssertEqual(fixture.publicationCount, 0)
            watchdog.shutdown()
        }

        func testSubmissionDelayDoesNotAgeOutstandingHeartbeat() async {
            let fixture = DriverFixture()
            let watchdog = CatalogPerfStallWatchdog(
                automatic: false, clock: { fixture.now }, enabled: { true },
                heartbeat: { _ in fixture.advance(to: 0.3, enabled: true) },
                sample: { _ in nil }, publish: { _ in }
            )
            watchdog.setActive(true)
            _ = await watchdog.tickForTesting()
            fixture.advance(to: 0.31, enabled: true)
            var state = await watchdog.tickForTesting()
            XCTAssertNil(state.running)
            fixture.advance(to: 0.551, enabled: true)
            state = await watchdog.tickForTesting()
            XCTAssertEqual(state.running, 1)
            watchdog.shutdown()
            await watchdog.joinForTesting()
        }

        func testThresholdCrossingWithoutPreferenceRefreshDefersAdmission() async {
            let fixture = DriverFixture()
            let watchdog = CatalogPerfStallWatchdog(
                automatic: false, clock: { fixture.scriptedClock() }, enabled: { fixture.enabled },
                heartbeat: { _ in }, sample: { _ in nil }, publish: { _ in }
            )
            watchdog.setActive(true)
            fixture.advance(to: 0, enabled: true)
            _ = await watchdog.tickForTesting()
            fixture.advance(to: 0.25, enabled: false)
            fixture.script([0.249999, 0.249999, 0.250001])
            var state = await watchdog.tickForTesting()
            XCTAssertNil(state.running)
            fixture.advance(to: 0.3, enabled: true)
            state = await watchdog.tickForTesting()
            XCTAssertEqual(state.running, 1) // Same episode remains eligible, cooldown unconsumed.
            watchdog.shutdown()
            await watchdog.joinForTesting()
        }

        func testOptOutBeforeAdmissionDoesNotStartDriver() async {
            let fixture = DriverFixture()
            let watchdog = CatalogPerfStallWatchdog(
                automatic: false, clock: { fixture.now }, enabled: { fixture.enabled },
                heartbeat: { _ in }, sample: { _ in XCTFail("opted-out child launch")
                    return nil
                }, publish: { _ in }
            )
            watchdog.setActive(true)
            fixture.advance(to: 0, enabled: true)
            _ = await watchdog.tickForTesting()
            fixture.advance(to: 0.25, enabled: false)
            let state = await watchdog.tickForTesting()
            XCTAssertNil(state.running)
            watchdog.shutdown()
            await watchdog.joinForTesting()
        }

        func testReceiptDuringClockReadCannotConsumeAdmission() async {
            let fixture = DriverFixture()
            let watchdog = CatalogPerfStallWatchdog(
                automatic: false, clock: { fixture.clockWithReceipt() }, enabled: { true },
                heartbeat: { fixture.storeHeartbeat($0) }, sample: { _ in nil }, publish: { _ in }
            )
            watchdog.setActive(true)
            _ = await watchdog.tickForTesting()
            fixture.advance(to: 0.27, enabled: true)
            let state = await watchdog.tickForTesting()
            XCTAssertNil(state.running)
            watchdog.shutdown()
        }

        func testReceiptAndWorkerBeginShareOneDecisionLock() {
            let recovered = CatalogPerfStallWatchdog.Acknowledgment()
            recovered.mark()
            XCTAssertFalse(recovered.begin())
            let started = CatalogPerfStallWatchdog.Acknowledgment()
            XCTAssertTrue(started.begin())
            started.mark()
            XCTAssertTrue(started.isReceived)
        }

        func testNamedThreadsCannotBecomeSymbolsAndObjcFramesRemainUseful() throws {
            let raw = """
            Call graph:
              4 Thread_1
                4 start  (in dyld) + 1  [0x1]
              4  Thread_2: Project Atlas  (in App) + 1  [0x1]
                4 @objc App.work()  (in App) + 1  [0x2]  (/private/path.swift:2)
              4 Thread_3: com.apple.NSEventThread
                4 runLoop  (in AppKit) + 56,26  [0x3,0x4]  AppDelegate.swift:33
              4 Thread_<multiple>
                4 anotherSymbol  (in App) + 1  [0x5]
            Total number in stack
            """
            let output = try String(decoding: XCTUnwrap(CatalogPerfStackArtifact.symbols(from: Data(raw.utf8))), as: UTF8.self)
            XCTAssertTrue(output.contains("@objc App.work()"))
            XCTAssertTrue(output.contains("runLoop"))
            for forbidden in ["Thread_", "Atlas", "NSEventThread", "0x", "/private/"] {
                XCTAssertFalse(output.contains(forbidden))
            }
            XCTAssertNil(CatalogPerfStackArtifact.symbols(from: Data(raw.replacingOccurrences(of: "Thread_2:", with: "Thread_broken:").utf8)))
        }

        func testInputAndSymbolOnlyPrivacyBounds() throws {
            let raw = """
            Process: secret [1234]
            Path: /Users/private/workspace
            Call graph:
                92 Thread_1234   DispatchQueue_1: private-session-title (serial)
                  92 start  (in dyld) + 6652  [0x181bb0d7c]
                    92 ???  (in private-image)  load address 0x102e0c000 + 0x740  [0x102e0c740]
                      92 Foo.work()  (in RepoPrompt) + 10  [0x12345]  (/Users/private/File.swift:99)
            Total number in stack (recursive counted multiple, when >=5):
            Binary Images: private
            """
            let data = try XCTUnwrap(CatalogPerfStackArtifact.symbols(from: Data(raw.utf8)))
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "stack\n   start\n     Foo.work()\n")
            for replacement in ["/Users/secret", "bad0x1234", "bad\\path", "1234", "a\"secret\"", "ABCDEF12-1234-1234-abcd-123456789012"] {
                XCTAssertNil(CatalogPerfStackArtifact.symbols(from: Data(raw.replacingOccurrences(of: "Foo.work()", with: replacement).utf8)), replacement)
            }
            XCTAssertNil(CatalogPerfStackArtifact.symbols(from: Data(raw.replacingOccurrences(of: "Foo.work()  (in", with: "malformed (in").utf8)))
            XCTAssertNil(CatalogPerfStackArtifact.symbols(from: Data("Call graph:\nunknown\n".utf8)))
            XCTAssertNil(CatalogPerfStackArtifact.symbols(from: Data(raw.replacingOccurrences(of: "[0x12345]", with: "[0x12345] unknown-suffix").utf8)))
            var input = CatalogPerfStackSample.Input()
            input.append(Data(repeating: 65, count: 8192), standardError: false)
            XCTAssertFalse(input.failed)
            input.append(Data([65]), standardError: false)
            XCTAssertTrue(input.failed)
            input = .init()
            input.append(Data(repeating: 1, count: 64 * 1024), standardError: true)
            XCTAssertTrue(input.stdout.isEmpty)
            XCTAssertFalse(input.failed)
            input.append(Data([1]), standardError: true)
            XCTAssertTrue(input.failed)
            input = .init()
            input.append(Data(repeating: 10, count: 1024 * 1024), standardError: false)
            XCTAssertFalse(input.failed)
            input.append(Data([10]), standardError: false)
            XCTAssertTrue(input.failed)
            let hugeTree = "Call graph:\n  1 Thread_1\n" + String(repeating: "    1 symbol  (in image) + 1  [0x123]\n", count: 10000) + "Total number in stack\n"
            XCTAssertNil(CatalogPerfStackArtifact.symbols(from: Data(hugeTree.utf8)))
        }

        func testArtifactReplacementModesDiskBoundAndSymlinkRefusal() throws {
            let manager = FileManager.default
            let caches = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try manager.createDirectory(at: caches, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: caches) }
            let folder = caches.appendingPathComponent("com.pvncher.repoprompt.ce/CatalogPerfStall")
            let last = folder.appendingPathComponent("last.stacks.txt")
            let pending = folder.appendingPathComponent("pending.stacks.txt")
            let maximum = Data(repeating: 65, count: 64 * 1024)
            let namespace = caches.appendingPathComponent("com.pvncher.repoprompt.ce")
            try manager.createDirectory(at: namespace, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: namespace.path)
            try CatalogPerfStackArtifact.replace(maximum, caches: caches)
            let heldFolder = open(folder.path, O_RDONLY | O_DIRECTORY)
            XCTAssertGreaterThanOrEqual(heldFolder, 0)
            defer { close(heldFolder) }
            XCTAssertEqual(flock(heldFolder, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try CatalogPerfStackArtifact.replace(Data("contender".utf8), caches: caches))
            XCTAssertEqual(try Data(contentsOf: last), maximum)
            XCTAssertEqual(flock(heldFolder, LOCK_UN), 0)
            XCTAssertEqual(try Data(contentsOf: last), maximum)
            XCTAssertEqual(try (manager.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual(try (manager.attributesOfItem(atPath: last.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try maximum.write(to: pending)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
            try CatalogPerfStackArtifact.replace(Data("stack\n symbol\n".utf8), caches: caches)
            XCTAssertEqual(try manager.contentsOfDirectory(atPath: folder.path), ["last.stacks.txt"])
            XCTAssertThrowsError(try CatalogPerfStackArtifact.replace(maximum + Data([1]), caches: caches))
            try manager.createSymbolicLink(at: pending, withDestinationURL: last)
            XCTAssertThrowsError(try CatalogPerfStackArtifact.replace(maximum, caches: caches))
            try manager.removeItem(at: pending)
            try manager.removeItem(at: last)
            try manager.createSymbolicLink(at: last, withDestinationURL: caches.appendingPathComponent("escape"))
            XCTAssertThrowsError(try CatalogPerfStackArtifact.replace(maximum, caches: caches))
            XCTAssertFalse(manager.fileExists(atPath: caches.appendingPathComponent("escape").path))
        }

        private final class DriverFixture: @unchecked Sendable {
            let started = XCTestExpectation(description: "fake driver started")
            private let lock = NSLock()
            private var time: TimeInterval = 0
            private var optIn = false
            private var preferenceReads = 0
            var preferenceReadCount: Int {
                lock.withLock { preferenceReads }
            }

            func readPreference() -> Bool {
                lock.withLock { preferenceReads += 1
                    return optIn
                }
            }

            private var ticket: CatalogPerfStallWatchdog.Ticket?
            private var continuation: CheckedContinuation<Data?, Never>?
            private var publications = 0
            private var times: [TimeInterval] = []
            func script(_ times: [TimeInterval]) {
                lock.withLock { self.times = times }
            }

            func scriptedClock() -> TimeInterval {
                lock.withLock { times.isEmpty ? time : times.removeFirst() }
            }

            private var clockReads = 0
            func clockWithReceipt() -> TimeInterval {
                let observation = lock.withLock { () -> (TimeInterval, (@Sendable () -> Void)?) in
                    if time >= 0.27 { clockReads += 1 }
                    return (time, clockReads == 3 ? heartbeat : nil)
                }
                observation.1?()
                return observation.0
            }

            private var heartbeat: (@Sendable () -> Void)?
            func storeHeartbeat(_ callback: @escaping @Sendable () -> Void) {
                lock.withLock { heartbeat = callback }
            }

            func acknowledge() {
                let callback = lock.withLock { heartbeat }
                callback?()
            }

            var now: TimeInterval {
                lock.withLock { time }
            }

            var enabled: Bool {
                lock.withLock { optIn }
            }

            var ticketIsValid: Bool {
                lock.withLock { ticket?.isValid ?? false }
            }

            var publicationCount: Int {
                lock.withLock { publications }
            }

            func advance(to time: TimeInterval, enabled: Bool) {
                lock.withLock { self.time = time
                    optIn = enabled
                }
            }

            func publish(_ data: Data) {
                lock.withLock { publications += 1 }
            }

            func sample(_ ticket: CatalogPerfStallWatchdog.Ticket) async -> Data? {
                await withCheckedContinuation { continuation in
                    lock.withLock { self.ticket = ticket
                        self.continuation = continuation
                    }
                    started.fulfill()
                }
            }

            func finish() {
                let callback = lock.withLock { let callback = continuation
                    continuation = nil
                    return callback
                }
                callback?.resume(returning: Data("stack\n symbol\n".utf8))
            }
        }
    }
#endif
