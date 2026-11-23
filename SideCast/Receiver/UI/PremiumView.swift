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
            Text("A one-time purchase for this device. Without it, this device plays the Mac's other sound and only one such device can be connected at a time. With Premium, your Mac can send single apps here, and this device can be connected alongside others. SideCast on the Mac is free.")
        }
    }
}
#endif
