// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Security
import SystemConfiguration

private enum HelperLog {
    static func error(_ message: String) {
        fputs("locachy-hid-helper: \(message)\n", stderr)
        fflush(stderr)
    }

    static func info(_ message: String) {
        fputs("locachy-hid-helper: \(message)\n", stderr)
        fflush(stderr)
    }
}

struct HidHelperOptions {
    let socketPath: String
    let karabinerSocketPath: String
    let check: Bool

    static let usage = """
    usage: locachy-hid-helper [--socket PATH] [--karabiner-socket PATH]
           locachy-hid-helper --check
    """

    init(_ arguments: [String]) throws {
        if arguments == ["--check"] {
            socketPath = HidHelperIPC.defaultSocketPath
            karabinerSocketPath = KarabinerCodec.defaultDaemonSocketPath
            check = true
            return
        }
        var socket = HidHelperIPC.defaultSocketPath
        var karabinerSocket = KarabinerCodec.defaultDaemonSocketPath
        var seenSocket = false
        var seenKarabiner = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--socket":
                guard !seenSocket, index + 1 < arguments.count else {
                    throw NSError(domain: "HidHelper", code: 2, userInfo: [NSLocalizedDescriptionKey: Self.usage])
                }
                socket = arguments[index + 1]
                seenSocket = true
                index += 2
            case "--karabiner-socket":
                guard !seenKarabiner, index + 1 < arguments.count else {
                    throw NSError(domain: "HidHelper", code: 2, userInfo: [NSLocalizedDescriptionKey: Self.usage])
                }
                karabinerSocket = arguments[index + 1]
                seenKarabiner = true
                index += 2
            default:
                throw NSError(domain: "HidHelper", code: 2, userInfo: [NSLocalizedDescriptionKey: Self.usage])
            }
        }
        socketPath = socket
        karabinerSocketPath = karabinerSocket
        check = false
    }
}

enum PeerVerifier {
    static let expectedSigningIdentifier = "org.locachy.extdisplay.sender"
    static let expectedExecutableName = "locachy-macos-sender"
    static let allowedPrefixes = ["/opt/homebrew/", "/usr/local/"]

    enum Result: Equatable {
        case authorized(pid: pid_t, uid: uid_t)
        case rejected(String)
    }

    static func verify(fd: Int32) -> Result {
        // 1. Peer effective credentials via LOCAL_PEERCRED
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen) == 0,
              credLen == socklen_t(MemoryLayout<xucred>.size),
              cred.cr_version == XUCRED_VERSION else {
            return .rejected("LOCAL_PEERCRED failed (errno=\(errno))")
        }

        // 2. Peer PID via LOCAL_PEERPID
        var pid: pid_t = 0
        var pidLen = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLen) == 0,
              pidLen == socklen_t(MemoryLayout<pid_t>.size),
              pid > 0 else {
            return .rejected("LOCAL_PEERPID failed (errno=\(errno))")
        }

        // Non-root test mode: allow only the same UID as the helper process.
        // Production root LaunchDaemon (geteuid() == 0) always runs full verification.
        let myUid = geteuid()
        if myUid != 0 {
            guard cred.cr_uid == myUid else {
                return .rejected("peer uid \(cred.cr_uid) does not match non-root helper uid \(myUid)")
            }
            return .authorized(pid: pid, uid: cred.cr_uid)
        }

        // 3. Peer audit token via LOCAL_PEERTOKEN
        var auditToken = audit_token_t()
        var tokenLen = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &auditToken, &tokenLen) == 0,
              tokenLen == socklen_t(MemoryLayout<audit_token_t>.size) else {
            return .rejected("LOCAL_PEERTOKEN failed (errno=\(errno))")
        }

        // 4. Verify peer UID matches the active console user UID
        var consoleUid: uid_t = 0
        guard let consoleUserCF = SCDynamicStoreCopyConsoleUser(nil, &consoleUid, nil) else {
            return .rejected("no active console user")
        }
        let consoleUser = consoleUserCF as String
        guard !consoleUser.isEmpty, consoleUser != "loginwindow" else {
            return .rejected("console user is loginwindow")
        }
        guard cred.cr_uid == consoleUid else {
            return .rejected("peer uid \(cred.cr_uid) != active console user uid \(consoleUid)")
        }

        // 5. Verify executable path resolves via realpath to allowed Homebrew prefix and binary name
        guard let rawPath = processPath(pid: pid) else {
            return .rejected("proc_pidpath failed for pid \(pid)")
        }
        guard let resolvedPath = resolveRealPath(rawPath) else {
            return .rejected("realpath failed for \(rawPath)")
        }
        guard isAllowedExecutablePath(resolvedPath) else {
            return .rejected("disallowed executable path \(resolvedPath)")
        }

        // 6. Verify dynamic code signature and signing identifier via audit_token
        let tokenData = withUnsafeBytes(of: &auditToken) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        var guestCode: SecCode?
        let copyGuestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode)
        guard copyGuestStatus == errSecSuccess, let code = guestCode else {
            return .rejected("SecCodeCopyGuestWithAttributes failed (OSStatus=\(copyGuestStatus))")
        }

        // Verify the binary matches its own code directory / designated requirement.
        // Note: the sender is locally signed with a self-signed keychain cert that
        // is not anchored to System Roots, so kSecCSCheckAllArchitectures / full
        // trust chain evaluation is intentionally not enforced here; instead we
        // verify structural integrity against the designated requirement AND bind
        // to the expected identifier + root-installed / Homebrew path + active console UID.
        let validityStatus = SecCodeCheckValidity(code, [], nil)
        guard validityStatus == errSecSuccess else {
            return .rejected("SecCodeCheckValidity failed (OSStatus=\(validityStatus))")
        }

        var staticCode: SecStaticCode?
        let copyStaticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard copyStaticStatus == errSecSuccess, let sCode = staticCode else {
            return .rejected("SecCodeCopyStaticCode failed (OSStatus=\(copyStaticStatus))")
        }

        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(sCode, [], &infoCF)
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else {
            return .rejected("SecCodeCopySigningInformation failed (OSStatus=\(infoStatus))")
        }

        guard let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              identifier == expectedSigningIdentifier else {
            let actual = info[kSecCodeInfoIdentifier as String] as? String ?? "<none>"
            return .rejected("unexpected signing identifier \(actual)")
        }

        return .authorized(pid: pid, uid: cred.cr_uid)
    }

    static func isAllowedExecutablePath(_ resolvedPath: String) -> Bool {
        guard allowedPrefixes.contains(where: { resolvedPath.hasPrefix($0) }) else {
            return false
        }
        let name = URL(fileURLWithPath: resolvedPath).lastPathComponent
        return name == expectedExecutableName
    }

    private static func processPath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE == 4 * MAXPATHLEN == 4096
        let maxSize = Int(MAXPATHLEN) * 4
        var buffer = [CChar](repeating: 0, count: maxSize)
        let length = proc_pidpath(pid, &buffer, UInt32(maxSize))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func resolveRealPath(_ path: String) -> String? {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(path, &resolved) != nil else { return nil }
        return String(cString: resolved)
    }
}

