import XCTest
@testable import PortalMac

final class PortalProductSnapshotTests: XCTestCase {
    func testSetupSnapshotPrioritizesAccessibilityAndStart() {
        let snapshot = PortalProductSnapshot(
            facts: .init(
                isRunning: false,
                isStarting: false,
                status: "Stopped",
                ipAddress: "192.168.1.4",
                accessibilityLabel: "Required",
                accessibilityOK: false,
                awdlEnabled: true,
                awdlLabel: "Enabled - cursor may stutter on Wi-Fi",
                windowsSetupStatus: "Ready to prepare a Windows host",
                isServingInstaller: false,
                windowsHostCount: 0,
                arrangementSummary: "not found"
            )
        )

        XCTAssertEqual(snapshot.headline, "Finish setup on this Mac")
        XCTAssertEqual(snapshot.primaryActionTitle, "Start Portal")
        XCTAssertEqual(snapshot.checklist.map(\.title), [
            "Grant Accessibility access",
            "Start Portal on this Mac",
            "Prepare the Windows companion"
        ])
        XCTAssertEqual(snapshot.overviewCards.first?.title, "Accessibility")
        XCTAssertFalse(snapshot.windowsReady)
    }

    func testReadySnapshotPromotesRunningStateAndConnectedWindows() {
        let snapshot = PortalProductSnapshot(
            facts: .init(
                isRunning: true,
                isStarting: false,
                status: "Listening for input from Windows",
                ipAddress: "192.168.1.4",
                accessibilityLabel: "Granted",
                accessibilityOK: true,
                awdlEnabled: false,
                awdlLabel: "Disabled - low latency mode",
                windowsSetupStatus: "2 hosts found, 1 ready for remote install",
                isServingInstaller: true,
                windowsHostCount: 2,
                arrangementSummary: "Mac: Studio\nWindows: Desk PC\nLink: M1 right <-> W1 left"
            )
        )

        XCTAssertEqual(snapshot.headline, "Portal is ready")
        XCTAssertEqual(snapshot.primaryActionTitle, "Stop Portal")
        XCTAssertEqual(snapshot.statusBadge, "Ready")
        XCTAssertEqual(snapshot.checklist.map(\.state), [.done, .done, .done])
        XCTAssertEqual(snapshot.overviewCards.map(\.title), ["Portal", "Low latency", "Windows app"])
        XCTAssertTrue(snapshot.windowsReady)
    }
}
