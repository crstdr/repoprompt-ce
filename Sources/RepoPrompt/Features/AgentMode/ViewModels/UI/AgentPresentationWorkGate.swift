import Combine
import Foundation
import RepoPromptDomainRuntime

/// A display-only gate. Callers must perform runtime/restore bookkeeping before asking to build.
@MainActor
final class AgentPresentationWorkGate {
    private let receiver = UUID()
    private let perf: CatalogPerf
    private var visible = true
    private var enabled: Bool
    private var dirty = false
    private var closed = false
    private var preferenceSubscription: AnyCancellable?
    private var catchUp: (() -> Void)?

    init(enabled: Bool, perf: CatalogPerf = .shared, catchUp: @escaping () -> Void) {
        self.enabled = enabled
        self.perf = perf
        self.catchUp = catchUp
    }

    convenience init(preference: HiddenWindowPresentationPreference, catchUp: @escaping () -> Void) {
        self.init(enabled: preference.isEnabled, catchUp: catchUp)
        preferenceSubscription = preference.changes.sink { [weak self] enabled in
            self?.setEnabled(enabled)
        }
    }

    func setVisible(_ visible: Bool) {
        guard !closed else { return }
        self.visible = visible
        flushIfNeeded()
    }

    func setEnabled(_ enabled: Bool) {
        guard !closed else { return }
        self.enabled = enabled
        flushIfNeeded()
    }

    /// Retain no snapshot, tab identity or delayed operation: reveal rebuilds from the current owner.
    func shouldBuild(recordBuild: Bool = true) -> Bool {
        guard !closed else { return false }
        let deferred = enabled && !visible
        if deferred { dirty = true }
        if deferred || recordBuild {
            perf.presentation(receiver: receiver, visible: visible, event: deferred ? .deferred : .build)
        }
        return !deferred
    }

    func didApply() {
        // The assignment may synchronously close its owner before this receipt is recorded.
        perf.presentation(receiver: receiver, visible: visible, event: .apply)
    }

    func close() {
        closed = true
        dirty = false
        catchUp = nil
        preferenceSubscription = nil
    }

    private func flushIfNeeded() {
        guard dirty, visible || !enabled else { return }
        // Clear before calling out: a synchronous rebind/visibility change may dirty it again.
        dirty = false
        perf.presentation(receiver: receiver, visible: visible, event: .catchUp)
        catchUp?()
    }
}

/// One process-wide poll detects external `defaults write` without adding a settings UI or MCP key.
/// Preferences synchronization is deliberately off MainActor and runs once per second, not per window.
@MainActor
final class HiddenWindowPresentationPreference {
    nonisolated static let key = "hiddenWindowPresentationDeferralEnabled"
    private(set) var isEnabled: Bool
    let changes = PassthroughSubject<Bool, Never>()
    private let timer: DispatchSourceTimer

    init(suiteName: String? = nil) {
        isEnabled = Self.loadEnabled(suiteName: suiteName)
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.repoprompt.presentation-preference", qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { @Sendable [weak self] in
            if let suiteName {
                UserDefaults(suiteName: suiteName)?.synchronize()
            } else {
                UserDefaults.standard.synchronize()
            }
            let enabled = Self.loadEnabled(suiteName: suiteName)
            Task { @MainActor [weak self] in
                guard let self, isEnabled != enabled else { return }
                // Store before notifying: a gate created by a catch-up subscriber sees this value.
                isEnabled = enabled
                changes.send(enabled)
            }
        }
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }

    private nonisolated static func loadEnabled(suiteName: String?) -> Bool {
        guard let suiteName else { return readEnabled() }
        guard let defaults = UserDefaults(suiteName: suiteName) else { return true }
        return readEnabled(from: defaults)
    }

    nonisolated static func readEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}
