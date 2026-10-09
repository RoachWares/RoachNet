import XCTest

/// Drives the installed RoachNet companion (com.roachwares.RoachNetCompanion) through
/// RoachTail pairing against a desktop roachnet-runtime on the host's loopback.
/// PAIR_URL (passed as TEST_RUNNER_PAIR_URL) is the roachnet://pair deep link with the
/// bridge URL and a fresh join code.
final class PairingUITests: XCTestCase {
    func testPairWithRoachTail() throws {
        let pairURL = try XCTUnwrap(ProcessInfo.processInfo.environment["PAIR_URL"].flatMap(URL.init(string:)), "PAIR_URL missing")
        let app = XCUIApplication(bundleIdentifier: "com.roachwares.RoachNetCompanion")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        sleep(2)
        attach(app, "launched")

        XCUIDevice.shared.system.open(pairURL)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 8) { open.tap() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        sleep(2)

        let pair = app.buttons["Pair with RoachTail"].firstMatch
        if !pair.waitForExistence(timeout: 8) {
            let chatTab = app.buttons["RoachClaw"].firstMatch
            if chatTab.waitForExistence(timeout: 5) { chatTab.tap() }
            let settings = app.buttons["Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings button not found")
            settings.tap()
        }
        XCTAssertTrue(pair.waitForExistence(timeout: 15), "Pair with RoachTail button not shown")
        attach(app, "before-pair")
        pair.tap()
        let badge = app.staticTexts["Paired over RoachTail"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 30), "App did not report a RoachTail peer token")
        sleep(3)
        attach(app, "after-pair")
        if pair.exists {
            // Sheet still open: close it the way a person would.
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 5) { done.tap() }
        }
        let runtimeTab = app.buttons["Runtime"].firstMatch
        if runtimeTab.waitForExistence(timeout: 10) { runtimeTab.tap() }
        let live = app.staticTexts["Phone to Mac link is live."].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 20), "Runtime tab does not show a live Mac link")
        attach(app, "runtime-tab")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
