@testable import RepoPromptApp
import XCTest

/// Regression coverage for `WorkspaceFilesViewModel`'s store-stream loops.
///
/// `subscribeToWorkspaceStoreDeltaEvents` and
/// `subscribeToCodemapMarkerReadinessUpdates` previously did `guard let self`
/// before a never-ending `for await`, so each task retained the view model for
/// the life of the process — a closed window's whole graph (store, prompt and
/// oracle VMs) could never be released. The loops now capture the store and
/// re-acquire `self` per event, matching the existing
/// `subscribeToCodemapRootStatusUpdates` shape: once the window drops the VM,
/// `deinit` cancels the tasks, the stream iterators terminate, and the store's
/// per-subscriber continuation slots are removed via `onTermination`.
@MainActor
final class WorkspaceFilesViewModelStreamLifetimeTests: XCTestCase {
    private func waitUntil(
        _ condition: @MainActor () async -> Bool,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "Timed out waiting for condition", file: file, line: line)
    }

    /// Releasing the view model must release it: the tasks hold only the store,
    /// `deinit` cancels them, and the store's subscriber slots are freed.
    /// Fails without the fix — the loops retain `self` so the VM never deinits.
    func testViewModelDeallocatesAndStoreStreamsEndAfterRelease() async {
        let store = WorkspaceFileContextStore()
        var viewModel: WorkspaceFilesViewModel? =
            WorkspaceFilesViewModel(workspaceFileContextStore: store)
        weak var weakVM = viewModel

        // Subscriptions register asynchronously from the observation tasks.
        await waitUntil {
            let counts = await store.streamContinuationCountsForTesting()
            return counts.appliedIndex == 1
                && counts.codemapMarkerReadiness == 1
                && counts.codemapRootStatus == 1
        }

        viewModel = nil

        await waitUntil { weakVM == nil }
        await waitUntil {
            let counts = await store.streamContinuationCountsForTesting()
            return counts.appliedIndex == 0
                && counts.codemapMarkerReadiness == 0
                && counts.codemapRootStatus == 0
        }
    }

    /// Releasing one window's view model must not disturb another window's
    /// subscriptions on the same store.
    func testReleasingOneViewModelKeepsSiblingSubscriptionsAlive() async {
        let store = WorkspaceFileContextStore()
        var closingVM: WorkspaceFilesViewModel? =
            WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let liveVM = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        weak var weakClosing = closingVM
        weak var weakLive = liveVM

        await waitUntil {
            let counts = await store.streamContinuationCountsForTesting()
            return counts.appliedIndex == 2
                && counts.codemapMarkerReadiness == 2
                && counts.codemapRootStatus == 2
        }

        closingVM = nil

        await waitUntil { weakClosing == nil }
        await waitUntil {
            let counts = await store.streamContinuationCountsForTesting()
            return counts.appliedIndex == 1
                && counts.codemapMarkerReadiness == 1
                && counts.codemapRootStatus == 1
        }
        XCTAssertNotNil(weakLive)
    }
}
