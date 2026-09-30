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
                        "windows", "keyboardShortcutter", "snippets", "permissions", "general"] {
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
            ("5", "Search snippets"),
            ("1", "Search apps, files, and folders"),
        ]
        for (key, prompt) in prompts {
            app.typeKey(key, modifierFlags: .command)
            XCTAssertTrue(paletteField(prompt).waitForExistence(timeout: 5), "⌘\(key)")
        }

        // The Hotkeys tab (⌘6) is hidden by default.
        XCTAssertFalse(app.buttons["palette.tab.keyboardShortcutter"].exists)
        app.typeKey("6", modifierFlags: .command)
        XCTAssertTrue(paletteField("Search apps, files, and folders").waitForExistence(timeout: 5), "⌘6 is ignored")
    }

    func testSnippetsTabCreatesASnippetInSettings() {
        // Settings is closed before the palette opens, so only ⌘N can bring it back.
        launch(permissions: "granted", ["-KBOpenPalette", "snippets", "-KBCloseSettings", "YES"])
        let field = paletteField("Search snippets")
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["palette.snippets.new"].waitForExistence(timeout: 5), "The empty state offers New Snippet")

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitForNonExistence(of: field), "The palette closes")
        let name = app.textFields["snippets.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "Settings opens the editor on the Snippets page")
        let save = element("snippets.editor.save")
        XCTAssertFalse(save.isEnabled, "Save waits for a name and text")

        name.click()
        name.typeText("Made-up greeting")
        let text = app.textViews["snippets.editor.text"]
        text.click()
        text.typeText("Hello from a test")
        XCTAssertTrue(save.isEnabled)
        save.click()

        XCTAssertTrue(waitForNonExistence(of: name), "Save closes the editor")
        XCTAssertTrue(element("settings.detail.snippets").exists)
        XCTAssertTrue(element("snippets.list").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Made-up greeting"].waitForExistence(timeout: 5), "The list shows the new snippet")
    }

    func testCommandEOnClipboardImageOpensScreenshotEditor() {
        launch(permissions: "granted", ["-KBOpenPalette", "clipboard", "-KBUITestSeedClipboardImage", "YES"])
        XCTAssertTrue(paletteField("Search clipboard history").waitForExistence(timeout: 20))

        app.typeKey("e", modifierFlags: .command)
        let editor = app.windows["screenshotEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.buttons["Save"].exists)
        XCTAssertFalse(editor.buttons["Done"].exists)
        XCTAssertTrue(editor.buttons["Blur"].exists)

        editor.buttons["Cancel"].click()
        XCTAssertTrue(waitForNonExistence(of: editor))
    }

    func testPaletteSettingsButtonOpensSettings() {
        // Settings is closed before the palette opens, so only the button can bring it back.
        launch(permissions: "granted", ["-KBOpenPalette", "clipboard", "-KBCloseSettings", "YES"])
        let field = paletteField("Search clipboard history")
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let settings = element("settings.detail.permissions")
        XCTAssertTrue(waitForNonExistence(of: settings), "Settings starts closed")

        let settingsButton = app.buttons["palette.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        XCTAssertEqual(settingsButton.label, "Keybumps Settings")
        settingsButton.click()
        XCTAssertTrue(waitForNonExistence(of: field), "The palette closes")
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings opens")
    }

    func testQuickSearchOpensKeybumpsSettings() {
        launch(permissions: "granted", ["-KBOpenPalette", "search", "-KBCloseSettings", "YES"])
        let field = paletteField("Search apps, files, and folders")
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let settings = element("settings.detail.permissions")
        XCTAssertTrue(waitForNonExistence(of: settings), "Settings starts closed")

        app.typeText("settings")
        let command = element("quickSearch.command.keybumpsSettings")
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        let systemSettings = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "System Settings"))
            .firstMatch
        XCTAssertTrue(systemSettings.waitForExistence(timeout: 5))
        XCTAssertLessThan(command.frame.minY, systemSettings.frame.minY, "Keybumps Settings is listed above System Settings")

        // Typing selects the first row, and Return runs it.
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(of: field), "The palette closes")
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings opens")
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
