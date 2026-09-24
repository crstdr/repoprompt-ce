import Foundation
@testable import RepoPromptApp
import XCTest

/// Pins how often the jj backend snapshots the working copy.
///
/// Every jj command snapshots by default, scanning all tracked files and rewriting
/// `.jj/working_copy` state. These tests drive the backend through a scripted executor, so
/// they need no jj installation and assert the exact commands jj would have received.
final class JujutsuSnapshotPolicyTests: XCTestCase {
    private static let ignoreWorkingCopy = "--ignore-working-copy"

    // MARK: - Runner

    func testRecordedPolicyPlacesFlagBeforeSubcommandSoTrailingPathsCannotSwallowIt() async throws {
        let log = JJInvocationLog()
        let runner = makeRunner(log: log)
        let repo = URL(fileURLWithPath: "/tmp/jj-policy-probe")

        _ = try await runner.run(["diff", "--stat", "--", "a.swift"], at: repo, workingCopy: .recorded)
        _ = try await runner.run(["diff", "--stat", "--", "a.swift"], at: repo, workingCopy: .snapshot)

        let invocations = await log.invocations
        XCTAssertEqual(invocations.first, [Self.ignoreWorkingCopy, "diff", "--stat", "--", "a.swift"])
        XCTAssertEqual(invocations.last, ["diff", "--stat", "--", "a.swift"])
    }

    // MARK: - Current bookmark

    func testCurrentBranchIsResolvedInOneProcessRegardlessOfBookmarkCount() async throws {
        let log = JJInvocationLog()
        let manyBookmarks = (0 ..< 120).map { "feature-\($0): abcdefgh 12345678 work \($0)" }
        let backend = JujutsuBackend(runner: makeRunner(
            log: log,
            allBookmarks: manyBookmarks.joined(separator: "\n") + "\n",
            bookmarksAtWorkingCopy: "zeta\nalpha"
        ))

        let branch = try await backend.getCurrentBranch(at: URL(fileURLWithPath: "/tmp/jj-policy-probe"))

        XCTAssertEqual(branch, "alpha", "The first local bookmark at @ in sorted order.")
        let invocations = await log.invocations
        XCTAssertEqual(invocations.count, 2, "One bookmark list plus one current read: \(invocations)")
        XCTAssertTrue(invocations.allSatisfy { $0.first == Self.ignoreWorkingCopy })
        XCTAssertTrue(perBookmarkLookups(in: invocations).isEmpty)
    }

    func testCurrentBranchIsUnknownWithoutAFallbackLoopWhenTheCurrentReadFails() async throws {
        let log = JJInvocationLog()
        let backend = JujutsuBackend(runner: makeRunner(log: log, currentReadExitCode: 1))

        let branch = try await backend.getCurrentBranch(at: URL(fileURLWithPath: "/tmp/jj-policy-probe"))

        XCTAssertNil(branch)
        let invocations = await log.invocations
        XCTAssertEqual(invocations.count, 2, "A failed read must not fall back to per-bookmark lookups.")
        XCTAssertTrue(perBookmarkLookups(in: invocations).isEmpty)
    }

    func testCurrentReadIsSkippedWhenTheRepositoryHasNoBookmarks() async throws {
        let log = JJInvocationLog()
        let backend = JujutsuBackend(runner: makeRunner(log: log, allBookmarks: ""))

        let branch = try await backend.getCurrentBranch(at: URL(fileURLWithPath: "/tmp/jj-policy-probe"))

        XCTAssertNil(branch)
        let invocations = await log.invocations
        XCTAssertEqual(invocations.count, 1, "Only the bookmark list runs: \(invocations)")
    }

    // MARK: - Status refresh

    /// The status poll runs this refresh every few seconds per window, so the number of
    /// working-copy snapshots it takes is the cost that matters.
    func testStatusRefreshSnapshotsTheWorkingCopyExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jj-snapshot-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".jj", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let log = JJInvocationLog()
        let service = VCSService(jjRunner: makeRunner(log: log))
        let status = GitStatusActor(vcsService: service, diffEngine: GitDiffEngine(vcsService: service))
        let detections = await status.updateRoots([root.path])
        XCTAssertEqual(detections.first?.backendKind, .jujutsu)

