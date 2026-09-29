import Foundation
import Testing
@testable import Keybumps

// MARK: - Policy

@Suite("License policy")
struct LicensePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func check(validatedDaysAgo days: Double, expiresAt: Date? = nil) -> LicenseCheck {
        LicenseCheck(key: "KEYBUMPS-ABCD", activationID: "a1", validatedAt: now.addingTimeInterval(-days * 86_400), expiresAt: expiresAt)
    }

    @Test("No check is unlicensed; a recent check is active")
    func activeWithinAllowance() {
        #expect(LicensePolicy.state(for: nil, now: now) == .unlicensed)
        let recent = check(validatedDaysAgo: 44)
        #expect(LicensePolicy.state(for: recent, now: now) == .active(recent))
    }

    @Test("More than 45 days without a check locks until one succeeds")
    func offlineAllowance() {
        #expect(LicensePolicy.state(for: check(validatedDaysAgo: 46), now: now) == .locked(.needsCheck))
    }

    @Test("A passed expiry date locks")
    func expiry() {
        #expect(LicensePolicy.state(for: check(validatedDaysAgo: 1, expiresAt: now), now: now) == .locked(.expired))
    }

    @Test("Refresh is due after a week, or when the clock moved backwards")
    func refreshSchedule() {
        #expect(!LicensePolicy.needsRefresh(check(validatedDaysAgo: 6), now: now))
        #expect(LicensePolicy.needsRefresh(check(validatedDaysAgo: 7), now: now))
        #expect(LicensePolicy.needsRefresh(check(validatedDaysAgo: -1), now: now))
    }

    @Test("Keys display with only their last four characters")
    func maskedKey() {
        #expect(check(validatedDaysAgo: 0).maskedKey == "••••ABCD")
    }
}

// MARK: - Polar provider

private final class RecordingHTTPClient: LicenseHTTPClient, @unchecked Sendable {
    var responses: [(Int, String)] = []
    var failWith: Error?
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failWith { throw failWith }
        let (status, body) = responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func body(_ index: Int) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())) as? [String: String] ?? [:]
    }
}

@Suite("Polar license provider")
struct PolarLicenseProviderTests {
    private func provider(_ http: RecordingHTTPClient) -> PolarLicenseProvider {
        PolarLicenseProvider(organizationID: "org-1", baseURL: URL(string: "https://polar.test")!, http: http)
    }

