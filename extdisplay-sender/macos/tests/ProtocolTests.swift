// SPDX-License-Identifier: GPL-3.0-or-later
// Protocol and input-validation tests. Nothing here creates a display, reads
// the screen, posts an event or touches TCC: RemoteInput records the CGEvents
// it would post through an injected sink.
import CoreGraphics
import CoreMedia
import Foundation

final class Recorder {
    var events: [CGEventType] = []
    var posted: [CGEvent] = []
}

@main
enum ProtocolTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        if condition {
            print("PASS: \(name)")
        } else {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func expectThrow(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            check(false, name)
        } catch {
            check(true, name)
        }
    }

    static func hello(_ json: String) throws -> Panel {
        try Panel(hello: Wire.object(Data(json.utf8)))
    }

    // The exact text extdisplay-protocol.c emits for a 1920x1200 @2x H.264 panel.
    static let receiverHello = """
    {"type":"hello","pv":3,"locachy":1,"device":"LOCachy","pixelsWide":1920,"pixelsHigh":1200,"scale":2.000,"panel":{"width":1920,"height":1200,"scale":2.000},"displayMaxFrameRate":60,"extendedOnly":true,"videoCaps":[{"codec":"h264","maxWidth":4096,"maxHeight":4096,"maxFramesPerSecond":60}],"input":["key","button","cancel","pointer","scroll"]}
    """

    static func main() {
        panelTests()
        frameTests()
        annexBTests()
        inputTests()
        pairingTests()
        scrollSemanticTests()
        modifierTransitionTests()
        modifierRepeatTests()
        commandSideTests()
        capsLockTests()
        physicalAndVirtualHidTests()
        tabletAndTouchTests()
        multiSessionTests()
        if failures == 0 {
            print("PASS: all protocol tests")
            exit(0)
        }
        print("FAIL: \(failures) protocol test(s)")
        exit(1)
    }

    static func panelTests() {
        do {
            let panel = try hello(receiverHello)
            check(panel.width == 1920 && panel.height == 1200 && panel.scale == 2 && panel.fps == 60 && panel.codec == "h264",
                  "accepts the exact receiver hello")
        } catch {
            check(false, "accepts the exact receiver hello: \(error)")
        }
        do {
            let named = try hello(receiverHello
                .replacingOccurrences(of: "\"device\":\"LOCachy\"", with: "\"device\":\"LOCachy\",\"host\":\"cf-fv1\",\"model\":\"CF-FV1RFAAS\""))
            check(named.identityKey == "host=cf-fv1|model=CF-FV1RFAAS|panel=1920x1200",
                  "keys receiver identity by sanitized host, model, and panel dimensions")
            let fallback = try hello(receiverHello)
            check(fallback.identityKey == "device=LOCachy|panel=1920x1200",
                  "falls back to device and panel dimensions when host/model are absent")
        } catch {
            check(false, "receiver identity keying: \(error)")
        }
        do {
            let native = try hello(receiverHello
                .replacingOccurrences(of: "\"width\":1920,\"height\":1200,\"scale\":2.000", with: "\"width\":2160,\"height\":1440,\"scale\":1.000")
                .replacingOccurrences(of: "\"pixelsWide\":1920,\"pixelsHigh\":1200", with: "\"pixelsWide\":2160,\"pixelsHigh\":1440"))
            check(native.width == 2160 && native.height == 1440 && native.scale == 2,
                  "computes exact 1:1 HiDPI geometry from a 2160x1440 handshake")
            let odd = try hello(receiverHello
                .replacingOccurrences(of: "\"width\":1920,\"height\":1200,\"scale\":2.000", with: "\"width\":1366,\"height\":768,\"scale\":1.000")
                .replacingOccurrences(of: "\"pixelsWide\":1920,\"pixelsHigh\":1200", with: "\"pixelsWide\":1366,\"pixelsHigh\":768"))
            check(odd.scale == 2, "enables HiDPI scaling for mainstream non-div4 panels (1366x768)")
            let tiny = try hello(receiverHello
                .replacingOccurrences(of: "\"width\":1920,\"height\":1200,\"scale\":2.000", with: "\"width\":320,\"height\":240,\"scale\":1.000")
                .replacingOccurrences(of: "\"pixelsWide\":1920,\"pixelsHigh\":1200", with: "\"pixelsWide\":320,\"pixelsHigh\":240"))
            check(tiny.scale == 1, "falls back to 1x for tiny sub-VGA panels")
        } catch {
            check(false, "computes exact geometry from handshake: \(error)")
        }
        do {
            // Comet Lake (Gen9.5): offers h264 + hevc420 (no 4:4:4) -> picks hevc420 at 60 fps.
            let cml = try hello(receiverHello
                .replacingOccurrences(of: "\"width\":1920,\"height\":1200", with: "\"width\":3840,\"height\":2160")
                .replacingOccurrences(of: "\"pixelsWide\":1920,\"pixelsHigh\":1200", with: "\"pixelsWide\":3840,\"pixelsHigh\":2160")
                .replacingOccurrences(of: "[{\"codec\":\"h264\",\"maxWidth\":4096,\"maxHeight\":4096,\"maxFramesPerSecond\":60}]",
                                      with: "[{\"codec\":\"h264\",\"maxWidth\":4096,\"maxHeight\":4096,\"maxFramesPerSecond\":60},{\"codec\":\"hevc420\",\"maxWidth\":4096,\"maxHeight\":4096,\"maxFramesPerSecond\":60}]"))
            check(cml.codec == "hevc420" && cml.streamCodec == "hevc" && cml.fps == 60,
                  "negotiates hevc420 at 4K60 when receiver offers h264+hevc420")
            // Ice Lake (Gen11+): offers h264 + hevc420 + hevc444 + hevc -> picks hevc444.
            let icl = try hello(receiverHello
                .replacingOccurrences(of: "[{\"codec\":\"h264\",\"maxWidth\":4096,\"maxHeight\":4096,\"maxFramesPerSecond\":60}]",
                                      with: "[{\"codec\":\"h264\",\"maxWidth\":4096,\"maxHeight\":4096,\"maxFramesPerSecond\":60},{\"codec\":\"hevc420\",\"maxWidth\":4096,\"maxHeight\":4096,\"maxFramesPerSecond\":60},{\"codec\":\"hevc444\",\"maxWidth\":4096,\"maxHeight\":4096,\"maxFramesPerSecond\":60},{\"codec\":\"hevc\",\"maxWidth\":4096,\"maxHeight\":4096,\"maxFramesPerSecond\":60}]"))
            check(icl.codec == "hevc444" && icl.streamCodec == "hevc",
                  "prefers hevc444 when hardware supports HEVC 4:4:4")
            // Optional input capabilities ("touch", "tablet") are recorded without breaking older hellos.
            let withDirect = try hello(receiverHello.replacingOccurrences(of: "\"scroll\"]", with: "\"scroll\",\"touch\",\"tablet\"]"))
            check(withDirect.supportedInput.contains("touch") && withDirect.supportedInput.contains("tablet"),
                  "records optional touch and tablet input capabilities from hello")
        } catch {
            check(false, "codec and input capability negotiation: \(error)")
        }
        expectThrow("rejects receivers with only unsupported codecs") {
            _ = try hello(receiverHello.replacingOccurrences(of: "\"codec\":\"h264\"", with: "\"codec\":\"vp9\""))
        }
        expectThrow("rejects a missing scroll capability") {
            _ = try hello(receiverHello.replacingOccurrences(of: ",\"scroll\"", with: ""))
        }
        expectThrow("rejects extendedOnly=false") {
            _ = try hello(receiverHello.replacingOccurrences(of: "\"extendedOnly\":true", with: "\"extendedOnly\":false"))
        }
        expectThrow("rejects protocol version 2") {
            _ = try hello(receiverHello.replacingOccurrences(of: "\"pv\":3", with: "\"pv\":2"))
        }
        expectThrow("rejects panels wider than 4096") {
            _ = try hello(receiverHello.replacingOccurrences(of: "\"width\":1920", with: "\"width\":5120"))
        }
        do {
            // 4096x2304 exceeds H.264 level 5.2 at 60 fps; the rate must drop.
            let big = try hello(receiverHello
                .replacingOccurrences(of: "\"width\":1920,\"height\":1200", with: "\"width\":4096,\"height\":2304"))
            check(big.fps == 55, "lowers the rate for a 4096x2304 panel to the H.264 macroblock limit")
        } catch {
            check(false, "lowers the rate for a 4096x2304 panel: \(error)")
        }
    }

    static func frameTests() {
        do {
            let frame = try Wire.frame(Data("{\"type\":\"ping\"}".utf8))
            var reader = FrameReader()
            var received: [Data] = []
            try reader.feed(frame.prefix(5)) { received.append($0) }
            try reader.feed(frame.dropFirst(5)) { received.append($0) }
            check(received.count == 1 && received[0] == Data("{\"type\":\"ping\"}".utf8),
                  "reassembles a frame split across reads")
        } catch {
            check(false, "reassembles a frame split across reads: \(error)")
        }
        do {
            let one = try Wire.frame(Data("{\"type\":\"a\"}".utf8))
            let two = try Wire.frame(Data("{\"type\":\"b\"}".utf8))
            var reader = FrameReader()
            var count = 0
            try reader.feed(one + two) { _ in count += 1 }
            check(count == 2, "delivers two frames packed in one read")
        } catch {
            check(false, "delivers two frames packed in one read: \(error)")
        }
        var zero = FrameReader()
        expectThrow("rejects a zero-length control frame") {
            try zero.feed(Data([0, 0, 0, 0])) { _ in }
        }
        expectThrow("a poisoned stream stays poisoned") {
            try zero.feed(Data([0, 0, 0, 2, 0x7b, 0x7d])) { _ in }
        }
        var oversized = FrameReader()
        expectThrow("rejects a control frame above the control limit") {
            try oversized.feed(Data([0, 0, 0x80, 0x00])) { _ in }
        }
        expectThrow("rejects a NUL byte inside control JSON") {
            _ = try Wire.object(Data([0x7b, 0x00, 0x7d]))
        }
        expectThrow("rejects a control payload that does not start with an object") {
            _ = try Wire.object(Data("[]".utf8))
        }
        check(Wire.maxFrame == 8 * 1024 * 1024, "Wire.maxFrame is 8 MiB matching receiver")
        do {
            let fiveMiB = Data(repeating: 0xab, count: 5 * 1024 * 1024)
            let framed = try Wire.frame(fiveMiB)
            let prefixLen = framed.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            check(framed.count == fiveMiB.count + 4 && prefixLen == fiveMiB.count,
                  "frames a 5 MiB video payload cleanly within the 8 MiB limit")
        } catch {
            check(false, "frames a 5 MiB video payload cleanly: \(error)")
        }
    }

    static func annexBTests() {
        let idr = Data([0x65, 0x88, 0x84])
        let slice = Data([0x41, 0x9a])
        var avcc = Data([0, 0, 0, 3]) + idr + Data([0, 0, 0, 2]) + slice
        let sets = [Data([0x67, 0x42]), Data([0x68, 0xce])]
        let expected = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xce]) + Data([0, 0, 0, 1]) + idr
            + Data([0, 0, 0, 1]) + slice
        let output = avcc.withUnsafeBytes { AnnexB.fromAVCC($0, parameterSets: sets) }
        check(output == expected, "converts AVCC to Annex-B with SPS/PPS on keyframes")

        // Contiguous CMBlockBuffer fast path.
        var contigBlock: CMBlockBuffer?
        let contigMem = UnsafeMutableRawPointer.allocate(byteCount: avcc.count, alignment: 1)
        defer { contigMem.deallocate() }
        avcc.copyBytes(to: contigMem.assumingMemoryBound(to: UInt8.self), count: avcc.count)
        let contigStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: contigMem, blockLength: avcc.count,
            blockAllocator: kCFAllocatorNull, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &contigBlock)
        check(contigStatus == kCMBlockBufferNoErr && contigBlock != nil
              && CMBlockBufferIsRangeContiguous(contigBlock!, atOffset: 0, length: avcc.count)
              && AnnexB.fromBlockBuffer(contigBlock!, parameterSets: sets) == expected,
              "converts a contiguous CMBlockBuffer to intact Annex-B")

        // Non-contiguous 2-segment CMBlockBuffer splitting an AVCC NAL unit across two
        // separate heap allocations so reading past segment 0 would yield corrupt bytes.
        let bigNal = Data((0..<64).map { UInt8(($0 * 17 + 5) & 0xff) })
        let fullAvcc = Data([0, 0, 0, UInt8(bigNal.count)]) + bigNal + Data([0, 0, 0, 2]) + slice
        let fullExpected = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xce])
            + Data([0, 0, 0, 1]) + bigNal + Data([0, 0, 0, 1]) + slice
        let splitAt = 19
        let part1 = fullAvcc.prefix(splitAt)
        let part2 = fullAvcc.dropFirst(splitAt)
        let seg1 = UnsafeMutableRawPointer.allocate(byteCount: part1.count + 64, alignment: 1)
        let seg2 = UnsafeMutableRawPointer.allocate(byteCount: part2.count, alignment: 1)
        defer { seg1.deallocate(); seg2.deallocate() }
        memset(seg1, 0xee, part1.count + 64)
        part1.copyBytes(to: seg1.assumingMemoryBound(to: UInt8.self), count: part1.count)
        part2.copyBytes(to: seg2.assumingMemoryBound(to: UInt8.self), count: part2.count)
        var nonContigBlock: CMBlockBuffer?
        let s0 = CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault, capacity: 2, flags: 0, blockBufferOut: &nonContigBlock)
        let s1 = nonContigBlock.map {
            CMBlockBufferAppendMemoryBlock(
                $0, memoryBlock: seg1, length: part1.count, blockAllocator: kCFAllocatorNull,
                customBlockSource: nil, offsetToData: 0, dataLength: part1.count, flags: 0)
        } ?? kCMBlockBufferBadPointerParameterErr
        let s2 = nonContigBlock.map {
            CMBlockBufferAppendMemoryBlock(
                $0, memoryBlock: seg2, length: part2.count, blockAllocator: kCFAllocatorNull,
                customBlockSource: nil, offsetToData: 0, dataLength: part2.count, flags: 0)
        } ?? kCMBlockBufferBadPointerParameterErr
        let isContig = nonContigBlock.map {
            CMBlockBufferIsRangeContiguous($0, atOffset: 0, length: fullAvcc.count)
        } ?? true
        let nonContigOut = nonContigBlock.flatMap { AnnexB.fromBlockBuffer($0, parameterSets: sets) }
        check(s0 == kCMBlockBufferNoErr && s1 == kCMBlockBufferNoErr && s2 == kCMBlockBufferNoErr
              && !isContig && nonContigOut == fullExpected,
              "converts a non-contiguous 2-segment CMBlockBuffer split mid-NAL to intact Annex-B")

        avcc = Data([0, 0, 0, 9, 0x65])
        check(avcc.withUnsafeBytes { AnnexB.fromAVCC($0, parameterSets: []) } == nil,
              "rejects an AVCC length that runs past the sample")
    }

    // A modifier key's own press must show the modifier and its release must
    // clear it, whether the message reports the state before or after the event.
    static func modifierTransitionTests() {
        let recorder = Recorder()
        let input = RemoteInput(bounds: { CGRect(x: 0, y: 0, width: 1920, height: 1200) },
                                sink: { recorder.posted.append($0) })
        func shiftKey(_ state: Int, modifiers: Int) throws {
            try input.handle(["type": "key", "device": 1, "code": 42, "keysym": 0xffe1,
                              "modifiers": modifiers, "locks": 0, "state": state, "mapping": "logical"])
        }
        do {
            try shiftKey(1, modifiers: 0)   // state before: nothing held; Shift goes down
            try shiftKey(0, modifiers: 1)   // state before: Shift held; Shift goes up
            check(recorder.posted.map { $0.flags.contains(.maskShift) } == [true, false],
                  "a Shift press shows Shift and its release clears it (state before the event)")
        } catch {
            check(false, "Shift transitions, state before: \(error)")
        }
        recorder.posted.removeAll()
        do {
            try shiftKey(1, modifiers: 1)   // state after: Shift now held
            try shiftKey(0, modifiers: 0)   // state after: Shift now released
            check(recorder.posted.map { $0.flags.contains(.maskShift) } == [true, false],
                  "a Shift press shows Shift and its release clears it (state after the event)")
        } catch {
            check(false, "Shift transitions, state after: \(error)")
        }
    }

    static func logicalKey(_ input: RemoteInput, _ code: Int, _ sym: Int, _ state: Int,
                           modifiers: Int = 0, locks: Int = 0) throws {
        try input.handle(["type": "key", "device": 1, "code": code, "keysym": sym,
                          "modifiers": modifiers, "locks": locks, "state": state, "mapping": "logical"])
    }

    static func modifierRepeatTests() {
        let recorder = Recorder()
        let input = RemoteInput(bounds: { CGRect(x: 0, y: 0, width: 1920, height: 1200) },
                                sink: { recorder.posted.append($0) })
        do {
            try logicalKey(input, 125, 0xffeb, 1)
            try logicalKey(input, 125, 0xffeb, 2, modifiers: 8)
            try logicalKey(input, 125, 0xffeb, 0, modifiers: 8)
            check(recorder.posted.map { $0.type } == [.flagsChanged, .flagsChanged],
                  "a Command repeat posts no flagsChanged event")

            recorder.posted.removeAll()
            // A special key needs no layout Shift/Option, so those bits must
            // not survive from its initial press after the live state changes.
            try logicalKey(input, 14, 0xff08, 1, modifiers: 1 | 4 | 8)
            try logicalKey(input, 14, 0xff08, 2, modifiers: 2, locks: 1)
            try input.handle(["type": "pointer", "x": 0.5, "y": 0.5])
            let repeatEvent = recorder.posted.dropFirst().first
            let liveFlags: CGEventFlags = [.maskControl, .maskAlphaShift]
            let checkedFlags: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskControl, .maskAlphaShift]
            check(repeatEvent?.type == .keyDown && repeatEvent?.getIntegerValueField(.keyboardEventAutorepeat) == 1
                  && repeatEvent?.flags.intersection(checkedFlags) == liveFlags,
                  "a repeated ordinary key uses current modifiers and locks, not press-time flags")
            check(recorder.posted.last?.type == .mouseMoved && recorder.posted.last?.flags.intersection(checkedFlags) == liveFlags,
                  "an ordinary key repeat also updates modifiers for later pointer events")
        } catch {
            check(false, "modifier repeats: \(error)")
        }
    }

    static func commandSideTests() {
        let recorder = Recorder()
        let input = RemoteInput(bounds: { CGRect(x: 0, y: 0, width: 1920, height: 1200) },
                                sink: { recorder.posted.append($0) })
        let left: UInt64 = 0x08, right: UInt64 = 0x10, noncoalesced: UInt64 = 0x100
        func deviceFlags(_ event: CGEvent) -> UInt64 { event.flags.rawValue & (left | right | noncoalesced) }
        do {
            try logicalKey(input, 125, 0xffeb, 1)
            try logicalKey(input, 126, 0xffec, 1, modifiers: 8)
            try logicalKey(input, 125, 0xffeb, 0, modifiers: 8)
            try input.handle(["type": "pointer", "x": 0.5, "y": 0.5])
            try input.handle(["type": "button", "button": 272, "state": 1, "x": 0.5, "y": 0.5])
            try input.handle(["type": "scroll", "dx": 0, "dy": -15, "phase": 2, "source": 1])
            try logicalKey(input, 126, 0xffec, 0, modifiers: 8)
            let transitions = recorder.posted.filter { $0.type == .flagsChanged }
            check(transitions.map(deviceFlags) == [left | noncoalesced, left | right | noncoalesced,
                                                   right | noncoalesced, noncoalesced],
                  "Command press and release events carry the currently held left/right device bits")
            check(transitions.map { $0.flags.contains(.maskCommand) } == [true, true, true, false],
                  "releasing Left Command keeps Command set until Right Command is released")
            let pointerEvents = recorder.posted.filter { $0.type != .flagsChanged }
            check(pointerEvents.map { $0.type } == [.mouseMoved, .leftMouseDown, .scrollWheel]
                  && pointerEvents.allSatisfy { $0.flags.contains(.maskCommand) && deviceFlags($0) == (right | noncoalesced) },
                  "motion, button and scroll events retain the held Right Command flags")
        } catch {
            check(false, "Command sides: \(error)")
        }
    }

    static func capsLockTests() {
        let recorder = Recorder()
        let input = RemoteInput(bounds: { CGRect(x: 0, y: 0, width: 1920, height: 1200) },
                                sink: { recorder.posted.append($0) })
        do {
            try logicalKey(input, 58, 0xffe5, 1)
            try logicalKey(input, 58, 0xffe5, 2, locks: 1)
            try logicalKey(input, 58, 0xffe5, 0, locks: 1)
            try logicalKey(input, 58, 0xffe5, 1, locks: 1)
            try logicalKey(input, 58, 0xffe5, 2)
            try logicalKey(input, 58, 0xffe5, 0)
            check(recorder.posted.map { $0.type } == Array(repeating: .flagsChanged, count: 4)
                  && recorder.posted.map { $0.flags.contains(.maskAlphaShift) } == [true, true, false, false],
                  "Caps Lock toggles on press, stays unchanged on release and never repeats")
        } catch {
            check(false, "Caps Lock transitions: \(error)")
        }
    }

