// Thin sender logging shim for the tracked upstream virtual-display source.
// No file logging or credentials are written by the sender.
import Foundation
enum Log {
    static func info(_ message: String) { SenderLog.info(message) }
}
