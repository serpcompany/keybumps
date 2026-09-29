import Foundation
import Testing
@testable import Keybumps

@MainActor
@Suite("In-memory test defaults")
struct InMemoryDefaultsTests {
    @Test("Every typed accessor round-trips in memory without reaching a real domain")
    func typedAccessorsRoundTrip() {
        let defaults = InMemoryDefaults()
        defaults.set(true, forKey: "bool")
        defaults.set(42, forKey: "integer")
        defaults.set("text", forKey: "string")
        defaults.set(["a", "b"], forKey: "array")
        defaults.set(Data([1, 2]), forKey: "data")
        defaults.register(defaults: ["registered": "fallback", "string": "ignored"])

        #expect(defaults.bool(forKey: "bool"))
        #expect(defaults.integer(forKey: "integer") == 42)
        #expect(defaults.string(forKey: "string") == "text")
        #expect(defaults.array(forKey: "array") as? [String] == ["a", "b"])
        #expect(defaults.data(forKey: "data") == Data([1, 2]))
        #expect(defaults.string(forKey: "registered") == "fallback")
        #expect(defaults.object(forKey: "missing") == nil)
        #expect(defaults.leakedDomain == nil)

        defaults.removeObject(forKey: "bool")
        #expect(defaults.object(forKey: "bool") == nil)
        defaults.setPersistentDomain(["seeded": 1], forName: defaults.domainName)
        #expect(defaults.integer(forKey: "seeded") == 1)
        #expect(defaults.persistentDomain(forName: defaults.domainName)?.keys.sorted() == ["seeded"])
        defaults.removePersistentDomain(forName: defaults.domainName)
        #expect(defaults.persistentDomain(forName: defaults.domainName) == nil)
        #expect(defaults.dictionaryRepresentation().keys.sorted() == ["registered", "string"])
        #expect(defaults.leakedDomain == nil)
    }

    @Test("AppPreferences persists, migrates, and reloads without reaching a real domain")
    func appPreferencesReloadFromTheSameDefaults() {
        let defaults = InMemoryDefaults()
        let legacy = InMemoryDefaults()
        legacy.set(["sound"], forKey: "selectedNotificationChannels")
        legacy.set(false, forKey: "showInDockAndSwitcher")

        let preferences = AppPreferences(defaults: defaults, legacyDefaults: [legacy])
        #expect(!preferences.showsCoachTips)
        #expect(!preferences.showInDockAndSwitcher)
        preferences.setCapability(.dictation, enabled: false)
        preferences.showsCoachTips = true
        preferences.dictationLanguage = "fr-FR"
        preferences.dictationDurationLimit = .tenMinutes
        preferences.didCompleteOnboarding = true
        preferences.setCapabilityShortcut(nil, for: .clipboardHistory)
        preferences.setWindowShortcut(nil, for: .left)

        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.enabledCapabilities == preferences.enabledCapabilities)
        #expect(!reloaded.enabledCapabilities.contains(.dictation))
        #expect(reloaded.showsCoachTips)
        #expect(!reloaded.showInDockAndSwitcher)
        #expect(reloaded.dictationLanguage == "fr-FR")
        #expect(reloaded.dictationDurationLimit == .tenMinutes)
        #expect(reloaded.didCompleteOnboarding)
        #expect(reloaded.capabilityShortcut(for: .clipboardHistory) == nil)
        #expect(reloaded.windowShortcut(for: .left) == nil)
        #expect(defaults.leakedDomain == nil)
        #expect(legacy.leakedDomain == nil)
    }

    @Test("Tests create preferences only through InMemoryDefaults")
    func noTestUsesARealSuite() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let exempt: Set<String> = ["InMemoryDefaults.swift", "InMemoryDefaultsTests.swift"]
        let sources = try FileManager.default.contentsOfDirectory(at: testsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !exempt.contains($0.lastPathComponent) }
        #expect(!sources.isEmpty)
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            #expect(!text.contains("UserDefaults(suiteName:"), "\(source.lastPathComponent) creates a real preferences suite; use InMemoryDefaults")
        }
    }

    @Test("The unit-test host doesn't launch the production app")
    func testHostStaysInert() {
        #expect(!KeybumpsMain.launchedApp)
    }
}
