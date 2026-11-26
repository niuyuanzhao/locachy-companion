// SPDX-License-Identifier: GPL-3.0-or-later
// Pure fixtures: no interface enumeration, discovery, UI, TCC or Mac session.
import Darwin
import dnssd
import Foundation
import Security

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
    static func interface(_ name: String, _ index: UInt32, bridge: Bool = false, ready: Bool = true, carrierActive: Bool = true) -> LinkInterfaces.Interface {
        LinkInterfaces.Interface(name: name, index: index, bridge: bridge, ready: ready, carrierActive: carrierActive)
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
        check(ignoredVM.links == [CableLink(name: "ipnet", index: 20, bridged: true)] && ignoredVM.isCertain,
              "ignores unrelated non-Thunderbolt VM bridges")
        let unreadableVM = LinkInterfaces.classify(withVMBridges, thunderbolt: ["wiredA", "wiredB"],
                                                   members: ["ipnet": ["wiredA", "wiredB"]])
        let ipnetLink = CableLink(name: "ipnet", index: 20, bridged: true)
        check(unreadableVM.links == [ipnetLink]
              && unreadableVM.activePorts == ["wiredA", "wiredB"]
              && unreadableVM.complete
              && unreadableVM.undetermined == ["bridge100"]
              && !unreadableVM.isCertain
              && unreadableVM.determines(ipnetLink)
              && !unreadableVM.isLost(ipnetLink),
              "does not let an unreadable unrelated bridge poison a verified Thunderbolt bridge")
        let mixed = LinkInterfaces.classify(ports, thunderbolt: ["wiredA"], members: ["ipnet": ["wiredA", "wiredB"]])
        check(mixed.links.isEmpty && mixed.isCertain, "rejects a bridge mixed with ordinary Ethernet and never bypasses through a member")
        let unreadableAll = LinkInterfaces.classify(ports, thunderbolt: ["wiredA", "wiredB"], members: [:])
        check(unreadableAll.links.isEmpty
              && !unreadableAll.isCertain
              && !unreadableAll.determines(ipnetLink)
              && !unreadableAll.isLost(ipnetLink)
              && !unreadableAll.isLost(CableLink(name: "wiredA", index: 4, bridged: false)),
              "fails closed for dialing when bridge membership cannot be inspected without reporting the link lost")
        let failedInspect = LinkSnapshot(links: [], message: "Cannot read the network interface list.", complete: false)
        check(!failedInspect.isCertain && !failedInspect.determines(ipnetLink) && !failedInspect.isLost(ipnetLink),
              "treats an incomplete inspection snapshot as unknown rather than lost")
        check(LinkInterfaces.classify([interface("wiredA", 4, ready: false)], thunderbolt: ["wiredA"], members: [:]).links.isEmpty,
              "waits for carrier and link-local IPv6 instead of dialing a down link")
        let bridgeAllUnplugged = [
            interface("wiredA", 4, ready: false, carrierActive: false),
            interface("wiredB", 7, ready: false, carrierActive: false),
            interface("ipnet", 20, bridge: true, ready: true, carrierActive: true)
        ]
        let unpluggedSnap = LinkInterfaces.classify(bridgeAllUnplugged, thunderbolt: ["wiredA", "wiredB"],
                                                    members: ["ipnet": ["wiredA", "wiredB"]])
        check(unpluggedSnap.links.isEmpty && unpluggedSnap.activePorts.isEmpty
              && unpluggedSnap.isCertain && unpluggedSnap.isLost(ipnetLink),
              "treats a bridge as offline and lost when all Thunderbolt member ports have no physical carrier")
        let bridgeOneActive = [
            interface("wiredA", 4, ready: false, carrierActive: true),
            interface("wiredB", 7, ready: false, carrierActive: false),
            interface("ipnet", 20, bridge: true, ready: true, carrierActive: true)
        ]
        let oneActiveSnap = LinkInterfaces.classify(bridgeOneActive, thunderbolt: ["wiredA", "wiredB"],
                                                    members: ["ipnet": ["wiredA", "wiredB"]])
        check(oneActiveSnap.links == [CableLink(name: "ipnet", index: 20, bridged: true)]
              && oneActiveSnap.activePorts == ["wiredA"],
              "accepts a Thunderbolt bridge and reports activePorts once a member has carrier")
        check(LinkInterfaces.classify([interface("wiredA", 4, ready: true, carrierActive: false)],
                                      thunderbolt: ["wiredA"], members: [:]).links.isEmpty,
              "ignores a standalone Thunderbolt port without active hardware carrier")
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
        let parsedGood = DiscoveryProfile.parseTXT(good)
        check(DiscoveryProfile.validTXT(good) && parsedGood?.code == sampleCode && parsedGood?.hostID == nil && parsedGood?.paired == false,
              "accepts the receiver's legacy discovery profile with code")
        let withHostAndCode = txt(["pv=3", "extended=1", "pair=psk128", "hostid=a1b2c3d4e5f60708", "code=\(sampleCode)"])
        let parsedHostCode = DiscoveryProfile.parseTXT(withHostAndCode)
        check(parsedHostCode?.code == sampleCode && parsedHostCode?.hostID == "a1b2c3d4e5f60708" && parsedHostCode?.pairedOnly == false,
              "accepts discovery TXT with hostid and pairing code")
        let pairedOnly = txt(["pv=3", "extended=1", "pair=psk128", "hostid=x1yoga-deadbeef01", "paired=1"])
        let parsedPaired = DiscoveryProfile.parseTXT(pairedOnly)
        check(parsedPaired?.code == nil && parsedPaired?.hostID == "x1yoga-deadbeef01" && parsedPaired?.paired == true && parsedPaired?.pairedOnly == true,
              "accepts paired-only discovery TXT with hostid and paired=1 without cleartext code")
        let pairedAndCode = txt(["pv=3", "extended=1", "pair=psk128", "hostid=x1yoga-deadbeef01", "paired=1", "code=\(sampleCode)"])
        let parsedBoth = DiscoveryProfile.parseTXT(pairedAndCode)
        check(parsedBoth?.code == sampleCode && parsedBoth?.hostID == "x1yoga-deadbeef01" && parsedBoth?.paired == true && parsedBoth?.pairedOnly == false,
              "accepts discovery TXT advertising both paired=1 and one-time code")
        check(!DiscoveryProfile.validTXT(txt(["pv=3", "extended=1", "pair=psk128"])), "rejects discovery TXT without a code or paired hostid")
        check(!DiscoveryProfile.validTXT(txt(["pv=3", "extended=1", "pair=psk128", "paired=1"])), "rejects paired=1 TXT without hostid or code")
        check(!DiscoveryProfile.validTXT(txt(["pv=3", "extended=1", "pair=psk128", "hostid=short", "paired=1"])), "rejects hostid shorter than 8 characters")
        check(!DiscoveryProfile.validTXT(txt(["pv=3", "extended=1", "pair=psk128", "hostid=bad host!id", "paired=1"])), "rejects hostid with disallowed characters")
        check(!DiscoveryProfile.validTXT(txt(["pv=3", "extended=1", "pair=psk128", "hostid=a1b2c3d4e5f60708", "paired=2"])), "rejects invalid paired flag values")
        check(!DiscoveryProfile.validTXT(txt(["pv=3", "extended=1", "pair=psk128", "code=\(sampleCode)", "extra=1"])), "rejects unknown discovery TXT keys")
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
        let a = ReceiverChoice(id: "4/a", name: "LOCachy-a", link: link, address: "fe80::1", port: 27183, code: sampleCode, hostID: "host-aaaaaaaa")
        let b = ReceiverChoice(id: "4/b", name: "LOCachy-b", link: link, address: "fe80::2", port: 27183, code: nil, hostID: "host-bbbbbbbb", paired: true)
        check(a.peerKey == "host-aaaaaaaa" && !a.pairedOnly && b.peerKey == "host-bbbbbbbb" && b.pairedOnly,
              "derives peerKey from hostID and distinguishes pairedOnly receivers")
        check(DiscoveryProfile.preferred([a], previous: nil) == a.id, "selects the only receiver automatically")
        check(DiscoveryProfile.preferred([a, b], previous: nil) == nil, "requires a choice when more than one receiver is found")
        check(DiscoveryProfile.preferred([b, a], previous: a.id) == a.id, "keeps the chosen identity when discovery order changes")
        check(DiscoveryProfile.preferred([], previous: a.id) == nil, "forgets a removed receiver")

        // Discovery error classification & reconnect backoff tests
        check(DiscoveryErrorClassifier.isPolicyDenied(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
              && DiscoveryErrorClassifier.isPolicyDenied(DNSServiceErrorType(kDNSServiceErr_NotPermitted))
              && !DiscoveryErrorClassifier.isPolicyDenied(DNSServiceErrorType(kDNSServiceErr_BadInterfaceIndex))
              && !DiscoveryErrorClassifier.isPolicyDenied(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord))
              && !DiscoveryErrorClassifier.isPolicyDenied(DNSServiceErrorType(kDNSServiceErr_Timeout)),
              "distinguishes Local Network policy denials from transient DNS-SD hotplug errors")

        check(!SecureTransport.isAuthFailure(tlsStatus: errSSLTransportReset)
              && !SecureTransport.isAuthFailure(tlsStatus: errSSLNetworkTimeout)
              && !SecureTransport.isAuthFailure(tlsStatus: errSSLClosedAbort)
              && !SecureTransport.isAuthFailure(tlsStatus: errSSLConnectionRefused)
              && SecureTransport.isAuthFailure(tlsStatus: errSSLUnknownPSKIdentity)
              && SecureTransport.isAuthFailure(tlsStatus: errSSLPeerBadRecordMac)
              && SecureTransport.isAuthFailure(tlsStatus: errSSLPeerHandshakeFail),
              "treats transport-level TLS errors as transient cable drops rather than permanent auth failures")

        var backoff = ReconnectBackoff()
        check(backoff.canAttempt("peer-a", now: 100.0), "ReconnectBackoff allows immediate first attempt")
        let d1 = backoff.recordFailure(for: "peer-a", now: 100.0)
        let d2 = backoff.recordFailure(for: "peer-a", now: 102.0)
        let d3 = backoff.recordFailure(for: "peer-a", now: 106.0)
        let d4 = backoff.recordFailure(for: "peer-a", now: 112.0)
        let d5 = backoff.recordFailure(for: "peer-a", now: 124.0)
        let d6 = backoff.recordFailure(for: "peer-a", now: 148.0)
        check(d1 == 1.5 && d2 == 3.0 && d3 == 6.0 && d4 == 12.0 && d5 == 24.0 && d6 == 30.0
              && !backoff.canAttempt("peer-a", now: 150.0)
              && backoff.canAttempt("peer-a", now: 178.0)
              && backoff.canAttempt("peer-b", now: 150.0),
              "ReconnectBackoff grows exponentially per peer up to 30s without blocking other peers")
        backoff.reset(for: "peer-a")
        check(backoff.canAttempt("peer-a", now: 150.0) && backoff.failureCount(for: "peer-a") == 0,
              "ReconnectBackoff resets immediately on replug or successful connect")

        // PeerStore tests (isolated in a temporary directory)
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("locachy-peerstore-\(UUID().uuidString)", isDirectory: true)
        let storeFile = tmpDir.appendingPathComponent("peers.json", isDirectory: false)
        let store = PeerStore(fileURL: storeFile)
        check(store.all().isEmpty, "PeerStore starts empty when backing file does not exist")

        let token = "locachy-pair://v1?host=x1yoga-01234567&id=locachy-peer-macbook&code=77777-77777-7777-7777-7777-7774&name=X1%20Yoga"
        do {
            let parsed = try PeerStore.parsePairingToken(token)
            check(parsed.hostID == "x1yoga-01234567"
                  && parsed.identity == "locachy-peer-macbook"
                  && parsed.displayName == "X1 Yoga"
                  && parsed.pskBase32 == "77777777777777777777777774",
                  "PeerStore.parsePairingToken extracts host, identity, displayName, and canonical base32 PSK")
            try store.save(parsed)
            let reloaded = PeerStore(fileURL: storeFile)
            let found = reloaded.lookup(hostID: "x1yoga-01234567")
            check(found?.identity == "locachy-peer-macbook" && found?.pskBase32 == "77777777777777777777777774",
                  "PeerStore persists and reloads stored peers atomically")
            var st = stat()
            let statOK = storeFile.path.withCString { Darwin.lstat($0, &st) == 0 }
            var dirSt = stat()
            let dirStatOK = tmpDir.path.withCString { Darwin.lstat($0, &dirSt) == 0 }
            check(statOK && (st.st_mode & 0o777) == 0o600 && dirStatOK && (dirSt.st_mode & 0o777) == 0o700,
                  "PeerStore enforces 0700 directory and 0600 file permissions")
            let removed = reloaded.remove(hostID: "x1yoga-01234567")
            check(removed && reloaded.lookup(hostID: "x1yoga-01234567") == nil,
                  "PeerStore removes stored peers cleanly")
        } catch {
            check(false, "PeerStore save/reload/remove: \(error)")
        }
        check((try? PeerStore.parsePairingToken("https://example.com/?host=x1yoga-01234567&id=peer&code=\(sampleCode)")) == nil,
              "PeerStore rejects non-locachy-pair scheme")
        check((try? PeerStore.parsePairingToken("locachy-pair://v1?host=bad&id=peer&code=\(sampleCode)")) == nil,
              "PeerStore rejects short hostid in pairing token")
        check((try? PeerStore.parsePairingToken("locachy-pair://v1?host=x1yoga-01234567&id=peer&code=INVALID")) == nil,
              "PeerStore rejects invalid base32 PSK in pairing token")
        check((try? PeerStore.parsePairingToken("locachy-pair://v1?host=x1yoga-01234567&id=peer&code=\(sampleCode)&evil=1")) == nil,
              "PeerStore rejects unknown parameters in pairing token")
        let bundleJSON = #"{"version":1,"host_id":"0123456789abcdef0123456789abcdef","extdisplay_identity":"locachy-peer-aabbccddeeff0011","extdisplay_code":"7777-7777-7777-7777-7777-7777-74","name":"Desktop Node"}"#
        let bundleB64 = Data(bundleJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        do {
            let fromBundle = try PeerStore.parsePairingToken("locachy-pair-v1:" + bundleB64)
            check(fromBundle.hostID == "0123456789abcdef0123456789abcdef" &&
                  fromBundle.identity == "locachy-peer-aabbccddeeff0011" &&
                  fromBundle.pskBase32 == "77777777777777777777777774" &&
                  fromBundle.displayName == "Desktop Node",
                  "PeerStore parses locachy-pair-v1 base64url bundle token")
        } catch {
            check(false, "PeerStore.parsePairingToken bundle: \(error)")
        }

        try? FileManager.default.removeItem(at: tmpDir)
        exit(failures == 0 ? 0 : 1)
    }
}
