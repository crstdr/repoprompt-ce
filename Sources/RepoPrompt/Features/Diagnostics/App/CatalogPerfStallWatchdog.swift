import Foundation

/// Diagnostic only: the existing CatalogPerf heartbeat and ten-second emission are unchanged.
/// All mutable state, preference reads and timer work belong to `queue`, never MainActor.
final class CatalogPerfStallWatchdog: @unchecked Sendable {
    /// Private opt-in, absent means OFF with no timer or polling. Enable takes effect at the next app activation.
    /// Only Cristian sets it:
    /// defaults write com.pvncher.repoprompt.ce CatalogPerfStallSamplingEnabled -bool true
    static let preferenceKey = "CatalogPerfStallSamplingEnabled"
    /// The existing heartbeat lease owner constructs and retains the production monitor.
    static func makeProduction() -> CatalogPerfStallWatchdog {
        CatalogPerfStallWatchdog(
            enabled: { UserDefaults.standard.bool(forKey: preferenceKey) },
            sample: { ticket in await CatalogPerfStackSample.capture(ticket: ticket) },
            publish: { data in try CatalogPerfStackArtifact.replace(data) }
        )
    }

    struct State {
        enum Action: Equatable {
            case heartbeat(UInt64)
            case capture(UInt64)
            case cancel(UInt64)
        }

        private(set) var active = false
        private(set) var enabled = false
        private(set) var terminated = false
        private(set) var outstanding: UInt64?
        private(set) var running: UInt64?
        private var issuedAt: TimeInterval = 0
        private var consumed = false
        private var lastAdmission: TimeInterval?
        private var nextID: UInt64 = 0
        private var cancelled = false
        private var lastTick: TimeInterval?
        private var admittedAt: TimeInterval = 0

        mutating func configure(active: Bool, enabled: Bool, terminate: Bool = false) -> [Action] {
            self.active = active
            self.enabled = enabled
            terminated = terminated || terminate
            // Keep the outstanding episode and admission history across leases and opt-out.
            // Only an actual main-queue acknowledgment can end an episode.
            if !active || !enabled || terminated, let running, !cancelled {
                cancelled = true
                return [.cancel(running)]
            }
            return []
        }

        func canAdmit(now: TimeInterval) -> Bool {
            active && enabled && !terminated && outstanding != nil && !consumed && running == nil &&
                now - issuedAt >= 0.250 && (lastAdmission.map { now - $0 >= 30 } ?? true) &&
                (lastTick.map { now - $0 <= 1 } ?? true)
        }

        mutating func tick(now: TimeInterval, permitsCapture: Bool = true) -> [Action] {
            defer { lastTick = now }
            if let running, !cancelled, now - admittedAt >= 3 {
                cancelled = true
                return [.cancel(running)]
            }
            guard active, enabled, !terminated else { return [] }
            if let lastTick, now - lastTick > 1 {
                // Sleep/starvation is not evidence of continuous main-thread blocking.
                issuedAt = now
            }
            guard let outstanding else {
                nextID += 1
                outstanding = nextID
                issuedAt = now
                consumed = false
                return [.heartbeat(nextID)]
            }
            guard permitsCapture, !consumed, running == nil, now - issuedAt >= 0.250,
                  lastAdmission.map({ now - $0 >= 30 }) ?? true else { return [] }
            consumed = true
            lastAdmission = now
            admittedAt = now
            running = outstanding
            cancelled = false
            return [.capture(outstanding)]
        }

        mutating func didIssue(_ id: UInt64, now: TimeInterval) {
            if outstanding == id { issuedAt = now }
        }

        mutating func acknowledge(_ id: UInt64) {
            guard outstanding == id else { return }
            outstanding = nil
            consumed = false
        }

        mutating func completed(_ id: UInt64) {
            guard running == id else { return }
            running = nil
        }
    }

    /// Publication is fenced against opt-out and shutdown. The lock is used only off-main;
    /// holding it across the bounded replacement prevents a late completion publishing after cancel.
    final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var valid = true
        private var started = false

        var isValid: Bool {
            lock.withLock { valid }
        }

        func cancel() {
            lock.withLock { valid = false }
        }

        func begin() -> Bool {
            lock.withLock {
                guard valid else { return false }
                started = true
                return true
            }
        }

        func cancelBeforeStart() {
            lock.withLock { if !started { valid = false } }
        }

