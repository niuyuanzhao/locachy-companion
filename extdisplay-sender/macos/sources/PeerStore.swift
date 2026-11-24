// SPDX-License-Identifier: GPL-3.0-or-later
import CoreFoundation
import Darwin
import Foundation

struct StoredPeer: Codable, Equatable {
    let hostID: String
    var displayName: String
    let identity: String
    let pskBase32: String
    let createdAt: String
    var lastUsedAt: String
}

// Persistent once-forever pairing credentials matching LOCachy's /etc/locachy/peers/
// protocol. Secrets are stored strictly at mode 0600 inside a 0700 directory using
// atomic O_CREAT|O_EXCL temp-file writes, fsync, and rename.
final class PeerStore {
    static let shared = PeerStore()
    static let maxPeers = 64

    private struct Envelope: Codable {
        var version: Int
        var peers: [String: StoredPeer]
    }

    private let lock = NSLock()
    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.fileURL = base.appendingPathComponent("LOCachy/peers.json", isDirectory: false)
        } else {
            self.fileURL = nil
        }
    }

    static func validHostID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 8 && bytes.count <= 64 else { return false }
        return bytes.allSatisfy { b in
            (b >= 0x30 && b <= 0x39)      // 0-9
                || (b >= 0x41 && b <= 0x5a) // A-Z
                || (b >= 0x61 && b <= 0x7a) // a-z
                || b == 0x5f || b == 0x2d   // '_', '-'
        }
    }

    static func validIdentity(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty && bytes.count <= 128 else { return false }
        return bytes.allSatisfy { b in
            (b >= 0x30 && b <= 0x39)
                || (b >= 0x41 && b <= 0x5a)
                || (b >= 0x61 && b <= 0x7a)
                || b == 0x5f || b == 0x2d || b == 0x2e // '_', '-', '.'
        }
    }

    static func sanitizeDisplayName(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        var out = ""
        var prevSpace = false
        for scalar in raw.unicodeScalars {
            guard scalar.value >= 0x20, scalar.value <= 0x7e else { continue }
            if scalar == " " {
                if !out.isEmpty && !prevSpace { out.append(" "); prevSpace = true }
            } else {
                out.append(Character(scalar))
                prevSpace = false
            }
            if out.count >= 64 { break }
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallback : trimmed
    }

    // Encodes a 16-byte PSK into canonical uppercase 26-char RFC 4648 base32
    // without hyphens or padding, matching PairingCode.decode.
    static func canonicalBase32(from key: Data) throws -> String {
        guard key.count == PairingCode.bytes else {
            throw SenderError("Pairing key must be 16 bytes")
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var out = [UInt8]()
        out.reserveCapacity(PairingCode.characters)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in key {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1f)])
                buffer &= (1 << UInt32(bits)) - 1
            }
        }
        if bits > 0 {
            out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1f)])
        }
        guard out.count == PairingCode.characters else {
            throw SenderError("Invalid pairing key encoding")
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decodePSK(_ base32: String) throws -> Data {
        var raw = Array(base32.utf8)
        defer { PairingCode.zero(&raw) }
        return try raw.withUnsafeBufferPointer { try PairingCode.decode($0) }
    }

    // Parses either a compact LOCachy pairing URI:
    //   locachy-pair://v1?host=<hostID>&id=<identity>&code=<CODE>[&name=<displayName>]
    // or a LOCachy bundle token from `locachy-pair add`:
    //   locachy-pair-v1:<base64url-json>
    static func parsePairingToken(_ rawToken: String) throws -> StoredPeer {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 16384 else {
            throw SenderError("Invalid LOCachy pairing token")
        }
        if trimmed.hasPrefix("locachy-pair-v1:") {
            return try parseBundleToken(trimmed)
        }
        guard trimmed.utf8.count <= 1024,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "locachy-pair",
              components.host?.lowercased() == "v1",
              let items = components.queryItems, !items.isEmpty else {
            throw SenderError("Invalid LOCachy pairing token (expected locachy-pair://v1?... or locachy-pair-v1:...)")
        }
        var params: [String: String] = [:]
        for item in items {
            let key = item.name.lowercased()
            guard let value = item.value, !value.isEmpty, params[key] == nil else {
                throw SenderError("Malformed or duplicated parameter in pairing token")
            }
            params[key] = value
        }
        let allowedKeys: Set<String> = ["host", "hostid", "id", "identity", "code", "psk", "name"]
        guard Set(params.keys).isSubset(of: allowedKeys) else {
            throw SenderError("Unsupported parameter in pairing token")
        }
        let hostID = params["host"] ?? params["hostid"] ?? ""
        let identity = params["id"] ?? params["identity"] ?? ""
        let code = params["code"] ?? params["psk"] ?? ""
        guard validHostID(hostID) else { throw SenderError("Invalid host identifier in pairing token") }
        guard validIdentity(identity) else { throw SenderError("Invalid peer identity in pairing token") }
        var key = try decodePSK(code)
        defer { key.resetBytes(in: 0..<key.count) }
        let canonical = try canonicalBase32(from: key)
        let name = sanitizeDisplayName(params["name"], fallback: hostID)
        let stamp = ISO8601DateFormatter().string(from: Date())
        return StoredPeer(
            hostID: hostID,
            displayName: name,
            identity: identity,
            pskBase32: canonical,
            createdAt: stamp,
            lastUsedAt: stamp
        )
    }

    private static func parseBundleToken(_ trimmed: String) throws -> StoredPeer {
        let payload = String(trimmed.dropFirst("locachy-pair-v1:".count))
        var b64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem != 0 { b64.append(String(repeating: "=", count: 4 - rem)) }
        guard var decodedData = Data(base64Encoded: b64) else {
            throw SenderError("Cannot base64url-decode locachy-pair-v1 token")
        }
        defer { decodedData.resetBytes(in: 0..<decodedData.count) }
        guard let obj = try? JSONSerialization.jsonObject(with: decodedData) as? [String: Any],
              let version = obj["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == 1 else {
            throw SenderError("Unsupported locachy-pair-v1 token format")
        }
        let hostID = (obj["host_id"] as? String) ?? ""
        let identity = (obj["extdisplay_identity"] as? String) ?? ""
        guard validHostID(hostID) else { throw SenderError("Invalid host_id in pairing bundle") }
        guard validIdentity(identity) else { throw SenderError("Invalid extdisplay_identity in pairing bundle") }
        var key: Data
        if let code = obj["extdisplay_code"] as? String, !code.isEmpty {
            key = try decodePSK(code)
        } else if let hex = obj["extdisplay_psk_hex"] as? String {
            key = try decodeHexPSK(hex)
        } else {
            throw SenderError("Pairing bundle is missing extdisplay key")
        }
        defer { key.resetBytes(in: 0..<key.count) }
        let canonical = try canonicalBase32(from: key)
        let rawName = (obj["host_name"] as? String) ?? (obj["name"] as? String)
        let name = sanitizeDisplayName(rawName, fallback: hostID)
        let stamp = ISO8601DateFormatter().string(from: Date())
        return StoredPeer(
            hostID: hostID,
            displayName: name,
            identity: identity,
            pskBase32: canonical,
            createdAt: stamp,
            lastUsedAt: stamp
        )
    }

    private static func decodeHexPSK(_ hex: String) throws -> Data {
        let chars = Array(hex.utf8)
        guard chars.count == PairingCode.bytes * 2 else {
            throw SenderError("Invalid hex PSK length in pairing bundle")
        }
        var out = Data(capacity: PairingCode.bytes)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = hexNibble(chars[i]), let lo = hexNibble(chars[i + 1]) else {
                out.resetBytes(in: 0..<out.count)
                throw SenderError("Invalid hex PSK in pairing bundle")
            }
            out.append((hi << 4) | lo)
        }
        return out
    }

    private static func hexNibble(_ c: UInt8) -> UInt8? {
        if c >= 0x30 && c <= 0x39 { return c - 0x30 }
        if c >= 0x41 && c <= 0x46 { return c - 0x41 + 10 }
        if c >= 0x61 && c <= 0x66 { return c - 0x61 + 10 }
        return nil
    }

    func lookup(hostID: String) -> StoredPeer? {
        guard Self.validHostID(hostID) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().peers[hostID]
    }

    func all() -> [StoredPeer] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().peers.values.sorted {
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.hostID < $1.hostID
        }
    }

    func save(_ peer: StoredPeer) throws {
        guard Self.validHostID(peer.hostID) else { throw SenderError("Invalid host identifier") }
        guard Self.validIdentity(peer.identity) else { throw SenderError("Invalid peer identity") }
        var decoded = try Self.decodePSK(peer.pskBase32)
        defer { decoded.resetBytes(in: 0..<decoded.count) }
        let canonical = try Self.canonicalBase32(from: decoded)
        let nowStamp = ISO8601DateFormatter().string(from: Date())

        lock.lock()
        defer { lock.unlock() }
        var env = loadLocked()
        if env.peers.count >= Self.maxPeers && env.peers[peer.hostID] == nil {
            if let oldest = env.peers.min(by: { $0.value.lastUsedAt < $1.value.lastUsedAt })?.key {
                env.peers.removeValue(forKey: oldest)
            }
        }
        let created = env.peers[peer.hostID]?.createdAt ?? (peer.createdAt.isEmpty ? nowStamp : peer.createdAt)
        let normalized = StoredPeer(
            hostID: peer.hostID,
            displayName: Self.sanitizeDisplayName(peer.displayName, fallback: peer.hostID),
            identity: peer.identity,
            pskBase32: canonical,
            createdAt: created,
            lastUsedAt: peer.lastUsedAt.isEmpty ? nowStamp : peer.lastUsedAt
        )
        env.peers[peer.hostID] = normalized
        try storeLocked(env)
    }

    func touchLastUsed(hostID: String, displayName: String? = nil) {
        guard Self.validHostID(hostID) else { return }
        lock.lock()
        defer { lock.unlock() }
        var env = loadLocked()
        guard var existing = env.peers[hostID] else { return }
        existing.lastUsedAt = ISO8601DateFormatter().string(from: Date())
        if let displayName {
            existing.displayName = Self.sanitizeDisplayName(displayName, fallback: existing.displayName)
        }
        env.peers[hostID] = existing
        try? storeLocked(env)
    }

    @discardableResult
    func remove(hostID: String) -> Bool {
        guard Self.validHostID(hostID) else { return false }
        lock.lock()
        defer { lock.unlock() }
        var env = loadLocked()
        guard env.peers.removeValue(forKey: hostID) != nil else { return false }
        try? storeLocked(env)
        return true
    }

    private func loadLocked() -> Envelope {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.version == 1 else {
            return Envelope(version: 1, peers: [:])
        }
        var valid: [String: StoredPeer] = [:]
        for (key, peer) in env.peers {
            guard key == peer.hostID,
                  Self.validHostID(peer.hostID),
                  Self.validIdentity(peer.identity) else { continue }
            if var decoded = try? Self.decodePSK(peer.pskBase32) {
                decoded.resetBytes(in: 0..<decoded.count)
                valid[key] = peer
            }
        }
        return Envelope(version: 1, peers: valid)
    }

    private func storeLocked(_ env: Envelope) throws {
        guard let url = fileURL else { throw SenderError("Peer storage path is unavailable") }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(env)
        defer { data.resetBytes(in: 0..<data.count) }

        let tempURL = dir.appendingPathComponent(".peers.json.\(UUID().uuidString).tmp", isDirectory: false)
        let fd = tempURL.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard fd >= 0 else {
            throw SenderError("Could not create peer store temporary file (errno=\(errno))")
        }
        var committed = false
        defer {
            Darwin.close(fd)
            if !committed {
                _ = tempURL.path.withCString { Darwin.unlink($0) }
            }
        }
        _ = Darwin.fchmod(fd, mode_t(0o600))
        let wroteAll = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return true }
            var offset = 0
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, base.advanced(by: offset), remaining)
                if n > 0 {
                    offset += n
                    remaining -= n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard wroteAll else {
            throw SenderError("Could not write peer store (errno=\(errno))")
        }
        if Darwin.fsync(fd) != 0 {
            throw SenderError("Could not flush peer store (errno=\(errno))")
        }
        let renamed = tempURL.path.withCString { src in
            url.path.withCString { dst in
                Darwin.rename(src, dst)
            }
        }
        guard renamed == 0 else {
            throw SenderError("Could not replace peer store (errno=\(errno))")
        }
        committed = true
    }
}
