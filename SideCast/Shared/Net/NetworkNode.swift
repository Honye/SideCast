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
    /// Interfaces the device was found on (Wi-Fi, peer-to-peer Wi-Fi, USB / Thunderbolt…).
    var interfaces: [NWInterface] = []

    var id: UUID { device.id }

    static func == (lhs: DiscoveredPeer, rhs: DiscoveredPeer) -> Bool {
        lhs.device == rhs.device && lhs.endpoint == rhs.endpoint && lhs.interfaces.map(\.name) == rhs.interfaces.map(\.name)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(device)
        hasher.combine(endpoint)
    }
}

@Observable
final class NetworkNode {
    static let serviceType = "_sidecast._tcp"

    private(set) var peers: [DiscoveredPeer] = []
    /// The user denied local network access; nothing can be discovered (FR-PERM-02/03).
    private(set) var localNetworkDenied = false

    @ObservationIgnored var onIncomingConnection: ((NWConnection) -> Void)?
    @ObservationIgnored var onPeersChanged: (() -> Void)?

    @ObservationIgnored private let identity: LocalIdentity
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var restartWorkItem: DispatchWorkItem?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// Names of the interfaces that are up right now. Bonjour can keep listing a device on an
    /// interface for a while after a cable was pulled.
    @ObservationIgnored private var liveInterfaces: Set<String>?
    /// The set of usable interfaces changed (a cable plugged in or pulled).
    @ObservationIgnored var onInterfacesChanged: (() -> Void)?

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
        startPathMonitor()
    }

    func stop() {
        restartWorkItem?.cancel()
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        peers = []
    }

    /// The peer's best interface that is up right now.
    func liveInterfaces(of peer: DiscoveredPeer) -> [NWInterface] {
        guard let liveInterfaces else { return peer.interfaces }
        return peer.interfaces.filter { liveInterfaces.contains($0.name) }
    }

    /// The best link the peer can be reached over right now.
    func bestLink(to peer: DiscoveredPeer) -> LinkKind {
        liveInterfaces(of: peer).map(LinkKind.of).max() ?? .unknown
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let names = Set(path.availableInterfaces.map(\.name))
            MainActor.assumeIsolated {
                guard let self, names != self.liveInterfaces else { return }
                self.liveInterfaces = names
                self.onInterfacesChanged?()
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// Connects over the best link the peer was found on: wired first (FR-CONN-04).
    func makeConnection(to peer: DiscoveredPeer) -> NWConnection {
        let parameters = Self.tcpParameters()
        if let interface = liveInterfaces(of: peer).first(where: { LinkKind.of($0) == .wired }) {
            parameters.requiredInterface = interface
        }
        return NWConnection(to: peer.endpoint, using: parameters)
    }

    /// Connects avoiding wired links, e.g. right after a cable was pulled.
    func makeWirelessConnection(to peer: DiscoveredPeer) -> NWConnection {
        let parameters = Self.tcpParameters()
        parameters.prohibitedInterfaceTypes = [.wiredEthernet]
        for interface in peer.interfaces where LinkKind.of(interface) == .wired {
            parameters.prohibitedInterfaces = (parameters.prohibitedInterfaces ?? []) + [interface]
        }
        return NWConnection(to: peer.endpoint, using: parameters)
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
                guard let self else { return }
                switch state {
                case .ready:
                    if self.localNetworkDenied { self.localNetworkDenied = false }
                case .waiting(let error):
                    self.localNetworkDenied = Self.isPolicyDenied(error)
                case .failed(let error):
                    Log.net.error("Browser failed: \(error.localizedDescription, privacy: .public)")
                    self.localNetworkDenied = Self.isPolicyDenied(error)
                    self.scheduleRestart()
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// kDNSServiceErr_PolicyDenied: local network privacy permission is off.
    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65_570 { return true }
        return false
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
                  let role = txt["role"].flatMap(DeviceRole.init(rawValue:)) else { continue }
            if var existing = byID[id] {
                // The same device on another interface.
                for interface in result.interfaces where !existing.interfaces.contains(where: { $0.name == interface.name }) {
                    existing.interfaces.append(interface)
                }
                byID[id] = existing
                continue
            }
            let name = txt["name"] ?? platform.rawValue
            byID[id] = DiscoveredPeer(
                device: DeviceInfo(id: id, name: name, platform: platform, role: role),
                endpoint: result.endpoint,
                interfaces: result.interfaces
            )
        }
        peers = byID.values.sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
        onPeersChanged?()
    }
}