        func ifValid(_ operation: () throws -> Void) rethrows {
            try lock.withLock { if valid { try operation() } }
        }
    }

    private let queue = DispatchQueue(label: "com.repoprompt.catalog-stall-watchdog", qos: .utility)
    private let clock: @Sendable () -> TimeInterval
    private let enabled: @Sendable () -> Bool
    private let heartbeat: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let sample: @Sendable (Ticket) async -> Data?
    private let publish: @Sendable (Data) throws -> Void
    private var state = State()
    private var timer: (any DispatchSourceTimer)?
    private var ticket: Ticket?
    private var acknowledgment: Acknowledgment?

    /// Main only marks receipt; no I/O or watchdog queue work under this tiny lock.
    final class Acknowledgment: @unchecked Sendable {
        private let lock = NSLock()
        private var received = false
        func mark() {
            lock.withLock { received = true }
        }

        func begin() -> Bool {
            lock.withLock { !received }
        }

        var isReceived: Bool {
            lock.withLock { received }
        }
    }

    private var lastPreferenceRead: TimeInterval?
    private let automatic: Bool
    private var settlementWaiters: [@Sendable () -> Void] = []

    private final class Settlement: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func finish() {
            let pending = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume()
        }
    }

    init(
        automatic: Bool = true,
        clock: @escaping @Sendable () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
        enabled: @escaping @Sendable () -> Bool,
        heartbeat: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { callback in DispatchQueue.main.async(execute: callback) },
        sample: @escaping @Sendable (Ticket) async -> Data?,
        publish: @escaping @Sendable (Data) throws -> Void
    ) {
        self.automatic = automatic
        self.clock = clock
        self.enabled = enabled
        self.heartbeat = heartbeat
        self.sample = sample
        self.publish = publish
    }

    func setActive(_ active: Bool) {
        queue.async { [self] in
            perform(state.configure(active: active, enabled: state.enabled))
            if active, !state.terminated {
                let optIn = enabled()
                configureOptIn(optIn)
                lastPreferenceRead = clock()
                if optIn, timer == nil, automatic {
                    let source = DispatchSource.makeTimerSource(queue: queue)
                    source.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
                    source.setEventHandler { [weak self] in self?.tick() }
                    timer = source
                    source.resume()
                }
            } else if !active {
                timer?.cancel()
                timer = nil
                lastPreferenceRead = nil
            }
        }
    }

    func shutdown() {
        queue.async { [self] in
            perform(state.configure(active: false, enabled: false, terminate: true))
            timer?.cancel()
            timer = nil
        }
    }

    /// Wait at most one second for cleanup. An unresolved child retains its sole-reaper owner.
    func settleForTermination() async {
        shutdown()
        await withCheckedContinuation { continuation in
            let settlement = Settlement(continuation)
            queue.async {
                if self.state.running == nil { settlement.finish() }
                else { self.settlementWaiters.append { settlement.finish() } }
            }
            // Independent of the state queue: a filesystem call during publication must not
            // extend the app's termination wait if cancellation is waiting on the ticket lock.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { settlement.finish() }
        }
    }

    private func tick() {
        let now = clock()
        if lastPreferenceRead.map({ now - $0 >= 0.5 }) ?? true {
            let optIn = enabled()
            configureOptIn(optIn, firstRead: lastPreferenceRead == nil)
            lastPreferenceRead = now
        }
        let prospective = state.canAdmit(now: clock())
        if prospective {
            // Every capture commit requires a fresh opt-in. A threshold crossed later waits a tick.
            configureOptIn(enabled())
        }
        // Timestamp before receipt: observer preemption cannot age an already-answered beat.
        let observedAt = clock()
        if acknowledgment?.isReceived == true, let id = state.outstanding {
            acknowledge(id)
        }
        perform(state.tick(now: observedAt, permitsCapture: prospective))
    }

    private func configureOptIn(_ optIn: Bool, firstRead: Bool = false) {
        if !optIn {
            timer?.cancel()
            timer = nil
        } else if optIn != state.enabled || firstRead {
            let interval: DispatchTimeInterval = .milliseconds(50)
            timer?.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        }
        perform(state.configure(active: state.active, enabled: optIn))
    }

    private func acknowledge(_ id: UInt64) {
        if state.running == id { ticket?.cancelBeforeStart() }
        state.acknowledge(id)
    }

    private func perform(_ actions: [State.Action]) {
        for action in actions {
            switch action {
            case let .heartbeat(id):
                let acknowledgment = Acknowledgment()
                self.acknowledgment = acknowledgment
                heartbeat { [weak self] in
                    acknowledgment.mark()
                    guard let self else { return }
                    queue.async { self.acknowledge(id) }
                }
                // Time before submission is observer work, not main-queue blocking.
                state.didIssue(id, now: clock())
            case .capture:
                let ticket = Ticket()
                self.ticket = ticket
                let acknowledgment = acknowledgment
                // The driver returns only after physical cleanup, including pipe closure and reap.
                Task.detached(priority: .utility) { [self] in
                    var data: Data?
                    if enabled(), acknowledgment?.begin() == true, ticket.begin() { data = await sample(ticket) }
                    let captured = data
                    queue.async {
                        // Publication, shutdown and lease deactivation share one ordered owner.
                        if let captured, self.enabled() { try? ticket.ifValid { try self.publish(captured) } }
                        if case let .capture(id) = action { self.state.completed(id) }
                        self.ticket = nil
                        let waiters = self.settlementWaiters
                        self.settlementWaiters.removeAll()
                        for waiter in waiters {
                            waiter()
                        }
                    }
                }
            case .cancel:
                ticket?.cancel()
            }
        }
    }

    #if DEBUG
        func hasTimerForTesting() async -> Bool {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.timer != nil) }
            }
        }

        func joinForTesting() async {
            await withCheckedContinuation { continuation in
                queue.async {
                    if self.state.running == nil { continuation.resume() }
                    else { self.settlementWaiters.append { continuation.resume() } }
                }
            }
        }

        /// Manual ticks and barriers exercise the real orchestration without timers or subprocesses.
        func tickForTesting() async -> State {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.tick()
                    continuation.resume(returning: self.state)
                }
            }
        }
    #endif
}
