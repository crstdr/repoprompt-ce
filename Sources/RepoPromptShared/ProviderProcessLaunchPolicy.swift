import Foundation

/// Provider launches fail closed in XCTest, including release-mode test bundles.
/// Fixture-process tests opt in for one configured instance or task scope; no process-global
/// environment toggle can authorize an unrelated test or a controller that lost its fake.
package enum ProviderProcessLaunchPolicy {
    @TaskLocal package static var allowsLaunchForTesting = false

    package struct Refusal: LocalizedError {
        package var errorDescription: String? {
            "Provider process launch refused under XCTest. Inject a fake or explicitly opt in with ProviderProcessLaunchPolicy.$allowsLaunchForTesting."
        }
    }

    private static let isXCTestProcess = ProcessInfo.processInfo.arguments.contains {
        $0.lowercased().hasSuffix(".xctest") || $0.lowercased().contains(".xctest/")
    }

        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
        || NSClassFromString("XCTestCase") != nil

    package static func check(allowsLaunchInTests: Bool = false) throws {
        if isXCTestProcess, !allowsLaunchInTests, !allowsLaunchForTesting {
            throw Refusal()
        }
    }
}
