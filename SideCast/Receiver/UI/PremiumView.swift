//
//  PremiumView.swift
//  SideCast
//
//  SideCast Premium on iPad / iPhone / Vision Pro (FR-PAY-02, FR-PAY-05): buy once, restore.
//  Premium unlocks per-app output and several devices on the connected Mac.
//

#if !os(macOS)
import StoreKit
import SwiftUI

struct PremiumSection: View {
    @Environment(ReceiverController.self) private var receiver

    var body: some View {
        let store = receiver.store
        Section {
            if store.isUnlocked {
                Label("SideCast Premium is unlocked", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                if receiver.macPremium, let mac = receiver.activeSession?.peer?.name {
                    Label("Unlocked by \(mac)", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
                if store.productUnavailable {
                    Label("The App Store isn't available right now. Try again later.", systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await store.loadProduct() }
                    }
                } else {
                ProductView(id: StoreManager.premiumProductID) {
                    Image(systemName: "sparkles")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                }
#if !os(visionOS)
                .productViewStyle(.compact)
#endif
                .onInAppPurchaseCompletion { _, result in
                    await store.handlePurchase(result)
                }
                }
                Button {
                    Task { await store.restore() }
                } label: {
                    if store.isRestoring {
                        ProgressView()
                    } else {
                        Text("Restore Purchases")
                    }
                }
                .disabled(store.isRestoring)
            }
            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("SideCast Premium")
        } footer: {
            Text("A one-time purchase. While this device is connected, your Mac can send each app to a different output, set each app's volume, and connect several devices at once.")
        }
    }
}
#endif
