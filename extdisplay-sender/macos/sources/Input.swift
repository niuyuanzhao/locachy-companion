// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon
import IOKit.pwr_mgt

struct KeyIdentity: Hashable { let device: Int; let code: Int }
// flags: flags for the initial press; layoutFlags: only the Shift/Option
// required by the resolved character, carried forward into autorepeat.
struct MappedKey {
    let code: CGKeyCode
    let text: String?
    let flags: CGEventFlags
    var layoutFlags: CGEventFlags = []
    var modifier: CGEventFlags = []
}

// Logical keys are resolved against the target's active Unicode keyboard layout,
// not a hard-coded US map. Press-time mappings survive until the matching up.
enum KeyMapping {
    static func flags(_ modifiers: Int, _ locks: Int) -> CGEventFlags {
        var result: CGEventFlags = []
        if modifiers & 1 != 0 { result.insert(.maskShift) }
        if modifiers & 2 != 0 { result.insert(.maskControl) }
        if modifiers & (4 | 16) != 0 { result.insert(.maskAlternate) }
        if modifiers & 8 != 0 { result.insert(.maskCommand) }
        if locks & 1 != 0 { result.insert(.maskAlphaShift) }
        return result
    }
    static func special(_ keysym: UInt32) -> CGKeyCode? {
        let codes: [UInt32: CGKeyCode] = [
            0xff08: 51, 0xff09: 48, 0xfe20: 48, 0xff0d: 36, 0xff1b: 53,
            0xffff: 117, 0xff50: 115, 0xff51: 123, 0xff52: 126, 0xff53: 124,
            0xff54: 125, 0xff55: 116, 0xff56: 121, 0xff57: 119, 0xff63: 114,
            0xffe1: 56, 0xffe2: 60, 0xffe3: 59, 0xffe4: 62,
            0xffe7: 55, 0xffe8: 54, 0xffe9: 58, 0xffea: 61,
            0xffeb: 55, 0xffec: 54, 0xfe03: 61, 0xffe5: 57,
            0xff7e: 104, 0xff21: 102, 0xff22: 102, 0xff23: 104, 0xff24: 104,
            0xff25: 104, 0xff26: 104, 0xff27: 104, 0xff28: 102, 0xff29: 102,
            0xff2a: 102, 0xff2d: 104, 0xff30: 102, 0xff7f: 71,
            0xff8d: 76, 0xff95: 115, 0xff96: 123, 0xff97: 126, 0xff98: 124,
            0xff99: 125, 0xff9a: 116, 0xff9b: 121, 0xff9c: 119, 0xff9e: 114,
            0xff9f: 117, 0xffaa: 67, 0xffab: 69, 0xffad: 78, 0xffae: 65, 0xffaf: 75,
            0xffb0: 82, 0xffb1: 83, 0xffb2: 84, 0xffb3: 85, 0xffb4: 86,
            0xffb5: 87, 0xffb6: 88, 0xffb7: 89, 0xffb8: 91, 0xffb9: 92,
            0xffbe: 122, 0xffbf: 120, 0xffc0: 99, 0xffc1: 118, 0xffc2: 96,
            0xffc3: 97, 0xffc4: 98, 0xffc5: 100, 0xffc6: 101, 0xffc7: 109,
            0xffc8: 103, 0xffc9: 111, 0xffca: 105, 0xffcb: 107, 0xffcc: 113,
            0xffcd: 106, 0xffce: 64, 0xffcf: 79, 0xffd0: 80, 0xffd1: 90
        ]
        return codes[keysym]
    }
    // The modifier a modifier keysym contributes; empty for every other key.
    static func modifierBit(_ keysym: UInt32) -> CGEventFlags {
        switch keysym {
        case 0xffe1, 0xffe2: return .maskShift                  // Shift_L, Shift_R
        case 0xffe3, 0xffe4: return .maskControl                // Control_L, Control_R
        case 0xffe9, 0xffea, 0xfe03: return .maskAlternate      // Alt_L, Alt_R, ISO_Level3_Shift (AltGr)
        case 0xffe7, 0xffe8, 0xffeb, 0xffec: return .maskCommand // Meta_L/R, Super_L/R
        default: return []
        }
    }
    static func isModifier(_ code: CGKeyCode) -> Bool { [54,55,56,57,58,59,60,61,62,63].contains(code) }
    static func unicode(_ keysym: UInt32) -> String? {
        let value: UInt32
        if keysym >= 0x20 && keysym <= 0xff { value = keysym }
        else if keysym & 0xff000000 == 0x01000000 { value = keysym & 0xffffff }
        else { return nil }
        guard let scalar = UnicodeScalar(value), !CharacterSet.controlCharacters.contains(scalar) else { return nil }
        return String(scalar)
    }
    // Snapshot TIS keyboard layout data on the main thread so logical-fallback
    // lookups on the high-priority input queue never call Carbon TIS APIs off-main.
    static func snapshotKeyboardLayouts() -> (layouts: [Data], keyboardType: UInt32) {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        ].compactMap { $0 }
        var layouts: [Data] = []
        for source in sources {
            if let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
                let cfData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
                let length = CFDataGetLength(cfData)
                if length > 0, let ptr = CFDataGetBytePtr(cfData) {
                    layouts.append(Data(bytes: ptr, count: length))
                }
            }
        }
        return (layouts, UInt32(LMGetKbdType()))
    }

    static func logical(_ keysym: UInt32, flags: CGEventFlags,
                        cachedLayouts: [Data]? = nil,
                        keyboardType: UInt32? = nil) throws -> MappedKey {
        if let code = special(keysym) { return MappedKey(code: code, text: nil, flags: flags) }
        guard let text = unicode(keysym) else { throw SenderError("Unsupported logical keysym") }
        // A target IME may not expose a Unicode layout. In that case fall back
        // to the layout used beneath the input method, not to a guessed US map.
        let layouts: [Data]
        let kbdType: UInt32
        if let cachedLayouts, let keyboardType {
            layouts = cachedLayouts
            kbdType = keyboardType
        } else if Thread.isMainThread {
            let snap = snapshotKeyboardLayouts()
            layouts = snap.layouts
            kbdType = snap.keyboardType
        } else {
            layouts = []
            kbdType = 0
        }
        for data in layouts {
            if let matched = data.withUnsafeBytes({ raw -> MappedKey? in
                guard let base = raw.baseAddress else { return nil }
                let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
                for combination: UInt32 in [0, UInt32(shiftKey >> 8), UInt32(optionKey >> 8), UInt32((shiftKey | optionKey) >> 8)] {
                    for code: UInt16 in 0...127 {
                        var state: UInt32 = 0, length = 0
                        var chars = [UniChar](repeating: 0, count: 8)
                        let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), combination,
                            kbdType, OptionBits(kUCKeyTranslateNoDeadKeysBit), &state, chars.count, &length, &chars)
                        if result == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == text {
                            var layoutFlags: CGEventFlags = []
                            if combination & UInt32(shiftKey >> 8) != 0 { layoutFlags.insert(.maskShift) }
                            if combination & UInt32(optionKey >> 8) != 0 { layoutFlags.insert(.maskAlternate) }
                            let mapped = flags.subtracting([.maskShift, .maskAlternate, .maskAlphaShift]).union(layoutFlags)
                            return MappedKey(code: code, text: nil, flags: mapped, layoutFlags: layoutFlags)
                        }
                    }
                }
                return nil
            }) {
                return matched
            }
        }
        // Unicode fallback is text, not a fabricated physical key. Refuse it
        // under shortcut modifiers, where it would silently invoke wrong keys.
        guard flags.intersection([.maskControl, .maskCommand, .maskAlternate]).isEmpty else {
            throw SenderError("Logical shortcut is unavailable in the target keyboard layout")
        }
        return MappedKey(code: 0, text: text, flags: [])
    }
}

final class RemoteInput {
    typealias Sink = (CGEvent) -> Void

    private struct TouchContact {
        let id: Int
        let startX: Double
        let startY: Double
        let startXmm: Double
        let startYmm: Double
        let startTime: TimeInterval
        var x: Double
        var y: Double
        var xmm: Double
        var ymm: Double
        var maxTravelMm: Double = 0
    }

