import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// The key display (#443) and the Keystrokes plugin. Nothing here listens to the keyboard or the
/// pointer, or draws on screen: presses and clicks come from fakes, and the presenter records.
@MainActor
@Suite("Keystrokes")
struct KeystrokesTests {
    /// What a Screencast recording will hold the display as (#449).
    static let recording = KeyDisplayOwner("screencast")

    // MARK: Naming

    @Test("A shortcut lists ⌃ ⌥ ⇧ ⌘ in menu order, then its key as a keycap shows it")
    func shortcutKeys() {
        #expect(name(kVK_ANSI_C, [.command]) == Keystroke(modifiers: ["⌘"], key: "C", isShortcut: true))
        #expect(name(kVK_ANSI_4, [.shift, .command])?.keycaps == ["⇧", "⌘", "4"])
        #expect(name(kVK_ANSI_K, [.command, .shift, .option, .control])?.text == "⌃⌥⇧⌘K")
        #expect(name(kVK_ANSI_Slash, [.shift, .command])?.text == "⇧⌘/", "Read without ⇧, as KeyCastr does")
        #expect(name(kVK_LeftArrow, [.option, .command])?.keycaps == ["⌥", "⌘", "←"])
        #expect(name(kVK_Space, [.command])?.keycaps == ["⌘", "Space"])
        #expect(name(kVK_F5, [.control])?.text == "⌃F5")
        #expect(name(kVK_Return, [.command])?.text == "⌘↩")
        #expect(name(kVK_Escape, [.option, .command])?.text == "⌥⌘⎋")
        #expect(name(kVK_LeftArrow, [.option])?.text == "⌥←", "⌥ with a key that types nothing is a shortcut")
        #expect(name(kVK_Delete, [.option, .shift])?.text == "⌥⇧⌫")
        #expect(name(kVK_ANSI_C, [.command, .capsLock])?.text == "⌘C", "Caps Lock isn't shown")
    }

    @Test("A ⌘ shortcut's key comes from the layout's ⌘ keys, and a capital that's longer stays as it is")
    func layoutAwareKeys() {
        // Dvorak – QWERTY ⌘: the key that types j types c while ⌘ is held.
        let dvorak = FixedKeyboardLayout(plain: [kVK_ANSI_C: "j"], command: [kVK_ANSI_C: "c"])
        #expect(KeystrokeNaming.keystroke(for: press(kVK_ANSI_C, [.command]), layout: dvorak)?.text == "⌘C")
        #expect(KeystrokeNaming.keystroke(for: press(kVK_ANSI_C, [.control]), layout: dvorak)?.text == "⌃J")
        let german = FixedKeyboardLayout(plain: [kVK_ANSI_Minus: "ß"])
        #expect(KeystrokeNaming.keystroke(for: press(kVK_ANSI_Minus, [.command]), layout: german)?.text == "⌘ß")
        #expect(KeystrokeNaming.keycapCase("é") == "É")
    }

    @Test("Typing is what the key typed, a space as ␣, and other keys as their symbols")
    func typingKeys() {
        #expect(name(kVK_ANSI_H, []) == Keystroke(modifiers: [], key: "h", isShortcut: false))
        #expect(name(kVK_ANSI_H, [.shift])?.key == "H")
        #expect(name(kVK_ANSI_H, [.capsLock])?.key == "H")
        #expect(name(kVK_ANSI_Slash, [.shift])?.key == "?")
        #expect(name(kVK_Space, [])?.key == "␣")
        #expect(name(kVK_Delete, [])?.key == "⌫")
        #expect(name(kVK_LeftArrow, [.shift])?.key == "⇧←")
        #expect(name(kVK_Tab, [.shift])?.key == "⇤", "As KeyCastr shows ⇧⇥")
        #expect(name(kVK_JIS_Eisu, [])?.key == "英数")
        #expect(name(kVK_ANSI_Q, []) == nil, "A key the layout types nothing for isn't shown")
        #expect(name(kVK_ANSI_A, [.option]) == Keystroke(modifiers: [], key: "å", isShortcut: false), "⌥ with a letter types a character")
        #expect(name(kVK_Space, [.option])?.isShortcut == false)
    }

    @Test("⌥ with a key that types a character is typing on any layout, so Shortcuts only never shows a German @ or a Polish ż")
    func optionTyping() throws {
        // German: ⌥L types @ and ⌥5 types [. Polish Pro: ⌥Z types ż.
        let german = FixedKeyboardLayout(option: [kVK_ANSI_L: "@", kVK_ANSI_5: "[", kVK_ANSI_Z: "ż"])
        let harness = DisplayHarness(layout: german)
        harness.display.acquire(.keystrokes, configuration: KeyDisplayConfiguration())
        for code in [kVK_ANSI_L, kVK_ANSI_5, kVK_ANSI_Z] {
            harness.keys.press(press(code, [.option]))
            harness.keys.press(press(code, [.option, .shift]))
        }
        #expect(harness.presenter.last?.entries.isEmpty ?? true, "Nothing typed shows")
        harness.keys.press(press(kVK_LeftArrow, [.option]))
        harness.keys.press(press(kVK_ANSI_L, [.option, .command]))
        #expect(harness.presenter.last?.entries.map(\.text) == ["⌥←", "⌥⌘L"])

        var allKeys = KeyDisplayConfiguration()
        allKeys.keys = .allKeys
        harness.display.acquire(.keystrokes, configuration: allKeys)
        harness.keys.press(press(kVK_ANSI_L, [.option]))
        #expect(harness.presenter.last?.entries.last?.text == "@", "With All keys it shows as what it typed")
        #expect(KeystrokeNaming.keystroke(for: press(kVK_ANSI_Z, [.option]), layout: german)?.key == "ż")
    }

