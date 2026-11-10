#if DEBUG
    import Foundation

    /// Opt-in, thread-local measurements. A settings-store identity can isolate one owner cohort
    /// on the MainActor. begin resets that thread's recording; end disables it but keeps its snapshot.
    enum StartupRecommendationDiagnostics {
        struct Snapshot: Equatable {
            var counts: [String: Int] = [:]
            var durations: [String: [UInt64]] = [:]
            var firstStart: UInt64?
            var lastEnd: UInt64?

            subscript(_ key: String) -> Int {
                counts[key, default: 0]
            }
        }

        fileprivate final class Recording {
            let scope: ObjectIdentifier?
            let collectCounts: Bool
            let collectTimings: Bool
            let scopeCatalogCounts: Bool
            var enabled = true
            var value = Snapshot()

            init(scope: AnyObject?, counts: Bool, timings: Bool, scopeCatalogCounts: Bool) {
                self.scope = scope.map(ObjectIdentifier.init)
                collectCounts = counts
                collectTimings = timings
                self.scopeCatalogCounts = scopeCatalogCounts
            }
        }

        private final class ThreadState {
            var recording: Recording?
            var computeScopes: [ObjectIdentifier] = []
        }

        struct TimingToken {
            fileprivate let recording: Recording
            fileprivate let start: UInt64
        }

        private static var state: ThreadState {
            let dictionary = Thread.current.threadDictionary
            let key = "RepoPrompt.StartupRecommendationDiagnostics"
            if let existing = dictionary[key] as? ThreadState { return existing }
            let created = ThreadState()
            dictionary[key] = created
            return created
        }

        static func begin(timings: Bool = false, scopeCatalogCounts: Bool = false, counts: Bool = true, scope: AnyObject? = nil) {
            state.recording = Recording(scope: scope, counts: counts, timings: timings, scopeCatalogCounts: scopeCatalogCounts)
        }

        static func end() {
            state.recording?.enabled = false
        }

        static func snapshot() -> Snapshot {
            state.recording?.value ?? Snapshot()
        }

        /// Production computes are synchronous, so the scope stays on the same thread until leave.
        static func enterCompute(scope: AnyObject) {
            state.computeScopes.append(ObjectIdentifier(scope))
        }

        static func leaveCompute() {
            _ = state.computeScopes.popLast()
        }

        private static func accepts(_ recording: Recording, scope: AnyObject?, catalog: Bool) -> Bool {
            if let expected = recording.scope {
                guard (scope.map(ObjectIdentifier.init) ?? state.computeScopes.last) == expected else { return false }
            }
            return !catalog || !recording.scopeCatalogCounts || !state.computeScopes.isEmpty
        }

        static func count(_ key: String, catalog: Bool = false, scope: AnyObject? = nil) {
            guard let recording = state.recording, recording.enabled, recording.collectCounts,
                  accepts(recording, scope: scope, catalog: catalog) else { return }
            recording.value.counts[key, default: 0] += 1
        }

        static func start(scope: AnyObject? = nil) -> TimingToken? {
            guard let recording = state.recording, recording.enabled, recording.collectTimings,
                  accepts(recording, scope: scope, catalog: false) else { return nil }
            return TimingToken(recording: recording, start: DispatchTime.now().uptimeNanoseconds)
        }

        static func finish(_ key: String, since token: TimingToken?) {
            guard let token, let recording = state.recording, recording === token.recording,
                  recording.enabled, recording.collectTimings,
                  recording.value.durations[key, default: []].count < 4096 else { return }
            let end = DispatchTime.now().uptimeNanoseconds
            recording.value.durations[key, default: []].append(end - token.start)
            if key == "compute" {
                recording.value.firstStart = min(recording.value.firstStart ?? token.start, token.start)
                recording.value.lastEnd = max(recording.value.lastEnd ?? end, end)
            }
        }
    }
#endif
