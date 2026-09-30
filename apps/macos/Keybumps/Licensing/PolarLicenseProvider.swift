import Foundation

struct LicenseActivation: Equatable, Sendable {
    var activationID: String
    var expiresAt: Date?
}

enum LicenseValidation: Equatable, Sendable {
    case granted(expiresAt: Date?)
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
            return LicenseActivation(activationID: body.id, expiresAt: body.licenseKey.expiresAt.flatMap(PolarDates.parse))
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
            let body = try decode(ValidationBody.self, from: data)
            return body.status == "granted"
                ? .granted(expiresAt: body.expiresAt.flatMap(PolarDates.parse))
                : .notAccepted
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
        struct Key: Decodable {
            let expiresAt: String?
            enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
        }
        let id: String
        let licenseKey: Key
        enum CodingKeys: String, CodingKey { case id, licenseKey = "license_key" }
    }

    private struct ValidationBody: Decodable {
        let status: String
        let expiresAt: String?
        enum CodingKeys: String, CodingKey { case status, expiresAt = "expires_at" }
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
