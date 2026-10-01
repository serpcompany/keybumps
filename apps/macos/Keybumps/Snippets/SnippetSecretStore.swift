import Foundation
import Security

/// Where a sensitive snippet's text lives, one item per snippet ID. The app keeps it in the
/// Keychain; unit tests and the UI-test composition keep it in memory, so they never touch the
/// owner's Keychain.
protocol SnippetSecretStoring: AnyObject {
    /// The item's text, or nil when there's no item (or its data isn't text). Throws when the
    /// Keychain won't read it, for example while it's locked or after a denied access prompt.
    func storedText(for id: UUID) throws -> String?
    func setText(_ text: String, for id: UUID) throws
    /// Removes the item if there is one; removing one that doesn't exist succeeds.
    func removeText(for id: UUID) throws
    /// The IDs that have an item, listed without reading any text.
    func itemIDs() throws -> Set<UUID>
}

extension SnippetSecretStoring {
    /// The item's text, or nil when there's none or it can't be read.
    func text(for id: UUID) -> String? {
        try? storedText(for: id)
    }
}

enum SnippetSecretError: Error, Equatable {
    case keychain(OSStatus)
    /// The Keychain listed its items in a shape `KeychainSnippetSecretStore.itemIDs(inListing:)` can't read.
    case unreadableListing
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
/// text, and a sensitive snippet it deletes leaves the installed app's item behind. Nothing removes
/// items by inference (`SnippetStore`), so that item stays until it's removed in Keychain Access.
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
        attributes[kSecAttrSynchronizable as String] = false
        return attributes
    }

    func storedText(for id: UUID) throws -> String? {
        var query = query(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SnippetSecretError.keychain(status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
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

    /// Lists every item's attributes, never its data.
    var itemListQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
    }

    func itemIDs() throws -> Set<UUID> {
        var result: AnyObject?
        let status = SecItemCopyMatching(itemListQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SnippetSecretError.keychain(status) }
        return try Self.itemIDs(inListing: result)
    }

    /// Reads `itemListQuery`'s result: an array of attribute dictionaries, each with the account
    /// `query(for:)` writes. Any other shape, or an item without a text account, throws, so an
    /// import can't go ahead without knowing (`SnippetStore.importSnippets`). An account that isn't
    /// a UUID is skipped: Keybumps never writes one, and it can't match a snippet's ID.
    static func itemIDs(inListing result: Any?) throws -> Set<UUID> {
        guard let items = result as? [[String: Any]] else { throw SnippetSecretError.unreadableListing }
        return try Set(items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else {
                throw SnippetSecretError.unreadableListing
            }
            return UUID(uuidString: account)
        })
    }
}

/// Sensitive snippet text held only in memory: for unit tests and UI tests.
final class InMemorySnippetSecretStore: SnippetSecretStoring {
    private(set) var texts: [UUID: String] = [:]
    /// Makes the next `setText` fail, as a locked or unavailable Keychain would.
    var failsNextWrite = false
    /// Makes the next `removeText` fail.
    var failsNextRemoval = false
    /// Makes the next `itemIDs` fail.
    var failsNextListing = false
    /// IDs whose items can't be written or removed, as items the Keychain won't let this app change.
    var refusedIDs: Set<UUID> = []
    /// IDs whose items can't be read, as a locked Keychain or a denied access prompt would refuse.
    var unreadableIDs: Set<UUID> = []
    /// How many items were ever removed, so tests can prove nothing was removed behind the user's back.
    private(set) var removals = 0

    init(_ texts: [UUID: String] = [:]) {
        self.texts = texts
    }

    /// How many times a text was read, so tests can prove a save didn't need it.
    private(set) var reads = 0

    func storedText(for id: UUID) throws -> String? {
        reads += 1
        if unreadableIDs.contains(id) { throw SnippetSecretError.keychain(errSecInteractionNotAllowed) }
        return texts[id]
    }

    func setText(_ text: String, for id: UUID) throws {
        if failsNextWrite {
            failsNextWrite = false
            throw SnippetSecretError.keychain(errSecInteractionNotAllowed)
        }
        if refusedIDs.contains(id) { throw SnippetSecretError.keychain(errSecInteractionNotAllowed) }
        texts[id] = text
    }

    func removeText(for id: UUID) throws {
        if failsNextRemoval {
            failsNextRemoval = false
            throw SnippetSecretError.keychain(errSecInteractionNotAllowed)
        }
        if refusedIDs.contains(id) { throw SnippetSecretError.keychain(errSecInteractionNotAllowed) }
        if texts[id] != nil { removals += 1 }
        texts[id] = nil
    }

    func itemIDs() throws -> Set<UUID> {
        if failsNextListing {
            failsNextListing = false
            throw SnippetSecretError.keychain(errSecInteractionNotAllowed)
        }
        return Set(texts.keys)
    }

    /// Loses an item behind the store's back, as a Keychain the user edited would.
    func removeTextForTesting(_ id: UUID) {
        texts[id] = nil
    }
}
