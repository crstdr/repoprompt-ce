@testable import RepoPromptApp
import XCTest

final class WindowPresentationVisibilityPolicyTests: XCTestCase {
    func testPresentationRequiresEveryOnScreenCondition() {
        let cases: [(visible: Bool, minimized: Bool, unoccluded: Bool, hidden: Bool, expected: Bool)] = [
            (true, false, true, false, true),
            (false, false, true, false, false),
            (true, true, true, false, false),
            (true, false, false, false, false),
            (true, false, true, true, false)
        ]
        for item in cases {
            XCTAssertEqual(WindowPresentationVisibility.isVisible(
                windowIsVisible: item.visible,
                isMiniaturized: item.minimized,
                occlusionIsVisible: item.unoccluded,
                appIsHidden: item.hidden
            ), item.expected)
        }
    }
}
