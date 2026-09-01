import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

final class MCPAgentPolicyAdmissionRaceTests: XCTestCase {
    private let manager = ServerNetworkManager.shared
    private let clientName = AgentProviderKind.openCodeMCPClientID

    override func tearDown() async throws {
        #if DEBUG
            await manager.debugResumePendingPolicyObservation()
            await manager.debugResumePendingPolicyRouteInstallation()
            await manager.debugResumePendingPolicyCommit()
            await manager.debugResumeConfirmOrFence()
            await manager.debugResumeConfirmOrFenceBeforeRevocation()
            await manager.debugResumeRunCatalogPublicationBeforeMainActor()
        #endif
        try await super.tearDown()
    }

    func testHelperIdentityTransitionWaitsForLateExpectedPIDRegistration() async throws {
        #if DEBUG
            let processTree = try makeSleepingProcessTree()
            defer { processTree.terminate() }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61001
            await installPolicy(runID: runID, windowID: windowID)
            await manager.debugClearRunRoutingHistoryForTesting()

            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(processTree.childPID),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 1.0,
                    requireRunRouting: false
                )
            }

            let waitStarted = await waitForEvent("pid_gate_wait_started", runID: runID)
            XCTAssertTrue(waitStarted)
            await manager.registerExpectedAgentPID(processTree.parentPID, for: clientName, runID: runID)
            let result = await application.value

            XCTAssertEqual(result.outcome, "applied")
            XCTAssertEqual(result.runID, runID)
            XCTAssertEqual(result.windowID, windowID)
            let mappedRunID = await manager.runIDForConnection(connectionID)
            let waitCompleted = await waitForEvent("pid_gate_wait_completed", runID: runID)
            let policyApplied = await waitForEvent("policy_applied", runID: runID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(mappedRunID, runID)
            XCTAssertTrue(waitCompleted)
            XCTAssertTrue(policyApplied)
            XCTAssertFalse(pending.contains { $0.runID == runID })

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: processTree.parentPID
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testWrongPIDCannotConsumeRunPolicy() async throws {
        #if DEBUG
            let expectedTree = try makeSleepingProcessTree()
            let unrelatedTree = try makeSleepingProcessTree()
            defer {
                expectedTree.terminate()
                unrelatedTree.terminate()
            }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61002
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(expectedTree.parentPID, for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(unrelatedTree.childPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "rejected:ownership_timeout")
            let mappedRunID = await manager.runIDForConnection(connectionID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertNil(mappedRunID)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: expectedTree.parentPID
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testWrongClientCannotConsumeOpenCodePolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61003
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: "unrelated-client",
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "fallback")
            let mappedRunID = await manager.runIDForConnection(connectionID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertNil(mappedRunID)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(runID: runID, connectionID: connectionID, windowID: windowID, expectedPID: getpid())
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testParallelSameProviderRunsConsumeOnlyTheirRunSpecificPIDPolicy() async throws {
        #if DEBUG
            let firstProcess = try makeSleepingProcessTree()
            let secondProcess = try makeSleepingProcessTree()
            defer {
                firstProcess.terminate()
                secondProcess.terminate()
            }

            let firstRunID = UUID()
            let secondRunID = UUID()
            let firstConnectionID = UUID()
            let secondConnectionID = UUID()
            let firstWindowID = 61004
            let secondWindowID = 61005
            await installPolicy(runID: firstRunID, windowID: firstWindowID)
            await installPolicy(runID: secondRunID, windowID: secondWindowID)
            let firstArmed = await manager.requireExpectedAgentPIDForPendingPolicy(
                for: clientName,
                runID: firstRunID,
                windowID: firstWindowID
            )
            let secondArmed = await manager.requireExpectedAgentPIDForPendingPolicy(
                for: clientName,
                runID: secondRunID,
                windowID: secondWindowID
            )
            XCTAssertTrue(firstArmed)
            XCTAssertTrue(secondArmed)

            // Register in reverse policy order to prove PID ownership, not FIFO position,
            // determines which same-client run each connection consumes.
            await manager.registerExpectedAgentPID(secondProcess.parentPID, for: clientName, runID: secondRunID)
            await manager.registerExpectedAgentPID(firstProcess.parentPID, for: clientName, runID: firstRunID)

            async let first = manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: firstConnectionID,
                clientPid: Int(firstProcess.childPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            async let second = manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: secondConnectionID,
                clientPid: Int(secondProcess.childPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            let (firstResult, secondResult) = await (first, second)

            XCTAssertEqual(firstResult.outcome, "applied")
            XCTAssertEqual(firstResult.runID, firstRunID)
            XCTAssertEqual(firstResult.windowID, firstWindowID)
            XCTAssertEqual(secondResult.outcome, "applied")
            XCTAssertEqual(secondResult.runID, secondRunID)
            XCTAssertEqual(secondResult.windowID, secondWindowID)
            let mappedFirstRunID = await manager.runIDForConnection(firstConnectionID)
            let mappedSecondRunID = await manager.runIDForConnection(secondConnectionID)
            XCTAssertEqual(mappedFirstRunID, firstRunID)
            XCTAssertEqual(mappedSecondRunID, secondRunID)

            await cleanup(
                runID: firstRunID,
                connectionID: firstConnectionID,
                windowID: firstWindowID,
                expectedPID: firstProcess.parentPID
            )
            await cleanup(
                runID: secondRunID,
                connectionID: secondConnectionID,
                windowID: secondWindowID,
                expectedPID: secondProcess.parentPID
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testMixedQueuePrioritizesConsumablePIDGatedRunPolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61006
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: [],
                oneShot: true,
                reason: "non-gated mixed queue fixture",
                ttl: 10,
                purpose: .unknown,
                requiresExpectedAgentPID: false
            )
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )

            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(result.outcome, "applied")
            XCTAssertEqual(result.runID, runID)
            XCTAssertEqual(pending.count, 1)
            XCTAssertNil(pending.first?.runID)

            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID)
            await cleanup(runID: runID, connectionID: connectionID, windowID: windowID, expectedPID: getpid())
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testKnownAgentBootstrapTimesOutInsteadOfFallingBackWhenLiveAffinityIsUnusable() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let bootstrapConnectionID = UUID()
            let windowID = 61009
            let sessionKey = "bootstrap-timeout-\(UUID().uuidString)"
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            let applied = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(applied.outcome, "applied")
            await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let readiness = await manager.debugBootstrapPolicyAdmissionStatus(
                bootstrapClientName: clientName,
                connectionID: bootstrapConnectionID,
                sessionKey: sessionKey,
                clientPid: Int(getpid()),
                timeout: 0.01
            )

            XCTAssertEqual(readiness, "timedOut")
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: nil
            )
            await manager.removeConnection(bootstrapConnectionID)
        #else
            throw XCTSkip("Bootstrap admission diagnostics require DEBUG helpers.")
        #endif
    }

    func testSessionTokenAlreadyBoundToLiveRunCannotConsumeAnotherRunPolicy() async throws {
        #if DEBUG
            let firstRunID = UUID()
            let secondRunID = UUID()
            let firstConnectionID = UUID()
            let secondConnectionID = UUID()
            let firstWindowID = 61007
            let secondWindowID = 61008
            let sessionKey = "routing-isolation-\(UUID().uuidString)"
            await installPolicy(runID: firstRunID, windowID: firstWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: firstRunID)

            let firstResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: firstConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(firstResult.outcome, "applied")
            XCTAssertEqual(firstResult.runID, firstRunID)

            await installPolicy(runID: secondRunID, windowID: secondWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: secondRunID)
            let secondResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: secondConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )

            XCTAssertEqual(secondResult.outcome, "rejected:session_token_bound_to_other_run")
            XCTAssertEqual(secondResult.runID, secondRunID)
            let secondMappedRunID = await manager.runIDForConnection(secondConnectionID)
            XCTAssertNil(secondMappedRunID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pending.contains { $0.runID == secondRunID })

            await cleanup(
                runID: firstRunID,
                connectionID: firstConnectionID,
                windowID: firstWindowID,
                expectedPID: getpid()
            )
            await cleanup(
                runID: secondRunID,
                connectionID: secondConnectionID,
                windowID: secondWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testPolicyInstallFreezesBlankTabStateBeforeFirstSelectionGet() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PolicyBlankTab-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let selectedFile = root.appendingPathComponent("version.env")
            try "VERSION=1\n".write(to: selectedFile, atomically: true, encoding: .utf8)

            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let seedTabID = UUID()
            let blankTabIDs = [UUID(), UUID()]
            let seedSelection = StoredSelection(
                selectedPaths: [selectedFile.path],
                slices: [selectedFile.path: [LineRange(start: 1, end: 1)]],
                codemapAutoEnabled: false
            )
            let workspace = window.workspaceManager.createWorkspace(
                name: "Policy blank state \(UUID().uuidString.prefix(8))",
                repoPaths: [root.path],
                ephemeral: true
            )
            let initialSwitchResult = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "policyBlankStateInitial"
            )
            XCTAssertEqual(initialSwitchResult, .switched)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(
                    id: seedTabID,
                    name: "Seed",
                    selection: seedSelection,
                    promptText: "seed prompt"
                ),
                ComposeTabState(id: blankTabIDs[0], name: "Agent 1"),
                ComposeTabState(id: blankTabIDs[1], name: "Agent 2")
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = seedTabID
            let reloadResult = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
                window.workspaceManager.workspaces[workspaceIndex],
                reason: "policyBlankStateTabs"
            )
            XCTAssertEqual(reloadResult, .switched)
            _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: root.path
            )
            await window.workspaceFilesViewModel.applyStoredSelection(seedSelection)
            window.promptManager.promptText = "seed prompt"
            XCTAssertEqual(window.workspaceFilesViewModel.snapshotSelection(), seedSelection)

            let tools = await window.mcpServer.windowMCPTools
            let manageSelection = try XCTUnwrap(
                tools.first { $0.name == MCPWindowToolName.manageSelection }
            )

            for (index, blankTabID) in blankTabIDs.enumerated() {
                window.workspaceManager.beginApplyingTabContext(forTabID: blankTabID)
                let currentWorkspaceIndex = try XCTUnwrap(
                    window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
                )
                window.workspaceManager.workspaces[currentWorkspaceIndex].activeComposeTabID = blankTabID
                window.promptManager.loadComposeTabsFromWorkspace(
                    window.workspaceManager.workspaces[currentWorkspaceIndex]
                )
                XCTAssertEqual(window.workspaceFilesViewModel.snapshotSelection(), seedSelection)

                let runID = UUID()
                let connectionID = UUID()
                await installAuthoritativePolicy(
                    runID: runID,
                    tabID: blankTabID,
                    windowID: window.windowID
                )
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                let result = await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    sessionKey: "blank-policy-\(index)-\(UUID().uuidString)",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
                XCTAssertEqual(result.outcome, "applied")
                XCTAssertEqual(result.runID, runID)

                let bound = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[connectionID])
                XCTAssertEqual(bound.tabID, blankTabID)
                XCTAssertEqual(bound.selection, StoredSelection())

                let firstGet = try await ServerNetworkManager.withConnectionID(connectionID) {
                    try await manageSelection([
                        "op": .string("get"),
                        "view": .string("files"),
                        "path_display": .string("full")
                    ])
                }
                let object = try XCTUnwrap(firstGet.objectValue)
                XCTAssertTrue((object["files"]?.arrayValue ?? []).isEmpty)
                XCTAssertTrue((object["file_slices"]?.arrayValue ?? []).isEmpty)
                XCTAssertEqual(window.workspaceManager.composeTab(with: blankTabID)?.selection, StoredSelection())

                await cleanup(
                    runID: runID,
                    connectionID: connectionID,
                    windowID: window.windowID,
                    expectedPID: getpid()
                )
                window.workspaceManager.endApplyingTabContext(forTabID: blankTabID)
            }
        #else
            throw XCTSkip("Policy-bound tab routing diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testRetainedConnectionCannotConsumeDifferentRunPolicy() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let firstRunID = UUID()
            let secondRunID = UUID()
            let retainedConnectionID = UUID()
            let rejectedHandoverConnectionID = UUID()
            let freshConnectionID = UUID()
            let firstTabID = UUID()
            let secondTabID = UUID()
            let firstSelection = StoredSelection(selectedPaths: ["/tmp/first-agent.swift"])
            let secondSelection = StoredSelection(selectedPaths: ["/tmp/second-agent.swift"])
            let windowID = window.windowID
            let sessionKey = "retained-connection-pinning-\(UUID().uuidString)"
            // This fixture intentionally uses synthetic nonexistent paths; suspend snapshot mirroring during reactivation.
            window.workspaceManager.beginApplyingTabContext(forTabID: firstTabID)
            defer { window.workspaceManager.endApplyingTabContext(forTabID: firstTabID) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "Retained connection selection isolation \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let initialSwitchResult = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "retainedConnectionSelectionIsolation"
            )
            XCTAssertEqual(initialSwitchResult, .switched)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(id: firstTabID, name: "First", selection: firstSelection),
                ComposeTabState(id: secondTabID, name: "Second", selection: secondSelection)
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = firstTabID
            let tabReloadResult = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
                window.workspaceManager.workspaces[workspaceIndex],
                reason: "retainedConnectionSelectionIsolationTabs"
            )
            XCTAssertEqual(tabReloadResult, .switched)
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

            await installAuthoritativePolicy(
                runID: firstRunID,
                tabID: firstTabID,
                windowID: windowID
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: firstRunID)
            let firstResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: retainedConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            XCTAssertEqual(firstResult.outcome, "applied")
            XCTAssertEqual(firstResult.runID, firstRunID)
            let firstBoundContext = try XCTUnwrap(
                window.mcpServer.tabContextByConnectionID[retainedConnectionID]
            )
            XCTAssertEqual(firstBoundContext.tabID, firstTabID)

            await MCPRoutingWaiter.cleanup(runID: secondRunID)
            await MCPRoutingWaiter.register(runID: secondRunID)
            await installAuthoritativePolicy(
                runID: secondRunID,
                tabID: secondTabID,
                windowID: windowID
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: secondRunID)
            let retainedStateBeforeRejection = await manager.debugConnectionPolicyState(
                for: retainedConnectionID
            )

            let rejectedResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: retainedConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )

            let retainedRunID = await manager.runIDForConnection(retainedConnectionID)
            let retainedStateAfterRejection = await manager.debugConnectionPolicyState(
                for: retainedConnectionID
            )
            let pendingAfterRejection = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(rejectedResult.outcome, "rejected:connection_bound_to_other_run")
            XCTAssertEqual(rejectedResult.runID, secondRunID)
            XCTAssertEqual(retainedRunID, firstRunID)
            XCTAssertEqual(retainedStateAfterRejection.restrictedTools, retainedStateBeforeRejection.restrictedTools)
            XCTAssertEqual(retainedStateAfterRejection.additionalTools, retainedStateBeforeRejection.additionalTools)
            XCTAssertEqual(retainedStateAfterRejection.purpose, retainedStateBeforeRejection.purpose)
            XCTAssertEqual(retainedStateAfterRejection.windowID, retainedStateBeforeRejection.windowID)
            let retainedContextAfterRejection = try XCTUnwrap(
                window.mcpServer.tabContextByConnectionID[retainedConnectionID]
            )
            XCTAssertEqual(retainedContextAfterRejection.tabID, firstBoundContext.tabID)
            XCTAssertEqual(retainedContextAfterRejection.runID, firstBoundContext.runID)
            XCTAssertEqual(retainedContextAfterRejection.workspaceID, firstBoundContext.workspaceID)
            XCTAssertEqual(retainedContextAfterRejection.selection, firstBoundContext.selection)
            XCTAssertNil(window.mcpServer.connectionID(forRunID: secondRunID))
            XCTAssertTrue(pendingAfterRejection.contains { $0.runID == secondRunID })
            let observedAfterWrongRunRejection = await MCPRoutingWaiter.connectionWasObserved(
                runID: secondRunID
            )
            XCTAssertFalse(observedAfterWrongRunRejection)

            let rejectedHandoverResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: rejectedHandoverConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            XCTAssertEqual(rejectedHandoverResult.outcome, "rejected:session_token_bound_to_other_run")
            XCTAssertEqual(rejectedHandoverResult.runID, secondRunID)
            let rejectedHandoverRunID = await manager.runIDForConnection(rejectedHandoverConnectionID)
            XCTAssertNil(rejectedHandoverRunID)
            let observedAfterWrongSessionRejection = await MCPRoutingWaiter.connectionWasObserved(
                runID: secondRunID
            )
            XCTAssertFalse(observedAfterWrongSessionRejection)

            let freshSessionKey = "fresh-run-token-\(UUID().uuidString)"
            XCTAssertNotEqual(freshSessionKey, sessionKey)
            let freshResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: freshConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: freshSessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            XCTAssertEqual(freshResult.outcome, "applied")
            XCTAssertEqual(freshResult.runID, secondRunID)
            let freshRunID = await manager.runIDForConnection(freshConnectionID)
            XCTAssertEqual(freshRunID, secondRunID)
            XCTAssertEqual(window.mcpServer.tabContextByConnectionID[freshConnectionID]?.tabID, secondTabID)
            let observedAfterConsumingConnection = await MCPRoutingWaiter.connectionWasObserved(
                runID: secondRunID
            )
            XCTAssertTrue(observedAfterConsumingConnection)

            await cleanup(
                runID: secondRunID,
                connectionID: freshConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await MCPRoutingWaiter.cleanup(runID: secondRunID)
            await manager.removeConnection(rejectedHandoverConnectionID)
            await cleanup(
                runID: firstRunID,
                connectionID: retainedConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Connection/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testRetainedConnectionCanConsumeSameRunPolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let firstWindowID = 61012
            let secondWindowID = 61013
            let sessionKey = "same-run-connection-reuse-\(UUID().uuidString)"
            await installPolicy(runID: runID, windowID: firstWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let firstResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(firstResult.outcome, "applied")

            await installPolicy(runID: runID, windowID: secondWindowID)
            let reconnectResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )

            XCTAssertEqual(reconnectResult.outcome, "applied")
            XCTAssertEqual(reconnectResult.runID, runID)
            XCTAssertEqual(reconnectResult.windowID, secondWindowID)
            let reconnectedRunID = await manager.runIDForConnection(connectionID)
            XCTAssertEqual(reconnectedRunID, runID)

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: secondWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Connection/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testTerminalRunCleanupReleasesAffinityBeforeFreshRunBinding() async throws {
        #if DEBUG
            let completedRunID = UUID()
            let resumedRunID = UUID()
            let completedConnectionID = UUID()
            let resumedConnectionID = UUID()
            let completedWindowID = 61014
            let resumedWindowID = 61015
            let completedSessionKey = "terminal-release-\(UUID().uuidString)"
            let resumedSessionKey = "fresh-resume-\(UUID().uuidString)"
            XCTAssertNotEqual(completedRunID, resumedRunID)
            XCTAssertNotEqual(completedConnectionID, resumedConnectionID)
            XCTAssertNotEqual(completedSessionKey, resumedSessionKey)

            await installPolicy(runID: completedRunID, windowID: completedWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: completedRunID)
            let completedResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: completedConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: completedSessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(completedResult.outcome, "applied")
            XCTAssertEqual(completedResult.runID, completedRunID)

            await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: completedRunID)
            await manager.cleanupRunRoutingState(for: completedRunID, windowID: completedWindowID)
            let releasedRunID = await manager.runIDForConnection(completedConnectionID)
            let releasedRunPolicy = await manager.debugRunPolicyState(for: completedRunID)
            XCTAssertNil(releasedRunID)
            XCTAssertNil(releasedRunPolicy)
            await manager.removeConnection(completedConnectionID)

            await installPolicy(runID: resumedRunID, windowID: resumedWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: resumedRunID)
            let resumedResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: resumedConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: resumedSessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            let boundResumedRunID = await manager.runIDForConnection(resumedConnectionID)

            XCTAssertEqual(resumedResult.outcome, "applied")
            XCTAssertEqual(resumedResult.runID, resumedRunID)
            XCTAssertEqual(boundResumedRunID, resumedRunID)

            await cleanup(
                runID: resumedRunID,
                connectionID: resumedConnectionID,
                windowID: resumedWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Connection/run lifecycle diagnostics require DEBUG helpers.")
        #endif
    }

    func testAuthoritativePIDOwnedAgentModeRouteCannotReplaceLiveAffinityForAnyRole() async throws {
        #if DEBUG
            let roles: [AgentModelCatalog.TaskLabelKind?] = [nil] + AgentModelCatalog.TaskLabelKind.allCases
                .map(Optional.some)
            for (index, role) in roles.enumerated() {
                let sessionKey = "authoritative-role-agnostic-\(index)-\(UUID().uuidString)"
                let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61100 + index * 2)
                let runID = UUID()
                let connectionID = UUID()
                let windowID = 61101 + index * 2
                await installAuthoritativePolicy(
                    runID: runID,
                    tabID: UUID(),
                    windowID: windowID,
                    taskLabelKind: role
                )
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

                let result = await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    sessionKey: sessionKey,
                    pidGateTimeout: 0.25,
                    requireRunRouting: false
                )

                XCTAssertEqual(
                    result.outcome,
                    "rejected:session_token_bound_to_other_run",
                    "role=\(role?.rawValue ?? "nil")"
                )
                XCTAssertEqual(result.runID, runID)
                let mappedRunID = await manager.runIDForConnection(connectionID)
                XCTAssertNil(mappedRunID)
                let pending = await manager.debugPendingPolicySnapshot(for: clientName)
                XCTAssertTrue(pending.contains { $0.runID == runID })
                await cleanup(
                    runID: runID,
                    connectionID: connectionID,
                    windowID: windowID,
                    expectedPID: getpid()
                )
                await cleanup(
                    runID: affinity.runID,
                    connectionID: affinity.connectionID,
                    windowID: affinity.windowID,
                    expectedPID: nil
                )
            }
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testAuthoritativeRouteCannotReplaceLiveAffinityForMismatchedPID() async throws {
        #if DEBUG
            let expectedTree = try makeSleepingProcessTree()
            let unrelatedTree = try makeSleepingProcessTree()
            defer {
                expectedTree.terminate()
                unrelatedTree.terminate()
            }
            let sessionKey = "authoritative-pid-mismatch-\(UUID().uuidString)"
            let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61120)
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61121
            await installAuthoritativePolicy(runID: runID, tabID: UUID(), windowID: windowID)
            await manager.registerExpectedAgentPID(expectedTree.parentPID, for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(unrelatedTree.childPID),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "rejected:ownership_timeout")
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: expectedTree.parentPID
            )
            await cleanup(
                runID: affinity.runID,
                connectionID: affinity.connectionID,
                windowID: affinity.windowID,
                expectedPID: nil
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testStaleLifecycleCannotReplaceLiveAffinityWithAuthoritativeRoute() async throws {
        #if DEBUG
            let sessionKey = "authoritative-stale-generation-\(UUID().uuidString)"
            let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61122)
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61123
            await installAuthoritativePolicy(runID: runID, tabID: UUID(), windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false,
                expectedLifecycleGeneration: .max
            )

            XCTAssertEqual(result.outcome, "rejected:session_token_bound_to_other_run")
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await cleanup(
                runID: affinity.runID,
                connectionID: affinity.connectionID,
                windowID: affinity.windowID,
                expectedPID: nil
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testUnreservedAgentModePolicyCannotReplaceLiveAffinity() async throws {
        #if DEBUG
            let sessionKey = "authoritative-unreserved-\(UUID().uuidString)"
            let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61124)
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61125
            await installAuthoritativePolicy(
                runID: runID,
                tabID: UUID(),
                windowID: windowID,
                oneShot: false
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "rejected:session_token_bound_to_other_run")
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pending.contains { $0.runID == runID })
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await cleanup(
                runID: affinity.runID,
                connectionID: affinity.connectionID,
                windowID: affinity.windowID,
                expectedPID: nil
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testSameTokenReconnectWithoutConsumablePolicyRestoresLiveAffinity() async throws {
        #if DEBUG
            let sessionKey = "ordinary-live-affinity-reconnect-\(UUID().uuidString)"
            let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61126)
            let reconnectConnectionID = UUID()

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: reconnectConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(result.outcome, "fallback")
            let restoredRunID = await manager.runIDForConnection(reconnectConnectionID)
            XCTAssertEqual(restoredRunID, affinity.runID)
            await manager.removeConnection(reconnectConnectionID)
            await cleanup(
                runID: affinity.runID,
                connectionID: affinity.connectionID,
                windowID: affinity.windowID,
                expectedPID: nil
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testRejectedAuthoritativeRoutePreservesPriorLiveAffinityForReconnect() async throws {
        #if DEBUG
            let sessionKey = "authoritative-route-rollback-\(UUID().uuidString)"
            let affinity = await seedLiveAffinity(sessionKey: sessionKey, windowID: 61127)
            let childRunID = UUID()
            let childConnectionID = UUID()
            let missingWindowID = 61997
            await installAuthoritativePolicy(
                runID: childRunID,
                tabID: UUID(),
                windowID: missingWindowID
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: childRunID)

            let failedChild = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: childConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )

            XCTAssertEqual(failedChild.outcome, "rejected:session_token_bound_to_other_run")
            let pendingAfterFailure = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pendingAfterFailure.contains { $0.runID == childRunID })

            await cleanup(
                runID: childRunID,
                connectionID: childConnectionID,
                windowID: missingWindowID,
                expectedPID: getpid()
            )

            let reconnectConnectionID = UUID()
            let reconnect = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: reconnectConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.05,
                requireRunRouting: false
            )

            XCTAssertEqual(reconnect.outcome, "fallback")
            let restoredRunID = await manager.runIDForConnection(reconnectConnectionID)
            XCTAssertEqual(restoredRunID, affinity.runID)
            await manager.removeConnection(reconnectConnectionID)
            await cleanup(
                runID: affinity.runID,
                connectionID: affinity.connectionID,
                windowID: affinity.windowID,
                expectedPID: nil
            )
        #else
            throw XCTSkip("Token/run isolation diagnostics require DEBUG helpers.")
        #endif
    }

    func testRouteMappingFailureRejectsAndRestoresOneShotPolicy() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let missingWindowID = 61999
            await installPolicy(runID: runID, windowID: missingWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )

            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            let mappedRunID = await manager.runIDForConnection(connectionID)
            XCTAssertEqual(result.outcome, "rejected:route_mapping_failed")
            XCTAssertEqual(result.restrictedTools, [])
            XCTAssertEqual(result.additionalTools, [])
            XCTAssertEqual(result.purpose, .unknown)
            XCTAssertNil(result.windowID)
            XCTAssertNil(mappedRunID)
            XCTAssertTrue(pending.contains { $0.runID == runID })

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: missingWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testSuspendedRouteInstallationReservesOneShotPolicyAndRollbackRestoresIt() async throws {
        #if DEBUG
            let runID = UUID()
            let firstConnectionID = UUID()
            let competingConnectionID = UUID()
            let retryConnectionID = UUID()
            let missingWindowID = 61998
            await installPolicy(runID: runID, windowID: missingWindowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.debugSuspendNextPendingPolicyRouteInstallation()

            let firstApplication = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: firstConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }

            let suspended = await waitUntil {
                await self.manager.debugIsPendingPolicyRouteInstallationSuspended()
            }
            XCTAssertTrue(suspended)

            let competingResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: competingConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            let reservedSnapshot = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(competingResult.outcome, "rejected:policy_reserved")
            XCTAssertTrue(reservedSnapshot.contains { $0.runID == runID })

            await manager.debugResumePendingPolicyRouteInstallation()
            let firstResult = await firstApplication.value
            XCTAssertEqual(firstResult.outcome, "rejected:route_mapping_failed")

            let retryResult = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: retryConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(retryResult.outcome, "applied")
            XCTAssertEqual(retryResult.runID, runID)
            let consumedSnapshot = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(consumedSnapshot.contains { $0.runID == runID })

            await manager.removeConnection(firstConnectionID)
            await manager.removeConnection(competingConnectionID)
            await cleanup(
                runID: runID,
                connectionID: retryConnectionID,
                windowID: missingWindowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Pending policy reservation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testRoutingSignalWaitsForOneShotPolicyCommit() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = window.windowID
            let liveConnection = MCPPolicyAuthorityTestConnection()
            await manager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: liveConnection,
                clientName: clientName,
                sessionToken: "policy-authority-\(runID.uuidString)"
            )
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await MCPRoutingWaiter.cleanup(runID: runID)
            await MCPRoutingWaiter.register(runID: runID)

            let routeWaiter = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 5)
            }
            let didRegisterRouteWaiter = await waitUntil {
                await MCPRoutingWaiter.debugContinuationCount(runID: runID) == 1
            }
            XCTAssertTrue(didRegisterRouteWaiter)

            await manager.debugSuspendNextPendingPolicyCommit()
            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)

            let pendingBeforeCommit = await manager.debugPendingPolicySnapshot(for: clientName)
            let waiterCountBeforeCommit = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertTrue(pendingBeforeCommit.contains { $0.runID == runID })
            XCTAssertEqual(waiterCountBeforeCommit, 1)
            XCTAssertNotNil(window.mcpServer.pendingPolicyRunIDMappingTokenIDByRunID[runID])
            let stagedRouteIsCommitted = await manager.isRunRouteAuthoritativelyCommitted(
                runID: runID,
                windowID: windowID,
                tabID: nil
            )
            XCTAssertFalse(stagedRouteIsCommitted)

            await manager.debugResumePendingPolicyCommit()
            let result = await application.value
            let didRoute = await routeWaiter.value
            XCTAssertEqual(result.outcome, "applied")
            XCTAssertTrue(didRoute)
            XCTAssertNotNil(window.mcpServer.pendingPolicyRunIDMappingTokenIDByRunID[runID])
            let appliedRouteIsCommitted = await manager.isRunRouteAuthoritativelyCommitted(
                runID: runID,
                windowID: windowID,
                tabID: nil
            )
            XCTAssertTrue(appliedRouteIsCommitted)

            await manager.revokeClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                runID: runID
            )
            let revokedRouteIsCommitted = await manager.isRunRouteAuthoritativelyCommitted(
                runID: runID,
                windowID: windowID,
                tabID: nil
            )
            XCTAssertFalse(revokedRouteIsCommitted)

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Pending policy commit diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testConfirmOrFenceReobservesCommitThatLandsAfterInitialFalseSample() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = makeWindow()
                defer { WindowStatesManager.shared.unregisterWindowState(window) }
                let runID = UUID()
                let connectionID = UUID()
                let liveConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugRegisterConnectionForSocketFixture(
                    connectionID: connectionID,
                    connection: liveConnection,
                    clientName: clientName,
                    sessionToken: "confirm-before-fence-\(runID.uuidString)"
                )
                await installPolicy(runID: runID, windowID: window.windowID)
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                await manager.debugSuspendNextPendingPolicyCommit()

                let application = Task {
                    await manager.debugApplyPendingPolicy(
                        clientName: clientName,
                        connectionID: connectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: "repoprompt_ce_cli_debug",
                        pidGateTimeout: 0.25,
                        requireRunRouting: true
                    )
                }
                let commitSuspended = await waitUntil { await self.manager.debugIsPendingPolicyCommitSuspended() }
                XCTAssertTrue(commitSuspended)

                await manager.debugSuspendNextConfirmOrFence()
                let decisionTask = Task {
                    await manager.confirmCommittedRunRouteOrFenceRevocation(
                        runID: runID,
                        windowID: window.windowID,
                        tabID: nil
                    )
                }
                let confirmSuspended = await waitUntil { await self.manager.debugIsConfirmOrFenceSuspended() }
                XCTAssertTrue(confirmSuspended)

                await manager.debugResumePendingPolicyCommit()
                let applicationResult = await application.value
                XCTAssertEqual(applicationResult.outcome, "applied")
                await manager.debugResumeConfirmOrFence()
                let decision = await decisionTask.value
                XCTAssertEqual(decision, .committed)
                let routeIsCommitted = await manager.isRunRouteAuthoritativelyCommitted(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: nil
                )
                XCTAssertTrue(routeIsCommitted)

                await cleanup(
                    runID: runID,
                    connectionID: connectionID,
                    windowID: window.windowID,
                    expectedPID: getpid()
                )
            }
        #else
            throw XCTSkip("Conditional route revocation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testConfirmOrFenceRetriesCommitThatLandsAfterNilMainActorMapping() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = makeWindow()
                defer { WindowStatesManager.shared.unregisterWindowState(window) }
                let runID = UUID()
                let connectionID = UUID()
                let liveConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugRegisterConnectionForSocketFixture(
                    connectionID: connectionID,
                    connection: liveConnection,
                    clientName: clientName,
                    sessionToken: "late-main-actor-commit-\(runID.uuidString)"
                )
                await installPolicy(runID: runID, windowID: window.windowID)
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                await manager.debugSuspendNextPendingPolicyCommit()

                let application = Task {
                    await manager.debugApplyPendingPolicy(
                        clientName: clientName,
                        connectionID: connectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: "repoprompt_ce_cli_debug",
                        pidGateTimeout: 0.25,
                        requireRunRouting: true
                    )
                }
                let commitSuspended = await waitUntil { await self.manager.debugIsPendingPolicyCommitSuspended() }
                XCTAssertTrue(commitSuspended)

                await manager.debugSuspendNextConfirmOrFenceBeforeRevocation()
                let decisionTask = Task {
                    await manager.confirmCommittedRunRouteOrFenceRevocation(
                        runID: runID,
                        windowID: window.windowID,
                        tabID: nil
                    )
                }
                let beforeRevocationSuspended = await waitUntil {
                    await self.manager.debugIsConfirmOrFenceBeforeRevocationSuspended()
                }
                XCTAssertTrue(beforeRevocationSuspended)

                await manager.debugResumePendingPolicyCommit()
                let applicationResult = await application.value
                XCTAssertEqual(applicationResult.outcome, "applied")
                await manager.debugResumeConfirmOrFenceBeforeRevocation()
                let decision = await decisionTask.value
                XCTAssertEqual(decision, .committed)
                let routeIsCommitted = await manager.isRunRouteAuthoritativelyCommitted(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: nil
                )
                XCTAssertTrue(routeIsCommitted)

                await cleanup(
                    runID: runID,
                    connectionID: connectionID,
                    windowID: window.windowID,
                    expectedPID: getpid()
                )
            }
        #else
            throw XCTSkip("Conditional route revocation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testConfirmOrFenceLateCandidateSkipsStaleTerminalPredecessorMapping() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = makeWindow()
                defer { WindowStatesManager.shared.unregisterWindowState(window) }
                let runID = UUID()

                // Construct a displaced predecessor exactly as a reconnect/handover
                // leaves it before its scheduled removal completes: the MainActor run
                // route no longer points at it, its transport is terminal, but its
                // actor-side run mapping still resolves to the run. Seed that
                // actor-side state directly instead of applying a full predecessor
                // policy and letting the successor displace it — displacement arms an
                // asynchronous pending-policy replacement cleanup task that races
                // this test's observation window and can remove the stale mapping
                // before the late-candidate probe runs.
                let staleConnectionID = UUID()
                let staleConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugRegisterConnectionForSocketFixture(
                    connectionID: staleConnectionID,
                    connection: staleConnection,
                    clientName: clientName,
                    sessionToken: "late-candidate-stale-\(runID.uuidString)"
                )
                await manager.debugSeedConnectionRunRouting(
                    connectionID: staleConnectionID,
                    runID: runID,
                    purpose: .agentModeRun,
                    windowID: window.windowID
                )
                await manager.debugPublishTransportTerminalForTesting(connectionID: staleConnectionID)
                let staleMappedRunIDBeforeSuccessor = await manager.runIDForConnection(staleConnectionID)
                XCTAssertEqual(staleMappedRunIDBeforeSuccessor, runID)

                let successorConnectionID = UUID()
                let successorConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugRegisterConnectionForSocketFixture(
                    connectionID: successorConnectionID,
                    connection: successorConnection,
                    clientName: clientName,
                    sessionToken: "late-candidate-successor-\(runID.uuidString)"
                )
                await installPolicy(runID: runID, windowID: window.windowID)
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                await manager.debugSuspendNextPendingPolicyCommit()

                let application = Task {
                    await manager.debugApplyPendingPolicy(
                        clientName: clientName,
                        connectionID: successorConnectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: "repoprompt_ce_cli_debug",
                        pidGateTimeout: 0.25,
                        requireRunRouting: true
                    )
                }
                let commitSuspended = await waitUntil { await self.manager.debugIsPendingPolicyCommitSuspended() }
                XCTAssertTrue(commitSuspended)

                await manager.debugSuspendNextConfirmOrFenceBeforeRevocation()
                let decisionTask = Task {
                    await manager.confirmCommittedRunRouteOrFenceRevocation(
                        runID: runID,
                        windowID: window.windowID,
                        tabID: nil
                    )
                }
                let beforeRevocationSuspended = await waitUntil {
                    await self.manager.debugIsConfirmOrFenceBeforeRevocationSuspended()
                }
                XCTAssertTrue(beforeRevocationSuspended)

                await manager.debugResumePendingPolicyCommit()
                let applicationResult = await application.value
                XCTAssertEqual(applicationResult.outcome, "applied")

                // Both mappings must be visible when the late-candidate probe runs:
                // the stale terminal predecessor and the committed successor. The
                // probe must not let the stale mapping mask the committed route.
                let staleMappedRunID = await manager.runIDForConnection(staleConnectionID)
                XCTAssertEqual(staleMappedRunID, runID)
                let staleIsTerminal = await manager.debugIsTransportTerminalForTesting(
                    connectionID: staleConnectionID
                )
                XCTAssertTrue(staleIsTerminal)
                let successorMappedRunID = await manager.runIDForConnection(successorConnectionID)
                XCTAssertEqual(successorMappedRunID, runID)

                await manager.debugResumeConfirmOrFenceBeforeRevocation()
                let decision = await decisionTask.value
                XCTAssertEqual(decision, .committed)
                // The stale terminal mapping is still present after the decision, so
                // the late-candidate probe observed both mappings and itself skipped
                // the terminal predecessor — the committed decision did not depend on
                // background cleanup removing the stale mapping first.
                let staleMappedRunIDAfterDecision = await manager.runIDForConnection(staleConnectionID)
                XCTAssertEqual(staleMappedRunIDAfterDecision, runID)
                let staleIsTerminalAfterDecision = await manager.debugIsTransportTerminalForTesting(
                    connectionID: staleConnectionID
                )
                XCTAssertTrue(staleIsTerminalAfterDecision)
                // The committed authority is the successor's route, not the stale
                // predecessor's.
                XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], successorConnectionID)
                let routeIsCommitted = await manager.isRunRouteAuthoritativelyCommitted(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: nil
                )
                XCTAssertTrue(routeIsCommitted)

                await manager.removeConnection(staleConnectionID)
                await cleanup(
                    runID: runID,
                    connectionID: successorConnectionID,
                    windowID: window.windowID,
                    expectedPID: getpid()
                )
            }
        #else
            throw XCTSkip("Conditional route revocation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testConfirmOrFencePreventsSuspendedCommitAfterRevocationFence() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = makeWindow()
                defer { WindowStatesManager.shared.unregisterWindowState(window) }
                let runID = UUID()
                let connectionID = UUID()
                let liveConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugRegisterConnectionForSocketFixture(
                    connectionID: connectionID,
                    connection: liveConnection,
                    clientName: clientName,
                    sessionToken: "fence-before-commit-\(runID.uuidString)"
                )
                await installPolicy(runID: runID, windowID: window.windowID)
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                await manager.debugSuspendNextPendingPolicyCommit()

                let application = Task {
                    await manager.debugApplyPendingPolicy(
                        clientName: clientName,
                        connectionID: connectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: "repoprompt_ce_cli_debug",
                        pidGateTimeout: 0.25,
                        requireRunRouting: true
                    )
                }
                let commitSuspended = await waitUntil { await self.manager.debugIsPendingPolicyCommitSuspended() }
                XCTAssertTrue(commitSuspended)

                let decision = await manager.confirmCommittedRunRouteOrFenceRevocation(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: nil
                )
                XCTAssertEqual(decision, .revocationFenced)
                await manager.revokeClientConnectionPolicy(
                    for: clientName,
                    windowID: window.windowID,
                    runID: runID
                )
                await manager.debugResumePendingPolicyCommit()
                let applicationResult = await application.value
                XCTAssertEqual(applicationResult.outcome, "rejected:stale_connection")
                let routeIsCommitted = await manager.isRunRouteAuthoritativelyCommitted(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: nil
                )
                XCTAssertFalse(routeIsCommitted)

                await cleanup(
                    runID: runID,
                    connectionID: connectionID,
                    windowID: window.windowID,
                    expectedPID: getpid()
                )
            }
        #else
            throw XCTSkip("Conditional route revocation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testTransportTerminalPublicationPreventsCommittedRouteConfirmation() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = makeWindow()
                defer { WindowStatesManager.shared.unregisterWindowState(window) }
                let runID = UUID()
                let connectionID = UUID()
                let liveConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugRegisterConnectionForSocketFixture(
                    connectionID: connectionID,
                    connection: liveConnection,
                    clientName: clientName,
                    sessionToken: "terminal-before-confirm-\(runID.uuidString)"
                )
                await installPolicy(runID: runID, windowID: window.windowID)
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                let application = await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
                XCTAssertEqual(application.outcome, "applied")
                let routeWasCommitted = await manager.isRunRouteAuthoritativelyCommitted(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: nil
                )
                XCTAssertTrue(routeWasCommitted)

                await manager.debugPublishTransportTerminalForTesting(connectionID: connectionID)
                let terminalRouteIsCommitted = await manager.isRunRouteAuthoritativelyCommitted(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: nil
                )
                XCTAssertFalse(terminalRouteIsCommitted)
                let terminalDecision = await manager.confirmCommittedRunRouteOrFenceRevocation(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: nil
                )
                XCTAssertEqual(terminalDecision, .revocationFenced)

                await cleanup(
                    runID: runID,
                    connectionID: connectionID,
                    windowID: window.windowID,
                    expectedPID: getpid()
                )
                await manager.debugPublishTransportTerminalForTesting(connectionID: connectionID)
                let terminalMarkerWasReinserted = await manager.debugIsTransportTerminalForTesting(
                    connectionID: connectionID
                )
                XCTAssertFalse(terminalMarkerWasReinserted)
            }
        #else
            throw XCTSkip("Transport terminal routing authority requires DEBUG helpers.")
        #endif
    }

    @MainActor
    func testDisconnectDuringObservationAwaitIsRejectedByExistingStalenessGuard() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let connectionID = UUID()
            await installPolicy(runID: runID, windowID: window.windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await MCPRoutingWaiter.register(runID: runID)
            await manager.debugSuspendNextPendingPolicyObservation()

            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let observationSuspended = await waitUntil {
                await self.manager.debugIsPendingPolicyObservationSuspended()
            }
            XCTAssertTrue(observationSuspended)

            await manager.debugInvalidatePendingPolicyApplication(connectionID: connectionID)
            await manager.debugResumePendingPolicyObservation()
            let result = await application.value

            XCTAssertEqual(result.outcome, "rejected:stale_connection")
            let connectionWasObserved = await MCPRoutingWaiter.connectionWasObserved(runID: runID)
            XCTAssertTrue(connectionWasObserved)
            XCTAssertNil(window.mcpServer.connectionIDByRunID[runID])
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: window.windowID,
                expectedPID: getpid()
            )
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Pending policy observation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testRevocationDuringObservationAwaitCannotPublishRoute() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let connectionID = UUID()
            await installPolicy(runID: runID, windowID: window.windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await MCPRoutingWaiter.register(runID: runID)
            await manager.debugSuspendNextPendingPolicyObservation()

            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let observationSuspended = await waitUntil {
                await self.manager.debugIsPendingPolicyObservationSuspended()
            }
            XCTAssertTrue(observationSuspended)

            await manager.revokeClientConnectionPolicy(
                for: clientName,
                windowID: window.windowID,
                runID: runID
            )
            await manager.debugResumePendingPolicyObservation()
            let result = await application.value

            XCTAssertTrue(
                result.outcome == "rejected:policy_removed" || result.outcome == "rejected:stale_connection",
                result.outcome
            )
            let connectionWasObserved = await MCPRoutingWaiter.connectionWasObserved(runID: runID)
            XCTAssertTrue(connectionWasObserved)
            XCTAssertNil(window.mcpServer.connectionIDByRunID[runID])
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: window.windowID,
                expectedPID: getpid()
            )
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Pending policy observation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testMatchedNonOneShotRunPolicyAlsoPublishesObservation() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let connectionID = UUID()
            await installAuthoritativePolicy(
                runID: runID,
                tabID: nil,
                windowID: window.windowID,
                oneShot: false
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await MCPRoutingWaiter.register(runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )

            XCTAssertEqual(result.outcome, "applied")
            let connectionWasObserved = await MCPRoutingWaiter.connectionWasObserved(runID: runID)
            XCTAssertTrue(connectionWasObserved)
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: window.windowID,
                expectedPID: getpid()
            )
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Pending policy observation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testStaleReplacementAdmissionRestoresDisplacedConnectionWithoutSchedulingReplacement() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let displacedConnectionID = UUID()
            let staleConnectionID = UUID()
            let windowID = window.windowID
            await manager.debugClearPendingPolicyReplacementSchedules()
            let didRegisterDisplacedConnection = window.mcpServer.registerRunIDMapping(
                connectionID: displacedConnectionID,
                runID: runID,
                windowID: windowID,
                signalRouting: false
            )
            XCTAssertTrue(didRegisterDisplacedConnection)
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            await manager.debugSuspendNextPendingPolicyCommit()
            let staleApplication = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: staleConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)
            let mappedBeforeInvalidation = window.mcpServer.connectionID(forRunID: runID)
            let replacementSchedulesBeforeInvalidation = await manager
                .debugPendingPolicyReplacementScheduleCount(
                    existing: displacedConnectionID,
                    replacement: staleConnectionID,
                    runID: runID
                )
            XCTAssertEqual(mappedBeforeInvalidation, staleConnectionID)
            XCTAssertEqual(replacementSchedulesBeforeInvalidation, 0)

            await manager.debugInvalidatePendingPolicyApplication(connectionID: staleConnectionID)
            await manager.debugResumePendingPolicyCommit()
            let staleResult = await staleApplication.value
            XCTAssertEqual(staleResult.outcome, "rejected:stale_connection")

            let pendingAfterRollback = await manager.debugPendingPolicySnapshot(for: clientName)
            let mappedAfterRollback = window.mcpServer.connectionID(forRunID: runID)
            let replacementSchedulesAfterRollback = await manager
                .debugPendingPolicyReplacementScheduleCount(
                    existing: displacedConnectionID,
                    replacement: staleConnectionID,
                    runID: runID
                )
            XCTAssertTrue(pendingAfterRollback.contains { $0.runID == runID })
            XCTAssertEqual(mappedAfterRollback, displacedConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[displacedConnectionID], runID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[staleConnectionID])
            XCTAssertEqual(replacementSchedulesAfterRollback, 0)

            await cleanup(
                runID: runID,
                connectionID: staleConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await manager.debugClearPendingPolicyReplacementSchedules()
        #else
            throw XCTSkip("Pending policy commit diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testSuccessfulReplacementAdmissionSchedulesDisplacedConnectionExactlyOnce() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let displacedConnectionID = UUID()
            let replacementConnectionID = UUID()
            let windowID = window.windowID
            await manager.debugClearPendingPolicyReplacementSchedules()
            let didRegisterDisplacedConnection = window.mcpServer.registerRunIDMapping(
                connectionID: displacedConnectionID,
                runID: runID,
                windowID: windowID,
                signalRouting: false
            )
            XCTAssertTrue(didRegisterDisplacedConnection)
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)

            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: replacementConnectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )

            let replacementScheduleCount = await manager.debugPendingPolicyReplacementScheduleCount(
                existing: displacedConnectionID,
                replacement: replacementConnectionID,
                runID: runID
            )
            let pendingAfterCommit = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertEqual(result.outcome, "applied")
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), replacementConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[replacementConnectionID], runID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[displacedConnectionID])
            XCTAssertEqual(replacementScheduleCount, 1)
            XCTAssertFalse(pendingAfterCommit.contains { $0.runID == runID })

            await cleanup(
                runID: runID,
                connectionID: replacementConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await manager.debugClearPendingPolicyReplacementSchedules()
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testSupersededStaleReplacementRollbackDoesNotOverwriteNewerOwner() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let displacedConnectionID = UUID()
            let staleConnectionID = UUID()
            let newerConnectionID = UUID()
            let windowID = window.windowID
            await manager.debugClearPendingPolicyReplacementSchedules()
            XCTAssertTrue(window.mcpServer.registerRunIDMapping(
                connectionID: displacedConnectionID,
                runID: runID,
                windowID: windowID,
                signalRouting: false
            ))
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.debugSuspendNextPendingPolicyCommit()

            let staleApplication = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: staleConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), staleConnectionID)
            XCTAssertTrue(window.mcpServer.registerRunIDMapping(
                connectionID: newerConnectionID,
                runID: runID,
                windowID: windowID,
                signalRouting: false
            ))

            await manager.debugInvalidatePendingPolicyApplication(connectionID: staleConnectionID)
            await manager.debugResumePendingPolicyCommit()
            let staleResult = await staleApplication.value
            let pendingAfterRollback = await manager.debugPendingPolicySnapshot(for: clientName)
            let staleCachedRunID = await manager.debugCachedRunID(for: staleConnectionID)
            let retainedRunPolicy = await manager.debugRunPolicyState(for: runID)
            let deferredReplacementScheduleCount = await manager
                .debugPendingPolicyReplacementScheduleCount(
                    existing: displacedConnectionID,
                    replacement: staleConnectionID,
                    runID: runID
                )

            XCTAssertEqual(staleResult.outcome, "rejected:stale_connection")
            XCTAssertTrue(pendingAfterRollback.contains { $0.runID == runID })
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), newerConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[newerConnectionID], runID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[displacedConnectionID])
            XCTAssertNil(window.mcpServer.connectionIDToRunID[staleConnectionID])
            XCTAssertNil(staleCachedRunID)
            XCTAssertNotNil(retainedRunPolicy)
            XCTAssertEqual(deferredReplacementScheduleCount, 0)

            await cleanup(
                runID: runID,
                connectionID: staleConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await manager.debugClearPendingPolicyReplacementSchedules()
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testStaleReplacementRollbackDoesNotUndoNewerSameConnectionGeneration() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let displacedConnectionID = UUID()
            let replacementConnectionID = UUID()
            let windowID = window.windowID
            await manager.debugClearPendingPolicyReplacementSchedules()
            XCTAssertTrue(window.mcpServer.registerRunIDMapping(
                connectionID: displacedConnectionID,
                runID: runID,
                windowID: windowID,
                signalRouting: false
            ))
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.debugSuspendNextPendingPolicyCommit()

            let staleApplication = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: replacementConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), replacementConnectionID)

            let newerToken = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: replacementConnectionID,
                runID: runID,
                windowID: windowID
            ))
            XCTAssertTrue(window.mcpServer.isCurrentPendingPolicyRunIDMapping(newerToken))

            await manager.debugInvalidatePendingPolicyApplication(connectionID: replacementConnectionID)
            await manager.debugResumePendingPolicyCommit()
            let staleResult = await staleApplication.value
            let cachedRunID = await manager.debugCachedRunID(for: replacementConnectionID)
            let retainedRunPolicy = await manager.debugRunPolicyState(for: runID)

            XCTAssertEqual(staleResult.outcome, "rejected:stale_connection")
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), replacementConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[replacementConnectionID], runID)
            XCTAssertTrue(window.mcpServer.isCurrentPendingPolicyRunIDMapping(newerToken))
            XCTAssertEqual(cachedRunID, runID)
            XCTAssertNotNil(retainedRunPolicy)

            await cleanup(
                runID: runID,
                connectionID: replacementConnectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
            await manager.debugClearPendingPolicyReplacementSchedules()
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testSupersededPendingPolicyApplicationOwnershipCannotCommitCurrentRouteToken() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = window.windowID
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.debugSuspendNextPendingPolicyCommit()

            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
            }
            let didSuspendCommit = await waitUntil {
                await self.manager.debugIsPendingPolicyCommitSuspended()
            }
            XCTAssertTrue(didSuspendCommit)
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), connectionID)

            await manager.debugSupersedePendingPolicyApplicationOwnership(
                connectionID: connectionID,
                runID: runID
            )
            await manager.debugResumePendingPolicyCommit()
            let result = await application.value
            let pendingAfterRollback = await manager.debugPendingPolicySnapshot(for: clientName)

            XCTAssertEqual(result.outcome, "rejected:stale_connection")
            XCTAssertTrue(pendingAfterRollback.contains { $0.runID == runID })
            XCTAssertNil(window.mcpServer.connectionID(forRunID: runID))

            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testSupersededPendingTokenDoesNotBecomeCurrentAgainAfterNestedRollback() throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let firstRunID = UUID()
            let secondRunID = UUID()
            let connectionID = UUID()
            let windowID = window.windowID
            let firstToken = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: connectionID,
                runID: firstRunID,
                windowID: windowID
            ))
            let secondToken = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: connectionID,
                runID: secondRunID,
                windowID: windowID
            ))
            XCTAssertFalse(window.mcpServer.isCurrentPendingPolicyRunIDMapping(firstToken))
            XCTAssertTrue(window.mcpServer.isCurrentPendingPolicyRunIDMapping(secondToken))

            let rollbackResult = window.mcpServer.rollbackPendingPolicyRunIDMapping(
                secondToken,
                clientName: clientName,
                windowID: windowID,
                signalRoutingFailure: false
            )

            XCTAssertEqual(rollbackResult, .restored)
            XCTAssertNil(window.mcpServer.connectionID(forRunID: firstRunID))
            XCTAssertNil(window.mcpServer.connectionIDToRunID[connectionID])
            XCTAssertFalse(window.mcpServer.isCurrentPendingPolicyRunIDMapping(firstToken))
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testPendingPolicyRollbackPreservesNewerQueuedContext() throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = window.windowID
            let token = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: connectionID,
                runID: runID,
                windowID: windowID
            ))

            window.mcpServer.installTabContext(
                clientID: nil,
                clientName: clientName,
                windowID: windowID,
                workspaceID: nil,
                snapshot: ComposeTabState(),
                runID: runID,
                signalRouting: false
            )
            XCTAssertEqual(window.mcpServer.pendingContextQueueLength(clientName: clientName, windowID: windowID), 1)

            let rollbackResult = window.mcpServer.rollbackPendingPolicyRunIDMapping(
                token,
                clientName: clientName,
                windowID: windowID,
                signalRoutingFailure: false
            )

            XCTAssertEqual(rollbackResult, .restored)
            XCTAssertEqual(window.mcpServer.pendingContextQueueLength(clientName: clientName, windowID: windowID), 1)
            window.mcpServer.removeTabContext(
                forConnectionID: nil,
                clientName: clientName,
                windowID: windowID,
                runID: runID
            )
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testPendingPolicyRollbackRestoresContextPromotedDuringRouteMapping() throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let connectionID = UUID()
            let windowID = window.windowID

            window.mcpServer.installTabContext(
                clientID: nil,
                clientName: clientName,
                windowID: windowID,
                workspaceID: nil,
                snapshot: ComposeTabState(),
                runID: runID,
                signalRouting: false
            )
            XCTAssertEqual(
                window.mcpServer.pendingContextQueueLength(clientName: clientName, windowID: windowID),
                1
            )

            let token = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: connectionID,
                runID: runID,
                windowID: windowID,
                clientName: clientName
            ))
            XCTAssertEqual(
                window.mcpServer.pendingContextQueueLength(clientName: clientName, windowID: windowID),
                0
            )

            let rollbackResult = window.mcpServer.rollbackPendingPolicyRunIDMapping(
                token,
                clientName: clientName,
                windowID: windowID,
                signalRoutingFailure: false
            )

            XCTAssertEqual(rollbackResult, .restored)
            XCTAssertEqual(
                window.mcpServer.pendingContextQueueLength(clientName: clientName, windowID: windowID),
                1
            )
            XCTAssertNil(window.mcpServer.tabContextByConnectionID[connectionID])
        #else
            throw XCTSkip("Pending policy rollback diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testPendingPolicyRollbackDoesNotRestorePreviousRunAfterPrimaryGenerationChanges() throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let previousRunID = UUID()
            let pendingRunID = UUID()
            let connectionID = UUID()
            let newerPrimaryConnectionID = UUID()
            let windowID = window.windowID
            XCTAssertTrue(window.mcpServer.registerRunIDMapping(
                connectionID: connectionID,
                runID: previousRunID,
                windowID: windowID,
                signalRouting: false
            ))
            let token = try XCTUnwrap(window.mcpServer.registerPendingPolicyRunIDMapping(
                connectionID: connectionID,
                runID: pendingRunID,
                windowID: windowID
            ))
            XCTAssertTrue(window.mcpServer.registerRunIDMapping(
                connectionID: newerPrimaryConnectionID,
                runID: previousRunID,
                windowID: windowID,
                signalRouting: false
            ))

            let rollbackResult = window.mcpServer.rollbackPendingPolicyRunIDMapping(
                token,
                clientName: clientName,
                windowID: windowID,
                signalRoutingFailure: false
            )

            XCTAssertEqual(rollbackResult, .restored)
            XCTAssertNil(window.mcpServer.connectionID(forRunID: pendingRunID))
            XCTAssertEqual(window.mcpServer.connectionID(forRunID: previousRunID), newerPrimaryConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[newerPrimaryConnectionID], previousRunID)
            XCTAssertNil(window.mcpServer.connectionIDToRunID[connectionID])
            window.mcpServer.cleanupRunIDMapping(
                runID: previousRunID,
                connectionID: newerPrimaryConnectionID,
                signalRoutingFailure: false
            )
        #else
            throw XCTSkip("Pending policy replacement diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testStaleTabContextCleanupPreservesSilentReplacementRunMapping() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let runID = UUID()
            let staleConnectionID = UUID()
            let replacementConnectionID = UUID()
            let snapshot = ComposeTabState()
            await MCPRoutingWaiter.cleanup(runID: runID)
            await MCPRoutingWaiter.register(runID: runID)
            addTeardownBlock {
                await MCPRoutingWaiter.cleanup(runID: runID)
            }
            let routeWaiter = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 1)
            }
            let didRegisterWaiter = await waitUntil {
                await MCPRoutingWaiter.debugContinuationCount(runID: runID) == 1
            }
            XCTAssertTrue(didRegisterWaiter)

            window.mcpServer.installTabContext(
                clientID: staleConnectionID.uuidString,
                clientName: clientName,
                windowID: window.windowID,
                workspaceID: nil,
                snapshot: snapshot,
                runID: runID,
                signalRouting: false
            )
            let didRegisterReplacement = window.mcpServer.registerRunIDMapping(
                connectionID: replacementConnectionID,
                runID: runID,
                windowID: window.windowID,
                signalRouting: false
            )
            window.mcpServer.removeTabContext(
                forConnectionID: staleConnectionID,
                clientName: clientName,
                windowID: window.windowID,
                runID: runID
            )

            let waiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertTrue(didRegisterReplacement)
            XCTAssertEqual(window.mcpServer.connectionIDByRunID[runID], replacementConnectionID)
            XCTAssertEqual(window.mcpServer.connectionIDToRunID[replacementConnectionID], runID)
            XCTAssertEqual(waiterCount, 1)

            await MCPRoutingWaiter.notifyRouted(runID: runID)
            let didRoute = await routeWaiter.value
            XCTAssertTrue(didRoute)
        #else
            throw XCTSkip("Tab-context routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testRunPolicyRevocationInvalidatesSuspendedApplicationBeforeAdmission() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61026
            await installPolicy(runID: runID, windowID: windowID)
            let armed = await manager.requireExpectedAgentPIDForPendingPolicy(
                for: clientName,
                runID: runID,
                windowID: windowID
            )
            XCTAssertTrue(armed)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            await manager.debugSuspendNextPendingPolicyRouteInstallation()

            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 0.25,
                    requireRunRouting: false
                )
            }
            let suspended = await waitUntil {
                await self.manager.debugIsPendingPolicyRouteInstallationSuspended()
            }
            XCTAssertTrue(suspended)

            await manager.revokeClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                runID: runID
            )
            await manager.debugResumePendingPolicyRouteInstallation()
            let result = await application.value

            XCTAssertTrue(
                result.outcome == "rejected:stale_connection" || result.outcome == "rejected:policy_removed",
                result.outcome
            )
            let mappedRunID = await manager.runIDForConnection(connectionID)
            let pending = await manager.debugPendingPolicySnapshot(for: clientName)
            let runPolicy = await manager.debugRunPolicyState(for: runID)
            XCTAssertNil(mappedRunID)
            XCTAssertFalse(pending.contains { $0.runID == runID })
            XCTAssertNil(runPolicy)
            await cleanup(
                runID: runID,
                connectionID: connectionID,
                windowID: windowID,
                expectedPID: getpid()
            )
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    func testPolicyCleanupWhileWaitingRejectsWithoutFallbackBinding() async throws {
        #if DEBUG
            let runID = UUID()
            let connectionID = UUID()
            let windowID = 61006
            await installPolicy(runID: runID, windowID: windowID)
            await manager.debugClearRunRoutingHistoryForTesting()

            let application = Task {
                await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    pidGateTimeout: 1.0,
                    requireRunRouting: false
                )
            }

            let waitStarted = await waitForEvent("pid_gate_wait_started", runID: runID)
            XCTAssertTrue(waitStarted)
            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
            let result = await application.value

            XCTAssertEqual(result.outcome, "rejected:policy_removed")
            let mappedRunID = await manager.runIDForConnection(connectionID)
            XCTAssertNil(mappedRunID)
            await cleanup(runID: runID, connectionID: connectionID, windowID: windowID, expectedPID: nil)
        #else
            throw XCTSkip("PID-gated routing diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testRunCatalogObservationHandlesSameRouteMembershipRacesAndCleanup() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease(owner: #function) { _ in
                try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                await manager.setEnabled(true)
                let window = makeWindow()
                await window.workspaceManager.awaitInitialized()
                let registration = try await AppDomainRuntimeComposition.shared.register(
                    window.mcpServer.windowMCPToolCatalogService
                )
                let runID = UUID()
                let connectionID = UUID()
                let tabID = UUID()
                try await installRoutingSnapshot(for: tabID, in: window)
                let session = window.agentModeViewModel.session(for: tabID)
                session.selectedAgent = .openCode
                session.hasLoadedPersistedState = true
                session.installRunID(runID)
                _ = try XCTUnwrap(window.agentModeViewModel.test_ensureSessionBoundToTab(session))
                let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                    window.agentModeViewModel,
                    tabID: tabID
                )
                addTeardownBlock { @MainActor in
                    await self.manager.debugSetActiveSessionLinkEndpointsForTesting(nil)
                    await self.cleanup(
                        runID: runID,
                        connectionID: connectionID,
                        windowID: window.windowID,
                        expectedPID: getpid()
                    )
                    await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                    WindowStatesManager.shared.unregisterWindowState(window)
                }

                await manager.debugSetActiveSessionLinkEndpointsForTesting([endpoint])
                let routeBeforePolicy = await manager.authoritativeRunCatalogRouteToken(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: tabID
                )
                XCTAssertNil(
                    routeBeforePolicy,
                    "an active link restored before routing must not manufacture a route token"
                )

                await installAuthoritativePolicy(
                    runID: runID,
                    tabID: tabID,
                    windowID: window.windowID
                )
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                let testConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: connectionID,
                    connection: testConnection,
                    pendingClientID: clientName
                )
                let applied = await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    sessionKey: "run-catalog-\(runID.uuidString)",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
                XCTAssertEqual(applied.outcome, "applied")
                let authoritativeToken = await manager.authoritativeRunCatalogRouteToken(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: tabID
                )
                let exactToken = try XCTUnwrap(authoritativeToken)
                let wrongToken = AgentSessionLinkRunCatalogRouteToken(
                    runID: runID,
                    observerEndpoint: endpoint,
                    connectionID: UUID(),
                    routingAuthorityGeneration: exactToken.routingAuthorityGeneration,
                    connectionLifecycleGeneration: exactToken.connectionLifecycleGeneration
                )
                await manager.debugCompleteRunCatalogObservation(
                    connectionID: connectionID,
                    initialRouteToken: wrongToken,
                    returnedSessionLinkPresence: true
                )
                let wrongRouteProjection = await manager.debugRunCatalogProjection(for: runID)
                XCTAssertNil(wrongRouteProjection)

                let names = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(names.contains(MCPWindowToolName.agentSessionLink))
                let finalProjection = await manager.debugRunCatalogProjection(for: runID)
                let ready = try XCTUnwrap(finalProjection)
                XCTAssertTrue(ready.isReady)
                XCTAssertEqual(ready.routeToken, exactToken)
                let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                await manager.setRestrictedTools(
                    for: connectionID,
                    tools: [MCPWindowToolName.agentSessionLink]
                )

                // Removing the final outbound grant changes observer readiness, but an inbound grant
                // keeps the same exact endpoint's catalog surface reachable for inverse/self ops.
                let countBeforeOutboundRemoval = await testConnection.toolListChangedCount()
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(
                    anyActive: [endpoint],
                    outbound: []
                )
                await manager.notifyToolListChangedForAgentSession(sessionID)
                let inboundOnlySnapshot = await manager.debugRunCatalogProjection(for: runID)
                let inboundOnlyProjection = try XCTUnwrap(inboundOnlySnapshot)
                XCTAssertFalse(inboundOnlyProjection.isReady)
                XCTAssertEqual(inboundOnlyProjection.hasAgentSessionLink, true)
                XCTAssertEqual(inboundOnlyProjection.hasActiveOutboundLink, false)
                let countAfterOutboundRemoval = await testConnection.toolListChangedCount()
                XCTAssertEqual(countAfterOutboundRemoval, countBeforeOutboundRemoval + 1)
                let inboundOnlyNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(inboundOnlyNames.contains(MCPWindowToolName.agentSessionLink))

                // The final inbound removal withdraws catalog presence. Complete a stale tools/list to
                // exercise mismatch recovery before the next settled list publishes absence.
                let countBeforeInboundRemoval = await testConnection.toolListChangedCount()
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(
                    anyActive: [],
                    outbound: []
                )
                await manager.debugCompleteRunCatalogObservation(
                    connectionID: connectionID,
                    initialRouteToken: exactToken,
                    returnedSessionLinkPresence: true
                )
                let staleSnapshot = await manager.debugRunCatalogProjection(for: runID)
                let staleProjection = try XCTUnwrap(staleSnapshot)
                XCTAssertFalse(staleProjection.isReady)
                XCTAssertEqual(staleProjection.routeToken, exactToken)
                XCTAssertEqual(staleProjection.hasAgentSessionLink, true)
                XCTAssertEqual(staleProjection.hasActiveOutboundLink, false)
                let countAfterInboundRemoval = await testConnection.toolListChangedCount()
                XCTAssertEqual(countAfterInboundRemoval, countBeforeInboundRemoval + 1)

                let namesAfterFinalRemoval = try await manager.debugListToolNames(for: connectionID)
                XCTAssertFalse(namesAfterFinalRemoval.contains(MCPWindowToolName.agentSessionLink))
                let countAfterSettledList = await testConnection.toolListChangedCount()
                XCTAssertEqual(countAfterSettledList, countBeforeInboundRemoval + 1)

                // A linked incarnation sharing only the session UUID must not grant this routed
                // incarnation catalog presence or cause a spurious exact-route invalidation.
                let duplicateIncarnation = DomainAgentSessionLinkEndpointIdentity(
                    windowID: endpoint.windowID,
                    workspaceID: endpoint.workspaceID,
                    tabID: UUID(),
                    sessionID: endpoint.sessionID,
                    persistentBindingGeneration: endpoint.persistentBindingGeneration,
                    bindingTransitionGeneration: endpoint.bindingTransitionGeneration
                )
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(
                    anyActive: [duplicateIncarnation],
                    outbound: [duplicateIncarnation]
                )
                await manager.notifyToolListChangedForAgentSession(sessionID)
                let countAfterDuplicateIncarnation = await testConnection.toolListChangedCount()
                XCTAssertEqual(countAfterDuplicateIncarnation, countAfterSettledList)
                let duplicateNames = try await manager.debugListToolNames(for: connectionID)
                XCTAssertFalse(duplicateNames.contains(MCPWindowToolName.agentSessionLink))

                await manager.debugSetActiveSessionLinkEndpointsForTesting([endpoint])
                _ = try await manager.debugListToolNames(for: connectionID)
                let restoredProjection = await manager.debugRunCatalogProjection(for: runID)
                XCTAssertTrue(try XCTUnwrap(restoredProjection).isReady)
                let countBeforeDuplicateInvalidations = await testConnection.toolListChangedCount()
                await manager.notifyToolListChangedForAgentSession(sessionID)
                await manager.notifyToolListChangedForAgentSession(sessionID)
                let projectionAfterDuplicates = await manager.debugRunCatalogProjection(for: runID)
                XCTAssertTrue(try XCTUnwrap(projectionAfterDuplicates).isReady)
                let countAfterDuplicateInvalidations = await testConnection.toolListChangedCount()
                XCTAssertEqual(countAfterDuplicateInvalidations, countBeforeDuplicateInvalidations)

                await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                let hasCatalogStateAfterCleanup = await manager.debugHasRunCatalogState(for: runID)
                XCTAssertFalse(hasCatalogStateAfterCleanup)
            }
        #else
            throw XCTSkip("Run catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    /// The production trigger path for the Codex session-link catalog repair, end to end.
    ///
    /// Nothing here calls `agentSessionLinkPublishRunCatalogProjection` directly. A real `tools/list`
    /// is served while the observer holds no grant, so the returned catalog truthfully omits
    /// `agent_session_link`. Restoring the outbound grant then drives
    /// `ServerNetworkManager.notifyToolListChangedForAgentSession` — the exact call
    /// `AgentSessionLinkRuntimeBridge.invalidateToolAdvertisement(forObserverSession:)` makes on every
    /// successful activation, including the launch coordinator's restored establishment — which
    /// republishes the *preserved* returned presence (`false`) alongside the now-live outbound
    /// presence (`true`).
    ///
    /// That false/live-true pair is the stuck state: `agentSessionLinkPromptContext` fails closed for
    /// the established run, so the repair must retire the process run while preserving the Codex
    /// conversation, exactly once.
    @MainActor
    func testRestoredOutboundGrantInvalidationRepairsCodexCatalogThroughServerProjection() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease(owner: #function) { _ in
                try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                await manager.setEnabled(true)
                let window = makeWindow()
                await window.workspaceManager.awaitInitialized()
                let registration = try await AppDomainRuntimeComposition.shared.register(
                    window.mcpServer.windowMCPToolCatalogService
                )
                let runID = UUID()
                let connectionID = UUID()
                let tabID = UUID()
                let conversationID = "restored-oversight-thread"
                let rolloutPath = "/tmp/restored-oversight-rollout.jsonl"
                try await installRoutingSnapshot(for: tabID, in: window)
                let session = window.agentModeViewModel.session(for: tabID)
                let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
                session.selectedAgent = .codexExec
                session.hasLoadedPersistedState = true
                session.installRunID(runID)
                session.codexConversationID = conversationID
                session.codexRolloutPath = rolloutPath
                session.codexController = controller
                _ = try XCTUnwrap(window.agentModeViewModel.test_ensureSessionBoundToTab(session))
                let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                    window.agentModeViewModel,
                    tabID: tabID
                )
                addTeardownBlock { @MainActor in
                    await self.manager.debugSetSessionLinkCatalogEndpointsForTesting(
                        anyActive: nil,
                        outbound: nil
                    )
                    await self.cleanup(
                        runID: runID,
                        connectionID: connectionID,
                        windowID: window.windowID,
                        expectedPID: getpid()
                    )
                    await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                    WindowStatesManager.shared.unregisterWindowState(window)
                }

                // Before restoration the observer holds no link at all, so the served catalog is
                // truthfully missing the tool and the projection is honestly unready.
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(anyActive: [], outbound: [])
                await installAuthoritativePolicy(
                    runID: runID,
                    tabID: tabID,
                    windowID: window.windowID
                )
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                let testConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: connectionID,
                    connection: testConnection,
                    pendingClientID: clientName
                )
                let applied = await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    sessionKey: "catalog-repair-\(runID.uuidString)",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
                XCTAssertEqual(applied.outcome, "applied")

                let names = try await manager.debugListToolNames(for: connectionID)
                XCTAssertFalse(names.contains(MCPWindowToolName.agentSessionLink))
                let unlinkedProjection = await manager.debugRunCatalogProjection(for: runID)
                let unlinked = try XCTUnwrap(unlinkedProjection)
                XCTAssertEqual(unlinked.hasAgentSessionLink, false)
                XCTAssertEqual(unlinked.hasActiveOutboundLink, false)
                XCTAssertNil(
                    session.codexSessionLinkCatalogRepairSourceGeneration,
                    "an honest false/false catalog is not a mismatch"
                )
                XCTAssertNotNil(session.codexController)

                let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                let sourceGeneration = session.codexControllerGeneration
                await manager.debugSetSessionLinkCatalogEndpointsForTesting(
                    anyActive: [endpoint],
                    outbound: [endpoint]
                )
                await manager.notifyToolListChangedForAgentSession(sessionID)

                let stuckProjection = await manager.debugRunCatalogProjection(for: runID)
                let stuck = try XCTUnwrap(stuckProjection)
                XCTAssertEqual(stuck.hasAgentSessionLink, false)
                XCTAssertEqual(stuck.hasActiveOutboundLink, true)
                XCTAssertEqual(stuck.routeToken?.observerEndpoint, endpoint)
                XCTAssertFalse(stuck.isReady)

                XCTAssertNil(session.runID, "the stale process run is retired so cold bootstrap applies")
                XCTAssertNil(session.codexController, "exactly one controller replacement")
                XCTAssertEqual(
                    session.codexConversationID,
                    conversationID,
                    "the Codex conversation survives the repair"
                )
                XCTAssertEqual(session.codexRolloutPath, rolloutPath)
                XCTAssertEqual(session.codexSessionLinkCatalogRepairSourceGeneration, sourceGeneration)
                XCTAssertNotEqual(sourceGeneration, session.codexControllerGeneration)
            }
        #else
            throw XCTSkip("Run catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testRunCatalogObservationHandoverRejectsLatePredecessorCompletionAndRemoval() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease(owner: #function) { _ in
                try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                await manager.setEnabled(true)
                let window = makeWindow()
                await window.workspaceManager.awaitInitialized()
                let registration = try await AppDomainRuntimeComposition.shared.register(
                    window.mcpServer.windowMCPToolCatalogService
                )
                let runID = UUID()
                let tabID = UUID()
                let predecessorConnectionID = UUID()
                let successorConnectionID = UUID()
                try await installRoutingSnapshot(for: tabID, in: window)
                let session = window.agentModeViewModel.session(for: tabID)
                session.selectedAgent = .openCode
                session.hasLoadedPersistedState = true
                session.installRunID(runID)
                _ = try XCTUnwrap(window.agentModeViewModel.test_ensureSessionBoundToTab(session))
                let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                    window.agentModeViewModel,
                    tabID: tabID
                )
                addTeardownBlock { @MainActor in
                    await self.manager.debugSetActiveSessionLinkEndpointsForTesting(nil)
                    await self.manager.removeConnection(predecessorConnectionID)
                    await self.cleanup(
                        runID: runID,
                        connectionID: successorConnectionID,
                        windowID: window.windowID,
                        expectedPID: getpid()
                    )
                    await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                    WindowStatesManager.shared.unregisterWindowState(window)
                }

                await manager.debugSetActiveSessionLinkEndpointsForTesting([endpoint])
                await installAuthoritativePolicy(
                    runID: runID,
                    tabID: tabID,
                    windowID: window.windowID
                )
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                let predecessorConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: predecessorConnectionID,
                    connection: predecessorConnection,
                    pendingClientID: clientName
                )
                let predecessorApplication = await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: predecessorConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    sessionKey: "run-catalog-predecessor-\(runID.uuidString)",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
                XCTAssertEqual(predecessorApplication.outcome, "applied")
                let predecessorRouteToken = await manager.authoritativeRunCatalogRouteToken(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: tabID
                )
                let predecessorToken = try XCTUnwrap(predecessorRouteToken)
                _ = try await manager.debugListToolNames(for: predecessorConnectionID)
                let predecessorReady = await manager.debugRunCatalogProjection(for: runID)
                XCTAssertEqual(predecessorReady?.routeToken, predecessorToken)

                await installAuthoritativePolicy(
                    runID: runID,
                    tabID: tabID,
                    windowID: window.windowID
                )
                let projectionWhileHandoverPending = await manager.debugRunCatalogProjection(for: runID)
                XCTAssertEqual(
                    projectionWhileHandoverPending?.routeToken,
                    predecessorToken,
                    "installing a pending handover must not retract the committed predecessor"
                )
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                let successorConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: successorConnectionID,
                    connection: successorConnection,
                    pendingClientID: clientName
                )
                let successorApplication = await manager.debugApplyPendingPolicy(
                    clientName: clientName,
                    connectionID: successorConnectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: "repoprompt_ce_cli_debug",
                    sessionKey: "run-catalog-successor-\(runID.uuidString)",
                    pidGateTimeout: 0.25,
                    requireRunRouting: true
                )
                XCTAssertEqual(successorApplication.outcome, "applied")
                XCTAssertFalse(
                    window.mcpServer.hasCurrentRunCatalogRouteToken(
                        predecessorToken,
                        expectedTabID: tabID
                    ),
                    "the predecessor token must stop matching as soon as C2 owns the MainActor route"
                )
                let retractedProjection = await manager.debugRunCatalogProjection(for: runID)
                XCTAssertNil(
                    retractedProjection,
                    "C2 is authoritative but has not published a tools/list observation yet"
                )

                let successorRouteToken = await manager.authoritativeRunCatalogRouteToken(
                    runID: runID,
                    windowID: window.windowID,
                    tabID: tabID
                )
                let successorToken = try XCTUnwrap(successorRouteToken)
                XCTAssertEqual(successorToken.connectionID, successorConnectionID)
                _ = try await manager.debugListToolNames(for: successorConnectionID)
                let successorReadyProjection = await manager.debugRunCatalogProjection(for: runID)
                let successorReady = try XCTUnwrap(successorReadyProjection)
                XCTAssertTrue(successorReady.isReady)
                XCTAssertEqual(successorReady.routeToken, successorToken)

                let successorNotificationCount = await successorConnection.toolListChangedCount()
                await manager.debugCompleteRunCatalogObservation(
                    connectionID: predecessorConnectionID,
                    initialRouteToken: predecessorToken,
                    returnedSessionLinkPresence: true
                )
                let projectionAfterLateCompletion = await manager.debugRunCatalogProjection(for: runID)
                XCTAssertEqual(
                    projectionAfterLateCompletion,
                    successorReady,
                    "late predecessor completion must not overwrite the successor observation"
                )
                let notificationCountAfterLateCompletion = await successorConnection.toolListChangedCount()
                XCTAssertEqual(
                    notificationCountAfterLateCompletion,
                    successorNotificationCount + 1,
                    "mismatch recovery must notify the authoritative successor"
                )

                await manager.removeConnection(predecessorConnectionID)
                let projectionAfterPredecessorRemoval = await manager.debugRunCatalogProjection(for: runID)
                XCTAssertEqual(
                    projectionAfterPredecessorRemoval,
                    successorReady,
                    "predecessor removal must not terminate the successor observation"
                )
            }
        #else
            throw XCTSkip("Run catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testFullRestartClearsRunCatalogObservationWaitersAndProjectionBeforeSameRunReconnect() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease(owner: #function) { _ in
                try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                await manager.setEnabled(true)
                let fixture = try await makeRunCatalogFixture()
                let predecessorConnectionID = UUID()
                let successorConnectionID = UUID()
                addTeardownBlock { @MainActor in
                    await self.manager.debugSetActiveSessionLinkEndpointsForTesting(nil)
                    await self.cleanup(
                        runID: fixture.runID,
                        connectionID: successorConnectionID,
                        windowID: fixture.window.windowID,
                        expectedPID: getpid()
                    )
                    await AppDomainRuntimeComposition.shared.unregister(fixture.registrationHandle)
                    WindowStatesManager.shared.unregisterWindowState(fixture.window)
                }

                await manager.debugSetActiveSessionLinkEndpointsForTesting([fixture.endpoint])
                let predecessorConnection = MCPPolicyAuthorityTestConnection()
                let predecessorToken = try await installPendingCatalogConnection(
                    fixture: fixture,
                    connectionID: predecessorConnectionID,
                    connection: predecessorConnection,
                    sessionKey: "run-catalog-restart-predecessor"
                )
                _ = try await manager.debugListToolNames(for: predecessorConnectionID)
                let predecessorProjection = await manager.debugRunCatalogProjection(for: fixture.runID)
                XCTAssertEqual(predecessorProjection?.routeToken, predecessorToken)

                let staleEndpoint = DomainAgentSessionLinkEndpointIdentity(
                    windowID: fixture.endpoint.windowID,
                    workspaceID: fixture.endpoint.workspaceID,
                    tabID: fixture.endpoint.tabID,
                    sessionID: fixture.endpoint.sessionID,
                    persistentBindingGeneration: fixture.endpoint.persistentBindingGeneration,
                    bindingTransitionGeneration: fixture.endpoint.bindingTransitionGeneration &+ 1
                )
                let waiter = Task {
                    await self.manager.awaitRunCatalogReadiness(
                        runID: fixture.runID,
                        observerEndpoint: staleEndpoint,
                        timeout: 30
                    )
                }
                let waiterRegistered = await waitUntil {
                    await self.manager.debugRunCatalogWaiterCount(for: fixture.runID) == 1
                }
                XCTAssertTrue(waiterRegistered)

                await manager.stop()
                let waiterOutcome = await waiter.value
                let hasCatalogStateAfterStop = await manager.debugHasRunCatalogState(for: fixture.runID)
                XCTAssertEqual(waiterOutcome, .superseded)
                XCTAssertFalse(hasCatalogStateAfterStop)
                let invalidatedProjection = fixture.window.agentModeViewModel
                    .agentSessionLinkRunCatalogProjectionByEndpoint[fixture.endpoint]
                XCTAssertEqual(invalidatedProjection?.runID, fixture.runID)
                XCTAssertFalse(try XCTUnwrap(invalidatedProjection).isReady)

                _ = await manager.start()
                await manager.setEnabled(true)
                let successorConnection = MCPPolicyAuthorityTestConnection()
                let successorToken = try await installPendingCatalogConnection(
                    fixture: fixture,
                    connectionID: successorConnectionID,
                    connection: successorConnection,
                    sessionKey: "run-catalog-restart-successor"
                )
                XCTAssertNotEqual(successorToken.connectionLifecycleGeneration, predecessorToken.connectionLifecycleGeneration)
                _ = try await manager.debugListToolNames(for: successorConnectionID)
                let successorProjection = await manager.debugRunCatalogProjection(for: fixture.runID)
                let successorReady = try XCTUnwrap(successorProjection)
                XCTAssertTrue(successorReady.isReady)
                XCTAssertEqual(successorReady.routeToken, successorToken)
            }
        #else
            throw XCTSkip("Run catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testDirectRunMappingRetractsReadyPredecessorUntilSuccessorListsTools() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease(owner: #function) { _ in
                try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                await manager.setEnabled(true)
                let fixture = try await makeRunCatalogFixture()
                let predecessorConnectionID = UUID()
                let successorConnectionID = UUID()
                addTeardownBlock { @MainActor in
                    await self.manager.debugSetActiveSessionLinkEndpointsForTesting(nil)
                    await self.manager.removeConnection(predecessorConnectionID)
                    await self.cleanup(
                        runID: fixture.runID,
                        connectionID: successorConnectionID,
                        windowID: fixture.window.windowID,
                        expectedPID: getpid()
                    )
                    await AppDomainRuntimeComposition.shared.unregister(fixture.registrationHandle)
                    WindowStatesManager.shared.unregisterWindowState(fixture.window)
                }

                await manager.debugSetActiveSessionLinkEndpointsForTesting([fixture.endpoint])
                let predecessorConnection = MCPPolicyAuthorityTestConnection()
                let predecessorToken = try await installPendingCatalogConnection(
                    fixture: fixture,
                    connectionID: predecessorConnectionID,
                    connection: predecessorConnection,
                    sessionKey: "run-catalog-direct-predecessor"
                )
                _ = try await manager.debugListToolNames(for: predecessorConnectionID)
                let predecessorProjection = await manager.debugRunCatalogProjection(for: fixture.runID)
                XCTAssertEqual(predecessorProjection?.routeToken, predecessorToken)

                let successorConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: successorConnectionID,
                    connection: successorConnection,
                    pendingClientID: clientName
                )
                let mapped = await manager.mapConnectionToRunID(
                    successorConnectionID,
                    runID: fixture.runID,
                    windowID: fixture.window.windowID
                )
                XCTAssertTrue(mapped)
                let mappedProjection = await manager.debugRunCatalogProjection(for: fixture.runID)
                XCTAssertNil(
                    mappedProjection,
                    "predecessor teardown may remove the server observation after publishing its unready state"
                )
                let blockedProjection = try XCTUnwrap(
                    fixture.window.agentModeViewModel
                        .agentSessionLinkRunCatalogProjectionByEndpoint[fixture.endpoint]
                )
                XCTAssertFalse(blockedProjection.isReady)
                XCTAssertEqual(
                    blockedProjection.routeToken,
                    predecessorToken,
                    "the predecessor token is retained only to route its unready projection"
                )
                XCTAssertFalse(
                    fixture.window.mcpServer.hasCurrentRunCatalogRouteToken(
                        predecessorToken,
                        expectedTabID: fixture.tabID
                    )
                )

                let authoritativeSuccessorToken = await manager.authoritativeRunCatalogRouteToken(
                    runID: fixture.runID,
                    windowID: fixture.window.windowID,
                    tabID: fixture.tabID
                )
                let successorToken = try XCTUnwrap(authoritativeSuccessorToken)
                XCTAssertEqual(successorToken.connectionID, successorConnectionID)
                _ = try await manager.debugListToolNames(for: successorConnectionID)
                let successorProjection = await manager.debugRunCatalogProjection(for: fixture.runID)
                let successorReady = try XCTUnwrap(successorProjection)
                XCTAssertTrue(successorReady.isReady)
                XCTAssertEqual(successorReady.routeToken, successorToken)
            }
        #else
            throw XCTSkip("Run catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    @MainActor
    func testStaleOwnedTerminationCannotRemoveSuccessorObservationOrSupersedeLaterWaiter() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease(owner: #function) { _ in
                try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                await manager.setEnabled(true)
                let fixture = try await makeRunCatalogFixture()
                let predecessorConnectionID = UUID()
                let successorConnectionID = UUID()
                addTeardownBlock { @MainActor in
                    await self.manager.debugResumeRunCatalogPublicationBeforeMainActor()
                    await self.manager.debugSetActiveSessionLinkEndpointsForTesting(nil)
                    await self.cleanup(
                        runID: fixture.runID,
                        connectionID: successorConnectionID,
                        windowID: fixture.window.windowID,
                        expectedPID: getpid()
                    )
                    await AppDomainRuntimeComposition.shared.unregister(fixture.registrationHandle)
                    WindowStatesManager.shared.unregisterWindowState(fixture.window)
                }

                await manager.debugSetActiveSessionLinkEndpointsForTesting([fixture.endpoint])
                let predecessorConnection = MCPPolicyAuthorityTestConnection()
                _ = try await installPendingCatalogConnection(
                    fixture: fixture,
                    connectionID: predecessorConnectionID,
                    connection: predecessorConnection,
                    sessionKey: "run-catalog-termination-predecessor"
                )
                _ = try await manager.debugListToolNames(for: predecessorConnectionID)

                await manager.debugSuspendNextRunCatalogPublicationBeforeMainActor()
                let predecessorRemoval = Task {
                    await self.manager.removeConnection(predecessorConnectionID)
                }
                let terminationSuspended = await waitUntil {
                    await self.manager.debugIsRunCatalogPublicationBeforeMainActorSuspended()
                }
                XCTAssertTrue(terminationSuspended)

                let successorConnection = MCPPolicyAuthorityTestConnection()
                await manager.debugInstallDirectAdmissionConnectionForTesting(
                    connectionID: successorConnectionID,
                    connection: successorConnection,
                    pendingClientID: clientName
                )
                let successorMapped = await manager.mapConnectionToRunID(
                    successorConnectionID,
                    runID: fixture.runID,
                    windowID: fixture.window.windowID
                )
                XCTAssertTrue(successorMapped)
                _ = try await manager.debugListToolNames(for: successorConnectionID)
                let successorProjection = await manager.debugRunCatalogProjection(for: fixture.runID)
                let successorReady = try XCTUnwrap(successorProjection)
                XCTAssertTrue(successorReady.isReady)
                XCTAssertEqual(successorReady.routeToken?.connectionID, successorConnectionID)

                let laterEndpoint = DomainAgentSessionLinkEndpointIdentity(
                    windowID: fixture.endpoint.windowID,
                    workspaceID: fixture.endpoint.workspaceID,
                    tabID: fixture.endpoint.tabID,
                    sessionID: fixture.endpoint.sessionID,
                    persistentBindingGeneration: fixture.endpoint.persistentBindingGeneration,
                    bindingTransitionGeneration: fixture.endpoint.bindingTransitionGeneration &+ 1
                )
                let laterWaiter = Task {
                    await self.manager.awaitRunCatalogReadiness(
                        runID: fixture.runID,
                        observerEndpoint: laterEndpoint,
                        timeout: 30
                    )
                }
                let laterWaiterRegistered = await waitUntil {
                    await self.manager.debugRunCatalogWaiterCount(for: fixture.runID) == 1
                }
                XCTAssertTrue(laterWaiterRegistered)

                await manager.debugResumeRunCatalogPublicationBeforeMainActor()
                await predecessorRemoval.value
                let projectionAfterStaleTermination = await manager.debugRunCatalogProjection(for: fixture.runID)
                let waiterCountAfterStaleTermination = await manager.debugRunCatalogWaiterCount(for: fixture.runID)
                XCTAssertEqual(projectionAfterStaleTermination, successorReady)
                XCTAssertEqual(waiterCountAfterStaleTermination, 1)

                laterWaiter.cancel()
                let laterWaiterOutcome = await laterWaiter.value
                XCTAssertEqual(laterWaiterOutcome, .cancelled)
            }
        #else
            throw XCTSkip("Run catalog observation diagnostics require DEBUG helpers.")
        #endif
    }

    #if DEBUG
        private struct RunCatalogTestFixture {
            let window: WindowState
            let registrationHandle: MCPDomainToolRegistrationHandle
            let runID: UUID
            let tabID: UUID
            let endpoint: DomainAgentSessionLinkEndpointIdentity
        }

        @MainActor
        private func makeRunCatalogFixture() async throws -> RunCatalogTestFixture {
            let window = makeWindow()
            await window.workspaceManager.awaitInitialized()
            let registration = try await AppDomainRuntimeComposition.shared.register(
                window.mcpServer.windowMCPToolCatalogService
            )
            let runID = UUID()
            let tabID = UUID()
            try await installRoutingSnapshot(for: tabID, in: window)
            let session = window.agentModeViewModel.session(for: tabID)
            session.selectedAgent = .openCode
            session.hasLoadedPersistedState = true
            session.installRunID(runID)
            _ = try XCTUnwrap(window.agentModeViewModel.test_ensureSessionBoundToTab(session))
            let endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(
                window.agentModeViewModel,
                tabID: tabID
            )
            return RunCatalogTestFixture(
                window: window,
                registrationHandle: registration.handle,
                runID: runID,
                tabID: tabID,
                endpoint: endpoint
            )
        }

        private func installPendingCatalogConnection(
            fixture: RunCatalogTestFixture,
            connectionID: UUID,
            connection: MCPPolicyAuthorityTestConnection,
            sessionKey: String
        ) async throws -> AgentSessionLinkRunCatalogRouteToken {
            await installAuthoritativePolicy(
                runID: fixture.runID,
                tabID: fixture.tabID,
                windowID: fixture.window.windowID
            )
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: fixture.runID)
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: connection,
                pendingClientID: clientName
            )
            let application = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: true
            )
            XCTAssertEqual(application.outcome, "applied")
            let routeToken = await manager.authoritativeRunCatalogRouteToken(
                runID: fixture.runID,
                windowID: fixture.window.windowID,
                tabID: fixture.tabID
            )
            return try XCTUnwrap(routeToken)
        }

        @MainActor
        private func installRoutingSnapshot(for tabID: UUID, in window: WindowState) async throws {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Run catalog observation \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let switchResult = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "runCatalogObservationInitial"
            )
            XCTAssertEqual(switchResult, .switched)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                ComposeTabState(id: tabID, name: "Run catalog observation")
            ]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabID
            let reloadResult = await window.workspaceManager.reactivateWorkspaceAfterReplacement(
                window.workspaceManager.workspaces[workspaceIndex],
                reason: "runCatalogObservationTab"
            )
            XCTAssertEqual(reloadResult, .switched)
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        }

        @MainActor
        private func makeWindow() -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            return window
        }

        private func installPolicy(runID: UUID, windowID: Int) async {
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "OpenCode routing race test",
                ttl: 10,
                tabID: nil,
                runID: runID,
                additionalTools: nil,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            )
        }

        private func installAuthoritativePolicy(
            runID: UUID,
            tabID: UUID?,
            windowID: Int,
            oneShot: Bool = true,
            taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil
        ) async {
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: oneShot,
                reason: "Authoritative PID-owned route test",
                ttl: 10,
                tabID: tabID,
                runID: runID,
                additionalTools: nil,
                purpose: .agentModeRun,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: true
            )
        }

        private func seedLiveAffinity(
            sessionKey: String,
            windowID: Int
        ) async -> (runID: UUID, connectionID: UUID, windowID: Int) {
            let runID = UUID()
            let connectionID = UUID()
            await installPolicy(runID: runID, windowID: windowID)
            await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
            let result = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(getpid()),
                bootstrapClientName: "repoprompt_ce_cli_debug",
                sessionKey: sessionKey,
                pidGateTimeout: 0.25,
                requireRunRouting: false
            )
            XCTAssertEqual(result.outcome, "applied")
            XCTAssertEqual(result.runID, runID)
            await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
            return (runID, connectionID, windowID)
        }

        private func cleanup(
            runID: UUID,
            connectionID: UUID,
            windowID: Int,
            expectedPID: pid_t?
        ) async {
            if let expectedPID {
                await manager.clearExpectedAgentPID(expectedPID, for: clientName, runID: runID)
            }
            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
            await manager.removeConnection(connectionID)
            await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
        }

        private func waitUntil(
            timeout: TimeInterval = 1.0,
            condition: @escaping () async -> Bool
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if await condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            } while Date() < deadline
            return false
        }

        private func waitForEvent(
            _ event: String,
            runID: UUID,
            timeout: TimeInterval = 1.0
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let payload = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 100)
                let events = payload["events"] as? [[String: Any]] ?? []
                if events.contains(where: { $0["event"] as? String == event }) {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            } while Date() < deadline
            return false
        }

        private struct SleepingProcessTree {
            let parent: Process
            let childPID: pid_t
            let parentExited: DispatchSemaphore

            var parentPID: pid_t {
                parent.processIdentifier
            }

            func terminate() {
                _ = Darwin.kill(childPID, SIGTERM)
                _ = Darwin.kill(parentPID, SIGTERM)
                guard parentExited.wait(timeout: .now() + 0.25) == .timedOut else {
                    parent.waitUntilExit()
                    return
                }

                _ = Darwin.kill(childPID, SIGKILL)
                _ = Darwin.kill(parentPID, SIGKILL)
                if parentExited.wait(timeout: .now() + 1.0) == .success {
                    parent.waitUntilExit()
                }
            }
        }

        private func makeSleepingProcessTree() throws -> SleepingProcessTree {
            let process = Process()
            let stdout = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3",
                "-c",
                "import subprocess; child=subprocess.Popen(['/bin/sleep','30']); print(child.pid, flush=True); child.wait()"
            ]
            process.standardOutput = stdout
            let parentExited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in parentExited.signal() }
            try process.run()
            var data = Data()
            while data.count < 32 {
                guard let byte = try stdout.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { break }
                if byte == Data([0x0A]) {
                    break
                }
                data.append(byte)
            }
            guard let text = String(data: data, encoding: .utf8),
                  let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                process.terminate()
                process.waitUntilExit()
                throw NSError(
                    domain: "MCPAgentPolicyAdmissionRaceTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to read child PID from process-tree fixture."]
                )
            }
            return SleepingProcessTree(parent: process, childPID: childPID, parentExited: parentExited)
        }
    #endif
}

private actor MCPPolicyAuthorityTestConnection: MCPServerConnection {
    private var toolListChangeNotifications = 0

    nonisolated var isFilesystemBacked: Bool {
        false
    }

    nonisolated var connectionFolderURL: URL? {
        nil
    }

    nonisolated var capabilityToken: String? {
        nil
    }

    func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}
    func stop() async {}
    func abortForExecutionWatchdog() async {}
    func notifyToolListChanged() async {
        toolListChangeNotifications += 1
    }

    func toolListChangedCount() -> Int {
        toolListChangeNotifications
    }

    func connectionState() -> ConnectionStateSnapshot {
        .ready
    }

    func isViableForRetention() -> Bool {
        true
    }

    func secondsSinceLastActivity() async -> TimeInterval {
        0
    }

    func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
        nil
    }

    func responseDeliverySnapshot() async -> MCPResponseDeliverySnapshot? {
        nil
    }

    func terminate(reason _: TerminationReason, message _: String?) async {}

    func sendProgress(
        tool _: String,
        kind _: RepoPromptProgressKind,
        stage _: String,
        message _: String
    ) async {}
}
