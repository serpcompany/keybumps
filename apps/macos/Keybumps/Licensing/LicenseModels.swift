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
    /// When Polar granted the key (its `created_at`), which the update year counts from (ADR 0011).
    /// Nil in a check stored before Keybumps read it.
    var purchasedAt: Date?
    /// The last day renewals paid for, from the Polar customer's `keybumps_updates_until` metadata.
    var renewedThrough: Date?

    /// The updates this license includes, once its purchase date is known.
    var updateYear: UpdateYear? { UpdateYear(purchasedAt: purchasedAt, renewedThrough: renewedThrough) }

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
    /// This build was released after the license's update year, so it was installed by hand: a
    /// renewal that covers it, or an earlier version, unlocks it (ADR 0011).
    case releasedAfterUpdateYear
}

/// The updates a license includes (ADR 0011): every release made on or before its last day. That's
/// the UTC day a year after the key was granted, or after 2026-10-19 for licenses bought before
/// then, unless renewals paid for a later one. The year ending never locks the version it covers.
struct UpdateYear: Equatable, Sendable {
    /// Licenses bought before this day get the updates released through a year after it.
    static let began = UpdateYear.day("2026-10-19")!
    /// The last day covered, at its start in UTC.
    let lastDay: Date

    init(lastDay: Date) {
        self.lastDay = Self.calendar.startOfDay(for: lastDay)
    }

    /// Nil until the purchase date is known; an unknown update year counts as covered.
    init?(purchasedAt: Date?, renewedThrough: Date?) {
        guard let purchasedAt,
              let firstYear = Self.calendar.date(byAdding: .year, value: 1, to: Self.calendar.startOfDay(for: max(purchasedAt, Self.began)))
        else { return nil }
        self.init(lastDay: max(firstYear, renewedThrough ?? firstYear))
    }

    /// When the last day is over.
    var end: Date { Self.calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay }

    func covers(releaseDate: Date) -> Bool { releaseDate < end }
    func hasEnded(at now: Date) -> Bool { now >= end }

    /// The last day as people read it, such as "Oct 19, 2027". The day is a UTC day, so it's shown
    /// in UTC, never as the day before in a time zone behind it.
    var lastDayText: String {
        lastDay.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    /// Days are UTC days.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// "2027-10-19" as the start of that UTC day; a full time counts as its UTC day.
    static func day(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .gmt
        if let date = formatter.date(from: value) { return date }
        return PolarDates.parse(value).map { calendar.startOfDay(for: $0) }
    }
}

/// When this build was released (`KBBuildReleaseDate`, which build-update-release.sh sets): the date
/// the license's update year is checked against (ADR 0011). Debug builds and QA candidates carry
/// none, so they always count as covered.
enum BuildRelease {
    static func date(bundle: Bundle = .main) -> Date? {
        (bundle.object(forInfoDictionaryKey: "KBBuildReleaseDate") as? String).flatMap(PolarDates.parse)
    }
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
    /// The stored license's update year, while it has one (ADR 0011).
    var updateYear: UpdateYear?
    var isBusy = false
    var lastError: LicenseActionError?

    var isEntitled: Bool { state.isEntitled }
}

/// Timing rules from ADR 0002.
enum LicensePolicy {
    /// Once a day (SERP native-app licensing standard): a revoked or refunded key locks within about
    /// a day online, or at once with Check Again.
    static let refreshInterval: TimeInterval = 86_400
    static let offlineAllowance: TimeInterval = 45 * 86_400

    /// `releaseDate` is this build's (`BuildRelease`); `updateYear` replaces the check's own, for
    /// QA candidates (`UpdateYearTest`).
    static func state(
        for check: LicenseCheck?,
        now: Date,
        deviceLabel: String? = nil,
        releaseDate: Date? = nil,
        updateYear: UpdateYear? = nil
    ) -> LicenseState {
        guard let check else { return .unlicensed }
        if let deviceLabel, let owner = check.deviceLabel, owner != deviceLabel { return .unlicensed }
        if check.notAccepted == true { return .locked(.notAccepted) }
        if let expiresAt = check.expiresAt, expiresAt <= now { return .locked(.expired) }
        // A clock set earlier than the last check makes `needsRefresh` true, so the next online
        // moment checks again. While offline it can stretch the allowance; that is accepted with no DRM.
        let age = now.timeIntervalSince(check.validatedAt)
        if age > offlineAllowance { return .locked(.needsCheck) }
        // Only a build released after the update year locks; the year ending never does (ADR 0011).
        if let releaseDate, let year = updateYear ?? check.updateYear, !year.covers(releaseDate: releaseDate) {
            return .locked(.releasedAfterUpdateYear)
        }
        return .active(check)
    }

    /// A check stored before Keybumps read the purchase date has no update year, so one runs at launch.
    static func needsUpdateYear(_ check: LicenseCheck?) -> Bool {
        check.map { $0.purchasedAt == nil } ?? false
    }

    static func needsRefresh(_ check: LicenseCheck, now: Date) -> Bool {
        let age = now.timeIntervalSince(check.validatedAt)
        return age >= refreshInterval || age < 0
    }
}

/// Public links shown on the License page.
enum LicenseLinks {
    static let buy = URL(string: "https://keybumps.app/pricing")!
    /// Where another year of updates is bought (ADR 0011).
    static let renew = URL(string: "https://keybumps.app/pricing")!
    static let customerPortal = URL(string: "https://polar.sh/serp/portal")!
}
