import Foundation
@testable import RepoPromptApp

private enum AgentSessionLinkLifecycleTestError: Error {
    case expectedCodexSendFailure
}

final class LifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func contains(_ event: String) -> Bool {
        events.contains(event)
    }

    func contains(prefix: String) -> Bool {
        events.contains(where: { $0.hasPrefix(prefix) })
    }
}

final class LifecycleNoopCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    enum SendBehavior: CustomStringConvertible {
        case success
        case failure
        case cancellation

        var description: String {
            switch self {
            case .success: "success"
            case .failure: "failure"
            case .cancellation: "cancellation"
            }
        }
    }

    private let recorder: LifecycleRecorder
    private let sendBehavior: SendBehavior
    private let activatesThread: Bool
    private(set) var hasActiveThread = false

    init(recorder: LifecycleRecorder, failSend: Bool = false) {
        self.recorder = recorder
        sendBehavior = failSend ? .failure : .success
        activatesThread = true
    }

    init(recorder: LifecycleRecorder, sendBehavior: SendBehavior, activatesThread: Bool) {
        self.recorder = recorder
        self.sendBehavior = sendBehavior
        self.activatesThread = activatesThread
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        hasActiveThread = activatesThread
        return CodexNativeSessionController.SessionRef(conversationID: "lifecycle", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        hasActiveThread = activatesThread
        return CodexNativeSessionController.SessionRef(conversationID: "lifecycle", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        hasActiveThread = activatesThread
        return CodexNativeSessionController.SessionRef(conversationID: "lifecycle", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(includeTurns: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "lifecycle",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func startUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexTurnStartReceipt {
        try recordCodexSend()
        return CodexTurnStartReceipt(provisionalSubmissionID: "lifecycle-submission")
    }

    func steerUserTurn(text: String, images: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
        try recordCodexSend()
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        recorder.record("codex:interrupt:\(expectedTurnID)")
        return CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    private func recordCodexSend() throws {
        recorder.record("codex:send")
        switch sendBehavior {
        case .success:
            return
        case .failure:
            throw AgentSessionLinkLifecycleTestError.expectedCodexSendFailure
        case .cancellation:
            throw CancellationError()
        }
    }

    func compactThread() async throws {}

    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {
        recorder.record("codex:cancel")
    }

    func shutdown() async {
        recorder.record("codex:shutdown")
    }

    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
