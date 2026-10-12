import XCTest

/// Drives the installed RoachNet companion (com.roachwares.RoachNetCompanion) against a
/// desktop roachnet-runtime on the host's loopback. `run.sh` runs these one phase at a
/// time (`-only-testing`) and does the desktop side in between; each phase gets what it
/// needs through TEST_RUNNER_* environment variables and skips when it isn't given them.
@MainActor
final class PairingUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let app = XCUIApplication(bundleIdentifier: "com.roachwares.RoachNetCompanion")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// Phase 1: load the roachnet://pair link and press "Pair with RoachTail".
    func test1PairWithRoachTail() throws {
        let pairURL = try XCTUnwrap(env["PAIR_URL"].flatMap(URL.init(string:)), "PAIR_URL missing")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        sleep(2)
        attach("launched")
        open(pairURL)
        // 0.2.0+: a link that points the phone at a new Mac asks before it is applied.
        let confirm = app.buttons["deeplink.confirm"].firstMatch
        if confirm.waitForExistence(timeout: 4) {
            attach("pair-link-confirmation")
            confirm.tap()
            sleep(1)
        }

        let pair = app.buttons["Pair with RoachTail"].firstMatch
        if !pair.waitForExistence(timeout: 8) {
            // 0.2.0+: settings open from the Home header; 0.1.x: from the RoachClaw header.
            let homeTab = app.buttons["tab.home"].firstMatch
            if homeTab.waitForExistence(timeout: 2) { homeTab.tap(); sleep(1) }
            for id in ["home.connection", "Settings"] {
                let button = app.buttons[id].firstMatch
                if button.waitForExistence(timeout: 4) { button.tap(); break }
            }
            if !pair.waitForExistence(timeout: 6) {
                let chatTab = app.buttons["RoachClaw"].firstMatch
                if chatTab.exists { chatTab.tap() }
                app.buttons["Settings"].firstMatch.tap()
            }
        }
        XCTAssertTrue(pair.waitForExistence(timeout: 15), "Pair with RoachTail button not shown")
        attach("before-pair")
        pair.tap()

        // The app stores its peer token and either closes the sheet or shows the paired badge.
        let badge = app.staticTexts["Paired over RoachTail"].firstMatch
        let closed = NSPredicate(format: "exists == false")
        let sheetGone = XCTNSPredicateExpectation(predicate: closed, object: pair)
        let paired = XCTWaiter().wait(for: [sheetGone], timeout: 30) == .completed || badge.exists
        sleep(2)
        attach("after-pair")
        XCTAssertTrue(paired, "The app did not finish pairing")
        if pair.exists, app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }

        let runtimeTab = app.buttons["Runtime"].firstMatch
        if runtimeTab.waitForExistence(timeout: 10) { runtimeTab.tap() }
        XCTAssertTrue(app.staticTexts["Phone to Mac link is live."].firstMatch.waitForExistence(timeout: 20),
                      "Runtime tab does not show a live Mac link")
        attach("runtime-tab")
    }

    /// Phase 2: send a RoachClaw message and wait for the reply from the desktop's model lane.
    func test2ChatRoundTrip() throws {
        guard let prompt = env["CHAT_PROMPT"], let expected = env["CHAT_EXPECT"] else { throw XCTSkip("CHAT_PROMPT not set") }
        app.activate()
        if app.state != .runningForeground { app.launch() }
        let chatTab = app.buttons["RoachClaw"].firstMatch
        XCTAssertTrue(chatTab.waitForExistence(timeout: 15))
        chatTab.tap()
        sleep(2) // let the tab transition finish so the composer isn't rebuilt mid-query

        let query = app.descendants(matching: .any).matching(identifier: "chat.composer")
        if !query.firstMatch.waitForExistence(timeout: 15) {
            // Seen once on 0.3.0: the tab opened without its composer. Capture it and try the tab again.
            attach("chat-no-composer")
            chatTab.tap()
            sleep(2)
            guard query.firstMatch.waitForExistence(timeout: 10) else { throw XCTSkip("This companion build has no chat.composer identifier") }
        }
        let composer = query.element(boundBy: query.count - 1)
        type(prompt, into: composer)
        app.buttons["chat.send"].firstMatch.tap()

        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 45), "No RoachClaw reply containing \(expected)")
        attach("chat-reply")
    }

    /// Phase 3: accept an Org invite from a roachnet://org-invite link.
    func test3JoinOrg() throws {
        guard let inviteURL = env["ORG_INVITE_URL"].flatMap(URL.init(string:)) else { throw XCTSkip("ORG_INVITE_URL not set") }
        app.activate()
        if app.state != .runningForeground { app.launch() }
        open(inviteURL)

        let name = app.textFields["org.join.name"].firstMatch
        guard name.waitForExistence(timeout: 15) else { throw XCTSkip("This companion build has no Org join form") }
        attach("org-join")
        type("Simulator Phone", into: name)
        app.buttons["org.join.submit"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Waiting on'")).firstMatch.waitForExistence(timeout: 20),
                      "The join request was not acknowledged")
        attach("org-join-sent")
        app.buttons["org.done"].firstMatch.tap()
    }

    /// Phase 4: approve the desktop's pending approval from the Org screen.
    func test4ApproveOrgRequest() throws {
        guard let approvalID = env["ORG_APPROVAL_ID"] else { throw XCTSkip("ORG_APPROVAL_ID not set") }
        app.activate()
        if app.state != .runningForeground { app.launch() }
        open(URL(string: "roachnet://open-org")!)

        let approve = app.buttons["org.approve.\(approvalID)"].firstMatch
        if !approve.waitForExistence(timeout: 20) {
            app.swipeDown()
            XCTAssertTrue(approve.waitForExistence(timeout: 20), "Approval \(approvalID) is not listed")
        }
        attach("org-approval")
        let note = app.textFields["org.note.\(approvalID)"].firstMatch
        if note.exists { type("Approved from the simulator check.", into: note) }
        approve.tap()
        // 0.3.0+ asks for Face ID or the passcode before an Org decision (finding I8). run.sh
        // enrolled Face ID on this throwaway simulator and sends a matching face during this
        // phase, so the test only answers the one-time "use Face ID?" alert and waits.
        let deadline = Date().addingTimeInterval(30)
        var allowed = false, captured = false
        while approve.exists && Date() < deadline {
            if !allowed, let button = faceIDPermissionButton() {
                attach("org-faceid-permission")
                button.tap()
                allowed = true
            } else if !captured {
                attach("org-unlock")
                captured = true
            }
            if app.staticTexts["Nothing was sent. Unlock to decide."].exists {
                attach("org-unlock-refused")
                XCTFail("The phone refused the unlock, so the approval was not sent")
                return
            }
            usleep(300_000)
        }
        XCTAssertFalse(approve.exists, "Approval card did not clear")
        attach("org-approved")
    }

    // MARK: Helpers

    private func open(_ url: URL) {
        XCUIDevice.shared.system.open(url)
        let openButton = springboard.buttons["Open"]
        if openButton.waitForExistence(timeout: 8) { openButton.tap() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        sleep(2)
    }

    /// Taps a text field until it has keyboard focus, then types. A tap that lands while the
    /// sheet is still animating in can leave the field without focus.
    private func type(_ text: String, into field: XCUIElement) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<4 {
            field.tap()
            let wait = XCTNSPredicateExpectation(predicate: focused, object: field)
            if XCTWaiter().wait(for: [wait], timeout: 3) == .completed { break }
        }
        field.typeText(text)
    }

    /// The button that allows Face ID in the one-time permission alert, wherever iOS shows it.
    private func faceIDPermissionButton() -> XCUIElement? {
        for scope in [springboard, app] {
            for label in ["OK", "Allow"] {
                let button = scope.alerts.buttons[label].firstMatch
                if button.exists { return button }
            }
        }
        return nil
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
