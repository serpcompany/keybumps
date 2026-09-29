import XCTest

/// Smoke suite for #70. Every launch uses faked permissions, disabled global hot keys, a fresh
/// defaults domain, and a disposable data directory; see `UITestLaunchConfiguration`.
final class SmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    func testLaunchReflectsFakedPermissions() {
        launch(permissions: "granted")
        XCTAssertTrue(element("settings.detail.permissions").waitForExistence(timeout: 20))
        XCTAssertFalse(attentionIndicator.exists, "Granted fakes should leave nothing needing attention")
        app.terminate()

        launch(permissions: "denied")
        XCTAssertTrue(element("settings.detail.permissions").waitForExistence(timeout: 20))
        XCTAssertTrue(attentionIndicator.waitForExistence(timeout: 5), "Denied fakes should surface permission attention")
    }

    func testEverySettingsPageOpens() {
        launch(permissions: "granted", ["-KBOpenSettings", "general"])
        XCTAssertTrue(element("settings.detail.general").waitForExistence(timeout: 20))

        for section in ["search", "clipboard", "screenshotTools", "dictation",
                        "windows", "keyboardShortcutter", "permissions", "general"] {
            element("settings.sidebar.\(section)").click()
            XCTAssertTrue(element("settings.detail.\(section)").waitForExistence(timeout: 5), section)
        }
    }

    func testEscapeClosesSettings() {
        launch(permissions: "granted", ["-KBOpenSettings", "general"])
        let detail = element("settings.detail.general")
        XCTAssertTrue(detail.waitForExistence(timeout: 20))

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5), "Escape closes Settings like Command-W")
    }

    func testCapabilityToggleTurnsOffAndOn() {
        launch(permissions: "granted", ["-KBOpenSettings", "clipboard"])
        let toggle = element("capability.toggle.clipboardHistory")
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue(of: toggle, 1))

        toggle.click()
        XCTAssertTrue(waitForValue(of: toggle, 0))
        toggle.click()
        XCTAssertTrue(waitForValue(of: toggle, 1))
    }

    func testPaletteCommandNumberSwitchesTabs() {
        launch(permissions: "granted", ["-KBOpenPalette", "search"])
        XCTAssertTrue(paletteField("Search apps, files, and folders").waitForExistence(timeout: 20))

        let prompts: [(key: String, prompt: String)] = [
            ("2", "Search clipboard history"),
            ("3", "Search screenshots"),
            ("4", "Search dictation history"),
            ("1", "Search apps, files, and folders"),
        ]
        for (key, prompt) in prompts {
            app.typeKey(key, modifierFlags: .command)
            XCTAssertTrue(paletteField(prompt).waitForExistence(timeout: 5), "⌘\(key)")
        }

        // The Hotkeys tab (⌘5) is hidden by default.
        XCTAssertFalse(app.buttons["palette.tab.keyboardShortcutter"].exists)
        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(paletteField("Search apps, files, and folders").waitForExistence(timeout: 5), "⌘5 is ignored")
    }

    func testCommandEOnClipboardImageOpensScreenshotEditor() {
        launch(permissions: "granted", ["-KBOpenPalette", "clipboard", "-KBUITestSeedClipboardImage", "YES"])
        XCTAssertTrue(paletteField("Search clipboard history").waitForExistence(timeout: 20))

        app.typeKey("e", modifierFlags: .command)
        let editor = app.windows["screenshotEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))

        editor.buttons["Cancel"].click()
        XCTAssertTrue(waitForNonExistence(of: editor))
    }

    // MARK: - Helpers

    private func launch(permissions: String, _ arguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = [
            "-KBUITestPermissions", permissions,
            // Pass a value so Foundation's argument domain never pairs the flag with the next argument.
            "-KBDisableHotKeys", "YES",
        ] + arguments
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var attentionIndicator: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH %@", "permission items need attention"))
            .firstMatch
    }

    private func paletteField(_ prompt: String) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", prompt)).firstMatch
    }

    private func waitForValue(of element: XCUIElement, _ value: Int) -> Bool {
        let predicate = NSPredicate(format: "value == %d", value)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 5) == .completed
    }

    private func waitForNonExistence(of element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 5) == .completed
    }
}
