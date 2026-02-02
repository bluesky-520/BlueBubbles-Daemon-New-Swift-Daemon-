import Foundation
import Vapor

/// In-memory store for incoming messages detected by MessagePoller, pushed via GET /events SSE.
final class IncomingMessageStore {
    private let lock = NSLock()
    private var pendingForSSE: [Message] = []

    func add(_ message: Message) {
        lock.lock()
        defer { lock.unlock() }
        pendingForSSE.append(message)
    }

    /// Take and clear pending messages for SSE (so they are sent once).
    func takePendingForSSE() -> [Message] {
        lock.lock()
        defer { lock.unlock() }
        let result = pendingForSSE
        pendingForSSE = []
        return result
    }
}