    private enum TouchGestureMode {
        case idle
        case singlePending(id: Int)
        case singleDragging(id: Int)
        case singleLongPressed(id: Int)
        case twoPending(id1: Int, id2: Int, startDistMm: Double, startMidX: Double, startMidY: Double, startTime: TimeInterval)
        case twoScrolling(lastMidPoint: CGPoint)
        case twoPinching(anchorDistMm: Double, zoomStepAccum: Double)
        case suppressed
    }

    private let bounds: () -> CGRect
    private let displays: () -> [CGRect]
    private let live: Bool
    private let sink: Sink
    private let keyboardSink: Sink
    private let now: () -> TimeInterval
    private let timerQueue: DispatchQueue
    // A real HID-state source for pointer/mouse/scroll/touch/tablet: menu
    // tracking treats sourceless synthetic clicks as malformed.
    private let source = CGEventSource(stateID: .hidSystemState)
    // A private-state source for fallback keyboard CGEvents posted to the
    // session tap, matching libvirtualhid and avoiding local keyboard state leaks.
    private let keyboardSource = CGEventSource(stateID: .privateState)
    private var virtualKeyboard: VirtualKeyboardBackend?
    private var held: [KeyIdentity: MappedKey] = [:]
    private var heldHid: [KeyIdentity: HidKey] = [:]
    private var buttons = Set<Int>()
    private var lastPoint = CGPoint.zero
    private var lastNorm = CGPoint(x: 0.5, y: 0.5)
    private var hasLastPoint = false
    private var pointerDeltaRemX = 0.0
    private var pointerDeltaRemY = 0.0
    private var flags: CGEventFlags = []
    private var scrollX = 0.0, scrollY = 0.0
    private var scrollActive = false
    private var lastClickTime = [Int: TimeInterval]()
    private var lastClickPoint = [Int: CGPoint]()
    private var clickCounts = [Int: Int64]()
    private var lastActivityTime = 0.0
    private var lastPointerTime = 0.0
    private var lastDisplayQueryTime = 0.0
    private var cachedDisplays: [CGRect] = []
    private var cachedBounds = CGRect.zero
    private var cachedLayouts: [Data] = []
    private var cachedKeyboardType: UInt32 = 0
    private var doubleClickInterval: TimeInterval = 0.5
    private var activityAssertion: IOPMAssertionID = 0

    // Active stylus / pen-display state
    private var tabletInProximity = false
    private var tabletToolType: Int64 = 1 // 1 = pen, 3 = eraser
    private var tabletDeviceID: Int64 = 1
    private var tabletPointerID: Int64 = 1
    private var tabletUniqueID: UInt64 = 0
    private var tabletCaps: UInt32 = 0
    private var tabletTipDown = false
    private var tabletBarrelButtons = Set<Int>() // 331 (BTN_STYLUS), 332 (BTN_STYLUS2)
    private var tabletPressure = 0.0
    private var tabletTiltX = 0.0 // degrees
    private var tabletTiltY = 0.0 // degrees
    private var tabletDistance = 0.0
    private var tabletRotation = 0.0
    private var tabletLastNormX = 0.5
    private var tabletLastNormY = 0.5

    // Multi-touch touchscreen state
    private var touchContacts: [Int: TouchContact] = [:]
    private var touchMode: TouchGestureMode = .idle
    private var touchScrollActive = false
    private var touchScrollLastPoint = CGPoint.zero
    private var touchScrollX = 0.0
    private var touchScrollY = 0.0
    private var touchLegacyDown = false
    private var longPressTimer: DispatchSourceTimer?

    init(displayID: CGDirectDisplayID, queue: DispatchQueue = .main) {
        bounds = { CGDisplayBounds(displayID) }
        displays = {
            var count: UInt32 = 0
            var list = [CGDirectDisplayID](repeating: 0, count: 16)
            CGGetActiveDisplayList(16, &list, &count)
            let rects = (0..<Int(count)).map { CGDisplayBounds(list[$0]) }.filter { !$0.isEmpty }
            return rects.isEmpty ? [CGDisplayBounds(displayID)] : rects
        }
        live = true
        now = { ProcessInfo.processInfo.systemUptime }
        timerQueue = queue
        if Thread.isMainThread {
            let snap = KeyMapping.snapshotKeyboardLayouts()
            cachedLayouts = snap.layouts
            cachedKeyboardType = snap.keyboardType
            doubleClickInterval = NSEvent.doubleClickInterval
        }
        source?.localEventsSuppressionInterval = 0
        keyboardSource?.localEventsSuppressionInterval = 0
        sink = { event in
            guard AXIsProcessTrusted() else { return }
            event.post(tap: .cghidEventTap)
        }
        keyboardSink = { event in
            guard AXIsProcessTrusted() else { return }
            event.post(tap: .cgSessionEventTap)
        }
        let client = VirtualKeyboardClient()
        client.start()
        virtualKeyboard = client
    }
    // Unit tests create CGEvents but never post, query a display or request TCC.
    init(bounds: @escaping () -> CGRect,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sink: @escaping Sink,
         virtualKeyboard: VirtualKeyboardBackend? = nil) {
        self.bounds = bounds
        self.displays = { [bounds()] }
        self.live = false
        self.now = now
        self.timerQueue = .main
        self.sink = sink
        self.keyboardSink = sink
        self.virtualKeyboard = virtualKeyboard
    }

    deinit {
        disarmLongPress()
        heldHid.removeAll()
        virtualKeyboard?.reset()
        virtualKeyboard?.stop()
    }

    var heldCount: Int {
        held.count + heldHid.count + buttons.count + (tabletTipDown ? 1 : 0) + tabletBarrelButtons.count + (touchLegacyDown ? 1 : 0)
    }

    func invalidateDisplayCache() {
        lastDisplayQueryTime = 0
    }

    private func refreshDisplayCache(now timestamp: TimeInterval) {
        if cachedBounds.isEmpty || cachedDisplays.isEmpty || timestamp - lastDisplayQueryTime >= 1.0 {
            lastDisplayQueryTime = timestamp
            cachedBounds = bounds()
            cachedDisplays = displays().filter { !$0.isEmpty }
        }
    }

    private func activeVirtualBounds() throws -> CGRect {
        if live { refreshDisplayCache(now: now()) }
        let rect = live && !cachedBounds.isEmpty ? cachedBounds : bounds()
        guard !rect.isEmpty else { throw SenderError("Virtual display is unavailable") }
        return rect
    }

    // Strict virtual-display coordinate mapping for direct touchscreens and
    // pen displays. Preserves sub-pixel precision and supports negative origins.
    private func displayPoint(x: Double, y: Double) throws -> CGPoint {
        let rect = try activeVirtualBounds()
        let clampedX = min(max(x, 0.0), 1.0)
        let clampedY = min(max(y, 0.0), 1.0)
        let maxX = max(rect.minX, rect.maxX - 0.001)
        let maxY = max(rect.minY, rect.maxY - 0.001)
        let px = min(max(rect.minX + clampedX * rect.width, rect.minX), maxX)
        let py = min(max(rect.minY + clampedY * rect.height, rect.minY), maxY)
        return CGPoint(x: px, y: py)
    }

    private func point(_ object: [String: Any]) throws -> CGPoint {
        let x = try Wire.number(object, "x", 0...1), y = try Wire.number(object, "y", 0...1)
        let rect = try activeVirtualBounds()
        return CGPoint(x: rect.minX + x * max(0, rect.width - 1), y: rect.minY + y * max(0, rect.height - 1))
    }

    private func projectToDisplays(_ target: CGPoint) -> CGPoint {
        refreshDisplayCache(now: now())
        let rects = cachedDisplays
        guard !rects.isEmpty else { return target }
        var best = target
        var bestDist = Double.infinity
        for r in rects {
            let cx = min(max(target.x, r.minX), r.maxX - 1)
            let cy = min(max(target.y, r.minY), r.maxY - 1)
            let d = hypot(target.x - cx, target.y - cy)
            if d < bestDist {
                bestDist = d
                best = CGPoint(x: cx, y: cy)
                if d == 0 { break }
            }
        }
        return best
    }

    private func hidModifierBitmap() -> UInt8 {
        var mask: UInt8 = 0
        for hid in heldHid.values {
            if case .modifier(let bit) = hid {
                mask |= bit
            }
        }
        return mask
    }

