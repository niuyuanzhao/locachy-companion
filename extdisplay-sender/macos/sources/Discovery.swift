// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import dnssd
import Foundation

struct ReceiverChoice: Equatable {
    let id: String
    let name: String
    let link: CableLink
    let address: String
    let port: UInt16
    let code: String?
    let hostID: String?
    let paired: Bool

    init(id: String, name: String, link: CableLink, address: String, port: UInt16,
         code: String?, hostID: String? = nil, paired: Bool = false) {
        self.id = id
        self.name = name
        self.link = link
        self.address = address
        self.port = port
        self.code = code
        self.hostID = hostID
        self.paired = paired
    }

    var pairedOnly: Bool { paired && code == nil }
    var peerKey: String { hostID ?? name }
}

struct DiscoveryAdvertisement: Equatable {
    let code: String?
    let hostID: String?
    let paired: Bool

    var pairedOnly: Bool { paired && code == nil }
}

enum DiscoveryProfile {
    static let type = "_locachy-ext._tcp"
    static let domain = "local."
    static let port: UInt16 = 27183
    private static let allowedTXTKeys: Set<String> = ["pv", "extended", "pair", "code", "hostid", "paired"]

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 63
            && name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    static func validHostID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 8 && bytes.count <= 64 else { return false }
        return bytes.allSatisfy { b in
            (b >= 0x30 && b <= 0x39)
                || (b >= 0x41 && b <= 0x5a)
                || (b >= 0x61 && b <= 0x7a)
                || b == 0x5f || b == 0x2d
        }
    }

    static func parseTXT(_ data: Data) -> DiscoveryAdvertisement? {
        guard !data.isEmpty, data.count <= 512 else { return nil }
        let bytes = Array(data)
        var offset = 0, fields: [String: String] = [:]
        while offset < bytes.count {
            let count = Int(bytes[offset]); offset += 1
            guard count > 0, count <= bytes.count - offset,
                  let field = String(bytes: bytes[offset..<offset + count], encoding: .ascii),
                  field.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
            offset += count
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, fields[String(pair[0]).lowercased()] == nil else { return nil }
            fields[String(pair[0]).lowercased()] = String(pair[1])
        }
        guard Set(fields.keys).isSubset(of: allowedTXTKeys),
              fields["pv"] == "3", fields["extended"] == "1", fields["pair"] == "psk128" else {
            return nil
        }

        let hostID: String?
        if let rawHostID = fields["hostid"] {
            guard validHostID(rawHostID) else { return nil }
            hostID = rawHostID
        } else {
            hostID = nil
        }

        let paired: Bool
        if let rawPaired = fields["paired"] {
            guard rawPaired == "0" || rawPaired == "1" else { return nil }
            paired = rawPaired == "1"
        } else {
            paired = false
        }

        let code: String?
        if let rawCode = fields["code"] {
            var raw = Array(rawCode.utf8)
            defer { PairingCode.zero(&raw) }
            guard var decoded = try? raw.withUnsafeBufferPointer({ try PairingCode.decode($0) }) else {
                return nil
            }
            decoded.resetBytes(in: 0..<decoded.count)
            code = rawCode
        } else {
            code = nil
        }

        guard code != nil || (paired && hostID != nil) else { return nil }
        return DiscoveryAdvertisement(code: code, hostID: hostID, paired: paired)
    }

    static func validTXT(_ data: Data) -> Bool { parseTXT(data) != nil }

    static func address(_ source: sockaddr_in6, on index: UInt32) -> String? {
        guard source.sin6_family == sa_family_t(AF_INET6), index != 0,
              source.sin6_scope_id == 0 || source.sin6_scope_id == index else { return nil }
        var address = source.sin6_addr
        guard withUnsafeBytes(of: address, { $0[0] == 0xfe && $0[1] & 0xc0 == 0x80 }) else { return nil }
        // BSD may embed the scope in bytes 2/3 of a link-local sockaddr.
        let embedded = withUnsafeBytes(of: address) { UInt32($0[2]) << 8 | UInt32($0[3]) }
        guard embedded == 0 || embedded == index else { return nil }
        withUnsafeMutableBytes(of: &address) { $0[2] = 0; $0[3] = 0 }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { return nil }
        return String(cString: text)
    }

    static func preferred(_ choices: [ReceiverChoice], previous: String?) -> String? {
        if let previous, choices.contains(where: { $0.id == previous }) { return previous }
        return choices.count == 1 ? choices.first?.id : nil
    }
}

// Per-peer exponential backoff for automatic reconnection so transient
// Thunderbolt or WindowServer failures retry promptly at first without
// spinning in a tight loop, and reset immediately on physical replug or success.
struct ReconnectBackoff {
    static let baseDelay: TimeInterval = 1.5
    static let maxDelay: TimeInterval = 30.0

