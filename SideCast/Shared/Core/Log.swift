//
//  Log.swift
//  SideCast
//

import os

nonisolated enum Log {
    static let subsystem = "com.imarkr.SideCast"
    static let net = Logger(subsystem: subsystem, category: "net")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let security = Logger(subsystem: subsystem, category: "security")
    static let app = Logger(subsystem: subsystem, category: "app")
}
