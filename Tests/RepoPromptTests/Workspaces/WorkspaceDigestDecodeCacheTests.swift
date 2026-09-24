import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Regression coverage for the digest-keyed decode cache behind
    /// `WorkspaceManagerViewModel.decodeDomainWorkspaceProjection` /
    /// `WorkspaceFileDecodeCache.decodeWorkspace(documentBytes:)`.
    ///
    /// The decode output is a pure function of the document bytes, so identical
    /// payloads (the same workspace projected into N windows, or a file whose
    /// metadata changed without content changes) must decode once process-wide.
    @MainActor
    final class WorkspaceDigestDecodeCacheTests: XCTestCase {
        private var savedLimits: (maxEntries: Int, maxInputBytes: Int)?

        override func setUp() async throws {
            let cache = WorkspaceFileDecodeCache.shared
            savedLimits = cache.decodeCacheLimitsForTesting()
            cache.removeAllForTesting()
        }

        override func tearDown() async throws {
            let cache = WorkspaceFileDecodeCache.shared
            if let savedLimits {
                cache.setDecodeCacheLimitsForTesting(
                    maxEntries: savedLimits.maxEntries,
                    maxInputBytes: savedLimits.maxInputBytes
                )
            }
            cache.removeAllForTesting()
        }

        /// A second decode of identical bytes must hit the cache and return an
        /// equal model — including across different file URLs (content, not
        /// location, is the key).
        func testIdenticalBytesDecodeOnceAndReturnEqualModels() throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let bytes = try fixture.bytes(revision: 1)
            let otherURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("other-\(UUID().uuidString).json")

            let first = try fixture.decode(bytes)
            let second = try fixture.decode(bytes)
            let third = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: bytes, fileURL: otherURL
            )

            XCTAssertEqual(first, fixture.model(revision: 1))
            XCTAssertEqual(second, first)
            XCTAssertEqual(third, first)

            let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.misses, 1)
            XCTAssertEqual(stats.hits, 2)
            XCTAssertEqual(stats.entries, 1)
        }

        /// Cache hits must return an independent value: mutating a decoded
        /// model must not corrupt the cached copy served to other consumers.
        func testCacheHitIsIsolatedFromCallerMutation() throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let bytes = try fixture.bytes(revision: 1)

            var first = try fixture.decode(bytes)
            first.name = "caller-mutated"
            first.composeTabs[0].promptText = "caller edit"

            let second = try fixture.decode(bytes)
            XCTAssertEqual(second, fixture.model(revision: 1))
            XCTAssertNotEqual(second.name, "caller-mutated")
        }

        /// Changed bytes must miss the cache and decode fresh content.
        func testChangedBytesMissCache() throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let rev1 = try fixture.bytes(revision: 1)
            let rev2 = try fixture.bytes(revision: 2)

            _ = try fixture.decode(rev1)
            let afterFirst = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()

            let second = try fixture.decode(rev2)
            XCTAssertEqual(second, fixture.model(revision: 2))

            let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.misses, afterFirst.misses + 1)
            XCTAssertEqual(stats.entries, 2)
        }

        /// Decode failures must not be cached: a later decode of the same bad
        /// bytes throws again rather than serving a cached result.
        func testFailedDecodeIsNotCached() throws {
            let bad = Data("{".utf8)
            let fileURL = URL(fileURLWithPath: "/tmp/x.json")
            XCTAssertThrowsError(
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: bad, fileURL: fileURL
                )
            )
            let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 0)
            XCTAssertThrowsError(
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: bad, fileURL: fileURL
                )
            )
            XCTAssertEqual(
                WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting().entries, 0
            )
        }

        /// The cache must stay bounded: with a small entry limit, decoding more
        /// distinct documents evicts the least-recently-used entries.
        func testEntryBoundEvictsLeastRecentlyUsed() throws {
            let cache = WorkspaceFileDecodeCache.shared
            cache.setDecodeCacheLimitsForTesting(maxEntries: 2, maxInputBytes: .max)
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)

            _ = try fixture.decode(fixture.bytes(revision: 1))
            _ = try fixture.decode(fixture.bytes(revision: 2))
            _ = try fixture.decode(fixture.bytes(revision: 3))

            var stats = cache.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 2)

            // Rev. 1 was evicted; rev. 2 and 3 remain cached.
            _ = try fixture.decode(fixture.bytes(revision: 1))
            stats = cache.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 2)
        }

        /// The byte bound holds even when many documents are cached.
        func testInputByteBoundIsEnforced() throws {
            let cache = WorkspaceFileDecodeCache.shared
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let bytes = try fixture.bytes(revision: 1)
            cache.setDecodeCacheLimitsForTesting(
                maxEntries: 1000, maxInputBytes: bytes.count * 3
            )

            for revision in 1 ... 6 {
                _ = try fixture.decode(fixture.bytes(revision: revision))
            }

            let stats = cache.digestDecodeStatsForTesting()
            XCTAssertLessThanOrEqual(stats.inputBytes, bytes.count * 3)
            XCTAssertLessThanOrEqual(stats.entries, 3)
        }

        /// Minimal documents missing persisted identities are decoded with
        /// synthesized `UUID()`/`Date()` fallbacks. Those results must NOT be
        /// memoized: two independent decodes of identical minimal bytes (two
        /// different files) must still receive independent identities.
        func testSynthesizedIdentitiesAreNeverCached() async throws {
            let minimal = Data(#"{"name":"Legacy","repoPaths":[]}"#.utf8)
            let fileURL = URL(fileURLWithPath: "/tmp/minimal-a.json")
            let otherURL = URL(fileURLWithPath: "/tmp/minimal-b.json")

            let first = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: minimal, fileURL: fileURL
            )
            let second = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: minimal, fileURL: otherURL
            )

            // Each decode synthesizes a fresh workspace identity — including
            // under a detached task, proving the recorder binding holds for
            // non-main-actor decodes.
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertNotEqual(
                first.composeTabs.first?.id, second.composeTabs.first?.id
            )

            let detached = try await Task.detached {
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: minimal, fileURL: fileURL
                )
            }.value
            XCTAssertNotEqual(detached.id, first.id)
            XCTAssertNotEqual(detached.id, second.id)

            let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 0)
            XCTAssertEqual(stats.hits, 0)
            XCTAssertEqual(stats.misses, 3)
        }

        /// Two concurrent cold misses on the same bytes must converge to a
        /// single cache entry charged once — the storeDecoded replacement path.
        func testConcurrentColdMissesConvergeToSingleEntry() async throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let bytes = try fixture.bytes(revision: 1)
            let expected = fixture.model(revision: 1)
            let fileURL = URL(fileURLWithPath: "/tmp/concurrent.json")

            async let left = Task.detached {
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: bytes, fileURL: fileURL
                )
            }.value
            async let right = Task.detached {
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: bytes, fileURL: fileURL
                )
            }.value
            let results = try await [left, right]

            XCTAssertEqual(results[0], expected)
            XCTAssertEqual(results[1], expected)

            let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 1)
            XCTAssertEqual(stats.inputBytes, bytes.count)
        }

        /// Each synthesis site must independently keep a decode out of the
        /// cache — a single marker is enough, so the combined minimal-document
        /// test alone cannot prove every site is marked. Strip one field at a
        /// time from otherwise complete bytes and verify no entry is created.
        func testEachSynthesisSiteIndependentlyPreventsCaching() throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let fullBytes = try fixture.bytes(revision: 1)
            let fileURL = URL(fileURLWithPath: "/tmp/stripped.json")

            func decodedJSON(_ bytes: Data) throws -> [String: Any] {
                try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            }

            // (a) Workspace `dateModified` fallback — timestamp-only synthesis
            // with otherwise valid compose invariants (proves admission depends
            // on synthesis, not on normalizationRequiresSave).
            var workspaceJSON = try decodedJSON(fullBytes)
            workspaceJSON.removeValue(forKey: "dateModified")
            // (b) A preset's `id` fallback.
            var presetIDJSON = try decodedJSON(fullBytes)
            var presetsByID = try XCTUnwrap(presetIDJSON["presets"] as? [[String: Any]])
            presetsByID[0].removeValue(forKey: "id")
            presetIDJSON["presets"] = presetsByID
            // (c) A preset's `lastUpdated` fallback.
            var presetDateJSON = try decodedJSON(fullBytes)
            var presetsByDate = try XCTUnwrap(presetDateJSON["presets"] as? [[String: Any]])
            presetsByDate[0].removeValue(forKey: "lastUpdated")
            presetDateJSON["presets"] = presetsByDate
            // (d) Empty `composeTabs` — normalization synthesizes a tab.
            var noTabsJSON = try decodedJSON(fullBytes)
            noTabsJSON.removeValue(forKey: "composeTabs")
            noTabsJSON.removeValue(forKey: "activeComposeTabID")
            // (e) A tab's `id` fallback.
            var tabIDJSON = try decodedJSON(fullBytes)
            var tabsByID = try XCTUnwrap(tabIDJSON["composeTabs"] as? [[String: Any]])
            tabsByID[0].removeValue(forKey: "id")
            tabIDJSON["composeTabs"] = tabsByID
            // (f) A tab's `lastModified` fallback.
            var tabDateJSON = try decodedJSON(fullBytes)
            var tabsByDate = try XCTUnwrap(tabDateJSON["composeTabs"] as? [[String: Any]])
            tabsByDate[0].removeValue(forKey: "lastModified")
            tabDateJSON["composeTabs"] = tabsByDate

            let cases = [workspaceJSON, presetIDJSON, presetDateJSON, noTabsJSON, tabIDJSON, tabDateJSON]
            for (index, json) in cases.enumerated() {
                WorkspaceFileDecodeCache.shared.removeAllForTesting()
                let stripped = try JSONSerialization.data(withJSONObject: json)
                _ = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: stripped, fileURL: fileURL
                )
                _ = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: stripped, fileURL: fileURL
                )
                let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
                XCTAssertEqual(stats.entries, 0, "case \(index) must never enter the digest cache")
                XCTAssertEqual(stats.hits, 0, "case \(index) must never hit")
                XCTAssertEqual(stats.misses, 2)
            }
        }

        /// Storing the same digest twice (the concurrent cold-miss path) must
        /// converge to one entry charged once.
        func testReplacementStoreChargesEntryOnce() throws {
            let cache = WorkspaceFileDecodeCache.shared
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let model = fixture.model(revision: 1)
            let bytes = try fixture.bytes(revision: 1)

            cache.storeDecodedForTesting(
                workspace: model, normalizationRequiresSave: false,
                digest: "duplicate-digest", inputByteCount: bytes.count
            )
            cache.storeDecodedForTesting(
                workspace: model, normalizationRequiresSave: false,
                digest: "duplicate-digest", inputByteCount: bytes.count
            )

            let stats = cache.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 1)
            XCTAssertEqual(stats.orderCount, 1)
            XCTAssertEqual(stats.inputBytes, bytes.count)
        }
    }
#endif
