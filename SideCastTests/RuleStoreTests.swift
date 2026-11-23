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
}
#endif