    private func hidKeyboardUsages() -> [UInt16] {
        var usages = Set<UInt16>()
        for hid in heldHid.values {
            if case .keyboard(let usage) = hid {
                usages.insert(usage)
            }
        }
        let sorted = usages.sorted()
        let limit = min(32, HidHelperIPC.maxKeys)
        return sorted.count > limit ? Array(sorted.prefix(limit)) : sorted
    }

    private func hidConsumerUsages() -> [UInt16] {
        var usages = Set<UInt16>()
        for hid in heldHid.values {
            if case .consumer(let usage) = hid {
                usages.insert(usage)
            }
        }
        let sorted = usages.sorted()
        let limit = min(32, HidHelperIPC.maxKeys)
        return sorted.count > limit ? Array(sorted.prefix(limit)) : sorted
    }

    private func hidSemanticFlags(from modifiers: UInt8) -> CGEventFlags {
        var result: CGEventFlags = []
        if modifiers & (0x02 | 0x20) != 0 { result.insert(.maskShift) }
        if modifiers & (0x01 | 0x10) != 0 { result.insert(.maskControl) }
        if modifiers & (0x04 | 0x40) != 0 { result.insert(.maskAlternate) }
        if modifiers & (0x08 | 0x80) != 0 { result.insert(.maskCommand) }
        return result
    }

    private func sendHidState(for changed: HidKey, via vk: VirtualKeyboardBackend) -> Bool {
        switch changed {
        case .modifier, .keyboard:
            return vk.sendKeyboardReport(modifiers: hidModifierBitmap(), keys: hidKeyboardUsages())
        case .consumer:
            return vk.sendConsumerReport(usages: hidConsumerUsages())
        }
    }

    private func deviceModifierFlags() -> CGEventFlags {
        var raw: UInt64 = 0
        for mapped in held.values {
            switch mapped.code {
            case 55: raw |= 0x08       // NX_DEVICELCMDKEYMASK
            case 54: raw |= 0x10       // NX_DEVICERCMDKEYMASK
            case 56: raw |= 0x02       // NX_DEVICELSHIFTKEYMASK
            case 60: raw |= 0x04       // NX_DEVICERSHIFTKEYMASK
            case 59: raw |= 0x01       // NX_DEVICELCTLKEYMASK
            case 62: raw |= 0x2000     // NX_DEVICERCTLKEYMASK
            case 58: raw |= 0x20       // NX_DEVICELALTKEYMASK
            case 61: raw |= 0x40       // NX_DEVICERALTKEYMASK
            default: break
            }
        }
        for hid in heldHid.values {
            if case .modifier(let bit) = hid {
                if bit & 0x01 != 0 { raw |= 0x01 }   // NX_DEVICELCTLKEYMASK
                if bit & 0x02 != 0 { raw |= 0x02 }   // NX_DEVICELSHIFTKEYMASK
                if bit & 0x04 != 0 { raw |= 0x20 }   // NX_DEVICELALTKEYMASK
                if bit & 0x08 != 0 { raw |= 0x08 }   // NX_DEVICELCMDKEYMASK
                if bit & 0x10 != 0 { raw |= 0x2000 } // NX_DEVICERCTLKEYMASK
                if bit & 0x20 != 0 { raw |= 0x04 }   // NX_DEVICERSHIFTKEYMASK
                if bit & 0x40 != 0 { raw |= 0x40 }   // NX_DEVICERALTKEYMASK
                if bit & 0x80 != 0 { raw |= 0x10 }   // NX_DEVICERCMDKEYMASK
            }
        }
        return CGEventFlags(rawValue: raw)
    }

