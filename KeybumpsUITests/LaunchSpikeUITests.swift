import XCTest

/// Spike for #70: proves an ad-hoc signed XCUITest can launch and drive Keybumps on a hosted runner.
final class LaunchSpikeUITests: XCTestCase {
    func testLaunchesAndAdvancesOnboarding() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Keybumps"].waitForExistence(timeout: 20))
        attachScreenshot(of: app, named: "welcome")

        app.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Six capabilities, one app"].waitForExistence(timeout: 5))

        app.buttons["Back"].click()
        XCTAssertTrue(app.staticTexts["Welcome to Keybumps"].waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "driven")
        app.terminate()
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
