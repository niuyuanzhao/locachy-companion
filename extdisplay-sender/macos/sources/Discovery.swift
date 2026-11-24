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

// DNS-SD callbacks, references and their contexts all live on the main queue.
// A browse is always scoped to one validated interface; no Any-interface browse,
// unicast DNS resolver, multicast reflection or discovery fallback exists.
final class ReceiverDiscovery {
    private var browsers: [UInt32: LinkBrowser] = [:]
    var onChange: (([ReceiverChoice]) -> Void)?
    var onError: ((String) -> Void)?

    func update(_ links: [CableLink]) {
        let wanted = Dictionary(links.prefix(16).map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, browser) in Array(browsers) where wanted[index] != browser.link {
            browser.stop(); browsers.removeValue(forKey: index)
        }
        for link in wanted.values where browsers[link.index] == nil {
            let browser = LinkBrowser(link: link)
            browser.onChange = { [weak self] in self?.changed() }
            browser.onError = { [weak self] in self?.onError?($0) }
            browsers[link.index] = browser
            browser.start()
        }
        changed()
    }

    private func changed() {
        let choices = browsers.values.flatMap { $0.choices }.sorted { $0.id < $1.id }
        onChange?(Array(choices.prefix(64)))
    }

    func stop() {
        for browser in browsers.values { browser.stop() }
        browsers.removeAll()
        onChange?([])
    }
    deinit { for browser in browsers.values { browser.stop() } }
}

private func discoveryError(_ code: DNSServiceErrorType) -> String {
    if code == kDNSServiceErr_PolicyDenied {
        return "Local Network access was denied. Enable it for this app in System Settings → Privacy & Security → Local Network."
    }
    return "Thunderbolt discovery failed (DNS-SD error \(code)). Retry after the link is ready."
}

private final class LinkBrowser {
    let link: CableLink
    private var ref: DNSServiceRef?
    private var services: [String: DiscoveredService] = [:]
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var choices: [ReceiverChoice] { services.values.compactMap { $0.choice } }

