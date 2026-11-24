// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import Security
import Darwin

struct CableEndpoint {
    let host: String
    let port: UInt16
    let interface: String
    let interfaceIndex: UInt32

    init(host: String, port: UInt16, interface: String) throws {
        let index = if_nametoindex(interface)
        guard port > 0, !interface.isEmpty, index != 0 else { throw SenderError("Invalid dedicated interface or port") }
        interfaceIndex = index
        // Never DNS-resolve a name or route to a non-link-local network.
        let parts = host.split(separator: "%", omittingEmptySubsequences: false)
        let bare = String(parts[0])
        guard parts.count <= 2, parts.count == 1 || String(parts[1]) == interface else { throw SenderError("Address zone must match the selected interface") }
        var v4 = in_addr(), v6 = in6_addr()
        let is4 = bare.withCString { inet_pton(AF_INET, $0, &v4) } == 1
        let is6 = bare.withCString { inet_pton(AF_INET6, $0, &v6) } == 1
        if is4 {
            let octets = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            guard octets[0] == 169, octets[1] == 254 else { throw SenderError("Only link-local addresses are accepted") }
            self.host = bare + "%" + interface
        } else if is6 {
            let octets = withUnsafeBytes(of: v6) { Array($0) }
            guard octets[0] == 0xfe, octets[1] & 0xc0 == 0x80 else { throw SenderError("Only link-local addresses are accepted") }
            self.host = bare + "%" + interface
        } else { throw SenderError("A numeric link-local address is required") }
        self.port = port
        self.interface = interface
    }
}

private func dispatchBytes(_ data: Data) -> dispatch_data_t {
    // DispatchData copies bytes here. The TLS implementation owns that copy
    // until its options and connection are released; no secret is persisted.
    let copied = data.withUnsafeBytes { DispatchData(bytes: $0) }
    return copied as __DispatchData
}

