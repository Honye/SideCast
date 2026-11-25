//
//  MirrorScreen.swift
//  SideCast
//
//  The mirrored Mac screen on iPad / iPhone / Vision Pro: full screen, letterboxed. The controls
//  show what is being mirrored, a button to stop mirroring (confirmed: the receiver may stop it)
//  and the touch control switch (FR-TOUCH-05) with its mode, trackpad or direct (FR-TOUCH-07).
//  With touch control on, touches go to the Mac and the button in the corner brings up the
//  controls (touches pause while they are up); otherwise a tap does.
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
            // While the controls are up, touches are for them; tapping elsewhere hides them.
            if !receiver.touchControlActive || showsControls {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation { showsControls.toggle() }
                        scheduleHide()
                    }
            }
            if let pictureSize = mirror.pictureSize {
                if receiver.touchControlActive && !showsControls {
                    TouchInputView(
                        pictureSize: pictureSize,
                        mode: receiver.touchControlMode,
                        send: { kind, point, delta in receiver.sendPointer(kind, at: point, delta: delta) },
                        sendTrackpad: { kind, delta in receiver.sendTrackpad(kind, delta: delta) }
                    )
                }
            } else {
                ProgressView()
                    .tint(.white)
            }
            if showsControls {
                VStack {
                    controls
                        .padding(.top, 12)
                    Spacer()
                }
                .transition(.opacity)
            } else if receiver.touchControlActive {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation { showsControls = true }
                            scheduleHide()
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.body.weight(.semibold))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.45), in: Circle())
                        .accessibilityLabel(Text("Show Controls"))
                        .accessibilityIdentifier("show-controls")
                        .padding(12)
                    }
                    Spacer()
                }
                .opacity(0.7)
            }
        }
        .ignoresSafeArea()
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

    private var controls: some View {
        @Bindable var receiver = receiver
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label {
                    Text("\(mirror.title) · \(mirror.macName)")
                        .lineLimit(1)
                } icon: {
                    Image(systemName: mirror.extended ? "display.2" : "rectangle.on.rectangle")
                }
                .font(.callout)
                Button(role: .destructive) {
                    receiver.stopMirroring()
                } label: {
                    mirror.extended ? Text("Stop Extended Display") : Text("Stop Mirroring")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("stop-mirroring")
            }
            if mirror.inputStatus != .unsupported {
                Toggle(isOn: $receiver.touchControlEnabled) {
                    Label("Touch Control", systemImage: "hand.tap")
                }
                .font(.callout)
                .accessibilityIdentifier("touch-control-toggle")
                .onChange(of: receiver.touchControlEnabled) { scheduleHide() }
                if receiver.touchControlEnabled {
                    Picker("Touch Mode", selection: $receiver.touchControlMode) {
                        Text("Trackpad").tag(TouchControlMode.trackpad)
                        Text("Direct Touch").tag(TouchControlMode.direct)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("touch-mode-picker")
                    .onChange(of: receiver.touchControlMode) { scheduleHide() }
                    Text(receiver.touchControlMode == .trackpad
                         ? "Slide to move the pointer, tap to click. Long-press, then slide to drag. Two fingers: tap to right-click, slide to scroll."
                         : "Tap or drag where you want the pointer. Two fingers: tap to right-click, slide to scroll.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if receiver.touchControlEnabled, mirror.inputStatus == .needsPermission {
                    Text("On the Mac, allow SideCast in System Settings › Privacy & Security › Accessibility.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard showsControls else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation { showsControls = false }
        }
    }
}
#endif