    @Test("A Keybumps shortcut registered now is a shortcut whatever its keys, so Dictation's ⌥Space shows, named")
    func registeredOptionShortcuts() throws {
        #expect(!KeystrokeFilter.shows(press(kVK_Space, [.option]), keys: .shortcutsOnly, secureInput: false))
        #expect(KeystrokeFilter.shows(press(kVK_Space, [.option]), keys: .shortcutsOnly, secureInput: false, isKeybumpsShortcut: true))
        #expect(KeystrokeNaming.keystroke(for: press(kVK_ANSI_K, [.option]), layout: FixedKeyboardLayout(), isKeybumpsShortcut: true)?.text == "⌥K")

        for keys in KeyDisplayConfiguration.Keys.allCases {
            let harness = DisplayHarness()
            harness.display.registeredShortcutName = { $0 == KeyPress(keyCode: UInt16(kVK_Space), modifiers: [.option]) ? "Start & Stop Dictation" : nil }
            var configuration = KeyDisplayConfiguration()
            configuration.keys = keys
            harness.display.acquire(.keystrokes, configuration: configuration)
            harness.keys.press(press(kVK_ANSI_H, []))
            harness.keys.press(press(kVK_Space, [.option]))
            let last = try #require(harness.presenter.last?.entries.last)
            #expect(last.text == "⌥Space", "\(keys)")
            #expect(last.name == "Start & Stop Dictation")
            #expect(!last.isTyping, "Not joined to the typing")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsKeystrokesDictation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = WiringHarness(enabled: [.keystrokes, .dictation], missing: nil, root: root)
        app.model.start()
        app.model.keyDisplay.receive(press(kVK_Space, [.option]))
        #expect(app.model.keyDisplay.timeline.entries.map(\.text) == ["⌥Space"])
        #expect(app.model.keyDisplay.timeline.entries.map(\.name) == ["Start & Stop Dictation"], "Its registered binding")
    }

    @Test("A key-down is read as its code, its modifiers, a repeat, and Keybumps' own marker, never its characters")
    func readsEvents() throws {
        let event = try #require(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true))
        event.flags = [.maskCommand, .maskShift, .maskSecondaryFn]
        #expect(KeyPress(event: event) == KeyPress(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .shift]))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: SystemTextPaster.syntheticEventMarker)
        let read = KeyPress(event: event)
        #expect(read.isRepeat)
        #expect(read.isSynthetic)
        #expect(KeyModifiers([.maskControl, .maskAlternate, .maskAlphaShift]) == [.control, .option, .capsLock])
        #expect(KeyModifiers([.command, .shift, .capsLock]).carbonFlags == UInt32(cmdKey | shiftKey))
    }

    // MARK: Filter

    @Test("Shortcuts only shows presses with ⌘ or ⌃, and ⌥ only with a key that types nothing; never plain typing or ⇧ alone. All keys shows both")
    func shortcutsOnly() {
        for modifiers: KeyModifiers in [[.command], [.control], [.option, .command], [.option, .control], [.option, .shift, .command]] {
            #expect(KeystrokeFilter.shows(press(kVK_ANSI_A, modifiers), keys: .shortcutsOnly, secureInput: false), "\(modifiers)")
        }
        for modifiers: KeyModifiers in [[], [.shift], [.capsLock], [.option], [.option, .shift]] {
            #expect(!KeystrokeFilter.shows(press(kVK_ANSI_A, modifiers), keys: .shortcutsOnly, secureInput: false), "\(modifiers)")
            #expect(KeystrokeFilter.shows(press(kVK_ANSI_A, modifiers), keys: .allKeys, secureInput: false), "\(modifiers)")
        }
        let typesNothing = [
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Delete, kVK_ForwardDelete, kVK_Return, kVK_ANSI_KeypadEnter,
            kVK_Tab, kVK_Escape, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_F1, kVK_F12,
        ]
        for code in typesNothing {
            #expect(KeystrokeFilter.shows(press(code, [.option]), keys: .shortcutsOnly, secureInput: false), "⌥ \(code)")
        }
        for code in [kVK_Space, kVK_ANSI_1, kVK_ANSI_Slash, kVK_ANSI_Grave] {
            #expect(!KeystrokeFilter.shows(press(code, [.option]), keys: .shortcutsOnly, secureInput: false), "⌥ \(code) types a character")
        }
    }

    @Test("Nothing shows while secure input is on, ⌘ and ⌃ shortcuts included, or that Keybumps posted itself, whatever Show says")
    func secureInputAndSyntheticKeys() {
        for keys in KeyDisplayConfiguration.Keys.allCases {
            #expect(!KeystrokeFilter.shows(press(kVK_ANSI_A, [.option]), keys: keys, secureInput: true), "A password typed with ⌥")
            #expect(!KeystrokeFilter.shows(press(kVK_ANSI_V, [.command]), keys: keys, secureInput: true))
            #expect(!KeystrokeFilter.shows(press(kVK_ANSI_A, []), keys: keys, secureInput: true))
            var pasted = press(kVK_ANSI_V, [.command])
            pasted.isSynthetic = true
            #expect(!KeystrokeFilter.shows(pasted, keys: keys, secureInput: false), "Keybumps' own ⌘V")
        }
    }

    // MARK: Action names

    @Test("Standard shortcuts are named, a Keybumps shortcut by its own title first, and typing never")
    func actionNames() throws {
        let copy = try #require(name(kVK_ANSI_C, [.command]))
        #expect(KeystrokeActionNames.name(for: copy, keybumps: nil) == "Copy")
        #expect(KeystrokeActionNames.name(for: try #require(name(kVK_Space, [.command])), keybumps: "Open Quick Search") == "Open Quick Search")
        #expect(KeystrokeActionNames.name(for: try #require(name(kVK_ANSI_Z, [.shift, .command])), keybumps: nil) == "Redo")
        #expect(KeystrokeActionNames.name(for: try #require(name(kVK_Tab, [.command])), keybumps: nil) == "Switch Apps")
        #expect(KeystrokeActionNames.name(for: try #require(name(kVK_ANSI_R, [.command])), keybumps: nil) == nil, "Depends on the app")
        #expect(KeystrokeActionNames.name(for: try #require(name(kVK_ANSI_C, [])), keybumps: "Copy") == nil, "Typing")

        let bindings = [
            CapabilityShortcut.quickSearch.ownerID: DefaultShortcut.quickSearch,
            "window.\(WindowAction.left.rawValue)": try #require(WindowAction.left.defaultShortcut),
        ]
        #expect(KeystrokeActionNames.keybumpsName(for: press(kVK_Space, [.command]), bindings: bindings) == "Open Quick Search")
        #expect(KeystrokeActionNames.keybumpsName(for: press(kVK_Space, [.command, .capsLock]), bindings: bindings) == "Open Quick Search")
        #expect(KeystrokeActionNames.keybumpsName(for: press(kVK_LeftArrow, [.control, .option, .command]), bindings: bindings) == "Left")
        #expect(KeystrokeActionNames.keybumpsName(for: press(kVK_Space, [.command, .shift]), bindings: bindings) == nil)
    }

    @Test("In the Command Palette, standard shortcuts get the palette's own names, or none")
    func paletteNames() throws {
        let palette = KeystrokeActionNames.paletteNames([.paste(), .edit, .space("Play")])
        #expect(palette == ["⌘P": "Paste", "⌘↩": "Edit", "Space": "Play"])
        #expect(KeystrokeActionNames.name(for: try #require(name(kVK_ANSI_P, [.command])), keybumps: nil, palette: palette) == "Paste", "Not Print")
        #expect(KeystrokeActionNames.name(for: try #require(name(kVK_Return, [.command])), keybumps: nil, palette: palette) == "Edit")
        #expect(KeystrokeActionNames.name(for: try #require(name(kVK_ANSI_Z, [.command])), keybumps: nil, palette: palette) == nil, "Not Undo")
        #expect(KeystrokeActionNames.name(for: try #require(name(kVK_ANSI_P, [.command])), keybumps: nil, palette: nil) == "Print")
        #expect(KeystrokeActionNames.name(for: try #require(name(kVK_Space, [.command])), keybumps: "Open Quick Search", palette: palette) == "Open Quick Search")
    }

    @Test("Only shortcuts registered with macOS now are named: not one that failed, and none while a shortcut is being recorded")
    func registeredBindingsOnly() {
        let backend = RefusingHotKeys(refused: DefaultShortcut.quickSearch)
        let coordinator = GlobalShortcutCoordinator(backend: backend)
        coordinator.register(owner: CapabilityShortcut.quickSearch.ownerID, binding: DefaultShortcut.quickSearch) {}
        coordinator.register(owner: CapabilityShortcut.clipboardHistory.ownerID, binding: DefaultShortcut.clipboard) {}
        #expect(coordinator.desiredBindings.count == 2)
        #expect(Array(coordinator.registeredBindings.keys) == [CapabilityShortcut.clipboardHistory.ownerID], "Spotlight owns ⌘Space")
        #expect(KeystrokeActionNames.keybumpsName(for: press(kVK_Space, [.command]), bindings: coordinator.registeredBindings) == nil)
        #expect(KeystrokeActionNames.keybumpsName(for: press(kVK_Space, [.shift, .command]), bindings: coordinator.registeredBindings) == "Open Clipboard History")

        coordinator.suspendForRecording()
        #expect(coordinator.registeredBindings.isEmpty)
        coordinator.resumeAfterRecording()
        #expect(coordinator.registeredBindings.count == 1)
    }

    // MARK: Timeline

    @Test("A shortcut starts a line, the same one again counts, and only the newest three lines show")
    func shortcutLines() throws {
        var timeline = KeystrokeTimeline()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        for (offset, code) in [kVK_ANSI_Z, kVK_ANSI_Z, kVK_ANSI_Z].enumerated() {
            timeline.record(try #require(name(code, [.command])), name: "Undo", at: start + Double(offset) * 0.3, linger: 1.5)
        }
        #expect(timeline.entries.map(\.text) == ["⌘Z"])
        #expect(timeline.entries.first?.count == 3)
        #expect(timeline.entries.first?.name == "Undo")

        for (offset, code) in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_S].enumerated() {
            timeline.record(try #require(name(code, [.command])), name: nil, at: start + 1 + Double(offset) * 0.1, linger: 1.5)
        }
        #expect(timeline.entries.map(\.text) == ["⌘C", "⌘V", "⌘S"], "The newest and the two above it")
        #expect(timeline.entries.map(\.keycaps) == [["⌘", "C"], ["⌘", "V"], ["⌘", "S"]])
    }

    @Test("Typing joins its line until a pause, keeps the end of a long line, and a shortcut ends it")
    func typingLines() throws {
        var timeline = KeystrokeTimeline()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var time = start
        for code in [kVK_ANSI_H, kVK_ANSI_A, kVK_Space, kVK_ANSI_H] {
            timeline.record(try #require(name(code, [])), name: nil, at: time, linger: 5)
            time += 0.2
        }
        #expect(timeline.entries.map(\.text) == ["ha␣h"])
        #expect(timeline.entries.first?.keycaps == ["ha␣h"], "One keycap holds what was typed")

        time += KeystrokeTimeline.typingBreak + 0.1
        timeline.record(try #require(name(kVK_ANSI_A, [])), name: nil, at: time, linger: 5)
        #expect(timeline.entries.map(\.text) == ["ha␣h", "a"], "A pause starts a new line")

        timeline.record(try #require(name(kVK_ANSI_S, [.command])), name: "Save", at: time + 0.1, linger: 5)
        timeline.record(try #require(name(kVK_ANSI_A, [])), name: nil, at: time + 0.2, linger: 5)
        #expect(timeline.entries.map(\.text) == ["a", "⌘S", "a"])

        for _ in 0..<30 { timeline.record(try #require(name(kVK_ANSI_H, [])), name: nil, at: time + 0.3, linger: 5) }
        #expect(timeline.entries.last?.text.count == KeystrokeTimeline.typedCharacters)
    }

    @Test("A line goes once it has been on screen for Stays on screen since its last press, and rings after half a second")
    func expiry() throws {
        var timeline = KeystrokeTimeline()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        timeline.record(try #require(name(kVK_ANSI_C, [.command])), name: nil, at: start, linger: 1.5)
        timeline.record(try #require(name(kVK_ANSI_V, [.command])), name: nil, at: start + 1, linger: 1.5)
        timeline.recordClick(at: CGPoint(x: 10, y: 20), time: start + 1)
        #expect(timeline.nextExpiry(linger: 1.5) == start + 1.5, "⌘C, first")

        timeline.expire(at: start + 1.5, linger: 1.5)
        #expect(timeline.entries.map(\.text) == ["⌘V"])
        #expect(timeline.clicks.isEmpty)
        #expect(timeline.nextExpiry(linger: 1.5) == start + 2.5)

        timeline.expire(at: start + 2.5, linger: 1.5)
        #expect(timeline.entries.isEmpty)
        #expect(timeline.nextExpiry(linger: 1.5) == nil)
    }

    // MARK: Holding

    @Test("The most recent holder's look applies, with Shortcuts only if any holder asks for it")
    func combinedConfiguration() {
        var plugin = KeyDisplayConfiguration()
        plugin.keys = .allKeys
        plugin.style = .bezel
        var recordingLook = KeyDisplayConfiguration()
        recordingLook.position = .bottomRight

        var holds = KeyDisplayHolds()
        #expect(holds.configuration == nil)
        holds.acquire(.keystrokes, configuration: plugin)
        #expect(holds.configuration == plugin)

        holds.acquire(Self.recording, configuration: recordingLook)
        #expect(holds.configuration == recordingLook, "The recording's own look, shortcuts only")

        var recordingAllKeys = recordingLook
        recordingAllKeys.keys = .allKeys
        holds.acquire(Self.recording, configuration: recordingAllKeys)
        #expect(holds.configuration == recordingAllKeys)

        var pluginShortcuts = plugin
        pluginShortcuts.keys = .shortcutsOnly
        holds.acquire(.keystrokes, configuration: pluginShortcuts)
        #expect(holds.owners == [.keystrokes, Self.recording], "Acquiring again keeps its place")
        #expect(holds.configuration?.position == .bottomRight, "Still the recording's look")
        #expect(holds.configuration?.keys == .shortcutsOnly, "Because the plugin asks for it")

        let released = holds.release(Self.recording)
        #expect(released)
        #expect(holds.configuration == pluginShortcuts)
        let releasedAgain = holds.release(Self.recording)
        #expect(!releasedAgain, "It no longer holds it")
        let reacquired = holds.acquire(.keystrokes, configuration: pluginShortcuts)
        #expect(!reacquired, "Nothing changed")
    }

    @Test("A recording's screens win while it holds the display, even when the plugin is turned on after it started")
    func recordingScreensWin() {
        var recording = KeyDisplayConfiguration()
        recording.displays = [2]
        var holds = KeyDisplayHolds()
        holds.acquire(Self.recording, configuration: recording, keepsWindowsOnScreen: true)
        holds.acquire(.keystrokes, configuration: KeyDisplayConfiguration())
        #expect(holds.configuration?.displays == [2], "The plugin's look, the recording's screen")
        #expect(holds.keepsWindowsOnScreen)
        holds.release(Self.recording)
        #expect(holds.configuration?.displays == nil, "The pointer's screen again")
        #expect(!holds.keepsWindowsOnScreen)
    }

    @Test("Lines show on the configuration's screens or the pointer's; rings on the clicked screen if it's allowed; windows only where there's something to show, unless a holder keeps them up")
    func screensForContent() {
        let screens = [
            KeyDisplayScreen(display: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 90)),
            KeyDisplayScreen(display: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100), visibleFrame: CGRect(x: 100, y: 0, width: 100, height: 90)),
        ]
        let now = Date()
        let line = KeystrokeTimeline.Entry(id: 1, keycaps: ["⌘", "C"], text: "⌘C", isTyping: false, lastPress: now)
        let clickOn2 = KeystrokeTimeline.Click(id: 2, location: CGPoint(x: 150, y: 50), time: now)

        var content = KeyDisplayContent(configuration: KeyDisplayConfiguration(), entries: [], clicks: [], pointerDisplay: 1)
        #expect(content.displaysNeedingWindows(on: screens).isEmpty, "Nothing to show")
        content.entries = [line]
        #expect(content.lineDisplays == [1])
        #expect(content.displaysNeedingWindows(on: screens) == [1], "The pointer's screen")
        content.clicks = [clickOn2]
        #expect(content.displaysNeedingWindows(on: screens) == [1, 2], "A ring on the clicked screen")

        content.configuration.displays = [1]
        #expect(!content.showsClicks(on: 2))
        #expect(content.displaysNeedingWindows(on: screens) == [1], "No ring off the recorded screen")
        content.entries = []
        content.clicks = []
        content.keepsWindowsOnScreen = true
        #expect(content.displaysNeedingWindows(on: screens) == [1], "Kept up on the recorded screen with nothing to show")
        content.configuration.displays = nil
        #expect(content.displaysNeedingWindows(on: screens) == [1, 2])
    }

    // MARK: The display

    @Test("The first holder starts the keyboard tap and puts the windows up; only the last one's release stops both")
    func firstAndLastHolder() {
        let harness = DisplayHarness()
        let display = harness.display
        #expect(!display.isShowing)
        #expect(display.overlayWindows.isEmpty)

        display.acquire(.keystrokes, configuration: KeyDisplayConfiguration())
        #expect(display.isShowing)
        #expect(harness.keys.isRunning)
        #expect(display.isListening)
        #expect(display.overlayWindows.isEmpty, "The plugin alone keeps no window up with nothing to show")

        display.acquire(Self.recording, configuration: KeyDisplayConfiguration(), keepsWindowsOnScreen: true)
        #expect(harness.keys.starts == 1, "One display, one tap")
        #expect(display.overlayWindows.count == 1, "Up before the first key, so the recording can add it")
        #expect(display.overlayWindowIDs.count == 1)
        #expect(display.overlayWindowIDs.map(Int.init) == display.overlayWindows.map(\.windowNumber), "As SCWindow.windowID")

        display.release(.keystrokes)
        #expect(display.isShowing, "The recording still holds it")
        #expect(harness.keys.isRunning)
        #expect(display.overlayWindows.count == 1)
        display.release(Self.recording)
        #expect(!display.isShowing)
        #expect(!harness.keys.isRunning)
        #expect(display.overlayWindows.isEmpty)
    }

    @Test("A recording that starts while the plugin shows keys reuses its display, which keeps the plugin's settings once it ends")
    func recordingReusesThePluginsDisplay() {
        let harness = DisplayHarness()
        let display = harness.display
        var plugin = KeyDisplayConfiguration()
        plugin.style = .bezel
        plugin.position = .bottomLeft
        display.acquire(.keystrokes, configuration: plugin)
        display.acquire(Self.recording, configuration: KeyDisplayConfiguration())
        #expect(harness.presenter.last?.configuration.style == .keycaps, "The recording's look while it records")

        display.release(Self.recording)
        #expect(display.configuration == plugin)
        #expect(harness.presenter.last?.configuration == plugin)
        #expect(harness.keys.isRunning)
    }

    @Test("It runs for a recording with the plugin off, and turning the plugin off mid-recording leaves the recording's display running")
    func pluginOffMidRecording() {
        let harness = DisplayHarness()
        let display = harness.display
        display.acquire(Self.recording, configuration: KeyDisplayConfiguration())
        #expect(display.isShowing, "No plugin needed")
        display.acquire(.keystrokes, configuration: KeyDisplayConfiguration())
        display.release(.keystrokes)
        #expect(display.isShowing)
        #expect(display.owners == [Self.recording])
        #expect(harness.keys.isRunning)
        #expect(harness.presenter.hides == 0)
    }

    @Test("A holder hears about the overlay windows at once and whenever they're replaced, until it lets go")
    func overlayWindowHandler() {
        let harness = DisplayHarness()
        let display = harness.display
        display.acquire(.keystrokes, configuration: KeyDisplayConfiguration())
        var heard: [[NSWindow]] = []
        display.acquire(Self.recording, configuration: KeyDisplayConfiguration(), keepsWindowsOnScreen: true) { heard.append($0) }
        #expect(heard.map(\.count) == [1], "At once, with the windows already up")

        harness.presenter.addDisplay()
        #expect(heard.map(\.count) == [1, 2], "A display was connected")
        #expect(heard.last.map { $0.map(ObjectIdentifier.init) } == display.overlayWindows.map(ObjectIdentifier.init))

        display.release(Self.recording)
        harness.presenter.addDisplay()
        #expect(heard.count == 2, "Not after it lets go")
    }

    @Test("Keys reach the overlay named, with the action's name, and leave once they've been on screen long enough")
    func keysReachTheOverlay() throws {
        let harness = DisplayHarness()
        let display = harness.display
        display.registeredShortcutName = { $0.keyCode == UInt16(kVK_Space) ? "Open Quick Search" : nil }
        display.pointerDisplay = { 7 }
        display.acquire(.keystrokes, configuration: KeyDisplayConfiguration())

        harness.keys.press(press(kVK_ANSI_C, [.command]))
        harness.keys.press(press(kVK_Space, [.command]))
        harness.keys.press(press(kVK_ANSI_H, []))
        let content = try #require(harness.presenter.last)
        #expect(content.entries.map(\.text) == ["⌘C", "⌘Space"], "Shortcuts only by default")
        #expect(content.entries.map(\.name) == ["Copy", "Open Quick Search"])
        #expect(content.pointerDisplay == 7, "On the pointer's screen")
        #expect(harness.presenter.animations.last == true)
        #expect(harness.scheduler.pending?.date == harness.clock.now + 1.5)

        harness.clock.now += 1.5
        display.expire()
        #expect(harness.presenter.last?.entries.isEmpty == true)
        #expect(harness.scheduler.pending == nil)
    }

    @Test("Name the action off shows no names; secure input shows nothing")
    func namesAndSecureInput() {
        let harness = DisplayHarness()
        var configuration = KeyDisplayConfiguration()
        configuration.namesActions = false
        configuration.keys = .allKeys
        harness.display.acquire(.keystrokes, configuration: configuration)
        harness.keys.press(press(kVK_ANSI_C, [.command]))
        #expect(harness.presenter.last?.entries.map(\.name) == [nil])

        harness.secureInput.isOn = true
        harness.keys.press(press(kVK_ANSI_H, []))
        harness.keys.press(press(kVK_ANSI_V, [.command]))
        #expect(harness.presenter.last?.entries.map(\.text) == ["⌘C"])
    }

    @Test("When Shortcuts only starts applying, typing on screen goes at once")
    func shortcutsOnlyTakesTypingOff() {
        let harness = DisplayHarness()
        var plugin = KeyDisplayConfiguration()
        plugin.keys = .allKeys
        harness.display.acquire(.keystrokes, configuration: plugin)
        harness.keys.press(press(kVK_ANSI_H, []))
        harness.keys.press(press(kVK_ANSI_C, [.command]))
        #expect(harness.presenter.last?.entries.map(\.text) == ["h", "⌘C"])

        harness.display.acquire(Self.recording, configuration: KeyDisplayConfiguration())
        #expect(harness.presenter.last?.entries.map(\.text) == ["⌘C"], "The recording never shows what was typed")
        #expect(harness.presenter.animations.last == false, "Gone at once, with no fade")
    }

    @Test("A screenshot shortcut never shows: it clears the screen at once, and nothing, rings included, shows until a key that isn't part of the screenshot")
    func screenshotsClearTheDisplay() throws {
        let harness = DisplayHarness()
        let display = harness.display
        var configuration = KeyDisplayConfiguration()
        configuration.keys = .allKeys
        configuration.showsClicks = true
        display.acquire(.keystrokes, configuration: configuration)
        harness.keys.press(press(kVK_ANSI_C, [.command]))
        harness.pointer.send(.down, at: CGPoint(x: 5, y: 5))
        #expect(harness.presenter.last?.entries.count == 1)

        harness.keys.press(press(kVK_ANSI_4, [.shift, .command]))
        #expect(display.isPausedForScreenshot)
        #expect(harness.presenter.last?.entries.isEmpty == true)
        #expect(harness.presenter.last?.clicks.isEmpty == true)
        #expect(harness.presenter.animations.last == false, "No fade into the screenshot")

        harness.pointer.send(.down, at: CGPoint(x: 5, y: 5))
        for key in [kVK_Escape, kVK_Space, kVK_Return] { harness.keys.press(press(key, [])) }
        harness.keys.press(press(kVK_ANSI_3, [.control, .shift, .command]))
        harness.keys.press(press(kVK_ANSI_5, [.shift, .command]))
        #expect(harness.presenter.last?.entries.isEmpty == true, "The drag's click, Escape, Space, Return, and more screenshots show nothing")
        #expect(harness.presenter.last?.clicks.isEmpty == true)
        #expect(display.isPausedForScreenshot)

        harness.keys.press(press(kVK_ANSI_H, []))
        #expect(!display.isPausedForScreenshot)
        #expect(harness.presenter.last?.entries.map(\.text) == ["h"], "The next other key ends it, and shows")
    }

    @Test("Screenshot shortcuts: macOS's defaults when its settings can't be read, on any layout, and the bindings passed for Screenshot Tools")
    func screenshotShortcuts() throws {
        for code in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_6] {
            #expect(KeystrokeFilter.isScreenshotShortcut(press(code, [.shift, .command])))
            #expect(KeystrokeFilter.isScreenshotShortcut(press(code, [.control, .shift, .command])), "⌃ copies the shot")
            #expect(KeystrokeFilter.isScreenshotShortcut(press(code, [.shift, .command, .capsLock])))
            #expect(!KeystrokeFilter.isScreenshotShortcut(press(code, [.command])), "⌘\(code)")
        }
        #expect(KeystrokeFilter.isScreenshotShortcut(press(kVK_ANSI_5, [.shift, .command])))
        #expect(!KeystrokeFilter.isScreenshotShortcut(press(kVK_ANSI_2, [.shift, .command])), "Not macOS's")
        #expect(KeystrokeFilter.isScreenshotShortcut(press(kVK_ANSI_2, [.shift, .command]), keybumps: [DefaultShortcut.screenshotScreen]))
        let moved = ShortcutBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), displayName: "⌃⌥S")
        #expect(KeystrokeFilter.isScreenshotShortcut(press(kVK_ANSI_S, [.control, .option]), keybumps: [moved]))
        #expect(!KeystrokeFilter.isScreenshotShortcut(press(kVK_ANSI_S, [.control, .option])))
    }

    @Test("macOS's screenshot shortcuts are read as the person set them: turned off, moved, or left at their defaults")
    func symbolicScreenshotShortcuts() {
        let optionShift = Int(NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.shift.rawValue)
        let hotKeys: [String: Any] = [
            "28": ["enabled": false, "value": ["parameters": [51, kVK_ANSI_3, 1_179_648], "type": "standard"]],
            "30": ["enabled": true, "value": ["parameters": [65535, kVK_ANSI_4, optionShift], "type": "standard"]],
            "31": ["enabled": true, "value": ["parameters": [65535, 65535, 0], "type": "standard"]],
            "64": ["enabled": true, "value": ["parameters": [32, kVK_Space, 1_048_576], "type": "standard"]],
        ]
        let keys = KeystrokeFilter.systemScreenshotKeys(symbolicHotKeys: hotKeys)
        func takes(_ code: Int, _ modifiers: KeyModifiers) -> Bool {
            KeystrokeFilter.isScreenshotShortcut(press(code, modifiers), system: keys)
        }
        #expect(!takes(kVK_ANSI_3, [.shift, .command]), "Turned off")
        #expect(takes(kVK_ANSI_3, [.control, .shift, .command]), "Not listed: its default")
        #expect(takes(kVK_ANSI_4, [.option, .shift]), "Moved to ⌥⇧4")
        #expect(!takes(kVK_ANSI_4, [.shift, .command]), "No longer ⇧⌘4")
        #expect(!takes(kVK_ANSI_4, [.control, .shift, .command]), "Set to no key")
        #expect(takes(kVK_ANSI_5, [.shift, .command]))
        #expect(takes(kVK_ANSI_6, [.shift, .command]), "The Touch Bar's")
        #expect(!takes(kVK_Space, [.command]), "Spotlight isn't a screenshot")
        #expect(KeystrokeFilter.systemScreenshotKeys(symbolicHotKeys: nil).count == 7, "Every default when unreadable")
    }

    @Test("The display reads macOS's screenshot shortcuts through its seam, and Screenshot Tools' only while they're registered")
    func displayScreenshotSources() throws {
        let harness = DisplayHarness()
        let display = harness.display
        var reads = 0
        display.symbolicHotKeys = {
            reads += 1
            return ["28": ["enabled": false, "value": ["parameters": [51, kVK_ANSI_3, 1_179_648], "type": "standard"]]]
        }
        var registered: [ShortcutBinding] = []
        display.keybumpsScreenshotBindings = { registered }
        display.acquire(.keystrokes, configuration: KeyDisplayConfiguration())
        #expect(reads == 1, "Read when the display starts")

        harness.keys.press(press(kVK_ANSI_3, [.shift, .command]))
        #expect(!display.isPausedForScreenshot, "The person turned ⇧⌘3 off")
        #expect(harness.presenter.last?.entries.map(\.text) == ["⇧⌘3"])
        harness.keys.press(press(kVK_ANSI_2, [.shift, .command]))
        #expect(!display.isPausedForScreenshot, "Screenshot Tools isn't registered")

        registered = [DefaultShortcut.screenshotScreen]
        harness.keys.press(press(kVK_ANSI_2, [.shift, .command]))
        #expect(display.isPausedForScreenshot)

        harness.clock.now += KeyDisplay.screenshotKeysLifetime
        harness.keys.press(press(kVK_ANSI_C, [.command]))
        #expect(reads == 2, "Read again once the last read is old")
    }

    @Test("Screenshot Tools' ⇧⌘2 clears the display only while Screenshot Tools is on; with it off, ⇧⌘2 shows")
    func screenshotToolsOffShows() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsKeystrokesScreenshotOff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let press = KeyPress(keyCode: UInt16(kVK_ANSI_2), modifiers: [.shift, .command])

        let off = WiringHarness(enabled: [.keystrokes], missing: nil, root: root)
        off.model.start()
        off.model.keyDisplay.receive(press)
        #expect(!off.model.keyDisplay.isPausedForScreenshot)
        #expect(off.model.keyDisplay.timeline.entries.count == 1, "Shown, as Xcode's Devices and Simulators")

        let on = WiringHarness(enabled: [.keystrokes, .screenshotTools, .clipboardHistory], missing: nil, root: root)
        on.model.start()
        on.model.keyDisplay.receive(press)
        #expect(on.model.keyDisplay.isPausedForScreenshot)
        #expect(on.model.keyDisplay.timeline.entries.isEmpty)
    }

    @Test("Screenshot Tools' hotkey clears the display before it captures, in case the tap never hears the hotkey")
    func screenshotToolsPausesTheDisplay() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsKeystrokesScreenshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = WatchingCaptureRunner()
        let capturer = ScreenshotCapturer(runner: runner, folder: { root }, displayCount: { 1 })
        let harness = WiringHarness(
            enabled: [.keystrokes, .screenshotTools, .clipboardHistory], missing: nil, root: root, screenshotCapturer: capturer
        )
        harness.model.start()
        var pausedWhenCapturing: [Bool] = []
        runner.onRun = { pausedWhenCapturing.append(harness.model.keyDisplay.isPausedForScreenshot) }

        // The tap hears nothing here: only the hotkey's own handler can clear the display.
        harness.pressHotKey(DefaultShortcut.screenshotScreen)
        #expect(pausedWhenCapturing == [true], "Cleared before screencapture would run")
    }

    @Test("The pointer tap runs only while clicks show, and a click becomes a ring in AppKit's coordinates")
    func clicks() throws {
        let harness = DisplayHarness()
        let display = harness.display
        display.mainDisplayHeight = { 1000 }
        display.acquire(.keystrokes, configuration: KeyDisplayConfiguration())
        #expect(!harness.pointer.isRunning)

        var withClicks = KeyDisplayConfiguration()
        withClicks.showsClicks = true
        display.acquire(.keystrokes, configuration: withClicks)
        #expect(harness.pointer.isRunning)
        harness.pointer.send(.down, at: CGPoint(x: 100, y: 300))
        harness.pointer.send(.up, at: CGPoint(x: 100, y: 300))
        let click = try #require(harness.presenter.last?.clicks.first)
        #expect(click.location == CGPoint(x: 100, y: 700))
        #expect(harness.presenter.last?.clicks.count == 1, "A press, not its release")

        display.acquire(.keystrokes, configuration: KeyDisplayConfiguration())
        #expect(!harness.pointer.isRunning)
        #expect(harness.presenter.last?.clicks.isEmpty == true)
    }

    @Test("A keyboard tap macOS refused starts once permissions are read again")
    func refusedTapRetries() {
        let harness = DisplayHarness()
        harness.keys.refuses = true
        harness.display.acquire(.keystrokes, configuration: KeyDisplayConfiguration())
        #expect(!harness.display.isListening)
        harness.display.permissionsDidRefresh()
        #expect(!harness.display.isListening)

        harness.keys.refuses = false
        harness.display.permissionsDidRefresh()
        #expect(harness.display.isListening)
        #expect(harness.keys.isRunning)

        harness.display.release(.keystrokes)
        harness.display.permissionsDidRefresh()
        #expect(!harness.keys.isRunning, "Nobody holds it")
    }

    // MARK: The plugin

    @Test("The plugin's settings, stored under its name, become its display's configuration")
    func pluginConfiguration() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.keystrokesConfiguration == KeyDisplayConfiguration(), "Keycaps, bottom center, shortcuts only, names, medium, 1.5 s, no clicks")

        preferences.set(.choice("bezel"), of: .keystrokesStyle, for: .keystrokes)
        preferences.set(.choice("bottomRight"), of: .keystrokesPosition, for: .keystrokes)
        preferences.set(.choice("large"), of: .keystrokesSize, for: .keystrokes)
        preferences.set(.choice("3"), of: .keystrokesDuration, for: .keystrokes)
        preferences.set(.choice("all"), of: .keystrokesKeys, for: .keystrokes)
        preferences.set(.bool(false), of: .keystrokesNamesActions, for: .keystrokes)
        preferences.set(.bool(true), of: .keystrokesShowsClicks, for: .keystrokes)
        #expect(defaults.string(forKey: "plugin.keystrokes.keys") == "all")
        #expect(AppPreferences(defaults: defaults).keystrokesConfiguration == KeyDisplayConfiguration(
            style: .bezel, position: .bottomRight, keys: .allKeys, namesActions: false, size: .large, linger: 3, showsClicks: true
        ))
    }

    @Test("The plugin holds the display while it's on, and Show & Hide Keystrokes lets go and takes it back")
    func pluginHoldsTheDisplay() {
        let harness = DisplayHarness()
        let notices = RecordingNotices()
        let module = KeystrokesModule(display: harness.display, notices: notices)
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.set(.choice("bezel"), of: .keystrokesStyle, for: .keystrokes)

        module.apply(harness.context(enabled: [.keystrokes], preferences: preferences))
        #expect(harness.display.holds(.keystrokes))
        #expect(harness.display.configuration?.style == .bezel)

        module.toggleHidden(preferences: preferences)
        #expect(!harness.display.holds(.keystrokes))
        module.apply(harness.context(enabled: [.keystrokes], preferences: preferences))
        #expect(!harness.display.holds(.keystrokes), "Hidden until the shortcut shows it again")
        module.toggleHidden(preferences: preferences)
        #expect(harness.display.holds(.keystrokes))
        #expect(notices.messages == ["Keystrokes hidden", "Showing keystrokes"])

        module.toggleHidden(preferences: preferences)
        module.deactivate(harness.context(enabled: [.keystrokes], preferences: preferences))
        module.apply(harness.context(enabled: [.keystrokes], preferences: preferences))
        #expect(harness.display.holds(.keystrokes), "Turning it off and on shows the keys again")

        module.apply(harness.context(enabled: [], preferences: preferences))
        #expect(!harness.display.holds(.keystrokes))
    }

    @Test("The app's display follows the plugin's switch and settings, and missing Input Monitoring is its page's attention")
    func pluginInTheApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsKeystrokes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [.keystrokes], missing: .inputMonitoring, root: root)
        let model = harness.model
        model.start()
        #expect(model.keyDisplay.holds(.keystrokes))
        #expect(model.keyDisplay.overlayWindows.isEmpty, "Nothing is drawn under the unit-test host")
        #expect(model.settingsAttentionCount(for: .keystrokes) == 1)
        #expect(model.missingPermissions(for: .keystrokes) == [.inputMonitoring])

        model.setPluginPreference(.keystrokesKeys, to: .choice("all"), for: .keystrokes)
        #expect(model.keyDisplay.configuration?.keys == .allKeys)

        model.setCapability(.keystrokes, enabled: false)
        #expect(!model.keyDisplay.isShowing)
        #expect(model.settingsAttentionCount(for: .keystrokes) == 0)
    }

    @Test("Keystrokes ships off, needs Input Monitoring, has no tab, and its shortcut starts unassigned")
    func manifest() {
        let descriptor = CapabilityDescriptor.keystrokes
        #expect(!descriptor.isOnByDefault)
        #expect(descriptor.minimumMacOS == nil)
        #expect(descriptor.paletteTab == nil)
        #expect(descriptor.requiredPermissions == [.inputMonitoring])
        #expect(descriptor.shortcuts == [.keystrokes])
        #expect(CapabilityShortcut.keystrokes.defaultBinding == nil)
        #expect(CapabilityShortcut.keystrokes.title == "Show & Hide Keystrokes")
        #expect(descriptor.preferences.map { $0.storageKey(for: .keystrokes) } == [
            "plugin.keystrokes.style", "plugin.keystrokes.position", "plugin.keystrokes.size", "plugin.keystrokes.duration",
            "plugin.keystrokes.keys", "plugin.keystrokes.namesActions", "plugin.keystrokes.showsClicks",
        ])
        let otherIcons = CapabilityCatalog.descriptors.filter { $0.capability != .keystrokes }.map(\.systemImage)
        #expect(!otherIcons.contains(descriptor.systemImage))
        #expect(MacPermission.inputMonitoring.explanation.contains("Keystrokes"))
    }

    // MARK: Helpers

    private func press(_ code: Int, _ modifiers: KeyModifiers) -> KeyPress {
        KeyPress(keyCode: UInt16(code), modifiers: modifiers)
    }

    private func name(_ code: Int, _ modifiers: KeyModifiers) -> Keystroke? {
        KeystrokeNaming.keystroke(for: press(code, modifiers), layout: FixedKeyboardLayout())
    }
}

