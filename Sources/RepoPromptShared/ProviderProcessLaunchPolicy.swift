import Darwin
import Foundation

/// In-process XCTest hosts may launch test-owned fixtures, never installed providers.
/// Separate non-XCTest children are not guarded. Arguments and environment do not identify a test host.
package enum ProviderProcessLaunchPolicy {
    /// Legacy task/instance permits are retained for source compatibility and have no effect.
    @TaskLocal package static var allowsLaunchForTesting = false

    package struct Refusal: LocalizedError {
        package var errorDescription: String? {
            "Provider process launch refused under XCTest: use an executable in a test temporary directory, bundle or fixture."
        }
    }

    package static func checkedExecutablePath(_ path: String) throws -> String {
        // XCTest may load after an earlier non-test lookup; never cache host identity.
        guard NSClassFromString("XCTestCase") != nil else { return path }
        let files = FileManager.default
        guard path.hasPrefix("/"), let executable = canonicalPath(path),
              let attributes = try? files.attributesOfItem(atPath: executable),
              attributes[.type] as? FileAttributeType == .typeRegular,
              files.isExecutableFile(atPath: executable)
        else { throw Refusal() }

        var roots = [files.temporaryDirectory.path]
        roots += Bundle.allBundles.filter { $0.bundleURL.pathExtension == "xctest" }.map(\.bundleURL.path)
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tests = checkout.appendingPathComponent("Tests").path
        if let checkoutPath = canonicalPath(checkout.path), let testsPath = canonicalPath(tests),
           testsPath == checkoutPath + "/Tests"
        {
            roots.append(testsPath)
        }
        guard roots.contains(where: { root in
            guard let root = canonicalPath(root) else { return false }
            return executable.hasPrefix(root + "/")
        }) else { throw Refusal() }
        // Launch this target, not the original symlink, so classification and execution agree.
        return executable
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
