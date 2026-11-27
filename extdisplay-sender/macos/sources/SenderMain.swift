// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

struct Options {
    enum Mode {
        case graphical
        case check
        case connect(endpoint: CableEndpoint, identity: String, hostID: String?)
        case importPeer(token: String?)
        case listPeers
        case forgetPeer(hostID: String)
    }

    let mode: Mode

    init(_ arguments: [String]) throws {
        if arguments.isEmpty { mode = .graphical; return }
        if arguments == ["--check"] { mode = .check; return }
        if arguments == ["--list-peers"] { mode = .listPeers; return }
        if arguments.count == 2 && (arguments[0] == "--pair-token" || arguments[0] == "--import-peer") {
            // "-" reads the token from stdin so the long-lived secret never appears in argv.
            mode = .importPeer(token: arguments[1] == "-" ? nil : arguments[1])
            return
        }
        if arguments.count == 2 && arguments[0] == "--forget-peer" {
            mode = .forgetPeer(hostID: arguments[1])
            return
        }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard ["--interface", "--address", "--port", "--identity", "--host-id"].contains(name),
                  index + 1 < arguments.count,
                  values[name] == nil else { throw SenderError(Self.usage) }
            values[name] = arguments[index + 1]
            index += 2
        }
        guard let interface = values["--interface"], let address = values["--address"],
              let portText = values["--port"], let port = UInt16(portText)
        else { throw SenderError(Self.usage) }
        let identity = values["--identity"] ?? Wire.identity
        guard PeerStore.validIdentity(identity) else { throw SenderError("Invalid PSK identity") }
        let hostID = values["--host-id"]
        if let hostID, !PeerStore.validHostID(hostID) { throw SenderError("Invalid host identifier") }
        let endpoint = try CableEndpoint(host: address, port: port, interface: interface)
        mode = .connect(endpoint: endpoint, identity: identity, hostID: hostID)
    }

    static let usage = """
    usage: locachy-macos-sender
           locachy-macos-sender --interface IFACE --address LINK_LOCAL --port PORT [--identity ID] [--host-id HOSTID]
           locachy-macos-sender --pair-token -        (token read from stdin)
           locachy-macos-sender --list-peers
           locachy-macos-sender --forget-peer HOSTID
           locachy-macos-sender --check
    No arguments opens automatic Thunderbolt discovery and the connection window.
    """
}

@available(macOS 14.0, *)
final class Sender {
    private static let inputTypes: Set<String> = [
        "key", "pointer", "button", "scroll", "cancel", "touch", "tablet", "capsLockToggle", "capsLockState"
    ]
    private let endpoint: CableEndpoint
    private let transport: SecureTransport
    private let inputCoordinator: InputCoordinator
    private let discoveredHostID: String?
    private let captureLock = NSLock()
    private var capture: CaptureSession?
    private var inputCapture: CaptureSession?
    private var activePanel: Panel?
    private var startTask: Task<Void, Never>?
    private var finished = false
    var onActive: ((Panel) -> Void)?
    var onPairGrant: ((String, String, String, String) -> Void)?
    var onEnd: ((String, Int32, Bool) -> Void)?

    init(endpoint: CableEndpoint, key: Data, identity: String = Wire.identity,
         discoveredHostID: String? = nil,
         inputCoordinator: InputCoordinator = .shared) throws {
        // Revalidate immediately before dialing, including bridge members and
        // the interface index. Advertisements are not authorization.
        try LinkInterfaces.require(endpoint.interface, index: endpoint.interfaceIndex)
        self.endpoint = endpoint
        self.inputCoordinator = inputCoordinator
        self.discoveredHostID = discoveredHostID
        transport = try SecureTransport(endpoint: endpoint, key: key, identity: identity)
        transport.onControl = { [weak self] object in
            guard let self else { return }
            if let type = object["type"] as? String {
                if type == "ping" {
                    // Reply on the transport queue directly so main-thread work never stalls keepalive.
                    var pong: [String: Any] = ["type": "pong", "mt": Int(Date().timeIntervalSince1970 * 1000)]
                    if object["t"] != nil, let ts = try? Wire.integer(object, "t", 0...Int.max) {
                        pong["t"] = ts
                    }
                    self.transport.sendObject(pong)
                    return
                }
                if type == "kf" {
                    self.captureLock.lock()
                    let session = self.inputCapture
                    self.captureLock.unlock()
                    session?.requestKeyframe()
                    return
                }
                if Self.inputTypes.contains(type) {
                    self.inputCoordinator.queue.async { [weak self] in self?.handleRemoteInput(object, type: type) }
                    return
                }
            }
            DispatchQueue.main.async { [weak self] in self?.control(object) }
        }
        transport.onEnd = { [weak self] reason, authFailed in
            DispatchQueue.main.async { self?.finish(reason, code: 1, authFailed: authFailed) }
        }
    }