/// The overlay windows themselves, on made-up screens. The windows are real but stay invisible and
/// click-through under the unit-test host (`hideDuringUnitTests`); the fade's wait is a manual
/// wake-up.
@MainActor
@Suite("Key display overlay")
struct KeyDisplayOverlayControllerTests {
    final class Screens { var list: [KeyDisplayScreen] = [] }

    static func screen(_ display: CGDirectDisplayID, x: CGFloat) -> KeyDisplayScreen {
        KeyDisplayScreen(
            display: display,
            frame: CGRect(x: x, y: 0, width: 200, height: 120),
            visibleFrame: CGRect(x: x, y: 20, width: 200, height: 90)
        )
    }

    static func content(lines: Int = 0, pointer: CGDirectDisplayID? = 1, displays: Set<CGDirectDisplayID>? = nil, keepsWindows: Bool = false) -> KeyDisplayContent {
        var configuration = KeyDisplayConfiguration()
        configuration.displays = displays
        let entries = (0..<lines).map { KeystrokeTimeline.Entry(id: $0, keycaps: ["⌘", "C"], text: "⌘C", isTyping: false, lastPress: Date()) }
        return KeyDisplayContent(configuration: configuration, entries: entries, clicks: [], pointerDisplay: pointer, keepsWindowsOnScreen: keepsWindows)
    }

