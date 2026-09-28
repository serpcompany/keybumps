import Foundation
import Testing
@testable import Keybumps

@MainActor
@Suite("In-memory test defaults")
struct InMemoryDefaultsTests {
    @Test("Every accessor AppPreferences uses round-trips in memory")
    func typedAccessorsRoundTrip() {
        let defaults = InMemoryDefaults()
        defaults.set(true, forKey: "bool")
        defaults.set(42, forKey: "integer")
        defaults.set("text", forKey: "string")
        defaults.set(["a", "b"], forKey: "array")
        defaults.set(Data([1, 2]), forKey: "data")

        #expect(defaults.bool(forKey: "bool"))
        #expect(defaults.integer(forKey: "integer") == 42)
        #expect(defaults.string(forKey: "string") == "text")
        #expect(defaults.array(forKey: "array") as? [String] == ["a", "b"])
        #expect(defaults.data(forKey: "data") == Data([1, 2]))
        #expect(defaults.object(forKey: "missing") == nil)

        defaults.removeObject(forKey: "bool")
        #expect(defaults.object(forKey: "bool") == nil)
        defaults.removePersistentDomain(forName: InMemoryDefaults.unusedSuiteName)
        #expect(defaults.dictionaryRepresentation().isEmpty)
    }

    @Test("AppPreferences persists and reloads through in-memory defaults")
    func appPreferencesReloadFromTheSameDefaults() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.setCapability(.dictation, enabled: false)
        preferences.set(.sound, enabled: true)
        preferences.showInDockAndSwitcher = false
        preferences.dictationLanguage = "fr-FR"
        preferences.dictationDurationLimit = .tenMinutes
        preferences.didCompleteOnboarding = true
        preferences.setCapabilityShortcut(nil, for: .clipboardHistory)
        preferences.setWindowShortcut(nil, for: .left)

        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.enabledCapabilities == preferences.enabledCapabilities)
        #expect(!reloaded.enabledCapabilities.contains(.dictation))
        #expect(reloaded.selectedChannels == preferences.selectedChannels)
        #expect(!reloaded.showInDockAndSwitcher)
        #expect(reloaded.dictationLanguage == "fr-FR")
        #expect(reloaded.dictationDurationLimit == .tenMinutes)
        #expect(reloaded.didCompleteOnboarding)
        #expect(reloaded.capabilityShortcut(for: .clipboardHistory) == nil)
        #expect(reloaded.windowShortcut(for: .left) == nil)
    }

    @Test("Nothing reaches the real preferences domain")
    func nothingIsPersisted() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.setCapability(.windowManagement, enabled: false)
        preferences.didCompleteOnboarding = true
        _ = defaults.synchronize()

        let suite = InMemoryDefaults.unusedSuiteName
        #expect(UserDefaults(suiteName: suite)?.persistentDomain(forName: suite) == nil)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        #expect(!FileManager.default.fileExists(atPath: plist.path))
    }
}
