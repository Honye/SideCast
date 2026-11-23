//
//  RuleStoreTests.swift
//  SideCastTests
//

#if os(macOS)
import Foundation
import Testing
@testable import SideCast

@MainActor
struct RuleStoreTests {
    let defaults = UserDefaults(suiteName: "SideCastTests.\(UUID().uuidString)")!

    @Test func rulesPersistAcrossInstances() {
        let receiver = UUID()
        let store = RuleStore(defaults: defaults)
        store.update("com.example.music", name: "Music") {
            $0.target = .receiver(id: receiver)
            $0.volume = 0.3
        }
        store.update("com.example.chat", name: "Chat") { $0.muted = true }

        let reloaded = RuleStore(defaults: defaults)
        #expect(reloaded.rule(for: "com.example.music").target == .receiver(id: receiver))
        #expect(reloaded.rule(for: "com.example.music").volume == 0.3)
        #expect(reloaded.rule(for: "com.example.music").appName == "Music")
        #expect(reloaded.rule(for: "com.example.chat").muted)
    }

    @Test func passthroughRulesAreNotStored() {
        let store = RuleStore(defaults: defaults)
        store.update("com.example.app", name: "App") { $0.volume = 0.5 }
        #expect(store.rules["com.example.app"] != nil)
        store.update("com.example.app", name: "App") { $0.volume = 1 }
        #expect(store.rules["com.example.app"] == nil)
        #expect(store.rule(for: "com.example.app").isPassthrough)
    }

    @Test func processOverridesKeepDefaultValues() {
        let store = RuleStore(defaults: defaults)
        store.update("com.example.browser#com.example.browser.helper", name: "Helper", keepPassthrough: true) {
            $0.volume = 1
        }
        // An override equal to the defaults still exists, so it doesn't fall back to the app rule.
        #expect(store.rules["com.example.browser#com.example.browser.helper"] != nil)
    }

    @Test func processGroupsSplitByKind() {
        let processes = [
            AudioProcess(objectID: 1, pid: 10, bundleID: "com.example.browser", isRunningOutput: false),
            AudioProcess(objectID: 2, pid: 11, bundleID: "com.example.browser.helper", isRunningOutput: true),
            AudioProcess(objectID: 3, pid: 12, bundleID: "com.example.browser.helper", isRunningOutput: false),
            AudioProcess(objectID: 4, pid: 13, bundleID: nil, isRunningOutput: false),
        ]
        let app = AudioApp(id: "com.example.browser", name: "Browser", processes: processes)
        let groups = app.processGroups
        #expect(groups.count == 3)
        let helper = groups.first { $0.kind == "com.example.browser.helper" }
        #expect(helper?.id == "com.example.browser#com.example.browser.helper")
        #expect(helper?.processes.count == 2)
        #expect(helper?.isPlaying == true)
        #expect(helper?.displayName == "helper")
        #expect(groups.contains { $0.kind == "pid:13" })
    }
}
#endif
