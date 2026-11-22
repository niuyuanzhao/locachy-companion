// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

// Pure wire codecs and Unix-domain stream client for Karabiner-DriverKit-VirtualHIDDevice v8.8.0.
// Every byte layout is derived directly from:
//   - pqrs/unix_domain_stream/impl/protocol.hpp
//   - pqrs/karabiner/driverkit/client_protocol_version.hpp
//   - pqrs/karabiner/driverkit/virtual_hid_device_service/{constants,parameters,request,response}.hpp
//   - pqrs/karabiner/driverkit/virtual_hid_device_driver/hid_report/{keyboard_input,consumer_input,keys,modifiers}.hpp

enum KarabinerMessageType: UInt8, Equatable {
    case heartbeat = 0
    case userData = 1
    case healthCheck = 2
    case healthCheckResponse = 3
    case request = 4
    case response = 5
}

enum KarabinerRequestType: UInt8, Equatable {
    case virtualHidKeyboardInitialize = 0
    case virtualHidKeyboardTerminate = 1
    case virtualHidKeyboardReset = 2
    case virtualHidPointingInitialize = 3
    case virtualHidPointingTerminate = 4
    case virtualHidPointingReset = 5
    case postKeyboardInputReport = 6
    case postConsumerInputReport = 7
    case postAppleVendorKeyboardInputReport = 8
    case postAppleVendorTopCaseInputReport = 9
    case postGenericDesktopInputReport = 10
    case postPointingInputReport = 11
}

enum KarabinerResponseType: UInt8, Equatable {
    case none = 0
    case driverActivated = 1
    case driverConnected = 2
    case driverVersionMismatched = 3
    case virtualHidKeyboardReady = 4
    case virtualHidPointingReady = 5
}

struct KarabinerKeyboardParameters: Equatable {
    var vendorId: UInt64
    var productId: UInt64
    var countryCode: UInt64

    static let `default` = KarabinerKeyboardParameters(
        vendorId: 0x16c0,
        productId: 0x27db,
        countryCode: 0
    )
}

enum KarabinerFrame: Equatable {
    case heartbeat
    case userData(Data)
    case healthCheck
    case healthCheckResponse
    case request(id: UInt64, payload: Data)
    case response(id: UInt64, payload: Data)
}

struct KarabinerStatusPair: Equatable {
    let type: KarabinerResponseType
    let value: Bool
}

enum KarabinerCodec {
    static let defaultDaemonSocketPath =
        "/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock"
    static let clientProtocolVersion: UInt16 = 7
    static let maxMessageSize = 1024
    static let keyboardReportSize = 67
    static let consumerReportSize = 65
    static let keyboardParametersSize = 24
    static let maxKeys = 32
    static let keyboardReportId: UInt8 = 1
    static let consumerReportId: UInt8 = 2

    private static let headerSize = 4
    private static let typeSize = 1
    private static let requestIdSize = 8

    // MARK: - Transport frame encoding

    static func encodeFrame(_ frame: KarabinerFrame) -> Data {
        switch frame {
        case .heartbeat:
            return makeSimpleFrame(.heartbeat, payload: Data())
        case let .userData(payload):
            return makeSimpleFrame(.userData, payload: payload)
        case .healthCheck:
            return makeSimpleFrame(.healthCheck, payload: Data())
        case .healthCheckResponse:
            return makeSimpleFrame(.healthCheckResponse, payload: Data())
        case let .request(id, payload):
            return makeRequestResponseFrame(.request, requestId: id, payload: payload)
        case let .response(id, payload):
            return makeRequestResponseFrame(.response, requestId: id, payload: payload)
        }
    }

    static func encodeHeartbeatFrame() -> Data {
        encodeFrame(.heartbeat)
    }

    static func encodeHealthCheckResponseFrame() -> Data {
        encodeFrame(.healthCheckResponse)
    }

    static func encodeRequestFrame(requestId: UInt64, payload: Data) -> Data {
        encodeFrame(.request(id: requestId, payload: payload))
    }

    static func encodeResponseFrame(requestId: UInt64, payload: Data) -> Data {
        encodeFrame(.response(id: requestId, payload: payload))
    }

