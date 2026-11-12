#if DEBUG
    @testable import RepoPromptApp
    import RepoPromptSettingsCore
    import XCTest

    @MainActor
    final class WindowSessionUnclaimedEntriesTests: XCTestCase {
        private let defaultsKey = "autoRestoreWorkspacesEnabled_v2"

        private final class CleanupState {
            var journeyFinished = false
        }

        private func entries() -> [WindowSessionEntry] {
            let repeated = UUID()
            return (0 ..< 36).map { index in
                let id: UUID? = switch index {
                case 2, 3: nil
                case 4, 5: repeated
                default: UUID()
                }
                return WindowSessionEntry(
                    windowKind: index.isMultiple(of: 2) ? .standard : .contextBuilder,
                    workspaceID: id,
                    workspaceName: index < 2 ? "Missing-\(id!.uuidString)" : (index.isMultiple(of: 4) ? nil : "Slot-\(index)"),
                    isSystemWorkspace: index == 2,
                    isEphemeral: false,
                    primaryRepoPath: index.isMultiple(of: 2) ? nil : "/missing/slot-\(index)",
                    lastFocused: index == 0,
                    workspaceInstanceNumber: index.isMultiple(of: 3) ? nil : index + 1,
                    mcpToolsEnabled: index < 2 ? false : (index.isMultiple(of: 3) ? nil : index.isMultiple(of: 2))
                )
            }
        }

        private func data(_ snapshot: WindowSessionSnapshot) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(snapshot)
        }

        private func assertSnapshot(_ snapshot: WindowSessionSnapshot, equals expected: [WindowSessionEntry], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(snapshot.version, 4, file: file, line: line)
            XCTAssertEqual(snapshot.windows.count, expected.count, file: file, line: line)
            for (actual, wanted) in zip(snapshot.windows, expected) {
                XCTAssertEqual(actual.windowKind, wanted.windowKind, file: file, line: line)
                XCTAssertEqual(actual.workspaceID, wanted.workspaceID, file: file, line: line)
                XCTAssertEqual(actual.workspaceName, wanted.workspaceName, file: file, line: line)
                XCTAssertEqual(actual.isSystemWorkspace, wanted.isSystemWorkspace, file: file, line: line)
                XCTAssertEqual(actual.isEphemeral, wanted.isEphemeral, file: file, line: line)
                XCTAssertEqual(actual.primaryRepoPath, wanted.primaryRepoPath, file: file, line: line)
                XCTAssertEqual(actual.lastFocused, wanted.lastFocused, file: file, line: line)
                XCTAssertEqual(actual.workspaceInstanceNumber, wanted.workspaceInstanceNumber, file: file, line: line)
                XCTAssertEqual(actual.mcpToolsEnabled, wanted.mcpToolsEnabled, file: file, line: line)
            }
        }

        func testBuilderPreservesUnclaimedSlotsAndExistingFiltering() throws {
            let saved = entries()
            let candidates = (0 ..< 5).map { WindowSessionCaptureCandidate(windowID: $0, entry: saved[$0]) }
            let combined = WindowSessionSnapshotBuilder.build(version: 4, candidates: candidates, excludedWindowIDs: [], unclaimedEntries: Array(saved.dropFirst(5)))
            assertSnapshot(combined, equals: saved)
            try assertSnapshot(JSONDecoder().decode(WindowSessionSnapshot.self, from: data(combined)), equals: saved)
            let closed = WindowSessionSnapshotBuilder.build(version: 4, candidates: candidates, excludedWindowIDs: [1], unclaimedEntries: Array(saved.dropFirst(5)))
            assertSnapshot(closed, equals: saved.enumerated().filter { $0.offset != 1 }.map(\.element))
            let oldCandidates = [candidates[2], WindowSessionCaptureCandidate(windowID: 10, entry: nil), candidates[0]]
            let prior = WindowSessionSnapshot(version: 4, windows: [saved[2], saved[0]])
            let omitted = WindowSessionSnapshotBuilder.build(version: 4, candidates: oldCandidates, excludedWindowIDs: [])
            let empty = WindowSessionSnapshotBuilder.build(version: 4, candidates: oldCandidates, excludedWindowIDs: [], unclaimedEntries: [])
            XCTAssertEqual(try data(omitted), try data(prior))
            XCTAssertEqual(try data(empty), try data(prior))
        }

        private func waitUntil(_ stage: String, condition: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition() {
                guard Date() < deadline else { throw NSError(domain: "WindowSessionUnclaimedEntriesTests.\(stage)", code: 1) }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }

        private func read(_ url: URL) -> WindowSessionSnapshot? {
            guard let contents = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(WindowSessionSnapshot.self, from: contents)
        }

        private func sentinel(_ url: URL) throws {
            try data(WindowSessionSnapshot(version: 4, windows: [])).write(to: url, options: .atomic)
        }

        private func waitForWrite(_ url: URL, stage: String) async throws -> WindowSessionSnapshot {
            try await waitUntil(stage) { self.read(url)?.windows.isEmpty == false }
            return try XCTUnwrap(read(url))
        }

        private func makeWindow(_ manager: WindowStatesManager, missing: UUID) async throws -> WindowState {
            let window = WindowState(automaticProviderModelDiscoveryEnabled: false)
            await window.workspaceManager.awaitInitialWorkspaceActivationCompletion()
            await window.workspaceManager.awaitInitialized()
            XCTAssertTrue(window.workspaceManager.activeWorkspace == nil || window.workspaceManager.activeWorkspace?.isSystemWorkspace == true)
            XCTAssertTrue(window.workspaceManager.hasAcceptedDomainCatalogForRestoration)
            XCTAssertNil(window.workspaceManager.workspace(withID: missing))
            window.windowStatesManager = manager
            return window
        }

        private func waitForClaim(_ window: WindowState, expected: WindowSessionEntry) async throws {
            try await waitUntil("claim") {
                window.protectedRestoreEntryForTesting?.workspaceID == expected.workspaceID &&
                    !window.hasUnfinishedRestoreExecution && !window.hasPendingRestoreEntryForTesting
            }
            let entry = try XCTUnwrap(window.protectedRestoreEntryForTesting)
            assertSnapshot(WindowSessionSnapshot(version: 4, windows: [entry]), equals: [expected])
        }

        func testGraceLateCloseAndRestartRetainUnclaimedEntries() async throws {
            let saved = entries()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("windowSessions.json")
            try data(WindowSessionSnapshot(version: 4, windows: saved)).write(to: url, options: .atomic)
            let previous = UserDefaults.standard.object(forKey: defaultsKey)
            let previousMCP = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            var openerCount = 0
            AppWindowOpener.shared.resetForTesting()
            AppWindowOpener.shared.installForTesting { openerCount += 1 }
            var managers: [WindowStatesManager] = []
            var windows: [(WindowStatesManager, WindowState)] = []
            let cleanup = CleanupState()
            addTeardownBlock { @MainActor in
                for manager in managers {
                    manager.releaseLeftoverRestoreEntryGateAfterGraceForTesting()
                    await manager.persistWindowSessionImmediately(reason: "test cleanup")
                    manager.setTerminatingForTesting(true)
                    for (_, window) in windows where window.windowStatesManager === manager {
                        manager.unregisterWindowState(window)
                        await window.tearDown()
                    }
                    manager.setTerminatingForTesting(false)
                }
                AppWindowOpener.shared.resetForTesting()
                GlobalSettingsStore.shared.setMCPAutoStart(previousMCP, commit: false)
                if let previous { UserDefaults.standard.set(previous, forKey: self.defaultsKey) }
                else { UserDefaults.standard.removeObject(forKey: self.defaultsKey) }
                if cleanup.journeyFinished {
                    try? FileManager.default.removeItem(at: directory)
                }
            }

            var manager = WindowStatesManager.makeForTesting(windowSessionFileURL: url)
            managers.append(manager)
            manager.autoRestoreWorkspacesEnabled = true
            var first = try await makeWindow(manager, missing: XCTUnwrap(saved[0].workspaceID))
            windows.append((manager, first))
            manager.loadWindowRestoreSessionIfNeeded()
            manager.registerWindowState(first)
            try await waitForClaim(first, expected: saved[0])
            XCTAssertEqual(manager.agentSessionOversightRestoreTopologyState, .pending)
            try sentinel(url)
            manager.releaseLeftoverRestoreEntryGateAfterGraceForTesting()
            try await waitUntil("grace") { manager.agentSessionOversightRestoreTopologyState == .incompleteLeftoversAbandoned(count: 35) }
            try await assertSnapshot(waitForWrite(url, stage: "grace write"), equals: saved)
            try sentinel(url)
            await manager.persistWindowSessionImmediately(reason: "test quit snapshot")
            try await assertSnapshot(waitForWrite(url, stage: "immediate write"), equals: saved)

            manager.setTerminatingForTesting(true)
            manager.unregisterWindowState(first)
            await first.tearDown()
            manager.setTerminatingForTesting(false)
            windows.removeAll { $0.1 === first }
            managers.removeAll { $0 === manager }
            try assertSnapshot(XCTUnwrap(read(url)), equals: saved)

            manager = WindowStatesManager.makeForTesting(windowSessionFileURL: url)
            managers.append(manager)
            manager.autoRestoreWorkspacesEnabled = true
            first = try await makeWindow(manager, missing: XCTUnwrap(saved[0].workspaceID))
            windows.append((manager, first))
            manager.loadWindowRestoreSessionIfNeeded()
            manager.registerWindowState(first)
            try await waitForClaim(first, expected: saved[0])
            try sentinel(url)
            manager.releaseLeftoverRestoreEntryGateAfterGraceForTesting()
            try await waitUntil("restart grace") { manager.agentSessionOversightRestoreTopologyState == .incompleteLeftoversAbandoned(count: 35) }
            try await assertSnapshot(waitForWrite(url, stage: "restart write"), equals: saved)

            let second = try await makeWindow(manager, missing: XCTUnwrap(saved[1].workspaceID))
            windows.append((manager, second))
            try sentinel(url)
            manager.registerWindowState(second)
            try await waitForClaim(second, expected: saved[1])
            try await assertSnapshot(waitForWrite(url, stage: "late registration"), equals: saved)
            XCTAssertEqual(manager.agentSessionOversightRestoreTopologyState, .incompleteLeftoversAbandoned(count: 35))
            try sentinel(url)
            second.beginClose()
            let remaining = saved.enumerated().filter { $0.offset != 1 }.map(\.element)
            try await assertSnapshot(waitForWrite(url, stage: "explicit close"), equals: remaining)
            try sentinel(url)
            manager.unregisterWindowState(second)
            try await assertSnapshot(waitForWrite(url, stage: "unregister"), equals: remaining)
            await second.tearDown()
            windows.removeAll { $0.1 === second }
            XCTAssertEqual(openerCount, 0)
            cleanup.journeyFinished = true
        }
    }
#endif
