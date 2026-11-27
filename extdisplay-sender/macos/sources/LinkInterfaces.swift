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

struct PeerPortCounts: Equatable {
    let active: Int
    let inactive: Int
    var total: Int { active + inactive }
}

struct LinkSnapshot {
    var links: [CableLink]
    var message: String
    var activePorts: Set<String>
    var activeConnections: Set<UInt64>
    var multiPeerPorts: [String: PeerPortCounts]
    // A failed check is not an unplug. `complete` is false when the interface or
    // Thunderbolt list could not be read at all; `undetermined` names interfaces
    // whose state could not be established (an unreadable bridge, or a standalone
    // port while some bridge is unreadable). Both stay fail-closed for dialing.
    var complete: Bool
    var undetermined: Set<String>

    init(links: [CableLink], message: String, activePorts: Set<String> = [],
         activeConnections: Set<UInt64> = [],
         multiPeerPorts: [String: PeerPortCounts] = [:],
         complete: Bool = true, undetermined: Set<String> = []) {
        self.links = links
        self.message = message
        self.activePorts = activePorts
        self.activeConnections = activeConnections
        self.multiPeerPorts = multiPeerPorts
        self.complete = complete
        self.undetermined = undetermined
    }

    var isCertain: Bool { complete && undetermined.isEmpty }
    func determines(_ link: CableLink) -> Bool { complete && !undetermined.contains(link.name) }
    // Only a link this check established can be reported as gone.
    func isLost(_ link: CableLink) -> Bool { determines(link) && !links.contains { $0.index == link.index } }
}

// Classification is separate from the system queries so bridge and hotplug cases
// can be tested without inspecting or changing the machine's network settings.
enum LinkInterfaces {
    struct Interface {
        let name: String
        let index: UInt32
        let bridge: Bool
        let ready: Bool
        let carrierActive: Bool

        init(name: String, index: UInt32, bridge: Bool, ready: Bool, carrierActive: Bool = true) {
            self.name = name
            self.index = index
            self.bridge = bridge
            self.ready = ready
            self.carrierActive = carrierActive
        }
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
        var activePorts = Set<String>()
        var undetermined = Set<String>()
        var unverifiedBridge = false
        for interface in interfaces where interface.bridge {
            guard let ports = members[interface.name] else {
                undetermined.insert(interface.name)
                unverifiedBridge = true
                continue
            }
            guard !ports.isEmpty, ports.count <= 32,
                  Set(ports).count == ports.count,
                  ports.allSatisfy({ known[$0] != nil }) else {
                // Never bypass an uninspectable bridge by dialing a member.
                covered.formUnion(ports)
                if !ports.isEmpty { undetermined.insert(interface.name) }
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
            // macOS keeps bridge0 UP|RUNNING with fe80:: even when every Thunderbolt
            // cable is unplugged. Require an active physical carrier on at least one
            // Thunderbolt bridge member before treating the bridge link as ready.
            let activeMembers = ports.filter { known[$0]?.carrierActive == true }
            if interface.ready && !activeMembers.isEmpty {
                accepted.append(CableLink(name: interface.name, index: interface.index, bridged: true))
                activePorts.formUnion(activeMembers)
            }
        }
        // An unreadable bridge map cannot prove that a standalone port is not a
        // member. Fail closed for those ports (never dial them) rather than widening
        // the path to an unknown LAN, but do not call them lost either. A verified
        // Thunderbolt-only bridge stays usable: xnu's bridge_ioctl_add refuses a
        // member that already belongs to a bridge (EBUSY) and any bridge as a member.
        let unreadableBridge = !undetermined.isEmpty
        for interface in interfaces where !interface.bridge && interface.ready
            && interface.carrierActive
            && thunderbolt.contains(interface.name) && !covered.contains(interface.name) {
            if unreadableBridge {
                undetermined.insert(interface.name)
            } else {
                accepted.append(CableLink(name: interface.name, index: interface.index, bridged: false))
                activePorts.insert(interface.name)
            }
        }
        accepted.sort { $0.name < $1.name }
        let message: String
        if !accepted.isEmpty { message = "Thunderbolt link ready. Looking for LOCachy…" }
        else if unverifiedBridge { message = "Cannot verify a Thunderbolt-only bridge." }
        else if !thunderbolt.isEmpty { message = "Waiting for the Thunderbolt network link and its IPv6 address…" }
        else { message = "Connect the Thunderbolt/USB4 cable, directly or through a compatible hub or dock." }
        return LinkSnapshot(links: accepted, message: message, activePorts: activePorts, undetermined: undetermined)
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
            return LinkSnapshot(links: [], message: "Cannot read the network interface list.", complete: false)
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
        guard let tbPorts = thunderboltPorts() else {
            return LinkSnapshot(links: [], message: "Cannot read the Thunderbolt interface list.", complete: false)
        }
        let list = interfaces.values.map { iface in
            Interface(
                name: iface.name,
                index: iface.index,
                bridge: iface.bridge,
                ready: iface.ready && localIPv6.contains(iface.name),
                carrierActive: tbPorts[iface.name]?.carrierActive ?? true
            )
        }
        let known = Set(interfaces.keys)
        var bridges: [String: [String]] = [:]
        // No private SCBridgeInterface API, shell, sudo or configuration write.
        for bridge in list.filter({ $0.bridge }).sorted(by: { $0.name < $1.name }).prefix(16) {
            if let output = try? queryBridge(bridge.name),
               let members = try? bridgeMembers(output, interface: bridge.name, known: known) {
                bridges[bridge.name] = members
            }
        }
        var snapshot = classify(list, thunderbolt: Set(tbPorts.keys), members: bridges)
        var activeConnections = Set<UInt64>()
        var multiPeerPorts: [String: PeerPortCounts] = [:]
        for (name, status) in tbPorts {
            if snapshot.activePorts.contains(name) {
                activeConnections.formUnion(status.activeConnections)
            }
            let counts = PeerPortCounts(active: status.activeConnections.count, inactive: status.inactiveConnections)
            if counts.total > 1 {
                multiPeerPorts[name] = counts
            }
        }
        snapshot.activeConnections = activeConnections
        snapshot.multiPeerPorts = multiPeerPorts
        return snapshot
    }

