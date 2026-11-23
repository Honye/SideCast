//
//  StoreManager.swift
//  SideCast
//
//  SideCast Premium as an App Store in-app purchase (FR-PAY-02, FR-PAY-05): a one-time,
//  non-consumable product. Used by the receiver apps (and later the Mac App Store version).
//

import Foundation
import Observation
import os
import StoreKit

@Observable
final class StoreManager {
    /// TODO: create this non-consumable product in App Store Connect before release.
    static let premiumProductID = "com.imarkr.SideCast.premium"

    private(set) var isUnlocked = false
    private(set) var product: Product?
    /// The product couldn't be loaded (offline, or not set up in App Store Connect yet).
    private(set) var productUnavailable = false
    private(set) var isRestoring = false
    private(set) var lastError: String?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    func start() {
        guard updatesTask == nil else { return }
        // Purchases made on another device, refunds, Ask to Buy approvals…
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
        Task {
            await loadProduct()
            await refreshEntitlement()
        }
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.premiumProductID]).first
        } catch {
            Log.app.error("Could not load products: \(error.localizedDescription, privacy: .public)")
        }
        productUnavailable = product == nil
    }

    func refreshEntitlement() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.premiumProductID,
               transaction.revocationDate == nil {
                unlocked = true
            }
        }
        if unlocked != isUnlocked {
            isUnlocked = unlocked
            onChange?()
        }
    }

    /// Called after a purchase made through StoreKit's views.
    func handlePurchase(_ result: Result<Product.PurchaseResult, Error>) async {
        switch result {
        case .success(.success(let verification)):
            if case .verified(let transaction) = verification {
                await transaction.finish()
            }
            lastError = nil
            await refreshEntitlement()
        case .success:
            break // cancelled or pending (Ask to Buy)
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    /// Restores purchases from the App Store account (FR-PAY-02).
    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshEntitlement()
    }
}
