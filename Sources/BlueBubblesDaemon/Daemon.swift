import Foundation

class Daemon {
    private let database: MessagesDatabase
    private let appleScriptSender: AppleScriptSender
    private let messagePoller: MessagePoller
    
    private var isRunning = false
    
    init() {
        self.database = MessagesDatabase()
        self.appleScriptSender = AppleScriptSender()
        self.messagePoller = MessagePoller(database: database)
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Start/Stop
    
    func start() {
        guard !isRunning else {
            logger.warning("Daemon already running")
            return
        }
        
        logger.info("Starting BlueBubbles Daemon...")
        
        // Open database
        guard database.open() else {
            logger.error("Failed to open Messages database")
            return
        }
        
        // Start poller
        messagePoller.start()
        
        isRunning = true
        logger.info("Daemon started successfully")
    }
    
    func stop() {
        guard isRunning else { return }
        
        logger.info("Stopping BlueBubbles Daemon...")
        
        // Stop poller
        messagePoller.stop()
        
        // Close database
        database.close()
        
        isRunning = false
        logger.info("Daemon stopped")
    }
    
    // MARK: - Public Interface
    
    var chats: [Chat] {
        return database.getAllChats()
    }
    
    func messages(forChatGuid chatGuid: String, limit: Int = 50, before: Int64? = nil) -> [Message] {
        return database.getMessages(forChatGuid: chatGuid, limit: limit, before: before)
    }
    
    func sendMessage(toChatWithGuid chatGuid: String, text: String) -> Bool {
        return appleScriptSender.sendMessage(toChatWithGuid: chatGuid, text: text)
    }
}