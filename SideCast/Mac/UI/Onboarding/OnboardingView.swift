//
//  OnboardingView.swift
//  SideCast
//
//  First-launch guide on the Mac (FR-PERM-01), step by step, as confirmed:
//  - Welcome → local network → system audio recording → screen recording → Accessibility →
//    audio driver → connect a device → done. The last three permissions are optional and can be
//    skipped; the Mac App Store version leaves out Accessibility and the driver.
//  - Each permission button brings up macOS's own question; a refused one opens System Settings.
//  - It can be shown again from Settings › General.
//

#if os(macOS)
import CoreGraphics
import SwiftUI

enum OnboardingStep: CaseIterable {
    case welcome, localNetwork, audioCapture, screenRecording, accessibility, audioDriver, connect, done

    /// The steps for this build of SideCast.
    static var steps: [OnboardingStep] {
        allCases.filter { step in
            switch step {
            case .accessibility: RemoteInputInjector.isSupported
            case .audioDriver: SystemAudioDriver.isSupported && SystemAudioDriver.installerPackage != nil
            default: true
            }
        }
    }

    var isOptional: Bool {
        [.screenRecording, .accessibility, .audioDriver].contains(self)
    }
}

struct OnboardingView: View {
    @Environment(SenderController.self) private var sender
    let close: () -> Void

    @State private var index = 0
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var accessibilityGranted = RemoteInputInjector.status == .available
    @State private var probe: Task<Void, Never>?
    @State private var audioCheckFailed = false

