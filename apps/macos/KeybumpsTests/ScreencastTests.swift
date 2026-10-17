import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import Keybumps

/// ScreenGrabs' recording (ADR 0009, ADR 0010), which was the Screencast plugin (#445): its part of
/// ScreenGrabs' manifest, its preferences and where they're stored, the macOS 15 gate
/// (`PluginCompatibility.supportsRecording`), and Record Screen, which opens the picker (#447) and
/// has ⇧⌘5. Nothing here records, reads the screen, asks for a permission, or opens Settings or
/// Finder.
@MainActor
@Suite("ScreenGrabs: recording")
struct ScreencastTests {
    static let macOS14 = PluginCompatibility(macOSMajorVersion: 14)
    static let macOS15 = PluginCompatibility(macOSMajorVersion: 15)

    static let recordScreen = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(controlKey | optionKey | shiftKey),
        displayName: "⌃⌥⇧R"
    )

    @Test("Recording is part of ScreenGrabs, which ships on with no minimum macOS: its shortcuts, its action, and its page")
    func manifest() throws {
        let descriptor = CapabilityDescriptor.screenshotTools
        #expect(descriptor.title == "ScreenGrabs")
        #expect(descriptor.category == .media)
        #expect(descriptor.isOnByDefault)
        #expect(descriptor.minimumMacOS == nil, "Recording needs macOS 15 inside the plugin (supportsRecording)")
        #expect(descriptor.dependencies == [.clipboardHistory], "for screenshots")
        #expect(descriptor.settingsPage?.section == .screenshotTools)
        #expect(CapabilityCatalog.defaultCapabilities.contains(.screenshotTools))
        #expect(Capability(rawValue: "screencast") == nil, "Retired (ADR 0010)")
        #expect(descriptor.shortcuts == [
            .screenshotScreen, .screenshotScreenAndEdit, .screenshotArea,
            .screencast, .screencastPause, .screencastStop, .screencastDiscard, .screencastDraw,
        ])
        #expect(descriptor.actions == [.startScreencast])
        #expect(PluginSettingsPage<EmptyView, EmptyView, EmptyView>.byline(descriptor) == "Official plugin by Keybumps · Media")
    }

    @Test("It needs Screen Recording, and can use Accessibility, the Microphone, and Input Monitoring, each with its own reason; Screen Recording and the Microphone name it on the Permissions page")
    func permissions() throws {
        let descriptor = CapabilityDescriptor.screenshotTools
        #expect(descriptor.requiredPermissions == [.screenRecording])
        #expect(MacPermission.screenRecording.explanation.contains("ScreenGrabs"))
        #expect(descriptor.optionalPermissions.map(\.permission) == [.accessibility, .microphone, .inputMonitoring])
        let reasons = descriptor.optionalPermissions.map(\.reason)
        #expect(reasons[1].contains("voice") && reasons[2].contains("shortcuts"))
        #expect(MacPermission.microphone.explanation.contains("ScreenGrabs"), "Settings › Permissions names it (#490)")
        #expect(!MacPermission.inputMonitoring.explanation.contains("ScreenGrabs"), "Optional: its reason is its own")
        #expect(PermissionSetupPlan.requiredPermissions(for: [.screenshotTools]) == [.screenRecording])
    }

    @Test("Quick Search finds ScreenGrabs by both plugins' words, and Record Screen by Screencast's")
    func command() {
        let command = QuickSearchCommand.capability(.screenshotTools)
        #expect(command.match("screengrabs") == .name)
        for word in ["screenshot", "screen recording", "record", "screencast"] {
            #expect(command.match(word) == .keyword, "\(word)")
        }
        #expect(PluginAction.startScreencast.id == "startScreencast", "It keys learned usage")
        #expect(PluginAction.startScreencast.title == "Record Screen")
        #expect(PluginAction.startScreencast.keywords.contains("screencast"))
    }

    @Test(
        "Quick Search, Settings' sidebar, and the Plugins page find ScreenGrabs however its name is typed (#512)",
        arguments: [
            ("ScreenGrabs", QuickSearchCommand.Match.name),
            ("screengrabs", .name),
            ("screengrab", .keyword),
            ("screen grabs", .keyword),
        ]
    )
    func findsItByName(query: String, match: QuickSearchCommand.Match) {
        #expect(CapabilityDescriptor.screenshotTools.title == "ScreenGrabs")
        #expect(QuickSearchCommand.capability(.screenshotTools).match(query) == match)
        let sidebar = SettingsSidebar.groups(matching: query)
        #expect(sidebar == [[.screenshotTools]])
        let plugins = PluginsTable.sections(matching: query).map(\.plugins)
        #expect(plugins == [[.screenshotTools]])
    }

    // MARK: Preferences

    @Test("Its preferences start as the issue sets them: both sounds, shortcuts shown, no click rings, a 3-second countdown")
    func defaults() {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        #expect(preferences.screencast == ScreencastPreferences(
            recordsMicrophone: true,
            recordsSystemAudio: true,
            countdownSeconds: 3,
            showsShortcuts: true,
            highlightsClicks: false,
            capturesFolder: ProductPaths.keybumps().captures
        ))
    }

    @Test("ScreenGrabs' page lists them in one Recordings group")
    func groups() {
        let descriptor = CapabilityDescriptor.screenshotTools
        #expect(descriptor.preferenceGroups.map(\.title) == ["Recordings"])
        #expect(descriptor.preferenceGroups.map { $0.preferences.map(\.key) } == [
            ["recordsMicrophone", "recordsSystemAudio", "countdown", "showsShortcuts", "highlightsClicks"],
        ])
        guard case .choice(let options, _) = PluginPreference.screencastCountdown.kind else {
            Issue.record("The countdown is a menu")
            return
        }
        #expect(options.map(\.value) == ["0", "3", "5", "10"])
        #expect(options.map(\.title) == ["None", "3 seconds", "5 seconds", "10 seconds"])
    }

    @Test("ScreenGrabs reads and writes them at Screencast's keys, plugin.screencast.<key>, read back after a relaunch, and in the typed value")
    func storage() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        for preference in CapabilityDescriptor.screenshotTools.preferences {
            #expect(preference.storageKey(for: .screenshotTools) == "plugin.screencast.\(preference.key)")
        }
        preferences.set(.bool(false), of: .screencastRecordsMicrophone, for: .screenshotTools)
        preferences.set(.bool(false), of: .screencastRecordsSystemAudio, for: .screenshotTools)
        preferences.set(.bool(false), of: .screencastShowsShortcuts, for: .screenshotTools)
        preferences.set(.bool(true), of: .screencastHighlightsClicks, for: .screenshotTools)
        preferences.set(.choice("0"), of: .screencastCountdown, for: .screenshotTools)

        #expect(defaults.object(forKey: "plugin.screencast.recordsMicrophone") as? Bool == false)
        #expect(defaults.object(forKey: "plugin.screencast.recordsSystemAudio") as? Bool == false)
        #expect(defaults.object(forKey: "plugin.screencast.showsShortcuts") as? Bool == false)
        #expect(defaults.object(forKey: "plugin.screencast.highlightsClicks") as? Bool == true)
        #expect(defaults.object(forKey: "plugin.screencast.countdown") as? String == "0")
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("plugin.screenshotTools.") }.isEmpty)

        let relaunched = AppPreferences(defaults: defaults).screencast
        #expect(!relaunched.recordsMicrophone)
        #expect(!relaunched.recordsSystemAudio)
        #expect(!relaunched.showsShortcuts)
        #expect(relaunched.highlightsClicks)
        #expect(relaunched.countdownSeconds == 0)

        preferences.set(.choice("10"), of: .screencastCountdown, for: .screenshotTools)
        #expect(preferences.screencast.countdownSeconds == 10)
        preferences.set(.choice("4"), of: .screencastCountdown, for: .screenshotTools)
        #expect(preferences.screencast.countdownSeconds == 10, "Only one of its options")
    }

    @Test("What Screencast saved before the merge is read by ScreenGrabs, and the picker's switches land on the same keys")
    func readsWhatScreencastSaved() {
        let defaults = InMemoryDefaults()
        defaults.set(false, forKey: "plugin.screencast.recordsSystemAudio")
        defaults.set("5", forKey: "plugin.screencast.countdown")
        let preferences = AppPreferences(defaults: defaults)
        #expect(!preferences.bool(.screencastRecordsSystemAudio, for: .screenshotTools))
        #expect(preferences.screencast.countdownSeconds == 5)

        var switches = preferences.screencast.switches
        switches.highlightsClicks = true
        preferences.setScreencastSwitches(switches)
        #expect(defaults.object(forKey: "plugin.screencast.highlightsClicks") as? Bool == true)
        #expect(defaults.object(forKey: "plugin.screenshotTools.highlightsClicks") == nil)
    }

    @available(macOS 15, *)
    @Test("Record Screen counts down from the Countdown saved at plugin.screencast.countdown, read again at each open (#520)")
    func countdownFromSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsCountdownReread-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = InMemoryDefaults()
        defaults.set("5", forKey: "plugin.screencast.countdown")
        let harness = WiringHarness(enabled: [.clipboardHistory, .screenshotTools], missing: nil, root: root, defaults: defaults)
        let overlays = FakeOverlays()
        let sleeper = ManualSleeper()
        let preferences = harness.model.preferences
        let module = Self.moduleOnFakes(preferences: preferences, presenter: overlays, sleep: { try await sleeper.sleep($0) })

        module.start()
        let controller = try #require(module.controller)
        try await Self.waitUntil { overlays.picker != nil }
        overlays.record()
        #expect(controller.phase == .countingDown(remaining: 5))
        try await Self.waitUntil { sleeper.pending == 1 }
        #expect(overlays.countdowns == [5])
        overlays.cancelTheCountdown()
        #expect(controller.phase == .idle)

        // Settings › ScreenGrabs' menu, through its row's own selection.
        PluginPreferenceRow.selection(of: .screencastCountdown, for: .screenshotTools, in: harness.model).wrappedValue = "10"
        module.start()
        try await Self.waitUntil { overlays.picker != nil }
        overlays.record()
        #expect(controller.phase == .countingDown(remaining: 10))
        try await Self.waitUntil { sleeper.pending == 1 }
        #expect(overlays.countdowns == [5, 10])
        overlays.cancelTheCountdown()
    }

    @available(macOS 15, *)
    @Test("Settings › ScreenGrabs' Countdown menu, through its own selection, saves 3 seconds where the next recording reads it, from None as the candidate had it (#520)")
    func countdownFromTheSettingsMenu() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsCountdownMenu-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = InMemoryDefaults()
        defaults.set("0", forKey: "plugin.screencast.countdown")
        let harness = WiringHarness(enabled: [.clipboardHistory, .screenshotTools], missing: nil, root: root, defaults: defaults)
        let menu = PluginPreferenceRow.selection(of: .screencastCountdown, for: .screenshotTools, in: harness.model)
        #expect(menu.wrappedValue == "0", "None")

        menu.wrappedValue = "3"

        #expect(menu.wrappedValue == "3")
        #expect(defaults.object(forKey: "plugin.screencast.countdown") as? String == "3")
        #expect(defaults.object(forKey: "plugin.screenshotTools.countdown") == nil)
        #expect(harness.model.preferences.screencast.countdownSeconds == 3)

        // What the recorder gets: the module reads the same preferences as Record Screen opens.
        let overlays = FakeOverlays()
        let sleeper = ManualSleeper()
        let module = Self.moduleOnFakes(preferences: harness.model.preferences, presenter: overlays, sleep: { try await sleeper.sleep($0) })
        module.start()
        let controller = try #require(module.controller)
        try await Self.waitUntil { overlays.picker != nil }
        overlays.record()
        #expect(controller.phase == .countingDown(remaining: 3))
        try await Self.waitUntil { sleeper.pending == 1 }
        #expect(overlays.countdowns == [3])
        overlays.cancelTheCountdown()
    }

    @available(macOS 15, *)
    @Test("A countdown chosen in Settings stays through a recording whose picker changed a switch, the picker's memory, and a relaunch (#520)")
    func countdownStaysAfterRecordingAndRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsCountdownStays-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = InMemoryDefaults()
        let harness = WiringHarness(enabled: [.clipboardHistory, .screenshotTools], missing: nil, root: root, defaults: defaults)
        PluginPreferenceRow.selection(of: .screencastCountdown, for: .screenshotTools, in: harness.model).wrappedValue = "5"
        let preferences = harness.model.preferences

        // A recording: Highlight clicks turned on in the picker, Record, the whole countdown, then Discard.
        let overlays = FakeOverlays()
        let sleeper = ManualSleeper()
        let module = Self.moduleOnFakes(preferences: preferences, presenter: overlays, sleep: { try await sleeper.sleep($0) })
        module.start()
        let controller = try #require(module.controller)
        try await Self.waitUntil { overlays.picker != nil }
        let picker = try #require(overlays.picker)
        picker.highlightsClicks = true
        overlays.record()
        for _ in 0..<5 {
            try await Self.waitUntil { sleeper.pending == 1 }
            sleeper.advance()
        }
        try await Self.waitUntil { controller.phase == .recording }
        #expect(overlays.countdowns == [5, 4, 3, 2, 1])
        await controller.discard()
        try await Self.waitUntil { controller.phase == .idle }

        // Record saved the switch and the picker's choices, and left the countdown alone.
        #expect(defaults.object(forKey: "plugin.screencast.highlightsClicks") as? Bool == true)
        #expect(defaults.object(forKey: ScreencastPickerMemory.key) != nil)
        #expect(defaults.object(forKey: "plugin.screencast.countdown") as? String == "5")
        #expect(preferences.screencast.countdownSeconds == 5)

        // The next Record Screen, which opens on the remembered choices, counts down from 5 again.
        module.start()
        try await Self.waitUntil { overlays.picker != nil && controller.phase == .picking }
        overlays.record()
        #expect(controller.phase == .countingDown(remaining: 5))
        overlays.cancelTheCountdown()

        // A relaunch reads it back, and Settings' menu shows it.
        let relaunched = WiringHarness(enabled: [.clipboardHistory, .screenshotTools], missing: nil, root: root, defaults: defaults)
        #expect(relaunched.model.preferences.screencast.countdownSeconds == 5)
        #expect(PluginPreferenceRow.selection(of: .screencastCountdown, for: .screenshotTools, in: relaunched.model).wrappedValue == "5")
    }

    @Test("The review panel's retired \"Also add to Screenshots\" switch is removed on load, and the rest kept")
    func retiredAddsToScreenshots() {
        let defaults = InMemoryDefaults()
        defaults.set(false, forKey: "plugin.screencast.addsToScreenshots")
        defaults.set(false, forKey: "plugin.screencast.recordsMicrophone")

        let preferences = AppPreferences(defaults: defaults)

        #expect(defaults.object(forKey: "plugin.screencast.addsToScreenshots") == nil, "Only QA builds had it (#464, #485)")
        #expect(defaults.object(forKey: "plugin.screencast.recordsMicrophone") as? Bool == false)
        #expect(!preferences.screencast.recordsMicrophone)
    }

    @Test("Recordings go in Documents › Keybumps › captures, shown as Go to Folder takes it")
    func capturesFolder() {
        let paths = ProductPaths.make(productDirectoryName: "Keybumps", fileManager: .default, sandboxRoot: nil, unitTestRoot: nil)
        #expect(paths.captures == paths.recordings.deletingLastPathComponent().appendingPathComponent("captures", isDirectory: true))
        // Lexical only: nothing reads the owner's folders.
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let documents = home.appendingPathComponent("Documents/Keybumps/captures", isDirectory: true)
        #expect(ScreencastCapturesSettings.displayPath(documents) == "~/Documents/Keybumps/captures")
    }

    // MARK: The macOS 15 gate

    @Test("Recording needs macOS 15; ScreenGrabs itself turns on everywhere", arguments: [14, 15, 26])
    func supportsRecording(_ version: Int) {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: PluginCompatibility(macOSMajorVersion: version))
        #expect(preferences.compatibility.supportsRecording == (version >= 15))
        #expect(preferences.compatibility.supports(.screenshotTools))
        #expect(preferences.compatibility.requirement(for: .screenshotTools) == nil)
        #expect(preferences.enabledCapabilities.contains(.screenshotTools), "It ships on")
        #expect(PluginCompatibility.recordingRequirement == "Recording needs macOS 15")
    }

    @Test("On macOS 14, Quick Search doesn't offer Record Screen, and its shortcut rows say why")
    func macOS14HidesTheActionAndSaysWhy() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsRecording14-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = WiringHarness(enabled: [.screenshotTools], missing: nil, root: root, compatibility: Self.macOS14)
        old.model.start()
        #expect(!old.model.quickSearchActions.contains { $0.action == .startScreencast })
        let current = WiringHarness(enabled: [.screenshotTools], missing: nil, root: root, compatibility: Self.macOS15)
        current.model.start()
        #expect(current.model.quickSearchActions.contains { $0.action == .startScreencast })

        for shortcut in CapabilityDescriptor.screenshotTools.shortcuts {
            let old = shortcut.detail(on: Self.macOS14)
            let current = shortcut.detail(on: Self.macOS15)
            #expect(current == shortcut.detail, "\(shortcut)")
            #expect(old == (shortcut.needsRecording ? "Recording needs macOS 15" : shortcut.detail), "\(shortcut)")
        }
        #expect(CapabilityShortcut.allCases.filter(\.needsRecording) == [.screencast, .screencastPause, .screencastStop, .screencastDiscard, .screencastDraw])
    }

    // MARK: Record Screen

    @Test("Record Screen is ScreenGrabs', with ⇧⌘5 on new installs and on updates that didn't know it")
    func recordScreenShortcut() {
        #expect(CapabilityShortcut.screencast.rawValue == "screencast", "Stored bindings keep the raw value")
        #expect(CapabilityShortcut.screencast.title == "Record Screen")
        #expect(CapabilityShortcut.screencast.capability == .screenshotTools)
        #expect(CapabilityShortcut.screencast.defaultBinding == DefaultShortcut.recordScreen)
        #expect(DefaultShortcut.recordScreen.keyCode == UInt32(kVK_ANSI_5) && DefaultShortcut.recordScreen.modifiers == UInt32(cmdKey | shiftKey))
        #expect(CapabilityShortcut.screencast.worksEverywhere)
        #expect(!CapabilityShortcut.originalShortcuts.contains(.screencast))
        #expect(AppPreferences(defaults: InMemoryDefaults()).capabilityShortcut(for: .screencast) == DefaultShortcut.recordScreen)

        // beta.25 and earlier saved shortcuts without knowing Record Screen.
        let upgraded = InMemoryDefaults()
        upgraded.set(try? JSONEncoder().encode([String: ShortcutBinding]()), forKey: "capabilityShortcuts")
        upgraded.set(["quickSearch", "clipboardHistory", "dictation"], forKey: "knownCapabilityShortcuts")
        #expect(AppPreferences(defaults: upgraded).capabilityShortcut(for: .screencast) == DefaultShortcut.recordScreen)
        for shortcut in [CapabilityShortcut.screencastPause, .screencastStop, .screencastDiscard, .screencastDraw] {
            #expect(shortcut.capability == .screenshotTools)
            #expect(shortcut.detail?.hasPrefix("Only while recording") == true, "\(shortcut)")
            #expect(shortcut.defaultBinding == nil)
        }
    }

    /// Saved shortcuts as a development or QA build since #458 left them: Record Screen known, with
    /// no binding of its own.
    private static func knownWithoutRecordScreen(_ shortcuts: [String: ShortcutBinding], window: [String: ShortcutBinding]? = nil) -> InMemoryDefaults {
        let defaults = InMemoryDefaults()
        defaults.set(try? JSONEncoder().encode(shortcuts), forKey: "capabilityShortcuts")
        defaults.set(CapabilityShortcut.allCases.map(\.rawValue), forKey: "knownCapabilityShortcuts")
        if let window { defaults.set(try? JSONEncoder().encode(window), forKey: "windowShortcuts") }
        return defaults
    }

    @Test("Once, at launch, an install that knows Record Screen with no shortcut gets ⇧⌘5, and a shortcut cleared later stays clear")
    func oneTimeStepAssigns() {
        let defaults = Self.knownWithoutRecordScreen([:])
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.capabilityShortcut(for: .screencast) == DefaultShortcut.recordScreen)
        #expect(defaults.bool(forKey: "didGiveRecordScreenShortcut"))
        #expect(AppPreferences(defaults: defaults).capabilityShortcut(for: .screencast) == DefaultShortcut.recordScreen, "Saved")

        preferences.setCapabilityShortcut(nil, for: .screencast)
        #expect(AppPreferences(defaults: defaults).capabilityShortcut(for: .screencast) == nil, "It never runs twice")

        let new = InMemoryDefaults()
        #expect(AppPreferences(defaults: new).capabilityShortcut(for: .screencast) == DefaultShortcut.recordScreen)
        #expect(new.data(forKey: "capabilityShortcuts") == nil, "A new install already has it, so nothing is saved")
    }

    @Test("Record Screen with another shortcut gets ⇧⌘5 in its place, and a shortcut set later stays (#513)")
    func oneTimeStepReplaces() {
        let defaults = Self.knownWithoutRecordScreen(["screencast": Self.recordScreen])
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.capabilityShortcut(for: .screencast) == DefaultShortcut.recordScreen)
        let oldKeysFree = !preferences.capabilityShortcuts.values.contains { $0.usesSameKeys(as: Self.recordScreen) }
        #expect(oldKeysFree, "Its old shortcut is replaced, not moved")
        #expect(defaults.bool(forKey: "didGiveRecordScreenShortcut"))

        preferences.setCapabilityShortcut(Self.recordScreen, for: .screencast)
        let next = AppPreferences(defaults: defaults)
        #expect(next.capabilityShortcut(for: .screencast) == Self.recordScreen, "It never runs twice")
    }

    @Test("An install #490's step marked done gets ⇧⌘5 once, taken from macOS where recording works (#513)")
    func oneTimeStepRunsOnceAfterTheOldOne() {
        let defaults = Self.knownWithoutRecordScreen(["screencast": Self.recordScreen])
        defaults.set(true, forKey: "didOfferRecordScreenShortcut")
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.macOS15)
        #expect(preferences.capabilityShortcut(for: .screencast) == DefaultShortcut.recordScreen)
        let takeover = ScreenshotToolsModule.takeoverBindings(preferences)
        #expect(takeover.contains(DefaultShortcut.recordScreen), "So macOS's screenshot toolbar (184) is turned off")
        #expect(defaults.bool(forKey: "didOfferRecordScreenShortcut"), "The old key stays")
        #expect(defaults.bool(forKey: "didGiveRecordScreenShortcut"))

        preferences.setCapabilityShortcut(nil, for: .screencast)
        let next = AppPreferences(defaults: defaults, compatibility: Self.macOS15)
        #expect(next.capabilityShortcut(for: .screencast) == nil, "It never runs twice")
        #expect(!ScreenshotToolsModule.takeoverBindings(next).contains(DefaultShortcut.recordScreen))
    }

    @Test("The step leaves Record Screen alone when ⇧⌘5 is another Keybumps shortcut's, a plugin's or a window's")
    func oneTimeStepLeavesAlone() throws {
        let taken = ShortcutBinding(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey), displayName: "⇧⌘5")
        let byAPlugin = Self.knownWithoutRecordScreen(["timer": taken])
        let first = AppPreferences(defaults: byAPlugin)
        #expect(first.capabilityShortcut(for: .screencast) == nil)
        #expect(first.capabilityShortcut(for: .timer) == taken)

        let byAPluginWithOwn = Self.knownWithoutRecordScreen(["timer": taken, "screencast": Self.recordScreen])
        let second = AppPreferences(defaults: byAPluginWithOwn)
        #expect(second.capabilityShortcut(for: .screencast) == Self.recordScreen, "It keeps its own")
        #expect(second.capabilityShortcut(for: .timer) == taken)

        let window = WindowAction.allCases[0]
        let byAWindow = Self.knownWithoutRecordScreen([:], window: [window.rawValue: taken])
        let third = AppPreferences(defaults: byAWindow)
        #expect(third.capabilityShortcut(for: .screencast) == nil)
        #expect(third.windowShortcut(for: window) == taken)

        for defaults in [byAPlugin, byAPluginWithOwn, byAWindow] {
            #expect(defaults.bool(forKey: "didGiveRecordScreenShortcut"), "It ran, and won't run again")
        }
        first.setCapabilityShortcut(nil, for: .timer)
        #expect(AppPreferences(defaults: byAPlugin).capabilityShortcut(for: .screencast) == nil, "Freed later, ⇧⌘5 isn't taken")
    }

    @Test("Record Screen registers only while ScreenGrabs is on, where it can record")
    func shortcutRegistersWhileOn() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencast-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = CapabilityShortcut.screencast.ownerID

        func harness(enabled: Set<Capability>, on compatibility: PluginCompatibility) -> WiringHarness {
            let harness = WiringHarness(enabled: enabled, missing: nil, root: root, compatibility: compatibility)
            harness.model.preferences.setCapabilityShortcut(Self.recordScreen, for: .screencast)
            harness.model.start()
            return harness
        }

        let on = harness(enabled: [.screenshotTools], on: Self.macOS15)
        #expect(on.shortcuts()[owner] != nil)
        on.model.setCapability(.screenshotTools, enabled: false)
        #expect(on.shortcuts()[owner] == nil)

        let off = harness(enabled: [], on: Self.macOS15)
        #expect(off.shortcuts()[owner] == nil)

        let old = harness(enabled: [.screenshotTools], on: Self.macOS14)
        #expect(old.shortcuts()[owner] == nil, "Never before macOS 15, so macOS keeps ⇧⌘5")
        #expect(old.shortcuts()[CapabilityShortcut.screenshotArea.ownerID] != nil, "Screenshots work as today")
    }

    @Test("Record Screen opens ScreenGrabs' page while it's off")
    func startWhileOffOpensItsPage() {
        var opened: [SettingsSection] = []
        let module = ScreencastModule(
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            openSettings: { opened.append($0) }
        )
        module.start()
        #expect(opened == [.screenshotTools])
    }

    @available(macOS 15, *)
    @Test("Record Screen opens the picker with Screen Recording, and never reads the screen without it")
    func startOpensThePicker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencastStart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = WiringHarness(enabled: [.screenshotTools], missing: .screenRecording, root: root)
        missing.model.start()
        missing.model.startScreencast()
        #expect(Self.module(of: missing).controller == nil, "No picker, so macOS never asks")

        let granted = WiringHarness(enabled: [.screenshotTools], missing: nil, root: root)
        granted.model.start()
        granted.model.startScreencast()
        let controller = try #require(Self.module(of: granted).controller)
        #expect(controller.phase == .picking)
        #expect(controller.picker?.microphoneAvailable == true)
        controller.cancel()

        let noMicrophone = WiringHarness(enabled: [.screenshotTools], missing: .microphone, root: root)
        noMicrophone.model.start()
        noMicrophone.model.startScreencast()
        let picker = try #require(Self.module(of: noMicrophone).controller?.picker)
        #expect(!picker.microphoneAvailable && !picker.recordsMicrophone, "Its switch stays off; nothing asks for it")
    }

    @available(macOS 15, *)
    @Test("Turning ScreenGrabs off closes the picker")
    func turningOffCancels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencastOff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [.screenshotTools], missing: nil, root: root)
        harness.model.start()
        harness.model.startScreencast()
        let controller = try #require(Self.module(of: harness).controller)
        #expect(controller.phase == .picking)
        harness.model.setCapability(.screenshotTools, enabled: false)
        #expect(await ScreencastWait.until { controller.phase == .idle })
        #expect(controller.picker == nil)
        harness.model.startScreencast()
        #expect(controller.phase == .idle, "Off, Record Screen opens its page instead")
    }

    @available(macOS 15, *)
    @Test("A saved recording opens the recording window, off screen here; turning ScreenGrabs off closes it, which saves")
    func savedCaptureOpensTheReviewPanel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencastReview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [.screenshotTools], missing: nil, root: root)
        harness.model.start()
        let module = Self.module(of: harness)
        let capture = try Self.recording(in: root.appendingPathComponent("captures/1791000000", isDirectory: true))

        module.review.captureStarting()
        module.review.captureFinished(.video(capture))
        try await Self.waitUntil { module.review.panel?.isShown == true }
        let panel = try #require(module.review.panel)
        let model = try #require(panel.model)
        #expect(!panel.window.isVisible, "never on screen under the unit-test host")
        #expect(model.input == .video(capture))
        #expect(model.context == .none, "the unit-test host's reader reads nothing")

        harness.model.setCapability(.screenshotTools, enabled: false)
        try await Self.waitUntil { !panel.isShown }
        #expect(ScreencastReview.read(from: capture.metadataURL) != nil, "closing saved it")
        #expect(FileManager.default.fileExists(atPath: capture.videos[0].file.path))
    }

    @available(macOS 15, *)
    @Test("Through the module, a recording made with the picker and stopped reaches the review panel once")
    func recordingReachesTheReviewOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencastOnce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsScreencastOnce-\(UUID().uuidString)"))
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        let writers = FakeWriterFactory()
        let clipboard = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("history.json"), pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("media", isDirectory: true), sourceApps: .inert
        )
        let module = Self.reviewingModule(writers: writers, review: ScreencastReviewServices(
            clipboard: clipboard,
            pasteboard: pasteboard,
            notices: nil,
            repositories: { ScreencastRepositoryMemory(storageURL: root.appendingPathComponent("repositories.json")) }
        ))
        var outcomes: [ScreencastReviewOutcome] = []
        module.review.onFinish = { outcomes.append($0) }

        module.start()
        let controller = try #require(module.controller)
        let picker = try #require(controller.picker)
        picker.target = .screen
        picker.clickScreen(PickerScreens.left)
        controller.confirm()
        try await Self.waitUntil { controller.phase == .recording }
        await controller.stop()
        try await Self.waitUntil { module.review.panel?.isShown == true }
        let panel = try #require(module.review.panel)
        guard case .video(let capture) = panel.model?.input else {
            Issue.record("the panel shows the recording")
            return
        }
        defer { try? FileManager.default.removeItem(at: capture.folder) }
        #expect(controller.phase == .idle)
        #expect(capture.videos.map(\.file) == writers.writers.map(\.fileURL), "the recording the module's recorder made")

        await panel.close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(outcomes == [.saved(.video(capture))], "once, and saved")
        #expect(!panel.isShown)
    }

    @available(macOS 15, *)
    @Test("Through the module, Record Screen closes the review window before its picker, and the app in front before the window gets the front back once the picker is done, not while it's open")
    func startingACaptureGivesTheFrontBackAfterThePicker() async throws {
        let fixture = ReviewFixture()
        defer { fixture.tearDown() }
        let front = FrontStandIn()
        let module = Self.reviewingModule(review: ScreencastReviewServices(
            clipboard: fixture.clipboard,
            pasteboard: fixture.pasteboard,
            notices: nil,
            repositories: { [fixture] in fixture.repositories },
            front: front.front
        ))
        await module.review.show(try fixture.video(), context: .none)
        let panel = try #require(module.review.panel)
        front.windowTakesTheFront(panel.window)

        module.start()
        let controller = try #require(module.controller)
        #expect(controller.phase == .picking && !panel.isShown, "the window goes before the picker opens")
        try await Self.waitUntil { panel.model == nil }
        #expect(front.activated.isEmpty, "nothing while the picker has the keyboard")

        controller.cancel()
        #expect(controller.phase == .idle)
        #expect(front.activated == [FrontStandIn.appBefore], "once the picker is done")
    }

    /// The module on fakes, turned on: made-up screens, an inert recorder, no countdown, and the
    /// review on `review`'s services.
    @available(macOS 15, *)
    private static func reviewingModule(
        writers: FakeWriterFactory = FakeWriterFactory(), review: ScreencastReviewServices
    ) -> ScreencastModule {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.set(.choice("0"), of: .screencastCountdown, for: .screenshotTools)
        return moduleOnFakes(preferences: preferences, writers: writers, review: review)
    }

    /// The module on fakes with `preferences`, turned on: made-up screens, an inert recorder,
    /// `presenter` for the picker and the countdown, and `sleep` for the countdown's clock.
    @available(macOS 15, *)
    private static func moduleOnFakes(
        preferences: AppPreferences,
        presenter: FakeOverlays? = nil,
        writers: FakeWriterFactory = FakeWriterFactory(),
        review: ScreencastReviewServices? = nil,
        sleep: @escaping (TimeInterval) async throws -> Void = { _ in }
    ) -> ScreencastModule {
        let module = ScreencastModule(
            preferences: preferences,
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            openSettings: { _ in },
            seams: ScreencastSeams(
                captureSystem: FakeCaptureSystem(content: ScreencastScreens.content()),
                writers: writers,
                pickerSystem: FakePickerSystem(content: ScreencastScreens.content()),
                presenter: presenter ?? FakeOverlays(),
                screens: { PickerScreens.both },
                sleep: sleep,
                contextReader: .inert
            ),
            review: review
        )
        module.apply(CapabilityContext(
            enabledCapabilities: [.screenshotTools],
            preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: DrawingHotKeyBackend()),
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            permissionReadiness: { capabilities in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: capabilities, states: [:], permissionsRequiringRelaunch: [])
            }
        ))
        return module
    }

    /// A recording's folder as the recorder leaves one: a stand-in video file and its meta.json.
    private static func recording(in folder: URL) throws -> ScreencastCapture {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: 0))
        try Data("made-up video".utf8).write(to: file)
        let video = ScreencastVideo(file: file, mixdown: nil, pixelWidth: 64, pixelHeight: 36, audioTracks: [], duration: 1)
        let capture = ScreencastCapture(folder: folder, videos: [video], duration: 1, endedEarly: nil)
        try ScreencastMetadata(capture: capture, target: .display(1), startedAt: Date(timeIntervalSince1970: 1_791_000_000)).write(to: capture.metadataURL)
        return capture
    }

    /// Lets the main actor run until `condition` holds, for two seconds at most.
    private static func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private static func module(of harness: WiringHarness) -> ScreencastModule {
        harness.model.recording!
    }

    // MARK: Settings attention

    @Test("ScreenGrabs' page needs attention while it's on without Screen Recording; the Microphone is optional")
    func attention() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencastAttention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let enabled: Set<Capability> = [.clipboardHistory, .screenshotTools]

        let missing = WiringHarness(enabled: enabled, missing: .screenRecording, root: root)
        missing.model.start()
        #expect(missing.model.settingsAttentionCount(for: .screenshotTools) == 1)
        #expect(missing.model.missingPermissions(for: .screenshotTools) == [.screenRecording])

        let noMicrophone = WiringHarness(enabled: enabled, missing: .microphone, root: root)
        noMicrophone.model.start()
        #expect(noMicrophone.model.settingsAttentionCount(for: .screenshotTools) == 0, "The Microphone is optional")

        let off = WiringHarness(enabled: [.clipboardHistory], missing: .screenRecording, root: root)
        off.model.start()
        #expect(off.model.settingsAttentionCount(for: .screenshotTools) == 0)
    }

    @Test("With Clipboard History off, Requires Clipboard History needs attention only while a screenshot hotkey is assigned, so someone who only records gets no dot that never clears")
    func attentionWithoutClipboardHistory() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreengrabsAttention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [.screenshotTools], missing: nil, root: root)
        harness.model.start()
        #expect(harness.model.screenshotTools.status == .requiresClipboardHistory)
        #expect(harness.model.settingsAttentionCount(for: .screenshotTools) == 1, "The screenshot hotkeys start assigned")

        let screenshotShortcuts = ScreenshotToolsModule.captureShortcuts.map(\.shortcut)
        for shortcut in screenshotShortcuts {
            harness.model.preferences.setCapabilityShortcut(nil, for: shortcut)
        }
        #expect(harness.model.preferences.capabilityShortcut(for: .screencast) != nil, "Record Screen is still on ⇧⌘5")
        #expect(harness.model.settingsAttentionCount(for: .screenshotTools) == 0, "Only recording")

        harness.model.preferences.setCapabilityShortcut(DefaultShortcut.screenshotArea, for: .screenshotArea)
        #expect(harness.model.settingsAttentionCount(for: .screenshotTools) == 1)
    }
}
