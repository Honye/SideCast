//
//  NetworkNode.swift
//  SideCast
//
//  Advertises this device over Bonjour and browses for other SideCast devices, on the local
//  network and over peer-to-peer Wi-Fi.
//

import Foundation
import Network
import Observation
import os

struct DiscoveredPeer: Identifiable, Hashable {
    let device: DeviceInfo
    let endpoint: NWEndpoint

    var id: UUID { device.id }
}

@Observable
final class NetworkNode {
    static let serviceType = "_sidecast._tcp"

    private(set) var peers: [DiscoveredPeer] = []

    @ObservationIgnored var onIncomingConnection: ((NWConnection) -> Void)?
    @ObservationIgnored var onPeersChanged: (() -> Void)?

    @ObservationIgnored private let identity: LocalIdentity
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var restartWorkItem: DispatchWorkItem?

    init(identity: LocalIdentity) {
        self.identity = identity
    }

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    func start() {
        startListener()
        startBrowser()
    }

    func stop() {
        restartWorkItem?.cancel()
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        peers = []
    }

    func makeConnection(to peer: DiscoveredPeer) -> NWConnection {
        NWConnection(to: peer.endpoint, using: Self.tcpParameters())
    }

    private var txtRecord: NWTXTRecord {
        NWTXTRecord([
            "v": "\(Hello.currentVersion)",
            "id": identity.device.id.uuidString,
            "name": identity.device.name,
            "platform": identity.device.platform.rawValue,
            "role": identity.device.role.rawValue,
        ])
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: Self.tcpParameters())
            listener.service = NWListener.Service(
                name: identity.device.name,
                type: Self.serviceType,
                domain: nil,
                txtRecord: txtRecord
            )
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.onIncomingConnection?(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        Log.net.info("Listening on port \(listener.port?.rawValue ?? 0)")
                    case .failed(let error):
                        Log.net.error("Listener failed: \(error.localizedDescription, privacy: .public)")
                        self?.scheduleRestart()
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Log.net.error("Could not create listener: \(error.localizedDescription, privacy: .public)")
            scheduleRestart()
        }
    }

    private func startBrowser() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: Self.tcpParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed(let error) = state {
                    Log.net.error("Browser failed: \(error.localizedDescription, privacy: .public)")
                    self?.scheduleRestart()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func scheduleRestart() {
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stop()
            self.start()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var byID: [UUID: DiscoveredPeer] = [:]
        for result in results {
            guard case let .bonjour(txt) = result.metadata,
                  let id = txt["id"].flatMap(UUID.init(uuidString:)),
                  id != identity.device.id,
                  let platform = txt["platform"].flatMap(DevicePlatform.init(rawValue:)),
                  let role = txt["role"].flatMap(DeviceRole.init(rawValue:)),
                  byID[id] == nil else { continue }
            let name = txt["name"] ?? platform.rawValue
            byID[id] = DiscoveredPeer(
                device: DeviceInfo(id: id, name: name, platform: platform, role: role),
                endpoint: result.endpoint
            )
        }
        peers = byID.values.sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
        onPeersChanged?()
    }
}
