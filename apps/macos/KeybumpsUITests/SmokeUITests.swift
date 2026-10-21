import AppKit
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
        // Settings opens on Permissions only while a permission is missing; with nothing missing and
        // no page left open before, it opens on General (#559).
        launch(permissions: "granted")
        XCTAssertTrue(element("settings.detail.general").waitForExistence(timeout: 20))
        XCTAssertFalse(attentionIndicator.exists, "Granted fakes should leave nothing needing attention")
        element("settings.sidebar.permissions").click()
        XCTAssertTrue(element("settings.detail.permissions").waitForExistence(timeout: 5))
        XCTAssertTrue(element("permission.status.accessibility").exists)
        XCTAssertFalse(element("permission.button.accessibility").exists, "A granted row shows only Granted (#559)")
        app.terminate()

        launch(permissions: "denied")
        XCTAssertTrue(element("settings.detail.permissions").waitForExistence(timeout: 20))
        XCTAssertTrue(attentionIndicator.waitForExistence(timeout: 5), "Denied fakes should surface permission attention")
        let allow = element("permission.button.accessibility")
        XCTAssertTrue(allow.exists, "A missing permission's row offers Allow…")
        XCTAssertEqual(allow.label, "Allow Accessibility", "VoiceOver hears the full name (#559)")
    }

    func testEverySettingsPageOpens() {
        launch(permissions: "granted", ["-KBOpenSettings", "general"])
        XCTAssertTrue(element("settings.detail.general").waitForExistence(timeout: 20))

        for section in [
            "permissions", "general", "plugins", "changelog", "search", "clipboard", "screenshotTools", "dictation", "windows",
            "keyboardShortcutter", "snippets", "timer", "emojiPicker", "translation", "keystrokes",
        ] {
            element("settings.sidebar.\(section)").click()
            XCTAssertTrue(element("settings.detail.\(section)").waitForExistence(timeout: 5), section)
        }
        // The Plugins page lists every plugin, and a row opens that plugin's page.
        element("settings.sidebar.plugins").click()
        element("plugins.row.timer").click()
        XCTAssertTrue(element("settings.detail.timer").waitForExistence(timeout: 5), "A Plugins row opens its page")
    }

    func testSettingsSidebarSearchFiltersAndEscapeClearsIt() {
        launch(permissions: "granted", ["-KBOpenSettings", "general"])
        XCTAssertTrue(element("settings.detail.general").waitForExistence(timeout: 20))
        let window = app.windows.containing(.any, identifier: "settings.detail.general").firstMatch
        XCTAssertEqual(window.title, "General", "The toolbar names the page, as System Settings does (#559)")

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The sidebar has the stock search field")
        // The list has the keyboard, and the typing goes to the app, not the field, so the rows filter
        // only if Command-F moved the keyboard to the field; otherwise typing selects a row by name.
        element("settings.sidebar.general").click()
        app.typeKey("f", modifierFlags: .command)
        app.typeText("clip")
        XCTAssertTrue(element("settings.sidebar.clipboard").waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings.sidebar.general").waitForNonExistence(timeout: 5), "Command-F focuses search, and search filters the rows")

        search.typeText("zzz")
        XCTAssertTrue(element("settings.sidebar.noResults").waitForExistence(timeout: 5), "A search that finds nothing says so")

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(element("settings.sidebar.general").waitForExistence(timeout: 5), "Escape clears the search")
        XCTAssertTrue(element("settings.detail.general").exists, "and leaves Settings open")
    }

    func testSidebarRowMenuTurnsAPluginOn() {
        launch(permissions: "granted", ["-KBOpenSettings", "general"])
        XCTAssertTrue(element("settings.detail.general").waitForExistence(timeout: 20))

        // Emoji Picker ships off; its row's menu turns it on, as its switch does (#559).
        let row = element("settings.sidebar.emojiPicker")
        row.rightClick()
        let turnOn = app.menuItems["Turn On Emoji Picker"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 5), "A plugin's row has a menu")
        XCTAssertTrue(app.menuItems["Open on keybumps.app"].exists)
        turnOn.click()

        row.click()
        let toggle = element("capability.toggle.emojiPicker")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(of: toggle, 1), "The menu turned it on")
    }

    func testReportAProblemOpensFromGeneralSettings() {
        launch(permissions: "granted", ["-KBOpenSettings", "general"])
        XCTAssertTrue(element("settings.detail.general").waitForExistence(timeout: 20))

        element("settings.general.reportProblem").click()
        let description = element("problemReport.description")
        XCTAssertTrue(description.waitForExistence(timeout: 5), "Report a Problem opens its window")
        XCTAssertTrue(element("problemReport.included").exists, "It shows what's attached")
        // With a description, only the destination can keep Send off: UI tests run a Debug
        // build, which has nowhere to send reports.
        description.click()
        description.typeText("Dropdowns don't open")
        let typed = (description.value as? String) ?? (description.textViews.firstMatch.value as? String) ?? ""
        XCTAssertTrue(typed.contains("Dropdowns"), "The description took the typing")
        XCTAssertFalse(element("problemReport.send").isEnabled)
    }

    /// #286: Dictation's dropdowns open and change the setting. It drives Recognition language,
    /// which is near the top, so no scrolling is needed; the last row (Recording length) is the
    /// same `SettingsDropdown`. Before #294, CI's 1024×768 screen put that row under the Dock.
    /// #530: Automatic is listed first, and fresh defaults choose it.
    func testDictationDropdownsOpenAndChangeTheSetting() {
        launch(permissions: "granted", ["-KBOpenSettings", "dictation"])
        let language = element("settings.dictation.language")
        XCTAssertTrue(language.waitForExistence(timeout: 20))
        XCTAssertTrue(element("settings.dictation.durationLimit").exists)
        XCTAssertEqual(language.value as? String, "Automatic", "Automatic is the default")

        language.click()
        // The pop-up's own items; `app.menuItems` would also match the menu bar's.
        let first = language.menuItems.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 5), "The language dropdown opens its menu")
        XCTAssertEqual(first.title, "Automatic", "Automatic is listed first")
        let second = language.menuItems.element(boundBy: 1)
        let title = second.title
        second.click()
        XCTAssertEqual(language.value as? String, title, "Picking a language changes the setting")
    }

    /// #294: Settings isn't held taller than its screen's visible frame. CI's 1024×768 screen is
    /// shorter than the window's old minimum, so the window reached under the Dock there. Each
    /// UI-test launch has fresh defaults, so this is the first-open fill.
    ///
    /// The window's frame (read through Accessibility) is checked against the visible frame the
    /// app's screen reports (`settings.visibleFrame`). That doesn't prove the window clears the
    /// Dock: on CI the app's visible frame (677pt tall) ends about 4pt inside the Dock's
    /// Accessibility frame, while the runner's `NSScreen` reports 674pt; the cause isn't known.
    /// The Dock's frame and the runner's visible frame are only reported.
    func testSettingsWindowFitsItsScreensVisibleFrame() {
        launch(permissions: "granted", ["-KBOpenSettings", "dictation"])
        XCTAssertTrue(element("settings.detail.dictation").waitForExistence(timeout: 20))
        let window = app.windows.containing(.any, identifier: "settings.detail.dictation").firstMatch
        XCTAssertTrue(window.exists)
        let reported = element("settings.visibleFrame")
        XCTAssertTrue(reported.waitForExistence(timeout: 5), "The app reports its screen's visible frame in UI-test mode")

        let fits = NSPredicate { _, _ in
            guard let visible = Self.visibleFrame(reportedBy: reported) else { return false }
            return visible.insetBy(dx: -1, dy: -1).contains(window.frame)
        }
        // The fill happens just after the window appears.
        let settled = XCTWaiter().wait(for: [expectation(for: fits, evaluatedWith: nil)], timeout: 10) == .completed
        let appVisible = Self.visibleFrame(reportedBy: reported).map { "\($0)" } ?? "unreadable"
        let runnerVisible = NSScreen.screens.first.map { "\(Self.topLeft($0.visibleFrame, primaryHeight: $0.frame.maxY))" } ?? "none"
        let dockBar = XCUIApplication(bundleIdentifier: "com.apple.dock").children(matching: .any).firstMatch
        let dock = dockBar.exists ? "\(dockBar.frame)" : "not found"
        XCTAssertTrue(
            settled,
            "Settings \(window.frame) lies within its screen's visible frame \(appVisible) (runner's visible frame \(runnerVisible), Dock \(dock))"
        )
    }

    /// The visible frame the app reports as `minX,minY,width,height,primaryHeight` in AppKit
    /// coordinates, in XCUITest's.
    private static func visibleFrame(reportedBy element: XCUIElement) -> CGRect? {
        let numbers = ((element.value as? String) ?? "").split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 5 else { return nil }
        return topLeft(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), primaryHeight: numbers[4])
    }

    /// The visible frame, in XCUITest's coordinates, of the runner's screen with the middle of
    /// `frame` on it.
    private static func visibleFrameOfScreen(containing frame: CGRect) -> CGRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY else { return nil }
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens
            .first { topLeft($0.frame, primaryHeight: primaryHeight).contains(middle) }
            .map { topLeft($0.visibleFrame, primaryHeight: primaryHeight) }
    }

    /// AppKit's screen coordinates start at the primary screen's bottom-left corner; XCUITest's at
    /// its top-left.
    private static func topLeft(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
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

        XCTAssertFalse(element("capability.offBanner.clipboardHistory").exists, "An on plugin shows no banner")

        toggle.click()
        XCTAssertTrue(waitForValue(of: toggle, 0))
        XCTAssertTrue(element("capability.offBanner.clipboardHistory").waitForExistence(timeout: 5), "Turning it off says so")
        toggle.click()
        XCTAssertTrue(waitForValue(of: toggle, 1))
        XCTAssertTrue(element("capability.offBanner.clipboardHistory").waitForNonExistence(timeout: 5))
    }

    /// #490: ScreenGrabs' page, on the plugin template, has its Screenshots group and then its
    /// Recordings group, still says screenshots need Clipboard History, and offers to turn it on.
    func testScreengrabsPageAsksForClipboardHistory() {
        launch(permissions: "granted", ["-KBOpenSettings", "screenshotTools"])
        XCTAssertTrue(element("settings.detail.screenshotTools").waitForExistence(timeout: 20))
        // By identifier: macOS may report a group's heading as a heading rather than static text.
        let screenshots = element("settings.group.Screenshots")
        let recordings = element("settings.group.Recordings")
        XCTAssertTrue(screenshots.waitForExistence(timeout: 5) && recordings.exists, "Its two groups")
        XCTAssertLessThan(screenshots.frame.minY, recordings.frame.minY, "Screenshots, then Recordings")
        element("settings.sidebar.clipboard").click()
        let toggle = element("capability.toggle.clipboardHistory")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(waitForValue(of: toggle, 0))

        element("settings.sidebar.screenshotTools").click()
        XCTAssertTrue(element("settings.detail.screenshotTools").waitForExistence(timeout: 5))
        let requires = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "Requires Clipboard History", "Requires Clipboard History"))
            .firstMatch
        XCTAssertTrue(requires.waitForExistence(timeout: 5), "Requires Clipboard History")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Enable Clipboard History")).firstMatch.exists)
    }

    func testPaletteCommandNumberSwitchesTabs() {
        launch(permissions: "granted", ["-KBOpenPalette", "search"])
        XCTAssertTrue(paletteField("Search apps, files, and folders").waitForExistence(timeout: 20))

        let prompts: [(key: String, prompt: String)] = [
            ("2", "Search clipboard history"),
            ("3", "Search ScreenGrabs"),
            ("4", "Search dictation history"),
            ("5", "Search snippets"),
            ("6", "Start a timer: 5m, 1h30m, tea 25"),
            ("1", "Search apps, files, and folders"),
        ]
        for (key, prompt) in prompts {
            app.typeKey(key, modifierFlags: .command)
            XCTAssertTrue(paletteField(prompt).waitForExistence(timeout: 5), "⌘\(key)")
        }

        // Emoji and Translate ship off, and the Hotkeys tab is hidden by default: none shows, and with
        // six tabs shown, ⌘7 to ⌘9 do nothing. A tab's key is its place among the tabs shown (#553).
        XCTAssertFalse(app.buttons["palette.tab.emoji"].exists)
        XCTAssertFalse(app.buttons["palette.tab.translate"].exists)
        XCTAssertFalse(app.buttons["palette.tab.keyboardShortcutter"].exists)
        app.typeKey("7", modifierFlags: .command)
        app.typeKey("8", modifierFlags: .command)
        app.typeKey("9", modifierFlags: .command)
        XCTAssertTrue(paletteField("Search apps, files, and folders").waitForExistence(timeout: 5), "⌘7, ⌘8, and ⌘9 are ignored")
    }

    /// #553: Settings › Quick Search's arrows move a tab, and its key, the tab Quick Search opens on,
    /// and Left and Right follow the order; Reset Order puts it back; a hidden tab's key goes to the
    /// tab after it. `testQuickSearchTabRowsDragToReorder` drags the rows.
    func testQuickSearchTabOrder() {
        launch(permissions: "granted", ["-KBOpenSettings", "search"])
        XCTAssertTrue(element("settings.detail.search").waitForExistence(timeout: 20))
        // The page is one list, taller than the window, so each step first brings into view the one
        // thing it uses. Reset Order, above the tab rows, is always laid out, so its state is read
        // without scrolling to it. A tab key is static text, so macOS reports its accessibility label
        // as its value.
        let reset = element("settings.quickSearch.resetOrder")
        let snippetsKey = element("settings.quickSearch.key.snippets")
        XCTAssertTrue(waitForEnabled(reset, false), "Nothing to reset in the default order")
        XCTAssertTrue(scrollQuickSearchPage(toShow: [snippetsKey]), "The Snippets row's key in view")
        XCTAssertTrue(waitForText(of: snippetsKey, "Tab key ⌘5"))

        // Snippets up to first.
        let up = element("settings.quickSearch.moveUp.snippets")
        for place in [4, 3, 2, 1] {
            XCTAssertTrue(scrollQuickSearchPage(toShow: [up]), "Snippets' Up arrow in view")
            up.click()
            XCTAssertTrue(waitForText(of: snippetsKey, "Tab key ⌘\(place)"), "Snippets moves up to ⌘\(place)")
        }
        XCTAssertTrue(waitForText(of: element("settings.quickSearch.key.search"), "Tab key ⌘2"))
        XCTAssertTrue(waitForEnabled(up, false), "The first tab can't move up")
        XCTAssertTrue(waitForEnabled(reset, true))

        // Quick Search opens on the first tab shown, and its keys and Left and Right follow the order.
        let open = element("settings.quickSearch.open")
        XCTAssertTrue(scrollQuickSearchPage(toShow: [open]), "Open in view")
        open.click()
        XCTAssertTrue(paletteField("Search snippets").waitForExistence(timeout: 10), "It opens on Snippets")
        XCTAssertTrue(app.buttons["palette.tab.snippets"].exists, "The tab bar is queried by its tabs' identifiers")
        XCTAssertFalse(app.buttons["palette.tab.keyboardShortcutter"].exists, "The Hotkeys tab starts hidden")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(paletteField("Search apps, files, and folders").waitForExistence(timeout: 5), "⌘2 is the Search tab now")
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        XCTAssertTrue(paletteField("Search snippets").waitForExistence(timeout: 5), "Left goes back to Snippets")
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(paletteField("Search clipboard history").waitForExistence(timeout: 5), "Right follows the order")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(of: paletteField("Search clipboard history")), "Escape closes Quick Search")

        // Reset Order puts the keys back and turns itself off.
        XCTAssertTrue(scrollQuickSearchPage(toShow: [reset]), "Reset Order in view")
        reset.click()
        XCTAssertTrue(waitForText(of: snippetsKey, "Tab key ⌘5"))
        XCTAssertTrue(waitForText(of: element("settings.quickSearch.key.search"), "Tab key ⌘1"))
        XCTAssertTrue(waitForEnabled(reset, false))

        // A hidden tab has no key, and the tabs after it move up; hiding one leaves the order alone.
        let clipboardSwitch = element("settings.quickSearch.show.clipboard")
        XCTAssertTrue(scrollQuickSearchPage(toShow: [clipboardSwitch]), "The Clipboard tab's switch in view")
        XCTAssertTrue(clipboardSwitch.exists, "Every tab whose plugin is on has a show switch")
        clipboardSwitch.click()
        XCTAssertTrue(waitForText(of: element("settings.quickSearch.key.clipboard"), "Not in the tab bar"))
        XCTAssertTrue(waitForText(of: element("settings.quickSearch.key.screenshots"), "Tab key ⌘2"), "The tabs after it move up")
        XCTAssertTrue(waitForEnabled(reset, false), "Hiding a tab doesn't change the order")
    }

    /// #553: Settings › Quick Search is one list (`List` with `ForEach.onMove` for its tab rows): the
    /// wheel over the tab rows scrolls the page, and the rows drag to reorder, as in any Mac list. A
    /// row dropped on the top edge of another lands above it, one dropped on the bottom edge of
    /// another lands below it, and the tab keys follow. (Dropped on the middle of a row, the list
    /// puts it below that row: the system's drop on an item.)
    func testQuickSearchTabRowsDragToReorder() {
        launch(permissions: "granted", ["-KBOpenSettings", "search"])
        XCTAssertTrue(element("settings.detail.search").waitForExistence(timeout: 20))

        // The wheel over a tab row scrolls the page: the row moves up.
        let searchRow = tabRow("search")
        XCTAssertTrue(searchRow.waitForExistence(timeout: 5))
        XCTAssertTrue(searchRow.isHittable, "The first tab row is in view when the page opens")
        let top = searchRow.frame.minY
        searchRow.scroll(byDeltaX: 0, deltaY: -100)
        let moved = NSPredicate { _, _ in searchRow.frame.minY < top - 20 }
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: moved, evaluatedWith: nil)], timeout: 5), .completed, "The page scrolls")

        // Each drag first brings into view its two rows, and only those, well inside the list's top
        // and bottom edges, where the list scrolls as you drag.
        let reset = element("settings.quickSearch.resetOrder")
        let snippetsKey = element("settings.quickSearch.key.snippets")
        let searchKey = element("settings.quickSearch.key.search")
        XCTAssertTrue(scrollQuickSearchPage(toShow: [tabRow("snippets"), searchRow], margin: 60), "The Snippets and Search rows in view")
        XCTAssertTrue(waitForText(of: snippetsKey, "Tab key ⌘5"))
        XCTAssertTrue(waitForText(of: searchKey, "Tab key ⌘1"))

        // Up: Snippets dropped on the top edge of the Search row goes first.
        dragTabRow("snippets", onto: "search", at: 0.1)
        XCTAssertTrue(waitForText(of: snippetsKey, "Tab key ⌘1"), "Snippets is first")
        XCTAssertTrue(waitForText(of: searchKey, "Tab key ⌘2"), "Search follows it")
        XCTAssertTrue(waitForEnabled(reset, true))

        // Down: Snippets dropped on the bottom edge of the Clipboard row lands below it.
        XCTAssertTrue(scrollQuickSearchPage(toShow: [tabRow("snippets"), tabRow("clipboard")], margin: 60), "The Snippets and Clipboard rows in view")
        dragTabRow("snippets", onto: "clipboard", at: 0.9)
        XCTAssertTrue(waitForText(of: snippetsKey, "Tab key ⌘3"), "Snippets is below Clipboard")
        XCTAssertTrue(waitForText(of: searchKey, "Tab key ⌘1"))
        XCTAssertTrue(waitForText(of: element("settings.quickSearch.key.clipboard"), "Tab key ⌘2"))
    }

    func testEmojiPickerShipsOffAndTurnsOnInSettings() {
        // Its page is drawn by the plugin template, with Accessibility as an optional permission.
        launch(permissions: "denied", ["-KBOpenSettings", "emojiPicker"])
        let toggle = element("capability.toggle.emojiPicker")
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue(of: toggle, 0), "Emoji Picker ships off")
        XCTAssertTrue(app.staticTexts["Accessibility (Optional)"].exists)
        XCTAssertTrue(element("plugin.emojiPicker.skinTone").exists)
        XCTAssertTrue(element("capability.offBanner.emojiPicker").exists, "Its page says it's off")

        // The banner's Turn On does what the switch does.
        element("capability.offBanner.turnOn.emojiPicker").click()
        XCTAssertTrue(waitForValue(of: toggle, 1))
        XCTAssertTrue(element("capability.offBanner.emojiPicker").waitForNonExistence(timeout: 5))
    }

    func testTranslationShipsOffAndTurnsOnInSettings() {
        // Its page is drawn by the plugin template, with its two languages and Accessibility as an
        // optional permission. CI's Mac runs macOS 15 or later, so it can be turned on.
        launch(permissions: "denied", ["-KBOpenSettings", "translation"])
        let toggle = element("capability.toggle.translation")
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue(of: toggle, 0), "Translation ships off")
        XCTAssertTrue(app.staticTexts["Accessibility (Optional)"].exists)
        XCTAssertTrue(element("plugin.translation.myLanguage").exists)
        XCTAssertTrue(element("plugin.translation.otherLanguage").exists)
        XCTAssertTrue(element("capability.offBanner.translation").exists, "Its page says it's off")

        element("capability.offBanner.turnOn.translation").click()
        XCTAssertTrue(waitForValue(of: toggle, 1))
        XCTAssertTrue(element("capability.offBanner.translation").waitForNonExistence(timeout: 5))
    }

    func testKeystrokesShipsOffAndTurnsOnInSettings() {
        // Its page is drawn by the plugin template, with Input Monitoring, which its keyboard tap
        // needs, and its preferences. The UI-test composition's key display never listens or draws.
        launch(permissions: "denied", ["-KBOpenSettings", "keystrokes"])
        let toggle = element("capability.toggle.keystrokes")
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue(of: toggle, 0), "Keystrokes ships off")
        XCTAssertTrue(app.staticTexts["Input Monitoring"].exists)
        for key in ["showing", "style", "position", "size", "duration", "keys", "namesActions", "showsClicks"] {
            XCTAssertTrue(element("plugin.keystrokes.\(key)").exists, key)
        }
        XCTAssertTrue(element("capability.offBanner.keystrokes").exists, "Its page says it's off")

        element("capability.offBanner.turnOn.keystrokes").click()
        XCTAssertTrue(waitForValue(of: toggle, 1))
        XCTAssertTrue(element("capability.offBanner.keystrokes").waitForNonExistence(timeout: 5))
    }

    func testScreengrabsPageShowsRecording() {
        // Recording is part of ScreenGrabs, which ships on (#490). Its page is drawn by the plugin
        // template: Screen Recording, the Microphone and Input Monitoring as optional permissions,
        // the Recordings group's preferences at Screencast's keys, and a note on where recordings
        // are kept. It has no folder rows (#605): everything is in the Keybumps folder, with a copy
        // where macOS saves screenshots. CI's Mac runs macOS 15 or later, so it can record.
        launch(permissions: "denied", ["-KBOpenSettings", "screenshotTools"])
        let toggle = element("capability.toggle.screenshotTools")
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue(of: toggle, 1), "ScreenGrabs ships on")
        XCTAssertTrue(app.staticTexts["Screen Recording"].exists)
        XCTAssertTrue(app.staticTexts["Microphone (Optional)"].exists)
        XCTAssertTrue(app.staticTexts["Input Monitoring (Optional)"].exists)
        for key in ["recordsMicrophone", "recordsSystemAudio", "countdown", "showsShortcuts", "highlightsClicks"] {
            XCTAssertTrue(element("plugin.screencast.\(key)").exists, key)
        }
        XCTAssertTrue(element("plugin.screenshotTools.recordingsAbout").exists, "where recordings are kept")
        for identifier in ["plugin.screencast.showCaptures", "plugin.screenshotTools.show.screenshots", "plugin.screenshotTools.choose.screenshots", "plugin.screenshotTools.choose.recordings"] {
            XCTAssertFalse(element(identifier).exists, "no folder rows: \(identifier)")
        }
        XCTAssertFalse(element("plugin.screenshotTools.recordingRequirement").exists, "Recording works here")
        XCTAssertFalse(element("capability.offBanner.screenshotTools").exists)
    }

    func testScreencastPickerOpensAndSwitchesModes() {
        // The UI-test composition's made-up screens: the main screen split into a top and a bottom
        // display, each as wide as it, two made-up windows on each, and a recorder that records
        // them but captures nothing.
        launchScreencastPicker()
        XCTAssertEqual(pickerPanels.count, 2, "One picker panel per screen")
        let confirm = element("screencast.picker.confirm")
        let hint = element("screencast.picker.hint")
        XCTAssertTrue(waitForLabel(of: confirm, "Record"))
        // It opens on Screen (#501), on the screen with the pointer, whichever that is on CI.
        let onAScreen = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Records all of Made-up ", "Records all of Made-up ")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: onAScreen, evaluatedWith: hint)], timeout: 5), .completed)
        XCTAssertTrue(element("screencast.picker.screen.1").exists && element("screencast.picker.everyScreen").exists)
        XCTAssertTrue(confirm.isEnabled)
        for key in ["microphone", "systemAudio", "shortcuts", "clicks"] {
            XCTAssertTrue(element("screencast.picker.\(key)").exists, key)
        }
        XCTAssertFalse(element("screencast.picker.kind.screenshot").exists, "The picker records video only (#485)")

        element("screencast.picker.target.area").click()
        XCTAssertTrue(waitForText(of: hint, "Drag to choose an area."))
        XCTAssertTrue(element("screencast.picker.screen.1").waitForNonExistence(timeout: 5), "No screen choices in Area")
        element("screencast.picker.target.window").click()
        XCTAssertTrue(waitForText(of: hint, "Click a window to choose it."))
        XCTAssertTrue(waitForLabel(of: confirm, "Record"))
        XCTAssertTrue(element("screencast.picker.microphone").exists)
    }

    func testScreencastPickerChoosesOneScreenOrEveryScreen() throws {
        launchScreencastPicker()
        let hint = element("screencast.picker.hint")
        element("screencast.picker.target.screen").click()
        // A choice for each made-up screen, named, top first as recordings number them, and All
        // Screens. It starts on the screen with the pointer, whichever that is on CI.
        let top = element("screencast.picker.screen.1")
        let bottom = element("screencast.picker.screen.2")
        let allScreens = element("screencast.picker.everyScreen")
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        XCTAssertTrue(bottom.exists && allScreens.exists)
        XCTAssertFalse(element("screencast.picker.screen.3").exists)

        bottom.click()
        XCTAssertTrue(waitForText(of: hint, "Records all of Made-up Bottom Display."))
        allScreens.click()
        XCTAssertTrue(waitForText(of: hint, "Records all screens, one file each."))
        top.click()
        XCTAssertTrue(waitForText(of: hint, "Records all of Made-up Top Display."))

        // A click on a screen still chooses it: the one with the bar, a quarter of the way down,
        // above the bar at its bottom, once the bar has chosen the other one. A click aimed at the
        // other screen's panel would count this key one as an interruption and never land.
        let screen = try pickerPanelWithTheBar()
        let panels = (0..<pickerPanels.count).map { pickerPanels.element(boundBy: $0) }
        let other = try XCTUnwrap(panels.first { $0.frame != screen.frame })
        let barOnTop = screen.frame.minY < other.frame.minY
        (barOnTop ? bottom : top).click()
        XCTAssertTrue(waitForText(of: hint, "Records all of Made-up \(barOnTop ? "Bottom" : "Top") Display."))
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).click()
        XCTAssertTrue(waitForText(of: hint, "Records all of Made-up \(barOnTop ? "Top" : "Bottom") Display."))
    }

    func testScreencastPickerRecordsTheWindowChosen() throws {
        // The made-up windows on the screen with the bar, in from its top-left corner: the first,
        // 400 × 220 at (60, 40), in front of the second, 360 × 180 at (200, 120), whose lower part
        // is under the bar. The picker shows them undimmed, so this click proves its panel takes a
        // click there rather than letting it through to whatever is under it.
        launchScreencastPicker()
        let hint = element("screencast.picker.hint")
        let confirm = element("screencast.picker.confirm")
        element("screencast.picker.target.window").click()
        XCTAssertTrue(waitForText(of: hint, "Click a window to choose it."))
        let screen = try pickerPanelWithTheBar()
        let frame = screen.frame
        let corner = screen.coordinate(withNormalizedOffset: .zero)

        // A click chooses the first window, where the second isn't.
        corner.withOffset(CGVector(dx: 100, dy: 100)).click()
        XCTAssertTrue(waitForText(of: hint, "Click another window to change it."))
        // The pointer over the second window, then beside both, then on the bar, over the second
        // window, and a click on the bar's words, change nothing.
        corner.withOffset(CGVector(dx: 520, dy: 200)).hover()
        corner.withOffset(CGVector(dx: frame.width - 100, dy: 60)).hover()
        hint.hover()
        hint.click()
        XCTAssertTrue(waitForText(of: hint, "Click another window to change it."))
        XCTAssertTrue(confirm.isEnabled)
        // Nor does a double click on the bar's words: it records nothing.
        hint.doubleClick()
        let countdown = app.dialogs.matching(identifier: "screencastCountdown").firstMatch
        XCTAssertFalse(countdown.waitForExistence(timeout: 2))
        XCTAssertTrue(waitForText(of: hint, "Click another window to change it."))

        // Record counts down on the window chosen: centered on the first window, not the second.
        confirm.click()
        XCTAssertTrue(countdown.waitForExistence(timeout: 5))
        XCTAssertEqual(countdown.frame.midX, frame.minX + 260, accuracy: 2)
        XCTAssertEqual(countdown.frame.midY, frame.minY + 150, accuracy: 2)
        escapeThenCancel(countdown)
    }

    func testScreencastPickerRecordsAWindowDoubleClicked() throws {
        // The made-up windows as above: the first chosen, then a double click on the second.
        launchScreencastPicker()
        let hint = element("screencast.picker.hint")
        element("screencast.picker.target.window").click()
        XCTAssertTrue(waitForText(of: hint, "Click a window to choose it."))
        let screen = try pickerPanelWithTheBar()
        let frame = screen.frame
        let corner = screen.coordinate(withNormalizedOffset: .zero)
        corner.withOffset(CGVector(dx: 100, dy: 100)).click()
        XCTAssertTrue(waitForText(of: hint, "Click another window to change it."))

        // It counts down on the second window: centered on it, at (200, 120), 360 × 180.
        corner.withOffset(CGVector(dx: 520, dy: 200)).doubleClick()
        let countdown = app.dialogs.matching(identifier: "screencastCountdown").firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 5))
        XCTAssertEqual(countdown.frame.midX, frame.minX + 380, accuracy: 2)
        XCTAssertEqual(countdown.frame.midY, frame.minY + 210, accuracy: 2)
        escapeThenCancel(countdown)
    }

    /// In the picker's 10-second countdown, Escape does nothing (#518); its Cancel closes it, and
    /// nothing records, even once the countdown would have run out.
    private func escapeThenCancel(_ countdown: XCUIElement) {
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(countdown.waitForNonExistence(timeout: 1), "Escape leaves the countdown")
        element("screencast.countdown.cancel").click()
        XCTAssertTrue(countdown.waitForNonExistence(timeout: 5))
        let bar = app.dialogs.matching(identifier: "screencastControlBar").firstMatch
        XCTAssertFalse(bar.waitForExistence(timeout: 10), "Nothing records")
    }

    func testEscapeClosesTheScreencastPicker() {
        launchScreencastPicker()
        XCTAssertEqual(pickerPanels.count, 2, "The picker is up before Escape")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(pickerPanels.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(pickerPanels.count, 0)
        XCTAssertFalse(element("screencast.picker.bar").exists)
    }

    func testScreencastControlBarButtonsChangeState() {
        // A recording of a made-up screen that captures nothing, with the control bar showing.
        launchScreencastRecording()

        let pause = element("screencast.bar.pause")
        XCTAssertTrue(waitForLabel(of: pause, "Pause"))
        pause.click()
        XCTAssertTrue(waitForLabel(of: pause, "Resume"), "Pause becomes Resume")
        pause.click()
        XCTAssertTrue(waitForLabel(of: pause, "Pause"), "Resume becomes Pause")

        let microphone = element("screencast.bar.microphone")
        XCTAssertTrue(waitForValue(of: microphone, equalTo: "On"))
        microphone.click()
        XCTAssertTrue(waitForValue(of: microphone, equalTo: "Off"), "The microphone mutes")

        // Discard and Restart each ask in the bar first, and Keep goes back to the controls.
        for (button, confirm) in [("discard", "confirmDiscard"), ("restart", "confirmRestart")] {
            element("screencast.bar.\(button)").click()
            XCTAssertTrue(element("screencast.bar.\(confirm)").waitForExistence(timeout: 5), button)
            element("screencast.bar.keep").click()
            XCTAssertTrue(element("screencast.bar.\(confirm)").waitForNonExistence(timeout: 5), button)
            XCTAssertTrue(element("screencast.bar.stop").waitForExistence(timeout: 5), "Keep brings the controls back")
        }
        XCTAssertTrue(waitForLabel(of: pause, "Pause"), "Still recording")

        // macOS reports the bar's panel as a dialog, not a window.
        let controlBar = app.dialogs.matching(identifier: "screencastControlBar").firstMatch
        XCTAssertTrue(controlBar.exists, "The bar's panel is there while recording")
        let stop = element("screencast.bar.stop")
        stop.click()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 10), "Stop ends the recording")
        XCTAssertTrue(controlBar.waitForNonExistence(timeout: 10), "The bar closes")
    }

    func testScreencastDrawingFromTheControlBar() {
        // A recording of a made-up screen that captures nothing, with the control bar showing.
        launchScreencastRecording()
        // Settings, which UI test mode opens at launch, has the keyboard.
        let general = element("settings.sidebar.general")
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        general.click()
        XCTAssertTrue(element("settings.detail.general").waitForExistence(timeout: 5))

        let draw = element("screencast.bar.draw")
        XCTAssertTrue(draw.waitForExistence(timeout: 5), "The bar has Draw once drawing is wired in")
        XCTAssertTrue(waitForValue(of: draw, equalTo: "Off"))
        XCTAssertFalse(element("screencast.draw.tool.pen").exists, "The tools show only while drawing")
        draw.click()
        XCTAssertTrue(waitForValue(of: draw, equalTo: "On"))
        XCTAssertTrue(element("screencast.draw.tool.pen").waitForExistence(timeout: 5), "The tools show above the bar")

        let arrow = element("screencast.draw.tool.arrow")
        arrow.click()
        XCTAssertTrue(waitForValue(of: arrow, equalTo: "Selected"))
        XCTAssertNotEqual(element("screencast.draw.tool.pen").value as? String, "Selected")
        let blue = element("screencast.draw.color.blue")
        blue.click()
        XCTAssertTrue(waitForValue(of: blue, equalTo: "Selected"))

        // An arrow on the drawing layer, which takes the pointer while drawing. macOS reports the
        // non-activating panels as dialogs. The drag is relative to the layer, which covers the
        // recorded made-up screen: in its left part, clear of the bar and the tools (centered
        // near the bottom of the real screen) and of the menu bar.
        let clear = element("screencast.draw.clear")
        XCTAssertFalse(clear.isEnabled, "Nothing to clear yet")
        let layer = app.dialogs.matching(identifier: "screencastDrawing").firstMatch
        XCTAssertTrue(layer.waitForExistence(timeout: 5))
        layer.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: layer.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        XCTAssertTrue(waitForEnabled(clear, true), "The arrow is there to clear")
        clear.click()
        XCTAssertTrue(waitForEnabled(clear, false), "Clear took it away")

        // Escape with Settings the key window: drawing hears it first (its hot key is inert with
        // -KBDisableHotKeys), so drawing stops and Settings, which closes on Escape, stays open.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(waitForValue(of: draw, equalTo: "Off"), "Escape stops drawing")
        XCTAssertTrue(element("screencast.draw.tool.pen").waitForNonExistence(timeout: 5), "and the tools go")
        XCTAssertTrue(element("settings.detail.general").exists, "Settings kept its window")

        let stop = element("screencast.bar.stop")
        XCTAssertTrue(stop.exists, "and the recording runs on (#518)")
        stop.click()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.dialogs.matching(identifier: "screencastDrawing").firstMatch.waitForNonExistence(timeout: 5), "The drawing goes with the recording")
    }

    // MARK: Screencast's review panel (#450)

    func testScreencastReviewEscapeClosesAndSaves() {
        launchScreencastReview("video")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10), "Escape closes the window")
        XCTAssertTrue(waitForReviewOutcome("saved; folder kept; note empty"), "Closing saves")
    }

    func testScreencastReviewCopies() {
        launchScreencastReview("video")
        element("screencast.review.copy").click()
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10))
        XCTAssertTrue(waitForReviewOutcome("copied; folder kept; note empty; clipboard 1"))
    }

    /// #511: Copy's keycap says ⌘C, and ⌘C copies.
    func testScreencastReviewCommandCCopies() {
        launchScreencastReview("video")
        app.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10), "⌘C copies, which closes the window")
        XCTAssertTrue(waitForReviewOutcome("copied; folder kept; note empty; clipboard 1"))
    }

    func testScreencastReviewDiscardAsksFirst() {
        launchScreencastReview("video")
        element("screencast.review.discard").click()
        let keep = element("screencast.review.keep")
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Discard asks first")
        XCTAssertTrue(element("screencast.review.confirmDiscard").exists)
        keep.click()
        XCTAssertTrue(element("screencast.review.discard").waitForExistence(timeout: 5), "Keep goes back")
        XCTAssertTrue(reviewPanel.exists)

        element("screencast.review.discard").click()
        element("screencast.review.confirmDiscard").click()
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10))
        XCTAssertTrue(waitForReviewOutcome("discarded; folder deleted"))
    }

    /// #475: a recording's review is a standard window that all but fills the screen: the player edge
    /// to edge, under the bar the Screenshot Editor has too (#511), with Discard, Copy, and Save on its
    /// right. Nothing to type, no timeline until Trim is picked (#517), and Save closes it.
    func testScreencastReviewOfAVideoFillsTheScreenWithItsActionsInTheEditorBar() throws {
        launchScreencastReview("video")
        let window = reviewPanel
        XCTAssertEqual(window.title, "Edit Recording", "titled as the Screenshot Editor's Edit Screenshot is")
        // The screen's visible frame, but 16 pt on each side. Up and down the check is looser: the
        // runner's visible frame can end a few points from the app's (#294).
        let visible = try XCTUnwrap(Self.visibleFrameOfScreen(containing: window.frame), "the window's screen")
        XCTAssertEqual(window.frame.minX, visible.minX + 16, accuracy: 2, "it fills the screen but a margin: left \(window.frame) in \(visible)")
        XCTAssertEqual(window.frame.maxX, visible.maxX - 16, accuracy: 2, "right")
        XCTAssertEqual(window.frame.minY, visible.minY + 16, accuracy: 5, "top")
        XCTAssertEqual(window.frame.maxY, visible.maxY - 16, accuracy: 5, "bottom")
        let player = window.descendants(matching: .any).matching(identifier: "screencast.review.playerArea").firstMatch
        XCTAssertTrue(player.exists, "the player")
        XCTAssertEqual(player.frame.minX, window.frame.minX, accuracy: 1, "edge to edge")
        XCTAssertEqual(player.frame.maxX, window.frame.maxX, accuracy: 1)
        XCTAssertEqual(player.frame.maxY, window.frame.maxY, accuracy: 1, "down to the bottom: no bar under it")
        var actions: [String: XCUIElement] = [:]
        for action in ["discard", "copy", "save"] {
            let button = window.descendants(matching: .any).matching(identifier: "screencast.review.\(action)").firstMatch
            XCTAssertTrue(button.exists, action)
            XCTAssertLessThanOrEqual(button.frame.maxY, player.frame.minY + 1, "\(action) is in the bar, above the player")
            actions[action] = button
        }
        if let discard = actions["discard"], let copy = actions["copy"], let save = actions["save"] {
            XCTAssertGreaterThan(discard.frame.minX, window.frame.midX, "Discard, Copy, and Save on the right, as the editor's actions are")
            XCTAssertLessThan(discard.frame.maxX, copy.frame.minX, "then Copy")
            XCTAssertLessThan(copy.frame.maxX, save.frame.minX, "Save last")
            XCTAssertEqual(save.label, "Save", "VoiceOver reads Save, not the Return sign in it")
        }
        for gone in ["note", "type", "repository", "destination", "saveAndSend", "sendAndDelete", "timeline", "addToScreenshots", "edit"] {
            XCTAssertFalse(element("screencast.review.\(gone)").exists, gone)
        }

        element("screencast.review.save").click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 10), "Save closes the window")
        XCTAssertTrue(waitForReviewOutcome("saved; folder kept; note empty"))
    }

    /// #517: Crop puts its shapes and Reset Crop in the bar and its rectangle over the video; Blur
    /// opens the timeline, and a drag over the video draws a blur, picked, with Delete in the bar and
    /// a bar on the timeline, which ⌫ deletes. Escape puts Blur down first; with no edits left,
    /// Escape then closes the window, which saves.
    func testScreencastReviewCropAndBlurTools() {
        launchScreencastReview("video")
        let crop = element("screencast.review.tool.crop")
        XCTAssertTrue(crop.waitForExistence(timeout: 5), "Crop is in the bar")
        crop.click()
        XCTAssertTrue(element("screencast.review.cropAspect").waitForExistence(timeout: 5), "Crop's shapes are in the bar")
        XCTAssertTrue(element("screencast.review.resetCrop").exists, "and Reset Crop")
        XCTAssertTrue(element("screencast.review.cropOverlay").exists, "and its rectangle is over the video")

        element("screencast.review.tool.blur").click()
        let timeline = element("screencast.review.timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "Blur opens the timeline")
        XCTAssertTrue(element("screencast.review.blurStrength").exists, "and puts Strength in the bar")
        let player = element("screencast.review.playerArea")
        player.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2))
            .press(forDuration: 0.1, thenDragTo: player.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        let delete = element("screencast.review.deleteBlur")
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "a drag over the video draws a blur, picked, with Delete in the bar")
        XCTAssertTrue(element("screencast.review.blurLanes").exists, "and its bar on the timeline")
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(of: delete), "⌫ deletes it")

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(of: timeline), "Escape puts Blur down first")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10), "then Escape closes it")
        XCTAssertTrue(waitForReviewOutcome("saved; folder kept; note empty"))
    }

    /// #517: Trim, the bar's first tool, opens the timeline under the player with its options in the
    /// bar; Escape puts it down first, and the window stays; with no edits, Escape then closes it,
    /// which saves.
    func testScreencastReviewTrimOpensTheTimeline() {
        launchScreencastReview("video")
        let trim = element("screencast.review.tool.trim")
        XCTAssertTrue(trim.waitForExistence(timeout: 5), "Trim is in the bar")
        trim.click()
        let timeline = element("screencast.review.timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "Trim opens the timeline")
        XCTAssertTrue(element("screencast.review.cutSection").exists, "Cut Section is in the bar")
        XCTAssertTrue(element("screencast.review.resetTrim").exists, "and Reset Trim")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(of: timeline), "Escape puts Trim down first")
        XCTAssertTrue(reviewPanel.exists, "and the window stays")
        XCTAssertFalse(element("screencast.review.uitest.outcome").exists, "nothing saved yet")

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10), "then Escape closes it")
        XCTAssertTrue(waitForReviewOutcome("saved; folder kept; note empty"))
    }

    /// #475: the window opens with nothing taking the keyboard, so Space is the player's and neither
    /// saves nor closes; Return saves and closes it.
    func testScreencastReviewOfAVideoSpacePlaysAndReturnSaves() {
        launchScreencastReview("video")
        app.typeKey(" ", modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(reviewPanel.exists, "Space plays and pauses, and the window stays")
        XCTAssertFalse(element("screencast.review.uitest.outcome").exists, "nothing saved yet")

        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10), "Return saves and closes the window")
        XCTAssertTrue(waitForReviewOutcome("saved; folder kept; note empty"))
    }

    // MARK: The ScreenGrabs tab's recordings (#494)

    /// A made-up recording, indexed beside a made-up screenshot a minute older: both tiles show, the
    /// recording first, and Return copies the recording as its video file, read here from the
    /// UI-test pasteboard (`NSPasteboard.keybumps`).
    func testScreengrabsTabListsARecordingBesideAScreenshotAndReturnCopiesIt() {
        launchScreengrabsTab()
        let recording = element("palette.screengrabs.recording")
        let screenshot = element("palette.screengrabs.screenshot")
        XCTAssertTrue(screenshot.waitForExistence(timeout: 10), "the screenshot's tile")
        XCTAssertLessThan(recording.frame.minX, screenshot.frame.minX, "the recording, newer, comes first")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.serp.keybumps.uitests.clipboard"))
        let before = pasteboard.changeCount
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(of: recording), "Return copies, which closes the palette")
        let copied = expectation(for: NSPredicate { _, _ in pasteboard.changeCount != before }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [copied], timeout: 5), .completed, "something was copied")
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        XCTAssertEqual(files.map(\.lastPathComponent), ["video-1.mov"], "the recording's video, as a file")
    }

    /// One click highlights a tile, leaving the palette open and copying nothing; a double-click
    /// copies it, as Return does (#552).
    func testScreengrabsTabClickHighlightsATileAndADoubleClickCopiesIt() {
        launchScreengrabsTab()
        let recording = element("palette.screengrabs.recording")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.serp.keybumps.uitests.clipboard"))
        let before = pasteboard.changeCount

        recording.click()
        XCTAssertTrue(paletteField("Search ScreenGrabs").exists, "One click leaves the palette open")
        XCTAssertEqual(pasteboard.changeCount, before, "and copies nothing")

        recording.doubleClick()
        XCTAssertTrue(waitForNonExistence(of: recording), "A double-click copies, which closes the palette")
        let copied = expectation(for: NSPredicate { _, _ in pasteboard.changeCount != before }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [copied], timeout: 5), .completed, "something was copied")
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        XCTAssertEqual(files.map(\.lastPathComponent), ["video-1.mov"], "the recording's video, as a file")
    }

    /// Until a tile is highlighted, the detail beside the grid says how to show one; a click on the
    /// recording shows it there, with its buttons, and the detail's Copy copies it as Return does
    /// (#552).
    func testScreengrabsTabClickShowsATileInTheDetailBesideTheGrid() {
        launchScreengrabsTab()
        let recording = element("palette.screengrabs.recording")
        let copy = element("palette.screengrabs.detail.copy")
        XCTAssertTrue(element("palette.screengrabs.detail.empty").waitForExistence(timeout: 5), "the hint, before a tile is highlighted")
        XCTAssertFalse(copy.exists)

        recording.click()
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the detail's Copy")
        XCTAssertGreaterThan(copy.frame.minX, recording.frame.maxX, "beside the grid")
        XCTAssertTrue(element("palette.screengrabs.detail.edit").exists)
        XCTAssertTrue(element("palette.screengrabs.detail.delete").exists, "Move to Trash")
        XCTAssertFalse(element("palette.screengrabs.detail.empty").exists)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.serp.keybumps.uitests.clipboard"))
        let before = pasteboard.changeCount
        copy.click()
        XCTAssertTrue(waitForNonExistence(of: recording), "Copy copies, which closes the palette")
        let copied = expectation(for: NSPredicate { _, _ in pasteboard.changeCount != before }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [copied], timeout: 5), .completed, "something was copied")
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        XCTAssertEqual(files.map(\.lastPathComponent), ["video-1.mov"], "the recording's video, as a file")
    }

    /// ⌘Return opens the recording window on the saved recording, with Move to Trash and Done in
    /// Discard's and Save's places; Done only closes it.
    func testScreengrabsTabCommandReturnOpensTheRecordingWindow() {
        launchScreengrabsTab()
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: .command)
        let done = element("screencast.review.done")
        XCTAssertTrue(done.waitForExistence(timeout: 10), "⌘Return opens the recording window, with Done in Save's place")
        XCTAssertTrue(element("screencast.review.moveToTrash").exists, "and Move to Trash in Discard's")
        XCTAssertFalse(element("screencast.review.save").exists)
        XCTAssertFalse(element("screencast.review.discard").exists)
        done.click()
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10), "Done closes it")
        XCTAssertTrue(waitForReviewOutcome("closed; folder kept"), "and writes nothing")
    }

    /// Delete on a recording asks first; Cancel keeps it, and Move to Trash takes it out of the tab
    /// (in UI test mode, into the sandbox's own Trash folder) and leaves the screenshot.
    func testScreengrabsTabDeleteAsksBeforeMovingARecordingToTheTrash() {
        launchScreengrabsTab()
        let recording = element("palette.screengrabs.recording")
        let question = app.staticTexts["Move this recording to the Trash?"]
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertTrue(question.waitForExistence(timeout: 5), "Delete asks first")
        // The palette is a non-activating panel, which macOS reports as a dialog, not a window, so
        // its question's buttons are under `app.dialogs`, as the picker's are; the Touch Bar's
        // copies of them aren't.
        app.dialogs.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(waitForNonExistence(of: question))
        XCTAssertTrue(recording.exists, "Cancel keeps it")

        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        app.dialogs.buttons["Move to Trash"].firstMatch.click()
        XCTAssertTrue(waitForNonExistence(of: recording), "Move to Trash takes it out of the tab")
        XCTAssertTrue(element("palette.screengrabs.screenshot").exists, "and the screenshot stays")
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

    /// One click on an emoji copies it, as Return does, and closes the palette (#552). Emoji Picker
    /// ships off, so the test turns it on.
    func testEmojiTabClickCopiesAnEmoji() {
        launch(permissions: "granted", ["-KBUITestEnableCapabilities", "emojiPicker", "-KBOpenPalette", "emoji", "-KBCloseSettings", "YES"])
        let field = paletteField("Search emoji by name, keyword, or :shortcode:")
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let cell = element("palette.emoji.cell")
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "The grid loads")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.serp.keybumps.uitests.clipboard"))
        let before = pasteboard.changeCount

        cell.click()
        XCTAssertTrue(waitForNonExistence(of: field), "One click copies, which closes the palette")
        let copied = expectation(for: NSPredicate { _, _ in pasteboard.changeCount != before }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [copied], timeout: 5), .completed, "something was copied")
        XCTAssertFalse((pasteboard.string(forType: .string) ?? "").isEmpty, "the emoji, as text")
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
        XCTAssertTrue(app.staticTexts["Accessibility (Optional)"].exists, "⌘V pastes with it (#379)")

        expansion.click()
        XCTAssertTrue(app.buttons["Allow Input Monitoring so keywords expand"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Expanding needs Accessibility"].exists)
        XCTAssertFalse(app.buttons["Allow Accessibility so keywords expand"].exists, "Only its Permissions row asks for it")
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
        // It reopens on the page it closed on, General, as nothing is missing (#559).
        let settings = element("settings.detail.general")
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
        // It reopens on the page it closed on, General, as nothing is missing (#559).
        let settings = element("settings.detail.general")
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

    func testQuickSearchListsAndRunsRecordScreen() {
        // An action command is listed only while its plugin is on; ScreenGrabs ships on (#490).
        launch(permissions: "granted", ["-KBOpenPalette", "search", "-KBCloseSettings", "YES"])
        let field = paletteField("Search apps, files, and folders")
        XCTAssertTrue(field.waitForExistence(timeout: 20))

        app.typeText("screencast")
        XCTAssertTrue(element("quickSearch.command.screenshotTools").waitForExistence(timeout: 5))
        let action = element("quickSearch.action.startScreencast")
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Record Screen is listed beside ScreenGrabs' command")
        action.click()
        XCTAssertTrue(waitForNonExistence(of: field), "The palette closes")
        XCTAssertTrue(element("screencast.picker.bar").waitForExistence(timeout: 10), "It opens the picker, as the shortcut does")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
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
        // It reopens on the page it closed on, General, as nothing is missing (#559).
        let settings = element("settings.detail.general")
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

    /// #334: recording a shortcut another action uses asks first. Cancel and Escape keep both
    /// shortcuts; Replace moves it, and the other action's row says where it went.
    func testRecordingATakenShortcutAsksBeforeMovingIt() {
        launch(permissions: "granted", ["-KBOpenSettings", "search"])
        let page = element("settings.detail.search")
        let field = app.buttons.matching(NSPredicate(format: "label == %@", "Record shortcut for Open Quick Search")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let original = field.value as? String
        let prompt = element("shortcut.replacementPrompt")
        let modifierError = app.staticTexts["Use at least one modifier key such as Control, Option, Shift, or Command."]
        // Typing before the click has started recording sends the key to the page instead.
        func record() {
            field.click()
            XCTAssertTrue(waitForValue(of: field, equalTo: "Waiting for shortcut"), "The click starts recording")
        }

        // A bare key first: the error goes away without cancelling the recording. ⌃⌥U is
        // Window Manager › Top Left's default.
        record()
        app.typeKey("q", modifierFlags: [])
        XCTAssertTrue(modifierError.waitForExistence(timeout: 5))
        app.typeKey("u", modifierFlags: [.control, .option])
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "A taken shortcut asks first")
        element("shortcut.keep").click()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, original, "Cancel keeps Quick Search's shortcut")

        // Escape cancels the question and leaves Settings open.
        record()
        app.typeKey("u", modifierFlags: [.control, .option])
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        XCTAssertTrue(page.exists, "Escape cancels the question, not Settings")
        XCTAssertEqual(field.value as? String, original)

        // One click on the field while it asks starts recording again; a free shortcut saves.
        record()
        app.typeKey("u", modifierFlags: [.control, .option])
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        record()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        app.typeKey("q", modifierFlags: [.control, .option, .shift])
        XCTAssertTrue(waitForSavedValue(of: field, notEqualTo: original), "A free shortcut saves at once")
        let free = field.value as? String

        record()
        app.typeKey("u", modifierFlags: [.control, .option])
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        element("shortcut.replace").click()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForSavedValue(of: field, notEqualTo: free), "Replace gives Quick Search the shortcut")

        element("settings.sidebar.windows").click()
        XCTAssertTrue(
            element("shortcut.moved.window.upperLeft").waitForExistence(timeout: 5),
            "Top Left says where its shortcut went"
        )
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

    /// Opens the recording picker, as Record Screen does. ScreenGrabs ships on, so no plugin needs
    /// turning on (#490).
    private func launchScreencastPicker() {
        launch(permissions: "granted", ["-KBOpenScreencastPicker", "YES"])
        XCTAssertTrue(element("screencast.picker.bar").waitForExistence(timeout: 20))
    }

    /// Starts a recording of a made-up screen, as Record would.
    private func launchScreencastRecording() {
        launch(permissions: "granted", ["-KBUITestScreencastRecording", "YES"])
        // The bar shows as the recording starts, its buttons waiting until it records, except Discard.
        let pause = element("screencast.bar.pause")
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: pause)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed, "Recording")
    }

    /// Opens the recording window on a made-up `video`.
    private func launchScreencastReview(_ capture: String) {
        launch(permissions: "granted", ["-KBUITestScreencastReview", capture])
        XCTAssertTrue(element("screencast.review.save").waitForExistence(timeout: 20))
        // So a later check that it closed is about the review, not a query that finds nothing.
        XCTAssertTrue(reviewPanel.waitForExistence(timeout: 5), "the window itself is found")
    }

    /// The palette on the ScreenGrabs tab, with the made-up recording indexed beside a made-up
    /// screenshot (`-KBUITestScreencastReview video` with `-KBOpenPalette`, #494).
    private func launchScreengrabsTab() {
        launch(permissions: "granted", ["-KBUITestScreencastReview", "video", "-KBOpenPalette", "screenshots", "-KBCloseSettings", "YES"])
        XCTAssertTrue(paletteField("Search ScreenGrabs").waitForExistence(timeout: 20))
        XCTAssertTrue(element("palette.screengrabs.recording").waitForExistence(timeout: 10), "the made-up recording's tile")
    }

    /// The review: a standard window (#475), which macOS reports as a window.
    private var reviewPanel: XCUIElement {
        app.windows.matching(identifier: "screencast.review.window").firstMatch
    }

    /// The UI-test-only line that says what the panel did with the capture.
    private func waitForReviewOutcome(_ text: String) -> Bool {
        let outcome = element("screencast.review.uitest.outcome")
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: outcome)], timeout: 10) == .completed
    }

    /// The picker's panels, one per screen. macOS reports a borderless, non-activating panel as a
    /// dialog, not a window, so `app.windows` never lists them.
    private var pickerPanels: XCUIElementQuery {
        app.dialogs.matching(identifier: "screencastPicker")
    }

    /// The picker panel on the screen with the bar: the screen the pointer was on, whichever that
    /// is on CI. It's the key panel, and the one a click on a window there makes key again, so
    /// clicks aimed through it never count the other picker panel as an interruption, as clicks
    /// aimed through that one would.
    private func pickerPanelWithTheBar() throws -> XCUIElement {
        XCTAssertEqual(pickerPanels.count, 2)
        let bar = element("screencast.picker.bar").frame
        let panels = (0..<pickerPanels.count).map { pickerPanels.element(boundBy: $0) }
        return try XCTUnwrap(panels.first { $0.frame.contains(CGPoint(x: bar.midX, y: bar.midY)) })
    }

    private func waitForLabel(of element: XCUIElement, _ label: String) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 5) == .completed
    }

    /// A text's words, which macOS gives as its label or its value.
    private func waitForText(of element: XCUIElement, _ text: String) -> Bool {
        let predicate = NSPredicate(format: "label == %@ OR value == %@", text, text)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 5) == .completed
    }

    /// A tab's row in Settings › Quick Search's tab list.
    private func tabRow(_ tab: String) -> XCUIElement {
        element("settings.quickSearch.tab.\(tab)")
    }

    /// Where an element sits in Settings › Quick Search's list, for `scrollQuickSearchPage`.
    private enum ListPlace { case inView, above, below }

    /// Scrolls Settings › Quick Search, one list taller than the window (#553), with the wheel over
    /// the list, until every element given sits at least `margin` inside the list's top and bottom
    /// edges. Ask for the one element a step is about to use, unless the step needs more on screen
    /// together, as a drag needs its two rows.
    ///
    /// Each turn of the wheel is short, 60 pt of the page's 270 or so, and goes toward an element
    /// still outside, so the list scrolls no further than it must: at its very bottom, CI saw it jump
    /// back up about 150 pt on its own. A query can miss an element, or the list, for a moment while
    /// the list lays out, so it looks again for up to 2 s before each turn.
    private func scrollQuickSearchPage(toShow elements: [XCUIElement], margin: CGFloat = 20) -> Bool {
        let list = app.scrollViews.containing(.any, identifier: "settings.detail.search").firstMatch
        guard list.waitForExistence(timeout: 5) else { return false }
        let shown = list.frame.insetBy(dx: 0, dy: margin)
        func place(_ element: XCUIElement) -> ListPlace {
            // A row the list hasn't laid out is below what it shows: the page opens at its top, and
            // scrolls less than its height, so what is above the tab rows stays laid out.
            guard element.exists else { return .below }
            let frame = element.frame
            if frame.minY < shown.minY { return .above }
            if frame.maxY > shown.maxY { return .below }
            return .inView
        }
        func look() -> [ListPlace] {
            let deadline = Date().addingTimeInterval(2)
            var places = elements.map(place)
            while places.contains(where: { $0 != .inView }) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                places = elements.map(place)
            }
            return places
        }
        for _ in 0..<10 {
            let places = look()
            if places.allSatisfy({ $0 == .inView }) { return true }
            guard list.waitForExistence(timeout: 2) else { return false }
            let down = places.contains(.below)
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: down ? -60 : 60)
        }
        return look().allSatisfy { $0 == .inView }
    }

    /// Drags one tab's row by its name and drops it at `height` of another's row in the list (0 its
    /// top edge, 1 its bottom edge), slowly, as a person would. The caller brings both into view
    /// first, away from the list's edges. The row is the list row around the tab's content, whose
    /// height includes the group's padding and separator: the list decides a drop by that height,
    /// putting one on the middle of a row below it and one on a quarter by an edge beside that edge.
    private func dragTabRow(_ tab: String, onto target: String, at height: CGFloat) {
        let row = tabRow(tab)
        let targetRow = app.outlineRows.containing(.any, identifier: "settings.quickSearch.tab.\(target)").firstMatch
        XCTAssertTrue(row.isHittable, "The \(tab) row is in view")
        XCTAssertTrue(targetRow.isHittable, "The \(target) row is in view")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).press(
            forDuration: 1,
            thenDragTo: targetRow.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: height)),
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )
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

    private func waitForValue(of element: XCUIElement, equalTo value: String) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 5) == .completed
    }

    /// Waits for a hotkey field to show a saved shortcut other than `value`, not still recording.
    private func waitForSavedValue(of element: XCUIElement, notEqualTo value: String?) -> Bool {
        let predicate = NSPredicate(format: "value != %@ AND value != %@", value ?? "", "Waiting for shortcut")
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 5) == .completed
    }

    private func waitForEnabled(_ element: XCUIElement, _ enabled: Bool) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled))
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 5) == .completed
    }

    private func waitForNonExistence(of element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 5) == .completed
    }
}
