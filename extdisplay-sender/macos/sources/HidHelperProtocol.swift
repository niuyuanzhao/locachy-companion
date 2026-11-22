// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum HidHelperState: UInt8, Equatable {
    case unavailable = 0
    case ready = 1
    case driverNotActivated = 2
    case versionMismatched = 3
}

struct HidHelperStatus: Equatable {
    let state: HidHelperState
    let detail: UInt8
}

enum HidHelperCommand: Equatable {
    case keyboardReport(modifiers: UInt8, keys: [UInt16])
    case consumerReport(usages: [UInt16])
    case reset
    case ping
}

enum HidHelperIPC {
    static let defaultSocketPath = "/var/run/locachy-hid-helper.sock"
    static let maxKeys = 32
    static let maxPayloadLength = 128

    private static let cmdKeyboardReport: UInt8 = 0x01
    private static let cmdConsumerReport: UInt8 = 0x02
    private static let cmdReset: UInt8 = 0x03
    private static let cmdPing: UInt8 = 0x04
    private static let msgStatus: UInt8 = 0x81

    static func encodeCommand(_ command: HidHelperCommand) -> Data {
        var payload = Data()
        switch command {
        case let .keyboardReport(modifiers, keys):
            let count = min(keys.count, maxKeys)
            payload.reserveCapacity(3 + count * 2)
            payload.append(cmdKeyboardReport)
            payload.append(modifiers)
            payload.append(UInt8(count))
            for i in 0..<count {
                let k = keys[i]
                payload.append(UInt8(k & 0xff))
                payload.append(UInt8((k >> 8) & 0xff))
            }
        case let .consumerReport(usages):
            let count = min(usages.count, maxKeys)
            payload.reserveCapacity(2 + count * 2)
            payload.append(cmdConsumerReport)
            payload.append(UInt8(count))
            for i in 0..<count {
                let u = usages[i]
                payload.append(UInt8(u & 0xff))
                payload.append(UInt8((u >> 8) & 0xff))
            }
        case .reset:
            payload.append(cmdReset)
        case .ping:
            payload.append(cmdPing)
        }
        return framePayload(payload)
    }

    static func decodeCommand(_ payload: Data) -> HidHelperCommand? {
        guard !payload.isEmpty, payload.count <= maxPayloadLength else { return nil }
        return payload.withUnsafeBytes { raw -> HidHelperCommand? in
            let bytes = raw.bindMemory(to: UInt8.self)
            switch bytes[0] {
            case cmdKeyboardReport:
                guard bytes.count >= 3 else { return nil }
                let modifiers = bytes[1]
                let count = Int(bytes[2])
                guard count <= maxKeys, bytes.count == 3 + count * 2 else { return nil }
                var keys: [UInt16] = []
                keys.reserveCapacity(count)
                for i in 0..<count {
                    let lo = UInt16(bytes[3 + i * 2])
                    let hi = UInt16(bytes[3 + i * 2 + 1])
                    keys.append(lo | (hi << 8))
                }
                return .keyboardReport(modifiers: modifiers, keys: keys)

            case cmdConsumerReport:
                guard bytes.count >= 2 else { return nil }
                let count = Int(bytes[1])
                guard count <= maxKeys, bytes.count == 2 + count * 2 else { return nil }
                var usages: [UInt16] = []
                usages.reserveCapacity(count)
                for i in 0..<count {
                    let lo = UInt16(bytes[2 + i * 2])
                    let hi = UInt16(bytes[2 + i * 2 + 1])
                    usages.append(lo | (hi << 8))
                }
                return .consumerReport(usages: usages)

            case cmdReset:
                guard bytes.count == 1 else { return nil }
                return .reset

            case cmdPing:
                guard bytes.count == 1 else { return nil }
                return .ping

            default:
                return nil
            }
        }
    }

    static func encodeStatus(_ status: HidHelperStatus) -> Data {
        var payload = Data(capacity: 3)
        payload.append(msgStatus)
        payload.append(status.state.rawValue)
        payload.append(status.detail)
        return framePayload(payload)
    }

    static func decodeStatus(_ payload: Data) -> HidHelperStatus? {
        guard payload.count == 3 else { return nil }
        return payload.withUnsafeBytes { raw -> HidHelperStatus? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes[0] == msgStatus,
                  let state = HidHelperState(rawValue: bytes[1]) else { return nil }
            return HidHelperStatus(state: state, detail: bytes[2])
        }
    }

    private static func framePayload(_ payload: Data) -> Data {
        precondition(!payload.isEmpty && payload.count <= maxPayloadLength)
        var framed = Data(capacity: 1 + payload.count)
        framed.append(UInt8(payload.count))
        framed.append(payload)
        return framed
    }
}

struct HidFrameReader {
    enum Error: Swift.Error, Equatable {
        case invalidLength(UInt8)
    }

    private var buffer = Data()
    private var offset = 0

    init() {}

    mutating func push(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        }
        buffer.append(chunk)

        var frames: [Data] = []
        while offset < buffer.count {
            let lengthByte = buffer[offset]
            let length = Int(lengthByte)
            guard length >= 1 && length <= HidHelperIPC.maxPayloadLength else {
                buffer.removeAll(keepingCapacity: false)
                offset = 0
                throw Error.invalidLength(lengthByte)
            }
            let available = buffer.count - offset - 1
            if available < length {
                break
            }
            let start = offset + 1
            let end = start + length
            frames.append(Data(buffer[start..<end]))
            offset = end
        }

        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 4096 {
            buffer = Data(buffer[offset...])
            offset = 0
        }
        return frames
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        offset = 0
    }
}
