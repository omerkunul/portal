import XCTest
@testable import PortalMac

final class PortalChromeMetricsTests: XCTestCase {
    func testTabHitAreaIsLargeEnoughForFullWidthClicks() {
        XCTAssertEqual(PortalChromeMetrics.tabWidth, 152)
        XCTAssertEqual(PortalChromeMetrics.tabHeight, 44)
    }

    func testWindowWidthIsFixedToProductLayout() {
        XCTAssertEqual(PortalChromeMetrics.windowWidth, 980)
        XCTAssertEqual(PortalChromeMetrics.windowHeight, 652)
    }
}