    private var failures: [String: Int] = [:]
    private var earliestAttempt: [String: TimeInterval] = [:]

    mutating func recordFailure(for key: String, now: TimeInterval) -> TimeInterval {
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        let shift = min(count - 1, 5)
        let delay = min(Self.maxDelay, Self.baseDelay * Double(1 << shift))
        earliestAttempt[key] = now + delay
        return delay
    }

    func canAttempt(_ key: String, now: TimeInterval) -> Bool {
        guard let readyAt = earliestAttempt[key] else { return true }
        return now >= readyAt
    }

    func remainingDelay(for key: String, now: TimeInterval) -> TimeInterval {
        guard let readyAt = earliestAttempt[key] else { return 0 }
        return max(0, readyAt - now)
    }

    func failureCount(for key: String) -> Int {
        failures[key] ?? 0
    }

    mutating func reset(for key: String) {
        failures.removeValue(forKey: key)
        earliestAttempt.removeValue(forKey: key)
    }

    mutating func resetAll() {
        failures.removeAll()
        earliestAttempt.removeAll()
    }
}

// DNS-SD callbacks, references and their contexts all live on the main queue.
// A browse is always scoped to one validated interface; no Any-interface browse,
// unicast DNS resolver, multicast reflection or discovery fallback exists.
final class ReceiverDiscovery {
    private var browsers: [UInt32: LinkBrowser] = [:]
    private var lastLinks: [CableLink] = []
    var onChange: (([ReceiverChoice]) -> Void)?
    var onError: ((String, Bool) -> Void)?

    func update(_ links: [CableLink], forceRestart: Bool = false) {
        lastLinks = links
        let wanted = Dictionary(links.prefix(16).map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, browser) in Array(browsers) where forceRestart || wanted[index] != browser.link {
            browser.stop(); browsers.removeValue(forKey: index)
        }
        for link in wanted.values where browsers[link.index] == nil {
            let browser = LinkBrowser(link: link)
            browser.onChange = { [weak self] in self?.changed() }
            browser.onError = { [weak self] message, isPolicy in self?.onError?(message, isPolicy) }
            browsers[link.index] = browser
            browser.start()
        }
        changed()
    }

    func restart() {
        update(lastLinks, forceRestart: true)
    }

    private func changed() {
        let choices = browsers.values.flatMap { $0.choices }.sorted { $0.id < $1.id }
        onChange?(Array(choices.prefix(64)))
    }

    func stop() {
        lastLinks = []
        for browser in browsers.values { browser.stop() }
        browsers.removeAll()
        onChange?([])
    }
    deinit { for browser in browsers.values { browser.stop() } }
}

enum DiscoveryErrorClassifier {
    static func isPolicyDenied(_ code: DNSServiceErrorType) -> Bool {
        code == kDNSServiceErr_PolicyDenied || code == kDNSServiceErr_NotPermitted
    }

    static func message(for code: DNSServiceErrorType) -> String {
        if isPolicyDenied(code) {
            return "Local Network access was denied. Enable it for this app in System Settings → Privacy & Security → Local Network."
        }
        return "Thunderbolt discovery failed (DNS-SD error \(code)). Retry after the link is ready."
    }
}

private final class LinkBrowser {
    let link: CableLink
    private var ref: DNSServiceRef?
    private var services: [String: DiscoveredService] = [:]
    private var retryWork: DispatchWorkItem?
    private var restartDelay: TimeInterval = 1.5
    private var stopped = false
    var onChange: (() -> Void)?
    var onError: ((String, Bool) -> Void)?
    var choices: [ReceiverChoice] { services.values.compactMap { $0.choice } }

    init(link: CableLink) { self.link = link }