        // Selecting the root runs one refresh with cold caches.
        await status.setSelectedRoot(root.path)
        // The stream replays the latest snapshot to a new subscriber.
        var snapshots = status.statusStream.makeAsyncIterator()
        let latest = await snapshots.next()
        let snapshot = try XCTUnwrap(latest)

        let invocations = await log.invocations
        let snapshotting = invocations.filter { $0.first != Self.ignoreWorkingCopy }
        XCTAssertEqual(snapshotting.count, 1, "Exactly one command may snapshot: \(snapshotting)")
        XCTAssertEqual(Array(snapshotting.first?.prefix(2) ?? []), ["diff", "--summary"])

        let summaryIndex = try XCTUnwrap(invocations.firstIndex { $0.prefix(2) == ["diff", "--summary"] })
        let statIndex = try XCTUnwrap(invocations.firstIndex { $0.dropFirst().prefix(2) == ["diff", "--stat"] })
        XCTAssertLessThan(summaryIndex, statIndex, "The stat read reuses the summary's snapshot.")
        XCTAssertTrue(perBookmarkLookups(in: invocations).isEmpty)
        XCTAssertEqual(invocations.count, 5, "summary, stat, two bookmark lists, current read: \(invocations)")

        XCTAssertEqual(snapshot.currentBranch, "main")
        XCTAssertEqual(snapshot.unstagedFiles.map(\.path), ["Sources/App.swift"])
        XCTAssertEqual(snapshot.totalAdditions, 2)
        XCTAssertEqual(snapshot.totalDeletions, 1)
    }

    // MARK: - Helpers

    /// `jj log -r <bookmark>` calls: the per-bookmark resolution this backend must not do.
    private func perBookmarkLookups(in invocations: [[String]]) -> [[String]] {
        invocations.filter { invocation in
            let command = invocation.first == Self.ignoreWorkingCopy ? Array(invocation.dropFirst()) : invocation
            return command.prefix(2) == ["log", "-r"] && command.dropFirst(2).first != "@"
        }
    }

    private func makeRunner(
        log: JJInvocationLog,
        allBookmarks: String = """
        core: vwzyxozr 38f2602e docs: scope claims
          @git: vwzyxozr 38f2602e docs: scope claims
          @origin: vwzyxozr 38f2602e docs: scope claims
        main: qpvuntsm 230dd059 initial

        """,
        bookmarksAtWorkingCopy: String = "main",
        currentReadExitCode: Int32 = 0
    ) -> JJCommandRunner {
        JJCommandRunner { arguments, _, _ in
            await log.record(arguments)
            let command = arguments.first == Self.ignoreWorkingCopy ? Array(arguments.dropFirst()) : arguments
            switch (command.first, command.dropFirst().first) {
            case ("diff"?, "--summary"?):
                return ("M Sources/App.swift\n", "", 0)
            case ("diff"?, "--stat"?):
                return ("Sources/App.swift | 3 ++-\n1 file changed, 2 insertions(+), 1 deletion(-)\n", "", 0)
            case ("diff"?, _):
                return ("", "", 0)
            case ("bookmark"?, "list"?):
                return command.contains("--all") ? (allBookmarks, "", 0) : ("core: vwzyxozr 38f2602e docs\n", "", 0)
            case ("log"?, "-r"?) where command.dropFirst(2).first == "@":
                return currentReadExitCode == 0
                    ? (bookmarksAtWorkingCopy, "", 0)
                    : ("", "unsupported template", currentReadExitCode)
            default:
                return ("", "unexpected jj invocation", 1)
            }
        }
    }
}

private actor JJInvocationLog {
    private(set) var invocations: [[String]] = []

    func record(_ arguments: [String]) {
        invocations.append(arguments)
    }
}
