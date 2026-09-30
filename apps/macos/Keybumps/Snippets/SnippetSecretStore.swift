import Foundation
import Security

/// Where a sensitive snippet's text lives, one item per snippet ID. The app keeps it in the
/// Keychain; unit tests and the UI-test composition keep it in memory, so they never touch the
/// owner's Keychain.
protocol SnippetSecretStoring: AnyObject {
    func text(for id: UUID) -> String?
    func setText(_ text: String, for id: UUID) throws
    func removeText(for id: UUID)
}

enum SnippetSecretError: Error, Equatable {
    case keychain(OSStatus)
}

/// Keychain storage for sensitive snippets: a generic password per snippet, readable only while
/// this Mac is unlocked, and never synced to iCloud Keychain or moved to another Mac. The service
/// name follows the bundle identifier, so Debug builds never read the installed app's snippets.
/// The item's label is generic; a snippet's name and keyword stay out of the Keychain.
final class KeychainSnippetSecretStore: SnippetSecretStoring {
    static let itemLabel = "Keybumps snippet"

    let service: String

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? ProductIdentity.bundleIdentifier) {
        service = "\(bundleIdentifier).snippets"
    }

    /// Identifies one snippet's item.
    func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    /// Everything a new item is added with.
    func newItemAttributes(for id: UUID, data: Data) -> [String: Any] {
        var attributes = query(for: id)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = Self.itemLabel
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        return attributes
    }

    func text(for id: UUID) -> String? {
        var query = query(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setText(_ text: String, for id: UUID) throws {
        let data = Data(text.utf8)
        var status = SecItemUpdate(query(for: id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(newItemAttributes(for: id, data: data) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SnippetSecretError.keychain(status) }
    }

    func removeText(for id: UUID) {
        SecItemDelete(query(for: id) as CFDictionary)
    }
}

/// Sensitive snippet text held only in memory: for unit tests and UI tests.
final class InMemorySnippetSecretStore: SnippetSecretStoring {
    private(set) var texts: [UUID: String] = [:]
    /// Makes the next `setText` fail, as a locked or unavailable Keychain would.
    var failsNextWrite = false

    init(_ texts: [UUID: String] = [:]) {
        self.texts = texts
    }

    func text(for id: UUID) -> String? { texts[id] }

    func setText(_ text: String, for id: UUID) throws {
        if failsNextWrite {
            failsNextWrite = false
            throw SnippetSecretError.keychain(errSecInteractionNotAllowed)
        }
        texts[id] = text
    }

    func removeText(for id: UUID) { texts[id] = nil }
}
