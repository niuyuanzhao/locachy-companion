// SPDX-License-Identifier: GPL-3.0-or-later
// Protocol and input-validation tests. Nothing here creates a display, reads
// the screen, posts an event or touches TCC: RemoteInput records the CGEvents
// it would post through an injected sink.
import CoreGraphics
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
        tabletAndTouchTests()
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
        expectThrow("a non-Unicode, non-special keysym is refused") {
            try input.handle(["type": "key", "device": 1, "code": 30, "keysym": 0x1000,
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
    }
}
