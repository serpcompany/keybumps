import Foundation

/// A `UserDefaults` that keeps every value in memory, so tests never create a preferences domain.
/// Removing a domain or deleting its plist doesn't stop cfprefsd from flushing it back later, so
/// tests must never write to a real suite. `UserDefaults` routes its typed accessors (`bool`,
/// `integer`, `string`, `array`, `data`, and the typed setters) through `object(forKey:)` and
/// `set(_:forKey:)`, which this class overrides; `InMemoryDefaultsTests` guards that.
final class InMemoryDefaults: UserDefaults {
    /// The suite `UserDefaults` is initialized with. Nothing may ever be written to it; the tests
    /// assert it stays empty, which would reveal an accessor that bypasses these overrides.
    static let unusedSuiteName = "com.serp.keybumps.tests.in-memory-defaults"

    private var storage: [String: Any] = [:]

    init() {
        super.init(suiteName: Self.unusedSuiteName)!
    }

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        storage[defaultName] = nil
    }

    override func dictionaryRepresentation() -> [String: Any] {
        storage
    }

    override func removePersistentDomain(forName domainName: String) {
        storage = [:]
    }

    override func synchronize() -> Bool {
        true
    }
}
