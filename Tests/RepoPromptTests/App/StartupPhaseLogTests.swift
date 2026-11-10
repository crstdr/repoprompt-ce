@testable import RepoPromptApp
import RepoPromptInstrumentation
import XCTest

final class StartupPhaseLogTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private let ticks: [TimeInterval]
        private var tickIndex = 0
        private(set) var emissions: [String] = []

        init(ticks: [TimeInterval]) {
            self.ticks = ticks
        }

        func uptime() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            defer { tickIndex += 1 }
            return ticks[min(tickIndex, ticks.count - 1)]
        }

        func emit(_ message: String) {
            lock.lock()
            emissions.append(message)
            lock.unlock()
        }
    }

    override func tearDown() {
        StartupPhaseLog.resetForTesting()
        super.tearDown()
    }

    /// The only values that may reach the unified log are the phase name, boundary,
    /// window ordinal, elapsed/span milliseconds and integer fields -- nothing
    /// user-identifying can appear because no string values are ever rendered.
    func testEmittedMarkersCarryOnlyPhaseDurationsOrdinalsAndCounts() {
        let recorder = Recorder(ticks: [125.0, 125.25, 125.25, 126.0])
        StartupPhaseLog.installForTesting(
            StartupPhaseLog.Runtime(
                uptime: { recorder.uptime() },
                processStartUptime: 100.0,
                emit: { recorder.emit($0) }
            )
        )

        StartupPhaseLog.mark(.windowAttached, window: 2)
        let span = StartupPhaseLog.begin(.windowComposition, window: 2)
        span.end(extraFields: ["entries": 42, "loaded": 40])

        let marker = #/^phase=[a-zA-Z]+ boundary=(begin|end|event)( window=\d+)? elapsed_ms=\d+( span_ms=\d+)?( [a-zA-Z0-9_]+=\d+)*$/#
        let knownPhases = Set(StartupPhaseLog.Phase.allCases.map(\.rawValue))
        var elapsed: [Int] = []
        for line in recorder.emissions {
            XCTAssertNotNil(line.wholeMatch(of: marker), "unexpected marker content: \(line)")
            let phase = line.components(separatedBy: " ")
                .first { $0.hasPrefix("phase=") }
                .map { String($0.dropFirst("phase=".count)) }
            XCTAssertEqual(phase.flatMap { knownPhases.contains($0) ? $0 : nil }, phase)
            let elapsedText = line.components(separatedBy: " ")
                .first { $0.hasPrefix("elapsed_ms=") }?
                .dropFirst("elapsed_ms=".count)
            elapsed.append(elapsedText.flatMap { Int($0) } ?? -1)
        }
        XCTAssertEqual(recorder.emissions.count, 3)
        XCTAssertEqual(elapsed, [25000, 25250, 26000])
        XCTAssertEqual(elapsed, elapsed.sorted())
        XCTAssertEqual(
            recorder.emissions.last,
            "phase=windowComposition boundary=end window=2 elapsed_ms=26000 span_ms=750 entries=42 loaded=40"
        )
    }

    func testAvailableModelEventEmissionBudget() {
        let recorder = Recorder(ticks: [125])
        StartupPhaseLog.installForTesting(.init(
            uptime: { recorder.uptime() }, processStartUptime: 100,
            emit: { recorder.emit($0) }
        ))
        let start = ProcessInfo.processInfo.systemUptime
        for window in 1 ... 36 {
            for _ in 0 ..< 7 {
                StartupPhaseLog.mark(.availableModelsUpdate, window: window, fields: [
                    "duration_ms": 20, "groups": 6, "models": 355,
                    "sameAsPrevious": 1, "trigger": 25
                ])
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(recorder.emissions.count, 252)
        XCTAssertLessThan(elapsed, 0.5)
        print("picker marker emission: lines=252 wall_ms=\(elapsed * 1000)")
    }

    func testRestoreRecorderPreservesStartupLevelsAndAttemptFields() {
        let normal = Recorder(ticks: [125])
        let debug = Recorder(ticks: [125])
        StartupPhaseLog.installForTesting(.init(
            uptime: { normal.uptime() }, processStartUptime: 100,
            emit: { normal.emit($0) }, debugEmit: { debug.emit($0) }
        ))
        let adapter: any WorkspaceRestorePerfRecording = AppWorkspaceRestorePerfRecorder()
        adapter.startupPhase(.oversightLaunchSeed, fields: ["entries": 2, "appended": 2])
        adapter.startupPhase(.oversightDiscoveryCompletion, debug: true, window: 3, fields: ["epoch": 2, "completed": 1])
        let observer = UUID()
        let target = UUID()
        adapter.oversightRestoreAttempt(observer: observer, target: target, outcome: .terminal, reason: "missing")
        adapter.oversightRestoreAttempt(observer: observer, target: target, outcome: .restored)
        XCTAssertEqual(normal.emissions, [
            "phase=oversightLaunchSeed boundary=event elapsed_ms=25000 appended=2 entries=2",
            "phase=oversightRestoreAttempt boundary=event elapsed_ms=25000 observer=\(observer.uuidString) target=\(target.uuidString) outcome=terminal reason=missing",
            "phase=oversightRestoreAttempt boundary=event elapsed_ms=25000 observer=\(observer.uuidString) target=\(target.uuidString) outcome=restored"
        ])
        XCTAssertEqual(debug.emissions, [
            "phase=oversightDiscoveryCompletion boundary=event window=3 elapsed_ms=25000 completed=1 epoch=2"
        ])
    }

    /// A regressed or imprecise start anchor must never emit negative timings.
    func testElapsedAndSpanMillisecondsClampToNonNegative() {
        XCTAssertEqual(StartupPhaseLog.elapsedMilliseconds(now: 42.0, processStart: 100.0), 0)
        XCTAssertEqual(StartupPhaseLog.elapsedMilliseconds(now: 100.4, processStart: 100.0), 400)
        XCTAssertEqual(StartupPhaseLog.spanMilliseconds(from: 10.5, to: 10.0), 0)
        XCTAssertEqual(StartupPhaseLog.spanMilliseconds(from: 10.0, to: 10.75), 750)
    }

    /// The span clock starts after begin emission returns, so a cold or descheduled
    /// emitter is charged to the marker path, not the measured phase. Here emission
    /// consumes 4.4s of the scripted clock; span_ms must exclude it while the begin
    /// line still records the request-time elapsed_ms.
    func testSpanClockStartsAfterBeginEmission() {
        let recorder = Recorder(ticks: [125.0, 129.4, 131.0])
        StartupPhaseLog.installForTesting(
            StartupPhaseLog.Runtime(
                uptime: { recorder.uptime() },
                processStartUptime: 100.0,
                emit: { recorder.emit($0) }
            )
        )

        let span = StartupPhaseLog.begin(.appInit)
        span.end()

        XCTAssertEqual(
            recorder.emissions,
            [
                "phase=appInit boundary=begin elapsed_ms=25000",
                "phase=appInit boundary=end elapsed_ms=31000 span_ms=1600"
            ]
        )
    }

    func testAppInitSubphaseRenderingAndNesting() {
        let recorder = Recorder(ticks: [125])
        StartupPhaseLog.installForTesting(.init(
            uptime: { recorder.uptime() }, processStartUptime: 100,
            emit: { recorder.emit($0) }
        ))
        let outer = StartupPhaseLog.begin(.appInit)
        for phase: StartupPhaseLog.Phase in [
            .appLoggingBootstrap, .appUIStateSetup, .appTelemetryBootstrap,
            .appRecorderInstallation, .appWindowManagerInit, .appWindowSessionLoadSchedule
        ] {
            let span = StartupPhaseLog.begin(phase)
            span.end()
        }
        outer.end()
        XCTAssertEqual(recorder.emissions.first, "phase=appInit boundary=begin elapsed_ms=25000")
        XCTAssertEqual(recorder.emissions.last, "phase=appInit boundary=end elapsed_ms=25000 span_ms=0")
        XCTAssertEqual(recorder.emissions.count, 14)
    }

    func testSearchResetReportsCompletionBeforeCallerResumes() async throws {
        let search = WorkspaceSearchService()
        let started = ProcessInfo.processInfo.systemUptime
        let result = await search.reset(measureCompletion: true)
        let completed = try XCTUnwrap(result)
        let resumed = ProcessInfo.processInfo.systemUptime
        XCTAssertGreaterThanOrEqual(completed, started)
        XCTAssertLessThanOrEqual(completed, resumed)
        let unmeasured = await search.reset()
        XCTAssertNil(unmeasured)
    }

    @MainActor
    func testReplayAttributionIsBoundedAcrossWindowOrdinals() async {
        let recorder = Recorder(ticks: [125])
        StartupPhaseLog.installForTesting(.init(
            uptime: { recorder.uptime() }, processStartUptime: 100,
            emit: { recorder.emit($0) }
        ))
        // This exercises file-state methods with synthetic tabs; it does not create real windows
        // or claim end-to-end restore coverage.
        let windows = (1 ... 36).map { window in
            let tabs = (0 ..< (window <= 12 ? 9 : 8)).map { tab in
                ComposeTabState(
                    activeChatSessionID: UUID(),
                    selection: StoredSelection(codemapAutoEnabled: false),
                    expandedFolders: (0 ..< 8).map { "missing-\(window)-\(tab)-\($0)" }
                )
            }
            return (WorkspaceFilesViewModel(workspaceFileContextStore: WorkspaceFileContextStore(), restorePerfRecorder: AppWorkspaceRestorePerfRecorder()), tabs)
        }
        XCTAssertEqual(windows.reduce(0) { $0 + $1.1.count }, 300)
        for (files, tabs) in windows {
            files.onActiveTabChangedFast(tabs[0])
        }
        let baselineStart = Date()
        for (files, tabs) in windows {
            await files.withDeferredSelectionSliceSnapshotRebuild(reason: "test") {
                await files.restoreExpansionState(from: tabs[0].expandedFolders)
                await files.onActiveTabChangedHeavy(for: tabs[0].id, selection: tabs[0].selection)
            }
        }
        let baseline = Date().timeIntervalSince(baselineStart)
        let started = Date()
        for (index, entry) in windows.enumerated() {
            let window = index + 1
            await entry.0.withDeferredSelectionSliceSnapshotRebuild(reason: "test", startupAttributionWindow: window) {
                await entry.0.restoreExpansionState(from: entry.1[0].expandedFolders, startupAttributionWindow: window)
                await entry.0.onActiveTabChangedHeavy(
                    for: entry.1[0].id, selection: entry.1[0].selection, startupAttributionWindow: window
                )
            }
        }
        let traced = Date().timeIntervalSince(started)
        print("Startup attribution synthetic baseline_s=\(baseline) traced_s=\(traced)")
        XCTAssertLessThan(traced, 5)
        XCTAssertEqual(recorder.emissions.count, 36 * 8)
        let phases = ["switchReplayExpansion", "switchReplaySelectionApply", "switchReplaySliceHydration", "switchReplayDeferredFlush"]
        for window in 1 ... 36 {
            let lines = recorder.emissions.filter { $0.contains(" window=\(window) ") }
            guard lines.count == 8 else {
                XCTFail("Expected eight replay markers for window \(window), got \(lines.count)")
                continue
            }
            for (index, phase) in phases.enumerated() {
                XCTAssertTrue(lines[index * 2].contains("phase=\(phase) boundary=begin"))
                XCTAssertTrue(lines[index * 2 + 1].contains("phase=\(phase) boundary=end"))
            }
            XCTAssertTrue(lines.allSatisfy { !$0.contains("missing-") })
        }
        XCTAssertEqual(recorder.emissions.count(where: { $0.contains("phase=switchReplayExpansion boundary=end") }), 36)
        XCTAssertEqual(recorder.emissions.count(where: { $0.contains("phase=switchReplaySliceHydration boundary=end") }), 36)
        XCTAssertTrue(
            recorder.emissions.filter { $0.contains("phase=switchReplayExpansion boundary=end") }
                .allSatisfy { $0.contains("requestedFolders=8") && $0.contains("outcome=3") }
        )
        XCTAssertTrue(
            recorder.emissions.filter { $0.contains("phase=switchReplaySliceHydration boundary=end") }
                .allSatisfy { $0.contains("outcome=6") && $0.contains("workers=0") }
        )
    }

    func testProductionLoggerAttributionEmissionBudget() {
        // The test binary is Debug; reset the seam to measure the actual unified-log sink.
        // This isolates marker emission, not end-to-end Release restore overhead.
        StartupPhaseLog.resetForTesting()
        let phases: [StartupPhaseLog.Phase] = [
            .switchSearchReset, .switchCanonicalRootRefresh, .switchAuthorityClassification,
            .switchSavedMarkerLookup, .switchHydrationSpawn, .switchRestoreStateYield,
            .switchReplayExpansion, .switchReplaySelectionApply, .switchReplaySliceHydration,
            .switchReplaySelectionFence, .switchReplayDeferredFlush
        ]
        let started = ProcessInfo.processInfo.systemUptime
        for window in 1 ... 36 {
            for phase in phases {
                StartupPhaseLog.begin(phase, window: window).end(extraFields: [
                    "count": 8, "outcome": 1, "workerResumeDelayMs": 0
                ])
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print("Startup attribution unified_log_marker_emission_s=\(elapsed) lines=792")
        XCTAssertLessThan(elapsed, 0.5)
    }

    @MainActor
    func testNestedFlushAndStaleReplayRemainBalanced() async {
        let recorder = Recorder(ticks: [125])
        StartupPhaseLog.installForTesting(.init(
            uptime: { recorder.uptime() }, processStartUptime: 100,
            emit: { recorder.emit($0) }
        ))
        let files = WorkspaceFilesViewModel(workspaceFileContextStore: WorkspaceFileContextStore(), restorePerfRecorder: AppWorkspaceRestorePerfRecorder())
        await files.withDeferredSelectionSliceSnapshotRebuild(reason: "outer") {
            await files.withDeferredSelectionSliceSnapshotRebuild(reason: "inner", startupAttributionWindow: 1) {
                files.onActiveTabChangedFast(ComposeTabState())
            }
        }
        await files.withDeferredSelectionSliceSnapshotRebuild(reason: "verify", startupAttributionWindow: 3) {}
        await files.onActiveTabChangedHeavy(for: UUID(), selection: StoredSelection(), startupAttributionWindow: 2)
        XCTAssertEqual(recorder.emissions.count, 8)
        XCTAssertTrue(recorder.emissions[1].contains("phase=switchReplayDeferredFlush boundary=end"))
        XCTAssertTrue(recorder.emissions[1].contains("nested=1"))
        XCTAssertTrue(recorder.emissions[1].contains("pending=1"))
        XCTAssertTrue(recorder.emissions[3].contains("pending=0"))
        XCTAssertTrue(recorder.emissions[5].contains("phase=switchReplaySelectionApply boundary=end"))
        XCTAssertTrue(recorder.emissions[5].contains("outcome=5"))
        XCTAssertTrue(recorder.emissions[7].contains("phase=switchReplaySliceHydration boundary=end"))
        XCTAssertTrue(recorder.emissions[7].contains("outcome=5"))
    }

    #if DEBUG
        @MainActor
        func testSelectionBecomingStaleAfterApplyEmitsStaleOutcome() async {
            let recorder = Recorder(ticks: [125])
            StartupPhaseLog.installForTesting(.init(
                uptime: { recorder.uptime() }, processStartUptime: 100,
                emit: { recorder.emit($0) }
            ))
            let files = WorkspaceFilesViewModel(
                workspaceFileContextStore: WorkspaceFileContextStore(), restorePerfRecorder: AppWorkspaceRestorePerfRecorder()
            )
            let oldTab = ComposeTabState(selection: StoredSelection(codemapAutoEnabled: false))
            let newTab = ComposeTabState(selection: StoredSelection(codemapAutoEnabled: false))
            files.onActiveTabChangedFast(oldTab)
            files.startupAfterSelectionForTesting = { [weak files] in files?.onActiveTabChangedFast(newTab) }
            defer { files.startupAfterSelectionForTesting = nil }
            await files.onActiveTabChangedHeavy(for: oldTab.id, selection: oldTab.selection, startupAttributionWindow: 1)
            XCTAssertEqual(recorder.emissions.count, 4)
            XCTAssertTrue(recorder.emissions[1].contains("phase=switchReplaySelectionApply boundary=end"))
            XCTAssertTrue(recorder.emissions[1].contains("outcome=5"))
            XCTAssertTrue(recorder.emissions[3].contains("phase=switchReplaySliceHydration boundary=end"))
            XCTAssertTrue(recorder.emissions[3].contains("outcome=5"))
        }
    #endif

    @MainActor
    func testCancelledReplayEmitsBalancedSelectionAndSkippedSliceMarkers() async {
        let recorder = Recorder(ticks: [125])
        StartupPhaseLog.installForTesting(.init(
            uptime: { recorder.uptime() }, processStartUptime: 100,
            emit: { recorder.emit($0) }
        ))
        let files = WorkspaceFilesViewModel(workspaceFileContextStore: WorkspaceFileContextStore(), restorePerfRecorder: AppWorkspaceRestorePerfRecorder())
        let tab = ComposeTabState(selection: StoredSelection(codemapAutoEnabled: false))
        files.onActiveTabChangedFast(tab)
        let operation = Task { @MainActor in
            await files.onActiveTabChangedHeavy(for: tab.id, selection: tab.selection, startupAttributionWindow: 1)
        }
        operation.cancel()
        await operation.value
        XCTAssertEqual(recorder.emissions.count, 4)
        XCTAssertTrue(recorder.emissions[1].contains("phase=switchReplaySelectionApply boundary=end"))
        XCTAssertTrue(recorder.emissions[1].contains("outcome=4"))
        XCTAssertTrue(recorder.emissions[3].contains("phase=switchReplaySliceHydration boundary=end"))
        XCTAssertTrue(recorder.emissions[3].contains("outcome=4"))
    }

    @MainActor
    func testExpansionMarkerCountDoesNotScaleWithPaths() async {
        let recorder = Recorder(ticks: [125])
        StartupPhaseLog.installForTesting(.init(
            uptime: { recorder.uptime() }, processStartUptime: 100,
            emit: { recorder.emit($0) }
        ))
        let files = WorkspaceFilesViewModel(workspaceFileContextStore: WorkspaceFileContextStore(), restorePerfRecorder: AppWorkspaceRestorePerfRecorder())
        await files.restoreExpansionState(from: ["missing"], startupAttributionWindow: 1)
        await files.restoreExpansionState(from: (0 ..< 300).map { "missing-\($0)" }, startupAttributionWindow: 2)
        XCTAssertEqual(recorder.emissions.count, 4)
        XCTAssertTrue(recorder.emissions[1].contains("requestedFolders=1"))
        XCTAssertTrue(recorder.emissions[3].contains("requestedFolders=300"))
        XCTAssertTrue(recorder.emissions.allSatisfy { !$0.contains("missing") })
    }

    #if DEBUG
        @MainActor
        func testReplayAttributionWithRealSelectionAndSliceWorker() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(enableStartupAttribution: true) { fixture in
                let selected = fixture.rootPaths[0] + "/README.md"
                let manual = fixture.rootPaths[1] + "/README.md"
                try await fixture.selectFixtureFiles([selected])
                let tabID = try XCTUnwrap(fixture.workspace.activeComposeTabID)
                let tab = ComposeTabState(
                    id: tabID,
                    selection: StoredSelection(
                        selectedPaths: [selected], manualCodemapPaths: [manual],
                        slices: [selected: [.init(start: 1, end: 1)]], codemapAutoEnabled: false
                    ),
                    expandedFolders: [fixture.rootPaths[0]]
                )
                fixture.files.onActiveTabChangedFast(tab)
                let recorder = Recorder(ticks: [125])
                StartupPhaseLog.installForTesting(.init(
                    uptime: { recorder.uptime() }, processStartUptime: 100,
                    emit: { recorder.emit($0) }
                ))
                defer { StartupPhaseLog.resetForTesting() }
                await fixture.files.withDeferredSelectionSliceSnapshotRebuild(reason: "test", startupAttributionWindow: 1) {
                    await fixture.files.restoreExpansionState(from: tab.expandedFolders, startupAttributionWindow: 1)
                    await fixture.files.onActiveTabChangedHeavy(for: tab.id, selection: tab.selection, startupAttributionWindow: 1)
                }
                let selection = try XCTUnwrap(recorder.emissions.first { $0.contains("phase=switchReplaySelectionApply boundary=end") })
                XCTAssertTrue(selection.contains("requestedSelectedPaths=1"))
                XCTAssertTrue(selection.contains("requestedManualCodemaps=1"))
                XCTAssertTrue(selection.contains("requestedSliceFiles=1"))
                XCTAssertTrue(selection.contains("requestedSliceRanges=1"))
                let slices = try XCTUnwrap(recorder.emissions.first { $0.contains("phase=switchReplaySliceHydration boundary=end") })
                XCTAssertTrue(slices.contains("workers=1"))
                XCTAssertTrue(slices.contains("workerResumeDelayMs="))
                XCTAssertFalse(recorder.emissions.contains { $0.contains("README") || $0.contains(fixture.rootPaths[0]) })

                fixture.files.startupBeforeSlicePersistenceForTesting = {
                    throw NSError(domain: "StartupPhaseLogTests", code: 1)
                }
                defer { fixture.files.startupBeforeSlicePersistenceForTesting = nil }
                let replacement = StoredSelection(
                    selectedPaths: [selected], slices: [selected: [.init(start: 1, end: 2)]], codemapAutoEnabled: false
                )
                await fixture.files.hydrateSlicesForActiveTab(from: replacement, startupAttributionWindow: 2)
                let failed = try XCTUnwrap(recorder.emissions.first {
                    $0.contains("phase=switchReplaySliceHydration boundary=end window=2 ")
                })
                XCTAssertTrue(failed.contains("outcome=8"))
                XCTAssertTrue(failed.contains("failedPersistRoots=1"))

                fixture.files.startupBeforeSlicePersistenceForTesting = nil
                let successor = ComposeTabState(selection: StoredSelection(codemapAutoEnabled: false))
                fixture.files.startupAfterSlicePersistenceForTesting = { [weak files = fixture.files] in
                    files?.onActiveTabChangedFast(successor)
                }
                defer { fixture.files.startupAfterSlicePersistenceForTesting = nil }
                await fixture.files.hydrateSlicesForActiveTab(from: replacement, startupAttributionWindow: 3)
                let stale = try XCTUnwrap(recorder.emissions.first {
                    $0.contains("phase=switchReplaySliceHydration boundary=end window=3 ")
                })
                XCTAssertTrue(stale.contains("outcome=5"))
                XCTAssertTrue(stale.contains("workers=1"))
            }
        }

        @MainActor
        func testSavedMarkerBecomingStaleAfterWorkerIsRecorded() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(enableStartupAttribution: true) { fixture in
                let manager = try XCTUnwrap(fixture.manager)
                let other = try await fixture.createAdditionalWorkspace(name: "Other", repoPaths: [fixture.rootPaths[0]])
                _ = await manager.switchWorkspace(to: other, saveState: false)
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -944)
                let beforeSnapshot = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                let before = try XCTUnwrap(beforeSnapshot)
                var working = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
                working.currentPromptText = "Modified working state"
                _ = try await client.replaceWorking(
                    working, fileURL: before.document.fileURL,
                    expectedWorkspaceRevision: before.revisions.workingRevision
                )
                try await fixture.settle()
                let target = try XCTUnwrap(manager.workspace(withID: fixture.workspace.id))
                let recorder = Recorder(ticks: [125])
                StartupPhaseLog.installForTesting(.init(
                    uptime: { recorder.uptime() }, processStartUptime: 100,
                    emit: { recorder.emit($0) }
                ))
                defer { StartupPhaseLog.resetForTesting() }
                manager.afterAuthorityRestoreSavedReadForTesting = { _ in
                    manager.cancelAuthorityRestoreClassificationForTesting()
                }
                defer { manager.afterAuthorityRestoreSavedReadForTesting = nil }
                _ = await manager.switchWorkspace(to: target, saveState: false)
                let markers = recorder.emissions.filter { $0.contains("phase=switchSavedMarkerLookup ") }
                XCTAssertEqual(markers.count, 2)
                let end = try XCTUnwrap(markers.first { $0.contains("boundary=end") })
                XCTAssertTrue(end.contains("outcome=5"))
                XCTAssertTrue(end.contains("workers=1"))
                XCTAssertTrue(end.contains("workerResumeDelayMs="))
                XCTAssertEqual(manager.activeWorkspaceID, other.id)
            }
        }

        @MainActor
        func testRealWorkspaceSwitchEmitsAttributionInOrder() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(enableStartupAttribution: true) { fixture in
                let other = try await fixture.createAdditionalWorkspace(name: "Other", repoPaths: [fixture.rootPaths[0]])
                _ = await fixture.manager.switchWorkspace(to: other, saveState: false)
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -944)
                let beforeSnapshot = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                let before = try XCTUnwrap(beforeSnapshot)
                var working = try XCTUnwrap(fixture.manager.workspace(withID: fixture.workspace.id))
                working.currentPromptText = "Modified working state"
                _ = try await client.replaceWorking(
                    working, fileURL: before.document.fileURL,
                    expectedWorkspaceRevision: before.revisions.workingRevision
                )
                try await fixture.settle()
                let recorder = Recorder(ticks: [125])
                StartupPhaseLog.installForTesting(.init(
                    uptime: { recorder.uptime() }, processStartUptime: 100,
                    emit: { recorder.emit($0) }
                ))
                defer { StartupPhaseLog.resetForTesting() }
                let target = try XCTUnwrap(fixture.manager.workspace(withID: fixture.workspace.id))
                _ = await fixture.manager.switchWorkspace(to: target, saveState: false)
                XCTAssertEqual(fixture.manager.activeWorkspaceID, target.id)
                let phases: [StartupPhaseLog.Phase] = [
                    .switchSearchReset, .switchCanonicalRootRefresh, .switchAuthorityClassification,
                    .switchHydrationSpawn, .switchRestoreStateYield,
                    .switchReplayExpansion, .switchReplaySelectionApply, .switchReplaySliceHydration,
                    .switchReplaySelectionFence, .switchReplayDeferredFlush
                ]
                var previousIndex = -1
                for phase in phases {
                    let matching = recorder.emissions.enumerated().filter {
                        $0.element.contains("phase=\(phase.rawValue) ") && $0.element.contains(" window=-944 ")
                    }
                    XCTAssertEqual(matching.count, 2, "Expected one begin/end pair for \(phase.rawValue)")
                    let begin = try XCTUnwrap(matching.first { $0.element.contains("boundary=begin") })
                    let end = try XCTUnwrap(matching.first { $0.element.contains("boundary=end") })
                    XCTAssertGreaterThan(begin.offset, previousIndex, "\(phase.rawValue) begins out of order")
                    XCTAssertGreaterThan(end.offset, begin.offset, "\(phase.rawValue) did not end")
                    if phase == .switchSearchReset {
                        XCTAssertTrue(end.element.contains("actorResumeDelayMs="))
                    }
                    if phase == .switchReplaySliceHydration {
                        XCTAssertTrue(end.element.contains("workers=1"))
                        XCTAssertTrue(end.element.contains("workerResumeDelayMs="))
                    }
                    previousIndex = end.offset
                }
                let markerLines = recorder.emissions.filter {
                    $0.contains("phase=switchSavedMarkerLookup ") && $0.contains(" window=-944 ")
                }
                XCTAssertEqual(markerLines.count, 2)
                let markerEnd = try XCTUnwrap(markerLines.first { $0.contains("boundary=end") })
                XCTAssertTrue(markerEnd.contains("markerState=2"))
                XCTAssertTrue(markerEnd.contains("outcome=1"))
                XCTAssertTrue(markerEnd.contains("workers=1"))
                XCTAssertTrue(markerEnd.contains("workerResumeDelayMs="))
            }
        }
    #endif

    /// Phase names are fixed enum raw values -- letters only -- so no call site can
    /// interpolate names or identifiers into a marker.
    func testPhaseRawValuesAreFixedLetterOnlyNames() {
        for phase in StartupPhaseLog.Phase.allCases {
            XCTAssertNotNil(
                phase.rawValue.wholeMatch(of: #/^[a-zA-Z]+$/#),
                "phase name must be letters only: \(phase.rawValue)"
            )
        }
    }

    /// The restore span records the switch request's actual outcome as a bounded
    /// integer code, not a discarded result or a logged string.
    func testSwitchOutcomeMappingCoversEverySwitchResult() {
        XCTAssertEqual(StartupPhaseLog.SwitchOutcome(.switched), .accepted)
        XCTAssertEqual(StartupPhaseLog.SwitchOutcome(.blocked("busy")), .blocked)
        XCTAssertEqual(StartupPhaseLog.SwitchOutcome(.cancelled("superseded")), .cancelled)
        XCTAssertEqual(
            Set(
                [
                    StartupPhaseLog.SwitchOutcome.accepted.rawValue,
                    StartupPhaseLog.SwitchOutcome.blocked.rawValue,
                    StartupPhaseLog.SwitchOutcome.cancelled.rawValue
                ]
            ).count,
            3
        )
    }
}