    static func decodeFrameBody(_ body: Data) -> KarabinerFrame? {
        guard body.count >= typeSize else { return nil }
        return body.withUnsafeBytes { raw -> KarabinerFrame? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let type = KarabinerMessageType(rawValue: bytes[0]) else { return nil }
            switch type {
            case .heartbeat:
                guard bytes.count <= maxMessageSize + typeSize else { return nil }
                return .heartbeat
            case .userData:
                guard bytes.count <= maxMessageSize + typeSize else { return nil }
                return .userData(Data(bytes[typeSize..<bytes.count]))
            case .healthCheck:
                guard bytes.count <= maxMessageSize + typeSize else { return nil }
                return .healthCheck
            case .healthCheckResponse:
                guard bytes.count <= maxMessageSize + typeSize else { return nil }
                return .healthCheckResponse
            case .request, .response:
                let minLen = typeSize + requestIdSize
                let maxLen = maxMessageSize + minLen
                guard bytes.count >= minLen && bytes.count <= maxLen else { return nil }
                var id: UInt64 = 0
                for i in 0..<requestIdSize {
                    id = (id << 8) | UInt64(bytes[typeSize + i])
                }
                let payload = Data(bytes[minLen..<bytes.count])
                return type == .request
                    ? .request(id: id, payload: payload)
                    : .response(id: id, payload: payload)
            }
        }
    }

    // MARK: - Application request payloads

    static func encodeKeyboardInitializePayload(
        parameters: KarabinerKeyboardParameters = .default,
        protocolVersion: UInt16 = clientProtocolVersion
    ) -> Data {
        var data = Data(capacity: 3 + keyboardParametersSize)
        appendUInt16LE(&data, protocolVersion)
        data.append(KarabinerRequestType.virtualHidKeyboardInitialize.rawValue)
        appendUInt64LE(&data, parameters.vendorId)
        appendUInt64LE(&data, parameters.productId)
        appendUInt64LE(&data, parameters.countryCode)
        return data
    }

    static func encodeSimpleRequestPayload(
        _ requestType: KarabinerRequestType,
        protocolVersion: UInt16 = clientProtocolVersion
    ) -> Data {
        var data = Data(capacity: 3)
        appendUInt16LE(&data, protocolVersion)
        data.append(requestType.rawValue)
        return data
    }

    static func encodeKeyboardReport(modifiers: UInt8, keys: [UInt16]) -> Data {
        var data = Data(count: keyboardReportSize)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            bytes[0] = keyboardReportId
            bytes[1] = modifiers
            bytes[2] = 0
            let count = min(keys.count, maxKeys)
            for i in 0..<count {
                let k = keys[i]
                bytes[3 + i * 2] = UInt8(k & 0xff)
                bytes[3 + i * 2 + 1] = UInt8((k >> 8) & 0xff)
            }
        }
        return data
    }

    static func encodePostKeyboardReportPayload(
        modifiers: UInt8,
        keys: [UInt16],
        protocolVersion: UInt16 = clientProtocolVersion
    ) -> Data {
        var data = Data(capacity: 3 + keyboardReportSize)
        appendUInt16LE(&data, protocolVersion)
        data.append(KarabinerRequestType.postKeyboardInputReport.rawValue)
        data.append(encodeKeyboardReport(modifiers: modifiers, keys: keys))
        return data
    }

    static func encodeConsumerReport(usages: [UInt16]) -> Data {
        var data = Data(count: consumerReportSize)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            bytes[0] = consumerReportId
            let count = min(usages.count, maxKeys)
            for i in 0..<count {
                let u = usages[i]
                bytes[1 + i * 2] = UInt8(u & 0xff)
                bytes[1 + i * 2 + 1] = UInt8((u >> 8) & 0xff)
            }
        }
        return data
    }

    static func encodePostConsumerReportPayload(
        usages: [UInt16],
        protocolVersion: UInt16 = clientProtocolVersion
    ) -> Data {
        var data = Data(capacity: 3 + consumerReportSize)
        appendUInt16LE(&data, protocolVersion)
        data.append(KarabinerRequestType.postConsumerInputReport.rawValue)
        data.append(encodeConsumerReport(usages: usages))
        return data
    }

    // MARK: - Status pair decoding

    static func decodeStatusPairs(_ payload: Data) -> [KarabinerStatusPair]? {
        guard payload.count % 2 == 0 else { return nil }
        return payload.withUnsafeBytes { raw -> [KarabinerStatusPair] in
            let bytes = raw.bindMemory(to: UInt8.self)
            var pairs: [KarabinerStatusPair] = []
            pairs.reserveCapacity(bytes.count / 2)
            var index = 0
            while index + 1 < bytes.count {
                if let type = KarabinerResponseType(rawValue: bytes[index]) {
                    pairs.append(KarabinerStatusPair(type: type, value: bytes[index + 1] != 0))
                }
                index += 2
            }
            return pairs
        }
    }

    // MARK: - Private helpers

    private static func makeSimpleFrame(_ type: KarabinerMessageType, payload: Data) -> Data {
        let bodySize = UInt32(typeSize + payload.count)
        var frame = Data(capacity: headerSize + Int(bodySize))
        appendUInt32BE(&frame, bodySize)
        frame.append(type.rawValue)
        frame.append(payload)
        return frame
    }

    private static func makeRequestResponseFrame(
        _ type: KarabinerMessageType,
        requestId: UInt64,
        payload: Data
    ) -> Data {
        let bodySize = UInt32(typeSize + requestIdSize + payload.count)
        var frame = Data(capacity: headerSize + Int(bodySize))
        appendUInt32BE(&frame, bodySize)
        frame.append(type.rawValue)
        appendUInt64BE(&frame, requestId)
        frame.append(payload)
        return frame
    }

    private static func appendUInt16LE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt64BE(_ data: inout Data, _ value: UInt64) {
        data.append(UInt8((value >> 56) & 0xff))
        data.append(UInt8((value >> 48) & 0xff))
        data.append(UInt8((value >> 40) & 0xff))
        data.append(UInt8((value >> 32) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt64LE(_ data: inout Data, _ value: UInt64) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 32) & 0xff))
        data.append(UInt8((value >> 40) & 0xff))
        data.append(UInt8((value >> 48) & 0xff))
        data.append(UInt8((value >> 56) & 0xff))
    }
}

