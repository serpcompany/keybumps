import CryptoKit
import Foundation
import IOKit
import Security

/// Where the License Check lives between launches.
protocol LicenseStoring: AnyObject {
    func load() -> LicenseCheck?
    func save(_ check: LicenseCheck) throws
    func clear()
}

/// Keychain storage: a generic-password item in the login keychain, protected by the user's login
/// password and the item's access list. It doesn't use the data protection keychain (that needs a
/// keychain-access-groups entitlement and provisioning profile), so the accessibility class set
/// below has no effect on macOS today. The service name follows the bundle identifier, so Debug
/// builds never touch the installed app's license.
final class KeychainLicenseStore: LicenseStoring {
    private let service: String
    private let account = "license-check"

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.serp.keybumps") {
        service = "\(bundleIdentifier).license"
    }

    func load() -> LicenseCheck? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(LicenseCheck.self, from: data)
    }

    func save(_ check: LicenseCheck) throws {
        let data = try JSONEncoder().encode(check)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(baseQuery as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LicenseActionError.unexpected }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class InMemoryLicenseStore: LicenseStoring {
    private(set) var check: LicenseCheck?
    init(_ check: LicenseCheck? = nil) { self.check = check }
    func load() -> LicenseCheck? { check }
    func save(_ check: LicenseCheck) throws { self.check = check }
    func clear() { check = nil }
}

/// The activation label sent to the provider: a one-way hash of this Mac's hardware UUID, never
/// the UUID itself, the Mac's name, or any other personal data.
protocol DeviceIdentifying {
    var activationLabel: String { get }
}

struct HardwareDeviceIdentity: DeviceIdentifying {
    var activationLabel: String {
        let uuid = Self.platformUUID() ?? "unknown"
        let digest = SHA256.hash(data: Data("keybumps-license:\(uuid)".utf8))
        return "mac-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}
