import Foundation

/// A `UserDefaults` that keeps every value in memory, so tests never create a preferences domain.
/// Removing a domain or deleting its plist doesn't stop cfprefsd from flushing it back later, so
/// tests must never write to a real suite; use this instead of `UserDefaults(suiteName:)`.
/// `UserDefaults` routes its typed accessors (`bool`, `integer`, `string`, `array`, `data`, and the
/// typed setters) through `object(forKey:)` and `set(_:forKey:)`, which this class overrides.
/// It holds one persistent domain, named `domainName`, plus a registration domain.
final class InMemoryDefaults: UserDefaults {
    /// The suite `UserDefaults` is initialized with, unique per instance. Nothing may ever reach
    /// it; `leakedDomain` reads it back so tests can prove no accessor bypassed these overrides.
    let domainName: String

    private var storage: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    init() {
        let name = "com.serp.keybumps.tests.in-memory-\(UUID().uuidString)"
        domainName = name
        super.init(suiteName: name)!
    }

    /// What the real preferences system holds for `domainName`; nil unless an accessor leaked.
    var leakedDomain: [String: Any]? {
        UserDefaults(suiteName: domainName)?.persistentDomain(forName: domainName)
    }

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName] ?? registered[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        storage[defaultName] = nil
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        registered.merge(registrationDictionary) { _, new in new }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        registered.merging(storage) { _, stored in stored }
    }

    override func persistentDomain(forName name: String) -> [String: Any]? {
        requireOwnDomain(name)
        return storage.isEmpty ? nil : storage
    }

    override func setPersistentDomain(_ domain: [String: Any], forName name: String) {
        requireOwnDomain(name)
        storage = domain
    }

    override func removePersistentDomain(forName name: String) {
        requireOwnDomain(name)
        storage = [:]
    }

    override func addSuite(named suiteName: String) {
        preconditionFailure("InMemoryDefaults can't search real suites")
    }

    override func synchronize() -> Bool {
        true
    }

    private func requireOwnDomain(_ name: String) {
        precondition(name == domainName, "InMemoryDefaults holds only its own domain, \(domainName)")
    }
}
