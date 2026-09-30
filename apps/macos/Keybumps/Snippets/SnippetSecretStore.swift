import Foundation
import Security

/// Where a sensitive snippet's text lives, one item per snippet ID. The app keeps it in the
/// Keychain; unit tests and the UI-test composition keep it in memory, so they never touch the
/// owner's Keychain.
protocol SnippetSecretStoring: AnyObject {
    func text(for id: UUID) -> String?
    func setText(_ text: String, for id: UUID) throws
    /// Removes the item if there is one; removing one that doesn't exist succeeds.
    func removeText(for id: UUID) throws
    /// The snippet IDs that have an item, or nil if they can't be listed.
    func storedIDs() -> Set<UUID>?
}

enum SnippetSecretError: Error, Equatable {
    case keychain(OSStatus)
}

/// Keychain storage for sensitive snippets: a generic-password item per snippet in the login
/// keychain, not synchronizable, with a generic label, so a snippet's name and keyword stay out of
/// the Keychain. The login keychain protects it with the user's login password and the item's
/// access list. It doesn't use the data protection keychain, which needs a keychain-access-groups
/// entitlement and provisioning profile, so accessibility classes such as "when unlocked, this
/// device only" don't apply: the login keychain is usually unlocked for the whole session, and its
/// file moves with Migration Assistant and backups.
///
/// The service name follows the bundle identifier. A Debug build reads the installed app's
/// `snippets.json` but its own Keychain items, so it can't read the installed app's sensitive
/// text, and snippets it deletes leave the installed app's item until that app next opens and
/// removes items no snippet uses (`SnippetStore`).
final class KeychainSnippetSecretStore: SnippetSecretStoring {
    static let itemLabel = "Keybumps snippet"

    let service: String

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? ProductIdentity.bundleIdentifier) {
        service = "\(bundleIdentifier).snippets"
    }

    /// Every item for this service.
    var serviceQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    /// Identifies one snippet's item.
    func query(for id: UUID) -> [String: Any] {
        var query = serviceQuery
        query[kSecAttrAccount as String] = id.uuidString
        return query
    }

    /// Everything a new item is added with.
    func newItemAttributes(for id: UUID, data: Data) -> [String: Any] {
        var attributes = query(for: id)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = Self.itemLabel
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

    func removeText(for id: UUID) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SnippetSecretError.keychain(status)
        }
    }

    /// Lists accounts only; no item's text is read.
    func storedIDs() -> Set<UUID>? {
        var query = serviceQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return nil }
        return Set(items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) })
    }
}

/// Sensitive snippet text held only in memory: for unit tests and UI tests.
final class InMemorySnippetSecretStore: SnippetSecretStoring {
    private(set) var texts: [UUID: String] = [:]
    /// Makes the next `setText` fail, as a locked or unavailable Keychain would.
    var failsNextWrite = false
    /// Makes the next `removeText` fail.
    var failsNextRemoval = false
    /// Makes `storedIDs` fail, as a Keychain that can't be listed would.
    var failsListing = false

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

    func removeText(for id: UUID) throws {
        if failsNextRemoval {
            failsNextRemoval = false
            throw SnippetSecretError.keychain(errSecInteractionNotAllowed)
        }
        texts[id] = nil
    }

    func storedIDs() -> Set<UUID>? {
        failsListing ? nil : Set(texts.keys)
    }

    /// Loses an item behind the store's back, as a Keychain the user edited would.
    func removeTextForTesting(_ id: UUID) {
        texts[id] = nil
    }
}
