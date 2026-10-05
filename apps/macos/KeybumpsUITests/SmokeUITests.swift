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

        for section in ["permissions", "general", "plugins"] {
            element("settings.sidebar.\(section)").click()
            XCTAssertTrue(element("settings.detail.\(section)").waitForExistence(timeout: 5), section)
        }
        // Every plugin's page opens from the Plugins table, as in Raycast's settings.
        for section in ["search", "clipboard", "screenshotTools", "dictation", "windows", "keyboardShortcutter", "snippets", "timer"] {
            element("plugins.row.\(section)").click()
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
            ("6", "Start a timer: 5m, 1h30m, tea 25"),
            ("1", "Search apps, files, and folders"),
        ]
        for (key, prompt) in prompts {
            app.typeKey(key, modifierFlags: .command)
            XCTAssertTrue(paletteField(prompt).waitForExistence(timeout: 5), "⌘\(key)")
        }

        // The Hotkeys tab (⌘7) is hidden by default.
        XCTAssertFalse(app.buttons["palette.tab.keyboardShortcutter"].exists)
        app.typeKey("7", modifierFlags: .command)
        XCTAssertTrue(paletteField("Search apps, files, and folders").waitForExistence(timeout: 5), "⌘7 is ignored")
    }

    func testHotkeysTabShowsShortcutCoachHistory() {
        // Its rows come from Shortcut Coach's module (`KeyboardShortcutterPaletteContent`).
        launch(permissions: "granted", ["-KBOpenPalette", "keyboardShortcutter", "-KBCloseSettings", "YES"])
        XCTAssertTrue(paletteField("Search hotkeys").waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["No matching hotkeys"].waitForExistence(timeout: 5), "The sandbox history is empty")
    }

    func testTimersTabStartsATimer() {
        // Its rows come from Timer's module (`TimerPaletteContent`).
        launch(permissions: "granted", ["-KBOpenPalette", "timers", "-KBCloseSettings", "YES"])
        let field = paletteField("Start a timer: 5m, 1h30m, tea 25")
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.typeText("tea 5m")
        XCTAssertTrue(element("palette.timers.new").waitForExistence(timeout: 5), "Typing offers to start it")

        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(of: field), "Return starts it and closes the palette")
    }

    func testSnippetsTabCreatesASnippetInSettings() {
        // Settings is closed before the palette opens, so only ⌘N can bring it back.
        launch(permissions: "granted", ["-KBOpenPalette", "snippets", "-KBCloseSettings", "YES"])
        let field = paletteField("Search snippets")
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["palette.snippets.new"].waitForExistence(timeout: 5), "The empty state offers New Snippet")

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitForNonExistence(of: field), "The palette closes")
        XCTAssertTrue(element("settings.detail.snippets").waitForExistence(timeout: 10), "Settings opens on the Snippets page")
        let name = element("snippets.editor.name")
        XCTAssertTrue(name.waitForExistence(timeout: 10), "The editor sheet opens")
        let save = element("snippets.editor.save")
        XCTAssertFalse(save.isEnabled, "Save waits for a name and text")

        name.click()
        name.typeText("Made-up greeting")
        let text = element("snippets.editor.text")
        text.click()
        text.typeText("Hello from a test")
        XCTAssertTrue(save.isEnabled)
        save.click()

        XCTAssertTrue(waitForNonExistence(of: name), "Save closes the editor")
        XCTAssertTrue(element("settings.detail.snippets").exists)
        XCTAssertTrue(element("snippets.list").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Made-up greeting"].waitForExistence(timeout: 5), "The list shows the new snippet")
        let importAlfred = element("snippets.importAlfred")
        XCTAssertTrue(importAlfred.exists)
        XCTAssertTrue(importAlfred.isEnabled, "Import from Alfred… is offered while snippets can be saved")
    }

    func testSelectAllSnippetsAndDeleteThemTogether() {
        launch(permissions: "granted", ["-KBOpenSettings", "snippets", "-KBUITestSeedSnippets", "YES"])
        XCTAssertTrue(element("snippets.list").waitForExistence(timeout: 20))
        let first = app.staticTexts["Made-up alpha"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "The seeded snippets are listed")
        XCTAssertTrue(app.staticTexts["3 snippets"].exists)

        first.click()
        XCTAssertTrue(element("snippets.edit").isEnabled, "Edit… takes one selected snippet")
        app.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["3 selected"].waitForExistence(timeout: 5), "⌘A selects every snippet")
        XCTAssertFalse(element("snippets.edit").isEnabled, "…and Edit… waits for just one")

        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Delete 3 snippets?"].waitForExistence(timeout: 5), "One confirmation for all three")
        // The alert's buttons are also in the Touch Bar, which isn't inside a window.
        app.windows.buttons["Delete"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No snippets yet"].waitForExistence(timeout: 5), "All three are deleted")
    }

    func testKeywordExpansionSwitchIsOffAndAsksForItsPermissions() {
        launch(permissions: "denied", ["-KBOpenSettings", "snippets"])
        let expansion = element("snippets.expansion")
        XCTAssertTrue(expansion.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Allow Input Monitoring so keywords expand"].exists, "Off by default, so it needs nothing")

        expansion.click()
        XCTAssertTrue(app.buttons["Allow Input Monitoring so keywords expand"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Allow Accessibility so keywords expand"].exists)
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

    func testQuickSearchNavigatesToCapabilities() {
        launch(permissions: "granted", ["-KBOpenPalette", "search", "-KBCloseSettings", "YES"])
        let field = paletteField("Search apps, files, and folders")
        XCTAssertTrue(field.waitForExistence(timeout: 20))

        // A whole word lists the capability's command first, and Return shows its tab in place.
        app.typeText("dictate")
        XCTAssertTrue(element("quickSearch.command.dictation").waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(paletteField("Search dictation history").waitForExistence(timeout: 5), "Return shows the Dictation tab")

        // Window Manager has no tab, so Return closes the palette and opens its Settings page.
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeText("window manager")
        XCTAssertTrue(element("quickSearch.command.windowManagement").waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(of: field), "The palette closes")
        XCTAssertTrue(element("settings.detail.windows").waitForExistence(timeout: 10), "Settings opens on Window Manager")
    }

    func testCapabilityCommandMovesOpenSettingsToItsPage() {
        // Settings stays open on General, so the page arrives through the open window, not a new one.
        launch(permissions: "granted", ["-KBOpenSettings", "general", "-KBOpenPalette", "search"])
        let general = element("settings.detail.general")
        XCTAssertTrue(general.waitForExistence(timeout: 20))
        let field = paletteField("Search apps, files, and folders")
        XCTAssertTrue(field.waitForExistence(timeout: 20))

        app.typeText("window manager")
        XCTAssertTrue(element("quickSearch.command.windowManagement").waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(of: field), "The palette closes")
        XCTAssertTrue(element("settings.detail.windows").waitForExistence(timeout: 10), "The open Settings window moves to Window Manager")
        XCTAssertFalse(general.exists)
    }

    func testKeybumpsItselfIsNeverListedAndItsSettingsOpenOnce() {
        // Owner QA of 4015.182.3: opening the Keybumps app from Quick Search opened Settings, then
        // Quick Search came back on top. Quick Search now never lists Keybumps itself. The app under
        // test isn't in /Applications, so it's seeded as the one Recent Item, which must stay hidden.
        launch(permissions: "granted", [
            "-KBOpenPalette", "search", "-KBCloseSettings", "YES", "-KBUITestSeedRecentKeybumps", "YES",
        ])
        let field = paletteField("Search apps, files, and folders")
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let settings = element("settings.detail.permissions")
        XCTAssertTrue(waitForNonExistence(of: settings), "Settings starts closed")
        // macOS static texts carry their string as the value, so match the identifier or the text.
        let emptyText = "Start typing to search your Mac"
        let emptyByText = app.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", emptyText, emptyText))
            .firstMatch
        XCTAssertTrue(
            element("quickSearch.noRecentItems").waitForExistence(timeout: 5) || emptyByText.exists,
            "Its only Recent Item, Keybumps, is hidden"
        )
        XCTAssertFalse(app.buttons["Clear All"].exists)

        // Typing its name offers Keybumps Settings, which opens Settings once.
        app.typeText("keybumps")
        XCTAssertTrue(element("quickSearch.command.keybumpsSettings").waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(of: field), "The palette closes")
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings opens")
        XCTAssertFalse(field.waitForExistence(timeout: 3), "Quick Search doesn't come back on top")
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