    init(link: CableLink) { self.link = link }
    func start() {
        let status = DNSServiceBrowse(&ref, 0, link.index, DiscoveryProfile.type, DiscoveryProfile.domain,
            { _, flags, index, error, name, type, domain, context in
                guard let context else { return }
                let owner = Unmanaged<LinkBrowser>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError else { owner.onError?(discoveryError(error)); return }
                guard index == owner.link.index, let name, let type, let domain else { return }
                owner.browse(flags: flags, name: String(cString: name), type: String(cString: type), domain: String(cString: domain))
            }, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let ref else { onError?(discoveryError(status)); return }
        let scheduled = DNSServiceSetDispatchQueue(ref, .main)
        if scheduled != kDNSServiceErr_NoError { stop(); onError?(discoveryError(scheduled)) }
    }
    private func browse(flags: DNSServiceFlags, name: String, type: String, domain: String) {
        guard DiscoveryProfile.validName(name), type == DiscoveryProfile.type + ".", domain == DiscoveryProfile.domain else { return }
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) == 0 {
            services.removeValue(forKey: name)?.stop(); onChange?(); return
        }
        guard services[name] == nil, services.count < 16 else { return }
        let service = DiscoveredService(link: link, name: name)
        service.onChange = { [weak self] in self?.onChange?() }
        service.onError = { [weak self] in self?.onError?($0) }
        services[name] = service
        service.start()
    }
    func stop() {
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
    var onError: ((String) -> Void)?
    private var resolve: DNSServiceRef?
    private var addresses: DNSServiceRef?
    private var timeout: DispatchWorkItem?
    private var expiry: DispatchWorkItem?
    private var host = ""
    private var advertisement: DiscoveryAdvertisement?

    init(link: CableLink, name: String) { self.link = link; self.name = name }
    func start() {
        let status = DNSServiceResolve(&resolve, DNSServiceFlags(kDNSServiceFlagsForceMulticast), link.index,
            name, DiscoveryProfile.type, DiscoveryProfile.domain,
            { _, _, index, error, _, target, port, length, txt, context in
                guard let context else { return }
                let owner = Unmanaged<DiscoveredService>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError else { owner.onError?(discoveryError(error)); return }
                guard index == owner.link.index, let target, let txt else { return }
                owner.resolved(target: String(cString: target), port: UInt16(bigEndian: port), txt: Data(bytes: txt, count: Int(length)))
            }, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let resolve else { onError?(discoveryError(status)); return }
        let scheduled = DNSServiceSetDispatchQueue(resolve, .main)
        guard scheduled == kDNSServiceErr_NoError else { stop(); onError?(discoveryError(scheduled)); return }
        let work = DispatchWorkItem { [weak self] in self?.expirePending() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func resolved(target: String, port: UInt16, txt: Data) {
        guard port == DiscoveryProfile.port, let adv = DiscoveryProfile.parseTXT(txt), target.utf8.count <= 253,
              target.lowercased().hasSuffix(".local."), !target.contains("%"),
              target.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) else {
            if let addresses = addresses { DNSServiceRefDeallocate(addresses) }; addresses = nil
            host = ""; advertisement = nil; choice = nil; expiry?.cancel(); onChange?()
            return
        }
        advertisement = adv
        if host == target {
            if let existing = choice,
               existing.code != adv.code || existing.hostID != adv.hostID || existing.paired != adv.paired {
                choice = ReceiverChoice(id: existing.id, name: existing.name, link: existing.link,
                                        address: existing.address, port: existing.port,
                                        code: adv.code, hostID: adv.hostID, paired: adv.paired)
                onChange?()
            }
            return
        }
        if let addresses = addresses { DNSServiceRefDeallocate(addresses) }; addresses = nil
        choice = nil; onChange?()
        host = target
        let status = DNSServiceGetAddrInfo(&addresses, DNSServiceFlags(kDNSServiceFlagsForceMulticast), link.index,
            DNSServiceProtocol(kDNSServiceProtocol_IPv6), target,
            { _, flags, index, error, _, address, ttl, context in
                guard let context else { return }
                let owner = Unmanaged<DiscoveredService>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError else { owner.onError?(discoveryError(error)); return }
                guard index == owner.link.index, let address, address.pointee.sa_family == sa_family_t(AF_INET6) else { return }
                let v6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee
                guard let text = DiscoveryProfile.address(v6, on: index) else { return }
                owner.address(text, add: flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, ttl: ttl)
            }, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let addresses else { onError?(discoveryError(status)); return }
        let scheduled = DNSServiceSetDispatchQueue(addresses, .main)
        if scheduled != kDNSServiceErr_NoError { DNSServiceRefDeallocate(addresses); self.addresses = nil; onError?(discoveryError(scheduled)) }
    }

    private func address(_ text: String, add: Bool, ttl: UInt32) {
        if !add || ttl == 0 {
            if choice?.address == text { choice = nil; expiry?.cancel(); onChange?() }
            return
        }
        guard let adv = advertisement else { return }
        // One advertised IPv6 address per service is enough; bounded state.
        guard choice == nil || choice?.address == text else { return }
        timeout?.cancel(); timeout = nil
        choice = ReceiverChoice(id: "\(link.index)/\(name)", name: name, link: link, address: text,
                                port: DiscoveryProfile.port, code: adv.code, hostID: adv.hostID, paired: adv.paired)
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.choice = nil; self?.onChange?() }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(min(ttl, 3600)), execute: work)
        onChange?()
    }
    private func expirePending() {
        stop()
        onChange?()
    }
    func stop() {
        timeout?.cancel(); timeout = nil
        expiry?.cancel(); expiry = nil
        if let resolve = resolve { DNSServiceRefDeallocate(resolve) }; resolve = nil
        if let addresses = addresses { DNSServiceRefDeallocate(addresses) }; addresses = nil
        choice = nil
    }
    deinit { stop() }
}
