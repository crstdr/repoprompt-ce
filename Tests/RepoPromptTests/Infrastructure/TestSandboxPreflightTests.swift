import Foundation
import RepoPromptTestSandboxPreflight
import XCTest

/// Covers the bundle-load guard that keeps RepoPromptTests out of the user's real app storage.
///
/// The guard itself runs before any test (a constructor in `RepoPromptTestSandboxPreflight`); an
/// unsandboxed `swift test` exits with status 78 before reaching this file. These tests pin the
/// validation contract it applies, including the misconfigurations it must reject.
final class TestSandboxPreflightTests: XCTestCase {
    private var scratch: URL!
    private var passwdHome: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestSandboxPreflightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        passwdHome = try XCTUnwrap(getpwuid(getuid())).pointee.pw_dir.map { String(cString: $0) }
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    func testBundleLoadPreflightAcceptedThisProcess() throws {
        XCTAssertTrue(rp_test_sandbox_preflight_passed())
        let sandboxRoot = try XCTUnwrap(ProcessInfo.processInfo.environment["REPOPROMPT_TEST_SANDBOX_ROOT"])
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        XCTAssertTrue(rp_test_sandbox_path_is_within(applicationSupport.path, sandboxRoot))
        XCTAssertFalse(rp_test_sandbox_path_is_within(applicationSupport.path, passwdHome + "/Library"))
    }

