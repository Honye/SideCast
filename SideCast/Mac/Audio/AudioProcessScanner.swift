//
//  AudioProcessScanner.swift
//  SideCast
//
//  Lists the processes Core Audio knows about and groups them by the app they belong to
//  (for example Chrome's helper processes belong to Chrome).
//

#if os(macOS)
import AppKit
import CoreAudio
import Darwin

nonisolated struct AudioProcess: Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

/// A user-facing app that owns one or more audio processes.
struct AudioApp: Identifiable, Hashable {
    /// Bundle ID of the owning app, or a fallback identifier for processes without one.
    let id: String
    let name: String
    var processes: [AudioProcess]

    var isPlaying: Bool { processes.contains(where: \.isRunningOutput) }
    var processObjectIDs: [AudioObjectID] { processes.map(\.objectID) }

    /// The app's processes grouped by kind (bundle ID), for per-process rules (FR-ROUTE-10).
    var processGroups: [ProcessGroup] {
        Dictionary(grouping: processes) { $0.bundleID ?? "pid:\($0.pid)" }
            .map { kind, processes in
                ProcessGroup(id: "\(id)#\(kind)", appID: id, kind: kind, processes: processes)
            }
            .sorted { $0.kind < $1.kind }
    }
}

/// One kind of process inside an app, e.g. Chrome's renderer helpers.
struct ProcessGroup: Identifiable, Hashable {
    /// Rule key: "<app ID>#<kind>".
    let id: String
    let appID: String
    let kind: String
    let processes: [AudioProcess]

    var isPlaying: Bool { processes.contains(where: \.isRunningOutput) }

    var displayName: String {
        if kind == appID {
            return String(localized: "Main process")
        }
        if kind.hasPrefix("pid:") {
            return String(localized: "Process \(String(kind.dropFirst(4)))")
        }
        if kind.hasPrefix(appID + ".") {
            return String(kind.dropFirst(appID.count + 1))
        }
        return kind
    }
}

enum AudioProcessScanner {
    static func scan() -> [AudioApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        var apps: [String: AudioApp] = [:]
        // Skip SideCast itself, including a receiver copy running in the iOS Simulator.
        for process in processes() where process.pid != ownPID && process.bundleID != ownBundleID {
            let owner = owningApplication(of: process.pid)
            if owner?.processIdentifier == ownPID { continue }
            let id = owner?.bundleIdentifier ?? process.bundleID ?? "pid:\(process.pid)"
            let name = owner?.localizedName ?? process.bundleID.map(readableName(fromBundleID:)) ?? "Process \(process.pid)"
            apps[id, default: AudioApp(id: id, name: name, processes: [])].processes.append(process)
        }
        return apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func processes() -> [AudioProcess] {
        let ids = (try? CAProperty.array(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList,
            of: AudioObjectID.self
        )) ?? []
        return ids.compactMap { id in
            guard let pid = try? CAProperty.value(id, kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
            let bundleID = (try? CAProperty.string(id, kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
            let running = (try? CAProperty.value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }

    /// Finds the regular (Dock) app a process belongs to, following "responsible process" and
    /// parent process links.
    static func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        var visited: Set<pid_t> = []
        while current > 1, visited.insert(current).inserted {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            if let responsible = responsiblePID(of: current), responsible > 1, !visited.contains(responsible) {
                current = responsible
            } else if let parent = parentPID(of: current) {
                current = parent
            } else {
                break
            }
        }
        return nil
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` is not public API; it is looked up at runtime
    /// and the parent process is used when it is unavailable.
    private static let responsibilityFunction: ResponsibilityFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    private static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let function = responsibilityFunction else { return nil }
        let result = function(pid)
        return result > 0 && result != pid ? result : nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    nonisolated private static func readableName(fromBundleID bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
#endif
