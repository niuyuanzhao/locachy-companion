// Thin sender logging shim for the tracked upstream virtual-display source.
import Foundation
enum Log {
    static func info(_ message: String) { SenderLog.info(message) }
}
