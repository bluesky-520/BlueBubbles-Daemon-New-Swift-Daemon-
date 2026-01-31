import Vapor

func sendRoutes(_ routes: RoutesBuilder, appleScriptSender: AppleScriptSender) throws {
    
    // MARK: - POST /send
    
    routes.post("send") { req async throws -> [String: String] in
        // Parse request body
        let payload = try req.content.decode(SendMessagePayload.self)
        
        logger.info("Sending message to chat: \(payload.chat_guid)")
        
        // Send via AppleScript
        let success = appleScriptSender.sendMessage(toChatWithGuid: payload.chat_guid, text: payload.text)
        
        if success {
            logger.info("Message sent successfully")
            
            // Generate a temporary GUID for the message
            let messageGuid = UUID().uuidString
            
            return [
                "guid": messageGuid,
                "status": "sent"
            ]
        } else {
            logger.error("Failed to send message")
            throw Abort(.internalServerError, reason: "Failed to send message via AppleScript")
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

// MARK: - Request Models

struct SendMessagePayload: Content {
    let chat_guid: String
    let text: String
}

struct TypingPayload: Content {
    let chat_guid: String
    let is_typing: Bool
}