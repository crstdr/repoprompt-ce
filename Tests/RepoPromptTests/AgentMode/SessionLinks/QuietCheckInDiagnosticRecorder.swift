import Foundation
@_spi(TestSupport) @testable import RepoPromptApp

/// Task-scoped production-event capture; the lock also covers inherited bridge publication tasks.
final class QuietCheckInDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentSessionLinkAutoWakeDiagnostics.Event] = []

    func record(_ event: AgentSessionLinkAutoWakeDiagnostics.Event) {
        lock.withLock { storage.append(event) }
    }

    var events: [AgentSessionLinkAutoWakeDiagnostics.Event] {
        lock.withLock { storage }
    }
}