final class FakeVirtualKeyboard: VirtualKeyboardBackend {
    var status: HidHelperStatus
    var isReady: Bool { status.state == .ready }
    var keyboardReports: [(UInt8, [UInt16])] = []
    var consumerReports: [[UInt16]] = []
    var resets = 0
    var failSends = false

    init(ready: Bool = true) {
        status = HidHelperStatus(state: ready ? .ready : .unavailable, detail: 0)
    }

    func sendKeyboardReport(modifiers: UInt8, keys: [UInt16]) -> Bool {
        if failSends { return false }
        keyboardReports.append((modifiers, keys))
        return true
    }

    func sendConsumerReport(usages: [UInt16]) -> Bool {
        if failSends { return false }
        consumerReports.append(usages)
        return true
    }

    func reset() {
        resets += 1
    }

    func stop() {}
}

    static func physicalAndVirtualHidTests() {
        // 1. Physical 1:1 CGEvent fallback (no virtual keyboard): evdev maps directly
        // to macOS CGKeyCode, arrow/function keys include implicit SecondaryFn/NumericPad flags.
        do {
            let recorder = Recorder()
            let input = RemoteInput(bounds: { CGRect(x: 0, y: 0, width: 1920, height: 1200) },
                                    sink: { recorder.posted.append($0) })
            try input.handle(["type": "key", "device": 1, "code": 125, "keysym": 0xffeb,
                              "modifiers": 0, "locks": 0, "state": 1, "mapping": "logical"])
            try input.handle(["type": "key", "device": 1, "code": 103, "keysym": 0xff52,
                              "modifiers": 8, "locks": 0, "state": 1, "mapping": "logical"])
            try input.handle(["type": "key", "device": 1, "code": 103, "keysym": 0xff52,
                              "modifiers": 8, "locks": 0, "state": 0, "mapping": "logical"])
            try input.handle(["type": "key", "device": 1, "code": 125, "keysym": 0xffeb,
                              "modifiers": 8, "locks": 0, "state": 0, "mapping": "logical"])
            check(recorder.posted.count == 4
                  && recorder.posted[0].type == .flagsChanged
                  && recorder.posted[0].getIntegerValueField(.keyboardEventKeycode) == 55
                  && recorder.posted[0].flags.contains(.maskCommand)
                  && recorder.posted[1].type == .keyDown
                  && recorder.posted[1].getIntegerValueField(.keyboardEventKeycode) == 126
                  && recorder.posted[1].flags.contains(.maskSecondaryFn)
                  && recorder.posted[1].flags.contains(.maskNumericPad)
                  && recorder.posted[3].type == .flagsChanged
                  && !recorder.posted[3].flags.contains(.maskCommand),
                  "physical 1:1 CGEvent fallback maps evdev Meta+Up with implicit SecondaryFn/NumericPad flags")
        } catch {
            check(false, "physical CGEvent fallback: \(error)")
        }

        // 2. Ready virtual HID backend receives raw USB HID reports for Meta hold + keys,
        // ignores Linux repeat events (macOS repeats natively), updates pointer modifier flags,
        // and resets on cancel.
        do {
            let recorder = Recorder()
            let fakeHid = FakeVirtualKeyboard(ready: true)
            let input = RemoteInput(bounds: { CGRect(x: 0, y: 0, width: 1920, height: 1200) },
                                    sink: { recorder.posted.append($0) },
                                    virtualKeyboard: fakeHid)
            // Press Left Meta (evdev 125 -> HID modifier 0x08)
            try input.handle(["type": "key", "device": 1, "code": 125, "keysym": 0xffeb,
                              "modifiers": 0, "locks": 0, "state": 1, "mapping": "logical"])
            // Press C (evdev 46 -> HID usage 0x06), repeat, then release C
            try input.handle(["type": "key", "device": 1, "code": 46, "keysym": 0x63,
                              "modifiers": 8, "locks": 0, "state": 1, "mapping": "logical"])
            try input.handle(["type": "key", "device": 1, "code": 46, "keysym": 0x63,
                              "modifiers": 8, "locks": 0, "state": 2, "mapping": "logical"])
            // Pointer click while Meta held in virtual HID must carry Command flag on CGEvent
            try input.handle(["type": "button", "button": 272, "state": 1, "x": 0.5, "y": 0.5])
            try input.handle(["type": "button", "button": 272, "state": 0, "x": 0.5, "y": 0.5])
            try input.handle(["type": "key", "device": 1, "code": 46, "keysym": 0x63,
                              "modifiers": 8, "locks": 0, "state": 0, "mapping": "logical"])
            // Cancel while Meta still held must reset virtual HID
            try input.handle(["type": "cancel", "scope": "all"])
            check(fakeHid.keyboardReports.count == 3
                  && fakeHid.keyboardReports[0].0 == 0x08 && fakeHid.keyboardReports[0].1 == []
                  && fakeHid.keyboardReports[1].0 == 0x08 && fakeHid.keyboardReports[1].1 == [0x06]
                  && fakeHid.keyboardReports[2].0 == 0x08 && fakeHid.keyboardReports[2].1 == []
                  && fakeHid.resets == 1
                  && recorder.posted.count == 2
                  && recorder.posted[0].type == .leftMouseDown
                  && recorder.posted[0].flags.contains(.maskCommand)
                  && input.heldCount == 0,
                  "virtual HID backend receives raw modifier+key reports, suppresses repeat, syncs mouse flags, and resets on cancel")
        } catch {
            check(false, "virtual HID backend: \(error)")
        }

        // 3. When virtual HID send fails mid-session, RemoteInput cleanly falls back to CGEvent.
        do {
            let recorder = Recorder()
            let fakeHid = FakeVirtualKeyboard(ready: true)
            fakeHid.failSends = true
            let input = RemoteInput(bounds: { CGRect(x: 0, y: 0, width: 1920, height: 1200) },
                                    sink: { recorder.posted.append($0) },
                                    virtualKeyboard: fakeHid)
            try input.handle(["type": "key", "device": 1, "code": 30, "keysym": 0x61,
                              "modifiers": 0, "locks": 0, "state": 1, "mapping": "logical"])
            try input.handle(["type": "key", "device": 1, "code": 30, "keysym": 0x61,
                              "modifiers": 0, "locks": 0, "state": 0, "mapping": "logical"])
            check(recorder.posted.count == 2
                  && recorder.posted[0].type == .keyDown
                  && recorder.posted[0].getIntegerValueField(.keyboardEventKeycode) == 0
                  && recorder.posted[1].type == .keyUp
                  && fakeHid.resets >= 1,
                  "virtual HID write failure falls back transparently to physical CGEvent")
        } catch {
            check(false, "virtual HID fallback on failure: \(error)")
        }

        // 4. JIS, Menu, Wakeup, and Brightness keymap additions.
        check(KeyMap.hidKey(forEvdev: 85) == .keyboard(0x35) && KeyMap.macKeyCode(forEvdev: 85) == 50,
              "KeyMap maps JIS Zenkaku/Hankaku (85) to HID 0x35 and macOS keycode 50")
        check(KeyMap.hidKey(forEvdev: 90) == .keyboard(0x88) && KeyMap.macKeyCode(forEvdev: 90) == 104
              && KeyMap.hidKey(forEvdev: 91) == .keyboard(0x88) && KeyMap.macKeyCode(forEvdev: 91) == 104,
              "KeyMap maps JIS Katakana (90) and Hiragana (91) to HID 0x88 and macOS Kana 104")
        check(KeyMap.hidKey(forEvdev: 139) == .keyboard(0x65) && KeyMap.macKeyCode(forEvdev: 139) == 110
              && KeyMap.macKeyCode(forEvdev: 143) == 63,
              "KeyMap maps Menu (139) and Wakeup (143)")
        check(KeyMap.hidKey(forEvdev: 224) == .consumer(0x70) && KeyMap.hidKey(forEvdev: 225) == .consumer(0x6F),
              "KeyMap maps BrightnessDown (224) and BrightnessUp (225) to USB HID consumer usages")
        do {
            let recorder = Recorder()
            let fakeHid = FakeVirtualKeyboard(ready: true)
            let input = RemoteInput(bounds: { CGRect(x: 0, y: 0, width: 1920, height: 1200) },
                                    sink: { recorder.posted.append($0) },
                                    virtualKeyboard: fakeHid)
            try input.handle(["type": "key", "device": 1, "code": 225, "keysym": 0,
                              "modifiers": 0, "locks": 0, "state": 1, "mapping": "physical"])
            try input.handle(["type": "key", "device": 1, "code": 225, "keysym": 0,
                              "modifiers": 0, "locks": 0, "state": 0, "mapping": "physical"])
            check(fakeHid.consumerReports == [[0x6F], []],
                  "BrightnessUp sends consumer usage 0x6F press and release through virtual HID")
        } catch {
            check(false, "Brightness consumer report: \(error)")
        }
    }

    static func tabletAndTouchTests() {
        let negRect = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        var clock: TimeInterval = 100.0
        let recorder = Recorder()
        let input = RemoteInput(bounds: { negRect }, now: { clock }, sink: { recorder.posted.append($0) })
        do {
            // Active stylus proximity (pen) -> tip down -> axis (pressure + tilt) -> tip up -> eraser switch -> barrel -> cancel
            try input.handle(["type": "tablet", "event": "proximity", "in": true, "tool": "pen",
                              "id": 12345, "caps": 7, "x": 0.5, "y": 0.25])
            check(recorder.posted.count == 2 && recorder.posted[0].type == .tabletProximity
                  && recorder.posted[0].getIntegerValueField(.tabletProximityEventPointerType) == 1
                  && recorder.posted[0].getIntegerValueField(.tabletProximityEventEnterProximity) == 1
                  && (recorder.posted[0].getIntegerValueField(.tabletProximityEventCapabilityMask) & 0x0580) == 0x0580
                  && abs(recorder.posted[1].location.x - (-960.0)) < 0.01
                  && abs(recorder.posted[1].location.y - 390.0) < 0.01,
                  "tablet proximity maps strictly into negative-origin virtual display with Quartz capability mask")

            recorder.posted.removeAll()
            try input.handle(["type": "tablet", "event": "tip", "down": true, "x": 0.5, "y": 0.25, "pressure": 0.25, "buttons": 1])
            try input.handle(["type": "tablet", "event": "axis", "x": 0.501, "y": 0.252, "pressure": 0.65,
                              "tiltX": 30.0, "tiltY": -15.0, "distance": 0.0, "rotation": 0.0, "buttons": 1])
            try input.handle(["type": "tablet", "event": "tip", "down": false, "x": 0.501, "y": 0.252, "pressure": 0.0, "buttons": 0])
            check(recorder.posted.count == 3
                  && recorder.posted[0].type == .leftMouseDown
                  && recorder.posted[1].type == .leftMouseDragged
                  && recorder.posted[2].type == .leftMouseUp
                  && abs(recorder.posted[1].getDoubleValueField(.mouseEventPressure) - 0.65) < 0.02
                  && abs(recorder.posted[1].getDoubleValueField(.tabletEventPointPressure) - 0.65) < 0.02
                  && abs(recorder.posted[1].getDoubleValueField(.tabletEventTiltX) - 0.5) < 0.02
                  && abs(recorder.posted[1].getDoubleValueField(.tabletEventTiltY) - (-0.25)) < 0.02
                  && recorder.posted[1].getIntegerValueField(.mouseEventSubtype) == Int64(CGEventMouseSubtype.tabletPoint.rawValue),
                  "tablet stroke sets BOTH mouseEventPressure and tabletEventPointPressure plus tilt and tabletPoint subtype")

            recorder.posted.removeAll()
            try input.handle(["type": "tablet", "event": "proximity", "in": true, "tool": "eraser",
                              "id": 999, "caps": 1, "x": 0.25, "y": 0.5])
            check(recorder.posted.count == 3
                  && recorder.posted[0].type == .tabletProximity
                  && recorder.posted[0].getIntegerValueField(.tabletProximityEventEnterProximity) == 0
                  && recorder.posted[1].type == .tabletProximity
                  && recorder.posted[1].getIntegerValueField(.tabletProximityEventPointerType) == 3
                  && recorder.posted[1].getIntegerValueField(.tabletProximityEventEnterProximity) == 1,
                  "switching pen to eraser emits proximity-out then eraser proximity-in")

            recorder.posted.removeAll()
            try input.handle(["type": "tablet", "event": "button", "button": 331, "state": 1, "x": 0.25, "y": 0.5, "buttons": 2])
            try input.handle(["type": "tablet", "event": "button", "button": 331, "state": 0, "x": 0.25, "y": 0.5, "buttons": 0])
            try input.handle(["type": "cancel", "scope": "all"])
            check(recorder.posted.count == 3
                  && recorder.posted[0].type == .rightMouseDown
                  && recorder.posted[1].type == .rightMouseUp
                  && recorder.posted[2].type == .tabletProximity
                  && recorder.posted[2].getIntegerValueField(.tabletProximityEventEnterProximity) == 0,
                  "stylus lower barrel maps to right-click and cancel emits proximity-out")

            // Multi-touch: 1-finger tap at exact display coordinates
            recorder.posted.removeAll()
            clock = 200.0
            try input.handle(["type": "touch", "phase": "frame", "points": [["id": 0, "state": "down", "x": 0.5, "y": 0.5, "xmm": 150.0, "ymm": 90.0]]])
            clock = 200.08
            try input.handle(["type": "touch", "phase": "frame", "points": [["id": 0, "state": "up", "x": 0.5, "y": 0.5, "xmm": 150.5, "ymm": 90.2]]])
            check(recorder.posted.count == 2 && recorder.posted[0].type == .leftMouseDown && recorder.posted[1].type == .leftMouseUp
                  && abs(recorder.posted[0].location.x - (-960.0)) < 0.01 && abs(recorder.posted[0].location.y - 660.0) < 0.01,
                  "1-finger tap clicks at exact virtual display coordinates")

            // Multi-touch: 1-finger long-press -> right click, lift does nothing
            recorder.posted.removeAll()
            clock = 210.0
            try input.handle(["type": "touch", "phase": "frame", "points": [["id": 0, "state": "down", "x": 0.25, "y": 0.25, "xmm": 75.0, "ymm": 45.0]]])
            clock = 210.6
            input.tickLongPress()
            try input.handle(["type": "touch", "phase": "frame", "points": [["id": 0, "state": "up", "x": 0.25, "y": 0.25, "xmm": 75.0, "ymm": 45.0]]])
            check(recorder.posted.count == 2 && recorder.posted[0].type == .rightMouseDown && recorder.posted[1].type == .rightMouseUp,
                  "1-finger long-press emits right-click and ignores lift")

            // Multi-touch: 1-finger drag -> leftMouseDown, leftMouseDragged, leftMouseUp
            recorder.posted.removeAll()
            clock = 220.0
            try input.handle(["type": "touch", "phase": "frame", "points": [["id": 0, "state": "down", "x": 0.2, "y": 0.2, "xmm": 60.0, "ymm": 40.0]]])
            clock = 220.05
            try input.handle(["type": "touch", "phase": "frame", "points": [["id": 0, "state": "move", "x": 0.3, "y": 0.2, "xmm": 90.0, "ymm": 40.0]]])
            clock = 220.1
            try input.handle(["type": "touch", "phase": "frame", "points": [["id": 0, "state": "up", "x": 0.3, "y": 0.2, "xmm": 90.0, "ymm": 40.0]]])
            check(recorder.posted.map { $0.type } == [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
                  "1-finger drag emits left mouse down, dragged, and up")

            // Multi-touch: 2-finger smooth scroll sets event.location inside virtual display
            recorder.posted.removeAll()
            clock = 230.0
            try input.handle(["type": "touch", "phase": "frame", "points": [
                ["id": 0, "state": "down", "x": 0.4, "y": 0.5, "xmm": 120.0, "ymm": 90.0],
                ["id": 1, "state": "down", "x": 0.6, "y": 0.5, "xmm": 180.0, "ymm": 90.0]
            ]])
            clock = 230.05
            try input.handle(["type": "touch", "phase": "frame", "points": [
                ["id": 0, "state": "move", "x": 0.4, "y": 0.4, "xmm": 120.0, "ymm": 72.0],
                ["id": 1, "state": "move", "x": 0.6, "y": 0.4, "xmm": 180.0, "ymm": 72.0]
            ]])
            clock = 230.1
            try input.handle(["type": "touch", "phase": "frame", "points": [
                ["id": 0, "state": "up", "x": 0.4, "y": 0.4, "xmm": 120.0, "ymm": 72.0],
                ["id": 1, "state": "up", "x": 0.6, "y": 0.4, "xmm": 180.0, "ymm": 72.0]
            ]])
            let scrolls = recorder.posted.filter { $0.type == .scrollWheel }
            check(scrolls.count == 3
                  && scrolls.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) } == [1, 2, 4]
                  && scrolls.allSatisfy { negRect.contains($0.location) },
                  "2-finger scroll emits began/changed/ended anchored inside virtual display bounds")

            // Multi-touch: 2-finger pinch emits Command+ zoom step
            recorder.posted.removeAll()
            clock = 240.0
            try input.handle(["type": "touch", "phase": "frame", "points": [
                ["id": 0, "state": "down", "x": 0.45, "y": 0.5, "xmm": 135.0, "ymm": 90.0],
                ["id": 1, "state": "down", "x": 0.55, "y": 0.5, "xmm": 165.0, "ymm": 90.0]
            ]])
            clock = 240.05
            try input.handle(["type": "touch", "phase": "frame", "points": [
                ["id": 0, "state": "move", "x": 0.40, "y": 0.5, "xmm": 120.0, "ymm": 90.0],
                ["id": 1, "state": "move", "x": 0.60, "y": 0.5, "xmm": 180.0, "ymm": 90.0]
            ]])
            try input.handle(["type": "touch", "phase": "frame", "points": [
                ["id": 0, "state": "up", "x": 0.40, "y": 0.5, "xmm": 120.0, "ymm": 90.0],
                ["id": 1, "state": "up", "x": 0.60, "y": 0.5, "xmm": 180.0, "ymm": 90.0]
            ]])
            let zooms = recorder.posted.filter { $0.type == .keyDown && $0.flags.contains(.maskCommand) }
            check(!zooms.isEmpty && zooms.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 24 },
                  "2-finger pinch outward emits Command+ zoom steps")
        } catch {
            check(false, "tablet and multi-touch tests: \(error)")
        }
    }

    // Scroll semantics as the receiver sends them: wheel steps are phase-2
    // updates with source 1 and no gesture phase; trackpad gestures bracket
    // with begin/update/end.
    static func scrollSemanticTests() {
        let recorder = Recorder()
        let input = RemoteInput(bounds: { CGRect(x: 0, y: 0, width: 1920, height: 1200) },
                                sink: { recorder.posted.append($0) })
        do {
            try input.handle(["type": "scroll", "dx": 0, "dy": -15, "phase": 2, "source": 1])
            let wheel = recorder.posted.last!
            check(wheel.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
                  && wheel.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
                  "a wheel step is a discrete event with no gesture phase")
        } catch {
            check(false, "wheel step: \(error)")
        }
        recorder.posted.removeAll()
        do {
            try input.handle(["type": "scroll", "dx": 0, "dy": 0, "phase": 1, "source": 2])
            try input.handle(["type": "scroll", "dx": 0, "dy": -4, "phase": 2, "source": 2])
            try input.handle(["type": "scroll", "dx": 0, "dy": 0, "phase": 3, "source": 2])
            let phases = recorder.posted.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }
            let continuous = recorder.posted.map { $0.getIntegerValueField(.scrollWheelEventIsContinuous) }
            check(phases == [1, 2, 4] && continuous == [1, 1, 1],
                  "a trackpad gesture maps to began, changed, ended and stays continuous")
        } catch {
            check(false, "trackpad gesture: \(error)")
        }
        expectThrow("a wheel step cannot begin a gesture") {
            try input.handle(["type": "scroll", "dx": 0, "dy": 0, "phase": 1, "source": 1])
        }
    }

    static func code(_ text: String) throws -> Data {
        let bytes = Array(text.utf8)
        return try bytes.withUnsafeBufferPointer { try PairingCode.decode($0) }
    }

    static func pairingTests() {
        check((try? code("AAAAAAAAAAAAAAAAAAAAAAAAAA")) == Data(count: 16), "decodes the all-zero code")
        check((try? code("77777777777777777777777774")) == Data(repeating: 0xff, count: 16), "decodes the all-ones code")
        check((try? code("77777-77777-7777-7777-7777-7774")) == Data(repeating: 0xff, count: 16),
              "accepts the grouped display form")
        check((try? code("aaaaa aaaaa-aaaa aaaa-aaaa-aaaa")) == Data(count: 16), "is case-insensitive and ignores spaces")
        expectThrow("refuses 25 characters") { _ = try code("AAAAAAAAAAAAAAAAAAAAAAAAA") }
        expectThrow("refuses 27 characters") { _ = try code("AAAAAAAAAAAAAAAAAAAAAAAAAAA") }
        expectThrow("refuses non-canonical trailing bits") { _ = try code("AAAAAAAAAAAAAAAAAAAAAAAAAB") }
        expectThrow("refuses characters outside base32") { _ = try code("AAAAAAAAAAAAAAAAAAAAAAAAA1") }
        expectThrow("refuses base32 padding") { _ = try code("AAAAAAAAAAAAAAAAAAAAAAAAAA======") }
    }

    static func inputTests() {
        let recorder = Recorder()
        let input = RemoteInput(bounds: { CGRect(x: 0, y: 0, width: 1920, height: 1200) },
                                sink: { recorder.events.append($0.type); recorder.posted.append($0) })
        do {
            try input.handle(["type": "pointer", "x": 0.5, "y": 0.5])
            check(recorder.events == [.mouseMoved], "pointer move posts a mouse-moved event")
        } catch {
            check(false, "pointer move: \(error)")
        }
        recorder.events.removeAll()
        expectThrow("pointer coordinates outside [0,1] are refused") {
            try input.handle(["type": "pointer", "x": 1.5, "y": 0.5])
        }
        recorder.events.removeAll()
        do {
            try input.handle(["type": "button", "button": 273, "state": 1, "x": 0.1, "y": 0.1])
            try input.handle(["type": "cancel", "scope": "all"])
            check(recorder.events == [.rightMouseDown, .rightMouseUp], "cancel releases a held secondary button")
        } catch {
            check(false, "button then cancel: \(error)")
        }
        recorder.events.removeAll()
        expectThrow("an unknown button code is refused") {
            try input.handle(["type": "button", "button": 275, "state": 1, "x": 0.1, "y": 0.1])
        }
        recorder.events.removeAll()
        do {
            let key: [String: Any] = ["type": "key", "device": 1, "code": 30, "keysym": 0x61,
                                      "modifiers": 0, "locks": 0, "state": 1, "mapping": "logical"]
            try input.handle(key)
            var release = key
            release["state"] = 0
            try input.handle(release)
            check(recorder.events.count == 2 && recorder.events[0] == .keyDown && recorder.events[1] == .keyUp,
                  "logical key press and release produce a matched key pair")
        } catch {
            check(false, "logical key pair: \(error)")
        }
        recorder.events.removeAll()
        expectThrow("a key without logical mapping is refused") {
            try input.handle(["type": "key", "device": 1, "code": 30, "keysym": 0x61,
                              "modifiers": 0, "locks": 0, "state": 1])
        }
        expectThrow("a non-Unicode, non-special keysym without a physical code is refused") {
            try input.handle(["type": "key", "device": 1, "code": 0, "keysym": 0x1000,
                              "modifiers": 0, "locks": 0, "state": 1, "mapping": "logical"])
        }
        recorder.events.removeAll()
        do {
            try input.handle(["type": "scroll", "dx": 0, "dy": -5, "phase": 2, "source": 0])
            check(recorder.events == [.scrollWheel], "numeric CG scroll phase posts a scroll event")
        } catch {
            check(false, "scroll with numeric phase: \(error)")
        }
        expectThrow("a scroll phase outside 0...4 is refused") {
            try input.handle(["type": "scroll", "dx": 0, "dy": 0, "phase": 5, "source": 0])
        }
        expectThrow("a scroll source outside 0...4 is refused") {
            try input.handle(["type": "scroll", "dx": 0, "dy": 1, "phase": 2, "source": 5])
        }
        expectThrow("scroll begin with non-zero deltas is refused") {
            try input.handle(["type": "scroll", "dx": 3, "dy": 0, "phase": 1, "source": 2])
        }
        recorder.events.removeAll()
        do {
            // begin, then cancel(): cancel must end the open gesture.
            try input.handle(["type": "scroll", "dx": 0, "dy": 0, "phase": 1, "source": 2])
            try input.handle(["type": "cancel", "scope": "all"])
            check(recorder.events == [.scrollWheel, .scrollWheel], "cancel ends an open scroll gesture")
        } catch {
            check(false, "scroll gesture cancel: \(error)")
        }
        recorder.events.removeAll()
        do {
            try input.handle(["type": "scroll", "dx": 0, "dy": 0, "phase": 1, "source": 2])
            try input.handle(["type": "scroll", "dx": 0, "dy": 0, "phase": 3, "source": 2])
            try input.handle(["type": "cancel", "scope": "all"])
            check(recorder.events == [.scrollWheel, .scrollWheel], "an ended gesture is not ended again by cancel")
        } catch {
            check(false, "scroll begin/end: \(error)")
        }
        expectThrow("a cancel with a non-'all' scope is refused") {
            try input.handle(["type": "cancel", "scope": "some"])
        }
        // Sub-pixel pointer residual accumulation: small fractional deltas accumulate
        // cleanly into integer CGEvent deltas while cursor position advances smoothly.
        do {
            let subRecorder = Recorder()
            let subInput = RemoteInput(bounds: { CGRect(x: 0, y: 0, width: 1920, height: 1200) },
                                       sink: { subRecorder.posted.append($0) })
            try subInput.handle(["type": "pointer", "x": 0.5, "y": 0.5])
            let startX = subRecorder.posted[0].location.x
            let startY = subRecorder.posted[0].location.y
            subRecorder.posted.removeAll()
            for _ in 0..<3 {
                try subInput.handle(["type": "pointer", "x": 0.5, "y": 0.5, "dx": 0.4, "dy": -0.4])
            }
            let dxs = subRecorder.posted.map { $0.getIntegerValueField(.mouseEventDeltaX) }
            let dys = subRecorder.posted.map { $0.getIntegerValueField(.mouseEventDeltaY) }
            let endX = subRecorder.posted.last!.location.x
            let endY = subRecorder.posted.last!.location.y
            check(dxs == [0, 1, 0] && dxs.reduce(0, +) == 1
                  && dys == [0, -1, 0] && dys.reduce(0, +) == -1
                  && abs((endX - startX) - 1.2) < 0.001
                  && abs((endY - startY) - (-1.2)) < 0.001,
                  "sub-pixel pointer deltas accumulate residuals without dropping fractional movement")
            // Cancel must clear fractional residuals.
            try subInput.handle(["type": "cancel", "scope": "all"])
            subRecorder.posted.removeAll()
            try subInput.handle(["type": "pointer", "x": 0.5, "y": 0.5, "dx": 0.4, "dy": 0.0])
            check(subRecorder.posted.count == 1 && subRecorder.posted[0].getIntegerValueField(.mouseEventDeltaX) == 0,
                  "cancel resets sub-pixel pointer delta residuals")
        } catch {
            check(false, "sub-pixel pointer residual accumulation: \(error)")
        }
    }

    // Multi-session coordination: one shared virtual keyboard with union HID
    // state, per-session cancel isolation, shared pointer and button refcounts.
    static func multiSessionTests() {
        let bounds = { CGRect(x: 0, y: 0, width: 1920, height: 1200) }

        // 1. HID union. A holds Shift, B holds 'a' and cancels: Shift stays in
        // the shared report and nothing resets. A's cancel releases it and resets.
        do {
            let fakeHid = FakeVirtualKeyboard(ready: true)
            let coordinator = InputCoordinator(live: false, virtualKeyboard: fakeHid)
            let recA = Recorder(), recB = Recorder()
            let inputA = RemoteInput(bounds: bounds, sink: { recA.posted.append($0) }, coordinator: coordinator)
            let inputB = RemoteInput(bounds: bounds, sink: { recB.posted.append($0) }, coordinator: coordinator)
            do {
                try inputA.handle(["type": "key", "device": 1, "code": 42, "keysym": 0xffe1,
                                   "modifiers": 0, "locks": 0, "state": 1, "mapping": "logical"])
                try inputB.handle(["type": "key", "device": 2, "code": 30, "keysym": 0x61,
                                   "modifiers": 0, "locks": 0, "state": 1, "mapping": "logical"])
                check(fakeHid.keyboardReports.last?.0 == 0x02 && fakeHid.keyboardReports.last?.1 == [0x04],
                      "two sessions share one keyboard report: A's Shift with B's key")
                try inputB.handle(["type": "cancel", "scope": "all"])
                check(fakeHid.keyboardReports.last?.0 == 0x02 && fakeHid.keyboardReports.last?.1 == [] && fakeHid.resets == 0,
                      "session B cancel keeps session A's Shift held and does not reset the virtual keyboard")
                try inputA.handle(["type": "cancel", "scope": "all"])
                check(fakeHid.resets == 1, "the last session to release resets the virtual keyboard once")
            } catch {
                check(false, "multi-session HID union: \(error)")
            }
        }

        // 2. Fallback keys. Both sessions hold the same physical key. A's cancel
        // must not post a key-up while B still holds it; B's release then does.
        do {
            let coordinator = InputCoordinator(live: false, virtualKeyboard: nil)
            let recA = Recorder(), recB = Recorder()
            let inputA = RemoteInput(bounds: bounds, sink: { recA.posted.append($0) }, coordinator: coordinator)
            let inputB = RemoteInput(bounds: bounds, sink: { recB.posted.append($0) }, coordinator: coordinator)
            do {
                try inputA.handle(["type": "key", "device": 1, "code": 30, "keysym": 0,
                                   "modifiers": 0, "locks": 0, "state": 1, "mapping": "physical"])
                try inputB.handle(["type": "key", "device": 2, "code": 30, "keysym": 0,
                                   "modifiers": 0, "locks": 0, "state": 1, "mapping": "physical"])
                let postedBeforeCancel = recA.posted.count
                try inputA.handle(["type": "cancel", "scope": "all"])
                check(recA.posted.count == postedBeforeCancel && !recA.posted.contains(where: { $0.type == .keyUp }),
                      "session A cancel does not release a key that session B still holds")
                try inputB.handle(["type": "key", "device": 2, "code": 30, "keysym": 0,
                                   "modifiers": 0, "locks": 0, "state": 0, "mapping": "physical"])
                check(recB.posted.last?.type == .keyUp && recB.posted.last?.getIntegerValueField(.keyboardEventKeycode) == 0,
                      "session B releases the shared key once no other session holds it")
            } catch {
                check(false, "multi-session fallback keys: \(error)")
            }
        }

        // 3. Shared pointer and buttons. One press for the button and one release
        // at the end. Session B's motion while A holds the button drags it.
        do {
            let coordinator = InputCoordinator(live: false, virtualKeyboard: nil)
            let recA = Recorder(), recB = Recorder()
            let inputA = RemoteInput(bounds: bounds, sink: { recA.posted.append($0) }, coordinator: coordinator)
            let inputB = RemoteInput(bounds: bounds, sink: { recB.posted.append($0) }, coordinator: coordinator)
            do {
                try inputA.handle(["type": "pointer", "x": 0.5, "y": 0.5])
                try inputA.handle(["type": "button", "button": 272, "state": 1, "x": 0.5, "y": 0.5])
                try inputB.handle(["type": "button", "button": 272, "state": 1, "x": 0.5, "y": 0.5])
                let allPosted = recA.posted + recB.posted
                check(allPosted.filter { $0.type == .leftMouseDown }.count == 1,
                      "a button pressed by two sessions produces a single mouse-down")
                try inputB.handle(["type": "pointer", "x": 0.5, "y": 0.5, "dx": 10, "dy": 0])
                check(recB.posted.last?.type == .leftMouseDragged,
                      "motion from session B drags the button held by session A")
                try inputA.handle(["type": "button", "button": 272, "state": 0, "x": 0.5, "y": 0.5])
                let upsAfterA = (recA.posted + recB.posted).filter { $0.type == .leftMouseUp }.count
                try inputB.handle(["type": "button", "button": 272, "state": 0, "x": 0.5, "y": 0.5])
                let upsAfterB = (recA.posted + recB.posted).filter { $0.type == .leftMouseUp }.count
                check(upsAfterA == 0 && upsAfterB == 1,
                      "the mouse button is released only when the last session lets go")
            } catch {
                check(false, "shared pointer and button refcounts: \(error)")
            }
        }

        // 4. Each concurrent session owns a distinct Quartz tablet device ID.
        do {
            let coordinator = InputCoordinator(live: false, virtualKeyboard: nil)
            let first = RemoteInput(bounds: bounds, sink: { _ in }, coordinator: coordinator)
            let second = RemoteInput(bounds: bounds, sink: { _ in }, coordinator: coordinator)
            check(first.tabletDeviceID != second.tabletDeviceID,
                  "concurrent sessions receive distinct tablet device IDs")
        }
    }
}