    @MainActor
    final class Harness {
        let screens = Screens()
        let scheduler = KeyDisplayManualScheduler()
        let notifications = KeyDisplayNotificationCenter()
        let controller: KeyDisplayOverlayController
        var changes = 0

        init(_ screens: [KeyDisplayScreen]) {
            self.screens.list = screens
            let provider = self.screens
            controller = KeyDisplayOverlayController(
                screens: { provider.list },
                scheduler: scheduler,
                notificationCenter: notifications,
                reduceMotion: { false }
            )
            controller.onWindowsChange = { [unowned self] in self.changes += 1 }
        }
    }

    @Test("With only the plugin, no window is up until there's something to show, then one on the pointer's screen until it fades")
    func windowsComeAndGo() throws {
        let harness = Harness([Self.screen(1, x: 0), Self.screen(2, x: 200)])
        let controller = harness.controller
        defer { controller.hide() }

        controller.show(Self.content(), animated: true)
        #expect(controller.windows.isEmpty, "Nothing to show")
        #expect(harness.changes == 0)

        controller.show(Self.content(lines: 1, pointer: 2), animated: true)
        let window = try #require(controller.windows.first)
        #expect(controller.windows.count == 1)
        #expect(window.frame == Self.screen(2, x: 200).frame, "The pointer's screen")
        #expect(window.isVisible)
        #expect(window.level == .statusBar)
        #expect(window.ignoresMouseEvents)
        #expect(!window.canBecomeKey)
        #expect(harness.changes == 1)

        controller.show(Self.content(), animated: true)
        #expect(controller.windows.count == 1, "Still up while the line fades")
        #expect(harness.scheduler.pending != nil)
        harness.scheduler.fire()
        #expect(controller.windows.isEmpty, "Taken down after the fade")
        #expect(!window.isVisible)
        #expect(harness.changes == 2)

        controller.show(Self.content(lines: 1, pointer: 2), animated: false)
        #expect(controller.windows.first === window, "The same window comes back")
        controller.show(Self.content(), animated: false)
        #expect(controller.windows.isEmpty, "Without animation, down at once")
        #expect(harness.scheduler.pending == nil)
    }

