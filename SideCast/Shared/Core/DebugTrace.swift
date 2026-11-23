//
//  DebugTrace.swift
//  SideCast
//
//  Debug builds only: appends trace lines to `<tmp>/sidecast-trace.log` so behaviour can be
//  checked without Console access. Compiled out of release builds.
//

import Foundation

nonisolated enum DebugTrace {
#if DEBUG
    private static let queue = DispatchQueue(label: "DebugTrace")
    static let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidecast-trace.log")
#endif

    static func write(_ message: @autoclosure () -> String) {
#if DEBUG
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message())\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
#endif
    }
}