struct KarabinerStreamReader {
    enum Error: Swift.Error, Equatable {
        case invalidBodySize(UInt32)
        case malformedFrame
    }

    static let maxBodySize = UInt32(KarabinerCodec.maxMessageSize + 1 + 8)

    private var buffer = Data()
    private var offset = 0

    init() {}

    mutating func push(_ chunk: Data) throws -> [KarabinerFrame] {
        guard !chunk.isEmpty else { return [] }
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        }
        buffer.append(chunk)

        var frames: [KarabinerFrame] = []
        while buffer.count - offset >= 4 {
            let bodySize =
                (UInt32(buffer[offset]) << 24) |
                (UInt32(buffer[offset + 1]) << 16) |
                (UInt32(buffer[offset + 2]) << 8) |
                UInt32(buffer[offset + 3])
            guard bodySize >= 1 && bodySize <= Self.maxBodySize else {
                reset()
                throw Error.invalidBodySize(bodySize)
            }
            let totalNeeded = 4 + Int(bodySize)
            if buffer.count - offset < totalNeeded {
                break
            }
            let bodyStart = offset + 4
            let bodyEnd = offset + totalNeeded
            let body = Data(buffer[bodyStart..<bodyEnd])
            offset = bodyEnd
            guard let frame = KarabinerCodec.decodeFrameBody(body) else {
                reset()
                throw Error.malformedFrame
            }
            frames.append(frame)
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

final class KarabinerDaemonClient {
    private let socketPath: String
    private let parameters: KarabinerKeyboardParameters
    private let queue = DispatchQueue(label: "org.locachy.hid-helper.karabiner")
    private let stateLock = NSLock()

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var heartbeatTimer: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var reader = KarabinerStreamReader()
    private var running = false
    private var nextRequestId: UInt64 = 1
    private var initRequestId: UInt64?

    private var connected = false
    private var driverActivated: Bool?
    private var driverConnected: Bool?
    private var driverVersionMismatched = false
    private var clientProtocolMismatched = false
    private var keyboardReady = false

    private var statusStorage = HidHelperStatus(state: .unavailable, detail: 0)
    private var statusCallback: ((HidHelperStatus) -> Void)?

    var currentStatus: HidHelperStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return statusStorage
    }

    var onStatusChanged: ((HidHelperStatus) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return statusCallback
        }
        set {
            stateLock.lock()
            statusCallback = newValue
            stateLock.unlock()
        }
    }

