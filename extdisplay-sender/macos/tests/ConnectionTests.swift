// SPDX-License-Identifier: GPL-3.0-or-later
// Pure fixtures: no interface enumeration, discovery, UI, TCC or Mac session.
import Darwin
import Foundation

@main
enum ConnectionTests {
    static var failures = 0
    static func check(_ value: Bool, _ name: String) {
        print("\(value ? "PASS" : "FAIL"): \(name)")
        if !value { failures += 1 }
    }
    static func txt(_ fields: [String]) -> Data {
        fields.reduce(into: Data()) { result, field in
            let bytes = Array(field.utf8); result.append(UInt8(bytes.count)); result.append(contentsOf: bytes)
        }
    }
    static func interface(_ name: String, _ index: UInt32, bridge: Bool = false, ready: Bool = true) -> LinkInterfaces.Interface {
        LinkInterfaces.Interface(name: name, index: index, bridge: bridge, ready: ready)
    }
    static func main() {
        let physical = [interface("wiredA", 4), interface("wiredB", 7), interface("wifi", 8)]
        let one = LinkInterfaces.classify(physical, thunderbolt: ["wiredA"], members: [:])
        check(one.links == [CableLink(name: "wiredA", index: 4, bridged: false)], "accepts only the verified Thunderbolt IP driver, not ordinary wired or Wi-Fi")
        let ports = physical + [interface("ipnet", 20, bridge: true)]
        let bridge = LinkInterfaces.classify(ports, thunderbolt: ["wiredA", "wiredB"], members: ["ipnet": ["wiredA", "wiredB"]])
        check(bridge.links == [CableLink(name: "ipnet", index: 20, bridged: true)], "uses the effective IP bridge and suppresses its member ports without naming assumptions")
        let withVMBridges = ports + [interface("vmenet0", 27), interface("bridge100", 28, bridge: true)]
        let ignoredVM = LinkInterfaces.classify(withVMBridges, thunderbolt: ["wiredA", "wiredB"],
                                                members: ["ipnet": ["wiredA", "wiredB"], "bridge100": ["vmenet0"]])
        check(ignoredVM.links == [CableLink(name: "ipnet", index: 20, bridged: true)], "ignores unrelated non-Thunderbolt VM bridges")
        let mixed = LinkInterfaces.classify(ports, thunderbolt: ["wiredA"], members: ["ipnet": ["wiredA", "wiredB"]])
        check(mixed.links.isEmpty, "rejects a bridge mixed with ordinary Ethernet and never bypasses through a member")
        check(LinkInterfaces.classify(ports, thunderbolt: ["wiredA", "wiredB"], members: [:]).links.isEmpty,
              "fails closed when bridge membership cannot be inspected")
        check(LinkInterfaces.classify([interface("wiredA", 4, ready: false)], thunderbolt: ["wiredA"], members: [:]).links.isEmpty,
              "waits for carrier and link-local IPv6 instead of dialing a down link")
        let snapshot = Data("ipnet: flags=8863<UP>\n\tmember: wiredA flags=3<LEARNING,DISCOVER>\n\tmember: wiredB flags=3\n".utf8)
        check((try? LinkInterfaces.bridgeMembers(snapshot, interface: "ipnet", known: ["wiredA", "wiredB"])) == ["wiredA", "wiredB"],
              "parses bounded read-only ifconfig bridge output")
        check((try? LinkInterfaces.bridgeMembers(snapshot, interface: "other", known: ["wiredA", "wiredB"])) == nil,
              "rejects output for another bridge")
        check((try? LinkInterfaces.bridgeMembers(snapshot, interface: "ipnet", known: ["wiredA"])) == nil,
              "rejects members not in the kernel interface list")
        check((try? LinkInterfaces.bridgeMembers(Data(repeating: 65, count: 65537), interface: "ipnet", known: [])) == nil,
              "rejects oversized bridge output")
        let sampleCode = "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AA"
        let good = txt(["pv=3", "extended=1", "pair=psk128", "code=\(sampleCode)"])
        check(DiscoveryProfile.validTXT(good), "accepts the receiver's discovery profile with code")
        check(!DiscoveryProfile.validTXT(txt(["pv=3", "extended=1", "pair=psk128"])), "rejects discovery TXT without a code")
        check(!DiscoveryProfile.validTXT(txt(["pv=3", "pv=2", "extended=1", "pair=psk128", "code=\(sampleCode)"])), "rejects duplicated discovery fields")
        check(!DiscoveryProfile.validTXT(txt(["pv=3", "extended=0", "pair=psk128", "code=\(sampleCode)"])), "rejects mirror advertisements")
        check(!DiscoveryProfile.validTXT(txt(["pv=3", "extended=1", "pair=pin", "code=\(sampleCode)"])), "rejects a different authentication profile")
        check(!DiscoveryProfile.validTXT(Data([9, 65])), "rejects truncated discovery TXT")
        check(!DiscoveryProfile.validName("bad\nreceiver"), "rejects control characters in a receiver label")
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_scope_id = 4
        _ = "fe80::1234".withCString { inet_pton(AF_INET6, $0, &addr.sin6_addr) }
        check(DiscoveryProfile.address(addr, on: 4) == "fe80::1234", "accepts link-local IPv6 on the discovered interface")
        check(DiscoveryProfile.address(addr, on: 7) == nil, "rejects an address from another interface")
        _ = "2001:db8::1".withCString { inet_pton(AF_INET6, $0, &addr.sin6_addr) }
        check(DiscoveryProfile.address(addr, on: 4) == nil, "rejects global IPv6 advertisements")
        let link = CableLink(name: "wiredA", index: 4, bridged: false)
        let a = ReceiverChoice(id: "4/a", name: "LOCachy-a", link: link, address: "fe80::1", port: 27183, code: sampleCode)
        let b = ReceiverChoice(id: "4/b", name: "LOCachy-b", link: link, address: "fe80::2", port: 27183, code: sampleCode)
        check(DiscoveryProfile.preferred([a], previous: nil) == a.id, "selects the only receiver automatically")
        check(DiscoveryProfile.preferred([a, b], previous: nil) == nil, "requires a choice when more than one receiver is found")
        check(DiscoveryProfile.preferred([b, a], previous: a.id) == a.id, "keeps the chosen identity when discovery order changes")
        check(DiscoveryProfile.preferred([], previous: a.id) == nil, "forgets a removed receiver")
        exit(failures == 0 ? 0 : 1)
    }
}
