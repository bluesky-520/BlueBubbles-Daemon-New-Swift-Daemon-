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

        // Include sent messages not yet in DB so bridge/client see them in updates immediately
        for chat in allChats {
            let sentRecent = sentMessageStore.getRecent(forChatGuid: chat.guid)
            for sent in sentRecent {
                guard sent.dateCreated > since else { continue }
                if !allMessages.contains(where: { $0.guid == sent.guid }) {
                    allMessages.append(sent)
                }
            }
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

    // MARK: - GET /attachments/:guid/info (metadata only, for BlueBubbles socket get-attachment)

    routes.get("attachments", ":guid", "info") { req async throws -> Attachment in
        guard let guid = req.parameters.get("guid") else {
            throw Abort(.badRequest)
        }
        guard let result = database.getAttachmentByGuid(guid) else {
            throw Abort(.notFound)
        }
        return result.attachment
    }

    // MARK: - GET /attachments/:guid (full file or byte range; Range header supported)

    routes.get("attachments", ":guid") { req async throws -> Response in
        guard let guid = req.parameters.get("guid") else {
            return Response(status: .badRequest)
        }
        guard let result = database.getAttachmentByGuid(guid) else {
            return Response(status: .notFound)
        }
        let path = result.path
        logger.debug("Attachment path: \(path)")
        guard FileManager.default.fileExists(atPath: path) else {
            logger.warning("Attachment file not found at path: \(path)")
            return Response(status: .notFound)
        }
        let fileURL = URL(fileURLWithPath: path)
        let totalBytes: Int64
        do {
            totalBytes = Int64(try FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64 ?? 0)
        } catch {
            logger.error("Failed to get file size: \(error.localizedDescription)")
            return Response(status: .internalServerError)
        }
        let rangeHeader = req.headers[.range].first
        var data: Data
        var status: HTTPResponseStatus = .ok
        var contentRange: String? = nil
        if let range = rangeHeader?.replacingOccurrences(of: "bytes=", with: "").trimmingCharacters(in: .whitespaces),
           let dashIndex = range.firstIndex(of: "-") {
            let startStr = String(range[..<dashIndex]).trimmingCharacters(in: .whitespaces)
            let endStr = String(range[range.index(after: dashIndex)...]).trimmingCharacters(in: .whitespaces)
            let start = Int64(startStr) ?? 0
            let end: Int64 = endStr.isEmpty ? totalBytes - 1 : min(Int64(endStr) ?? totalBytes - 1, totalBytes - 1)
            let length = max(0, end - start + 1)
            if start >= 0, length > 0, start < totalBytes {
                guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                    return Response(status: .internalServerError)
                }
                defer { try? handle.close() }
                try? handle.seek(toOffset: UInt64(start))
                data = (try? handle.read(upToCount: Int(length))) ?? Data()
                status = .partialContent
                contentRange = "bytes \(start)-\(start + Int64(data.count) - 1)/\(totalBytes)"
            } else {
                data = try Data(contentsOf: fileURL)
            }
        } else {
            data = try Data(contentsOf: fileURL)
        }
        let downloadName = result.attachment.filename.isEmpty ? guid : (result.attachment.filename as NSString).lastPathComponent
        let response = Response(status: status)
        // Advertise byte-range support (clients use Range for previews/streaming).
        response.headers.add(name: "Accept-Ranges", value: "bytes")
        response.headers.contentType = .init(type: result.attachment.mimeType.split(separator: "/").first.map(String.init) ?? "application", subType: result.attachment.mimeType.split(separator: "/").dropFirst().first.map(String.init) ?? "octet-stream")
        response.headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(downloadName)\"")
        if totalBytes > 0 {
            response.headers.add(name: "Content-Length", value: "\(data.count)")
        }
        if let cr = contentRange {
            response.headers.add(name: "Content-Range", value: cr)
        }
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