    static func require(_ name: String, index: UInt32? = nil) throws {
        let snapshot = inspect()
        guard snapshot.links.contains(where: { $0.name == name && (index == nil || $0.index == index) }) else {
            throw SenderError("The selected Thunderbolt path is no longer ready. " + snapshot.message)
        }
    }

    private struct ThunderboltPortStatus {
        let carrierActive: Bool
        let activeConnections: Set<UInt64>
        let inactiveConnections: Int
    }

    // Returns each Thunderbolt IP BSD interface name mapped to its hardware
    // carrier state (IOLinkStatus valid+active bits) and its child
    // AppleThunderboltIPConnection states. nil when IOKit itself fails.
    private static func thunderboltPorts() -> [String: ThunderboltPortStatus]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONetworkInterface"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var ports: [String: ThunderboltPortStatus] = [:]
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let name = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  validName(name) else { continue }
            var ancestor = entry
            IOObjectRetain(ancestor)
            var isIP = false
            var carrierActive: Bool? = nil
            var ipPortEntry: io_registry_entry_t = 0
            for _ in 0..<128 {
                if carrierActive == nil,
                   let raw = IORegistryEntryCreateCFProperty(ancestor, "IOLinkStatus" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                    let status = raw.uint64Value
                    // kIONetworkLinkValid = 0x1 (IFM_AVALID), kIONetworkLinkActive = 0x2 (IFM_ACTIVE)
                    if (status & 0x1) != 0 {
                        carrierActive = (status & 0x2) != 0
                    }
                }
                // A generic Thunderbolt ancestor would also accept a dock's
                // ordinary Ethernet adapter. Require the Thunderbolt IP driver.
                if IOObjectConformsTo(ancestor, "AppleThunderboltIPPort") != 0 {
                    isIP = true
                    ipPortEntry = ancestor
                    IOObjectRetain(ipPortEntry)
                    break
                }
                if IOObjectConformsTo(ancestor, "AppleThunderboltIPService") != 0 {
                    isIP = true
                    break
                }
                var parent: io_registry_entry_t = 0
                if IORegistryEntryGetParentEntry(ancestor, kIOServicePlane, &parent) != KERN_SUCCESS { break }
                IOObjectRelease(ancestor)
                ancestor = parent
            }
            IOObjectRelease(ancestor)
            var activeConnections = Set<UInt64>()
            var inactiveConnections = 0
            if ipPortEntry != 0 {
                defer { IOObjectRelease(ipPortEntry) }
                var children: io_iterator_t = 0
                if IORegistryEntryGetChildIterator(ipPortEntry, kIOServicePlane, &children) == KERN_SUCCESS {
                    defer { IOObjectRelease(children) }
                    while true {
                        let child = IOIteratorNext(children)
                        if child == 0 { break }
                        defer { IOObjectRelease(child) }
                        guard IOObjectConformsTo(child, "AppleThunderboltIPConnection") != 0 else { continue }
                        let state = (IORegistryEntryCreateCFProperty(
                            child, "Thunderbolt IP Connection State" as CFString, kCFAllocatorDefault, 0
                        )?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
                        if state == 1 {
                            var entryID: UInt64 = 0
                            if IORegistryEntryGetRegistryEntryID(child, &entryID) == KERN_SUCCESS {
                                activeConnections.insert(entryID)
                            }
                        } else {
                            inactiveConnections += 1
                        }
                    }
                }
            }
            if isIP {
                ports[name] = ThunderboltPortStatus(
                    carrierActive: carrierActive ?? true,
                    activeConnections: activeConnections,
                    inactiveConnections: inactiveConnections
                )
            }
        }
        return ports
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
// omit a secondary Thunderbolt path while Wi-Fi is the default route. IOKit
// interest notifications on the Thunderbolt IP port driver are an extra signal
// that has NOT been verified to fire on cable transitions: IOKit's controller
// link-state path (IONetworkController::setLinkStatus) broadcasts to interfaces,
// not to controller clients. Link snapshots remain the source of truth.
final class LinkWatcher {
    // Matches kIOMessageServiceIsTerminated = iokit_common_msg(0x010) in
    // IOKit/IOMessage.h: (UInt32)(err_system(0x38) | err_sub(0) | 0x010).
    // Defined explicitly because Swift does not import function-like C macros
    // from IOKit/IOMessage.h.
    private static let ioMessageServiceIsTerminated: UInt32 = 0xe000_0010

