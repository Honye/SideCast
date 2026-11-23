//
//  StoreManager.swift
//  SideCast
//
//  SideCast Premium as an App Store in-app purchase (FR-PAY-02, FR-PAY-05): a one-time,
//  non-consumable product (App Store Connect: com.imarkr.SideCast.premium).
//  Also keeps diagnostics so purchase problems can be told apart (product not returned,
//  StoreKit error, wrong environment, purchases disabled…).
//

import Foundation
import Observation
import os
import StoreKit

/// What the App Store said, for the diagnostics panel. Values are technical and not localized.
struct StoreDiagnostics: Equatable {
    var productLoad = "not loaded yet"
    var productLoadedAt: Date?
    var environment = "unknown"
    var storefront = "unknown"
    var canMakePayments = AppStore.canMakePayments
    var entitlements = "not checked yet"
    var lastPurchase = "none"
    var lastRestore = "none"

    var report: String {
        var lines = [
            "Product ID: \(StoreManager.premiumProductID)",
            "Bundle ID: \(Bundle.main.bundleIdentifier ?? "?")",
            "App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))",
            "Environment: \(environment)",
            "Storefront: \(storefront)",
            "Can make payments: \(canMakePayments ? "yes" : "no")",
            "Product load: \(productLoad)",
        ]
        if let productLoadedAt {
            lines.append("Loaded at: \(productLoadedAt.formatted(date: .omitted, time: .standard))")
        }
        lines += [
            "Entitlements: \(entitlements)",
            "Last purchase: \(lastPurchase)",
            "Last restore: \(lastRestore)",
        ]
        return lines.joined(separator: "\n")
    }
}

@Observable
final class StoreManager {
    static let premiumProductID = "com.imarkr.SideCast.premium"

    private(set) var isUnlocked = false
    private(set) var product: Product?
    /// The product couldn't be loaded (offline, or not set up in App Store Connect yet).
    private(set) var productUnavailable = false
    private(set) var isRestoring = false
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var diagnostics = StoreDiagnostics()

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
            await refreshDiagnostics()
            await loadProduct()
            await refreshEntitlement()
        }
    }

    func loadProduct() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let products = try await Product.products(for: [Self.premiumProductID])
            product = products.first
            if let product {
                diagnostics.productLoad = "OK — \(product.displayName), \(product.displayPrice), type \(product.type.rawValue), family shareable \(product.isFamilyShareable)"
            } else {
                // The request worked but the App Store doesn't know this product (yet).
                diagnostics.productLoad = "App Store returned no product for this ID (not synced to this environment yet, missing metadata, or ID mismatch)"
            }
        } catch {
            Log.app.error("Could not load products: \(error.localizedDescription, privacy: .public)")
            diagnostics.productLoad = "Error — \(Self.describe(error))"
        }
        diagnostics.productLoadedAt = Date()
        productUnavailable = product == nil
    }

    /// Environment (Xcode / sandbox / production), storefront and payment availability.
    func refreshDiagnostics() async {
        diagnostics.canMakePayments = AppStore.canMakePayments
        if let storefront = await Storefront.current {
            diagnostics.storefront = "\(storefront.countryCode) (\(storefront.id))"
        } else {
            diagnostics.storefront = "unavailable (not signed in to the App Store?)"
        }
        do {
            switch try await AppTransaction.shared {
            case .verified(let transaction):
                diagnostics.environment = transaction.environment.rawValue
            case .unverified(let transaction, let error):
                diagnostics.environment = "\(transaction.environment.rawValue) (unverified: \(Self.describe(error)))"
            }
        } catch {
            diagnostics.environment = "unknown — \(Self.describe(error))"
        }
    }

    func refreshEntitlement() async {
        var unlocked = false
        var found: [String] = []
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                found.append("\(transaction.productID) verified\(transaction.revocationDate == nil ? "" : " revoked")")
                if transaction.productID == Self.premiumProductID, transaction.revocationDate == nil {
                    unlocked = true
                }
            case .unverified(let transaction, let error):
                found.append("\(transaction.productID) unverified: \(Self.describe(error))")
            }
        }
        diagnostics.entitlements = found.isEmpty ? "none" : found.joined(separator: "; ")
        if unlocked != isUnlocked {
            isUnlocked = unlocked
            onChange?()
        }
    }

    /// Called after a purchase made through StoreKit's views.
    func handlePurchase(_ result: Result<Product.PurchaseResult, Error>) async {
        switch result {
        case .success(.success(let verification)):
            switch verification {
            case .verified(let transaction):
                diagnostics.lastPurchase = "success, verified (transaction \(transaction.id))"
                await transaction.finish()
            case .unverified(_, let error):
                diagnostics.lastPurchase = "success but unverified: \(Self.describe(error))"
            }
            lastError = nil
            await refreshEntitlement()
        case .success(.pending):
            diagnostics.lastPurchase = "pending (Ask to Buy or extra confirmation needed)"
        case .success(.userCancelled):
            diagnostics.lastPurchase = "cancelled by user"
        case .success:
            diagnostics.lastPurchase = "unknown result"
        case .failure(let error):
            diagnostics.lastPurchase = "error — \(Self.describe(error))"
            lastError = error.localizedDescription
        }
    }

    /// Restores purchases from the App Store account (FR-PAY-02).
    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            diagnostics.lastRestore = "synced at \(Date().formatted(date: .omitted, time: .standard))"
            lastError = nil
        } catch {
            diagnostics.lastRestore = "error — \(Self.describe(error))"
            lastError = error.localizedDescription
        }
        await refreshEntitlement()
    }

    /// Reloads everything shown in the diagnostics panel.
    func refreshAll() async {
        await refreshDiagnostics()
        await loadProduct()
        await refreshEntitlement()
    }

    /// Error type, code and message, e.g. "StoreKitError.networkError(...) [SKErrorDomain 2]".
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(String(reflecting: type(of: error))): \(error) [\(nsError.domain) \(nsError.code)] \(error.localizedDescription)"
    }
}
