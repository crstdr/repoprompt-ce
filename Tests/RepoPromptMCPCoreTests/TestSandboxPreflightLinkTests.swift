import RepoPromptTestSandboxPreflight
import XCTest

/// References the C guard so its bundle-load constructor is linked into this test bundle.
final class TestSandboxPreflightLinkTests: XCTestCase {
    func testBundleLoadPreflightAcceptedThisProcess() {
        XCTAssertTrue(rp_test_sandbox_preflight_passed())
    }
}