    func start() {
        guard !stopped else { return }
        retryWork?.cancel(); retryWork = nil
        if let ref = ref { DNSServiceRefDeallocate(ref); self.ref = nil }
        let status = DNSServiceBrowse(&ref, 0, link.index, DiscoveryProfile.type, DiscoveryProfile.domain,
            { _, flags, index, error, name, type, domain, context in
                guard let context else { return }
                let owner = Unmanaged<LinkBrowser>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError else { owner.handleBrowseError(error); return }
                guard index == owner.link.index, let name, let type, let domain else { return }
                owner.browse(flags: flags, name: String(cString: name), type: String(cString: type), domain: String(cString: domain))
            }, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let ref else { handleBrowseError(status); return }
        let scheduled = DNSServiceSetDispatchQueue(ref, .main)
        if scheduled != kDNSServiceErr_NoError {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
            handleBrowseError(scheduled)
        }
    }

    private func handleBrowseError(_ code: DNSServiceErrorType) {
        guard !stopped else { return }
        if let ref = ref { DNSServiceRefDeallocate(ref); self.ref = nil }
        for service in services.values { service.stop() }
        services.removeAll()
        onChange?()
        let policy = DiscoveryErrorClassifier.isPolicyDenied(code)
        onError?(DiscoveryErrorClassifier.message(for: code), policy)
        // Policy denial also retries on a slower cadence: there is no Local
        // Network permission change callback (TN3179), and DNSServiceBrowse
        // does not recover automatically once its ref is deallocated.
        scheduleRestart(delay: policy ? 5.0 : nil)
    }

    private func scheduleRestart(delay fixedDelay: TimeInterval? = nil) {
        retryWork?.cancel()
        let delay: TimeInterval
        if let fixedDelay {
            delay = fixedDelay
        } else {
            delay = restartDelay
            restartDelay = min(15.0, restartDelay * 2.0)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.start()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Backoff restarts only after a receiver actually resolves, so a receiver that
    // is listed but never resolvable cannot cause a tight restart loop.
    private func serviceChanged() {
        if services.values.contains(where: { $0.choice != nil }) { restartDelay = 1.5 }
        onChange?()
    }

    private func browse(flags: DNSServiceFlags, name: String, type: String, domain: String) {
        guard !stopped, DiscoveryProfile.validName(name), type == DiscoveryProfile.type + ".", domain == DiscoveryProfile.domain else { return }
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) == 0 {
            services.removeValue(forKey: name)?.stop(); onChange?(); return
        }
        if let existing = services[name] {
            if existing.isActive { return }
            existing.stop()
            services.removeValue(forKey: name)
        }
        guard services.count < 16 else { return }
        let service = DiscoveredService(link: link, name: name)
        service.onChange = { [weak self] in self?.serviceChanged() }
        service.onError = { [weak self] msg, policy in self?.onError?(msg, policy) }
        service.onInvalidated = { [weak self, weak service] policyDenied in
            guard let self, let service, self.services[name] === service else { return }
            // A single unresolvable receiver must not wedge discovery: drop only this
            // entry and re-browse after backoff so a still-present service is found again.
            self.services.removeValue(forKey: name)
            self.onChange?()
            if !self.stopped { self.scheduleRestart(delay: policyDenied ? 5.0 : nil) }
        }
        services[name] = service
        service.start()
    }

    func stop() {
        stopped = true
        retryWork?.cancel(); retryWork = nil
        if let ref = ref { DNSServiceRefDeallocate(ref) }; ref = nil
        for service in services.values { service.stop() }
        services.removeAll()
    }
    deinit { stop() }
}

private final class DiscoveredService {
    let link: CableLink
    let name: String
    var choice: ReceiverChoice?
    var onChange: (() -> Void)?
    var onError: ((String, Bool) -> Void)?
    var onInvalidated: ((Bool) -> Void)?
    private var resolve: DNSServiceRef?
    private var addresses: DNSServiceRef?
    private var timeout: DispatchWorkItem?
    private var host = ""
    private var advertisement: DiscoveryAdvertisement?
    private var knownAddresses: [String] = []
    private var stopped = false
    var isActive: Bool { !stopped && resolve != nil }

    init(link: CableLink, name: String) { self.link = link; self.name = name }
    func start() {
        guard !stopped else { return }
        let status = DNSServiceResolve(&resolve, DNSServiceFlags(kDNSServiceFlagsForceMulticast), link.index,
            name, DiscoveryProfile.type, DiscoveryProfile.domain,
            { _, _, index, error, _, target, port, length, txt, context in
                guard let context else { return }
                let owner = Unmanaged<DiscoveredService>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError else { owner.handleServiceError(error); return }
                guard index == owner.link.index, let target, let txt else { return }
                owner.resolved(target: String(cString: target), port: UInt16(bigEndian: port), txt: Data(bytes: txt, count: Int(length)))
            }, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let resolve else { handleServiceError(status); return }
        let scheduled = DNSServiceSetDispatchQueue(resolve, .main)
        guard scheduled == kDNSServiceErr_NoError else { handleServiceError(scheduled); return }
        let work = DispatchWorkItem { [weak self] in self?.expirePending() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func handleServiceError(_ code: DNSServiceErrorType) {
        guard !stopped else { return }
        let policy = DiscoveryErrorClassifier.isPolicyDenied(code)
        // Transient per-service errors (e.g. NoSuchRecord, Timeout, BadInterfaceIndex
        // during hot-unplug) invalidate this service entry cleanly without blocking
        // future re-discovery or raising a sticky UI error banner.
        if policy {
            onError?(DiscoveryErrorClassifier.message(for: code), true)
        }
        stop()
        onInvalidated?(policy)
    }

    private func resolved(target: String, port: UInt16, txt: Data) {
        guard !stopped else { return }
        guard port == DiscoveryProfile.port, let adv = DiscoveryProfile.parseTXT(txt), target.utf8.count <= 253,
              target.lowercased().hasSuffix(".local."), !target.contains("%"),
              target.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) else {
            if let addresses = addresses { DNSServiceRefDeallocate(addresses) }; addresses = nil
            host = ""; advertisement = nil; knownAddresses.removeAll(); choice = nil; onChange?()
            return
        }
        advertisement = adv
        if host == target, addresses != nil {
            if let existing = choice,
               existing.code != adv.code || existing.hostID != adv.hostID || existing.paired != adv.paired {
                choice = ReceiverChoice(id: existing.id, name: existing.name, link: existing.link,
                                        address: existing.address, port: existing.port,
                                        code: adv.code, hostID: adv.hostID, paired: adv.paired)
                onChange?()
            } else if choice == nil, let addr = knownAddresses.first {
                choice = ReceiverChoice(id: "\(link.index)/\(name)", name: name, link: link, address: addr,
                                        port: DiscoveryProfile.port, code: adv.code, hostID: adv.hostID, paired: adv.paired)
                onChange?()
            }
            return
        }
        if let addresses = addresses { DNSServiceRefDeallocate(addresses) }; addresses = nil
        knownAddresses.removeAll()
        choice = nil; onChange?()
        host = target
        let status = DNSServiceGetAddrInfo(&addresses, DNSServiceFlags(kDNSServiceFlagsForceMulticast), link.index,
            DNSServiceProtocol(kDNSServiceProtocol_IPv6), target,
            { _, flags, index, error, _, address, ttl, context in
                guard let context else { return }
                let owner = Unmanaged<DiscoveredService>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError else { owner.handleServiceError(error); return }
                guard index == owner.link.index, let address, address.pointee.sa_family == sa_family_t(AF_INET6) else { return }
                let v6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee
                guard let text = DiscoveryProfile.address(v6, on: index) else { return }
                owner.address(text, add: flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, ttl: ttl)
            }, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let addresses else { handleServiceError(status); return }
        let scheduled = DNSServiceSetDispatchQueue(addresses, .main)
        if scheduled != kDNSServiceErr_NoError {
            DNSServiceRefDeallocate(addresses)
            self.addresses = nil
            handleServiceError(scheduled)
        }
    }

    private func address(_ text: String, add: Bool, ttl: UInt32) {
        guard !stopped else { return }
        if !add || ttl == 0 {
            knownAddresses.removeAll { $0 == text }
            if choice?.address == text {
                if let fallback = knownAddresses.first, let adv = advertisement {
                    choice = ReceiverChoice(id: "\(link.index)/\(name)", name: name, link: link, address: fallback,
                                            port: DiscoveryProfile.port, code: adv.code, hostID: adv.hostID, paired: adv.paired)
                } else {
                    choice = nil
                }
                onChange?()
            }
            return
        }
        guard let adv = advertisement else { return }
        timeout?.cancel(); timeout = nil
        let isNewAddress = !knownAddresses.contains(text)
        if isNewAddress {
            // Prefer a newly announced link-local IPv6 address so a receiver that
            // changes address after replug/reboot takes effect before the old TTL
            // expires, without flipping back and forth between already-known ones.
            knownAddresses.insert(text, at: 0)
            if knownAddresses.count > 8 { knownAddresses.removeLast(knownAddresses.count - 8) }
        }
        guard choice == nil || isNewAddress else { return }
        let selected = isNewAddress ? text : (knownAddresses.first ?? text)
        let updated = ReceiverChoice(id: "\(link.index)/\(name)", name: name, link: link, address: selected,
                                     port: DiscoveryProfile.port, code: adv.code, hostID: adv.hostID, paired: adv.paired)
        guard choice != updated else { return }
        choice = updated
        // No local TTL timer: the long-lived GetAddrInfo query reports expiry as a
        // removal, while cache refreshes never repeat the Add event, so a local timer
        // would drop a live receiver. Cable loss is handled by LinkWatcher, which
        // stops this interface's browser when no Thunderbolt carrier remains.
        onChange?()
    }

    private func expirePending() {
        guard !stopped else { return }
        stop()
        onInvalidated?(false)
    }

    func stop() {
        stopped = true
        timeout?.cancel(); timeout = nil
        if let resolve = resolve { DNSServiceRefDeallocate(resolve) }; resolve = nil
        if let addresses = addresses { DNSServiceRefDeallocate(addresses) }; addresses = nil
        knownAddresses.removeAll()
        choice = nil
    }
    deinit { stop() }
}
