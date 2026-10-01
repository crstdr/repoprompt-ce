import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class MCPToolIdleWaitTests: XCTestCase {
    @MainActor
    func testAlreadyCancelledToolIdleWaitDoesNotTakeIdleFastPath() async {
        let server = makeServerViewModel(service: MCPService(
            hostBootstrapOperation: {}, controllerStartOperation: {}, controllerFullShutdownOperation: {}
        ))
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await server.awaitNoActiveToolExecutions(runID: UUID())
        }
        do {
            try await task.value
            XCTFail("Already-cancelled idle waiter must throw")
        } catch is CancellationError {
            // The same guard also closes cancellation before continuation installation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    private func makeServerViewModel(service: MCPService) -> MCPServerViewModel {
        let store = WorkspaceFileContextStore()
        let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let settingsManager = WindowSettingsManager(windowID: -1)
        let prompt = PromptViewModel(
            fileManager: fileManager,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: settingsManager
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let oracle = OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
        return MCPServerViewModel(
            service: service,
            promptVM: prompt,
            oracleVM: oracle,
            workspaceManager: workspaceManager,
            windowID: -1,
            workspaceSearch: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("workspace search is not used by these tests")
            },
            ensureGitDataRootLoaded: { _, _ in
                throw MCPError.internalError("git-data loading is not used by these tests")
            }
        )
    }
}
