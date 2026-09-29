import Foundation

/// The single app-shell licensing seam (ADR 0002). Capability modules never read it; `AppModel`
/// starts them only while the snapshot is entitled.
@MainActor
protocol LicenseControlling: AnyObject {
    var snapshot: LicenseSnapshot { get }
    var onChange: ((LicenseSnapshot) -> Void)? { get set }
    func start()
    func activate(key: String) async
    func deactivate() async
    func refreshIfNeeded() async
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
    private var timer: Timer?
    private var started = false

    init(
        provider: any LicenseProviding,
        store: any LicenseStoring,
        device: any DeviceIdentifying,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.store = store
        self.device = device
        self.now = now
        snapshot = LicenseSnapshot(state: LicensePolicy.state(for: store.load(), now: now()))
    }

    func start() {
        guard !started else { return }
        started = true
        publishStoredState()
        Task { await refreshIfNeeded() }
        // Re-evaluate the offline allowance and refresh schedule a few times a day.
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshIfNeeded() }
        }
    }

    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !snapshot.isBusy else { return }
        snapshot.isBusy = true
        snapshot.lastError = nil
        defer { snapshot.isBusy = false }
        do {
            let activation = try await provider.activate(key: key, label: device.activationLabel)
            let check = LicenseCheck(
                key: key,
                activationID: activation.activationID,
                validatedAt: now(),
                expiresAt: activation.expiresAt
            )
            try store.save(check)
            snapshot.state = LicensePolicy.state(for: check, now: now())
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
            snapshot.state = .unlicensed
        } catch {
            // Keep the activation locally: the slot is only freed once the provider confirms.
            snapshot.lastError = (error as? LicenseActionError) ?? .unexpected
        }
    }

    func refreshIfNeeded() async {
        publishStoredState()
        guard var check = store.load() else { return }
        let lockedForCheck = snapshot.state == .locked(.needsCheck)
        guard lockedForCheck || LicensePolicy.needsRefresh(check, now: now()) else { return }
        let result: LicenseValidation
        do {
            result = try await provider.validate(key: check.key, activationID: check.activationID)
        } catch {
            return // Unknown answer: never change the current state.
        }
        switch result {
        case .granted(let expiresAt):
            check.validatedAt = now()
            check.expiresAt = expiresAt
            try? store.save(check)
            snapshot.state = LicensePolicy.state(for: check, now: now())
        case .revoked:
            snapshot.state = .locked(.revoked)
        case .notFound:
            store.clear()
            snapshot.state = .locked(.deactivated)
        }
    }

    /// Applies time-based rules (offline allowance, expiry) to the stored check without a network call.
    private func publishStoredState() {
        switch snapshot.state {
        case .locked(.revoked), .locked(.deactivated):
            return // Only a successful activation or check clears these.
        default:
            snapshot.state = LicensePolicy.state(for: store.load(), now: now())
        }
    }
}

@MainActor
enum LicenseControllerFactory {
    static func makeDefault() -> any LicenseControlling {
        LicenseController(
            provider: PolarLicenseProvider(),
            store: KeychainLicenseStore(),
            device: HardwareDeviceIdentity()
        )
    }
}

#if DEBUG
/// Test and UI-test compositions: a fixed license state with no Keychain or network access.
@MainActor
final class FixedLicenseController: LicenseControlling {
    private(set) var snapshot: LicenseSnapshot { didSet { onChange?(snapshot) } }
    var onChange: ((LicenseSnapshot) -> Void)?

    init(state: LicenseState = .active(FixedLicenseController.sampleCheck)) {
        snapshot = LicenseSnapshot(state: state)
    }

    static let sampleCheck = LicenseCheck(
        key: "KEYBUMPS-TEST-0000",
        activationID: "test-activation",
        validatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        expiresAt: nil
    )

    func start() {}
    func activate(key: String) async { snapshot.state = .active(Self.sampleCheck) }
    func deactivate() async { snapshot.state = .unlicensed }
    func refreshIfNeeded() async {}
}
#endif
