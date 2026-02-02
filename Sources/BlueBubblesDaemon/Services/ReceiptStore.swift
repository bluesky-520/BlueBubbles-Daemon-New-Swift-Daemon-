import Foundation
import Vapor

/// Read receipt payload for GET /messages/updates and Socket.IO parity.
struct ReadReceipt: Content {
    let chatGuid: String
    let messageGuids: [String]
    let dateRead: Int64
}

/// In-memory store for read receipts submitted via POST /read_receipt; returned in GET /messages/updates.
final class ReceiptStore {
    private let lock = NSLock()
    private var pending: [ReadReceipt] = []

    func add(chatGuid: String, messageGuids: [String], dateRead: Int64) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(ReadReceipt(chatGuid: chatGuid, messageGuids: messageGuids, dateRead: dateRead))
    }

    func takePending() -> [ReadReceipt] {
        lock.lock()
        defer { lock.unlock() }
        let result = pending
        pending = []
        return result
    }
}
