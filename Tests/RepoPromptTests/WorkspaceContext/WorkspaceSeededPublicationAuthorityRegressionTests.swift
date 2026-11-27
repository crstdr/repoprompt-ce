import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptShared
import RepoPromptVCS
@testable import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore
import XCTest

#if DEBUG
    final class WorkspaceSeededPublicationAuthorityRegressionTests: XCTestCase {
        private enum HelperEnvironment {
            static let isHelper = "REPOPROMPT_SEEDED_PUBLICATION_AUTHORITY_HELPER"
            static let readyMarkerPath = "REPOPROMPT_SEEDED_PUBLICATION_AUTHORITY_READY_MARKER"
            static let completionMarkerPath = "REPOPROMPT_SEEDED_PUBLICATION_AUTHORITY_COMPLETION_MARKER"
            static let fixtureParentPath = "REPOPROMPT_SEEDED_PUBLICATION_AUTHORITY_FIXTURE_PARENT"
        }

        private static let readyMarker = "seeded-publication-authority-fixture-ready\n"
        private static let completionMarker = "seeded-publication-authority-commit-completed\n"

        /// The authority and watermark permits are intentionally non-recursive. This
        /// executes the real pending seeded-root commit after a first published root
        /// has installed the static all-loaded cache identity. The helper process
        /// contains the known-bad self-deadlock so its forced cleanup cannot strand
        /// the shared XCTest process on the baseline.
        func testPendingSeededPublicationCompletesWhenPublishedFencesAreQueryable() async throws {
            if ProcessInfo.processInfo.environment[HelperEnvironment.isHelper] == "1" {
                try await runSeededPublicationHelper()
                return
            }

            let root = try makeTestDirectory(name: "seeded-publication-authority-helper")
            let coordinationDirectory = root.appendingPathComponent("coordination", isDirectory: true)
            let helperTemporaryDirectory = root.appendingPathComponent("helper-tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: coordinationDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: helperTemporaryDirectory, withIntermediateDirectories: true)

            let readyMarkerURL = coordinationDirectory.appendingPathComponent("ready")
            let completionMarkerURL = coordinationDirectory.appendingPathComponent("completed")
            let result = try runHelperTestProcess(
                readyMarkerURL: readyMarkerURL,
                completionMarkerURL: completionMarkerURL,
                helperTemporaryDirectory: helperTemporaryDirectory
            )

            XCTAssertEqual(
                result.terminationStatus,
                0,
                "Seeded publication helper XCTest failed:\n\(result.output)"
            )
            XCTAssertEqual(
                try String(contentsOf: completionMarkerURL, encoding: .utf8),
                Self.completionMarker,
                "The helper must write its completion marker only after the second real pending seeded-root commit returns.\n\(result.output)"
            )
        }

        private enum MarkerWaitOutcome {
            case observed
            case deadlineExpired
            case childTerminated
        }

        private func runHelperTestProcess(
            readyMarkerURL: URL,
            completionMarkerURL: URL,
            helperTemporaryDirectory: URL
        ) throws -> (terminationStatus: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "xctest",
                "-XCTest",
                "RepoPromptTests.WorkspaceSeededPublicationAuthorityRegressionTests",
                Bundle(for: WorkspaceSeededPublicationAuthorityRegressionTests.self).bundleURL.path
            ]

            var environment = ProcessInfo.processInfo.environment
            environment[HelperEnvironment.isHelper] = "1"
            environment[HelperEnvironment.readyMarkerPath] = readyMarkerURL.path
            environment[HelperEnvironment.completionMarkerPath] = completionMarkerURL.path
            environment[HelperEnvironment.fixtureParentPath] = helperTemporaryDirectory.path
            environment["TMPDIR"] = helperTemporaryDirectory.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice

            let outputURL = readyMarkerURL.deletingLastPathComponent().appendingPathComponent("helper.log")
            try Data().write(to: outputURL)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }
            process.standardOutput = outputHandle
            process.standardError = outputHandle

            let completion = DispatchSemaphore(value: 0)
            let readyOrTermination = DispatchSemaphore(value: 0)
            let completionOrTermination = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                completion.signal()
                readyOrTermination.signal()
                completionOrTermination.signal()
            }
            try process.run()

            let readyOutcome: MarkerWaitOutcome
            do {
                readyOutcome = try waitForMarker(
                    at: readyMarkerURL,
                    deadline: 30,
                    wakeSignal: readyOrTermination
                )
            } catch {
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                throw helperProcessFailure(
                    code: 1,
                    description: "Could not observe the helper ready marker: \(error.localizedDescription)",
                    reaped: reaped,
                    output: output
                )
            }
            guard case .observed = readyOutcome else {
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                let description = switch readyOutcome {
                case .deadlineExpired:
                    "Seeded publication helper did not reach the second commit before the 30-second startup deadline."
                case .childTerminated:
                    "Seeded publication helper exited before reaching the second commit."
                case .observed:
                    "unreachable"
                }
                throw helperProcessFailure(code: 1, description: description, reaped: reaped, output: output)
            }

            let completionOutcome: MarkerWaitOutcome
            do {
                completionOutcome = try waitForMarker(
                    at: completionMarkerURL,
                    deadline: 3,
                    wakeSignal: completionOrTermination
                )
            } catch {
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                throw helperProcessFailure(
                    code: 2,
                    description: "Could not observe the helper completion marker: \(error.localizedDescription)",
                    reaped: reaped,
                    output: output
                )
            }
            switch completionOutcome {
            case .observed:
                break
            case .deadlineExpired:
                let childWasRunningAtDeadline = process.isRunning
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                throw helperProcessFailure(
                    code: 2,
                    description: "Seeded publication helper exceeded the bounded post-ready commit deadline while childRunningAtDeadline=\(childWasRunningAtDeadline).",
                    reaped: reaped,
                    output: output
                )
            case .childTerminated:
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                throw helperProcessFailure(
                    code: 4,
                    description: "Seeded publication helper exited before writing its completion marker.",
                    reaped: reaped,
                    output: output
                )
            }

            if completion.wait(timeout: .now() + 10) == .timedOut {
                let reaped = terminateAndReap(process, completion: completion)
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                throw helperProcessFailure(
                    code: 3,
                    description: "Seeded publication helper did not exit after its completed commit.",
                    reaped: reaped,
                    output: output
                )
            }

            return try (process.terminationStatus, String(contentsOf: outputURL, encoding: .utf8))
        }

        private func runSeededPublicationHelper() async throws {
            var phase = "fixture"
            var sourceA: URL?
            var sourceB: URL?

            do {
                let fixtureParent = try requiredExistingDirectoryURL(HelperEnvironment.fixtureParentPath)
                let fixture = try ReviewGitRepositoryFixture(
                    name: "SeededPublicationAuthorityRegression",
                    parentDirectory: fixtureParent
                )
                defer { fixture.cleanup() }
                let readyMarkerURL = try requiredMarkerURL(HelperEnvironment.readyMarkerPath)
                let completionMarkerURL = try requiredMarkerURL(HelperEnvironment.completionMarkerPath)

                phase = "source repositories"
                sourceA = try fixture.makeRepository(
                    named: "source-a",
                    files: ["Sources/Alpha.swift": "struct Alpha {}\n"]
                )
                sourceB = try fixture.makeRepository(
                    named: "source-b",
                    files: ["Sources/Beta.swift": "struct Beta {}\n"]
                )
                let sourceA = try XCTUnwrap(sourceA)
                let sourceB = try XCTUnwrap(sourceB)
                let git = GitService()
                WorkspaceContextStartupInstrumentation.install(AppWorkspaceStartupEventRecorder())
                WorkspaceExternalReadWorkHooks.install(AppWorkspaceExternalReadWorkRecorder())
                let store = WorkspaceFileContextStore(startupFeatureFlags: .standaloneOperationalDefault())

                phase = "source snapshot admission"
                let loadedA = try await store.loadRoot(path: sourceA.path, kind: .primaryWorkspace)
                let loadedB = try await store.loadRoot(path: sourceB.path, kind: .primaryWorkspace)
                let admissionA = try await store.admitReusableSnapshotForLoadedRoot(
                    rootID: loadedA.id,
                    expectedStandardizedPath: loadedA.standardizedFullPath
                )
                let admissionB = try await store.admitReusableSnapshotForLoadedRoot(
                    rootID: loadedB.id,
                    expectedStandardizedPath: loadedB.standardizedFullPath
                )
                guard case .admitted = admissionA,
                      case .admitted = admissionB
                else {
                    throw testFailure("Source snapshot admission failed: A=\(admissionA), B=\(admissionB).")
                }

                phase = "first seeded preparation"
                let first = try await makeSeededWorktreePreparation(store: store, git: git, source: sourceA)
                phase = "first seeded publication"
                let firstRoots = try await store.commitSessionWorktreeOwnership(first.preparation)
                guard firstRoots.count == 1, let firstRoot = firstRoots.first else {
                    throw testFailure("The first seeded publication did not install exactly one root.")
                }

                phase = "static cache priming"
                _ = await store.lookupPath("Alpha.swift", profile: .uiAssisted, rootScope: .allLoaded)
                let staticCacheCount = await store.staticPathMatchSnapshotCacheCountForTesting()
                guard staticCacheCount == 1 else {
                    throw testFailure("The first publication did not cache the all-loaded static lookup identity.")
                }

                phase = "second seeded preparation"
                let second = try await makeSeededWorktreePreparation(store: store, git: git, source: sourceB)
                let firstFenceIsCurrent = await store.publishedSeededAuthorityIsCurrentForTesting(rootID: firstRoot.rootID)
                guard firstFenceIsCurrent else {
                    throw testFailure("The first published seeded authority fence was not current before the second commit.")
                }
                try Self.readyMarker.write(to: readyMarkerURL, atomically: true, encoding: .utf8)

                phase = "second seeded publication"
                let secondRoots = try await store.commitSessionWorktreeOwnership(second.preparation)
                guard secondRoots.count == 1 else {
                    throw testFailure("The second seeded publication did not install exactly one root.")
                }

                let ownership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
                guard ownership.installedOwnerCount == 2, ownership.rootClaimCount == 2 else {
                    throw testFailure("Both independently published seeded roots must retain ownership.")
                }
                try Self.completionMarker.write(to: completionMarkerURL, atomically: true, encoding: .utf8)

                await store.releaseSessionWorktreeOwnership(ownerID: first.ownerID)
                await store.releaseSessionWorktreeOwnership(ownerID: second.ownerID)
                await store.unloadRoots(ids: [loadedA.id, loadedB.id])
            } catch {
                func sourceDescription(_ source: URL?) -> String {
                    guard let source else { return "not-created" }
                    return "path=\(source.path), exists=\(FileManager.default.fileExists(atPath: source.path))"
                }
                throw testFailure(
                    "Seeded publication helper failed during \(phase), sourceA={\(sourceDescription(sourceA))}, sourceB={\(sourceDescription(sourceB))}: \(error)."
                )
            }
        }

        private func requiredMarkerURL(_ key: String) throws -> URL {
            guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else {
                throw NSError(
                    domain: "WorkspaceSeededPublicationAuthorityRegressionTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Missing helper environment \(key)"]
                )
            }
            return URL(fileURLWithPath: path)
        }

        private func requiredExistingDirectoryURL(_ key: String) throws -> URL {
            let url = try requiredMarkerURL(key)
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw testFailure("Helper fixture parent is not an existing directory: \(url.path).")
            }
            return url
        }

        private func waitForMarker(
            at markerURL: URL,
            deadline: TimeInterval,
            wakeSignal: DispatchSemaphore
        ) throws -> MarkerWaitOutcome {
            if FileManager.default.fileExists(atPath: markerURL.path) { return .observed }
            let directoryURL = markerURL.deletingLastPathComponent()
            let descriptor = Darwin.open(directoryURL.path, O_EVTONLY)
            guard descriptor >= 0 else {
                throw testFailure("Could not observe helper coordination directory: \(directoryURL.path).")
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename],
                queue: .global(qos: .utility)
            )
            source.setEventHandler {
                if FileManager.default.fileExists(atPath: markerURL.path) {
                    wakeSignal.signal()
                }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            source.resume()
            defer { source.cancel() }

            if FileManager.default.fileExists(atPath: markerURL.path) { return .observed }
            guard wakeSignal.wait(timeout: .now() + deadline) == .success else {
                return FileManager.default.fileExists(atPath: markerURL.path) ? .observed : .deadlineExpired
            }
            return FileManager.default.fileExists(atPath: markerURL.path) ? .observed : .childTerminated
        }

        private func helperProcessFailure(
            code: Int,
            description: String,
            reaped: Bool,
            output: String
        ) -> NSError {
            NSError(
                domain: "WorkspaceSeededPublicationAuthorityRegressionTests",
                code: code,
                userInfo: [
                    NSLocalizedDescriptionKey: "\(description)\(cleanupResultDescription(reaped: reaped))\n\(output)"
                ]
            )
        }

        private func terminateAndReap(_ process: Process, completion: DispatchSemaphore) -> Bool {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            return completion.wait(timeout: .now() + 5) == .success && !process.isRunning
        }

        private func cleanupResultDescription(reaped: Bool) -> String {
            reaped ? "" : " Forced helper cleanup did not reap the child within five seconds."
        }

        private func testFailure(_ description: String) -> NSError {
            NSError(
                domain: "WorkspaceSeededPublicationAuthorityRegressionTests",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }

    /// Real seeded-worktree preparation shared by tests that need a published seeded root:
    /// creates an app-managed Git worktree with a creation receipt and prepares its ownership.
    fileprivate extension XCTestCase {
        func makeSeededWorktreePreparation(
            store: WorkspaceFileContextStore,
            git: GitService,
            source: URL
        ) async throws -> (ownerID: UUID, preparation: WorkspaceSessionWorktreeOwnershipPreparation) {
            let ownerID = UUID()
            let startupContext = WorktreeStartupContext(
                agentSessionID: ownerID,
                flags: WorktreeStartupFeatureFlags(
                    observeDiffSeededWorktreeStartup: true,
                    serveDiffSeededWorktreeStartup: true
                )
            )
            let expectedGeneration = await store.nextSessionWorktreeOwnershipGeneration(ownerID: ownerID)
            let plan = try GitWorktreeDefaultPathPlanner.plan(
                GitWorktreeDefaultPathPlanner.Request(
                    mainWorktreeRoot: source,
                    existingWorktreeRoots: [source],
                    detach: true,
                    purpose: .agentStart(sessionID: ownerID.uuidString)
                )
            )
            // Receipt witnessing requires an existing, stable app-managed parent before
            // Git creates the destination. The destination itself must remain absent.
            try FileManager.default.createDirectory(
                at: plan.appManagedContainer,
                withIntermediateDirectories: true
            )
            var watchRootIsDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: plan.appManagedContainer.path,
                isDirectory: &watchRootIsDirectory
            ), watchRootIsDirectory.boolValue else {
                throw seededAuthorityFixtureFailure("The receipt witness root was not a directory: \(plan.appManagedContainer.path).")
            }
            let targetExists = FileManager.default.fileExists(atPath: plan.path.path)
            guard !targetExists else {
                throw seededAuthorityFixtureFailure("The planned worktree destination already exists: \(plan.path.path).")
            }
            let initializationContext = try GitWorktreeInitializationContext(
                agentSessionID: ownerID,
                correlationID: startupContext.correlationID,
                logicalRootPath: source.path,
                expectedOwnerBindingGeneration: expectedGeneration,
                repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""),
                observeReceipt: true
            )
            var sourceIsDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory),
                  sourceIsDirectory.boolValue
            else {
                throw seededAuthorityFixtureFailure("The source repository disappeared before real worktree creation: \(source.path).")
            }
            let creation: GitWorktreeCreateResult
            do {
                creation = try await git.createWorktreeWithResult(
                    request: plan.createRequest,
                    at: source,
                    initializationContext: initializationContext
                )
            } catch {
                throw seededAuthorityFixtureFailure(
                    "Real worktree creation failed for source=\(source.path), target=\(plan.path.path), sourceIsDirectory=\(sourceIsDirectory.boolValue): \(error)."
                )
            }
            // A plain throw (not XCTUnwrap) so callers that retry setup do not record a failure.
            guard let receipt = creation.initializationReceipt else {
                throw seededAuthorityFixtureFailure(
                    "The helper requires a real worktree creation receipt to exercise seeded publication."
                )
            }
            let targetPath = (creation.descriptor.path as NSString).standardizingPath
            if let fallback = receipt.fallbackReason() {
                let decisions = WorktreeStartupInstrumentation.receiptDecisions(
                    correlationID: startupContext.correlationID
                )
                throw seededAuthorityFixtureFailure(
                    "The real creation receipt is ineligible before Store preparation: fallback=\(fallback), creationFallback=\(String(describing: creation.initializationFallbackReason)), witness=\(receipt.witnessCoverage), decisions=\(decisions)."
                )
            }
            let hint = WorkspaceRootMaterializationHint(
                bindingID: "seeded-publication-\(ownerID.uuidString)",
                standardizedTargetPath: targetPath,
                creationReceipt: receipt,
                correlationID: startupContext.correlationID
            )
            let preparation = try await store.prepareSessionWorktreeOwnership(
                ownerID: ownerID,
                bindingFingerprint: "seeded-publication-\(ownerID.uuidString)",
                physicalRootPaths: [targetPath],
                startupContext: startupContext,
                initializationHintsByPhysicalRootPath: [targetPath: hint]
            )
            guard preparation.pendingSeededRootPreparations.count == 1 else {
                let observation = preparation.materializationHintObservationsByPhysicalRootPath[
                    targetPath
                ]
                let receiptDecisions = WorktreeStartupInstrumentation.receiptDecisions(
                    correlationID: startupContext.correlationID
                )
                throw seededAuthorityFixtureFailure(
                    "The helper did not reach the real pending seeded-root commit path for \(source.path): observation=\(String(describing: observation)), creationFallback=\(String(describing: creation.initializationFallbackReason)), receiptDecisions=\(receiptDecisions)."
                )
            }
            return (ownerID, preparation)
        }

        private func seededAuthorityFixtureFailure(_ description: String) -> NSError {
            NSError(
                domain: "WorkspaceSeededAuthorityFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }

    /// An edit's original-file read on a published seeded root parks in the Git-sync wait while a
    /// Git mutation is in flight. These tests block a real seeded root with authority events and
    /// check that the read gives up at the edit's pre-write deadline without writing anything.
    final class ApplyEditsGitSyncDeadlineTests: XCTestCase {
        private static let relativePath = "Sources/Alpha.swift"
        private static let originalText = "struct Alpha {}\n"

        private struct SeededRoot {
            let store: WorkspaceFileContextStore
            let rootID: UUID
            let file: WorkspaceFileRecord
            let fileURL: URL
            let repositoryKey: GitWorkspaceAuthorityRepositoryKey
        }

        private final class LineRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String] = []
            func append(_ line: String) {
                lock.withLock { storage.append(line) }
            }

            var lines: [String] {
                lock.withLock { storage }
            }
        }

        func testPreWriteWaitBudgetDerivesFromShortestClientAllowance() {
            XCTAssertEqual(MCPTimeoutPolicy.antigravityToolCallAbortSeconds, 180)
            XCTAssertEqual(
                MCPTimeoutPolicy.mutationPreWriteWaitBudgetSeconds,
                MCPTimeoutPolicy.antigravityToolCallAbortSeconds
                    - MCPTimeoutPolicy.responseSendDeadlineSeconds
                    - MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds
            )
            XCTAssertEqual(MCPTimeoutPolicy.mutationPreWriteWaitBudget, .seconds(145))
            XCTAssertEqual(MCPTimeoutPolicy.workspaceFreshnessWaitTimeoutSeconds, 30, "the ingress freshness check is unchanged")
        }

        func testOriginalReadGivesUpAtDeadlineWhileGitSyncIsPendingAndWritesNothing() async throws {
            let recorder = LineRecorder()
            MCPDomainMutationCall.setDebugObserverForTesting { recorder.append($0) }
            defer { MCPDomainMutationCall.setDebugObserverForTesting(nil) }

            try await withBlockableSeededRoot { seeded in
                await self.beginGitMutation(seeded, generation: 1)
                let blockedValue = await seeded.store.publishedSeededAuthoritySnapshotForTesting(rootID: seeded.rootID)
                let blocked = try XCTUnwrap(blockedValue)
                XCTAssertTrue(blocked.isBlocked)
                XCTAssertEqual(blocked.activeMutationDepth, 1)

                let call = MCPDomainMutationCall(
                    invocationID: UUID(),
                    toolName: "apply_edits",
                    watchdogEnvironment: .continuous()
                )
                let service = self.service(seeded, deadline: Self.deadline(after: .milliseconds(300)))
                do {
                    _ = try await MCPDomainMutationCall.$current.withValue(call) {
                        try await service.run(self.rewriteRequest(seeded))
                    }
                    XCTFail("the read must give up while the Git-sync check is pending")
                } catch is WorkspaceSeededAuthorityWaitTimeout {}

                XCTAssertEqual(try String(contentsOf: seeded.fileURL, encoding: .utf8), Self.originalText, "nothing was written")
                let afterTimeoutValue = await seeded.store.publishedSeededAuthoritySnapshotForTesting(rootID: seeded.rootID)
                let afterTimeout = try XCTUnwrap(afterTimeoutValue)
                XCTAssertTrue(afterTimeout.isBlocked, "timing out leaves the root blocked for reconciliation")
                XCTAssertEqual(afterTimeout.activeMutationDepth, 1)
                XCTAssertEqual(afterTimeout.waiterCount, 0, "the timed-out waiter is removed")

                let lines = recorder.lines.filter { $0.contains("call=\(call.invocationID.uuidString)") }
                XCTAssertTrue(lines.contains { $0.contains("event=end stage=git_sync_wait") && $0.contains("phase=before_read") && $0.contains("outcome=expired") }, "\(lines)")
                XCTAssertTrue(lines.contains { $0.contains("event=end stage=original_read") && $0.contains("outcome=expired") }, "\(lines)")
                XCTAssertFalse(lines.contains { $0.contains("stage=write") }, "\(lines)")
                XCTAssertFalse(lines.contains { $0.contains(seeded.fileURL.path) || $0.contains("Alpha") }, "timings carry no paths or contents")

                await self.finishGitMutation(seeded, generation: 2)
                await seeded.store.waitForPublishedSeededAuthorityReconciliationForTesting(rootID: seeded.rootID)
                let current = await seeded.store.publishedSeededAuthorityIsCurrentForTesting(rootID: seeded.rootID)
                XCTAssertTrue(current, "reconciliation still completes after the timeout")
                let retried = try await self.service(seeded, deadline: Self.deadline(after: .seconds(30)))
                    .run(self.rewriteRequest(seeded))
                XCTAssertEqual(retried.editsApplied, 1)
                XCTAssertEqual(try String(contentsOf: seeded.fileURL, encoding: .utf8), "struct Beta {}\n")
            }
        }

        func testCurrentRootEditIsUnaffectedAndRecordsReadAndWriteTimings() async throws {
            let recorder = LineRecorder()
            MCPDomainMutationCall.setDebugObserverForTesting { recorder.append($0) }
            defer { MCPDomainMutationCall.setDebugObserverForTesting(nil) }

            try await withBlockableSeededRoot { seeded in
                let call = MCPDomainMutationCall(
                    invocationID: UUID(),
                    toolName: "apply_edits",
                    watchdogEnvironment: .continuous()
                )
                let result = try await MCPDomainMutationCall.$current.withValue(call) {
                    try await self.service(seeded, deadline: Self.deadline(after: .seconds(30)))
                        .run(self.rewriteRequest(seeded))
                }
                XCTAssertEqual(result.editsApplied, 1)
                XCTAssertEqual(try String(contentsOf: seeded.fileURL, encoding: .utf8), "struct Beta {}\n")

                let lines = recorder.lines.filter { $0.contains("call=\(call.invocationID.uuidString)") }
                let readAndWrite = lines.compactMap { line -> String? in
                    let fields = line.split(separator: " ").map(String.init)
                    guard let stage = fields.first(where: { $0.hasPrefix("stage=") }),
                          stage == "stage=original_read" || stage == "stage=write",
                          let event = fields.first(where: { $0.hasPrefix("event=") })
                    else { return nil }
                    let outcome = fields.first(where: { $0.hasPrefix("outcome=") })
                    return ([event, stage] + (outcome.map { [$0] } ?? [])).joined(separator: " ")
                }
                XCTAssertEqual(readAndWrite, [
                    "event=begin stage=original_read",
                    "event=end stage=original_read outcome=completed",
                    "event=begin stage=write",
                    "event=end stage=write outcome=completed"
                ])
                XCTAssertTrue(lines.allSatisfy { !$0.contains("event=end") || $0.contains("duration_ms=") }, "\(lines)")
                XCTAssertFalse(lines.contains { $0.contains(seeded.fileURL.path) || $0.contains("Alpha") }, "timings carry no paths or contents")
            }
        }

        func testCancelledReadWhileParkedReportsCancellationAndRemovesWaiter() async throws {
            try await withBlockableSeededRoot { seeded in
                await self.beginGitMutation(seeded, generation: 1)
                let service = self.service(seeded, deadline: Self.deadline(after: .seconds(60)))
                let request = self.rewriteRequest(seeded)
                let read = Task { try await service.run(request) }
                await seeded.store.waitForPublishedSeededAuthorityWaiterForTesting(rootID: seeded.rootID)
                read.cancel()
                do {
                    _ = try await read.value
                    XCTFail("cancelled read must not succeed")
                } catch is CancellationError {
                } catch {
                    XCTFail("caller cancellation stays cancellation, got \(error)")
                }
                let snapshotValue = await seeded.store.publishedSeededAuthoritySnapshotForTesting(rootID: seeded.rootID)
                let snapshot = try XCTUnwrap(snapshotValue)
                XCTAssertEqual(snapshot.waiterCount, 0)
                XCTAssertEqual(try String(contentsOf: seeded.fileURL, encoding: .utf8), Self.originalText)
                await self.finishGitMutation(seeded, generation: 2)
                await seeded.store.waitForPublishedSeededAuthorityReconciliationForTesting(rootID: seeded.rootID)
            }
        }

        // MARK: - Helpers

        private static func deadline(after duration: Duration) -> MCPDomainAdmissionDeadline {
            let clock = ContinuousClock()
            let origin = clock.now
            return MCPDomainAdmissionDeadline(
                instant: duration,
                now: { origin.duration(to: clock.now) },
                sleep: { try await Task.sleep(for: $0) }
            )
        }

        private func service(_ seeded: SeededRoot, deadline: MCPDomainAdmissionDeadline) -> ApplyEditsService {
            ApplyEditsService(
                engine: .default,
                host: WorkspaceFileEditHost(
                    store: seeded.store,
                    target: .existing(seeded.file),
                    originalReadDeadline: deadline
                )
            )
        }

        private func rewriteRequest(_ seeded: SeededRoot) -> ApplyEditsRequest {
            ApplyEditsRequest(
                path: seeded.file.standardizedFullPath,
                mode: .single(search: "Alpha", replace: "Beta", replaceAll: false),
                verbose: false
            )
        }

        private func beginGitMutation(_ seeded: SeededRoot, generation: UInt64) async {
            await seeded.store.handleSeededAuthorityInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
                repositoryKey: seeded.repositoryKey,
                invalidationGeneration: generation,
                acceptedMetadataWatermark: 0,
                kind: .mutationBegan(.other)
            ))
        }

        private func finishGitMutation(_ seeded: SeededRoot, generation: UInt64) async {
            await seeded.store.handleSeededAuthorityInvalidationForTesting(GitWorkspaceAuthorityInvalidationEvent(
                repositoryKey: seeded.repositoryKey,
                invalidationGeneration: generation,
                acceptedMetadataWatermark: 0,
                kind: .mutationCompleted(.other, .succeeded)
            ))
        }

        private func withBlockableSeededRoot(_ body: (SeededRoot) async throws -> Void) async throws {
            let fixture = try ReviewGitRepositoryFixture(name: "ApplyEditsGitSyncDeadline")
            defer { fixture.cleanup() }
            let source = try fixture.makeRepository(named: "source", files: [Self.relativePath: Self.originalText])
            WorkspaceContextStartupInstrumentation.install(AppWorkspaceStartupEventRecorder())
            WorkspaceExternalReadWorkHooks.install(AppWorkspaceExternalReadWorkRecorder())
            let store = WorkspaceFileContextStore(startupFeatureFlags: .standaloneOperationalDefault())
            let loaded = try await store.loadRoot(path: source.path, kind: .primaryWorkspace)
            // A freshly created repository can still deliver Git metadata events, which makes
            // seeded admission fall back as "authority unstable". Retry setup until it settles.
            var prepared: (ownerID: UUID, preparation: WorkspaceSessionWorktreeOwnershipPreparation)?
            var setupFailures: [String] = []
            for _ in 0 ..< 5 where prepared == nil {
                do {
                    let admission = try await store.admitReusableSnapshotForLoadedRoot(
                        rootID: loaded.id,
                        expectedStandardizedPath: loaded.standardizedFullPath
                    )
                    guard case .admitted = admission else {
                        setupFailures.append("admission: \(admission)")
                        try await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    prepared = try await makeSeededWorktreePreparation(store: store, git: GitService(), source: source)
                } catch {
                    setupFailures.append("preparation: \(error.localizedDescription)")
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            guard let prepared else {
                await store.unloadRoots(ids: [loaded.id])
                XCTFail("seeded root setup did not settle: \(setupFailures)")
                return
            }
            do {
                let roots = try await store.commitSessionWorktreeOwnership(prepared.preparation)
                let root = try XCTUnwrap(roots.first, "seeded publication installs one root")
                let fileValue = await store.file(rootID: root.rootID, relativePath: Self.relativePath)
                let file = try XCTUnwrap(fileValue)
                let keyValue = await store.publishedSeededAuthorityRepositoryKeyForTesting(rootID: root.rootID)
                let key = try XCTUnwrap(keyValue)
                try await body(SeededRoot(
                    store: store,
                    rootID: root.rootID,
                    file: file,
                    fileURL: URL(fileURLWithPath: file.standardizedFullPath),
                    repositoryKey: key
                ))
            } catch {
                await store.releaseSessionWorktreeOwnership(ownerID: prepared.ownerID)
                await store.unloadRoots(ids: [loaded.id])
                throw error
            }
            await store.releaseSessionWorktreeOwnership(ownerID: prepared.ownerID)
            await store.unloadRoots(ids: [loaded.id])
        }
    }
#endif