final class SecureTransport {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "locachy.sender.transport", qos: .userInteractive)
    private let sendLock = NSLock()
    private var reader = FrameReader()
    private var timer: DispatchSourceTimer?
    private var lastReceived = ProcessInfo.processInfo.systemUptime
    private var ready = false
    private var ended = false
    private var queuedVideo = 0
    private var queuedControl = 0
    var canAcceptVideo: Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        return queuedVideo < 2
    }
    private var _onVideoDrained: (() -> Void)?
    var onVideoDrained: (() -> Void)? {
        get {
            sendLock.lock()
            defer { sendLock.unlock() }
            return _onVideoDrained
        }
        set {
            sendLock.lock()
            _onVideoDrained = newValue
            sendLock.unlock()
        }
    }
    var onReady: (() -> Void)?
    var onControl: (([String: Any]) -> Void)?
    var onEnd: ((String, Bool) -> Void)?

    // Shared by production and the loopback interoperability test, so the
    // tested TLS profile is exactly the one used on the dedicated cable.
    static func tlsOptions(key: Data, identity: String = Wire.identity, queue: DispatchQueue) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        // TLS 1.2 PSK: the Apple client cannot complete external TLS 1.3 PSK
        // (verified against OpenSSL 4.1; see README). One non-forward-secret
        // suite is offered and required; no certificate path exists.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: Wire.pskSuite)!)
        sec_protocol_options_add_tls_application_protocol(options, Wire.alpn)
        sec_protocol_options_add_pre_shared_key(options, dispatchBytes(key), dispatchBytes(Data(identity.utf8)))
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        // TLS 1.2 renegotiation defaults to enabled in Network.framework.
        sec_protocol_options_set_tls_renegotiation_enabled(options, false)
        // PSK is the only authentication method; never accept a certificate.
        sec_protocol_options_set_verify_block(options, { _, _, completion in completion(false) }, queue)
        return tls
    }

    static func profileOK(_ connection: NWConnection) -> Bool {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
        let m = metadata.securityProtocolMetadata
        return sec_protocol_metadata_get_negotiated_tls_protocol_version(m) == .TLSv12
            && sec_protocol_metadata_get_negotiated_tls_ciphersuite(m).rawValue == Wire.pskSuite
            && negotiatedProtocol(m) == Wire.alpn
    }

    // The cable profile: TLS above, Nagle off, bounded connect, and no path
    // other than the one named interface. Wi-Fi, cellular and loopback are
    // prohibited outright so a missing cable can never fall back to them.
    static func cableParameters(key: Data, identity: String = Wire.identity, queue: DispatchQueue, interface: NWInterface) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: tlsOptions(key: key, identity: identity, queue: queue), tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.wifi, .cellular, .loopback]
        parameters.prohibitExpensivePaths = true
        parameters.allowLocalEndpointReuse = false
        parameters.requiredInterface = interface
        return parameters
    }

    // NWPathMonitor.availableInterfaces omits link-local-only Thunderbolt
    // bridges (bridge0 has no default route while Wi-Fi/Ethernet is active).
    // IPv6Address/IPv4Address("addr%iface").interface constructs the exact
    // kernel-scoped NWInterface directly from the validated interface name.
    static func scopedInterface(for endpoint: CableEndpoint) throws -> NWInterface {
        guard if_nametoindex(endpoint.interface) == endpoint.interfaceIndex else {
            throw SenderError("Selected interface changed; discover the receiver again")
        }
        let resolved = IPv6Address(endpoint.host)?.interface ?? IPv4Address(endpoint.host)?.interface
        guard let selected = resolved, selected.name == endpoint.interface, UInt32(selected.index) == endpoint.interfaceIndex else {
            throw SenderError("Selected interface is unavailable to Network.framework")
        }
        return selected
    }

    init(endpoint: CableEndpoint, key: Data, identity: String = Wire.identity) throws {
        guard key.count == PairingCode.bytes else { throw SenderError("Pairing code must be 16 bytes") }
        guard !identity.isEmpty, identity.utf8.count <= 128 else { throw SenderError("Invalid PSK identity") }
        let selected = try Self.scopedInterface(for: endpoint)
        let parameters = Self.cableParameters(key: key, identity: identity, queue: queue, interface: selected)
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: parameters)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.ended else { return }
                switch state {
                case .ready:
                    guard Self.profileOK(connection) else { self.finish("TLS profile negotiation failed", authFailed: true); return }
                    self.ready = true
                    self.lastReceived = ProcessInfo.processInfo.systemUptime
                    self.onReady?()
                    self.receive()
                case .waiting(let error), .failed(let error):
                    let isTLSAuthFailure: Bool
                    if case .tls = error {
                        isTLSAuthFailure = !self.ready
                    } else {
                        isTLSAuthFailure = false
                    }
                    self.finish("Thunderbolt connection or pairing failed: \(error). Check the cable, current receiver code and Local Network permission",
                                authFailed: isTLSAuthFailure)
                case .cancelled:
                    self.finish("Connection closed")
                default: break
                }
            }
            connection.start(queue: self.queue)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                guard let self, !self.ended, self.ready else { return }
                let age = ProcessInfo.processInfo.systemUptime - self.lastReceived
                guard age < 8 else {
                    self.finish(String(format: "Cable session timed out (no peer data for %.1fs)", age))
                    return
                }
                self.sendObject(["type": "ping"])
            }
            self.timer = timer
            timer.resume()
        }
    }

    static func negotiatedProtocol(_ metadata: sec_protocol_metadata_t) -> String? {
        if #available(macOS 15.5, *) {
            guard let copied = sec_protocol_metadata_copy_negotiated_protocol(metadata) else { return nil }
            defer { free(UnsafeMutableRawPointer(mutating: copied)) }
            return String(cString: copied)
        }
        guard let name = sec_protocol_metadata_get_negotiated_protocol(metadata) else { return nil }
        return String(cString: name)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            do {
                if let data, !data.isEmpty {
                    self.lastReceived = ProcessInfo.processInfo.systemUptime
                    try self.reader.feed(data) { payload in self.onControl?(try Wire.object(payload)) }
                }
                if let error {
                    self.finish("Cable disconnected (\(error))")
                } else if complete {
                    try self.reader.finish()
                    self.finish("Cable disconnected (peer closed)")
                } else {
                    self.receive()
                }
            } catch { self.finish("Invalid control stream") }
        }
    }
    func sendObject(_ object: [String: Any]) {
        do { _ = try send(try Wire.json(object), video: false) }
        catch { stop("Control message could not be sent") }
    }
    @discardableResult
    func sendVideo(_ data: Data) throws -> Bool { try send(data, video: true) }
    private func send(_ payload: Data, video: Bool) throws -> Bool {
        let framed = try Wire.frame(payload)
        sendLock.lock()
        if video && queuedVideo >= 32 {
            sendLock.unlock()
            return false
        }
        if !video && queuedControl >= 64 {
            sendLock.unlock()
            stop("Peer is not consuming the stream")
            return false
        }
        if video { queuedVideo += 1 } else { queuedControl += 1 }
        sendLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            guard self.ready, !self.ended, let connection = self.connection else {
                self.sendLock.lock()
                if video {
                    self.queuedVideo = max(0, self.queuedVideo - 1)
                } else {
                    self.queuedControl = max(0, self.queuedControl - 1)
                }
                self.sendLock.unlock()
                return
            }
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                var drainHandler: (() -> Void)?
                self.sendLock.lock()
                if video {
                    self.queuedVideo = max(0, self.queuedVideo - 1)
                    if self.queuedVideo < 2 {
                        drainHandler = self._onVideoDrained
                    }
                } else {
                    self.queuedControl = max(0, self.queuedControl - 1)
                }
                self.sendLock.unlock()
                if let error {
                    self.finish("Cable send failed (\(error))")
                } else {
                    drainHandler?()
                }
            })
        }
        return true
    }
    func stop(_ reason: String) { queue.async { self.finish(reason) } }
    private func finish(_ reason: String, authFailed: Bool = false) {
        guard !ended else { return }
        ended = true
        ready = false
        timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        onEnd?(reason, authFailed)
    }
}
