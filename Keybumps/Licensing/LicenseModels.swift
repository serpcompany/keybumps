import Foundation

/// The app's cached result of its last successful license validation (the License Check).
/// See `docs/adr/0002-polar-native-license-keys.md`.
struct LicenseCheck: Codable, Equatable, Sendable {
    var key: String
    var activationID: String
    var validatedAt: Date
    var expiresAt: Date?
    /// The activation label of the Mac that activated. A check restored onto another Mac (for
    /// example by Migration Assistant copying the login keychain) doesn't count there.
    var deviceLabel: String?
    /// The provider refused this key and activation at the last check. Persisted, so relaunching
    /// can't undo a refund; cleared by the next successful check or activation.
    var notAccepted: Bool?

    /// The key with only its last four characters visible, for display.
    var maskedKey: String {
        let suffix = key.suffix(4)
        return key.count > 4 ? "••••\(suffix)" : String(key)
    }
}

/// Why Keybumps is Locked.
enum LicenseLockReason: Equatable, Sendable {
    /// The provider no longer accepts this key and activation: revoked or refunded, disabled, or
    /// this Mac deactivated elsewhere (Polar reports all of these the same way). The stored check
    /// is kept, so a later successful check unlocks it again.
    case notAccepted
    /// The license's own expiry date has passed.
    case expired
    /// No successful check within the offline allowance; one successful check unlocks it.
    case needsCheck
}

enum LicenseState: Equatable, Sendable {
    /// No key has been activated on this Mac.
    case unlicensed
    case active(LicenseCheck)
    case locked(LicenseLockReason)

    var isEntitled: Bool {
        if case .active = self { return true }
        return false
    }
}

/// A failed user action (activate or deactivate). Checks never surface errors; they keep the current state.
enum LicenseActionError: Error, Equatable, Sendable {
    case invalidKey
    /// The key is revoked, disabled, expired, or already active on another Mac.
    case notPermitted
    case network
    case unexpected

    var message: String {
        switch self {
        case .invalidKey:
            return "That license key wasn’t found. Check it against your Polar receipt."
        case .notPermitted:
            return "This key can’t be activated here. It may already be active on another Mac; deactivate it there or in the customer portal."
        case .network:
            return "Keybumps couldn’t reach the license server. Check your connection and try again."
        case .unexpected:
            return "Something went wrong activating the license. Try again, or contact support@keybumps.app."
        }
    }
}

struct LicenseSnapshot: Equatable, Sendable {
    var state: LicenseState
    var isBusy = false
    var lastError: LicenseActionError?

    var isEntitled: Bool { state.isEntitled }
}

/// Timing rules from ADR 0002.
enum LicensePolicy {
    /// Hourly, so a revoked or refunded key locks within about an hour online.
    static let refreshInterval: TimeInterval = 3_600
    static let offlineAllowance: TimeInterval = 45 * 86_400

    static func state(for check: LicenseCheck?, now: Date, deviceLabel: String? = nil) -> LicenseState {
        guard let check else { return .unlicensed }
        if let deviceLabel, let owner = check.deviceLabel, owner != deviceLabel { return .unlicensed }
        if check.notAccepted == true { return .locked(.notAccepted) }
        if let expiresAt = check.expiresAt, expiresAt <= now { return .locked(.expired) }
        // A clock set earlier than the last check makes `needsRefresh` true, so the next online
        // moment checks again. While offline it can stretch the allowance; that is accepted with no DRM.
        let age = now.timeIntervalSince(check.validatedAt)
        if age > offlineAllowance { return .locked(.needsCheck) }
        return .active(check)
    }

    static func needsRefresh(_ check: LicenseCheck, now: Date) -> Bool {
        let age = now.timeIntervalSince(check.validatedAt)
        return age >= refreshInterval || age < 0
    }
}

/// Public links shown on the License page.
enum LicenseLinks {
    static let buy = URL(string: "https://keybumps.app/pricing")!
    static let customerPortal = URL(string: "https://polar.sh/serp/portal")!
}
