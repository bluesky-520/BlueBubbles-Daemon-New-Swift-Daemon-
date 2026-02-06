import Foundation
import Vapor

func sendRoutes(_ routes: RoutesBuilder, appleScriptSender: AppleScriptSender, database: MessagesDatabase, sentMessageStore: SentMessageStore, sendCache: SendCache, receiptStore: ReceiptStore) throws {

    // MARK: - POST /send

    routes.post("send") { req async throws -> Response in
        let payload = try req.content.decode(SendMessagePayload.self)
        let tempGuid = payload.temp_guid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTempGuid = tempGuid.map { !$0.isEmpty } ?? false

        if hasTempGuid, let guid = tempGuid, sendCache.contains(guid) {
            return try jsonResponse(status: .badRequest, body: SendErrorBody(error: "Message is already queued to be sent (Temp GUID: \(guid))", temp_guid: guid))
        }

        if hasTempGuid, let guid = tempGuid {
            _ = sendCache.add(guid)
        }
        defer {
            if hasTempGuid, let guid = tempGuid {
                sendCache.remove(guid)
            }
        }

        logger.info("Sending message to chat: \(payload.chat_guid)")

        let chatIdentifier = database.getChatIdentifier(forChatGuid: payload.chat_guid)
        let recipients = database.getChatRecipients(forChatGuid: payload.chat_guid)
        let resolvedPaths = resolveAttachmentPaths(payload.attachment_paths)
        let success = appleScriptSender.sendMessage(
            toChatWithGuid: payload.chat_guid,
            text: payload.text,
            chatIdentifier: chatIdentifier,
            recipients: recipients,
            attachmentPaths: resolvedPaths
        )

        if success {
            logger.info("Message sent successfully")

            let messageGuid = "sent-\(UUID().uuidString)"
            let dateCreated = Int64((Date().timeIntervalSince1970 - 978_307_200) * 1_000_000_000)

            let sentMessage = Message(
                guid: messageGuid,
                text: payload.text,
                sender: "me",
                handleId: "",
                dateCreated: dateCreated,
                dateRead: nil,
                isFromMe: true,
                type: "text",
                attachments: nil,
                subject: nil,
                error: nil,
                associatedMessageGuid: nil,
                associatedMessageType: nil,
                chatGuid: payload.chat_guid
            )
            sentMessageStore.add(sentMessage)

            let body = SendSuccessBody(guid: messageGuid, status: "sent", dateCreated: String(dateCreated), temp_guid: tempGuid)
            return try jsonResponse(status: .ok, body: body)
        } else {
            logger.error("Failed to send message")
            let body = SendErrorBody(error: "Failed to send message via AppleScript", temp_guid: tempGuid)
            return try jsonResponse(status: .internalServerError, body: body)
        }
    }
    
    // MARK: - POST /typing
    
    routes.post("typing") { req async throws -> HTTPStatus in
        // Parse request body
        let payload = try req.content.decode(TypingPayload.self)
        
        logger.debug("Typing indicator: chat=\(payload.chat_guid), is_typing=\(payload.is_typing)")
        
        // In production, you might forward this to some tracking system
        // For now, just acknowledge
        
        return .ok
    }

    // MARK: - POST /read_receipt

    routes.post("read_receipt") { req async throws -> HTTPStatus in
        let payload = try req.content.decode(ReadReceiptPayload.self)
        let dateRead = Int64(Date().timeIntervalSince1970 * 1000)
        receiptStore.add(chatGuid: payload.chat_guid, messageGuids: payload.message_guids, dateRead: dateRead)
        logger.debug("Read receipt: chat=\(payload.chat_guid), messages=\(payload.message_guids.count)")
        return .ok
    }
}

// MARK: - Request / Response Models

struct SendMessagePayload: Content {
    let chat_guid: String
    let text: String
    /// Optional POSIX paths to files to attach (e.g. temp files written by the client/server).
    let attachment_paths: [String]?
    /// Optional client-generated GUID to correlate request with events and prevent duplicate sends.
    let temp_guid: String?
}

struct SendSuccessBody: Content {
    let guid: String
    let status: String
    let dateCreated: String
    var temp_guid: String?
}

struct SendErrorBody: Content {
    let error: String
    let temp_guid: String?
}

struct TypingPayload: Content {
    let chat_guid: String
    let is_typing: Bool
}

struct ReadReceiptPayload: Content {
    let chat_guid: String
    let message_guids: [String]
}

// MARK: - Helpers

private func jsonResponse<T: Encodable>(status: HTTPStatus, body: T) throws -> Response {
    let data = try JSONEncoder().encode(body)
    let res = Response(status: status)
    res.headers.contentType = .json
    res.body = .init(data: data)
    return res
}

/// Resolve attachment paths to match the official BlueBubbles private-api storage.
/// - Absolute paths are preserved.
/// - `file://` URLs are converted to POSIX paths.
/// - Relative paths (e.g. "uuid/filename") are resolved under
///   ~/Library/Messages/Attachments/BlueBubbles.
private func resolveAttachmentPaths(_ paths: [String]?) -> [String]? {
    guard let paths = paths else { return nil }
    let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    let privateApiDir = "\(homeDir)/Library/Messages/Attachments/BlueBubbles"
    let resolved = paths.compactMap { raw -> String? in
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("file://"), let url = URL(string: normalized), url.isFileURL {
            return url.path
        }
        let expandedTilde = (normalized as NSString).expandingTildeInPath
        if expandedTilde.hasPrefix("/") {
            return (expandedTilde as NSString).standardizingPath
        }
        let joined = (privateApiDir as NSString).appendingPathComponent(expandedTilde)
        return (joined as NSString).standardizingPath
    }
    return resolved.isEmpty ? nil : resolved
}