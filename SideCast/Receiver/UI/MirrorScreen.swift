//
//  MirrorScreen.swift
//  SideCast
//
//  The mirrored Mac screen on iPad / iPhone / Vision Pro: full screen, letterboxed. A tap shows
//  what is being mirrored and a button to stop mirroring (confirmed: the receiver may stop it).
//

#if !os(macOS)
import SwiftUI

struct MirrorScreen: View {
    @Environment(ReceiverController.self) private var receiver
    let mirror: MirrorState
    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            MirrorLayerView(renderer: receiver.mirrorRenderer)
            if mirror.pictureSize == nil {
                ProgressView()
                    .tint(.white)
            }
            if showsControls {
                VStack {
                    HStack(spacing: 12) {
                        Label {
                            Text("\(mirror.displayName) · \(mirror.macName)")
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "rectangle.on.rectangle")
                        }
                        .font(.callout)
                        Button("Stop Mirroring", role: .destructive) {
                            receiver.stopMirroring()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("stop-mirroring")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { showsControls.toggle() }
            scheduleHide()
        }
#if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
#endif
        .onAppear {
            scheduleHide()
#if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
#endif
        }
        .onDisappear {
            hideTask?.cancel()
#if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
#endif
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard showsControls else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation { showsControls = false }
        }
    }
}
#endif
