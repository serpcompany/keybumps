import AppKit

/// The single app-shell licensing seam (ADR 0002). Capability modules never read it; `AppModel`
/// starts them only while the snapshot is entitled.
@MainActor
protocol LicenseControlling: AnyObject {
    var snapshot: LicenseSnapshot { get }
    var onChange: ((LicenseSnapshot) -> Void)? { get set }
    func start()
    func activate(key: String) async
    func deactivate() async
    /// Checks with the provider when one is due, or always when `force` is true (the "Check Again" button).
    func refresh(force: Bool) async
}

@MainActor
final class LicenseController: LicenseControlling {
    private(set) var snapshot: LicenseSnapshot {
        didSet { if snapshot != oldValue { onChange?(snapshot) } }
    }
    var onChange: ((LicenseSnapshot) -> Void)?

    private let provider: any LicenseProviding
    private let store: any LicenseStoring
    private let device: any DeviceIdentifying
    private let now: () -> Date
    /// This build's release date, which the update year is checked against (ADR 0011).
    private let releaseDate: Date?
    /// Replaces the stored license's update year, in QA candidates only (`UpdateYearTest`).
    private let testUpdateYear: UpdateYear?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var started = false

    init(
        provider: any LicenseProviding,
        store: any LicenseStoring,
        device: any DeviceIdentifying,
        now: @escaping () -> Date = Date.init,
        releaseDate: Date? = nil,
        testUpdateYear: UpdateYear? = nil
    ) {
        self.provider = provider
        self.store = store
        self.device = device
        self.now = now
        self.releaseDate = releaseDate
        self.testUpdateYear = testUpdateYear
        snapshot = LicenseSnapshot(state: .unlicensed)
        applyStoredCheck()
    }

    func start() {
        guard !started else { return }
        started = true
        applyStoredCheck()
        let force = LicensePolicy.needsUpdateYear(store.load())
        Task { await refresh(force: force) }
        // Re-evaluate hourly; a check runs once the daily refresh interval has passed.
        timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: false) }
        }
        timer?.tolerance = 300
        // A Mac waking from sleep checks right away if one is due, instead of waiting for the timer.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The network usually isn't back the instant the Mac wakes; a failed check changes nothing.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                await self?.refresh(force: false)
            }
        }
    }

    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !snapshot.isBusy else { return }
        snapshot.isBusy = true
        snapshot.lastError = nil
        defer { snapshot.isBusy = false }
        let label = device.activationLabel
        do {
            let activation = try await provider.activate(key: key, label: label)
            let check = LicenseCheck(
                key: key,
                activationID: activation.activationID,
                validatedAt: now(),
                expiresAt: activation.dates.expiresAt,
                deviceLabel: label,
                purchasedAt: activation.dates.purchasedAt,
                renewedThrough: activation.dates.renewedThrough
            )
            do {
                try store.save(check)
            } catch {
                // Don't leave a used activation slot that this Mac can't remember.
                try? await provider.deactivate(key: key, activationID: activation.activationID)
                throw LicenseActionError.unexpected
            }
            applyStoredCheck()
        } catch {
            snapshot.lastError = (error as? LicenseActionError) ?? .unexpected
        }
    }

    func deactivate() async {
        guard let check = store.load(), !snapshot.isBusy else { return }
        snapshot.isBusy = true
        snapshot.lastError = nil
        defer { snapshot.isBusy = false }
        do {
            try await provider.deactivate(key: check.key, activationID: check.activationID)
            store.clear()
            applyStoredCheck()
        } catch {
            // Keep the activation locally: the slot is only freed once the provider confirms.
            snapshot.lastError = (error as? LicenseActionError) ?? .unexpected
        }
    }

    func refresh(force: Bool) async {
        guard !snapshot.isBusy else { return }
        applyStoredCheck()
        guard var check = store.load(), snapshot.state != .unlicensed else { return }
        let locked = !snapshot.isEntitled
        guard force || locked || LicensePolicy.needsRefresh(check, now: now()) else { return }
        snapshot.isBusy = true
        defer { snapshot.isBusy = false }
        let result: LicenseValidation
        do {
            result = try await provider.validate(key: check.key, activationID: check.activationID)
        } catch {
            return // Unknown answer: never change the current state.
        }
        // A deactivate or re-activation replaced the stored check while this ran; ignore the stale answer.
        guard store.load()?.activationID == check.activationID else { return }
        switch result {
        case .granted(let dates):
            check.validatedAt = now()
            check.expiresAt = dates.expiresAt
            // The purchase date never changes, so an answer without it keeps the one known.
            check.purchasedAt = dates.purchasedAt ?? check.purchasedAt
            // Renewals can go down, when one is refunded, but an answer Keybumps couldn't read
            // them from keeps the date known.
            if dates.readRenewals { check.renewedThrough = dates.renewedThrough }
            check.notAccepted = nil
        case .notAccepted:
            check.notAccepted = true
        }
        try? store.save(check)
        applyStoredCheck()
    }

    /// Applies the stored check's refusal, time, device, and update-year rules, with no network call.
    private func applyStoredCheck() {
        let check = store.load()
        var next = snapshot
        next.state = LicensePolicy.state(
            for: check, now: now(), deviceLabel: device.activationLabel,
            releaseDate: releaseDate, updateYear: testUpdateYear
        )
        next.updateYear = next.state == .unlicensed ? nil : testUpdateYear ?? check?.updateYear
        snapshot = next
    }
}

@MainActor
enum LicenseControllerFactory {
    static func makeDefault() -> any LicenseControlling {
        LicenseController(
            provider: PolarLicenseProvider(),
            store: KeychainLicenseStore(),
            device: HardwareDeviceIdentity(),
            releaseDate: UpdateYearTest.releaseDate ?? BuildRelease.date(),
            testUpdateYear: UpdateYearTest.updateYear
        )
    }
}

/// QA candidates (`-dev.` versions) and Debug builds only: `-KBTestUpdateYearEnd 2026-10-01` ends
/// the license's update year on that day, and `-KBTestReleaseDate 2026-10-19` dates this build, so a
/// candidate shows an ended update year, or Locks as a newer build installed by hand (ADR 0011).
enum UpdateYearTest {
    static var updateYear: UpdateYear? {
        value(for: "KBTestUpdateYearEnd").flatMap(UpdateYear.day).map(UpdateYear.init(lastDay:))
    }

    static var releaseDate: Date? {
        value(for: "KBTestReleaseDate").flatMap(UpdateYear.day)
    }

    private static func value(for key: String, defaults: UserDefaults = .standard, bundle: Bundle = .main) -> String? {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard UpdatePreview.isAllowed(version: version) else { return nil }
        return defaults.string(forKey: key)
    }
}

#if DEBUG
/// Test and UI-test compositions: a fixed license state with no Keychain or network access.
@MainActor
final class FixedLicenseController: LicenseControlling {
    private(set) var snapshot: LicenseSnapshot { didSet { onChange?(snapshot) } }
    var onChange: ((LicenseSnapshot) -> Void)?

    init(state: LicenseState = .active(FixedLicenseController.sampleCheck), updateYear: UpdateYear? = nil) {
        snapshot = LicenseSnapshot(state: state, updateYear: updateYear)
    }

    nonisolated static let sampleCheck = LicenseCheck(
        key: "KEYBUMPS-TEST-0000",
        activationID: "test-activation",
        validatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        expiresAt: nil
    )

    func start() {}
    func activate(key: String) async { snapshot.state = .active(Self.sampleCheck) }
    func deactivate() async { snapshot = LicenseSnapshot(state: .unlicensed) }
    func refresh(force: Bool) async {}
}
#endif
