import Vapor

struct MessageUpdatesResponse: Content {
    let messages: [Message]
    let typing: [String]
    let receipts: [String]
}

func messageRoutes(_ routes: RoutesBuilder, database: MessagesDatabase, sentMessageStore: SentMessageStore) throws {

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
        let since = (try? req.query.get(Int64.self, at: "since")) ?? 0
        
        logger.debug("Fetching updates since: \(since)")
        
        // Get new messages since timestamp
        // Note: This is a simplified version - in production you'd track by timestamp
        let allChats = database.getAllChats()
        var allMessages: [Message] = []
        
        for chat in allChats {
            let messages = database.getMessages(forChatGuid: chat.guid, limit: 100)
            let recentMessages = messages.filter { $0.dateCreated > since }
            allMessages.append(contentsOf: recentMessages)
        }
        
        // Sort by date
        allMessages.sort { $0.dateCreated < $1.dateCreated }
        
        logger.debug("Found \(allMessages.count) updates")
        
        return MessageUpdatesResponse(
            messages: allMessages,
            typing: [],
            receipts: []
        )
    }
}