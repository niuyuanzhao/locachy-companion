// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct SavedDisplayMode: Codable, Equatable {
    let pointsWide: Int
    let pointsHigh: Int
    let pixelsWide: Int
    let pixelsHigh: Int
}

final class DisplayModeDB {
    static let shared = DisplayModeDB()

    private struct Record: Codable {
        let host: String
        let model: String
        let panelWidth: Int
        let panelHeight: Int
        var pointsWide: Int
        var pointsHigh: Int
        var pixelsWide: Int
        var pixelsHigh: Int
        var updatedAt: String
    }

    private struct Envelope: Codable {
        var version: Int
        var displays: [String: Record]
    }

    private let lock = NSLock()
    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.fileURL = base.appendingPathComponent("LOCachy/display-modes.json", isDirectory: false)
        } else {
            self.fileURL = nil
        }
    }

    static func isValid(_ mode: SavedDisplayMode, for panel: Panel, allowedPointSizes: [(Int, Int)]) -> Bool {
        guard mode.pointsWide >= 2, mode.pointsHigh >= 2,
              allowedPointSizes.contains(where: { $0.0 == mode.pointsWide && $0.1 == mode.pointsHigh }) else {
            return false
        }
        if mode.pixelsWide == mode.pointsWide * panel.scale && mode.pixelsHigh == mode.pointsHigh * panel.scale {
            return true
        }
        return mode.pixelsWide == mode.pointsWide && mode.pixelsHigh == mode.pointsHigh
    }

    func lookup(for panel: Panel, allowedPointSizes: [(Int, Int)]) -> SavedDisplayMode? {
        lock.lock()
        defer { lock.unlock() }
        let env = loadLocked()
        guard let rec = env.displays[panel.identityKey],
              rec.panelWidth == panel.width, rec.panelHeight == panel.height else {
            return nil
        }
        let candidate = SavedDisplayMode(
            pointsWide: rec.pointsWide, pointsHigh: rec.pointsHigh,
            pixelsWide: rec.pixelsWide, pixelsHigh: rec.pixelsHigh)
        return Self.isValid(candidate, for: panel, allowedPointSizes: allowedPointSizes) ? candidate : nil
    }

    func save(for panel: Panel, mode: SavedDisplayMode, allowedPointSizes: [(Int, Int)]) {
        guard Self.isValid(mode, for: panel, allowedPointSizes: allowedPointSizes) else { return }
        lock.lock()
        defer { lock.unlock() }
        var env = loadLocked()
        if let existing = env.displays[panel.identityKey],
           existing.pointsWide == mode.pointsWide, existing.pointsHigh == mode.pointsHigh,
           existing.pixelsWide == mode.pixelsWide, existing.pixelsHigh == mode.pixelsHigh {
            return
        }
        if env.displays.count >= 64 && env.displays[panel.identityKey] == nil {
            if let oldest = env.displays.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
                env.displays.removeValue(forKey: oldest)
            }
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        env.displays[panel.identityKey] = Record(
            host: panel.hostName, model: panel.machineModel,
            panelWidth: panel.width, panelHeight: panel.height,
            pointsWide: mode.pointsWide, pointsHigh: mode.pointsHigh,
            pixelsWide: mode.pixelsWide, pixelsHigh: mode.pixelsHigh,
            updatedAt: stamp)
        storeLocked(env)
    }

    private func loadLocked() -> Envelope {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.version == 1 else {
            return Envelope(version: 1, displays: [:])
        }
        return env
    }

    private func storeLocked(_ env: Envelope) {
        guard let url = fileURL else { return }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(env) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
