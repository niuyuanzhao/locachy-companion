// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

struct Options {
    let endpoint: CableEndpoint?
    let check: Bool
    let graphical: Bool

    init(_ arguments: [String]) throws {
        if arguments.isEmpty { endpoint = nil; check = false; graphical = true; return }
        if arguments == ["--check"] { endpoint = nil; check = true; graphical = false; return }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard ["--interface", "--address", "--port"].contains(name), index + 1 < arguments.count,
                  values[name] == nil else { throw SenderError(Self.usage) }
            values[name] = arguments[index + 1]
            index += 2
        }
        guard let interface = values["--interface"], let address = values["--address"],
              let portText = values["--port"], let port = UInt16(portText)
        else { throw SenderError(Self.usage) }
        endpoint = try CableEndpoint(host: address, port: port, interface: interface)
        check = false
        graphical = false
    }

    static let usage = """
    usage: locachy-macos-sender
           locachy-macos-sender --interface IFACE --address LINK_LOCAL --port PORT
           locachy-macos-sender --check
    No arguments opens automatic Thunderbolt discovery and the connection window.
    """
}

@available(macOS 14.0, *)
final class Sender {
    private let transport: SecureTransport
    private var capture: CaptureSession?
    private var activePanel: Panel?
    private var startTask: Task<Void, Never>?
    private var finished = false
    var onActive: (() -> Void)?
    var onEnd: ((String, Int32) -> Void)?

    init(endpoint: CableEndpoint, key: Data) throws {
        // Revalidate immediately before dialing, including bridge members and
        // the interface index. Advertisements are not authorization.
        try LinkInterfaces.require(endpoint.interface, index: endpoint.interfaceIndex)
        transport = try SecureTransport(endpoint: endpoint, key: key)
        transport.onControl = { [weak self] object in DispatchQueue.main.async { self?.control(object) } }
        transport.onEnd = { [weak self] reason in DispatchQueue.main.async { self?.finish(reason, code: 1) } }
    }

    func run() {
        SenderLog.info("Connecting over the selected Thunderbolt link")
        transport.start()
    }

    private func control(_ object: [String: Any]) {
        guard !finished, let type = object["type"] as? String else { return }
        do {
            switch type {
            case "hello":
                let panel = try Panel(hello: object)
                if let current = activePanel {
                    if current != panel { finish("Receiver panel changed; reconnect to resize", code: 0) }
                    return
                }
                activePanel = panel
                let acceptedInput = Wire.capabilities + Wire.optionalCapabilities.filter { panel.supportedInput.contains($0) }
                transport.sendObject(["type": "welcome", "locachy": 1, "extended": true, "input": acceptedInput])
                let session = CaptureSession(transport: transport, panel: panel)
                capture = session
                startTask = Task { @MainActor in
                    do {
                        try await session.start()
                        if !self.finished { self.onActive?() }
                    } catch { self.finish(String(describing: error), code: 1) }
                }
            case "ping":
                var pong: [String: Any] = ["type": "pong", "mt": Int(Date().timeIntervalSince1970 * 1000)]
                if object["t"] != nil { pong["t"] = try Wire.integer(object, "t", 0...Int.max) }
                transport.sendObject(pong)
            case "kf": capture?.requestKeyframe()
            case "closing", "sleeping": finish("Receiver ended the session", code: 0)
            case "key", "pointer", "button", "scroll", "cancel", "touch", "tablet":
                guard let capture else { return }
                MainActor.assumeIsolated {
                    do { try capture.handleInput(object) }
                    catch {
                        if type == "key" { SenderLog.info("Ignored unmapped key: \(error)") }
                        else { self.finish("Rejected malformed remote input", code: 1) }
                    }
                }
            default: break
            }
        } catch { finish(String(describing: error), code: 1) }
    }

    func stop() { finish("Stopped by the Mac", code: 0) }
    private func finish(_ reason: String, code: Int32) {
        guard !finished else { return }
        finished = true
        let pendingStart = startTask
        pendingStart?.cancel(); startTask = nil
        Task { @MainActor in
            // Do not let a suspended startCapture create a stream after cleanup.
            await pendingStart?.value
            if let capture = self.capture {
                capture.stop(reason)
                self.capture = nil
            } else {
                SenderLog.info(reason)
            }
            self.transport.stop(reason)
            // The same cleanup serves both GUI retry and the one-shot CLI.
            try? await Task.sleep(for: .milliseconds(250))
            self.onEnd?(reason, code)
        }
    }
}

@main
enum SenderMain {
    private static var signals: [DispatchSourceSignal] = []

    static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.check {
                let available = ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
                    .allSatisfy { NSClassFromString($0) != nil }
                print(available ? "PASS: CGVirtualDisplay classes are present"
                                : "FAIL: CGVirtualDisplay is unavailable on this macOS")
                exit(available ? 0 : 1)
            }
            guard #available(macOS 14.0, *) else { throw SenderError("macOS 14 or later is required") }
            if options.graphical {
                let app = NSApplication.shared
                let controller = ConnectionWindow()
                app.delegate = controller
                app.setActivationPolicy(.accessory)
                withExtendedLifetime(controller) { app.run() }
            } else {
                guard let endpoint = options.endpoint else { throw SenderError(Options.usage) }
                try LinkInterfaces.require(endpoint.interface, index: endpoint.interfaceIndex)
                var key = try PairingCode.read()
                defer { key.resetBytes(in: 0..<key.count) }
                let sender = try Sender(endpoint: endpoint, key: key)
                key.resetBytes(in: 0..<key.count)
                sender.onEnd = { _, code in exit(code) }
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