    private func eventFlags(_ semantic: CGEventFlags, flagsChanged: Bool = false) -> CGEventFlags {
        let device = deviceModifierFlags()
        var result = semantic.union(device)
        let modifierFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift]
        if flagsChanged || !device.isEmpty || !semantic.intersection(modifierFlags).isEmpty {
            result.insert(CGEventFlags(rawValue: 0x100)) // NX_NONCOALESCEDMASK
        }
        return result
    }

    private func releaseFlags(for mapped: MappedKey, from before: CGEventFlags) -> CGEventFlags {
        guard !mapped.modifier.isEmpty else { return before }
        if held.values.contains(where: { $0.modifier.contains(mapped.modifier) })
            || !hidSemanticFlags(from: hidModifierBitmap()).intersection(mapped.modifier).isEmpty {
            return before.union(mapped.modifier)
        }
        return before.subtracting(mapped.modifier)
    }

    private func postKey(_ mapped: MappedKey, down: Bool, flags: CGEventFlags, repeatKey: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: keyboardSource, virtualKey: mapped.code, keyDown: down) else { return }
        let flagsChanged = KeyMapping.isModifier(mapped.code)
        if flagsChanged { event.type = .flagsChanged }
        let implicit = KeyMap.implicitKeyFlags(forMacKeyCode: mapped.code)
        event.flags = eventFlags(flags.union(implicit), flagsChanged: flagsChanged)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        if let text = mapped.text {
            let utf16 = Array(text.utf16)
            utf16.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
        }
        keyboardSink(event)
    }

    private func nextClickCount(for button: Int, at point: CGPoint, maxRadius: Double = 4) -> Int64 {
        let currentTime = now(), previous = lastClickPoint[button] ?? point
        let close = hypot(point.x - previous.x, point.y - previous.y) <= maxRadius
        let interval = live ? doubleClickInterval : NSEvent.doubleClickInterval
        let soon = currentTime - (lastClickTime[button] ?? -100) <= interval
        let count: Int64 = soon && close ? min(3, (clickCounts[button] ?? 0) + 1) : 1
        clickCounts[button] = count
        lastClickTime[button] = currentTime
        lastClickPoint[button] = point
        return count
    }

    private func mouse(_ button: Int, _ down: Bool, at point: CGPoint, cancelled: Bool = false, maxClickRadius: Double = 4) {
        let cgButton: CGMouseButton = button == 272 ? .left : button == 273 ? .right : .center
        let type: CGEventType = button == 272 ? (down ? .leftMouseDown : .leftMouseUp)
            : button == 273 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        let clickState: Int64
        if cancelled {
            clickState = 0
        } else if down {
            clickState = nextClickCount(for: button, at: point, maxRadius: maxClickRadius)
        } else {
            clickState = clickCounts[button] ?? 1
        }
        event.flags = eventFlags(flags)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        sink(event)
    }

    // MARK: - Active Stylus / Pen Display

    private static func uint64Value(_ object: [String: Any], _ name: String) throws -> UInt64 {
        guard let value = object[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else {
            throw SenderError("Invalid \(name)")
        }
        if value.doubleValue < 0 || !value.doubleValue.isFinite {
            throw SenderError("Invalid \(name)")
        }
        // Reject non-integer floating values when representable accurately in Double.
        if value.doubleValue < 9007199254740992.0 && value.doubleValue.rounded() != value.doubleValue {
            throw SenderError("Invalid \(name)")
        }
        return value.uint64Value
    }

    private static func uint32Value(_ object: [String: Any], _ name: String) throws -> UInt32 {
        let v = try uint64Value(object, name)
        guard v <= UInt64(UInt32.max) else { throw SenderError("Invalid \(name)") }
        return UInt32(v)
    }

    private func currentTabletButtonMask() -> Int {
        var mask = 0
        if tabletTipDown { mask |= 1 }
        if tabletBarrelButtons.contains(331) { mask |= 2 }
        if tabletBarrelButtons.contains(332) { mask |= 4 }
        return mask
    }

    private func tabletPointerType(for tool: String?) -> Int64 {
        tool == "eraser" ? 3 : 1
    }

    private func applyTabletFields(_ event: CGEvent, normX: Double, normY: Double, pressure: Double, buttons: Int) {
        let p = min(max(pressure, 0.0), 1.0)
        let nx = min(max(normX, 0.0), 1.0)
        let ny = min(max(normY, 0.0), 1.0)
        let tx = min(max(tabletTiltX / 60.0, -1.0), 1.0)
        let ty = min(max(tabletTiltY / 60.0, -1.0), 1.0)
        event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        event.setDoubleValueField(.mouseEventPressure, value: p)
        event.setDoubleValueField(.tabletEventPointPressure, value: p)
        event.setDoubleValueField(.tabletEventTiltX, value: tx)
        event.setDoubleValueField(.tabletEventTiltY, value: ty)
        event.setIntegerValueField(.tabletEventPointX, value: Int64((nx * 65535.0).rounded()))
        event.setIntegerValueField(.tabletEventPointY, value: Int64((ny * 65535.0).rounded()))
        event.setIntegerValueField(.tabletEventPointButtons, value: Int64(buttons))
        event.setIntegerValueField(.tabletEventDeviceID, value: tabletDeviceID)
        event.setDoubleValueField(.tabletEventRotation, value: tabletRotation)
        event.setIntegerValueField(.tabletEventPointZ, value: Int64((min(max(tabletDistance, 0.0), 1.0) * 65535.0).rounded()))
    }

    private static func quartzCapabilityMask(from receiverCaps: UInt32) -> Int64 {
        // Map receiver POINTER_TABLET_CAP_* bits to IOLLEvent.h NX_TABLET_CAPABILITY_*.
        var mask: Int64 = 0x0001 | 0x0002 | 0x0004 | 0x0040 // DEVICEID | ABSX | ABSY | BUTTONS
        if receiverCaps & (1 << 0) != 0 { mask |= 0x0400 }          // PRESSURE
        if receiverCaps & (1 << 1) != 0 { mask |= 0x0200 }          // ABSZ (distance)
        if receiverCaps & (1 << 2) != 0 { mask |= 0x0080 | 0x0100 } // TILTX | TILTY
        if receiverCaps & (1 << 3) != 0 { mask |= 0x2000 }          // ROTATION
        return mask
    }

    private func postTabletProximity(enter: Bool, at point: CGPoint) {
        guard let event = CGEvent(source: source) else { return }
        event.type = .tabletProximity
        event.location = point
        event.flags = eventFlags(flags)
        event.setIntegerValueField(.tabletProximityEventVendorID, value: 0x4C4F)
        event.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: tabletPointerID)
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: tabletDeviceID)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        event.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: Int64(bitPattern: tabletUniqueID))
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: Self.quartzCapabilityMask(from: tabletCaps))
        event.setIntegerValueField(.tabletProximityEventPointerType, value: tabletToolType)
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        sink(event)
    }

    private func postTabletMouse(_ type: CGEventType, button: CGMouseButton, at point: CGPoint,
                                 normX: Double, normY: Double, pressure: Double, buttons: Int,
                                 clickState: Int64? = nil) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = eventFlags(flags)
        if let clickState {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        applyTabletFields(event, normX: normX, normY: normY, pressure: pressure, buttons: buttons)
        sink(event)
    }

    private func releaseHeldTabletInputs(at point: CGPoint, cancelled: Bool) {
        if tabletTipDown {
            tabletTipDown = false
            tabletPressure = 0.0
            let mask = currentTabletButtonMask()
            postTabletMouse(.leftMouseUp, button: .left, at: point,
                            normX: tabletLastNormX, normY: tabletLastNormY,
                            pressure: 0.0, buttons: mask,
                            clickState: cancelled ? 0 : (clickCounts[272] ?? 1))
        }
        if tabletBarrelButtons.remove(331) != nil {
            let mask = currentTabletButtonMask()
            postTabletMouse(.rightMouseUp, button: .right, at: point,
                            normX: tabletLastNormX, normY: tabletLastNormY,
                            pressure: tabletPressure, buttons: mask,
                            clickState: cancelled ? 0 : (clickCounts[273] ?? 1))
        }
        if tabletBarrelButtons.remove(332) != nil {
            let mask = currentTabletButtonMask()
            postTabletMouse(.otherMouseUp, button: .center, at: point,
                            normX: tabletLastNormX, normY: tabletLastNormY,
                            pressure: tabletPressure, buttons: mask,
                            clickState: cancelled ? 0 : (clickCounts[274] ?? 1))
        }
    }

    private func handleTablet(_ object: [String: Any]) throws {
        guard let kind = object["event"] as? String else { throw SenderError("Missing tablet event") }
        let nx = object["x"] == nil ? tabletLastNormX : try Wire.number(object, "x", 0...1)
        let ny = object["y"] == nil ? tabletLastNormY : try Wire.number(object, "y", 0...1)
        let p = try displayPoint(x: nx, y: ny)
        tabletLastNormX = nx
        tabletLastNormY = ny

        switch kind {
        case "proximity":
            let entering = try Wire.boolean(object, "in")
            let tool = object["tool"] as? String
            let newToolType = tabletPointerType(for: tool)
            let newUniqueID = object["id"] == nil ? tabletUniqueID : try Self.uint64Value(object, "id")
            let newCaps = object["caps"] == nil ? tabletCaps : try Self.uint32Value(object, "caps")

            if entering {
                if tabletInProximity && (tabletToolType != newToolType || tabletUniqueID != newUniqueID) {
                    releaseHeldTabletInputs(at: p, cancelled: false)
                    postTabletProximity(enter: false, at: p)
                    tabletInProximity = false
                }
                tabletToolType = newToolType
                tabletPointerID = newToolType
                tabletUniqueID = newUniqueID
                tabletCaps = newCaps
                if !tabletInProximity {
                    tabletInProximity = true
                    postTabletProximity(enter: true, at: p)
                }
                lastPoint = p
                hasLastPoint = true
                postTabletMouse(.mouseMoved, button: .left, at: p,
                                normX: nx, normY: ny, pressure: tabletPressure,
                                buttons: currentTabletButtonMask())
            } else {
                releaseHeldTabletInputs(at: p, cancelled: false)
                if tabletInProximity {
                    postTabletProximity(enter: false, at: p)
                    tabletInProximity = false
                }
                tabletPressure = 0.0
                tabletTiltX = 0.0
                tabletTiltY = 0.0
                tabletDistance = 0.0
                tabletRotation = 0.0
                lastPoint = p
                hasLastPoint = true
            }

        case "axis":
            if object["pressure"] != nil { tabletPressure = try Wire.number(object, "pressure", 0...1) }
            if object["tiltX"] != nil { tabletTiltX = try Wire.number(object, "tiltX", -90...90) }
            if object["tiltY"] != nil { tabletTiltY = try Wire.number(object, "tiltY", -90...90) }
            if object["distance"] != nil { tabletDistance = try Wire.number(object, "distance", 0...1) }
            if object["rotation"] != nil { tabletRotation = try Wire.number(object, "rotation", -360...360) }
            let btnMask = object["buttons"] == nil ? currentTabletButtonMask() : try Wire.integer(object, "buttons", 0...15)
            let eventType: CGEventType
            let cgButton: CGMouseButton
            if tabletTipDown {
                eventType = .leftMouseDragged
                cgButton = .left
            } else if tabletBarrelButtons.contains(331) {
                eventType = .rightMouseDragged
                cgButton = .right
            } else if tabletBarrelButtons.contains(332) {
                eventType = .otherMouseDragged
                cgButton = .center
            } else {
                eventType = .mouseMoved
                cgButton = .left
            }
            lastPoint = p
            hasLastPoint = true
            postTabletMouse(eventType, button: cgButton, at: p,
                            normX: nx, normY: ny, pressure: tabletPressure, buttons: btnMask)

        case "tip":
            let down = try Wire.boolean(object, "down")
            if object["pressure"] != nil { tabletPressure = try Wire.number(object, "pressure", 0...1) }
            else if !down { tabletPressure = 0.0 }
            let btnMask: Int
            if object["buttons"] != nil {
                btnMask = try Wire.integer(object, "buttons", 0...15)
            } else {
                btnMask = (down ? 1 : 0) | (tabletBarrelButtons.contains(331) ? 2 : 0) | (tabletBarrelButtons.contains(332) ? 4 : 0)
            }
            lastPoint = p
            hasLastPoint = true
            if down {
                tabletTipDown = true
                let clicks = nextClickCount(for: 272, at: p, maxRadius: 8)
                postTabletMouse(.leftMouseDown, button: .left, at: p,
                                normX: nx, normY: ny, pressure: tabletPressure,
                                buttons: btnMask, clickState: clicks)
            } else {
                tabletTipDown = false
                let clicks = clickCounts[272] ?? 1
                postTabletMouse(.leftMouseUp, button: .left, at: p,
                                normX: nx, normY: ny, pressure: tabletPressure,
                                buttons: btnMask, clickState: clicks)
            }

        case "button":
            let code = Int(try Self.uint32Value(object, "button"))
            let state = try Wire.integer(object, "state", 0...1)
            let down = state == 1
            if object["pressure"] != nil { tabletPressure = try Wire.number(object, "pressure", 0...1) }
            let mappedButton: (mouseCode: Int, cgButton: CGMouseButton, downType: CGEventType, upType: CGEventType)?
            switch code {
            case 331: mappedButton = (273, .right, .rightMouseDown, .rightMouseUp)
            case 332: mappedButton = (274, .center, .otherMouseDown, .otherMouseUp)
            default: mappedButton = nil
            }
            guard let mapped = mappedButton else { return }
            let changed = down ? tabletBarrelButtons.insert(code).inserted : tabletBarrelButtons.remove(code) != nil
            guard changed else { return }
            let btnMask = object["buttons"] == nil ? currentTabletButtonMask() : try Wire.integer(object, "buttons", 0...15)
            lastPoint = p
            hasLastPoint = true
            let clicks = down ? nextClickCount(for: mapped.mouseCode, at: p, maxRadius: 8) : (clickCounts[mapped.mouseCode] ?? 1)
            postTabletMouse(down ? mapped.downType : mapped.upType, button: mapped.cgButton, at: p,
                            normX: nx, normY: ny, pressure: tabletPressure,
                            buttons: btnMask, clickState: clicks)

        default:
            throw SenderError("Invalid tablet event")
        }
    }

    // MARK: - Multi-Touch Touchscreen

    private static let tapMaxTravelMm = 4.0
    private static let dragMinTravelMm = 3.5
    private static let singleTapMaxDuration = 0.45
    private static let longPressDuration = 0.50
    private static let twoFingerTapMaxDuration = 0.30
    private static let pinchMinDeltaMm = 4.0
    private static let pinchMinRatioChange = 0.06
    private static let pinchStepRatio = 0.12
    private static let scrollMinTravelMm = 3.5

    private func armLongPress(for id: Int) {
        disarmLongPress()
        guard live else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + Self.longPressDuration)
        timer.setEventHandler { [weak self] in
            self?.tickLongPress()
        }
        timer.resume()
        longPressTimer = timer
    }

    private func disarmLongPress() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    // Evaluates whether a pending 1-finger hold has crossed the long-press
    // threshold. Invoked by the DispatchSourceTimer in live mode and directly
    // by deterministic unit tests with an injected clock.
    func tickLongPress() {
        guard case .singlePending(let id) = touchMode,
              let contact = touchContacts[id],
              touchContacts.count == 1 else {
            disarmLongPress()
            return
        }
        guard contact.maxTravelMm < Self.tapMaxTravelMm,
              now() - contact.startTime >= Self.longPressDuration else { return }
        disarmLongPress()
        guard let p = try? displayPoint(x: contact.startX, y: contact.startY) else { return }
        lastPoint = p
        hasLastPoint = true
        touchMode = .singleLongPressed(id: id)
        mouse(273, true, at: p, maxClickRadius: 16)
        mouse(273, false, at: p, maxClickRadius: 16)
    }

    private func endTouchScroll(cancelled: Bool) {
        guard touchScrollActive else { return }
        postScroll(wheelX: 0, wheelY: 0, pointX: 0, pointY: 0,
                   phase: cancelled ? 8 : 4, continuous: 1, at: touchScrollLastPoint)
        touchScrollActive = false
        touchScrollX = 0
        touchScrollY = 0
    }

    private func postZoomStep(zoomIn: Bool) {
        // US ANSI keycodes: 24 = Equal/Plus, 27 = Minus. Standard Command+/Command-
        // zoom works across Safari, Chrome, Preview, Finder, Freeform, Notes, Figma, VS Code.
        let code: CGKeyCode = zoomIn ? 24 : 27
        let zoomFlags = flags.union(.maskCommand)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
            down.flags = eventFlags(zoomFlags)
            sink(down)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
            up.flags = eventFlags(zoomFlags)
            sink(up)
        }
    }

    private func cancelTouch(fromTouchCancel: Bool) {
        disarmLongPress()
        if case .singleDragging = touchMode {
            mouse(272, false, at: lastPoint, cancelled: true)
        }
        endTouchScroll(cancelled: true)
        if touchLegacyDown {
            touchLegacyDown = false
            mouse(272, false, at: lastPoint, cancelled: true)
        }
        touchContacts.removeAll()
        touchMode = fromTouchCancel ? .idle : .idle
    }

    private func fallbackMm(x: Double, y: Double, rect: CGRect) -> (Double, Double) {
        // Fallback physical coordinates (assuming ~110 ppi logical points -> ~0.23 mm/pt)
        // when a frame omits xmm/ymm.
        return (x * rect.width * 0.23, y * rect.height * 0.23)
    }

    private func handleTouchFrame(_ object: [String: Any], scrollScale: Double) throws {
        guard let rawPoints = object["points"] as? [[String: Any]] else {
            throw SenderError("Missing touch points")
        }
        let rect = try activeVirtualBounds()
        let timestamp = now()
        var sawCancel = false
        var endedIDs: [Int] = []
        var endedSnapshots: [Int: TouchContact] = [:]

        for entry in rawPoints {
            let id = try Wire.integer(entry, "id", 0...Int(Int32.max))
            guard let state = entry["state"] as? String else { throw SenderError("Invalid touch point state") }
            switch state {
            case "cancel":
                sawCancel = true
            case "down":
                let x = try Wire.number(entry, "x", 0...1)
                let y = try Wire.number(entry, "y", 0...1)
                let fallback = fallbackMm(x: x, y: y, rect: rect)
                let xmm = entry["xmm"] == nil ? fallback.0 : try Wire.number(entry, "xmm", -10000...10000)
                let ymm = entry["ymm"] == nil ? fallback.1 : try Wire.number(entry, "ymm", -10000...10000)
                touchContacts[id] = TouchContact(
                    id: id, startX: x, startY: y, startXmm: xmm, startYmm: ymm,
                    startTime: timestamp, x: x, y: y, xmm: xmm, ymm: ymm, maxTravelMm: 0
                )
            case "move":
                let x = try Wire.number(entry, "x", 0...1)
                let y = try Wire.number(entry, "y", 0...1)
                let fallback = fallbackMm(x: x, y: y, rect: rect)
                let xmm = entry["xmm"] == nil ? fallback.0 : try Wire.number(entry, "xmm", -10000...10000)
                let ymm = entry["ymm"] == nil ? fallback.1 : try Wire.number(entry, "ymm", -10000...10000)
                if var contact = touchContacts[id] {
                    contact.x = x
                    contact.y = y
                    contact.xmm = xmm
                    contact.ymm = ymm
                    let travel = hypot(xmm - contact.startXmm, ymm - contact.startYmm)
                    if travel > contact.maxTravelMm { contact.maxTravelMm = travel }
                    touchContacts[id] = contact
                } else {
                    touchContacts[id] = TouchContact(
                        id: id, startX: x, startY: y, startXmm: xmm, startYmm: ymm,
                        startTime: timestamp, x: x, y: y, xmm: xmm, ymm: ymm, maxTravelMm: 0
                    )
                }
            case "up":
                if var contact = touchContacts.removeValue(forKey: id) {
                    if entry["x"] != nil && entry["y"] != nil {
                        let x = try Wire.number(entry, "x", 0...1)
                        let y = try Wire.number(entry, "y", 0...1)
                        let fallback = fallbackMm(x: x, y: y, rect: rect)
                        let xmm = entry["xmm"] == nil ? fallback.0 : try Wire.number(entry, "xmm", -10000...10000)
                        let ymm = entry["ymm"] == nil ? fallback.1 : try Wire.number(entry, "ymm", -10000...10000)
                        contact.x = x
                        contact.y = y
                        contact.xmm = xmm
                        contact.ymm = ymm
                        let travel = hypot(xmm - contact.startXmm, ymm - contact.startYmm)
                        if travel > contact.maxTravelMm { contact.maxTravelMm = travel }
                    }
                    endedIDs.append(id)
                    endedSnapshots[id] = contact
                }
            default:
                throw SenderError("Invalid touch point state")
            }
        }

        if sawCancel {
            cancelTouch(fromTouchCancel: true)
            return
        }

        let activeCount = touchContacts.count

        // Handle transitions out of active gestures when finger count changes.
        if activeCount >= 3 {
            disarmLongPress()
            if case .singleDragging = touchMode {
                mouse(272, false, at: lastPoint, cancelled: true)
            }
            endTouchScroll(cancelled: false)
            touchMode = .suppressed
            return
        }

        switch touchMode {
        case .idle:
            if activeCount == 1, let c = touchContacts.values.first {
                touchMode = .singlePending(id: c.id)
                armLongPress(for: c.id)
            } else if activeCount == 2 {
                enterTwoFingerPending(timestamp: timestamp)
            } else if activeCount == 0 && endedIDs.count == 1, let c = endedSnapshots[endedIDs[0]] {
                // Single-frame down+up tap
                if c.maxTravelMm < Self.tapMaxTravelMm && timestamp - c.startTime < Self.singleTapMaxDuration {
                    let p = try displayPoint(x: c.startX, y: c.startY)
                    lastPoint = p
                    hasLastPoint = true
                    mouse(272, true, at: p, maxClickRadius: 20)
                    mouse(272, false, at: p, maxClickRadius: 20)
                }
            }

        case .singlePending(let id):
            if activeCount == 2 {
                disarmLongPress()
                enterTwoFingerPending(timestamp: timestamp)
            } else if activeCount == 1, let c = touchContacts[id] {
                if c.maxTravelMm >= Self.dragMinTravelMm {
                    disarmLongPress()
                    let p0 = try displayPoint(x: c.startX, y: c.startY)
                    let p = try displayPoint(x: c.x, y: c.y)
                    touchMode = .singleDragging(id: id)
                    lastPoint = p0
                    hasLastPoint = true
                    mouse(272, true, at: p0, maxClickRadius: 20)
                    postTouchDrag(to: p)
                } else if timestamp - c.startTime >= Self.longPressDuration {
                    tickLongPress()
                }
            } else if activeCount == 0 {
                disarmLongPress()
                touchMode = .idle
                if let c = endedSnapshots[id] {
                    if c.maxTravelMm < Self.tapMaxTravelMm && timestamp - c.startTime < Self.singleTapMaxDuration {
                        let p = try displayPoint(x: c.startX, y: c.startY)
                        lastPoint = p
                        hasLastPoint = true
                        mouse(272, true, at: p, maxClickRadius: 20)
                        mouse(272, false, at: p, maxClickRadius: 20)
                    } else if c.maxTravelMm >= Self.dragMinTravelMm {
                        let p0 = try displayPoint(x: c.startX, y: c.startY)
                        let p = try displayPoint(x: c.x, y: c.y)
                        lastPoint = p0
                        hasLastPoint = true
                        mouse(272, true, at: p0, maxClickRadius: 20)
                        postTouchDrag(to: p)
                        mouse(272, false, at: p, maxClickRadius: 20)
                    }
                }
            } else {
                disarmLongPress()
                touchMode = .suppressed
            }

        case .singleDragging(let id):
            if let c = touchContacts[id] {
                if activeCount == 1 {
                    let p = try displayPoint(x: c.x, y: c.y)
                    postTouchDrag(to: p)
                } else {
                    // Second finger joined mid-drag: end drag cleanly, suppress until release.
                    let p = try displayPoint(x: c.x, y: c.y)
                    lastPoint = p
                    hasLastPoint = true
                    mouse(272, false, at: p, maxClickRadius: 20)
                    touchMode = .suppressed
                }
            } else {
                let endPoint: CGPoint
                if let c = endedSnapshots[id] {
                    endPoint = try displayPoint(x: c.x, y: c.y)
                } else {
                    endPoint = lastPoint
                }
                lastPoint = endPoint
                hasLastPoint = true
                mouse(272, false, at: endPoint, maxClickRadius: 20)
                touchMode = activeCount == 0 ? .idle : .suppressed
            }

        case .singleLongPressed:
            if activeCount == 0 {
                touchMode = .idle
            }

        case .twoPending(let id1, let id2, let startDistMm, let startMidX, let startMidY, let startTime):
            if activeCount == 2, let c1 = touchContacts[id1], let c2 = touchContacts[id2] {
                let distMm = hypot(c2.xmm - c1.xmm, c2.ymm - c1.ymm)
                let distDelta = abs(distMm - startDistMm)
                let ratioChange = startDistMm > 1.0 ? distDelta / startDistMm : 0.0
                let midXmm = (c1.xmm + c2.xmm) * 0.5
                let midYmm = (c1.ymm + c2.ymm) * 0.5
                let startMidXmm = (c1.startXmm + c2.startXmm) * 0.5
                let startMidYmm = (c1.startYmm + c2.startYmm) * 0.5
                let midTravelMm = hypot(midXmm - startMidXmm, midYmm - startMidYmm)
                let midNormX = (c1.x + c2.x) * 0.5
                let midNormY = (c1.y + c2.y) * 0.5
                let midPoint = try displayPoint(x: midNormX, y: midNormY)
                let startMidPoint = try displayPoint(x: startMidX, y: startMidY)

                let isPinch = distDelta >= Self.pinchMinDeltaMm && (startDistMm <= 1.0 || ratioChange >= Self.pinchMinRatioChange)
                if isPinch && distDelta >= midTravelMm {
                    let safeAnchor = max(startDistMm, 1.0)
                    let logScale = log(max(distMm, 1.0) / safeAnchor)
                    let stepLog = log(1.0 + Self.pinchStepRatio)
                    var accum = logScale / stepLog
                    while accum >= 1.0 {
                        postZoomStep(zoomIn: true)
                        accum -= 1.0
                    }
                    while accum <= -1.0 {
                        postZoomStep(zoomIn: false)
                        accum += 1.0
                    }
                    touchMode = .twoPinching(anchorDistMm: max(distMm, 1.0), zoomStepAccum: accum)
                } else if midTravelMm >= Self.scrollMinTravelMm {
                    lastPoint = startMidPoint
                    hasLastPoint = true
                    if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: startMidPoint, mouseButton: .left) {
                        move.flags = eventFlags(flags)
                        sink(move)
                    }
                    touchScrollActive = true
                    touchScrollLastPoint = startMidPoint
                    touchScrollX = 0
                    touchScrollY = 0
                    postScroll(wheelX: 0, wheelY: 0, pointX: 0, pointY: 0, phase: 1, continuous: 1, at: startMidPoint)
                    emitTouchScrollDelta(from: startMidPoint, to: midPoint, scrollScale: scrollScale)
                    touchMode = .twoScrolling(lastMidPoint: midPoint)
                }
            } else {
                // One or both fingers lifted while in twoPending.
                let c1 = touchContacts[id1] ?? endedSnapshots[id1]
                let c2 = touchContacts[id2] ?? endedSnapshots[id2]
                let withinTravel = (c1?.maxTravelMm ?? 0) < Self.tapMaxTravelMm && (c2?.maxTravelMm ?? 0) < Self.tapMaxTravelMm
                let withinDuration = timestamp - startTime < Self.twoFingerTapMaxDuration
                if withinTravel && withinDuration {
                    let midPoint = try displayPoint(x: startMidX, y: startMidY)
                    lastPoint = midPoint
                    hasLastPoint = true
                    mouse(273, true, at: midPoint, maxClickRadius: 20)
                    mouse(273, false, at: midPoint, maxClickRadius: 20)
                }
                touchMode = activeCount == 0 ? .idle : .suppressed
            }

        case .twoScrolling(let lastMidPoint):
            if activeCount == 2 {
                let pts = Array(touchContacts.values)
                let midPoint = try displayPoint(x: (pts[0].x + pts[1].x) * 0.5, y: (pts[0].y + pts[1].y) * 0.5)
                emitTouchScrollDelta(from: lastMidPoint, to: midPoint, scrollScale: scrollScale)
                touchMode = .twoScrolling(lastMidPoint: midPoint)
            } else {
                endTouchScroll(cancelled: false)
                touchMode = activeCount == 0 ? .idle : .suppressed
            }

        case .twoPinching(let anchorDistMm, var accum):
            if activeCount == 2 {
                let pts = Array(touchContacts.values)
                let distMm = max(hypot(pts[1].xmm - pts[0].xmm, pts[1].ymm - pts[0].ymm), 1.0)
                let stepLog = log(1.0 + Self.pinchStepRatio)
                accum += log(distMm / max(anchorDistMm, 1.0)) / stepLog
                while accum >= 1.0 {
                    postZoomStep(zoomIn: true)
                    accum -= 1.0
                }
                while accum <= -1.0 {
                    postZoomStep(zoomIn: false)
                    accum += 1.0
                }
                touchMode = .twoPinching(anchorDistMm: distMm, zoomStepAccum: accum)
            } else {
                touchMode = activeCount == 0 ? .idle : .suppressed
            }

        case .suppressed:
            if activeCount == 0 {
                touchMode = .idle
            }
        }
    }

    private func enterTwoFingerPending(timestamp: TimeInterval) {
        let sorted = touchContacts.values.sorted { $0.id < $1.id }
        guard sorted.count == 2 else { touchMode = .suppressed; return }
        let c1 = sorted[0], c2 = sorted[1]
        let distMm = hypot(c2.xmm - c1.xmm, c2.ymm - c1.ymm)
        let midX = (c1.x + c2.x) * 0.5
        let midY = (c1.y + c2.y) * 0.5
        let startTime = min(c1.startTime, c2.startTime)
        touchMode = .twoPending(id1: c1.id, id2: c2.id, startDistMm: distMm, startMidX: midX, startMidY: midY, startTime: min(startTime, timestamp))
    }

    private func postTouchDrag(to point: CGPoint) {
        let dx = point.x - lastPoint.x
        let dy = point.y - lastPoint.y
        lastPoint = point
        hasLastPoint = true
        if let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
            event.flags = eventFlags(flags)
            sink(event)
        }
    }

    private func emitTouchScrollDelta(from previous: CGPoint, to current: CGPoint, scrollScale: Double) {
        let scale = (scrollScale.isFinite && scrollScale > 0 && scrollScale <= 4) ? scrollScale : 1.0
        // Natural direction: dragging fingers up (negative dy) pushes content up (negative scroll delta in pixel coords -> wait:
        // on macOS CGEvent scrollWheel with pixel units, positive wheel1/pointDeltaAxis1 scrolls content down / moves viewport up,
        // matching dragging fingers downward -> positive dy).
        let dx = (current.x - previous.x) * scale
        let dy = (current.y - previous.y) * scale
        touchScrollLastPoint = current
        lastPoint = current
        hasLastPoint = true
        touchScrollX += dx
        touchScrollY += dy
        let ix = touchScrollX.rounded(.towardZero)
        let iy = touchScrollY.rounded(.towardZero)
        touchScrollX -= ix
        touchScrollY -= iy
        if dx != 0 || dy != 0 {
            postScroll(wheelX: Int32(ix), wheelY: Int32(iy), pointX: dx, pointY: dy, phase: 2, continuous: 1, at: current)
        }
    }

    // MARK: - Dispatch

    func handle(_ object: [String: Any], scrollScale: Double = 1) throws {
        guard let type = object["type"] as? String else { throw SenderError("Missing input type") }
        if live {
            let currentTime = now()
            if currentTime - lastActivityTime >= 1.0 {
                lastActivityTime = currentTime
                IOPMAssertionDeclareUserActivity("LOCachy Remote Input" as CFString, kIOPMUserActiveLocal, &activityAssertion)
            }
        }
        switch type {
        case "key":
            let identity = KeyIdentity(device: try Wire.integer(object, "device", 1...Int(UInt32.max)), code: try Wire.integer(object, "code", 0...767))
            let state = try Wire.integer(object, "state", 0...2)
            let modifiers = try Wire.integer(object, "modifiers", 0...127), locks = try Wire.integer(object, "locks", 0...3)
            let mapping = object["mapping"] as? String
            guard mapping == "logical" || mapping == "physical" else { throw SenderError("Unsupported keyboard mapping") }
            // The wire reports the state before the event. Apply the key's
            // own transition on top of it for flagsChanged events.
            let before = KeyMapping.flags(modifiers, locks)
            if state == 0 {
                if let releasedHid = heldHid.removeValue(forKey: identity) {
                    if let vk = virtualKeyboard {
                        if !sendHidState(for: releasedHid, via: vk) {
                            heldHid.removeAll()
                            vk.reset()
                        }
                    } else {
                        heldHid.removeAll()
                    }
                    let removedModFlags: CGEventFlags = {
                        if case .modifier(let bit) = releasedHid { return hidSemanticFlags(from: bit) }
                        return []
                    }()
                    let activeMods = hidSemanticFlags(from: hidModifierBitmap())
                        .union(held.values.reduce(CGEventFlags()) { $0.union($1.modifier) })
                    flags = before.subtracting(removedModFlags).union(activeMods)
                    return
                }
                guard let mapped = held.removeValue(forKey: identity) else { return }
                flags = releaseFlags(for: mapped, from: before)
                // Multiple physical keyboards may hold the same logical key.
                if !held.values.contains(where: { $0.code == mapped.code && $0.text == mapped.text }) {
                    postKey(mapped, down: false, flags: flags)
                }
            } else if state == 2 {
                if heldHid[identity] != nil {
                    // macOS natively handles key repeat for held virtual USB HID keys.
                    return
                }
                guard let mapped = held[identity], !KeyMapping.isModifier(mapped.code) else { return }
                flags = before
                postKey(mapped, down: true, flags: before.union(mapped.layoutFlags), repeatKey: true)
            } else {
                if let prevHid = heldHid.removeValue(forKey: identity) {
                    if let vk = virtualKeyboard, !sendHidState(for: prevHid, via: vk) {
                        heldHid.removeAll()
                        vk.reset()
                    }
                }
                if let prev = held.removeValue(forKey: identity) {
                    postKey(prev, down: false, flags: releaseFlags(for: prev, from: before))
                }
                guard held.count + heldHid.count < 128 else { throw SenderError("Too many held keys") }
                let sym: UInt32
                if mapping == "physical" && object["keysym"] == nil {
                    sym = 0
                } else {
                    sym = UInt32(try Wire.integer(object, "keysym", 0...Int(UInt32.max)))
                }
                if let vk = virtualKeyboard, vk.isReady, let hid = KeyMap.hidKey(forEvdev: identity.code) {
                    heldHid[identity] = hid
                    if sendHidState(for: hid, via: vk) {
                        let activeMods = hidSemanticFlags(from: hidModifierBitmap())
                            .union(held.values.reduce(CGEventFlags()) { $0.union($1.modifier) })
                        if case .keyboard(0x39) = hid {
                            flags = before.symmetricDifference(.maskAlphaShift).union(activeMods)
                        } else {
                            flags = before.union(activeMods)
                        }
                        return
                    }
                    heldHid.removeAll()
                    vk.reset()
                }
                var mapped: MappedKey
                if identity.code > 0, (sym != 0 || mapping == "physical"),
                   let macCode = KeyMap.macKeyCode(forEvdev: identity.code) {
                    mapped = MappedKey(
                        code: macCode,
                        text: nil,
                        flags: before,
                        layoutFlags: [],
                        modifier: KeyMap.modifierFlag(forMacKeyCode: macCode)
                    )
                } else {
                    if sym == 0 { return }
                    mapped = try KeyMapping.logical(
                        sym, flags: before,
                        cachedLayouts: cachedLayouts.isEmpty ? nil : cachedLayouts,
                        keyboardType: cachedLayouts.isEmpty ? nil : cachedKeyboardType)
                    mapped.modifier = KeyMapping.modifierBit(sym)
                }
                held[identity] = mapped
                flags = before.union(mapped.modifier)
                if mapped.code == 57 { // Caps Lock toggles only on its press.
                    flags.formSymmetricDifference(.maskAlphaShift)
                    postKey(mapped, down: true, flags: flags)
                } else {
                    postKey(mapped, down: true, flags: mapped.flags.union(mapped.modifier))
                }
            }
        case "pointer":
            let mapped = try point(object)
            let x = try Wire.number(object, "x", 0...1), y = try Wire.number(object, "y", 0...1)
            let currentTime = now()
            let syncCursor = !hasLastPoint || (live && currentTime - lastPointerTime > 0.3)
            lastPointerTime = currentTime
            if syncCursor {
                pointerDeltaRemX = 0.0
                pointerDeltaRemY = 0.0
            }
            var dx = 0.0, dy = 0.0
            if object["dx"] != nil || object["dy"] != nil {
                dx = object["dx"] == nil ? 0 : try Wire.number(object, "dx", -16384...16384)
                dy = object["dy"] == nil ? 0 : try Wire.number(object, "dy", -16384...16384)
                if syncCursor {
                    hasLastPoint = true
                    lastPoint = live ? (CGEvent(source: nil)?.location ?? mapped) : mapped
                }
                lastPoint = projectToDisplays(CGPoint(x: lastPoint.x + dx, y: lastPoint.y + dy))
                lastNorm = CGPoint(x: x, y: y)
            } else if !hasLastPoint {
                hasLastPoint = true
                lastNorm = CGPoint(x: x, y: y)
                lastPoint = live ? (CGEvent(source: nil)?.location ?? mapped) : mapped
            } else {
                if syncCursor, let cur = CGEvent(source: nil)?.location {
                    lastPoint = cur
                }
                let rect = !cachedBounds.isEmpty ? cachedBounds : bounds()
                let refW = max(1440.0, Double(rect.width)), refH = max(960.0, Double(rect.height))
                dx = (x - lastNorm.x) * refW
                dy = (y - lastNorm.y) * refH
                if x <= 0.0005 && lastNorm.x <= 0.0005 { dx = -18.0 }
                else if x >= 0.9995 && lastNorm.x >= 0.9995 { dx = 18.0 }
                if y <= 0.0005 && lastNorm.y <= 0.0005 { dy = -18.0 }
                else if y >= 0.9995 && lastNorm.y >= 0.9995 { dy = 18.0 }
                lastNorm = CGPoint(x: x, y: y)
                lastPoint = projectToDisplays(CGPoint(x: lastPoint.x + dx, y: lastPoint.y + dy))
            }
            pointerDeltaRemX += dx
            pointerDeltaRemY += dy
            let intDx = Int64(pointerDeltaRemX.rounded())
            let intDy = Int64(pointerDeltaRemY.rounded())
            pointerDeltaRemX -= Double(intDx)
            pointerDeltaRemY -= Double(intDy)
            let button = buttons.contains(272) ? 272 : buttons.contains(273) ? 273 : 274
            let cgButton: CGMouseButton = button == 272 ? .left : button == 273 ? .right : .center
            let eventType: CGEventType = buttons.isEmpty ? .mouseMoved : button == 272 ? .leftMouseDragged : button == 273 ? .rightMouseDragged : .otherMouseDragged
            if let event = CGEvent(mouseEventSource: source, mouseType: eventType, mouseCursorPosition: lastPoint, mouseButton: cgButton) {
                event.setIntegerValueField(.mouseEventDeltaX, value: intDx)
                event.setIntegerValueField(.mouseEventDeltaY, value: intDy)
                event.flags = eventFlags(flags); sink(event)
            }
        case "button":
            let button = try Wire.integer(object, "button", 272...274), down = try Wire.integer(object, "state", 0...1) == 1
            let mapped = try point(object)
            if !hasLastPoint {
                hasLastPoint = true
                lastPoint = live ? (CGEvent(source: nil)?.location ?? mapped) : mapped
            } else if live, let current = CGEvent(source: nil)?.location {
                lastPoint = current
            }
            if down ? buttons.insert(button).inserted : buttons.remove(button) != nil { mouse(button, down, at: lastPoint) }
        case "tablet":
            try handleTablet(object)
        case "touch":
            let phase = object["phase"] as? String
            if phase == "frame" {
                try handleTouchFrame(object, scrollScale: scrollScale)
                return
            }
            guard ["began", "moved", "ended", "cancelled"].contains(phase ?? "") else { throw SenderError("Invalid touch phase") }
            let nx = try Wire.number(object, "x", 0...1), ny = try Wire.number(object, "y", 0...1)
            let p = try displayPoint(x: nx, y: ny)
            if phase == "began" {
                lastPoint = p
                hasLastPoint = true
                if !touchLegacyDown {
                    touchLegacyDown = true
                    mouse(272, true, at: p)
                }
            } else if phase == "moved" {
                if touchLegacyDown {
                    postTouchDrag(to: p)
                } else {
                    lastPoint = p
                    hasLastPoint = true
                    if let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
                        event.flags = eventFlags(flags)
                        sink(event)
                    }
                }
            } else {
                lastPoint = p
                hasLastPoint = true
                if touchLegacyDown {
                    touchLegacyDown = false
                    mouse(272, false, at: p, cancelled: phase == "cancelled")
                }
            }
        case "scroll":
            guard scrollScale.isFinite, scrollScale > 0, scrollScale <= 4 else { throw SenderError("Invalid scroll scale") }
            // Receiver phase: 0 none (discrete), 1 begin, 2 update, 3 end,
            // 4 cancel. Absent phase/source is upstream OpenDisplay's plain
            // discrete scroll. Mapped explicitly to CGScrollPhase bits.
            let phase = object["phase"] == nil ? 0 : try Wire.integer(object, "phase", 0...4)
            let origin = object["source"] == nil ? 0 : try Wire.integer(object, "source", 0...4)
            let rawX = try Wire.number(object, "dx", -16384...16384)
            let rawY = try Wire.number(object, "dy", -16384...16384)
            guard [1, 3, 4].contains(phase) ? (rawX == 0 && rawY == 0) : true else {
                throw SenderError("Scroll begin/end/cancel must carry zero deltas")
            }
            // The receiver sends wheel steps (source 1) as phase 2 with deltas
            // and never brackets them with begin/end. A wheel step is a plain
            // non-continuous wheel event with no gesture phase; a gesture phase
            // without a begin would look like a broken trackpad gesture.
            let wheel = origin == 1
            if wheel && phase != 0 && phase != 2 {
                throw SenderError("A wheel step carries no gesture begin, end or cancel")
            }
            let cgPhase: Int64 = wheel ? 0 : [0: 0, 1: 1, 2: 2, 3: 4, 4: 8][phase]!
            let continuous: Int64 = wheel || (phase == 0 && origin == 0) ? 0 : 1
            let rect = try activeVirtualBounds()
            guard rect.width > 0 else { throw SenderError("Virtual display is unavailable") }
            let dx = rawX * scrollScale, dy = rawY * scrollScale
            scrollX += dx; scrollY += dy
            let x = scrollX.rounded(.towardZero), y = scrollY.rounded(.towardZero)
            scrollX -= x; scrollY -= y
            postScroll(wheelX: Int32(x), wheelY: Int32(y), pointX: dx, pointY: dy, phase: cgPhase, continuous: continuous)
            if !wheel && phase == 1 { scrollActive = true }
            if phase == 3 || phase == 4 { scrollActive = false; scrollX = 0; scrollY = 0 }
        case "cancel":
            guard object["scope"] as? String == "all" else { throw SenderError("Invalid cancel scope") }
            cancel()
        default: break
        }
    }

    private func postScroll(wheelX: Int32, wheelY: Int32, pointX: Double, pointY: Double,
                            phase: Int64, continuous: Int64, at location: CGPoint? = nil) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: wheelY, wheel2: wheelX, wheel3: 0) else { return }
        if let location {
            event.location = location
        }
        event.flags = eventFlags(flags)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: pointY)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: pointX)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        sink(event)
    }

    func cancel() {
        // End an open scroll gesture first so the target does not keep a
        // phantom trackpad gesture alive after focus loss or teardown.
        if scrollActive { postScroll(wheelX: 0, wheelY: 0, pointX: 0, pointY: 0, phase: 8, continuous: 1) }
        scrollActive = false
        cancelTouch(fromTouchCancel: false)
        releaseHeldTabletInputs(at: lastPoint, cancelled: true)
        if tabletInProximity {
            postTabletProximity(enter: false, at: lastPoint)
            tabletInProximity = false
        }
        tabletPressure = 0.0
        tabletTiltX = 0.0
        tabletTiltY = 0.0
        tabletDistance = 0.0
        tabletRotation = 0.0
        flags = []
        heldHid.removeAll()
        virtualKeyboard?.reset()
        let cancelledKeys = held
        held.removeAll()
        var released = Set<CGKeyCode>()
        for mapped in cancelledKeys.values where released.insert(mapped.code).inserted {
            postKey(mapped, down: false, flags: [])
        }
        for button in buttons { mouse(button, false, at: lastPoint, cancelled: true) }
        buttons.removeAll()
        scrollX = 0; scrollY = 0
        pointerDeltaRemX = 0.0; pointerDeltaRemY = 0.0
    }
}
