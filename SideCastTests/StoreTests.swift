//
//  StoreTests.swift
//  SideCastTests
//

import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import SideCast

@MainActor
@Suite(.serialized)
struct StoreTests {
    /// StoreKit Test publishes entitlement changes with a short delay.
    func waitFor(_ store: StoreManager, unlocked: Bool) async throws -> Bool {
        for _ in 0..<30 {
            await store.refreshEntitlement()
            if store.isUnlocked == unlocked { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func purchaseUnlocksAndRefundRelocks() async throws {
        let url = try #require(Bundle(for: TestBundleMarker.self).url(forResource: "SideCastTests", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let store = StoreManager()
        await store.loadProduct()
        #expect(store.product?.id == StoreManager.premiumProductID)
        #expect(try await waitFor(store, unlocked: false))

        try await session.buyProduct(identifier: StoreManager.premiumProductID)
        #expect(try await waitFor(store, unlocked: true))

        let transaction = try #require(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        #expect(try await waitFor(store, unlocked: false))
    }
}

final class TestBundleMarker {}