    private let queue = DispatchQueue(label: "locachy.sender.links")
    private let monitor = NWPathMonitor()
    private var route: DispatchSourceRead?
    private var ioNotifyPort: IONotificationPortRef?
    private var ioMatchIterators: [io_iterator_t] = []
    private var ioInterestTokens: [UInt64: io_object_t] = [:]
    private var ioFallbackInterestTokens: [io_object_t] = []
    private var pending: DispatchWorkItem?
    private var running = false
    private var stopped = false
    var onChange: ((LinkSnapshot) -> Void)?

    func start() {
        guard !running else { return }
        running = true
        stopped = false
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
        queue.async { [weak self] in self?.setupIOKitNotifications() }
        monitor.pathUpdateHandler = { [weak self] _ in self?.schedule() }
        monitor.start(queue: queue)
        queue.async { [weak self] in self?.schedule() }
    }

    private func setupIOKitNotifications() {
        guard !stopped, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, queue)
        ioNotifyPort = port
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for className in ["AppleThunderboltIPPort", "AppleThunderboltIPService"] {
            var iter: io_iterator_t = 0
            let kr = IOServiceAddMatchingNotification(
                port,
                kIOFirstMatchNotification,
                IOServiceMatching(className),
                { refcon, iterator in
                    guard let refcon else { return }
                    let watcher = Unmanaged<LinkWatcher>.fromOpaque(refcon).takeUnretainedValue()
                    watcher.drainAndWatchPorts(iterator)
                },
                refcon,
                &iter
            )
            if kr == KERN_SUCCESS {
                ioMatchIterators.append(iter)
                drainAndWatchPorts(iter)
            }
        }
    }

    private func drainAndWatchPorts(_ iterator: io_iterator_t) {
        guard !stopped, let port = ioNotifyPort else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var sawAny = false
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            sawAny = true
            var entryID: UInt64 = 0
            let hasEntryID = IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS
            if hasEntryID && ioInterestTokens[entryID] != nil {
                IOObjectRelease(service)
                continue
            }
            var token: io_object_t = 0
            let kr = IOServiceAddInterestNotification(
                port,
                service,
                kIOGeneralInterest,
                { refcon, service, messageType, _ in
                    guard let refcon else { return }
                    let watcher = Unmanaged<LinkWatcher>.fromOpaque(refcon).takeUnretainedValue()
                    watcher.handleInterest(service: service, messageType: messageType)
                },
                refcon,
                &token
            )
            if kr == KERN_SUCCESS {
                if hasEntryID {
                    ioInterestTokens[entryID] = token
                } else {
                    ioFallbackInterestTokens.append(token)
                }
            }
            IOObjectRelease(service)
        }
        if sawAny { schedule() }
    }

    private func handleInterest(service: io_service_t, messageType: UInt32) {
        guard !stopped else { return }
        if messageType == Self.ioMessageServiceIsTerminated {
            var entryID: UInt64 = 0
            if service != 0,
               IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
               let token = ioInterestTokens.removeValue(forKey: entryID) {
                IOObjectRelease(token)
            }
        }
        schedule()
    }

    private func teardownIOKitNotifications() {
        for token in ioInterestTokens.values { IOObjectRelease(token) }
        ioInterestTokens.removeAll()
        for token in ioFallbackInterestTokens { IOObjectRelease(token) }
        ioFallbackInterestTokens.removeAll()
        for iter in ioMatchIterators { IOObjectRelease(iter) }
        ioMatchIterators.removeAll()
        if let port = ioNotifyPort {
            IONotificationPortDestroy(port)
            ioNotifyPort = nil
        }
    }

    func refresh() { queue.async { [weak self] in self?.schedule() } }
    private func schedule() {
        guard !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            let snapshot = LinkInterfaces.inspect()
            DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    func stop() {
        monitor.cancel()
        route?.cancel(); route = nil
        onChange = nil
        // Asynchronous: an inspect() in flight can hold the queue for seconds
        // (bridge queries), and quitting must not wait for it. onChange is already
        // nil, so a snapshot finishing meanwhile reaches nobody.
        queue.async {
            self.stopped = true
            self.pending?.cancel(); self.pending = nil
            self.teardownIOKitNotifications()
        }
    }
    deinit {
        monitor.cancel()
        route?.cancel()
        pending?.cancel()
        teardownIOKitNotifications()
    }
}
