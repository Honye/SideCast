//
//  RuntimeEnvironment.swift
//  SideCast
//

import Foundation

nonisolated enum RuntimeEnvironment {
    /// True when the app is hosting unit tests. Networking and audio stay off then.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}