    func run() {
        SenderLog.info("Connecting to \(endpoint.host):\(endpoint.port) over \(endpoint.interface)")
        transport.start()
    }

    private func handleRemoteInput(_ object: [String: Any], type: String) {
        captureLock.lock()
        let session = inputCapture
        captureLock.unlock()
        guard let session else { return }
        do {
            try session.handleInput(object)
        } catch {
            if type == "key" {
                let code = object["code"].map { "\($0)" } ?? "nil"
                let sym = object["keysym"].map { "\($0)" } ?? "nil"
                SenderLog.info("Ignored unmapped key (code=\(code) keysym=\(sym)): \(error)")
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.finish("Rejected malformed remote input", code: 1)
                }
            }
        }
    }

    private func control(_ object: [String: Any]) {
        guard !finished, let type = object["type"] as? String else { return }
        do {
            switch type {
            case "hello":
                let panel = try Panel(hello: object, discoveredHostID: discoveredHostID)
                if let current = activePanel {
                    if current != panel { finish("Receiver panel changed; reconnect to resize", code: 0) }
                    return
                }
                activePanel = panel
                if let hostID = panel.hostID,
                   let grantIdentity = panel.peerGrantIdentity,
                   let grantCode = panel.peerGrantCode {
                    onPairGrant?(hostID, panel.displayLabel, grantIdentity, grantCode)
                }
                let acceptedInput = Wire.capabilities + Wire.optionalCapabilities.filter { panel.supportedInput.contains($0) }
                transport.sendObject(["type": "welcome", "locachy": 1, "extended": true, "input": acceptedInput])
                let session = CaptureSession(
                    transport: transport,
                    panel: panel,
                    hostIDOverride: discoveredHostID,
                    inputCoordinator: inputCoordinator
                )
                capture = session
                captureLock.lock()
                inputCapture = session
                captureLock.unlock()
                startTask = Task { @MainActor in
                    do {
                        try await session.start()
                        if !self.finished { self.onActive?(panel) }
                    } catch { self.finish(String(describing: error), code: 1) }
                }
            case "pairGrant":
                guard let panel = activePanel,
                      let hostID = (object["hostId"] as? String ?? object["hostid"] as? String ?? panel.hostID),
                      PeerStore.validHostID(hostID),
                      let grantIdentity = (object["peerIdentity"] as? String ?? object["identity"] as? String),
                      PeerStore.validIdentity(grantIdentity),
                      let grantCode = (object["peerKey"] as? String ?? object["peerCode"] as? String ?? object["code"] as? String)
                else { break }
                var decoded = try PeerStore.decodePSK(grantCode)
                decoded.resetBytes(in: 0..<decoded.count)
                let label = PeerStore.sanitizeDisplayName(object["name"] as? String, fallback: panel.displayLabel)
                onPairGrant?(hostID, label, grantIdentity, grantCode)
            case "ping":
                var pong: [String: Any] = ["type": "pong", "mt": Int(Date().timeIntervalSince1970 * 1000)]
                if object["t"] != nil { pong["t"] = try Wire.integer(object, "t", 0...Int.max) }
                transport.sendObject(pong)
            case "kf": capture?.requestKeyframe()
            case "closing", "sleeping": finish("Receiver ended the session", code: 0)
            default: break
            }
        } catch { finish(String(describing: error), code: 1) }
    }

    func stop(_ reason: String = "Stopped by the Mac") { finish(reason, code: 0) }
    private func finish(_ reason: String, code: Int32, authFailed: Bool = false) {
        guard !finished else { return }
        finished = true
        captureLock.lock()
        inputCapture = nil
        captureLock.unlock()
        // Close the transport immediately so a dead or superseded cable link
        // stops waiting on peer I/O while CaptureSession finishes teardown.
        transport.stop(reason)
        let pendingStart = startTask
        pendingStart?.cancel(); startTask = nil
        Task { @MainActor in
            // Do not let a suspended startCapture create a stream after cleanup.
            await pendingStart?.value
            if let capture = self.capture {
                await capture.stopAsync(reason)
                self.capture = nil
            } else {
                SenderLog.info(reason)
            }
            // The same cleanup serves both GUI retry and the one-shot CLI.
            try? await Task.sleep(for: .milliseconds(250))
            self.onEnd?(reason, code, authFailed)
        }
    }
}

