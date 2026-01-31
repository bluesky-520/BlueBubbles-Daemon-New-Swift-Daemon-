import Vapor

func chatRoutes(_ routes: RoutesBuilder, database: MessagesDatabase) throws {
    
    // MARK: - GET /chats
    
    routes.get("chats") { req async throws -> [Chat] in
        logger.info("Fetching all chats")
        
        let chats = database.getAllChats()
        
        logger.debug("Returning \(chats.count) chats")
        return chats
    }
    
    // MARK: - GET /chats/:chatGuid
    
    routes.get("chats", ":chatGuid") { req async throws -> Chat in
        let chatGuid = req.parameters.get("chatGuid")!
        
        logger.info("Fetching chat: \(chatGuid)")
        
        let chats = database.getAllChats()
        guard let chat = chats.first(where: { $0.guid == chatGuid }) else {
            throw Abort(.notFound, reason: "Chat not found")
        }
        
        return chat
    }
}