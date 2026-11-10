#if DEBUG
    import Darwin
    import Foundation

    /// Opt-in, memory-only baseline recorder. No workspace IDs, settings, or model strings are retained.
    /// Entry point: StartupRecommendationBaselineTests. begin resets counts; end disables recording.
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

        private final class Storage: @unchecked Sendable {
            let lock = NSLock()
            var enabled = false
            var timings = false
            var scopeCatalogCounts = false
            var computeDepth: [UInt32: Int] = [:]
            var value = Snapshot()
        }

        private static let storage = Storage()

        static func begin(timings: Bool = false, scopeCatalogCounts: Bool = false) {
            storage.lock.withLock {
                storage.value = Snapshot()
                storage.enabled = true
                storage.timings = timings
                storage.scopeCatalogCounts = scopeCatalogCounts
            }
        }

        static func end() {
            storage.lock.withLock {
                storage.enabled = false
                storage.timings = false
            }
        }

        static func snapshot() -> Snapshot {
            storage.lock.withLock { storage.value }
        }

        /// Thread depth attributes catalog work to synchronous recommendation computes. Those
        /// computes never suspend, so unrelated background catalog reads remain outside the scope.
        static func enterCompute() {
            storage.lock.withLock {
                storage.computeDepth[pthread_mach_thread_np(pthread_self()), default: 0] += 1
            }
        }

        static func leaveCompute() {
            storage.lock.withLock {
                let thread = pthread_mach_thread_np(pthread_self())
                storage.computeDepth[thread, default: 0] -= 1
                if storage.computeDepth[thread] == 0 { storage.computeDepth.removeValue(forKey: thread) }
            }
        }

        static func count(_ key: String, catalog: Bool = false) {
            storage.lock.withLock {
                guard storage.enabled else { return }
                if catalog, storage.scopeCatalogCounts,
                   storage.computeDepth[pthread_mach_thread_np(pthread_self()), default: 0] == 0 { return }
                storage.value.counts[key, default: 0] += 1
            }
        }

        static func start() -> UInt64? {
            storage.lock.withLock {
                storage.enabled && storage.timings ? DispatchTime.now().uptimeNanoseconds : nil
            }
        }

        static func finish(_ key: String, since start: UInt64?) {
            guard let start else { return }
            let end = DispatchTime.now().uptimeNanoseconds
            let duration = end - start
            storage.lock.withLock {
                guard storage.enabled, storage.timings,
                      storage.value.durations[key, default: []].count < 4096 else { return }
                storage.value.durations[key, default: []].append(duration)
                if key == "compute" {
                    storage.value.firstStart = min(storage.value.firstStart ?? start, start)
                    storage.value.lastEnd = max(storage.value.lastEnd ?? end, end)
                }
            }
        }

        /// Counts only parser invocations in staticOption, not other Codex parsing.
        static func staticSpecifier(raw: String) -> CodexModelSpecifier {
            count("staticParser", catalog: true)
            return CodexModelSpecifier(raw: raw, discoveredRecords: staticPersistedRecords())
        }

        private static func staticPersistedRecords() -> [CodexDynamicModelRecord] {
            count("staticPersistedLoad", catalog: true)
            return CodexDynamicModelStore.load()
        }
    }
#endif
