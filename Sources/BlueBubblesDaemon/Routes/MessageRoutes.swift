import Foundation
import NIOCore
import Vapor

struct MessageUpdatesResponse: Content {
    let messages: [Message]
    let typing: [String]
    let receipts: [ReadReceipt]
}

func messageRoutes(_ routes: RoutesBuilder, database: MessagesDatabase, sentMessageStore: SentMessageStore, receiptStore: ReceiptStore) throws {

    // MARK: - GET /chats/:chatGuid/messages

    routes.get("chats", ":chatGuid", "messages") { req async throws -> [Message] in
        let chatGuid = req.parameters.get("chatGuid")!
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 50
        let before = try? req.query.get(Int64.self, at: "before")

        logger.info("Fetching messages for chat \(chatGuid), limit: \(limit)")

        var messages = database.getMessages(forChatGuid: chatGuid, limit: limit, before: before)
        let sentRecent = sentMessageStore.getRecent(forChatGuid: chatGuid)
        for sent in sentRecent {
            if !messages.contains(where: { $0.guid == sent.guid }) {
                messages.append(sent)
            }
        }
        messages.sort { $0.dateCreated < $1.dateCreated }

        logger.debug("Returning \(messages.count) messages for chat \(chatGuid)")
        return messages
    }
    
    // MARK: - GET /messages/updates
    
    routes.get("messages", "updates") { req async throws -> MessageUpdatesResponse in
        let sinceRaw = (try? req.query.get(Int64.self, at: "since")) ?? 0
        
        // Accept since in ms (Unix epoch) or Apple nanoseconds; normalize to Apple ns for DB comparison.
        let since: Int64 = sinceRaw < 1_000_000_000_000_000 ? sinceMsToAppleNs(sinceRaw) : sinceRaw

        logger.debug("Fetching updates since: \(since) (raw: \(sinceRaw))")

        let allChats = database.getAllChats()
        var allMessages: [Message] = []

        for chat in allChats {
            let messages = database.getMessages(forChatGuid: chat.guid, limit: 100)
            let recentMessages = messages.filter { $0.dateCreated > since }
            allMessages.append(contentsOf: recentMessages)
        }

        allMessages.sort { $0.dateCreated < $1.dateCreated }

        logger.debug("Found \(allMessages.count) updates")

        let pendingReceipts = receiptStore.takePending()
        return MessageUpdatesResponse(
            messages: allMessages,
            typing: [],
            receipts: pendingReceipts
        )
    }

    // MARK: - GET /attachments/:guid

    routes.get("attachments", ":guid") { req async throws -> Response in
        guard let guid = req.parameters.get("guid") else {
            return Response(status: .badRequest)
        }
        guard let result = database.getAttachmentByGuid(guid) else {
            return Response(status: .notFound)
        }
        let path = result.path
        guard FileManager.default.fileExists(atPath: path) else {
            return Response(status: .notFound)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            logger.error("Failed to read attachment file: \(error.localizedDescription)")
            return Response(status: .internalServerError)
        }
        let downloadName = result.attachment.filename.isEmpty ? guid : (result.attachment.filename as NSString).lastPathComponent
        var response = Response(status: .ok)
        response.headers.contentType = .init(type: result.attachment.mimeType.split(separator: "/").first.map(String.init) ?? "application", subType: result.attachment.mimeType.split(separator: "/").dropFirst().first.map(String.init) ?? "octet-stream")
        response.headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(downloadName)\"")
        response.body = .init(buffer: ByteBuffer(data: data))
        return response
    }
}

/// Convert milliseconds since Unix epoch to Apple Messages date (nanoseconds since 2001-01-01).
private func sinceMsToAppleNs(_ ms: Int64) -> Int64 {
    let unixEpochMs2001: Int64 = 978_307_200_000
    let msSince2001 = max(0, ms - unixEpochMs2001)
    return msSince2001 * 1_000_000
}