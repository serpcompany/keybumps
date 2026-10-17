import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// The one-time step that folds what an install saved for Screencast into Screenshot Tools, which
/// becomes Screengrabs (#489). Fixtures are saved values written as raw strings, as an install holds
/// them, so they still describe real installs once `Capability.screencast` is retired (#490).
@MainActor
@Suite("Screengrabs migration")
struct ScreengrabsMigrationTests {
    static let flag = "didFoldScreencastIntoScreengrabs"
    /// `knownCapabilities` on an install that ran a build with Screencast.
    nonisolated static let knownWithScreencast = [
        "clipboardHistory", "dictation", "emojiPicker", "keyboardShortcutter", "keystrokes", "quickSearch", "screencast",
        "screenshotTools", "snippets", "timer", "translation", "windowManagement",
    ]
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
        "Screenshot Tools on stays on whatever Screencast was, both off stay off, and only the flag is written",
        arguments: [["clipboardHistory", "screenshotTools", "screencast"], ["clipboardHistory", "screenshotTools"], ["clipboardHistory"], nil]
    )
    func onOrOffCarriesOver(enabled: [String]?) {
        let defaults = Self.install(enabled: enabled)
        defaults.set(true, forKey: "copiesScreenshotsToClipboard")
        let before = defaults.dictionaryRepresentation()

        Self.fold(defaults)

        #expect(Self.changedKeys(before, defaults.dictionaryRepresentation()) == [Self.flag])
        #expect(defaults.bool(forKey: Self.flag))
    }

    @Test("Screencast on and Screenshot Tools off: Screengrabs turns on, its screenshot keys go back to macOS, and screenshots stop being copied")
    func screencastOnlyTurnsScreengrabsOn() {
        let defaults = Self.install(enabled: ["clipboardHistory", "screencast"])
        defaults.set(true, forKey: "copiesScreenshotsToClipboard")
        defaults.set(["28", "30"], forKey: "takenOverSystemShortcuts")
        let before = defaults.dictionaryRepresentation()

        Self.fold(defaults)

        #expect(Self.changedKeys(before, defaults.dictionaryRepresentation()) == [
            "enabledCapabilities", "capabilityShortcuts", "copiesScreenshotsToClipboard", Self.flag,
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
        #expect(preferences.capabilityShortcut(for: .screenshotArea) == nil)
        #expect(preferences.capabilityShortcut(for: .screencast) == Self.savedShortcuts["screencast"])
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
        #expect(preferences.capabilityShortcut(for: .screenshotArea) == Self.custom)
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

    @Test("It runs once: the next launch changes nothing, even after the person undoes what it did")
    func runsOnce() throws {
        try Self.withFolder { folder in
            let usageURL = folder.appendingPathComponent("application-usage.json")
            let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
            try Self.writeUsage(["command:screencast": ApplicationUsageRecord(launchCount: 2, lastOpenedAt: day)], to: usageURL)
            let defaults = Self.install(enabled: ["screencast"])
            AppPreferences.foldScreencastIntoScreengrabs(in: defaults, applicationUsage: usageURL)
            #expect(defaults.bool(forKey: Self.flag))

            // Screenshot Tools off again, ⇧⌘2–⇧⌘4 back, copying back on, and Screencast's command
            // learned again (as in a build rolled back to, which still lists it).
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

    @Test(
        "An install that never knew Screencast (beta.25 or earlier) is left as it is, even with a saved list naming it",
        arguments: [knownWithScreencast.filter { $0 != "screencast" }, nil]
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

            #expect(Self.changedKeys(before, defaults.dictionaryRepresentation()).isEmpty, "Not even the flag")
            #expect(try Data(contentsOf: usageURL) == usageBefore)
        }
    }

    @Test("On macOS 14, where Screencast could never be on, Screenshot Tools stays as it was", arguments: [true, false])
    func macOS14(screenshotToolsOn: Bool) {
        let defaults = Self.install(enabled: ["clipboardHistory", "screencast"] + (screenshotToolsOn ? ["screenshotTools"] : []))
        // macOS 14 never saves Screencast on, even when its saved list names it (`PluginCompatibility`).
        _ = AppPreferences(defaults: defaults, compatibility: PluginCompatibility(macOSMajorVersion: 14))
        #expect(defaults.stringArray(forKey: "enabledCapabilities")?.contains("screencast") == false)
        #expect(defaults.stringArray(forKey: "knownCapabilities")?.contains("screencast") == true)
        let before = defaults.dictionaryRepresentation()

        Self.fold(defaults)

        #expect(Self.changedKeys(before, defaults.dictionaryRepresentation()) == [Self.flag])
        #expect(defaults.stringArray(forKey: "enabledCapabilities")?.contains("screenshotTools") == screenshotToolsOn)
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
        "Quick Search's learned usage of Screencast is added to Screenshot Tools'; Start Screencast's action keeps its own",
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