@main
enum SenderMain {
    private static var signals: [DispatchSourceSignal] = []

    static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            switch options.mode {
            case .check:
                let available = ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
                    .allSatisfy { NSClassFromString($0) != nil }
                print(available ? "PASS: CGVirtualDisplay classes are present"
                                : "FAIL: CGVirtualDisplay is unavailable on this macOS")
                exit(available ? 0 : 1)
            case .importPeer(let token):
                let rawToken = token ?? (readLine(strippingNewline: true) ?? "")
                let peer = try PeerStore.parsePairingToken(rawToken)
                try PeerStore.shared.save(peer)
                print("Saved pairing credential for \(peer.displayName) (host=\(peer.hostID), identity=\(peer.identity))")
                exit(0)
            case .listPeers:
                let peers = PeerStore.shared.all()
                if peers.isEmpty {
                    print("No paired LOCachy receivers stored.")
                } else {
                    for peer in peers {
                        print("\(peer.hostID)\t\(peer.displayName)\t\(peer.identity)\tlastUsed=\(peer.lastUsedAt)")
                    }
                }
                exit(0)
            case .forgetPeer(let hostID):
                guard PeerStore.validHostID(hostID) else { throw SenderError("Invalid host identifier") }
                if PeerStore.shared.remove(hostID: hostID) {
                    print("Removed stored credential for \(hostID)")
                    exit(0)
                } else {
                    fputs("locachy-macos: No stored credential for \(hostID)\n", stderr)
                    exit(1)
                }
            case .graphical:
                guard #available(macOS 14.0, *) else { throw SenderError("macOS 14 or later is required") }
                let app = NSApplication.shared
                let controller = ConnectionWindow()
                app.delegate = controller
                app.setActivationPolicy(.accessory)
                withExtendedLifetime(controller) { app.run() }
            case .connect(let endpoint, let cliIdentity, let hostID):
                guard #available(macOS 14.0, *) else { throw SenderError("macOS 14 or later is required") }
                try LinkInterfaces.require(endpoint.interface, index: endpoint.interfaceIndex)
                let resolvedIdentity: String
                var key: Data
                if let hostID, let stored = PeerStore.shared.lookup(hostID: hostID), cliIdentity == Wire.identity {
                    key = try PeerStore.decodePSK(stored.pskBase32)
                    resolvedIdentity = stored.identity
                } else {
                    key = try PairingCode.read()
                    resolvedIdentity = cliIdentity
                }
                defer { key.resetBytes(in: 0..<key.count) }
                let sender = try Sender(endpoint: endpoint, key: key, identity: resolvedIdentity, discoveredHostID: hostID)
                key.resetBytes(in: 0..<key.count)
                sender.onEnd = { _, code, _ in
                    InputCoordinator.shared.shutdown()
                    exit(code)
                }
                for number in [SIGINT, SIGTERM, SIGHUP] {
                    signal(number, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                    source.setEventHandler { sender.stop() }
                    source.resume(); signals.append(source)
                }
                sender.run()
                withExtendedLifetime(sender) { dispatchMain() }
            }
        } catch {
            fputs("locachy-macos: \(error)\n", stderr)
            exit(2)
        }
    }
}
