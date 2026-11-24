//
//  SystemAudioDriverTests.swift
//  SideCastTests
//
//  Receivers as macOS output devices (V1-M4). The driver itself is tested by
//  Driver/Tests/run-tests.sh; these cover the app side.
//

#if os(macOS)
import Foundation
import Testing
@testable import SideCast

struct SystemAudioDriverTests {
    let ipad = UUID()
    let iphone = UUID()

    @Test func deviceUIDsStandForReceivers() {
        let uid = SystemAudioDriver.uid(for: ipad)
        #expect(uid.hasPrefix("com.imarkr.SideCast.receiver."))
        #expect(SystemAudioDriver.receiver(forUID: uid) == ipad)
        #expect(SystemAudioDriver.receiver(forUID: "BuiltInSpeakerDevice") == nil)
        #expect(SystemAudioDriver.receiver(forUID: "com.imarkr.SideCast.receiver.not-a-uuid") == nil)
        #expect(SystemAudioDriver.receiver(forUID: nil) == nil)
        #expect(SystemAudioDriver.deviceName(for: "Jun's iPad") == "Jun's iPad (SideCast)")
    }

    @Test func volumeBecomesGain() {
        #expect(SystemAudioDriver.gain(decibels: 0) == 1)
        #expect(SystemAudioDriver.gain(decibels: -96) == 0)
        #expect(SystemAudioDriver.gain(decibels: -120) == 0)
        #expect(abs(SystemAudioDriver.gain(decibels: -6.0206) - 0.5) < 0.001)
        // The driver maps the slider's 50% to 40·log10(0.5) dB, i.e. a quarter of the amplitude.
        #expect(abs(SystemAudioDriver.gain(decibels: 40 * log10(0.5)) - 0.25) < 0.001)
    }

    @Test func driverAndInstallersShipWithTheApp() {
        #expect(SystemAudioDriver.installerPackage != nil)
        #expect(SystemAudioDriver.uninstallerPackage != nil)
        #expect(SystemAudioDriver().bundledVersion == 1)
    }

    // MARK: Putting a receiver back as the output (Q: devices appear while connected)

    @Test func restoresReceiverThatWasTheOutputWhenItReconnects() {
        var memory = SystemOutputMemory()
        let device = SystemAudioDriver.uid(for: ipad)
        // iPad is the output.
        #expect(memory.update(previousDefault: "Speakers", currentDefault: device, presentReceivers: [ipad]) == nil)
        // It disconnects; its device goes away and macOS falls back to the speakers.
        #expect(memory.update(previousDefault: device, currentDefault: device, presentReceivers: []) == nil)
        #expect(memory.update(previousDefault: device, currentDefault: "Speakers", presentReceivers: []) == nil)
        #expect(memory.receiver == ipad && memory.fallbackUID == "Speakers")
        // Other refreshes while it's away change nothing.
        #expect(memory.update(previousDefault: "Speakers", currentDefault: "Speakers", presentReceivers: [iphone]) == nil)
        // It's back: put it back, once.
        #expect(memory.update(previousDefault: "Speakers", currentDefault: "Speakers", presentReceivers: [ipad]) == ipad)
        #expect(memory == SystemOutputMemory())
        #expect(memory.update(previousDefault: "Speakers", currentDefault: "Speakers", presentReceivers: [ipad]) == nil)
    }

    @Test func doesNotRestoreAfterTheUserChoseAnotherOutput() {
        var memory = SystemOutputMemory()
        let device = SystemAudioDriver.uid(for: ipad)
        _ = memory.update(previousDefault: device, currentDefault: "Speakers", presentReceivers: [])
        // The user picks AirPods while the iPad is away.
        #expect(memory.update(previousDefault: "Speakers", currentDefault: "AirPods", presentReceivers: []) == nil)
        #expect(memory.update(previousDefault: "AirPods", currentDefault: "AirPods", presentReceivers: [ipad]) == nil)
    }

    @Test func switchingAwayManuallyIsNotRemembered() {
        var memory = SystemOutputMemory()
        let device = SystemAudioDriver.uid(for: ipad)
        // The iPad is still there; the user chose the speakers.
        #expect(memory.update(previousDefault: device, currentDefault: "Speakers", presentReceivers: [ipad]) == nil)
        #expect(memory == SystemOutputMemory())
    }

    @Test func restoresAfterSideCastRestarted() {
        // SideCast quit while the iPad was the output; it doesn't know what macOS picked.
        var memory = SystemOutputMemory(receiver: ipad, fallbackUID: nil)
        #expect(memory.update(previousDefault: nil, currentDefault: "Speakers", presentReceivers: []) == nil)
        #expect(memory.fallbackUID == "Speakers")
        #expect(memory.update(previousDefault: "Speakers", currentDefault: "Speakers", presentReceivers: [ipad]) == ipad)
    }
}
#endif
