//
//  LemonSqueezyClient.swift
//  SideCast
//
//  LemonSqueezy License API (https://docs.lemonsqueezy.com/api/license-api): activate, validate
//  and deactivate a license key for this Mac. These endpoints need no API key.
//

#if os(macOS)
import Foundation

struct LicensingConfig: Sendable {
    /// LemonSqueezy store and product the license must belong to. Fill in before release.
    var storeID: Int?
    var productIDs: Set<Int>
    /// Web checkout page for buying SideCast Premium.
    var checkoutURL: URL?

    var isConfigured: Bool { storeID != nil && !productIDs.isEmpty }

    /// TODO: set from the LemonSqueezy dashboard (Store ID, Product ID, checkout link).
    static let production = LicensingConfig(storeID: nil, productIDs: [], checkoutURL: nil)
}

enum LicenseError: Error, Equatable {
    case notConfigured
    case rejected(String)
    case wrongProduct
    case network(String)
}

struct LicenseMeta: Decodable, Equatable {
    let storeID: Int
    let productID: Int
    let productName: String?

    enum CodingKeys: String, CodingKey {
        case storeID = "store_id"
        case productID = "product_id"
        case productName = "product_name"
    }
}

struct LicenseKeyInfo: Decodable, Equatable {
    let status: String
}

struct LicenseInstance: Decodable, Equatable {
    let id: String
}

struct LicenseResponse: Decodable {
    let activated: Bool?
    let valid: Bool?
    let deactivated: Bool?
    let error: String?
    let licenseKey: LicenseKeyInfo?
    let instance: LicenseInstance?
    let meta: LicenseMeta?

    enum CodingKeys: String, CodingKey {
        case activated, valid, deactivated, error, instance, meta
        case licenseKey = "license_key"
    }
}

struct LemonSqueezyClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let baseURL = URL(string: "https://api.lemonsqueezy.com/v1/licenses/")!

    let config: LicensingConfig
    var transport: Transport = { request in try await URLSession.shared.data(for: request) }

    /// Activates the key for this Mac; returns the instance ID.
    func activate(key: String, instanceName: String) async throws -> String {
        let response = try await post("activate", ["license_key": key, "instance_name": instanceName])
        guard response.activated == true, let instance = response.instance else {
            throw LicenseError.rejected(response.error ?? "")
        }
        try checkProduct(response.meta)
        return instance.id
    }

    /// Returns true if the key is still valid for this instance.
    func validate(key: String, instanceID: String) async throws -> Bool {
        let response = try await post("validate", ["license_key": key, "instance_id": instanceID])
        guard response.valid == true else { return false }
        try checkProduct(response.meta)
        return true
    }

    func deactivate(key: String, instanceID: String) async throws {
        _ = try await post("deactivate", ["license_key": key, "instance_id": instanceID])
    }

    /// application/x-www-form-urlencoded body; only unreserved characters stay unescaped.
    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { key, value in
                let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(escaped)"
            }
            .joined(separator: "&")
    }

    private func checkProduct(_ meta: LicenseMeta?) throws {
        guard let meta, meta.storeID == config.storeID, config.productIDs.contains(meta.productID) else {
            throw LicenseError.wrongProduct
        }
    }

    private func post(_ action: String, _ fields: [String: String]) async throws -> LicenseResponse {
        guard config.isConfigured else { throw LicenseError.notConfigured }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(action))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)
        request.timeoutInterval = 20

        let data: Data
        do {
            (data, _) = try await transport(request)
        } catch {
            throw LicenseError.network(error.localizedDescription)
        }
        guard let response = try? JSONDecoder().decode(LicenseResponse.self, from: data) else {
            throw LicenseError.network("Unexpected response")
        }
        return response
    }
}
#endif