    @Test("A holder that keeps windows up gets one on each of its screens for the whole hold, the same one as screens change")
    func keptWindows() throws {
        let harness = Harness([Self.screen(1, x: 0), Self.screen(2, x: 200)])
        let controller = harness.controller
        defer { controller.hide() }

        controller.show(Self.content(displays: [1], keepsWindows: true), animated: true)
        let first = try #require(controller.windows.first)
        #expect(controller.windows.count == 1, "Only the recorded screen")
        #expect(first.frame == Self.screen(1, x: 0).frame)

        controller.show(Self.content(lines: 1, displays: [1], keepsWindows: true), animated: true)
        controller.show(Self.content(displays: [1], keepsWindows: true), animated: true)
        #expect(harness.scheduler.pending == nil, "Never taken down while kept")

        harness.screens.list = [Self.screen(1, x: 50), Self.screen(2, x: 250)]
        controller.screensDidChange()
        #expect(controller.windows.first === first, "A screen that stays keeps its window, and its number")
        #expect(first.frame == Self.screen(1, x: 50).frame, "Moved with its screen")

        controller.show(Self.content(keepsWindows: true), animated: true)
        #expect(controller.windows.count == 2, "Every screen when none is named")
        let changes = harness.changes
        harness.screens.list = [Self.screen(1, x: 50)]
        controller.screensDidChange()
        #expect(controller.windows.map(ObjectIdentifier.init) == [ObjectIdentifier(first)], "A screen that's gone loses its window")
        #expect(harness.changes == changes + 1)
        harness.screens.list = [Self.screen(1, x: 50), Self.screen(3, x: 250)]
        controller.screensDidChange()
        #expect(controller.windows.count == 2, "A screen that's added gets one")
        #expect(harness.changes == changes + 2)
    }

