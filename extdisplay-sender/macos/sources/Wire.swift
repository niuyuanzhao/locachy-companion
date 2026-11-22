// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreFoundation

struct SenderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// OpenDisplay pv3 framing with a mandatory authenticated LOCachy v1 profile.
// Discovery is separate and unauthenticated. No mirror fallback, clipboard,
// file transfer, or power commands exist in the authenticated stream.
enum Wire {
    static let maxFrame = 4 * 1024 * 1024
    static let maxControl = 32767
    static let identity = "locachy-extdisplay-v1"
    // TLS_PSK_WITH_AES_128_GCM_SHA256: the only PSK suite Network.framework negotiates.
    static let pskSuite: UInt16 = 0x00A8
    static let alpn = "locachy-extdisplay-v1"
    static let capabilities = ["key", "button", "cancel", "pointer", "scroll"]
    static let optionalCapabilities = ["touch", "tablet"]

    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maxFrame else { throw SenderError("Invalid frame size") }
        var size = UInt32(payload.count).bigEndian
        var result = Data(bytes: &size, count: 4)
        result.append(payload)
        return result
    }
    static func json(_ object: [String: Any]) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard bytes.count <= maxControl else { throw SenderError("Control message too large") }
        return bytes
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maxControl, data.first == 123,
              !data.contains(0), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] is String else { throw SenderError("Invalid control message") }
        return object
    }
    static func integer(_ object: [String: Any], _ name: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let value = object[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
              value.doubleValue >= Double(range.lowerBound), value.doubleValue <= Double(range.upperBound)
        else { throw SenderError("Invalid \(name)") }
        return value.intValue
    }
    static func number(_ object: [String: Any], _ name: String, _ range: ClosedRange<Double>) throws -> Double {
        guard let value = object[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, range.contains(value.doubleValue)
        else { throw SenderError("Invalid \(name)") }
        return value.doubleValue
    }
    static func boolean(_ object: [String: Any], _ name: String) throws -> Bool {
        guard let value = object[name] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID()
        else { throw SenderError("Invalid \(name)") }
        return value.boolValue
    }
}

struct Panel: Equatable {
    // H.264 High level 5.2: 2,073,600 macroblocks per second (MaxMBPS).
    static let maxMacroblocksPerSecond = 2_073_600

    static func h264SafeRate(width: Int, height: Int, requested: Int) -> Int {
        let macroblocks = max(1, ((width + 15) / 16) * ((height + 15) / 16))
        let levelRate = maxMacroblocksPerSecond / macroblocks
        guard levelRate < requested else { return requested }
        // One frame of headroom below the nominal limit, as the level allows.
        return max(1, levelRate - 1)
    }

    let width: Int
    let height: Int
    let scale: Int
    let fps: Int
    let codec: String
    let supportedInput: Set<String>
    let deviceName: String
    let hostName: String
    let machineModel: String

    var streamCodec: String {
        codec.hasPrefix("hevc") ? "hevc" : "h264"
    }

    var identityKey: String {
        if !hostName.isEmpty || !machineModel.isEmpty {
            return "host=\(hostName)|model=\(machineModel)|panel=\(width)x\(height)"
        }
        return "device=\(deviceName)|panel=\(width)x\(height)"
    }

    private static func sanitizeLabel(_ raw: String?) -> String {
        guard let raw else { return "" }
        var out = ""
        var prevSpace = false
        for scalar in raw.unicodeScalars {
            guard scalar.value >= 0x20, scalar.value <= 0x7e, scalar != "|", scalar != "\"", scalar != "\\" else { continue }
            if scalar == " " {
                if !out.isEmpty && !prevSpace { out.append(" "); prevSpace = true }
            } else {
                out.append(Character(scalar))
                prevSpace = false
            }
            if out.count >= 64 { break }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    init(hello: [String: Any]) throws {
        guard hello["type"] as? String == "hello", try Wire.integer(hello, "locachy", 1...1) == 1,
              try Wire.integer(hello, "pv", 3...3) == 3,
              try Wire.boolean(hello, "extendedOnly"),
              let input = hello["input"] as? [String], Set(Wire.capabilities).isSubset(of: Set(input)),
              let caps = hello["videoCaps"] as? [[String: Any]], !caps.isEmpty, caps.count <= 16
        else { throw SenderError("Receiver does not support the authenticated extended-display profile") }
        supportedInput = Set(input)
        let device = Self.sanitizeLabel(hello["device"] as? String)
        deviceName = device.isEmpty ? "LOCachy" : device
        hostName = Self.sanitizeLabel(hello["host"] as? String)
        machineModel = Self.sanitizeLabel(hello["model"] as? String)
        let panel = hello["panel"] as? [String: Any] ?? hello
        width = try Wire.integer(panel, panel["width"] == nil ? "pixelsWide" : "width", 64...4096)
        height = try Wire.integer(panel, panel["height"] == nil ? "pixelsHigh" : "height", 64...4096)
        _ = try Wire.number(panel, "scale", 0.5...4)
        // Enable HiDPI (@2x) for any mainstream panel resolution; Capture.swift's
        // Metal bicubic scaler handles arbitrary ratios cleanly.
        scale = (max(width, height) >= 640 && min(width, height) >= 480) ? 2 : 1
        // VirtualCanvasSizing rounds to even points; capture verifies the
        // resulting mode and the receiver reads the real size from the SPS.
        guard width * height <= 16 * 1024 * 1024 else { throw SenderError("Panel is too large") }
        // The receiver always sends displayMaxFrameRate, but absence means the
        // legacy 60 Hz contract. H.264 level 5.2 caps macroblocks per second,
        // so only H.264 lowers its rate via Panel.h264SafeRate.
        let requestedRate = hello["displayMaxFrameRate"] == nil ? 60
            : try Wire.integer(hello, "displayMaxFrameRate", 1...120)
        let panelW = width, panelH = height
        let baseFps = min(60, requestedRate)
        let priority = ["hevc444", "hevc", "hevc420", "h264"]
        var negotiatedCodec: String?
        var negotiatedFps = baseFps
        for candidate in priority {
            let candidateFps = candidate == "h264"
                ? Panel.h264SafeRate(width: panelW, height: panelH, requested: baseFps)
                : baseFps
            let covered = caps.contains { capability in
                guard capability["codec"] as? String == candidate else { return false }
                for (key, required) in [("maxWidth", panelW), ("maxHeight", panelH),
                                        ("maxFramesPerSecond", candidateFps), ("maxFrameRate", candidateFps)] {
                    if capability[key] != nil {
                        guard let maximum = try? Wire.integer(capability, key, 1...Int.max),
                              maximum >= required else { return false }
                    }
                }
                return true
            }
            if covered {
                negotiatedCodec = candidate
                negotiatedFps = candidateFps
                break
            }
        }
        guard let selectedCodec = negotiatedCodec else {
            let offered = caps.compactMap { $0["codec"] as? String }
            if offered.contains(where: { priority.contains($0) }) {
                throw SenderError("Panel exceeds the offered decoder envelope")
            }
            throw SenderError("Receiver does not offer a supported video codec")
        }
        codec = selectedCodec
        fps = negotiatedFps
    }
}

// A bounded incremental reader. Failure poisons the stream; no resynchronizing
// through attacker-controlled bytes after a malformed length or truncated EOF.
struct FrameReader {
    private var bytes = Data()
    private var failed = false
    mutating func feed(_ chunk: Data, receive: (Data) throws -> Void) throws {
        guard !failed else { throw SenderError("Poisoned frame stream") }
        do {
            // Network reads are capped at 64 KiB. Process between appends so a
            // peer cannot inflate the accumulator with concatenated frames.
            guard chunk.count <= 65536 else { throw SenderError("Read chunk too large") }
            bytes.append(chunk)
            while bytes.count >= 4 {
                let size = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard size > 0, size <= Wire.maxControl else { throw SenderError("Invalid control frame length") }
                guard bytes.count >= size + 4 else { break }
                let payload = Data(bytes.dropFirst(4).prefix(size))
                bytes.removeFirst(size + 4)
                try receive(payload)
            }
            guard bytes.count <= Wire.maxControl + 4 else { throw SenderError("Control buffer overflow") }
        } catch { failed = true; bytes.removeAll(); throw error }
    }
    func finish() throws {
        guard !failed, bytes.isEmpty else { throw SenderError("Truncated control frame") }
    }
}

// Encodes H.264 AVCC samples as complete Annex-B access units. Keyframes carry
// SPS/PPS. No telemetry prefix: the frozen LOCachy receiver requires 00000001.
enum AnnexB {
    static let start: [UInt8] = [0, 0, 0, 1]
    static func fromAVCC(_ bytes: UnsafeRawBufferPointer, parameterSets: [Data]) -> Data? {
        var output = Data(capacity: bytes.count + parameterSets.reduce(0) { $0 + $1.count + 4 })
        for set in parameterSets where !set.isEmpty { output.append(contentsOf: start); output.append(set) }
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 4 else { return nil }
            let size = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard size > 0, size <= bytes.count - offset else { return nil }
            output.append(contentsOf: start)
            output.append(contentsOf: bytes[offset..<(offset + size)])
            offset += size
        }
        return output.starts(with: start) && output.count <= Wire.maxFrame ? output : nil
    }
}
