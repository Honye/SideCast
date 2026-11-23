//
//  AudioRouter.swift
//  SideCast
//
//  Turns "this app goes to that destination at this gain" into process taps and destination
//  engines, changing only what differs from the current setup.
//

#if os(macOS)
import CoreAudio
import Foundation
import os

/// Where captured audio goes.
enum RouteTarget: Hashable {
    /// A local output device, by UID.
    case device(String)
    /// A connected receiver.
    case receiver(UUID)
    /// Nowhere: the app stays silent (its target is offline).
    case discard
}

struct RouteUnit: Equatable {
    /// Stable key, e.g. the app's bundle ID.
    let key: String
    let name: String
    let processes: [AudioObjectID]
    let target: RouteTarget
    let gain: Float
}

final class AudioRouter {
    /// Returns the network sink for a connected receiver.
    var sinkProvider: ((UUID) -> AudioFrameSink?)?
    private(set) var lastError: Error?

    private var taps: [String: ProcessTap] = [:]
    private var engines: [RouteTarget: DestinationEngine] = [:]
    private var lastUnits: [RouteUnit] = []
    private var lastDefaultDevice: String?

    func apply(_ units: [RouteUnit], defaultDeviceUID: String?) {
        let units = units.sorted { $0.key < $1.key }
        guard units != lastUnits || defaultDeviceUID != lastDefaultDevice else { return }
        lastUnits = units
        lastDefaultDevice = defaultDeviceUID
        lastError = nil

        // Create or update taps.
        for unit in units {
            do {
                if let tap = taps[unit.key] {
                    try tap.update(processes: unit.processes)
                } else {
                    taps[unit.key] = try ProcessTap(name: "SideCast · \(unit.name)", processes: unit.processes)
                }
            } catch {
                record(error, context: "tap for \(unit.key)")
            }
        }

        var groups: [RouteTarget: [DestinationEngine.Member]] = [:]
        for unit in units {
            guard let tap = taps[unit.key] else { continue }
            groups[unit.target, default: []].append(.init(key: unit.key, tap: tap, gain: unit.gain))
        }

        // Engines that lose members are rebuilt first, so a tap is out of its old aggregate
        // before it joins a new one.
        let targets = Set(engines.keys).union(groups.keys)
        let shrinking = targets.filter { target in
            let new = Set(groups[target]?.map(\.key) ?? [])
            let old = Set(engines[target]?.memberKeys ?? [])
            return new.isSubset(of: old)
        }
        for target in shrinking.sorted(by: { "\($0)" < "\($1)" }) + targets.subtracting(shrinking).sorted(by: { "\($0)" < "\($1)" }) {
            configure(target, members: groups[target] ?? [], defaultDeviceUID: defaultDeviceUID)
        }

        let keys = Set(units.map(\.key))
        for key in taps.keys where !keys.contains(key) {
            taps.removeValue(forKey: key)
        }
    }

    /// Forces the next `apply` to reconfigure, e.g. after a receiver's sink changed.
    func invalidate() {
        lastUnits = []
    }

    func takePeak(for key: String) -> Float? {
        for engine in engines.values {
            if let peak = engine.takePeak(for: key) { return peak }
        }
        return nil
    }

    func stopAll() {
        for engine in engines.values {
            engine.stop()
        }
        engines = [:]
        taps = [:]
        lastUnits = []
    }

    private func configure(_ target: RouteTarget, members: [DestinationEngine.Member], defaultDeviceUID: String?) {
        guard !members.isEmpty else {
            engines.removeValue(forKey: target)?.stop()
            return
        }
        let output: DestinationEngine.Output
        switch target {
        case .device(let uid):
            output = .init(deviceUID: uid, writesToOutput: true, sink: nil)
        case .receiver(let id):
            guard let clock = defaultDeviceUID else { return }
            output = .init(deviceUID: clock, writesToOutput: false, sink: sinkProvider?(id))
        case .discard:
            guard let clock = defaultDeviceUID else { return }
            output = .init(deviceUID: clock, writesToOutput: false, sink: nil)
        }
        let engine = engines[target] ?? DestinationEngine()
        engines[target] = engine
        do {
            try engine.update(members: members, output: output)
        } catch {
            record(error, context: "destination \(target)")
            engine.stop()
            engines.removeValue(forKey: target)
        }
    }

    private func record(_ error: Error, context: String) {
        lastError = error
        Log.audio.error("\(context, privacy: .public): \(String(describing: error), privacy: .public)")
        DebugTrace.write("error \(context): \(error)")
    }
}
#endif