    private var steps: [OnboardingStep] { OnboardingStep.steps }
    private var step: OnboardingStep { steps[index] }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 32)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 470)
        .task {
            while !Task.isCancelled {
                screenGranted = CGPreflightScreenCaptureAccess()
                accessibilityGranted = RemoteInputInjector.status == .available
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { probe?.cancel() }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            StepPage(
                symbol: "hifispeaker.2.fill",
                title: Text("Welcome to SideCast"),
                message: Text("SideCast plays your Mac's sound on your iPad, iPhone, Vision Pro or another Mac, and can show your screen there too. You can send each app to a different device and set its own volume.\n\nA few permissions are needed first. This takes about a minute.")
            ) { EmptyView() }

        case .localNetwork:
            StepPage(
                symbol: "network",
                title: Text("Find Your Devices"),
                message: Text("SideCast uses the local network to find your devices nearby and connect to them. If macOS asks whether SideCast may find devices on your local network, choose Allow.")
            ) {
                if sender.node.localNetworkDenied {
                    StatusLine(.denied, Text("Local network access is off."))
                    Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.localNetwork) }
                } else if sender.node.localNetworkConfirmed {
                    StatusLine(.granted, Text("Allowed"))
                } else {
                    StatusLine(.waiting, Text("Waiting for macOS…"))
                }
            }

        case .audioCapture:
            StepPage(
                symbol: "waveform",
                title: Text("Take App Sound"),
                message: Text("To play an app on another device, or at another volume, SideCast takes that app's sound. macOS calls this \u{201C}system audio recording\u{201D}. SideCast never records or saves audio.")
            ) {
                if sender.audioCaptureConfirmed {
                    StatusLine(.granted, Text("Allowed"))
                } else if probe != nil {
                    StatusLine(.waiting, Text("Choose Allow in the message from macOS…"))
                    Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.audioCapture) }
                        .buttonStyle(.link)
                } else {
                    if audioCheckFailed {
                        StatusLine(.denied, Text("Not allowed yet. If you declined, turn on SideCast in System Settings, then check again."))
                    }
                    HStack {
                        Button(action: checkAudioCapture) {
                            audioCheckFailed ? Text("Check Again") : Text("Allow System Audio Recording…")
                        }
                        .buttonStyle(.borderedProminent)
                        if audioCheckFailed {
                            Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.audioCapture) }
                        }
                    }
                }
            }

        case .screenRecording:
            StepPage(
                symbol: "rectangle.on.rectangle",
                title: Text("Show Your Screen"),
                message: Text("Optional. Needed to mirror your Mac's screen to a device or use a device as an extended display. If macOS says SideCast has to be reopened, you can do that after this guide.")
            ) {
                if screenGranted {
                    StatusLine(.granted, Text("Allowed"))
                } else {
                    HStack {
                        Button("Allow Screen Recording…") { _ = CGRequestScreenCaptureAccess() }
                            .buttonStyle(.borderedProminent)
                        Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.screenCapture) }
                    }
                }
            }

        case .accessibility:
            StepPage(
                symbol: "hand.tap",
                title: Text("Control Your Mac by Touch"),
                message: Text("Optional. With touch control, taps, drags and scrolling on a device's mirrored screen act on this Mac. macOS lists this under Accessibility.")
            ) {
                if accessibilityGranted {
                    StatusLine(.granted, Text("Allowed"))
                } else {
                    HStack {
                        Button("Allow Touch Control…") { RemoteInputInjector.requestPermission() }
                            .buttonStyle(.borderedProminent)
                        Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.accessibility) }
                    }
                }
            }

        case .audioDriver:
            StepPage(
                symbol: "speaker.wave.2.circle",
                title: Text("Show Devices in Sound Settings"),
                message: Text("Optional. With the SideCast audio driver, each connected device also appears in System Settings › Sound and the sound menu, so any app can play to it. Installing needs an administrator password, and sound on this Mac stops for a moment.")
            ) {
                let driver = sender.systemDriver
                if driver.isInstalled {
                    StatusLine(.granted, Text("Installed"))
                } else if driver.waitingForInstaller {
                    StatusLine(.waiting, Text("Finish in the installer…"))
                } else {
                    Button("Install Audio Driver…") { driver.install() }
                        .buttonStyle(.borderedProminent)
                }
            }

        case .connect:
            StepPage(
                symbol: "ipad.and.iphone",
                title: Text("Connect a Device"),
                message: Text("Install SideCast from the App Store on your iPad, iPhone or Vision Pro and open it, or turn on receive mode on another Mac. Then connect to it here. Devices on your Apple ID connect right away; others show a pairing code to enter on the device.")
            ) {
                let rows = sender.receiverRows
                if rows.isEmpty {
                    StatusLine(.waiting, Text("Looking for devices…"))
                } else {
                    VStack(spacing: 8) {
                        ForEach(rows, id: \.device.id) { row in
                            ReceiverRow(device: row.device, peer: row.peer)
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }

        case .done:
            StepPage(
                symbol: "checkmark.circle.fill",
                title: Text("You're All Set"),
                message: Text("SideCast lives in the menu bar. Click its icon to choose where each app plays, set volumes and show your screen on a device.")
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    SummaryLine(Text("Local network"), sender.node.localNetworkConfirmed && !sender.node.localNetworkDenied)
                    SummaryLine(Text("System audio recording"), sender.audioCaptureConfirmed)
                    SummaryLine(Text("Screen recording"), screenGranted, optional: true)
                    if steps.contains(.accessibility) {
                        SummaryLine(Text("Touch control"), accessibilityGranted, optional: true)
                    }
                    if steps.contains(.audioDriver) {
                        SummaryLine(Text("Audio driver"), sender.systemDriver.isInstalled, optional: true)
                    }
                    Text("You can change these any time in Settings › General.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if index > 0 {
                Button("Back") { index -= 1 }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { position in
                    Circle()
                        .fill(position == index ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Step \(index + 1) of \(steps.count)"))
            Spacer()
            if step.isOptional, !isDone(step) {
                Button("Not Now") { advance() }
            }
            Button {
                step == .done ? close() : advance()
            } label: {
                switch step {
                case .done: Text("Start Using SideCast")
                case .welcome: Text("Get Started")
                default: Text("Continue")
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func isDone(_ step: OnboardingStep) -> Bool {
        switch step {
        case .screenRecording: screenGranted
        case .accessibility: accessibilityGranted
        case .audioDriver: sender.systemDriver.isInstalled
        default: false
        }
    }

    private func advance() {
        index = min(index + 1, steps.count - 1)
    }

    private func checkAudioCapture() {
        audioCheckFailed = false
        probe = Task {
            let outcome = await AudioCapturePermissionProbe().run()
            if outcome == .allowed {
                sender.confirmAudioCapture()
            } else if !Task.isCancelled {
                audioCheckFailed = true
            }
            probe = nil
        }
    }
}

// MARK: - Pieces

private struct StepPage<Status: View>: View {
    let symbol: String
    let title: Text
    let message: Text
    @ViewBuilder let status: () -> Status

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .frame(height: 56)
            title
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            message
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                status()
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}

private struct StatusLine: View {
    enum Kind { case granted, denied, waiting }
    let kind: Kind
    let text: Text

    init(_ kind: Kind, _ text: Text) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            switch kind {
            case .granted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .waiting:
                ProgressView().controlSize(.small)
            }
            text
                .foregroundStyle(kind == .granted ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

private struct SummaryLine: View {
    let title: Text
    let done: Bool
    var optional = false

    init(_ title: Text, _ done: Bool, optional: Bool = false) {
        self.title = title
        self.done = done
        self.optional = optional
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : optional ? "minus.circle" : "exclamationmark.circle")
                .foregroundStyle(done ? AnyShapeStyle(.green) : optional ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            title
            Spacer()
            Group {
                if done {
                    Text("Ready")
                } else if optional {
                    Text("Skipped")
                } else {
                    Text("Not yet")
                }
            }
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(width: 320)
    }
}
#endif