    @Test("Show and hide work with no screens; the screen observer is added once and removed by hide, after which nothing comes back")
    func screenObserver() {
        let harness = Harness([])
        let controller = harness.controller
        controller.show(Self.content(lines: 1), animated: true)
        controller.show(Self.content(lines: 1), animated: true)
        #expect(controller.windows.isEmpty)
        #expect(harness.notifications.added == 1)
        #expect(controller.isWatchingScreens)

        controller.hide()
        #expect(harness.notifications.removed == 1)
        #expect(!controller.isWatchingScreens)

        harness.screens.list = [Self.screen(1, x: 0)]
        harness.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        controller.screensDidChange()
        #expect(controller.windows.isEmpty, "No windows while nobody holds the display")
        #expect(harness.changes == 0)
    }

    @Test("Hiding takes every window down and says so")
    func hideClosesWindows() throws {
        let harness = Harness([Self.screen(1, x: 0)])
        let controller = harness.controller
        controller.show(Self.content(keepsWindows: true), animated: true)
        let window = try #require(controller.windows.first)
        controller.hide()
        #expect(controller.windows.isEmpty)
        #expect(!window.isVisible)
        #expect(harness.changes == 2)
    }
}

/// Counts the observers added and removed.
final class KeyDisplayNotificationCenter: NotificationCenter, @unchecked Sendable {
    private(set) var added = 0
    private(set) var removed = 0

