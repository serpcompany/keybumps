import Foundation

/// What Polar says about a granted key's dates: its own expiry, when it was granted (`created_at`),
/// and the last day its customer's renewals paid for (`keybumps_updates_until` metadata, ADR 0011).
struct LicenseKeyDates: Equatable, Sendable {
    var expiresAt: Date?
    var purchasedAt: Date?
    /// Nil when the customer has no renewal.
    var renewedThrough: Date?
    /// Whether the answer carried readable customer metadata, so a nil `renewedThrough` means no
    /// renewal (one refunded, say) rather than an answer Keybumps couldn't read.
    var readRenewals = false
}

struct LicenseActivation: Equatable, Sendable {
    var activationID: String
    var dates = LicenseKeyDates()
}

enum LicenseValidation: Equatable, Sendable {
    case granted(LicenseKeyDates)
    /// Revoked or refunded, disabled, expired, unknown, or this activation removed. Polar answers
    /// all of these with 404, so they can't be told apart.
    case notAccepted
}

/// The license provider seam. Polar is the only implementation (ADR 0002); another provider is
/// another conformance plus an app update.
protocol LicenseProviding: Sendable {
    /// Throws `LicenseActionError`.
    func activate(key: String, label: String) async throws -> LicenseActivation
    /// Throws `LicenseActionError.network` (or `.unexpected`) when the answer is unknown.
    func validate(key: String, activationID: String) async throws -> LicenseValidation
    /// Succeeds when the activation is gone, including when it was already removed.
    func deactivate(key: String, activationID: String) async throws
}

protocol LicenseHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionLicenseHTTPClient: LicenseHTTPClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenseActionError.unexpected }
        return (data, http)
    }
}

/// Polar's public customer-portal license-key API. It needs the organization id and the key, and no secret.
struct PolarLicenseProvider: LicenseProviding {
    /// SERP's Polar organization. Public; it appears in every customer-portal request.
    static let organizationID = "e6922794-2041-4804-a7ad-6ffa1abc1048"
    static let baseURL = URL(string: "https://api.polar.sh")!

    let organizationID: String
    let baseURL: URL
    let http: any LicenseHTTPClient

    init(
        organizationID: String = PolarLicenseProvider.organizationID,
        baseURL: URL = PolarLicenseProvider.baseURL,
        http: any LicenseHTTPClient = URLSessionLicenseHTTPClient()
    ) {
        self.organizationID = organizationID
        self.baseURL = baseURL
        self.http = http
    }

    func activate(key: String, label: String) async throws -> LicenseActivation {
        let (data, response) = try await post("activate", ["key": key, "organization_id": organizationID, "label": label])
        switch response.statusCode {
        case 200:
            let body = try decode(ActivationBody.self, from: data)
            return LicenseActivation(activationID: body.id, dates: body.licenseKey.dates)
        case 404, 422: throw LicenseActionError.invalidKey
        case 403: throw LicenseActionError.notPermitted
        default: throw LicenseActionError.unexpected
        }
    }

    func validate(key: String, activationID: String) async throws -> LicenseValidation {
        let (data, response) = try await post(
            "validate", ["key": key, "organization_id": organizationID, "activation_id": activationID]
        )
        switch response.statusCode {
        case 200:
            let body = try decode(KeyBody.self, from: data)
            guard let status = body.status else { throw LicenseActionError.unexpected }
            return status == "granted" ? .granted(body.dates) : .notAccepted
        case 404: return .notAccepted
        default: throw LicenseActionError.unexpected
        }
    }

    func deactivate(key: String, activationID: String) async throws {
        let (_, response) = try await post(
            "deactivate", ["key": key, "organization_id": organizationID, "activation_id": activationID]
        )
        guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
            throw LicenseActionError.unexpected
        }
    }

    private func post(_ action: String, _ body: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: "v1/customer-portal/license-keys/\(action)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            return try await http.send(request)
        } catch let error as LicenseActionError {
            throw error
        } catch {
            throw LicenseActionError.network
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LicenseActionError.unexpected
        }
    }

    private struct ActivationBody: Decodable {
        let id: String
        let licenseKey: KeyBody
        enum CodingKeys: String, CodingKey { case id, licenseKey = "license_key" }
    }

    /// The key in a validate answer, or in an activate answer's `license_key`. A date Keybumps can't
    /// read counts as unknown rather than failing the check; validation needs `status`.
    private struct KeyBody: Decodable {
        let status: String?
        var dates: LicenseKeyDates

        private enum CodingKeys: String, CodingKey { case status, expiresAt = "expires_at", createdAt = "created_at", customer }
        private enum CustomerKeys: String, CodingKey { case metadata }
        private enum MetadataKeys: String, CodingKey { case updatesUntil = "keybumps_updates_until" }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            dates = LicenseKeyDates(
                expiresAt: (try? container.decodeIfPresent(String.self, forKey: .expiresAt)).flatMap(PolarDates.parse),
                purchasedAt: (try? container.decodeIfPresent(String.self, forKey: .createdAt)).flatMap(PolarDates.parse)
            )
            // No metadata, or a renewal date that isn't one, leaves the renewal unknown.
            guard let metadata = try? container.nestedContainer(keyedBy: CustomerKeys.self, forKey: .customer)
                .nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata) else { return }
            guard metadata.contains(.updatesUntil) else {
                dates.readRenewals = true
                return
            }
            guard let value = try? metadata.decode(String.self, forKey: .updatesUntil),
                  let day = UpdateYear.day(value) else { return }
            dates.renewedThrough = day
            dates.readRenewals = true
        }
    }
}

enum PolarDates {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