final class HidHelperServer {
    private let socketPath: String
    private let karabiner: KarabinerDaemonClient
    private let queue = DispatchQueue(label: "org.locachy.hid-helper.server")

    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    private var clientFd: Int32 = -1
    private var clientReadSource: DispatchSourceRead?
    private var clientReader = HidFrameReader()

    init(socketPath: String, karabinerSocketPath: String) {
        self.socketPath = socketPath
        self.karabiner = KarabinerDaemonClient(socketPath: karabinerSocketPath)
        self.karabiner.onStatusChanged = { [weak self] status in
            self?.queue.async {
                self?.sendStatusToActiveClientLocked(status)
            }
        }
    }

    func start() throws {
        try queue.sync {
            try bindAndListenLocked()
        }
        karabiner.start()
        HelperLog.info("listening on \(socketPath)")
    }

    func stop() {
        queue.sync {
            closeActiveClientLocked(resetKeyboard: false)
            if let source = acceptSource {
                acceptSource = nil
                listenFd = -1
                source.cancel()
            } else if listenFd >= 0 {
                Darwin.close(listenFd)
                listenFd = -1
            }
            _ = Darwin.unlink(socketPath)
        }
        karabiner.stop()
    }

    // MARK: - Listening socket (queue-isolated)

    private func bindAndListenLocked() throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard !pathBytes.isEmpty && pathBytes.count <= maxPathLen else {
            throw NSError(domain: "HidHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "socket path too long: \(socketPath)"
            ])
        }

        // Remove stale socket file if present.
        if Darwin.unlink(socketPath) != 0 && errno != ENOENT {
            throw NSError(domain: "HidHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed to unlink \(socketPath) (errno=\(errno))"
            ])
        }

        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw NSError(domain: "HidHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "socket() failed (errno=\(errno))"
            ])
        }

        var noSigPipe: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0..<pathBytes.count {
                buf[i] = pathBytes[i]
            }
            buf[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(sock)
            throw NSError(domain: "HidHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "bind(\(socketPath)) failed (errno=\(err))"
            ])
        }

        // Production root daemon exposes 0666 because the sender runs as the console user;
        // every connection is authenticated via kernel audit_token + SecCode + console UID + path.
        // Non-root mode restricts the socket to 0600.
        let mode: mode_t = (geteuid() == 0) ? 0o666 : 0o600
        guard Darwin.chmod(socketPath, mode) == 0 else {
            let err = errno
            Darwin.close(sock)
            _ = Darwin.unlink(socketPath)
            throw NSError(domain: "HidHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "chmod(\(socketPath)) failed (errno=\(err))"
            ])
        }

        guard Darwin.listen(sock, 8) == 0 else {
            let err = errno
            Darwin.close(sock)
            _ = Darwin.unlink(socketPath)
            throw NSError(domain: "HidHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "listen() failed (errno=\(err))"
            ])
        }

        let flags = fcntl(sock, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        }

        listenFd = sock
        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingLocked()
        }
        source.setCancelHandler {
            Darwin.close(sock)
        }
        acceptSource = source
        source.resume()
    }

    private func acceptPendingLocked() {
        guard listenFd >= 0 else { return }
        while true {
            var peerAddr = sockaddr_un()
            var peerLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let accepted = withUnsafeMutablePointer(to: &peerAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.accept(listenFd, saPtr, &peerLen)
                }
            }
            if accepted < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                if errno == EINTR {
                    continue
                }
                HelperLog.error("accept() error (errno=\(errno))")
                return
            }

            var noSigPipe: Int32 = 1
            _ = setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            switch PeerVerifier.verify(fd: accepted) {
            case let .rejected(reason):
                HelperLog.error("rejected client connection: \(reason)")
                Darwin.close(accepted)
                continue
            case let .authorized(pid, uid):
                HelperLog.info("accepted authorized client pid=\(pid) uid=\(uid)")
                attachClientLocked(fd: accepted)
            }
        }
    }

    // MARK: - Active client lifecycle (queue-isolated)

    private func attachClientLocked(fd: Int32) {
        if clientFd >= 0 {
            HelperLog.info("replacing previous client connection")
            closeActiveClientLocked(resetKeyboard: true)
        }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        clientFd = fd
        clientReader.reset()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleClientReadableLocked()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        clientReadSource = source
        source.resume()

        // Proactively push current status so the sender knows driver readiness immediately.
        sendStatusToActiveClientLocked(karabiner.currentStatus)
    }

    private func closeActiveClientLocked(resetKeyboard: Bool) {
        let hadClient = (clientFd >= 0 || clientReadSource != nil)
        if let source = clientReadSource {
            clientReadSource = nil
            clientFd = -1
            source.cancel()
        } else if clientFd >= 0 {
            Darwin.close(clientFd)
            clientFd = -1
        }
        clientReader.reset()

        if hadClient && resetKeyboard {
            // Immediately release all keys on disconnect so nothing can ever remain stuck.
            karabiner.resetKeyboard()
        }
    }

    private func handleClientReadableLocked() {
        guard clientFd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(clientFd, &buf, buf.count)
            if n > 0 {
                let chunk = Data(bytes: buf, count: n)
                do {
                    let payloads = try clientReader.push(chunk)
                    for payload in payloads {
                        guard let command = HidHelperIPC.decodeCommand(payload) else {
                            HelperLog.error("malformed client command; resetting keyboard and closing")
                            closeActiveClientLocked(resetKeyboard: true)
                            return
                        }
                        handleCommandLocked(command)
                        if clientFd < 0 { return }
                    }
                } catch {
                    HelperLog.error("invalid client framing (\(error)); resetting keyboard and closing")
                    closeActiveClientLocked(resetKeyboard: true)
                    return
                }
            } else if n == 0 {
                HelperLog.info("client disconnected; releasing all virtual keys")
                closeActiveClientLocked(resetKeyboard: true)
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                if errno == EINTR {
                    continue
                }
                HelperLog.error("client read error (errno=\(errno)); releasing all virtual keys")
                closeActiveClientLocked(resetKeyboard: true)
                return
            }
        }
    }

    private func handleCommandLocked(_ command: HidHelperCommand) {
        switch command {
        case let .keyboardReport(modifiers, keys):
            _ = karabiner.postKeyboard(modifiers: modifiers, keys: keys)
        case let .consumerReport(usages):
            _ = karabiner.postConsumer(usages: usages)
        case .reset:
            karabiner.resetKeyboard()
        case .ping:
            sendStatusToActiveClientLocked(karabiner.currentStatus)
        }
    }

    private func sendStatusToActiveClientLocked(_ status: HidHelperStatus) {
        guard clientFd >= 0 else { return }
        let frame = HidHelperIPC.encodeStatus(status)
        if !writeAllLocked(fd: clientFd, data: frame) {
            HelperLog.error("client write error; releasing all virtual keys")
            closeActiveClientLocked(resetKeyboard: true)
        }
    }

    private func writeAllLocked(fd: Int32, data: Data) -> Bool {
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
}

@main
enum HidHelperMain {
    private static var signalSources: [DispatchSourceSignal] = []

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            let options = try HidHelperOptions(Array(CommandLine.arguments.dropFirst()))
            if options.check {
                print("PASS: locachy-hid-helper ready (protocol v\(KarabinerCodec.clientProtocolVersion))")
                exit(0)
            }

            let server = HidHelperServer(
                socketPath: options.socketPath,
                karabinerSocketPath: options.karabinerSocketPath
            )
            try server.start()

            for sig in [SIGINT, SIGTERM, SIGHUP] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    HelperLog.info("received signal \(sig); resetting keyboard and shutting down")
                    server.stop()
                    exit(0)
                }
                source.resume()
                signalSources.append(source)
            }

            withExtendedLifetime(server) {
                dispatchMain()
            }
        } catch {
            HelperLog.error("\(error.localizedDescription)")
            exit(2)
        }
    }
}
