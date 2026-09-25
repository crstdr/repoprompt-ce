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
        XCTAssertFalse(rp_test_sandbox_path_is_within(applicationSupport.path, passwdHome))
    }

    func testInheritedWorkspaceStorageOverrideCannotPointOutsideSandbox() throws {
        let sandboxRoot = try XCTUnwrap(ProcessInfo.processInfo.environment["REPOPROMPT_TEST_SANDBOX_ROOT"])
        if let override = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL") {
            XCTAssertTrue(
                rp_test_sandbox_path_is_within(override, sandboxRoot),
                "GlobalCustomStorageURL escapes the test sandbox: \(override)"
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

        let containingRealHome = URL(fileURLWithPath: passwdHome).deletingLastPathComponent().path
        XCTAssertNotNil(
            validate(root: containingRealHome, home: passwdHome),
            "sandbox containing the real home"
        )
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

    /// A live override from a concurrently running test cannot reach real data and must survive;
    /// dead, real-home, out-of-root and malformed overrides are cleared.
    func testStorageOverrideClearingKeepsLiveConcurrentTestOverrides() throws {
        let runnerParent = scratch.appendingPathComponent("runner-parent", isDirectory: true)
        let userTemp = scratch.appendingPathComponent("user-temp", isDirectory: true)
        let ownSandbox = runnerParent.appendingPathComponent("rpce-local-tests-own/digest", isDirectory: true)
        let otherSandbox = runnerParent.appendingPathComponent("rpce-local-tests-other/digest", isDirectory: true)
        let durableState = userTemp.appendingPathComponent("SomeSuite-Durable-1/state", isDirectory: true)
        for directory in [ownSandbox, otherSandbox.appendingPathComponent("root-fixture"), durableState] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func shouldClear(_ value: String?) -> Bool {
            rp_test_sandbox_should_clear_storage_override(value, ownSandbox.path, userTemp.path, passwdHome)
        }

        // Kept: live overrides under a test root (own sandbox, another live sandbox, a live temp
        // fixture whose `Workspaces` child is not created yet).
        XCTAssertFalse(shouldClear(ownSandbox.appendingPathComponent("Workspaces").path))
        XCTAssertFalse(shouldClear(otherSandbox.appendingPathComponent("root-fixture/Workspaces").path))
        XCTAssertFalse(shouldClear(durableState.appendingPathComponent("Workspaces").path))

        // Cleared: dead trees, real-home paths, paths outside every test root, non-paths.
        XCTAssertTrue(shouldClear(runnerParent.appendingPathComponent("rpce-local-tests-gone/digest/root/Workspaces").path))
        XCTAssertTrue(shouldClear(userTemp.appendingPathComponent("Gone-Durable-2/state/Workspaces").path))
        XCTAssertTrue(shouldClear(passwdHome + "/Library/Application Support/RepoPrompt CE/Workspaces"))
        XCTAssertTrue(shouldClear(scratch.appendingPathComponent("elsewhere/Workspaces").path))
        XCTAssertTrue(shouldClear("relative/Workspaces"))
        XCTAssertTrue(shouldClear(nil))
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
        fixedHome: String?? = .none
    ) -> String? {
        let resolvedFixedHome: String? = switch fixedHome {
        case .none: home
        case let .some(value): value
        }
        var reason = [CChar](repeating: 0, count: 1024)
        let accepted = rp_test_sandbox_validate(root, home, resolvedFixedHome, passwdHome, &reason, reason.count)
        return accepted ? nil : String(cString: reason)
    }
}
