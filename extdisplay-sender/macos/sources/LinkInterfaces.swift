// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import IOKit
import Network

struct CableLink: Equatable, Hashable {
    let name: String
    let index: UInt32
    let bridged: Bool
}

struct LinkSnapshot {
    var links: [CableLink]
    var message: String
}

// Classification is separate from the system queries so bridge and hotplug cases
// can be tested without inspecting or changing the machine's network settings.
enum LinkInterfaces {
    struct Interface {
        let name: String
        let index: UInt32
        let bridge: Bool
        let ready: Bool
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count < Int(IFNAMSIZ)
            && name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || [45, 46, 95].contains($0) }
            && name != "." && name != ".."
    }

    static func classify(_ interfaces: [Interface], thunderbolt: Set<String>,
                         members: [String: [String]]) -> LinkSnapshot {
        let known = Dictionary(interfaces.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var covered = Set<String>(), accepted: [CableLink] = []
        var unverifiedBridge = false
        for interface in interfaces where interface.bridge {
            guard let ports = members[interface.name], !ports.isEmpty, ports.count <= 32,
                  Set(ports).count == ports.count,
                  ports.allSatisfy({ known[$0] != nil }) else {
                // Never bypass an uninspectable bridge by dialing a member.
                covered.formUnion(members[interface.name] ?? [])
                unverifiedBridge = true
                continue
            }
            let hasThunderbolt = ports.contains { thunderbolt.contains($0) }
            guard hasThunderbolt else {
                // An unrelated bridge (e.g. VM bridge100 with vmenet0) is ignored.
                covered.formUnion(ports)
                continue
            }
            guard ports.allSatisfy({ thunderbolt.contains($0) }) else {
                // Never bypass a mixed Thunderbolt + Ethernet bridge.
                covered.formUnion(ports)
                unverifiedBridge = true
                continue
            }
            covered.formUnion(ports)
            if interface.ready { accepted.append(CableLink(name: interface.name, index: interface.index, bridged: true)) }
        }
        // An unreadable bridge map cannot prove that a physical port is not a
        // member. Fail closed rather than widening the path to an unknown LAN.
        let unreadableBridge = interfaces.contains { $0.bridge && members[$0.name] == nil }
        if !unreadableBridge {
            for interface in interfaces where !interface.bridge && interface.ready
                && thunderbolt.contains(interface.name) && !covered.contains(interface.name) {
                accepted.append(CableLink(name: interface.name, index: interface.index, bridged: false))
            }
        } else { accepted.removeAll() }
        accepted.sort { $0.name < $1.name }
        let message: String
        if !accepted.isEmpty { message = "Thunderbolt link ready. Looking for LOCachy…" }
        else if unverifiedBridge { message = "Cannot verify a Thunderbolt-only bridge." }
        else if !thunderbolt.isEmpty { message = "Waiting for the Thunderbolt network link and its IPv6 address…" }
        else { message = "Connect the Thunderbolt/USB4 cable, directly or through a compatible hub or dock." }
        return LinkSnapshot(links: accepted, message: message)
    }

    static func bridgeMembers(_ output: Data, interface: String, known: Set<String>) throws -> [String] {
        guard output.count <= 65536, let text = String(data: output, encoding: .utf8),
              !text.contains("\0"), text.hasPrefix(interface + ":") else {
            throw SenderError("Cannot read the bridge membership")
        }
        var members: [String] = []
        for line in text.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.first == "member:" else { continue }
            guard words.count >= 2, validName(String(words[1])), known.contains(String(words[1])), members.count < 32,
                  !members.contains(String(words[1])) else { throw SenderError("Invalid bridge membership") }
            members.append(String(words[1]))
        }
        return members
    }

    static func inspect() -> LinkSnapshot {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return LinkSnapshot(links: [], message: "Cannot read the network interface list.")
        }
        defer { freeifaddrs(first) }
        var interfaces: [String: Interface] = [:]
        var localIPv6 = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let item = current.pointee
            let name = String(cString: item.ifa_name)
            if validName(name), let address = item.ifa_addr {
                if Int32(address.pointee.sa_family) == AF_LINK {
                    let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
                    let flags = item.ifa_flags
                    // Bridges expose an Ethernet sdl_type on macOS. AF_LINK's
                    // ifa_data carries the real if_data.ifi_type (IFT_BRIDGE).
                    let kernelType = item.ifa_data.map { UnsafeRawPointer($0).assumingMemoryBound(to: if_data.self).pointee.ifi_type }
                    interfaces[name] = Interface(name: name, index: UInt32(link.sdl_index),
                        bridge: kernelType == 0xd1 || link.sdl_type == 0xd1,
                        ready: flags & UInt32(IFF_UP) != 0 && flags & UInt32(IFF_RUNNING) != 0)
                } else if Int32(address.pointee.sa_family) == AF_INET6 {
                    let a = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    if withUnsafeBytes(of: a, { $0[0] == 0xfe && $0[1] & 0xc0 == 0x80 }) { localIPv6.insert(name) }
                }
            }
            cursor = item.ifa_next
        }
        let list = interfaces.values.map { Interface(name: $0.name, index: $0.index, bridge: $0.bridge,
                                                     ready: $0.ready && localIPv6.contains($0.name)) }
        let known = Set(interfaces.keys)
        var bridges: [String: [String]] = [:]
        // No private SCBridgeInterface API, shell, sudo or configuration write.
        for bridge in list.filter({ $0.bridge }).prefix(16) {
            if let output = try? queryBridge(bridge.name),
               let members = try? bridgeMembers(output, interface: bridge.name, known: known) {
                bridges[bridge.name] = members
            }
        }
        return classify(list, thunderbolt: thunderboltNames(), members: bridges)
    }

    static func require(_ name: String, index: UInt32? = nil) throws {
        let snapshot = inspect()
        guard snapshot.links.contains(where: { $0.name == name && (index == nil || $0.index == index) }) else {
            throw SenderError("The selected Thunderbolt path is no longer ready. " + snapshot.message)
        }
    }

    private static func thunderboltNames() -> Set<String> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONetworkInterface"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names = Set<String>()
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let name = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  validName(name) else { continue }
            var ancestor = entry
            IOObjectRetain(ancestor)
            var isIP = false
            for _ in 0..<128 {
                // A generic Thunderbolt ancestor would also accept a dock's
                // ordinary Ethernet adapter. Require the Thunderbolt IP driver.
                if IOObjectConformsTo(ancestor, "AppleThunderboltIPPort") != 0
                    || IOObjectConformsTo(ancestor, "AppleThunderboltIPService") != 0 { isIP = true; break }
                var parent: io_registry_entry_t = 0
                if IORegistryEntryGetParentEntry(ancestor, kIOServicePlane, &parent) != KERN_SUCCESS { break }
                IOObjectRelease(ancestor)
                ancestor = parent
            }
            IOObjectRelease(ancestor)
            if isIP { names.insert(name) }
        }
        return names
    }

    private static func queryBridge(_ name: String) throws -> Data {
        guard validName(name) else { throw SenderError("Invalid interface name") }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = [name]
        process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        pipe.fileHandleForWriting.closeFile()
        let fd = pipe.fileHandleForReading.fileDescriptor
        defer { pipe.fileHandleForReading.closeFile() }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096), ended = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= 65536 else { break }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { ended = true; break }
            else if errno != EINTR && errno != EAGAIN { break }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&event, 1, 25)
        }
        if !ended {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw SenderError("Bridge inspection timed out or exceeded its output limit")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SenderError("Bridge inspection failed") }
        return output
    }
}

