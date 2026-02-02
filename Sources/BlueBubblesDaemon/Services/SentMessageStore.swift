import Foundation
import Vapor

/// In-memory store for messages sent via the API so they appear in GET /messages and SSE until the poller picks them up from the DB.
final class SentMessageStore {
    private let lock = NSLock()
    /// Recent sent messages per chat (guid -> list, newest last). Capped per chat.
    private var byChat: [String: [Message]] = [:]
    /// Pending messages to push via SSE (consumed by events route).
    private var pendingForSSE: [Message] = []
    private let maxPerChat = 50

    func add(_ message: Message) {
        lock.lock()
        defer { lock.unlock() }
        guard let chatGuid = message.chatGuid else { return }
        if byChat[chatGuid] == nil { byChat[chatGuid] = [] }
        byChat[chatGuid]?.append(message)
        if (byChat[chatGuid]?.count ?? 0) > maxPerChat {
            byChat[chatGuid]?.removeFirst()
        }
        pendingForSSE.append(message)
    }

    func getRecent(forChatGuid chatGuid: String) -> [Message] {
        lock.lock()
        defer { lock.unlock() }
        return byChat[chatGuid] ?? []
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
