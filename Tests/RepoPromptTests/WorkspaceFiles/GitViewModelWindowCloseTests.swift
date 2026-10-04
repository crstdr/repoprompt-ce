import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Exercises the Git lifecycle hooks called by WindowState, not full window composition.
    /// No Prompt, Agent Mode, router, provider or workspace restoration is constructed.
    @MainActor
    final class GitViewModelWindowCloseTests: XCTestCase {
        private var originalGitMode: String?
        private var owners: [(viewModel: GitViewModel, actor: GitStatusActor)] = []

        override func setUp() async throws {
            try await super.setUp()
            originalGitMode = UserDefaults.standard.string(forKey: "gitDiffInclusionMode")
            UserDefaults.standard.set(GitDiffInclusionMode.none.rawValue, forKey: "gitDiffInclusionMode")
        }

        override func tearDown() async throws {
            for owner in owners {
                await owner.viewModel.shutdownForWindowClose()
                await owner.actor.shutdown() // Also clean up when testing a broken close hook.
            }
            owners.removeAll()
            if let originalGitMode {
                UserDefaults.standard.set(originalGitMode, forKey: "gitDiffInclusionMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "gitDiffInclusionMode")
            }
            try await super.tearDown()
        }

        func testWindowCloseHookStopsStatusPollingAndRejectsLateRefreshes() async throws {
            let firstWait = expectation(description: "Open Git owner awaits its first poll")
            let secondWait = expectation(description: "Open Git owner refreshes and awaits its second poll")
            let clock = PollClock(waits: [firstWait, secondWait])
            let (viewModel, actor) = await openGitOwner(clock: clock)
            await fulfillment(of: [firstWait], timeout: 2)
            let initialSnapshot = await actor.test_latestSnapshot
            let initial = try XCTUnwrap(initialSnapshot)

            await clock.advance()
            await fulfillment(of: [secondWait], timeout: 2)
            let beforeCloseSnapshot = await actor.test_latestSnapshot
            let beforeClose = try XCTUnwrap(beforeCloseSnapshot)
            XCTAssertEqual(beforeClose.generation, initial.generation + 1)

            // These are the same hooks called by WindowState.beginClose() and tearDown().
            viewModel.prepareForWindowClose()
            await viewModel.shutdownForWindowClose()
            let hasPollerAfterClose = await actor.test_hasPollingTask
            XCTAssertFalse(hasPollerAfterClose)
            XCTAssertEqual(viewModel.test_pendingWindowCloseTaskCount, 0)

            // Exercise late observer/root work as well as a tick after the close boundary.
            await clock.advance()
            await actor.setInclusionMode(.none)
            await actor.setInclusionMode(.all)
            await actor.setSelectedRoot("/closed-window-root")
            await actor.restartPollingIfNeeded()
            let lateRefresh = await actor.refresh(trigger: .explicitRefresh)
            let afterClose = await actor.test_latestSnapshot
            let hasRestartedPoller = await actor.test_hasPollingTask
            let waits = await clock.waitCount
            XCTAssertNil(lateRefresh)
            XCTAssertEqual(afterClose?.generation, beforeClose.generation)
            XCTAssertFalse(hasRestartedPoller)
            XCTAssertEqual(waits, 2)
        }

        func testReopenedGitOwnerPollsWithoutRevivingClosedOwner() async throws {
            let closedWait = expectation(description: "First Git owner polls")
            let closedClock = PollClock(waits: [closedWait])
            let (closedViewModel, closedActor) = await openGitOwner(clock: closedClock)
            await fulfillment(of: [closedWait], timeout: 2)
            let closedSnapshot = await closedActor.test_latestSnapshot
            let closedGeneration = try XCTUnwrap(closedSnapshot).generation
            closedViewModel.prepareForWindowClose()
            await closedViewModel.shutdownForWindowClose()

            let firstWait = expectation(description: "Reopened Git owner awaits a poll")
            let secondWait = expectation(description: "Reopened Git owner refreshes and keeps polling")
            let reopenedClock = PollClock(waits: [firstWait, secondWait])
            let (reopenedViewModel, reopenedActor) = await openGitOwner(clock: reopenedClock)
            await fulfillment(of: [firstWait], timeout: 2)
            let initialSnapshot = await reopenedActor.test_latestSnapshot
            let initial = try XCTUnwrap(initialSnapshot)
            await reopenedClock.advance()
            await fulfillment(of: [secondWait], timeout: 2)
            let refreshed = await reopenedActor.test_latestSnapshot
            let reopenedHasPoller = await reopenedActor.test_hasPollingTask
            let closedHasPoller = await closedActor.test_hasPollingTask
            let afterReopen = await closedActor.test_latestSnapshot
            XCTAssertFalse(closedActor === reopenedActor)
            XCTAssertEqual(refreshed?.generation, initial.generation + 1)
            XCTAssertTrue(reopenedHasPoller)
            XCTAssertFalse(closedHasPoller)
            XCTAssertEqual(afterReopen?.generation, closedGeneration)
            await reopenedViewModel.shutdownForWindowClose()
        }

        private func openGitOwner(clock: PollClock) async -> (GitViewModel, GitStatusActor) {
            let vcs = VCSService()
            let actor = GitStatusActor(vcsService: vcs, diffEngine: GitDiffEngine(vcsService: vcs))
            await actor.test_setPollingWait { try await clock.sleep() }
            // Inject a fresh window-scoped poller without any production window composition.
            let viewModel = GitViewModel(statusActor: actor)
            owners.append((viewModel, actor))
            // No repository is needed: the real refresh publishes a generation on every tick.
            viewModel.gitDiffInclusionMode = .all
            await actor.setInclusionMode(.all)
            return (viewModel, actor)
        }

        private actor PollClock {
            private let waits: [XCTestExpectation]
            private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
            private(set) var waitCount = 0

            init(waits: [XCTestExpectation]) {
                self.waits = waits
            }

            func sleep() async throws {
                let id = UUID()
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            sleepers[id] = continuation
                            waitCount += 1
                            if waitCount <= waits.count { waits[waitCount - 1].fulfill() }
                        }
                    }
                } onCancel: {
                    Task { await self.cancel(id) }
                }
            }

            func advance() {
                let pending = sleepers
                sleepers.removeAll()
                pending.values.forEach { $0.resume() }
            }

            private func cancel(_ id: UUID) {
                sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }
#endif