// AF_ROUTE reports changes on non-default links too. NWPathMonitor alone can
// omit a secondary Thunderbolt path while Wi-Fi is the default route.
final class LinkWatcher {
    private let queue = DispatchQueue(label: "locachy.sender.links")
    private let monitor = NWPathMonitor()
    private var route: DispatchSourceRead?
    private var pending: DispatchWorkItem?
    private var running = false
    var onChange: ((LinkSnapshot) -> Void)?

    func start() {
        guard !running else { return }
        running = true
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        if fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                var bytes = [UInt8](repeating: 0, count: 8192)
                while Darwin.read(fd, &bytes, bytes.count) > 0 { }
                self?.schedule()
            }
            source.setCancelHandler { close(fd) }
            route = source
            source.resume()
        }
        monitor.pathUpdateHandler = { [weak self] _ in self?.schedule() }
        monitor.start(queue: queue)
        queue.async { self.schedule() }
    }

    func refresh() { queue.async { self.schedule() } }
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = LinkInterfaces.inspect()
            DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    func stop() {
        monitor.cancel()
        route?.cancel(); route = nil
        queue.async { self.pending?.cancel(); self.pending = nil }
        onChange = nil
    }
    deinit { monitor.cancel(); route?.cancel(); pending?.cancel() }
}
