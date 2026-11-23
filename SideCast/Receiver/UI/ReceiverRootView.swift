//
//  ReceiverRootView.swift
//  SideCast
//

#if !os(macOS)
import SwiftUI

struct ReceiverRootView: View {
    @Environment(ReceiverController.self) private var receiver

    var body: some View {
        NavigationStack {
            Text("SideCast")
                .navigationTitle("SideCast")
        }
    }
}
#endif
