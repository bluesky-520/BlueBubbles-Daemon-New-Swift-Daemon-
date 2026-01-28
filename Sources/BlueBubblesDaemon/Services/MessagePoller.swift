import Foundation

class MessagePoller {
    private let database: MessagesDatabase
    private var timer: Timer?
    private var isRunning = false
    
    // Callback for new messages
    var onNewMessages: (([Message]) -> Void)?
    
    init(database: MessagesDatabase) {
        self.database = database
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Start/Stop
    
    func start() {
        guard !isRunning else {
            logger.warning("Poller already running")
            return
        }
        
        isRunning = true
        logger.info("Starting message poller (interval: \(Config.pollInterval)s)")
        
        timer = Timer.scheduledTimer(
            withTimeInterval: Config.pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.pollForNewMessages()
        }
        
        // Run immediately on start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.pollForNewMessages()
        }
    }
    
    func stop() {
        guard isRunning else { return }
        
        timer?.invalidate()
        timer = nil
        isRunning = false
        
        logger.info("Message poller stopped")
    }
    
    // MARK: - Polling Logic
    
    private func pollForNewMessages() {
        guard database.isOpen else {
            logger.warning("Database not open, skipping poll")
            return
        }
        
        let (newMessages, newMaxRowId) = database.getNewMessages(since: database.lastProcessedRowId)
        
        if !newMessages.isEmpty {
            logger.info("Detected \(newMessages.count) new messages")
            
            // Notify subscribers
            onNewMessages?(newMessages)
            
            // Update last processed row ID
            database.updateLastProcessedRowId(newMaxRowId)
        }
    }
}