    func testWorkspaceStorageOverrideIsOnlyEverAKeptSandboxPath() {
        // Matches the preflight policy: an override may belong to this or another existing marked
        // sandbox (a concurrent test), never to the real home or an unowned location.
        if let override = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL") {
            XCTAssertFalse(
                rp_test_sandbox_should_clear_storage_override(override, passwdHome),
                "GlobalCustomStorageURL escapes every test sandbox: \(override)"
            )
        }
    }

    func testAcceptsWellFormedSandbox() throws {
        let root = try makeSandbox(named: "valid")
        XCTAssertNil(validate(root: root.path, home: root.path + "/home"))
    }

    /// Deliberately misconfigured environments: every one must be refused.
    func testRejectsEnvironmentsThatCouldReachRealStorage() throws {
        let root = try makeSandbox(named: "rejections")
        let home = root.path + "/home"

        XCTAssertNotNil(validate(root: nil, home: home), "missing sandbox root")
        XCTAssertNotNil(validate(root: "relative/root", home: home), "relative sandbox root")
        let realHomeReason = validate(root: root.path, home: passwdHome)
        XCTAssertTrue(realHomeReason?.contains("HOME=") == true, "real HOME: \(realHomeReason ?? "accepted")")
        XCTAssertNotNil(validate(root: root.path, home: home, fixedHome: passwdHome), "real CFFIXED_USER_HOME")
        XCTAssertNotNil(validate(root: root.path, home: home, fixedHome: .some(nil)), "unset CFFIXED_USER_HOME")
        XCTAssertNotNil(validate(root: root.path, home: nil), "unset HOME")
        XCTAssertNotNil(validate(root: root.path, home: root.path + "/../escaped"), "dot-dot escape")
        XCTAssertNotNil(validate(root: "/", home: home), "filesystem root as sandbox")

        let unmarked = scratch.appendingPathComponent("unmarked", isDirectory: true)
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: true)
        XCTAssertNotNil(
            validate(root: unmarked.path, home: unmarked.path + "/home"),
            "missing runner marker"
        )

        // A marked sandbox that contains the (synthetic) real home is refused for that reason.
        let homeInside = validate(root: root.path, home: home, passwdHome: root.path + "/fake-user")
        XCTAssertTrue(
            homeInside?.contains("contains the user's real home") == true,
            "sandbox containing the real home: \(homeInside ?? "accepted")"
        )
        XCTAssertNotNil(validate(root: root.path, home: home, passwdHome: "relative/home"), "relative real home")
    }

    func testPathContainmentResolvesSymlinksAndNonexistentPaths() throws {
        let root = try makeSandbox(named: "containment")
        XCTAssertTrue(rp_test_sandbox_path_is_within(root.path, root.path))
        XCTAssertTrue(rp_test_sandbox_path_is_within(root.path + "/not/created/yet", root.path))
        XCTAssertFalse(rp_test_sandbox_path_is_within(root.path + "-sibling/x", root.path))
        XCTAssertFalse(rp_test_sandbox_path_is_within("relative/path", root.path))

        let link = scratch.appendingPathComponent("link-to-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertTrue(rp_test_sandbox_path_is_within(link.path + "/missing/file.json", root.path))
    }

    /// Only an override inside an existing marked runner sandbox (normally a concurrent test) survives;
    /// dead, real-home, unowned and malformed overrides are cleared.
    func testStorageOverrideClearingKeepsOnlyMarkedSandboxOverrides() throws {
        let ownSandbox = try makeSandbox(named: "own-sandbox")
        let otherSandbox = try makeSandbox(named: "other-sandbox")
        let unowned = scratch.appendingPathComponent("Suite-Durable-1/state", isDirectory: true)
        let outside = scratch.appendingPathComponent("outside-real-storage", isDirectory: true)
        for directory in [unowned, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let linkOut = ownSandbox.appendingPathComponent("link-out")
        try FileManager.default.createSymbolicLink(at: linkOut, withDestinationURL: outside)

        func shouldClear(_ value: String?) -> Bool {
            rp_test_sandbox_should_clear_storage_override(value, passwdHome)
        }

        // Kept: existing marked sandboxes, including children that do not exist yet.
        XCTAssertFalse(shouldClear(ownSandbox.appendingPathComponent("Workspaces").path))
        XCTAssertFalse(shouldClear(otherSandbox.appendingPathComponent("root-fixture/Workspaces").path))

        // Cleared regardless of where scratch lives: real home, symlink out of a sandbox, non-paths.
        XCTAssertTrue(shouldClear(passwdHome + "/Library/Application Support/RepoPrompt CE/Workspaces"))
        XCTAssertTrue(shouldClear("relative/Workspaces"))
        XCTAssertTrue(shouldClear(nil))

        // The remaining cases need a scratch area outside every runner sandbox (true while
        // Foundation's temporary directory ignores TMPDIR). Checked independently of the
        // classifier under test by looking for the runner marker on scratch's ancestors.
        var ancestor = scratch.resolvingSymlinksInPath()
        var scratchInsideSandbox = false
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".issue944-test-sandbox").path) {
                scratchInsideSandbox = true
                break
            }
            ancestor.deleteLastPathComponent()
        }
        try XCTSkipIf(scratchInsideSandbox, "Scratch directory lives inside a runner sandbox")

        XCTAssertTrue(shouldClear(unowned.appendingPathComponent("Workspaces").path))
        XCTAssertTrue(shouldClear(scratch.appendingPathComponent("gone-sandbox/root/Workspaces").path))
        XCTAssertTrue(shouldClear(linkOut.appendingPathComponent("Workspaces").path))
    }

    /// A dangling symlink inside a sandbox whose target (with several missing components) lies in
    /// the real home must not be re-appended lexically and kept: it would reach the home once the
    /// target appears. Uses a synthetic home so nothing is created under the real one.
    func testDanglingSymlinkIntoHomeIsNeverTreatedAsSandboxed() throws {
        let sandbox = try makeSandbox(named: "dangling")
        let syntheticHome = scratch.appendingPathComponent("synthetic-home", isDirectory: true)
        try FileManager.default.createDirectory(at: syntheticHome, withIntermediateDirectories: true)
        let link = sandbox.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: syntheticHome.appendingPathComponent("not-yet-created/descendant")
        )

        let value = link.appendingPathComponent("Workspaces").path
        XCTAssertFalse(rp_test_sandbox_path_is_within(value, sandbox.path))
        XCTAssertTrue(rp_test_sandbox_should_clear_storage_override(value, syntheticHome.path))
        XCTAssertTrue(rp_test_sandbox_should_clear_storage_override(link.path, syntheticHome.path))
    }

    /// UserDefaults' argument domain (`-GlobalCustomStorageURL <path>`) is classified like a
    /// preference: only a path inside an existing marked sandbox is accepted.
    func testLaunchArgumentOverrideIsClassified() throws {
        let sandbox = try makeSandbox(named: "argument-sandbox")
        func isSafe(_ arguments: [String]) -> Bool {
            var cStrings = arguments.map { strdup($0) }
            defer { cStrings.forEach { free($0) } }
            return cStrings.withUnsafeMutableBufferPointer { buffer in
                buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { rebound in
                    rp_test_sandbox_argument_override_is_safe(Int32(rebound.count), rebound.baseAddress, passwdHome)
                }
            }
        }

        XCTAssertTrue(isSafe(["xctest", "-XCTest", "Suite", "bundle.xctest"]))
        XCTAssertTrue(isSafe(["xctest", "-GlobalCustomStorageURL", sandbox.appendingPathComponent("Workspaces").path]))
        XCTAssertFalse(isSafe(["xctest", "-GlobalCustomStorageURL", passwdHome + "/Library/Application Support/RepoPrompt CE/Workspaces"]))
        XCTAssertFalse(isSafe(["xctest", "-GlobalCustomStorageURL", "relative/Workspaces"]))
        XCTAssertFalse(isSafe(["xctest", "-GlobalCustomStorageURL"]))
    }

    private func makeSandbox(named name: String) throws -> URL {
        let root = scratch.appendingPathComponent(name, isDirectory: true)
        for child in ["home", "tmp"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(child, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        FileManager.default.createFile(atPath: root.appendingPathComponent(".issue944-test-sandbox").path, contents: Data())
        return root
    }

    /// Returns the refusal reason, or nil when the environment is accepted.
    private func validate(
        root: String?,
        home: String?,
        fixedHome: String?? = .none,
        passwdHome passwdHomeOverride: String? = nil
    ) -> String? {
        let resolvedFixedHome: String? = switch fixedHome {
        case .none: home
        case let .some(value): value
        }
        var reason = [CChar](repeating: 0, count: 1024)
        let accepted = rp_test_sandbox_validate(
            root, home, resolvedFixedHome, passwdHomeOverride ?? passwdHome, &reason, reason.count
        )
        return accepted ? nil : String(cString: reason)
    }
}