    init(
        socketPath: String = KarabinerCodec.defaultDaemonSocketPath,
        parameters: KarabinerKeyboardParameters = .default
    ) {
        self.socketPath = socketPath
        self.parameters = parameters
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.connectNow()
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            cancelReconnectTimer()
            if fd >= 0 {
                _ = sendRequestSync(KarabinerCodec.encodePostKeyboardReportPayload(modifiers: 0, keys: []))
                _ = sendRequestSync(KarabinerCodec.encodePostConsumerReportPayload(usages: []))
                _ = sendRequestSync(KarabinerCodec.encodeSimpleRequestPayload(.virtualHidKeyboardReset))
                _ = sendRequestSync(KarabinerCodec.encodeSimpleRequestPayload(.virtualHidKeyboardTerminate))
            }
            disconnectLocked()
        }
    }

    @discardableResult
    func postKeyboard(modifiers: UInt8, keys: [UInt16]) -> Bool {
        let payload = KarabinerCodec.encodePostKeyboardReportPayload(modifiers: modifiers, keys: keys)
        return queue.sync {
            guard connected && fd >= 0 else { return false }
            return sendRequestSync(payload) != nil
        }
    }

    @discardableResult
    func postConsumer(usages: [UInt16]) -> Bool {
        let payload = KarabinerCodec.encodePostConsumerReportPayload(usages: usages)
        return queue.sync {
            guard connected && fd >= 0 else { return false }
            return sendRequestSync(payload) != nil
        }
    }

    func resetKeyboard() {
        let zeroKeyboard = KarabinerCodec.encodePostKeyboardReportPayload(modifiers: 0, keys: [])
        let zeroConsumer = KarabinerCodec.encodePostConsumerReportPayload(usages: [])
        let resetReq = KarabinerCodec.encodeSimpleRequestPayload(.virtualHidKeyboardReset)
        queue.sync {
            guard connected && fd >= 0 else { return }
            _ = sendRequestSync(zeroKeyboard)
            _ = sendRequestSync(zeroConsumer)
            _ = sendRequestSync(resetReq)
        }
    }

    // MARK: - Connection lifecycle (queue-isolated)

    private func connectNow() {
        guard running, fd < 0 else { return }
        cancelReconnectTimer()

        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            scheduleReconnect()
            return
        }

        var noSigPipe: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard !pathBytes.isEmpty && pathBytes.count <= maxPathLen else {
            Darwin.close(sock)
            scheduleReconnect()
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0..<pathBytes.count {
                buf[i] = pathBytes[i]
            }
            buf[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(sock, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            Darwin.close(sock)
            updateStatusLocked()
            scheduleReconnect()
            return
        }

        // Switch to non-blocking for DispatchSourceRead while keeping short write loop bounded.
        let flags = fcntl(sock, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        }

        fd = sock
        connected = true
        reader.reset()
        driverActivated = nil
        driverConnected = nil
        driverVersionMismatched = false
        clientProtocolMismatched = false
        keyboardReady = false
        initRequestId = nil

        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleReadable()
        }
        source.setCancelHandler {
            Darwin.close(sock)
        }
        readSource = source
        source.resume()

        startHeartbeatTimer()

        let initPayload = KarabinerCodec.encodeKeyboardInitializePayload(parameters: parameters)
        initRequestId = sendRequestSync(initPayload)
        updateStatusLocked()
    }

    private func disconnectLocked() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        if let source = readSource {
            readSource = nil
            fd = -1
            source.cancel()
        } else if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }

        connected = false
        driverActivated = nil
        driverConnected = nil
        driverVersionMismatched = false
        clientProtocolMismatched = false
        keyboardReady = false
        initRequestId = nil
        reader.reset()
        updateStatusLocked()
    }

    private func handleDisconnectLocked() {
        disconnectLocked()
        if running {
            scheduleReconnect()
        }
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, self.connected, self.fd >= 0 else { return }
            if !self.writeAllLocked(KarabinerCodec.encodeHeartbeatFrame()) {
                self.handleDisconnectLocked()
            }
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func scheduleReconnect() {
        guard running, reconnectTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.reconnectTimer?.cancel()
            self.reconnectTimer = nil
            self.connectNow()
        }
        reconnectTimer = timer
        timer.resume()
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    // MARK: - I/O (queue-isolated)

    private func handleReadable() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                let chunk = Data(bytes: buf, count: n)
                do {
                    let frames = try reader.push(chunk)
                    for frame in frames {
                        handleFrameLocked(frame)
                        if fd < 0 { return }
                    }
                } catch {
                    handleDisconnectLocked()
                    return
                }
            } else if n == 0 {
                handleDisconnectLocked()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                if errno == EINTR {
                    continue
                }
                handleDisconnectLocked()
                return
            }
        }
    }

    private func handleFrameLocked(_ frame: KarabinerFrame) {
        switch frame {
        case .heartbeat, .userData, .healthCheckResponse:
            break

        case .healthCheck:
            if !writeAllLocked(KarabinerCodec.encodeHealthCheckResponseFrame()) {
                handleDisconnectLocked()
            }

        case let .request(id, payload):
            applyStatusPayloadLocked(payload)
            if !writeAllLocked(KarabinerCodec.encodeResponseFrame(requestId: id, payload: Data())) {
                handleDisconnectLocked()
            }

        case let .response(id, payload):
            if let expectedInit = initRequestId, id == expectedInit {
                initRequestId = nil
                if payload.isEmpty {
                    clientProtocolMismatched = true
                    updateStatusLocked()
                    return
                }
            }
            applyStatusPayloadLocked(payload)
        }
    }

    private func applyStatusPayloadLocked(_ payload: Data) {
        guard !payload.isEmpty,
              let pairs = KarabinerCodec.decodeStatusPairs(payload) else {
            return
        }
        for pair in pairs {
            switch pair.type {
            case .none:
                break
            case .driverActivated:
                driverActivated = pair.value
            case .driverConnected:
                driverConnected = pair.value
            case .driverVersionMismatched:
                driverVersionMismatched = pair.value
            case .virtualHidKeyboardReady:
                keyboardReady = pair.value
            case .virtualHidPointingReady:
                break
            }
        }
        updateStatusLocked()
    }

    @discardableResult
    private func sendRequestSync(_ payload: Data) -> UInt64? {
        guard fd >= 0 else { return nil }
        let id = nextRequestId
        nextRequestId &+= 1
        let frame = KarabinerCodec.encodeRequestFrame(requestId: id, payload: payload)
        guard writeAllLocked(frame) else {
            handleDisconnectLocked()
            return nil
        }
        return id
    }

    private func writeAllLocked(_ data: Data) -> Bool {
        guard fd >= 0 else { return false }
        let total = data.count
        var sent = 0
        var eagainRetries = 0
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            while sent < total {
                let n = Darwin.write(fd, base.advanced(by: sent), total - sent)
                if n > 0 {
                    sent += n
                    eagainRetries = 0
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    eagainRetries += 1
                    if eagainRetries > 50 {
                        return false
                    }
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let pr = Darwin.poll(&pfd, 1, 20)
                    if pr <= 0 {
                        return false
                    }
                } else {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Status derivation

    private func computeStatusLocked() -> HidHelperStatus {
        guard connected else {
            return HidHelperStatus(state: .unavailable, detail: 0)
        }
        var detail: UInt8 = 0
        if driverActivated == true { detail |= 0x01 }
        if driverConnected == true { detail |= 0x02 }
        if driverVersionMismatched || clientProtocolMismatched { detail |= 0x04 }
        if keyboardReady { detail |= 0x08 }

        if driverVersionMismatched || clientProtocolMismatched {
            return HidHelperStatus(state: .versionMismatched, detail: detail)
        }
        if keyboardReady {
            return HidHelperStatus(state: .ready, detail: detail)
        }
        if driverActivated == false {
            return HidHelperStatus(state: .driverNotActivated, detail: detail)
        }
        return HidHelperStatus(state: .unavailable, detail: detail)
    }

    private func updateStatusLocked() {
        let newStatus = computeStatusLocked()
        var callback: ((HidHelperStatus) -> Void)?
        var changed = false
        stateLock.lock()
        if statusStorage != newStatus {
            statusStorage = newStatus
            callback = statusCallback
            changed = true
        }
        stateLock.unlock()
        if changed, let callback {
            callback(newStatus)
        }
    }
}
