import Vapor

func sendRoutes(_ routes: RoutesBuilder, appleScriptSender: AppleScriptSender, database: MessagesDatabase, sentMessageStore: SentMessageStore, sendCache: SendCache) throws {

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
        let success = appleScriptSender.sendMessage(
            toChatWithGuid: payload.chat_guid,
            text: payload.text,
            chatIdentifier: chatIdentifier,
            recipients: recipients,
            attachmentPaths: payload.attachment_paths
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

// MARK: - Helpers

private func jsonResponse<T: Encodable>(status: HTTPStatus, body: T) throws -> Response {
    let data = try JSONEncoder().encode(body)
    var res = Response(status: status)
    res.headers.contentType = .json
    res.body = .init(data: data)
    return res
}