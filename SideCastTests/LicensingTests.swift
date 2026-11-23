//
//  LicensingTests.swift
//  SideCastTests
//

#if os(macOS)
import Foundation
import Testing
@testable import SideCast

/// Records requests and replies with canned JSON.
final class FakeLicenseServer: @unchecked Sendable {
    var responses: [String: String] = [:]
    var failNetwork = false
    private(set) var requests: [(action: String, body: String)] = []

    var transport: LemonSqueezyClient.Transport {
        { [self] request in
            let action = request.url!.lastPathComponent
            requests.append((action, String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
            if failNetwork { throw URLError(.notConnectedToInternet) }
            let body = responses[action] ?? #"{"error":"unknown"}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

let testConfig = LicensingConfig(storeID: 11, productIDs: [22], checkoutURL: nil)

func meta(store: Int = 11, product: Int = 22) -> String {
    #""meta":{"store_id":\#(store),"product_id":\#(product),"product_name":"SideCast Premium"}"#
}

struct LemonSqueezyClientTests {
    @Test func activateSendsFormAndReturnsInstance() async throws {
        let server = FakeLicenseServer()
        server.responses["activate"] = #"{"activated":true,"error":null,"license_key":{"status":"active"},"instance":{"id":"inst-1"},"# + meta() + "}"
        let client = LemonSqueezyClient(config: testConfig, transport: server.transport)
        let instance = try await client.activate(key: "ABC-123", instanceName: "Jun's Mac & Co")
        #expect(instance == "inst-1")
        #expect(server.requests.first?.action == "activate")
        #expect(server.requests.first?.body == "instance_name=Jun%27s%20Mac%20%26%20Co&license_key=ABC-123")
    }

    @Test func rejectsKeysForOtherProducts() async {
        let server = FakeLicenseServer()
        server.responses["activate"] = #"{"activated":true,"error":null,"license_key":{"status":"active"},"instance":{"id":"x"},"# + meta(product: 99) + "}"
        let client = LemonSqueezyClient(config: testConfig, transport: server.transport)
        await #expect(throws: LicenseError.wrongProduct) {
            _ = try await client.activate(key: "K", instanceName: "Mac")
        }
    }

    @Test func surfacesServerErrors() async {
        let server = FakeLicenseServer()
        server.responses["activate"] = #"{"activated":false,"error":"This license key has reached the activation limit."}"#
        let client = LemonSqueezyClient(config: testConfig, transport: server.transport)
        await #expect(throws: LicenseError.rejected("This license key has reached the activation limit.")) {
            _ = try await client.activate(key: "K", instanceName: "Mac")
        }
    }

    @Test func unconfiguredBuildRefuses() async {
        let client = LemonSqueezyClient(config: LicensingConfig(storeID: nil, productIDs: [], checkoutURL: nil))
        await #expect(throws: LicenseError.notConfigured) {
            _ = try await client.activate(key: "K", instanceName: "Mac")
        }
    }
}

@MainActor
struct LicenseManagerTests {
    let account = "license-test-\(UUID().uuidString)"

    @Test func activateRevalidateAndRevoke() async {
        defer { Keychain.delete(account) }
        let server = FakeLicenseServer()
        server.responses["activate"] = #"{"activated":true,"error":null,"license_key":{"status":"active"},"instance":{"id":"inst-1"},"# + meta() + "}"
        let client = LemonSqueezyClient(config: testConfig, transport: server.transport)

        let manager = LicenseManager(client: client, keychainAccount: account)
        #expect(!manager.isLicensed)
        await manager.activate(key: "  KEY-ABCD  ")
        #expect(manager.state == .licensed(keySuffix: "ABCD"))

        // A new instance (next launch) restores the license from the Keychain.
        let relaunched = LicenseManager(client: client, keychainAccount: account)
        #expect(relaunched.isLicensed)

        // Offline: keep the license.
        server.failNetwork = true
        await relaunched.revalidate()
        #expect(relaunched.isLicensed)

        // Server says it's no longer valid (e.g. refunded): revoke.
        server.failNetwork = false
        server.responses["validate"] = #"{"valid":false,"error":"license_key not found."}"#
        await relaunched.revalidate()
        #expect(!relaunched.isLicensed)
        #expect(relaunched.lastError != nil)
        #expect(!LicenseManager(client: client, keychainAccount: account).isLicensed)
    }

    @Test func failedActivationStaysUnlicensed() async {
        defer { Keychain.delete(account) }
        let server = FakeLicenseServer()
        server.responses["activate"] = #"{"activated":false,"error":"license_key not found."}"#
        let manager = LicenseManager(client: LemonSqueezyClient(config: testConfig, transport: server.transport), keychainAccount: account)
        await manager.activate(key: "NOPE")
        #expect(manager.state == .unlicensed)
        #expect(manager.lastError == "license_key not found.")
    }
}
#endif