    override func addObserver(
        forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        added += 1
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }

    override func removeObserver(_ observer: Any) {
        removed += 1
        super.removeObserver(observer)
    }
}

/// A US layout's letters, digits, and a few symbols, plus keys a test changes.
@MainActor
private final class FixedKeyboardLayout: KeyboardLayoutTranslating {
    private static let us: [Int: (String, String)] = [
        kVK_ANSI_A: ("a", "A"), kVK_ANSI_C: ("c", "C"), kVK_ANSI_H: ("h", "H"), kVK_ANSI_K: ("k", "K"),
        kVK_ANSI_R: ("r", "R"), kVK_ANSI_S: ("s", "S"), kVK_ANSI_V: ("v", "V"), kVK_ANSI_Z: ("z", "Z"),
        kVK_ANSI_L: ("l", "L"), kVK_ANSI_P: ("p", "P"), kVK_ANSI_5: ("5", "%"), kVK_ANSI_2: ("2", "@"), kVK_ANSI_3: ("3", "#"),
        kVK_ANSI_4: ("4", "$"), kVK_ANSI_Slash: ("/", "?"), kVK_ANSI_Minus: ("-", "_"),
    ]
    /// US ⌥ characters.
    private static let usOption: [Int: String] = [kVK_ANSI_A: "å", kVK_ANSI_C: "ç", kVK_ANSI_L: "¬", kVK_ANSI_5: "∞", kVK_ANSI_Z: "Ω"]
    private let plain: [Int: String]
    private let command: [Int: String]
    private let option: [Int: String]

