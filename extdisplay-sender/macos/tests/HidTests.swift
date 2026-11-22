// SPDX-License-Identifier: GPL-3.0-or-later
// Pure byte-level unit tests for HidHelperProtocol and KarabinerWire (v8.8.0 protocol v7).
// Never touches /var/run, /Library/Application Support/org.pqrs, or any live HID driver.
import Darwin
import Foundation

@main
enum HidTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        if condition {
            print("PASS: \(name)")
        } else {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func main() {
        helperProtocolTests()
        karabinerCodecTests()
        karabinerLoopbackTests()
        if failures == 0 {
            print("PASS: all HID protocol tests")
            exit(0)
        }
        print("FAIL: \(failures) HID protocol test(s)")
        exit(1)
    }

    static func helperProtocolTests() {
        // Round-trip keyboard report
        let kbFrame = HidHelperIPC.encodeCommand(.keyboardReport(modifiers: 0x08, keys: [0x04, 0x06, 0x28]))
        var reader = HidFrameReader()
        do {
            let p1 = try reader.push(kbFrame.prefix(3))
            let p2 = try reader.push(kbFrame.dropFirst(3))
            let payloads = p1 + p2
            check(payloads.count == 1
                  && HidHelperIPC.decodeCommand(payloads[0]) == .keyboardReport(modifiers: 0x08, keys: [0x04, 0x06, 0x28]),
                  "HidHelperIPC round-trips split keyboardReport frame")
        } catch {
            check(false, "HidHelperIPC keyboardReport: \(error)")
        }

        // Round-trip consumer report, reset, ping, and status
        let cr = HidHelperIPC.encodeCommand(.consumerReport(usages: [0x00E9, 0x00CD]))
        let rs = HidHelperIPC.encodeCommand(.reset)
        let pg = HidHelperIPC.encodeCommand(.ping)
        let st = HidHelperIPC.encodeStatus(HidHelperStatus(state: .ready, detail: 0x0B))
        do {
            var r2 = HidFrameReader()
            let all = try r2.push(cr + rs + pg + st)
            check(all.count == 4
                  && HidHelperIPC.decodeCommand(all[0]) == .consumerReport(usages: [0x00E9, 0x00CD])
                  && HidHelperIPC.decodeCommand(all[1]) == .reset
                  && HidHelperIPC.decodeCommand(all[2]) == .ping
                  && HidHelperIPC.decodeStatus(all[3]) == HidHelperStatus(state: .ready, detail: 0x0B),
                  "HidHelperIPC decodes packed consumer, reset, ping, and status frames")
        } catch {
            check(false, "HidHelperIPC packed frames: \(error)")
        }

        // Invalid length rejection
        var bad = HidFrameReader()
        var threwZero = false
        do { _ = try bad.push(Data([0x00])) } catch { threwZero = true }
        var threwTooBig = false
        do { _ = try bad.push(Data([0x81, 0x03])) } catch { threwTooBig = true }
        check(threwZero && threwTooBig, "HidFrameReader rejects length 0 and >128")
        check(HidHelperIPC.decodeCommand(Data([0x01, 0x00, 0x02, 0x04])) == nil,
              "HidHelperIPC rejects truncated keyboardReport payload")
    }

    static func karabinerCodecTests() {
        // Exact v8.8.0 byte layouts verified against Karabiner-DriverKit-VirtualHIDDevice v8.8.0 headers:
        // 1. Heartbeat frame: 4-byte BE bodySize=1 + type=0
        check(KarabinerCodec.encodeHeartbeatFrame() == Data([0x00, 0x00, 0x00, 0x01, 0x00]),
              "Karabiner heartbeat frame matches unix_domain_stream protocol.hpp")

        // 2. virtual_hid_keyboard_initialize payload: 2B LE version(7) + 1B req(0) + 3x8B LE (0x16c0, 0x27db, 0) = 27 bytes
        let initPayload = KarabinerCodec.encodeKeyboardInitializePayload()
        check(initPayload.count == 27
              && initPayload[0] == 7 && initPayload[1] == 0 && initPayload[2] == 0
              && initPayload[3] == 0xc0 && initPayload[4] == 0x16
              && initPayload[11] == 0xdb && initPayload[12] == 0x27
              && initPayload[19] == 0,
              "Karabiner keyboard initialize payload matches v8.8.0 exact 27-byte layout")

        // 3. post_keyboard_input_report payload: 3B header + 67B packed keyboard_input = 70 bytes
        let kbPayload = KarabinerCodec.encodePostKeyboardReportPayload(modifiers: 0x08, keys: [0x0004, 0x001D])
        check(kbPayload.count == 70
              && kbPayload[0] == 7 && kbPayload[1] == 0 && kbPayload[2] == 6
              && kbPayload[3] == 1 && kbPayload[4] == 0x08 && kbPayload[5] == 0
              && kbPayload[6] == 0x04 && kbPayload[7] == 0x00
              && kbPayload[8] == 0x1D && kbPayload[9] == 0x00
              && kbPayload[10] == 0x00 && kbPayload[69] == 0x00,
              "Karabiner keyboard report matches v8.8.0 packed 67-byte keyboard_input layout")

        // 4. post_consumer_input_report payload: 3B header + 65B packed consumer_input = 68 bytes
        let consPayload = KarabinerCodec.encodePostConsumerReportPayload(usages: [0x00E9])
        check(consPayload.count == 68
              && consPayload[0] == 7 && consPayload[1] == 0 && consPayload[2] == 7
              && consPayload[3] == 2 && consPayload[4] == 0xE9 && consPayload[5] == 0x00,
              "Karabiner consumer report matches v8.8.0 packed 65-byte consumer_input layout")

        // 5. Request frame + stream reader round-trip
        let reqFrame = KarabinerCodec.encodeRequestFrame(requestId: 42, payload: kbPayload)
        var stream = KarabinerStreamReader()
        do {
            let a = try stream.push(reqFrame.prefix(9))
            let b = try stream.push(reqFrame.dropFirst(9))
            let out = a + b
            check(out.count == 1 && out[0] == .request(id: 42, payload: kbPayload),
                  "KarabinerStreamReader reassembles split request frame with BE uint32/uint64")
        } catch {
            check(false, "KarabinerStreamReader round-trip: \(error)")
        }

        // 6. Status pair decoding
        let pairs = KarabinerCodec.decodeStatusPairs(Data([1, 1, 2, 1, 3, 0, 4, 1]))
        check(pairs == [
            KarabinerStatusPair(type: .driverActivated, value: true),
            KarabinerStatusPair(type: .driverConnected, value: true),
            KarabinerStatusPair(type: .driverVersionMismatched, value: false),
            KarabinerStatusPair(type: .virtualHidKeyboardReady, value: true),
        ], "KarabinerCodec decodes 2-byte status pairs")
        check(KarabinerCodec.decodeStatusPairs(Data([1, 1, 2])) == nil,
              "KarabinerCodec rejects odd-length status payload")
    }

    static func karabinerLoopbackTests() {
        // Test KarabinerDaemonClient against an in-process mock AF_UNIX server in /tmp
        let sockPath = "/tmp/locachy-karabiner-test-\(getpid()).sock"
        _ = Darwin.unlink(sockPath)
        defer { _ = Darwin.unlink(sockPath) }

        let listenFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { check(false, "create mock unix socket"); return }
        defer { Darwin.close(listenFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(sockPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0..<bytes.count { buf[i] = bytes[i] }
            buf[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listenFd, 2) == 0 else {
            check(false, "bind/listen mock unix socket")
            return
        }

        let gotInit = DispatchSemaphore(value: 0)
        let gotReport = DispatchSemaphore(value: 0)
        let gotReset = DispatchSemaphore(value: 0)
        let becameReady = DispatchSemaphore(value: 0)

        var sawInit = false
        var sawMetaHold = false
        var sawReset = false

        DispatchQueue.global().async {
            var peer = sockaddr_un()
            var peerLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let conn = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFd, $0, &peerLen)
                }
            }
            guard conn >= 0 else { return }
            defer { Darwin.close(conn) }
            // A write to a peer that already closed must fail with EPIPE instead of
            // raising SIGPIPE and killing the test (production sets this on its socket too).
            var noSigPipe: Int32 = 1
            _ = setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var reader = KarabinerStreamReader()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(conn, &buf, buf.count)
                if n <= 0 { break }
                guard let frames = try? reader.push(Data(bytes: buf, count: n)) else { break }
                for frame in frames {
                    if case let .request(id, payload) = frame, payload.count >= 3 {
                        let reqType = payload[2]
                        if reqType == KarabinerRequestType.virtualHidKeyboardInitialize.rawValue && payload.count == 27 {
                            sawInit = true
                            // Reply with driverActivated=1, driverConnected=1, virtualHidKeyboardReady=1
                            let resp = KarabinerCodec.encodeResponseFrame(requestId: id, payload: Data([1, 1, 2, 1, 4, 1]))
                            _ = resp.withUnsafeBytes { Darwin.write(conn, $0.baseAddress!, $0.count) }
                            gotInit.signal()
                        } else if reqType == KarabinerRequestType.postKeyboardInputReport.rawValue && payload.count == 70 {
                            if payload[4] == 0x08 && payload[6] == 0x04 {
                                sawMetaHold = true
                                gotReport.signal()
                            }
                            let resp = KarabinerCodec.encodeResponseFrame(requestId: id, payload: Data())
                            _ = resp.withUnsafeBytes { Darwin.write(conn, $0.baseAddress!, $0.count) }
                        } else if reqType == KarabinerRequestType.virtualHidKeyboardReset.rawValue {
                            sawReset = true
                            let resp = KarabinerCodec.encodeResponseFrame(requestId: id, payload: Data())
                            _ = resp.withUnsafeBytes { Darwin.write(conn, $0.baseAddress!, $0.count) }
                            gotReset.signal()
                        }
                    }
                }
            }
        }

        let client = KarabinerDaemonClient(socketPath: sockPath)
        client.onStatusChanged = { st in
            if st.state == .ready { becameReady.signal() }
        }
        client.start()

        let initOk = gotInit.wait(timeout: .now() + .seconds(3)) == .success
        let readyOk = becameReady.wait(timeout: .now() + .seconds(3)) == .success
        let sentOk = client.postKeyboard(modifiers: 0x08, keys: [0x04])
        let reportOk = gotReport.wait(timeout: .now() + .seconds(3)) == .success
        client.resetKeyboard()
        let resetOk = gotReset.wait(timeout: .now() + .seconds(3)) == .success
        client.stop()

        check(initOk && sawInit && readyOk && sentOk && reportOk && sawMetaHold && resetOk && sawReset,
              "KarabinerDaemonClient completes initialize, becomes ready, sends Meta+A report, and resets cleanly")
    }
}