    @Test("Activation posts the key, organization, and label, and reads the activation")
    func activate() async throws {
        let http = RecordingHTTPClient()
        http.responses = [(200, #"{"id":"act-1","license_key":{"status":"granted","expires_at":"2027-01-02T03:04:05.123Z"}}"#)]
        let activation = try await provider(http).activate(key: "KEYBUMPS-1", label: "mac-abc")
        #expect(activation.activationID == "act-1")
        #expect(activation.expiresAt == PolarDates.parse("2027-01-02T03:04:05.123Z"))
        #expect(http.requests[0].url?.absoluteString == "https://polar.test/v1/customer-portal/license-keys/activate")
        #expect(http.requests[0].httpMethod == "POST")
        #expect(http.body(0) == ["key": "KEYBUMPS-1", "organization_id": "org-1", "label": "mac-abc"])
    }

    @Test("Activation maps Polar's errors", arguments: [
        (404, LicenseActionError.invalidKey), (403, .notPermitted), (500, .unexpected),
    ])
    func activationErrors(status: Int, expected: LicenseActionError) async {
        let http = RecordingHTTPClient()
        http.responses = [(status, #"{"error":"x"}"#)]
        await #expect(throws: expected) { try await provider(http).activate(key: "K", label: "L") }
    }

    @Test("A transport failure is a network error")
    func networkError() async {
        let http = RecordingHTTPClient()
        http.failWith = URLError(.notConnectedToInternet)
        await #expect(throws: LicenseActionError.network) { try await provider(http).activate(key: "K", label: "L") }
    }

    @Test("Validation: 200 granted is accepted; Polar's 404 (revoked, refunded, removed) is not")
    func validate() async throws {
        let http = RecordingHTTPClient()
        http.responses = [
            (200, #"{"status":"granted","expires_at":null}"#),
            (404, #"{"error":"ResourceNotFound"}"#),
            (200, #"{"status":"revoked","expires_at":null}"#),
            (500, ""),
        ]
        let polar = provider(http)
        #expect(try await polar.validate(key: "K", activationID: "A") == .granted(expiresAt: nil))
        #expect(try await polar.validate(key: "K", activationID: "A") == .notAccepted)
        #expect(try await polar.validate(key: "K", activationID: "A") == .notAccepted)
        await #expect(throws: LicenseActionError.unexpected) { try await polar.validate(key: "K", activationID: "A") }
        #expect(http.body(0) == ["key": "K", "organization_id": "org-1", "activation_id": "A"])
    }

    @Test("Deactivation succeeds when removed or already gone")
    func deactivate() async throws {
        let http = RecordingHTTPClient()
        http.responses = [(204, ""), (404, #"{"error":"ResourceNotFound"}"#), (500, "")]
        let polar = provider(http)
        try await polar.deactivate(key: "K", activationID: "A")
        try await polar.deactivate(key: "K", activationID: "A")
        await #expect(throws: LicenseActionError.unexpected) { try await polar.deactivate(key: "K", activationID: "A") }
    }
}

// MARK: - Controller

private final class FakeProvider: LicenseProviding, @unchecked Sendable {
    var activation: Result<LicenseActivation, LicenseActionError> = .success(LicenseActivation(activationID: "act-1", expiresAt: nil))
    var validation: Result<LicenseValidation, LicenseActionError> = .success(.granted(expiresAt: nil))
    var deactivation: Result<Void, LicenseActionError> = .success(())
    private(set) var activatedLabels: [String] = []
    private(set) var validations = 0

    func activate(key: String, label: String) async throws -> LicenseActivation {
        activatedLabels.append(label)
        return try activation.get()
    }
    func validate(key: String, activationID: String) async throws -> LicenseValidation {
        validations += 1
        return try validation.get()
    }
    private(set) var deactivations = 0
    func deactivate(key: String, activationID: String) async throws {
        deactivations += 1
        try deactivation.get()
    }
}

private final class FailingStore: LicenseStoring {
    func load() -> LicenseCheck? { nil }
    func save(_ check: LicenseCheck) throws { throw LicenseActionError.unexpected }
    func clear() {}
}

private struct FakeDevice: DeviceIdentifying { let activationLabel = "mac-test" }

@MainActor
@Suite("License controller")
struct LicenseControllerTests {
    private final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    private func make(store: InMemoryLicenseStore = InMemoryLicenseStore(), provider: FakeProvider = FakeProvider(), clock: Clock = Clock())
        -> (LicenseController, InMemoryLicenseStore, FakeProvider, Clock) {
        (LicenseController(provider: provider, store: store, device: FakeDevice(), now: { clock.now }), store, provider, clock)
    }

    @Test("Activating stores the check and becomes active")
    func activate() async {
        let (controller, store, provider, clock) = make()
        #expect(controller.snapshot.state == .unlicensed)
        await controller.activate(key: "  KEYBUMPS-1 \n")
        let check = LicenseCheck(key: "KEYBUMPS-1", activationID: "act-1", validatedAt: clock.now, expiresAt: nil, deviceLabel: "mac-test")
        #expect(store.check == check)
        #expect(controller.snapshot.state == .active(check))
        #expect(provider.activatedLabels == ["mac-test"])
    }

    @Test("A failed activation reports the error and stays unlicensed")
    func activationFailure() async {
        let provider = FakeProvider()
        provider.activation = .failure(.notPermitted)
        let (controller, store, _, _) = make(provider: provider)
        await controller.activate(key: "KEYBUMPS-1")
        #expect(controller.snapshot.state == .unlicensed)
        #expect(controller.snapshot.lastError == .notPermitted)
        #expect(store.check == nil)
    }

    @Test("No check runs within the refresh interval")
    func noEarlyRefresh() async {
        let clock = Clock()
        let store = InMemoryLicenseStore(LicenseCheck(key: "K", activationID: "A", validatedAt: clock.now, expiresAt: nil))
        let (controller, _, provider, _) = make(store: store, clock: clock)
        clock.now.addTimeInterval(6 * 86_400)
        await controller.refresh(force: false)
        #expect(provider.validations == 0)
    }

    @Test("A weekly check renews the license")
    func refreshRenews() async {
        let clock = Clock()
        let store = InMemoryLicenseStore(LicenseCheck(key: "K", activationID: "A", validatedAt: clock.now, expiresAt: nil))
        let (controller, _, provider, _) = make(store: store, clock: clock)
        clock.now.addTimeInterval(8 * 86_400)
        await controller.refresh(force: false)
        #expect(provider.validations == 1)
        #expect(store.check?.validatedAt == clock.now)
        #expect(controller.snapshot.isEntitled)
    }

    @Test("A refusal locks but keeps the key, and a later success unlocks")
    func refusalRecovers() async {
        let clock = Clock()
        let original = LicenseCheck(key: "K", activationID: "A", validatedAt: clock.now, expiresAt: nil)
        let provider = FakeProvider()
        provider.validation = .success(.notAccepted)
        let store = InMemoryLicenseStore(original)
        let (controller, _, _, _) = make(store: store, provider: provider, clock: clock)
        clock.now.addTimeInterval(8 * 86_400)
        await controller.refresh(force: false)
        #expect(controller.snapshot.state == .locked(.notAccepted))
        #expect(store.check == original)

        provider.validation = .success(.granted(expiresAt: nil))
        await controller.refresh(force: false)
        #expect(controller.snapshot.isEntitled)
    }

    @Test("Check Again validates even when no check is due")
    func forcedCheck() async {
        let clock = Clock()
        let store = InMemoryLicenseStore(LicenseCheck(key: "K", activationID: "A", validatedAt: clock.now, expiresAt: nil))
        let (controller, _, provider, _) = make(store: store, clock: clock)
        await controller.refresh(force: true)
        #expect(provider.validations == 1)
    }

    @Test("A check restored onto another Mac doesn't count there")
    func otherMac() {
        let store = InMemoryLicenseStore(LicenseCheck(
            key: "K", activationID: "A", validatedAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: nil, deviceLabel: "mac-other"
        ))
        let (controller, _, _, _) = make(store: store)
        #expect(controller.snapshot.state == .unlicensed)
    }

    @Test("If the activation can't be saved, its slot is freed")
    func saveFailureFreesSlot() async {
        let provider = FakeProvider()
        let controller = LicenseController(provider: provider, store: FailingStore(), device: FakeDevice())
        await controller.activate(key: "KEYBUMPS-1")
        #expect(controller.snapshot.lastError == .unexpected)
        #expect(provider.deactivations == 1)
        #expect(controller.snapshot.state == .unlicensed)
    }

    @Test("A network failure never changes the state; past the allowance, one success unlocks")
    func offline() async {
        let clock = Clock()
        let store = InMemoryLicenseStore(LicenseCheck(key: "K", activationID: "A", validatedAt: clock.now, expiresAt: nil))
        let provider = FakeProvider()
        provider.validation = .failure(.network)
        let (controller, _, _, _) = make(store: store, provider: provider, clock: clock)
        clock.now.addTimeInterval(10 * 86_400)
        await controller.refresh(force: false)
        #expect(controller.snapshot.isEntitled)

        clock.now.addTimeInterval(40 * 86_400)
        await controller.refresh(force: false)
        #expect(controller.snapshot.state == .locked(.needsCheck))

        provider.validation = .success(.granted(expiresAt: nil))
        await controller.refresh(force: false)
        #expect(controller.snapshot.isEntitled)
    }

    @Test("Deactivating frees the slot; if it fails, the activation stays")
    func deactivate() async {
        let clock = Clock()
        let original = LicenseCheck(key: "K", activationID: "A", validatedAt: clock.now, expiresAt: nil)
        let provider = FakeProvider()
        provider.deactivation = .failure(.network)
        let store = InMemoryLicenseStore(original)
        let (controller, _, _, _) = make(store: store, provider: provider, clock: clock)
        await controller.deactivate()
        #expect(controller.snapshot.isEntitled)
        #expect(controller.snapshot.lastError == .network)
        #expect(store.check == original)

        provider.deactivation = .success(())
        await controller.deactivate()
        #expect(controller.snapshot.state == .unlicensed)
        #expect(store.check == nil)
    }
}

// MARK: - Launch arguments

@Suite("License launch argument")
struct LicenseLaunchArgumentTests {
    @Test("UI tests default to active and accept unlicensed and revoked")
    func parsing() {
        #expect(UITestLaunchConfiguration(arguments: ["-KBUITestPermissions", "granted"]).licenseState == .active)
        #expect(UITestLaunchConfiguration(arguments: ["-KBUITestPermissions", "granted", "-KBLicenseState", "unlicensed"]).licenseState == .unlicensed)
        #expect(UITestLaunchConfiguration(arguments: ["-KBUITestPermissions", "granted", "-KBLicenseState", "revoked"]).licenseState == .revoked)
        #expect(UITestLaunchConfiguration(arguments: ["-KBLicenseState", "unlicensed"]).licenseState == .active)
    }
}
