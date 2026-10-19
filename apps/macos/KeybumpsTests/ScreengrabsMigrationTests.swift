import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// The one-time step that folds what an install saved for Screencast into Screenshot Tools, which
/// became ScreenGrabs (#489), and that `AppPreferences.init` runs first now that
/// `Capability.screencast` is retired (#490). Fixtures are saved values written as raw strings, as
/// an install holds them.
@MainActor
@Suite("ScreenGrabs migration")
struct ScreengrabsMigrationTests {
    /// `knownCapabilities` on an install that ran a build with Screencast.
    nonisolated static let knownWithScreencast = [
        "clipboardHistory", "dictation", "emojiPicker", "keyboardShortcutter", "keystrokes", "quickSearch", "screencast",
        "screenshotTools", "snippets", "timer", "translation", "windowManagement",
    ]
    /// `knownCapabilities` as launch saves it now that `Capability.screencast` is retired (#490).
    nonisolated static let knownWithoutScreencast = knownWithScreencast.filter { $0 != "screencast" }
    static let screenshotShortcuts = ["screenshotScreen", "screenshotScreenAndEdit", "screenshotArea"]
    static let custom = ShortcutBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | optionKey), displayName: "⌥⌘S")

    /// Every default, plus a key for each of Screencast's five shortcuts.
    nonisolated static var savedShortcuts: [String: ShortcutBinding] {
        var shortcuts = Dictionary(uniqueKeysWithValues: CapabilityShortcut.allCases.compactMap { shortcut in
            shortcut.defaultBinding.map { (shortcut.rawValue, $0) }
        })
        let controlCommand = UInt32(cmdKey | controlKey)
        shortcuts["screencast"] = ShortcutBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: controlCommand, displayName: "⌃⌘R")
        shortcuts["screencastPause"] = ShortcutBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: controlCommand, displayName: "⌃⌘P")
        shortcuts["screencastStop"] = ShortcutBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: controlCommand, displayName: "⌃⌘T")
        shortcuts["screencastDiscard"] = ShortcutBinding(keyCode: UInt32(kVK_ANSI_D), modifiers: controlCommand, displayName: "⌃⌘D")
        shortcuts["screencastDraw"] = ShortcutBinding(keyCode: UInt32(kVK_ANSI_W), modifiers: controlCommand, displayName: "⌃⌘W")
        return shortcuts
    }

    /// An install with these plugins on (nil: never changed), as a build with Screencast leaves it.
    static func install(
        enabled: [String]?,
        known: [String]? = knownWithScreencast,
        shortcuts: [String: ShortcutBinding]? = savedShortcuts
    ) -> InMemoryDefaults {
        let defaults = InMemoryDefaults()
        defaults.set(enabled, forKey: "enabledCapabilities")
        defaults.set(known, forKey: "knownCapabilities")
        defaults.set(CapabilityShortcut.allCases.map(\.rawValue).sorted(), forKey: "knownCapabilityShortcuts")
        if let shortcuts { setShortcuts(shortcuts, in: defaults) }
        return defaults
    }

    static func setShortcuts(_ shortcuts: [String: ShortcutBinding], in defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(shortcuts), forKey: "capabilityShortcuts")
    }

    static func shortcuts(in defaults: UserDefaults) -> [String: ShortcutBinding]? {
        defaults.data(forKey: "capabilityShortcuts").flatMap { try? JSONDecoder().decode([String: ShortcutBinding].self, from: $0) }
    }

    /// The keys whose saved values differ.
    static func changedKeys(_ before: [String: Any], _ after: [String: Any]) -> Set<String> {
        Set(before.keys).union(after.keys).filter { key in
            guard let old = before[key], let new = after[key] else { return true }
            return !(old as AnyObject).isEqual(new)
        }
    }

    /// A folder of its own, standing in for Application Support, which `body` gets and which is then removed.
    static func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreengrabsMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    static func writeUsage(_ records: [String: ApplicationUsageRecord], to url: URL) throws {
        try JSONEncoder().encode(records).write(to: url)
    }

    static func usage(at url: URL) throws -> [String: ApplicationUsageRecord] {
        try JSONDecoder().decode([String: ApplicationUsageRecord].self, from: Data(contentsOf: url))
    }

    /// Every file under `root`, by its path from there.
    static func files(in root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            var isDirectory: ObjCBool = false
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files[path] = try Data(contentsOf: url)
        }
        return files
    }

    /// Runs the step with a usage file that doesn't exist, in a folder that doesn't either.
    static func fold(_ defaults: UserDefaults) {
        AppPreferences.foldScreencastIntoScreengrabs(
            in: defaults,
            applicationUsage: FileManager.default.temporaryDirectory
                .appendingPathComponent("ScreengrabsMigrationTests-missing-\(UUID().uuidString)")
                .appendingPathComponent("application-usage.json")
        )
    }

    // MARK: On or off

    @Test(
        "Screenshot Tools on stays on whatever Screencast was, both off stay off, and nothing is written",
        arguments: [["clipboardHistory", "screenshotTools", "screencast"], ["clipboardHistory", "screenshotTools"], ["clipboardHistory"], nil]
    )
    func onOrOffCarriesOver(enabled: [String]?) {
        let defaults = Self.install(enabled: enabled)
        defaults.set(true, forKey: "copiesScreenshotsToClipboard")
        let before = defaults.dictionaryRepresentation()

        Self.fold(defaults)

        #expect(Self.changedKeys(before, defaults.dictionaryRepresentation()).isEmpty)
    }

    @Test("Screencast on and Screenshot Tools off: ScreenGrabs turns on, its screenshot keys go back to macOS, and screenshots stop being copied")
    func screencastOnlyTurnsScreengrabsOn() {
        let defaults = Self.install(enabled: ["clipboardHistory", "screencast"])
        defaults.set(true, forKey: "copiesScreenshotsToClipboard")
        defaults.set(["28", "30"], forKey: "takenOverSystemShortcuts")
        let before = defaults.dictionaryRepresentation()

        Self.fold(defaults)

        #expect(Self.changedKeys(before, defaults.dictionaryRepresentation()) == [
            "enabledCapabilities", "capabilityShortcuts", "copiesScreenshotsToClipboard",
        ])
        #expect(defaults.stringArray(forKey: "enabledCapabilities") == ["clipboardHistory", "screencast", "screenshotTools"])
        var expected = Self.savedShortcuts
        for id in Self.screenshotShortcuts { expected[id] = nil }
        #expect(Self.shortcuts(in: defaults) == expected, "Every other binding, Screencast's five included, keeps its raw value")
        #expect(defaults.object(forKey: "copiesScreenshotsToClipboard") as? Bool == false)

        // Launch reads that as Screenshot Tools on, its screenshot shortcuts unassigned rather than
        // new, and screenshots not copied.
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.enabledCapabilities.contains(.screenshotTools))
        #expect(preferences.capabilityShortcut(for: .screenshotScreen) == nil)
        #expect(preferences.capabilityShortcut(for: .screenshotScreenAndEdit) == nil)
        #expect(preferences.capabilityShortcut(for: .screenshotAreaAndEdit) == nil)
        #expect(preferences.capabilityShortcut(for: .screencast) == DefaultShortcut.recordScreen, "Launch's one-time step then gives Record Screen ⇧⌘5 in place of its own (#513)")
        #expect(!preferences.copiesScreenshotsToClipboard)
    }

    @Test("Screencast on and Screenshot Tools off, on an install that never changed a shortcut, saves every other default")
    func screencastOnlyWithShortcutsNeverSaved() {
        let defaults = Self.install(enabled: ["screencast"], shortcuts: nil)

        Self.fold(defaults)

        var expected = Dictionary(uniqueKeysWithValues: CapabilityShortcut.allCases.compactMap { shortcut in
            shortcut.defaultBinding.map { (shortcut.rawValue, $0) }
        })
        for id in Self.screenshotShortcuts { expected[id] = nil }
        #expect(Self.shortcuts(in: defaults) == expected)
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.capabilityShortcut(for: .screenshotScreen) == nil)
        #expect(preferences.capabilityShortcut(for: .quickSearch) == DefaultShortcut.quickSearch)
    }

    @Test("A custom screenshot shortcut is kept, and one already cleared stays cleared, while one on its default key is unassigned")
    func customScreenshotShortcutKept() {
        var shortcuts = Self.savedShortcuts
        shortcuts["screenshotArea"] = Self.custom
        shortcuts["screenshotScreenAndEdit"] = nil
        // The same keys under another name are still the default.
        shortcuts["screenshotScreen"] = ShortcutBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), displayName: "Shift-Command-2")
        let defaults = Self.install(enabled: ["screencast"], shortcuts: shortcuts)

        Self.fold(defaults)

        let saved = Self.shortcuts(in: defaults)
        #expect(saved?["screenshotArea"] == Self.custom)
        #expect(saved?.keys.contains("screenshotScreenAndEdit") == false)
        #expect(saved?.keys.contains("screenshotScreen") == false)
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.capabilityShortcut(for: .screenshotAreaAndEdit) == Self.custom)
        #expect(preferences.capabilityShortcut(for: .screenshotScreen) == nil)
        #expect(preferences.capabilityShortcut(for: .screenshotScreenAndEdit) == nil)
    }

    // MARK: When it runs

    @Test("A new install has nothing to carry over, and nothing is written")
    func freshInstall() throws {
        try Self.withFolder { folder in
            let usageURL = folder.appendingPathComponent("application-usage.json")
            let defaults = InMemoryDefaults()

            AppPreferences.foldScreencastIntoScreengrabs(in: defaults, applicationUsage: usageURL)

            #expect(defaults.dictionaryRepresentation().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: usageURL.path))
        }
    }

    @Test("Once launch saves knownCapabilities without screencast (#490), it doesn't run again, whatever else is saved")
    func stopsOnceLaunchDropsScreencast() throws {
        try Self.withFolder { folder in
            let usageURL = folder.appendingPathComponent("application-usage.json")
            let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
            try Self.writeUsage(["command:screencast": ApplicationUsageRecord(launchCount: 2, lastOpenedAt: day)], to: usageURL)
            let defaults = Self.install(enabled: ["screencast"])
            AppPreferences.foldScreencastIntoScreengrabs(in: defaults, applicationUsage: usageURL)
            #expect(defaults.stringArray(forKey: "enabledCapabilities") == ["screencast", "screenshotTools"])
            // What launch saves right after the step, now that `Capability.screencast` is retired.
            defaults.set(Self.knownWithoutScreencast, forKey: "knownCapabilities")

            // Screenshot Tools off again, ⇧⌘2–⇧⌘4 back, copying back on, and picks under Screencast's
            // command: only `knownCapabilities` decides.
            defaults.set(["screencast"], forKey: "enabledCapabilities")
            Self.setShortcuts(Self.savedShortcuts, in: defaults)
            defaults.set(true, forKey: "copiesScreenshotsToClipboard")
            try Self.writeUsage([
                "command:screencast": ApplicationUsageRecord(launchCount: 1, lastOpenedAt: day),
                "command:screenshotTools": ApplicationUsageRecord(launchCount: 2, lastOpenedAt: day),
            ], to: usageURL)
            let before = defaults.dictionaryRepresentation()
            let usageBefore = try Data(contentsOf: usageURL)

            AppPreferences.foldScreencastIntoScreengrabs(in: defaults, applicationUsage: usageURL)

            #expect(Self.changedKeys(before, defaults.dictionaryRepresentation()).isEmpty)
            #expect(try Data(contentsOf: usageURL) == usageBefore)
        }
    }

    @Test("Run again before launch saves knownCapabilities (a launch cut short), it changes nothing and adds no pick twice")
    func runAgainChangesNothing() throws {
        try Self.withFolder { folder in
            let usageURL = folder.appendingPathComponent("application-usage.json")
            let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
            try Self.writeUsage([
                "command:screencast": ApplicationUsageRecord(launchCount: 3, lastOpenedAt: day),
                "command:screenshotTools": ApplicationUsageRecord(launchCount: 4, lastOpenedAt: day),
            ], to: usageURL)
            let defaults = Self.install(enabled: ["screencast"])
            defaults.set(true, forKey: "copiesScreenshotsToClipboard")
            AppPreferences.foldScreencastIntoScreengrabs(in: defaults, applicationUsage: usageURL)
            #expect(try Self.usage(at: usageURL) == ["command:screenshotTools": ApplicationUsageRecord(launchCount: 7, lastOpenedAt: day)])
            let before = defaults.dictionaryRepresentation()
            let usageBefore = try Data(contentsOf: usageURL)

            AppPreferences.foldScreencastIntoScreengrabs(in: defaults, applicationUsage: usageURL)

            #expect(Self.changedKeys(before, defaults.dictionaryRepresentation()).isEmpty)
            #expect(try Data(contentsOf: usageURL) == usageBefore)
        }
    }

    @Test("A build rolled back to puts screencast back in knownCapabilities, so after a return it runs again, from what the person last saved")
    func runsAgainAfterRollback() throws {
        try Self.withFolder { folder in
            let usageURL = folder.appendingPathComponent("application-usage.json")
            let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let later = Date(timeIntervalSinceReferenceDate: 810_000_000)
            try Self.writeUsage([
                "command:screencast": ApplicationUsageRecord(launchCount: 3, lastOpenedAt: day),
                "command:screenshotTools": ApplicationUsageRecord(launchCount: 4, lastOpenedAt: day),
            ], to: usageURL)
            // The first update, with Screenshot Tools on: only the picks move.
            let defaults = Self.install(enabled: ["clipboardHistory", "screenshotTools"])
            defaults.set(true, forKey: "copiesScreenshotsToClipboard")
            AppPreferences.foldScreencastIntoScreengrabs(in: defaults, applicationUsage: usageURL)
            #expect(try Self.usage(at: usageURL) == ["command:screenshotTools": ApplicationUsageRecord(launchCount: 7, lastOpenedAt: day)])
            defaults.set(Self.knownWithoutScreencast, forKey: "knownCapabilities")

            // Rolled back: the older build lists Screencast again, and there the person turns it on,
            // turns Screenshot Tools off, and picks Screencast's command once more.
            defaults.set(Self.knownWithScreencast, forKey: "knownCapabilities")
            defaults.set(["clipboardHistory", "screencast"], forKey: "enabledCapabilities")
            try Self.writeUsage([
                "command:screencast": ApplicationUsageRecord(launchCount: 1, lastOpenedAt: later),
                "command:screenshotTools": ApplicationUsageRecord(launchCount: 7, lastOpenedAt: day),
            ], to: usageURL)

            // Updated again.
            AppPreferences.foldScreencastIntoScreengrabs(in: defaults, applicationUsage: usageURL)

            #expect(defaults.stringArray(forKey: "enabledCapabilities") == ["clipboardHistory", "screencast", "screenshotTools"])
            var expected = Self.savedShortcuts
            for id in Self.screenshotShortcuts { expected[id] = nil }
            #expect(Self.shortcuts(in: defaults) == expected)
            #expect(defaults.object(forKey: "copiesScreenshotsToClipboard") as? Bool == false)
            #expect(
                try Self.usage(at: usageURL) == ["command:screenshotTools": ApplicationUsageRecord(launchCount: 8, lastOpenedAt: later)],
                "Only the pick made since the first update is added"
            )
        }
    }

    @Test(
        "An install that never knew Screencast (beta.25 or earlier) is left as it is, even with a saved list naming it",
        arguments: [knownWithoutScreencast, nil]
    )
    func neverKnewScreencast(known: [String]?) throws {
        try Self.withFolder { folder in
            let usageURL = folder.appendingPathComponent("application-usage.json")
            try Self.writeUsage(["command:screencast": ApplicationUsageRecord(launchCount: 1, lastOpenedAt: Date())], to: usageURL)
            let usageBefore = try Data(contentsOf: usageURL)
            // Only `knownCapabilities` arms it; the saved list of plugins that are on doesn't.
            let defaults = Self.install(enabled: ["clipboardHistory", "screencast"], known: known)
            let before = defaults.dictionaryRepresentation()

            AppPreferences.foldScreencastIntoScreengrabs(in: defaults, applicationUsage: usageURL)

            #expect(Self.changedKeys(before, defaults.dictionaryRepresentation()).isEmpty)
            #expect(try Data(contentsOf: usageURL) == usageBefore)
        }
    }

    @Test("On macOS 14, where Screencast could never be on, Screenshot Tools stays as it was through launch", arguments: [true, false])
    func macOS14(screenshotToolsOn: Bool) {
        // What a build with Screencast saved on macOS 14: never Screencast on (`PluginCompatibility`),
        // though it knew it.
        let defaults = Self.install(enabled: ["clipboardHistory"] + (screenshotToolsOn ? ["screenshotTools"] : []))
        defaults.set(true, forKey: "copiesScreenshotsToClipboard")
        let shortcuts = Self.shortcuts(in: defaults) ?? [:]

        let preferences = AppPreferences(defaults: defaults, compatibility: PluginCompatibility(macOSMajorVersion: 14))

        #expect(preferences.enabledCapabilities.contains(.screenshotTools) == screenshotToolsOn)
        #expect(preferences.copiesScreenshotsToClipboard)
        for id in Self.screenshotShortcuts {
            #expect(preferences.capabilityShortcut(for: CapabilityShortcut(rawValue: id)!) == shortcuts[id], "\(id)")
        }
    }

    // MARK: From launch

    @Test("Launch runs the step first, then saves knownCapabilities without screencast, so the step runs once")
    func launchRunsTheStepOnce() throws {
        let defaults = Self.install(enabled: ["clipboardHistory", "screencast"])
        defaults.set(true, forKey: "copiesScreenshotsToClipboard")

        let first = AppPreferences(defaults: defaults)
        #expect(first.enabledCapabilities == [.quickSearch, .clipboardHistory, .screenshotTools], "Quick Search is always on (#553)")
        #expect(defaults.stringArray(forKey: "enabledCapabilities") == ["clipboardHistory", "quickSearch", "screenshotTools"])
        #expect(defaults.stringArray(forKey: "knownCapabilities")?.contains("screencast") == false)
        #expect(first.capabilityShortcut(for: .screenshotAreaAndEdit) == nil)
        #expect(first.capabilityShortcut(for: .screencast) == DefaultShortcut.recordScreen, "Launch's one-time step then gives Record Screen ⇧⌘5 in place of its own (#513)")
        #expect(!first.copiesScreenshotsToClipboard)

        // The person takes back ⇧⌘4 and the clipboard copy; the next launch leaves them.
        first.setCapabilityShortcut(DefaultShortcut.screenshotAreaAndEdit, for: .screenshotAreaAndEdit)
        first.copiesScreenshotsToClipboard = true
        let second = AppPreferences(defaults: defaults)
        #expect(second.capabilityShortcut(for: .screenshotAreaAndEdit) == DefaultShortcut.screenshotAreaAndEdit)
        #expect(second.copiesScreenshotsToClipboard)
        #expect(second.enabledCapabilities == [.quickSearch, .clipboardHistory, .screenshotTools])
    }

    // MARK: What it leaves

    @Test("Screencast's settings and memories keep their keys and values; launch removes only addsToScreenshots")
    func screencastSettingsKept() {
        let kept: [String: Any] = [
            "plugin.screencast.recordsMicrophone": false,
            "plugin.screencast.recordsSystemAudio": true,
            "plugin.screencast.countdown": "10",
            "plugin.screencast.showsShortcuts": false,
            "plugin.screencast.highlightsClicks": true,
            "screencast.lastArea": Data([1, 2, 3]),
            "screencast.controlBarPositions": Data([4, 5, 6]),
            "screencast.drawingStyle": Data([7, 8, 9]),
            "screencast.pickerChoices": Data([10, 11, 12]),
            "takenOverSystemShortcuts": ["28", "30"],
        ]
        // The row that writes the most.
        let defaults = Self.install(enabled: ["screencast"])
        for (key, value) in kept { defaults.set(value, forKey: key) }
        defaults.set(false, forKey: "plugin.screencast.addsToScreenshots")
        let knownShortcuts = defaults.stringArray(forKey: "knownCapabilityShortcuts")

        Self.fold(defaults)

        for (key, value) in kept {
            #expect((defaults.object(forKey: key) as AnyObject?)?.isEqual(value) == true, "\(key)")
        }
        #expect(defaults.object(forKey: "plugin.screencast.addsToScreenshots") as? Bool == false, "The step itself leaves it")
        #expect(defaults.stringArray(forKey: "knownCapabilityShortcuts") == knownShortcuts)

        _ = AppPreferences(defaults: defaults)

        #expect(defaults.object(forKey: "plugin.screencast.addsToScreenshots") == nil, "Its reader went in #487")
        for (key, value) in kept {
            #expect((defaults.object(forKey: key) as AnyObject?)?.isEqual(value) == true, "\(key)")
        }
    }

    @Test("Of the files, only application-usage.json changes: Screencast's repositories and captures are left as they are")
    func filesKept() throws {
        try Self.withFolder { root in
            let support = root.appendingPathComponent("Library/Application Support/Keybumps")
            let capture = root.appendingPathComponent("Documents/Keybumps/captures/2026-10-01 at 10.00.00")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
            let usageURL = support.appendingPathComponent("application-usage.json")
            try Self.writeUsage(["command:screencast": ApplicationUsageRecord(launchCount: 1, lastOpenedAt: Date())], to: usageURL)
            try Data("[]".utf8).write(to: support.appendingPathComponent("screencast-repositories.json"))
            try Data("{}".utf8).write(to: capture.appendingPathComponent("meta.json"))
            try Data([0, 0, 0, 0x18]).write(to: capture.appendingPathComponent("display-1.mov"))
            let usagePath = "Library/Application Support/Keybumps/application-usage.json"
            var before = try Self.files(in: root)
            let usageBefore = before.removeValue(forKey: usagePath)

            AppPreferences.foldScreencastIntoScreengrabs(in: Self.install(enabled: ["screencast"]), applicationUsage: usageURL)

            var after = try Self.files(in: root)
            let usageAfter = after.removeValue(forKey: usagePath)
            #expect(after == before)
            #expect(usageAfter != nil && usageAfter != usageBefore)
        }
    }

    // MARK: Learned usage

    @Test(
        "Quick Search's learned usage of Screencast is added to Screenshot Tools'; Record Screen's action keeps its own",
        arguments: [nil, 500_000_000, 900_000_000] as [TimeInterval?]
    )
    func learnedUsageAdded(screenshotToolsLastOpened: TimeInterval?) throws {
        try Self.withFolder { folder in
            let usageURL = folder.appendingPathComponent("application-usage.json")
            let screencastLastOpened = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let action = ApplicationUsageRecord(launchCount: 5, lastOpenedAt: screencastLastOpened)
            let app = ApplicationUsageRecord(launchCount: 2, lastOpenedAt: screencastLastOpened)
            var records = [
                "command:screencast": ApplicationUsageRecord(launchCount: 3, lastOpenedAt: screencastLastOpened),
                "action:startScreencast": action,
                "/Applications/Example.app": app,
            ]
            let screenshotTools = screenshotToolsLastOpened.map {
                ApplicationUsageRecord(launchCount: 4, lastOpenedAt: Date(timeIntervalSinceReferenceDate: $0))
            }
            records["command:screenshotTools"] = screenshotTools
            try Self.writeUsage(records, to: usageURL)

            AppPreferences.foldScreencastIntoScreengrabs(in: Self.install(enabled: ["screenshotTools"]), applicationUsage: usageURL)

            let expected = ApplicationUsageRecord(
                launchCount: 3 + (screenshotTools?.launchCount ?? 0),
                lastOpenedAt: max(screencastLastOpened, screenshotTools?.lastOpenedAt ?? .distantPast)
            )
            #expect(try Self.usage(at: usageURL) == [
                "command:screenshotTools": expected,
                "action:startScreencast": action,
                "/Applications/Example.app": app,
            ])
            #expect(ApplicationUsageStore(storageURL: usageURL).record(for: .capability(.screenshotTools)) == expected)
        }
    }
}
