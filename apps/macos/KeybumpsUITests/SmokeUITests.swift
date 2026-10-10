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

        for section in [
            "permissions", "general", "plugins", "changelog", "search", "clipboard", "screenshotTools", "dictation", "windows",
            "keyboardShortcutter", "snippets", "timer", "emojiPicker", "translation", "keystrokes", "screencast",
        ] {
            element("settings.sidebar.\(section)").click()
            XCTAssertTrue(element("settings.detail.\(section)").waitForExistence(timeout: 5), section)
        }
        // The Plugins page lists every plugin, and a row opens that plugin's page.
        element("settings.sidebar.plugins").click()
        element("plugins.row.timer").click()
        XCTAssertTrue(element("settings.detail.timer").waitForExistence(timeout: 5), "A Plugins row opens its page")
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
    func testDictationDropdownsOpenAndChangeTheSetting() {
        launch(permissions: "granted", ["-KBOpenSettings", "dictation"])
        let language = element("settings.dictation.language")
        XCTAssertTrue(language.waitForExistence(timeout: 20))
        XCTAssertTrue(element("settings.dictation.durationLimit").exists)

        language.click()
        // The pop-up's own items; `app.menuItems` would also match the menu bar's.
        let first = language.menuItems.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 5), "The language dropdown opens its menu")
        let title = first.title
        first.click()
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

        // Emoji (⌘7) and Translate (⌘8) ship off, and the Hotkeys tab (⌘9) is hidden by default: none
        // shows, and their Command-numbers do nothing.
        XCTAssertFalse(app.buttons["palette.tab.emoji"].exists)
        XCTAssertFalse(app.buttons["palette.tab.translate"].exists)
        XCTAssertFalse(app.buttons["palette.tab.keyboardShortcutter"].exists)
        app.typeKey("7", modifierFlags: .command)
        app.typeKey("8", modifierFlags: .command)
        app.typeKey("9", modifierFlags: .command)
        XCTAssertTrue(paletteField("Search apps, files, and folders").waitForExistence(timeout: 5), "⌘7, ⌘8, and ⌘9 are ignored")
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
        for key in ["style", "position", "size", "duration", "keys", "namesActions", "showsClicks"] {
            XCTAssertTrue(element("plugin.keystrokes.\(key)").exists, key)
        }
        XCTAssertTrue(element("capability.offBanner.keystrokes").exists, "Its page says it's off")

        element("capability.offBanner.turnOn.keystrokes").click()
        XCTAssertTrue(waitForValue(of: toggle, 1))
        XCTAssertTrue(element("capability.offBanner.keystrokes").waitForNonExistence(timeout: 5))
    }

    func testScreencastShipsOffAndTurnsOnInSettings() {
        // Its page is drawn by the plugin template: Screen Recording, the Microphone as an optional
        // permission, its preferences, and its captures folder. CI's Mac runs macOS 15 or later, so
        // it can be turned on.
        launch(permissions: "denied", ["-KBOpenSettings", "screencast"])
        let toggle = element("capability.toggle.screencast")
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue(of: toggle, 0), "Screencast ships off")
        XCTAssertTrue(app.staticTexts["Screen Recording"].exists)
        XCTAssertTrue(app.staticTexts["Microphone (Optional)"].exists)
        for key in ["recordsMicrophone", "recordsSystemAudio", "countdown", "showsShortcuts", "highlightsClicks"] {
            XCTAssertTrue(element("plugin.screencast.\(key)").exists, key)
        }
        XCTAssertTrue(element("plugin.screencast.showCaptures").exists)
        XCTAssertTrue(element("capability.offBanner.screencast").exists, "Its page says it's off")

        element("capability.offBanner.turnOn.screencast").click()
        XCTAssertTrue(waitForValue(of: toggle, 1))
        XCTAssertTrue(element("capability.offBanner.screencast").waitForNonExistence(timeout: 5))
    }

    func testScreencastPickerOpensAndSwitchesModes() {
        // The UI-test composition's made-up screens: the main screen split into two displays, two
        // made-up windows, and a recorder that records them but captures nothing.
        launchScreencastPicker()
        XCTAssertEqual(pickerWindows.count, 2, "One picker window per screen")
        let confirm = element("screencast.picker.confirm")
        let hint = element("screencast.picker.hint")
        XCTAssertTrue(waitForLabel(of: confirm, "Record"))
        XCTAssertTrue(waitForText(of: hint, "Drag to choose an area."))
        for key in ["microphone", "systemAudio", "shortcuts", "clicks"] {
            XCTAssertTrue(element("screencast.picker.\(key)").exists, key)
        }

        element("screencast.picker.kind.screenshot").click()
        XCTAssertTrue(waitForLabel(of: confirm, "Capture"))
        XCTAssertTrue(element("screencast.picker.microphone").waitForNonExistence(timeout: 5), "A screenshot has no sound")
        XCTAssertFalse(element("screencast.picker.systemAudio").exists)

        element("screencast.picker.target.window").click()
        XCTAssertTrue(waitForText(of: hint, "Click a window to choose it."))

        element("screencast.picker.kind.video").click()
        XCTAssertTrue(waitForLabel(of: confirm, "Record"))
        XCTAssertTrue(element("screencast.picker.microphone").waitForExistence(timeout: 5))
    }

    func testScreencastPickerChoosesOneScreenOrEveryScreen() {
        launchScreencastPicker()
        let hint = element("screencast.picker.hint")
        element("screencast.picker.target.screen").click()
        XCTAssertTrue(waitForText(of: hint, "Every screen, one file each. Click a screen for just that one."))
        let everyScreen = element("screencast.picker.everyScreen")
        XCTAssertTrue(everyScreen.exists)

        // Above the bar, which sits at the bottom of one of them.
        let rightScreen = (0..<pickerWindows.count).map { pickerWindows.element(boundBy: $0) }.max { $0.frame.minX < $1.frame.minX }
        rightScreen?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).click()
        XCTAssertTrue(waitForText(of: hint, "This screen only. Choose Every Screen for all of them."))

        everyScreen.click()
        XCTAssertTrue(waitForText(of: hint, "Every screen, one file each. Click a screen for just that one."))
    }

    func testEscapeClosesTheScreencastPicker() {
        launchScreencastPicker()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(pickerWindows.firstMatch.waitForNonExistence(timeout: 5))
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

        let stop = element("screencast.bar.stop")
        stop.click()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 10), "Stop ends the recording, and the bar closes")
        XCTAssertFalse(app.windows.matching(identifier: "screencastControlBar").firstMatch.exists)
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

        // An arrow on the drawing layer, which takes the pointer while drawing.
        let clear = element("screencast.draw.clear")
        XCTAssertFalse(clear.isEnabled, "Nothing to clear yet")
        let layer = app.windows.matching(identifier: "screencastDrawing").firstMatch
        XCTAssertTrue(layer.waitForExistence(timeout: 5))
        layer.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: layer.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)))
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
        stop.click()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.windows.matching(identifier: "screencastDrawing").firstMatch.exists, "The drawing goes with the recording")
    }

    // MARK: Screencast's review panel (#450)

    func testScreencastReviewSavesAScreenshotWithItsNote() {
        launchScreencastReview("screenshot")
        XCTAssertTrue(element("screencast.review.addToScreenshots").exists, "A screenshot offers Also add to Screenshots")
        XCTAssertTrue(element("screencast.review.type").exists)
        XCTAssertTrue(element("screencast.review.repository").exists)
        XCTAssertTrue(element("screencast.review.destination").exists)
        XCTAssertFalse(element("screencast.review.saveAndSend").isEnabled, "Sending comes with destinations")
        XCTAssertFalse(element("screencast.review.sendAndDelete").isEnabled)

        let note = element("screencast.review.note")
        note.click()
        note.typeText("Header typo")
        element("screencast.review.save").click()
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10), "Save closes the panel")
        XCTAssertTrue(waitForReviewOutcome("saved; folder kept; note Header typo"))
    }

    func testScreencastReviewReturnSaves() {
        launchScreencastReview("screenshot")
        let note = element("screencast.review.note")
        note.click()
        note.typeText("Saved by Return")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10))
        XCTAssertTrue(waitForReviewOutcome("saved; folder kept; note Saved by Return"))
    }

    func testScreencastReviewEscapeClosesAndSaves() {
        launchScreencastReview("video")
        let note = element("screencast.review.note")
        note.click()
        note.typeText("Closed by Escape")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10), "Escape closes the panel")
        XCTAssertTrue(waitForReviewOutcome("saved; folder kept; note Closed by Escape"), "Closing saves")
    }

    func testScreencastReviewCopies() {
        launchScreencastReview("screenshot")
        element("screencast.review.copy").click()
        XCTAssertTrue(reviewPanel.waitForNonExistence(timeout: 10))
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

    func testScreencastReviewOfAVideoHasTrimAndNoScreenshotsSwitch() {
        launchScreencastReview("video")
        XCTAssertTrue(element("screencast.review.trim").exists)
        XCTAssertFalse(element("screencast.review.addToScreenshots").exists, "Only a screenshot can go to ⌘3")
        XCTAssertFalse(element("screencast.review.edit").exists)
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
        XCTAssertTrue(app.staticTexts["Accessibility (Optional)"].exists, "⌘P pastes with it (#379)")

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

    /// Turns Screencast on (it ships off) and opens its picker, as Start Screencast does.
    private func launchScreencastPicker() {
        launch(permissions: "granted", ["-KBUITestEnableCapabilities", "screencast", "-KBOpenScreencastPicker", "YES"])
        XCTAssertTrue(element("screencast.picker.bar").waitForExistence(timeout: 20))
    }

    /// Turns Screencast on and starts a recording of a made-up screen, as Record would.
    private func launchScreencastRecording() {
        launch(permissions: "granted", ["-KBUITestEnableCapabilities", "screencast", "-KBUITestScreencastRecording", "YES"])
        // The bar shows as the recording starts, its buttons waiting until it records.
        let pause = element("screencast.bar.pause")
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: pause)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed, "Recording")
    }

    /// Turns Screencast on and opens its review panel on a made-up `video` or `screenshot`.
    private func launchScreencastReview(_ capture: String) {
        launch(permissions: "granted", ["-KBUITestEnableCapabilities", "screencast", "-KBUITestScreencastReview", capture])
        XCTAssertTrue(element("screencast.review.note").waitForExistence(timeout: 20))
    }

    private var reviewPanel: XCUIElement {
        app.windows.matching(identifier: "screencast.review.panel").firstMatch
    }

    /// The UI-test-only line that says what the panel did with the capture.
    private func waitForReviewOutcome(_ text: String) -> Bool {
        let outcome = element("screencast.review.uitest.outcome")
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: outcome)], timeout: 10) == .completed
    }

    private var pickerWindows: XCUIElementQuery {
        app.windows.matching(identifier: "screencastPicker")
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
