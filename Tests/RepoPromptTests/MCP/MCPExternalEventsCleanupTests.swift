import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class MCPExternalEventsCleanupTests: XCTestCase {
    @MainActor
    func testManyWindowAppearancesPruneOnceOffMainThread() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "background prune started")
        started.assertForOverFulfill = true
        let executions = ExecutionCounter()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let monitor = MCPExternalEventsMonitor(eventsDirectory: directory) { _ in
            XCTAssertFalse(Thread.isMainThread)
            executions.increment()
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }

        let first = monitor.scheduleCleanupOnce()
        XCTAssertEqual(executions.value, 0, "No prune in the synchronous appearance turn")
        await fulfillment(of: [started], timeout: 5)
        var tasks: [Task<Void, Never>] = []
        for _ in 0 ..< 25 {
            tasks.append(monitor.scheduleCleanupOnce())
        }
        XCTAssertEqual(executions.value, 1)
        release.signal()
        await first.value
        for task in tasks {
            await task.value
        }
        // Later windows must not restart maintenance after the first pass finishes.
        await monitor.scheduleCleanupOnce().value
        XCTAssertEqual(executions.value, 1)
    }

    func testSymlinkRetentionMatchesPreviousMetadataLookupWithoutRemovingTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let cases: [(String, TimeInterval, TimeInterval?)] = [
            ("recent-link.json", -60, -8 * 24 * 3600),
            ("old-link.json", -8 * 24 * 3600, -60),
            ("dangling.json", -8 * 24 * 3600, nil)
        ]
        var expectedNames: Set<String> = []
        var targets: [URL] = []
        for (name, linkAge, targetAge) in cases {
            let target = root.appendingPathComponent(name + ".target")
            if let targetAge {
                try Data("target".utf8).write(to: target)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(targetAge)], ofItemAtPath: target.path
                )
                targets.append(target)
            }
            let link = directory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let timestamp = timespec(tv_sec: Int(now.addingTimeInterval(linkAge).timeIntervalSince1970), tv_nsec: 0)
            let times = [timestamp, timestamp]
            let result = times.withUnsafeBufferPointer {
                utimensat(AT_FDCWD, link.path, $0.baseAddress, AT_SYMLINK_NOFOLLOW)
            }
            XCTAssertEqual(result, 0)
            // Characterize the original decision, including dangling links, rather
            // than inventing a new link-following policy.
            let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
            let modification = try XCTUnwrap(attributes[.modificationDate] as? Date)
            if modification >= cutoff { expectedNames.insert(name) }
        }

        MCPExternalEventsMonitor.cleanupOldEvents(in: directory, now: now)
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)), expectedNames)
        for target in targets {
            XCTAssertEqual(try Data(contentsOf: target), Data("target".utf8))
        }
    }

    func testRetentionPreservesRecentBoundaryHiddenAndNonJSONFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let retention: TimeInterval = 7 * 24 * 3600
        let cases: [(String, TimeInterval, Bool)] = [
            ("old.json", -retention - 1, false),
            ("cli-old.json", -retention - 1, false),
            ("boundary.json", -retention, true),
            ("recent.json", -60, true),
            ("future.json", 60, true),
            (".hidden.json", -retention - 1, true),
            ("old.txt", -retention - 1, true)
        ]
        for (name, age, _) in cases {
            let url = directory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(age)], ofItemAtPath: url.path)
        }

        MCPExternalEventsMonitor.cleanupOldEvents(in: directory, now: now)
        for (name, _, shouldExist) in cases {
            XCTAssertEqual(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), shouldExist, name)
        }
        // Missing directories remain a best-effort no-op.
        MCPExternalEventsMonitor.cleanupOldEvents(in: directory.appendingPathComponent("missing"), now: now)
    }
}

private final class ExecutionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
