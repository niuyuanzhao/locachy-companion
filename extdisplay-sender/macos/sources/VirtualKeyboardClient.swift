// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

protocol VirtualKeyboardBackend: AnyObject {
    var status: HidHelperStatus { get }
    var isReady: Bool { get }
    func sendKeyboardReport(modifiers: UInt8, keys: [UInt16]) -> Bool
    func sendConsumerReport(usages: [UInt16]) -> Bool
    func reset()
    func stop()
}

// Non-blocking AF_UNIX client for the privileged LOCachy virtual HID helper
// (Karabiner DriverKit bridge). Connects lazily, reconnects every 2s when
// unavailable, and fails closed so RemoteInput falls back to CGEvent cleanly.
final class VirtualKeyboardClient: VirtualKeyboardBackend {
    private static let queueKey = DispatchSpecificKey<UInt8>()

    private let socketPath: String
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "locachy.macos.hid-client")
    private let lock = NSLock()
    private let writeLock = NSLock()

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var reconnectTimer: DispatchSourceTimer?
    private var readBuffer = Data()
    private var stopped = false
    private var started = false
    private var currentStatus = HidHelperStatus(state: .unavailable, detail: 0)
    private var lastLoggedStatus: HidHelperStatus?

    init(socketPath: String? = nil, log: @escaping (String) -> Void = { fputs("locachy-macos: \($0)\n", stderr) }) {
        if let socketPath {
            self.socketPath = socketPath
        } else if let env = ProcessInfo.processInfo.environment["LOCACHY_HID_HELPER_SOCK"], !env.isEmpty {
            self.socketPath = env
        } else {
            self.socketPath = HidHelperIPC.defaultSocketPath
        }
        self.log = log
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    deinit {
        stop()
    }

    var status: HidHelperStatus {
        lock.lock()
        let value = currentStatus
        lock.unlock()
        return value
    }

    var isReady: Bool {
        status.state == .ready
    }

    func start() {
        lock.lock()
        guard !stopped, !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        queue.async { [weak self] in
            self?.attemptConnect()
        }
    }

    func sendKeyboardReport(modifiers: UInt8, keys: [UInt16]) -> Bool {
        let clamped = keys.count > HidHelperIPC.maxKeys ? Array(keys.prefix(HidHelperIPC.maxKeys)) : keys
        return sendCommand(.keyboardReport(modifiers: modifiers, keys: clamped))
    }

    func sendConsumerReport(usages: [UInt16]) -> Bool {
        let clamped = usages.count > HidHelperIPC.maxKeys ? Array(usages.prefix(HidHelperIPC.maxKeys)) : usages
        return sendCommand(.consumerReport(usages: clamped))
    }

    func reset() {
        _ = sendCommand(.reset)
    }

    func stop() {
        writeLock.lock()
        lock.lock()
        if stopped {
            lock.unlock()
            writeLock.unlock()
            return
        }
        stopped = true
        let activeFd = fd
        lock.unlock()
        if activeFd >= 0 {
            let payload = HidHelperIPC.encodeCommand(.reset)
            _ = Self.writeAll(fd: activeFd, data: payload)
        }
        writeLock.unlock()

        let cleanup = {
            self.cancelReconnectTimer()
            self.teardownConnection(scheduleReconnect: false, logUnavailable: false)
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            cleanup()
        } else {
            queue.sync(execute: cleanup)
        }
    }

    // MARK: - Connection lifecycle (queue-isolated except lock-guarded fd/status)

    private func sendCommand(_ command: HidHelperCommand) -> Bool {
        let frame = HidHelperIPC.encodeCommand(command)
        writeLock.lock()
        lock.lock()
        let activeFd = fd
        let isStopped = stopped
        lock.unlock()
        guard !isStopped, activeFd >= 0 else {
            writeLock.unlock()
            return false
        }

        let ok = Self.writeAll(fd: activeFd, data: frame)
        if !ok {
            lock.lock()
            if fd == activeFd {
                currentStatus = HidHelperStatus(state: .unavailable, detail: 0)
            }
            lock.unlock()
        }
        writeLock.unlock()

        if ok {
            return true
        }

        queue.async { [weak self] in
            guard let self else { return }
            if self.currentFd() == activeFd {
                self.teardownConnection(scheduleReconnect: !self.isStopped(), logUnavailable: true)
            }
        }
        return false
    }

    private func currentFd() -> Int32 {
        lock.lock()
        let value = fd
        lock.unlock()
        return value
    }

    private func isStopped() -> Bool {
        lock.lock()
        let value = stopped
        lock.unlock()
        return value
    }

    private func attemptConnect() {
        guard !isStopped(), currentFd() < 0 else { return }

        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            updateStatus(HidHelperStatus(state: .unavailable, detail: 0))
            scheduleReconnectTimer()
            return
        }

        var noSigPipe: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(sock, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard !pathBytes.isEmpty, pathBytes.count < maxPathLen else {
            Darwin.close(sock)
            updateStatus(HidHelperStatus(state: .unavailable, detail: 0))
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: maxPathLen) { buf in
                for i in 0..<pathBytes.count {
                    buf[i] = pathBytes[i]
                }
                buf[pathBytes.count] = 0
            }
        }

        let addrLen = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count + 1)
        addr.sun_len = UInt8(addrLen)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.connect(sock, sockAddrPtr, addrLen)
            }
        }
        guard connected == 0 else {
            Darwin.close(sock)
            updateStatus(HidHelperStatus(state: .unavailable, detail: 0))
            scheduleReconnectTimer()
            return
        }

        let flags = fcntl(sock, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        }

        cancelReconnectTimer()
        readBuffer.removeAll(keepingCapacity: true)

        writeLock.lock()
        lock.lock()
        if stopped {
            lock.unlock()
            writeLock.unlock()
            Darwin.close(sock)
            return
        }
        fd = sock
        lock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleReadable(sock: sock)
        }
        source.setCancelHandler {
            Darwin.close(sock)
        }
        readSource = source
        source.resume()

        // Request initial helper/driver status immediately after connecting.
        let pingFrame = HidHelperIPC.encodeCommand(.ping)
        let pingOk = Self.writeAll(fd: sock, data: pingFrame)
        writeLock.unlock()
        if !pingOk {
            teardownConnection(scheduleReconnect: !isStopped(), logUnavailable: true)
        }
    }

    private func handleReadable(sock: Int32) {
        guard currentFd() == sock else { return }
        var temp = [UInt8](repeating: 0, count: 512)
        while true {
            let n = Darwin.read(sock, &temp, temp.count)
            if n > 0 {
                readBuffer.append(contentsOf: temp[0..<n])
                if !drainStatusFrames() {
                    teardownConnection(scheduleReconnect: !isStopped(), logUnavailable: true)
                    return
                }
            } else if n == 0 {
                teardownConnection(scheduleReconnect: !isStopped(), logUnavailable: true)
                return
            } else {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK { break }
                teardownConnection(scheduleReconnect: !isStopped(), logUnavailable: true)
                return
            }
        }
    }

    private func drainStatusFrames() -> Bool {
        while !readBuffer.isEmpty {
            let length = Int(readBuffer[readBuffer.startIndex])
            guard length >= 1 && length <= 128 else {
                return false
            }
            guard readBuffer.count >= 1 + length else {
                break
            }
            let start = readBuffer.index(after: readBuffer.startIndex)
            let end = readBuffer.index(start, offsetBy: length)
            let payload = Data(readBuffer[start..<end])
            readBuffer.removeFirst(1 + length)
            if let status = HidHelperIPC.decodeStatus(payload) {
                updateStatus(status)
            }
        }
        return true
    }

    private func teardownConnection(scheduleReconnect: Bool, logUnavailable: Bool) {
        let source = readSource
        readSource = nil
        readBuffer.removeAll(keepingCapacity: false)

        writeLock.lock()
        lock.lock()
        let activeFd = fd
        fd = -1
        if !logUnavailable {
            currentStatus = HidHelperStatus(state: .unavailable, detail: 0)
        }
        lock.unlock()
        writeLock.unlock()

        if let source {
            source.cancel()
        } else if activeFd >= 0 {
            Darwin.close(activeFd)
        }

        if logUnavailable {
            updateStatus(HidHelperStatus(state: .unavailable, detail: 0))
        }
        if scheduleReconnect && !isStopped() {
            scheduleReconnectTimer()
        }
    }

    private func scheduleReconnectTimer() {
        guard !isStopped(), reconnectTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.attemptConnect()
        }
        reconnectTimer = timer
        timer.resume()
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    private func updateStatus(_ next: HidHelperStatus) {
        lock.lock()
        currentStatus = next
        let shouldLog = lastLoggedStatus != next
        if shouldLog {
            lastLoggedStatus = next
        }
        lock.unlock()

        if shouldLog {
            log(Self.statusDescription(next))
        }
    }

    private static func statusDescription(_ status: HidHelperStatus) -> String {
        switch status.state {
        case .ready:
            return "Keyboard backend: virtual-hid (DriverKit ready)"
        case .driverNotActivated:
            return "Keyboard backend: cgevent fallback (driver awaiting approval in System Settings -> Login Items & Extensions -> Driver Extensions)"
        case .versionMismatched:
            return "Keyboard backend: cgevent fallback (Karabiner virtual HID driver version mismatch; detail=\(status.detail))"
        case .unavailable:
            return "Keyboard backend: cgevent fallback (hid helper unavailable)"
        }
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return true }
            var remaining = raw.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.send(fd, base.advanced(by: offset), remaining, 0)
                if written > 0 {
                    offset += written
                    remaining -= written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