    init(plain: [Int: String] = [:], command: [Int: String] = [:], option: [Int: String] = [:]) {
        self.plain = plain
        self.command = command
        self.option = option
    }

    func character(for keyCode: UInt16, with modifiers: KeyModifiers) -> String? {
        let code = Int(keyCode)
        if modifiers.contains(.command), let character = command[code] { return character }
        if modifiers.contains(.option) { return option[code] ?? Self.usOption[code] }
        if let character = plain[code] { return modifiers.contains(.shift) ? character.uppercased() : character }
        guard let (lower, upper) = Self.us[code] else { return nil }
        let capsLock = modifiers.contains(.capsLock) && lower.first?.isLetter == true
        return modifiers.contains(.shift) || capsLock ? upper : lower
    }
}

/// A display built on fakes, with a clock and wake-ups the test moves itself.
@MainActor
private final class DisplayHarness {
    final class Clock { var now = Date(timeIntervalSinceReferenceDate: 1000) }
    final class SecureInput { var isOn = false }

    let keys = FakeKeyPresses()
    let pointer = FakePointer()
    let presenter = RecordingPresenter()
    let scheduler = KeyDisplayManualScheduler()
    let clock = Clock()
    let secureInput = SecureInput()
    let display: KeyDisplay
    private let shortcuts = GlobalShortcutCoordinator(backend: QuietHotKeys())

    init(layout: FixedKeyboardLayout? = nil) {
        let clock = clock
        let secureInput = secureInput
        display = KeyDisplay(
            keys: keys,
            pointer: pointer,
            presenter: presenter,
            layout: layout ?? FixedKeyboardLayout(),
            now: { clock.now },
            scheduler: scheduler,
            secureInput: { secureInput.isOn }
        )
    }

    func context(enabled: Set<Capability>, preferences: AppPreferences) -> CapabilityContext {
        CapabilityContext(
            enabledCapabilities: enabled,
            preferences: preferences,
            shortcuts: shortcuts,
            permissions: PermissionCoordinator(
                accessibilityTrusted: { true },
                inputMonitoringAuthorized: { true },
                microphoneAuthorizationStatus: { .authorized },
                speechAuthorizationStatus: { .authorized },
                screenRecordingAuthorized: { true },
                requestScreenRecording: {},
                openSettings: { _ in }
            ),
            permissionReadiness: { _ in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: [], states: [:], permissionsRequiringRelaunch: [])
            }
        )
    }
}

private final class FakeKeyPresses: KeyPressMonitoring {
    var onPress: ((KeyPress) -> Void)?
    /// Refuses to start, as macOS does without Input Monitoring.
    var refuses = false
    private(set) var isRunning = false
    private(set) var starts = 0

    func start() -> Bool {
        starts += 1
        isRunning = !refuses
        return isRunning
    }

    func stop() { isRunning = false }
    func press(_ press: KeyPress) { onPress?(press) }
}

private final class FakePointer: PointerEventMonitoring {
    var onSample: ((PointerSample) -> Void)?
    var onTapRecovered: (() -> Void)?
    private(set) var isRunning = false

    func start() -> Bool {
        isRunning = true
        return true
    }

    func stop() { isRunning = false }

    func send(_ phase: PointerSample.Phase, at location: CGPoint) {
        onSample?(PointerSample(phase: phase, location: location, modifiers: [], timestamp: 0))
    }
}

/// Records what it's asked to show, with or without animation. Like the real one, it keeps a
/// window up while a holder asks; those are windows the Window Server makes (so they have window
/// numbers) but never puts on screen.
@MainActor
private final class RecordingPresenter: KeyDisplayPresenting {
    private(set) var windows: [NSWindow] = []
    var onWindowsChange: (() -> Void)?
    private(set) var shown: [KeyDisplayContent] = []
    private(set) var animations: [Bool] = []
    private(set) var hides = 0
    var last: KeyDisplayContent? { shown.last }

    func show(_ content: KeyDisplayContent, animated: Bool) {
        if content.keepsWindowsOnScreen, windows.isEmpty {
            windows = [Self.window()]
            onWindowsChange?()
        }
        shown.append(content)
        animations.append(animated)
    }

    func hide() {
        hides += 1
        guard !windows.isEmpty else { return }
        windows = []
        onWindowsChange?()
    }

    /// A display was connected.
    func addDisplay() {
        windows.append(Self.window())
        onWindowsChange?()
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

/// Keeps the wake-ups asked for: the display's, which a test runs by calling `expire()`, and the
/// overlay's, which it runs with `fire()`.
@MainActor
final class KeyDisplayManualScheduler: TimerScheduling {
    final class Wake: TimerScheduledAction {
        let date: Date
        let action: @MainActor () -> Void
        private(set) var isCancelled = false
        init(date: Date, action: @escaping @MainActor () -> Void) {
            self.date = date
            self.action = action
        }
        func cancel() { isCancelled = true }
    }

    private(set) var wakes: [Wake] = []
    /// The wake-up still to come, if any.
    var pending: Wake? { wakes.last.flatMap { $0.isCancelled ? nil : $0 } }

    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledAction {
        let wake = Wake(date: date, action: action)
        wakes.append(wake)
        return wake
    }

    /// Runs the wake-up still to come.
    func fire() {
        guard let wake = pending else { return }
        wake.cancel()
        wake.action()
    }
}

@MainActor
private final class RecordingNotices: PaletteNoticePresenting {
    private(set) var messages: [String] = []
    func showNotice(_ message: String, isWarning: Bool) { messages.append(message) }
}

/// Notes each capture it's asked to run, and runs nothing.
private final class WatchingCaptureRunner: ScreenshotCaptureRunning {
    var onRun: () -> Void = {}
    func run(arguments: [String], completion: @escaping @MainActor () -> Void) { onRun() }
}

/// Refuses one binding, as macOS does when another app owns it.
@MainActor
private final class RefusingHotKeys: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    let refused: ShortcutBinding
    init(refused: ShortcutBinding) { self.refused = refused }
    func installHandler(_ handler: @escaping (UInt32) -> Void) {}
    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool { !binding.usesSameKeys(as: refused) }
    func unregister(identifier: UInt32) {}
}

@MainActor
private final class QuietHotKeys: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    func installHandler(_ handler: @escaping (UInt32) -> Void) {}
    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool { true }
    func unregister(identifier: UInt32) {}
}
