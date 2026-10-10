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
        #expect(name(kVK_ANSI_A, [.option])?.text == "⌥A", "⌥ alone is a shortcut, shown by its key rather than the å it types")
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

    @Test("Shortcuts only shows presses with ⌘, ⌃, or ⌥, never plain typing or ⇧ alone; All keys shows both")
    func shortcutsOnly() {
        for modifiers: KeyModifiers in [[.command], [.control], [.option], [.option, .shift]] {
            #expect(KeystrokeFilter.shows(press(kVK_ANSI_A, modifiers), keys: .shortcutsOnly, secureInput: false), "\(modifiers)")
        }
        for modifiers: KeyModifiers in [[], [.shift], [.capsLock]] {
            #expect(!KeystrokeFilter.shows(press(kVK_ANSI_A, modifiers), keys: .shortcutsOnly, secureInput: false), "\(modifiers)")
            #expect(KeystrokeFilter.shows(press(kVK_ANSI_A, modifiers), keys: .allKeys, secureInput: false), "\(modifiers)")
        }
    }

    @Test("Nothing shows while secure input is on, or that Keybumps posted itself, whatever Show says")
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
        #expect(display.overlayWindows.count == 1, "Up before the first key, so a recording can add it")
        #expect(display.overlayWindowIDs.count == 1)
        #expect(display.overlayWindowIDs.map(Int.init) == display.overlayWindows.map(\.windowNumber), "As SCWindow.windowID")

        display.acquire(Self.recording, configuration: KeyDisplayConfiguration())
        #expect(harness.keys.starts == 1, "One display, one tap")
        #expect(harness.presenter.windowSets == 1, "The recording reuses the plugin's windows")

        display.release(.keystrokes)
        #expect(display.isShowing, "The recording still holds it")
        #expect(harness.keys.isRunning)
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
        display.acquire(Self.recording, configuration: KeyDisplayConfiguration()) { heard.append($0) }
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
        display.acquire(.keystrokes, configuration: KeyDisplayConfiguration())

        harness.keys.press(press(kVK_ANSI_C, [.command]))
        harness.keys.press(press(kVK_Space, [.command]))
        harness.keys.press(press(kVK_ANSI_H, []))
        let content = try #require(harness.presenter.last)
        #expect(content.entries.map(\.text) == ["⌘C", "⌘Space"], "Shortcuts only by default")
        #expect(content.entries.map(\.name) == ["Copy", "Open Quick Search"])
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

/// A US layout's letters, digits, and a few symbols, plus keys a test changes.
@MainActor
private final class FixedKeyboardLayout: KeyboardLayoutTranslating {
    private static let us: [Int: (String, String)] = [
        kVK_ANSI_A: ("a", "A"), kVK_ANSI_C: ("c", "C"), kVK_ANSI_H: ("h", "H"), kVK_ANSI_K: ("k", "K"),
        kVK_ANSI_R: ("r", "R"), kVK_ANSI_S: ("s", "S"), kVK_ANSI_V: ("v", "V"), kVK_ANSI_Z: ("z", "Z"),
        kVK_ANSI_4: ("4", "$"), kVK_ANSI_Slash: ("/", "?"), kVK_ANSI_Minus: ("-", "_"),
    ]
    private let plain: [Int: String]
    private let command: [Int: String]

    init(plain: [Int: String] = [:], command: [Int: String] = [:]) {
        self.plain = plain
        self.command = command
    }

    func character(for keyCode: UInt16, with modifiers: KeyModifiers) -> String? {
        let code = Int(keyCode)
        if modifiers.contains(.command), let character = command[code] { return character }
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
    let scheduler = ManualScheduler()
    let clock = Clock()
    let secureInput = SecureInput()
    let display: KeyDisplay
    private let shortcuts = GlobalShortcutCoordinator(backend: QuietHotKeys())

    init() {
        let clock = clock
        let secureInput = secureInput
        display = KeyDisplay(
            keys: keys,
            pointer: pointer,
            presenter: presenter,
            layout: FixedKeyboardLayout(),
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

/// Records what it's asked to show, with windows the Window Server makes (so they have window
/// numbers) but never puts on screen.
@MainActor
private final class RecordingPresenter: KeyDisplayPresenting {
    private(set) var windows: [NSWindow] = []
    var onWindowsChange: (() -> Void)?
    private(set) var shown: [KeyDisplayContent] = []
    private(set) var hides = 0
    /// How many times it put windows up from none.
    private(set) var windowSets = 0
    var last: KeyDisplayContent? { shown.last }

    func show(_ content: KeyDisplayContent) {
        if windows.isEmpty {
            windows = [Self.window()]
            windowSets += 1
            onWindowsChange?()
        }
        shown.append(content)
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

/// Keeps the wake-ups the display asks for, which the test fires by calling `expire()`.
@MainActor
private final class ManualScheduler: TimerScheduling {
    final class Wake: TimerScheduledAction {
        let date: Date
        private(set) var isCancelled = false
        init(date: Date) { self.date = date }
        func cancel() { isCancelled = true }
    }

    private(set) var wakes: [Wake] = []
    /// The wake-up still to come, if any.
    var pending: Wake? { wakes.last.flatMap { $0.isCancelled ? nil : $0 } }

    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledAction {
        let wake = Wake(date: date)
        wakes.append(wake)
        return wake
    }
}

@MainActor
private final class RecordingNotices: PaletteNoticePresenting {
    private(set) var messages: [String] = []
    func showNotice(_ message: String, isWarning: Bool) { messages.append(message) }
}

@MainActor
private final class QuietHotKeys: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    func installHandler(_ handler: @escaping (UInt32) -> Void) {}
    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool { true }
    func unregister(identifier: UInt32) {}
}
