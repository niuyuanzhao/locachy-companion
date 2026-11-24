// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Deterministic per-receiver virtual display identity so macOS WindowServer
// preserves each receiver's arrangement, resolution, HiDPI scaling, and color
// settings independently across reconnects and concurrent multi-display sessions.
struct VirtualDisplayIdentity: Equatable {
    let name: String
    let serialNum: UInt32
    let productID: UInt32

    static func derive(from panel: Panel, hostIDOverride: String? = nil) -> VirtualDisplayIdentity {
        let key: String
        if let override = hostIDOverride, !override.isEmpty {
            key = "hostid=\(override)|panel=\(panel.width)x\(panel.height)"
        } else {
            key = panel.identityKey
        }
        let serialHash = fnv1a32("locachy.display.serial|" + key)
        // Reserve non-zero 31-bit serial numbers (avoiding 0 and matching
        // deterministic per-receiver identity).
        let serialNum = (serialHash & 0x7FFF_FFFF) == 0 ? 0x4C4F_4301 : (serialHash & 0x7FFF_FFFF)

        let productSeed: String
        if let override = hostIDOverride, !override.isEmpty {
            productSeed = "locachy.display.product|hostid=\(override)|model=\(panel.machineModel)"
        } else if let panelHostID = panel.hostID, !panelHostID.isEmpty {
            productSeed = "locachy.display.product|hostid=\(panelHostID)|model=\(panel.machineModel)"
        } else if !panel.hostName.isEmpty || !panel.machineModel.isEmpty {
            productSeed = "locachy.display.product|host=\(panel.hostName)|model=\(panel.machineModel)"
        } else {
            productSeed = "locachy.display.product|" + key
        }
        let productHash = fnv1a32(productSeed)
        let productID: UInt32 = 0x4C00 | (productHash & 0x00FF)

        return VirtualDisplayIdentity(name: panel.displayLabel, serialNum: serialNum, productID: productID)
    }

    static func fnv1a32(_ text: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return hash
    }
}

// Tracks active virtual display serial numbers in this process so two concurrent
// sessions can never pass colliding serial numbers to CGVirtualDisplay, even if
// two legacy receivers omit host/model identifiers or hash-collide.
final class ActiveDisplayRegistry {
    static let shared = ActiveDisplayRegistry()

    private let lock = NSLock()
    private var activeSerials = Set<UInt32>()

    func claim(preferred: VirtualDisplayIdentity) -> VirtualDisplayIdentity {
        lock.lock()
        defer { lock.unlock() }
        var serial = preferred.serialNum == 0 ? 0x4C4F_4301 : preferred.serialNum
        var product = preferred.productID
        var step: UInt32 = 0
        while activeSerials.contains(serial) && step < 1024 {
            step += 1
            serial = ((preferred.serialNum &+ step) & 0x7FFF_FFFF)
            if serial == 0 { serial = 1 }
            product = 0x4C00 | ((preferred.productID &+ step) & 0x00FF)
        }
        activeSerials.insert(serial)
        return VirtualDisplayIdentity(name: preferred.name, serialNum: serial, productID: product)
    }

    func release(serialNum: UInt32) {
        lock.lock()
        activeSerials.remove(serialNum)
        lock.unlock()
    }

    func isActive(serialNum: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeSerials.contains(serialNum)
    }
}
