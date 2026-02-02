import Vapor
import Logging

@main
struct BlueBubblesDaemon {
    static func main() async throws {
        logger.info("🚀 Starting BlueBubbles Daemon...")
        
        // Initialize services
        let database = MessagesDatabase()
        let appleScriptSender = AppleScriptSender()
        let messagePoller = MessagePoller(database: database)
        let contactsController = ContactsController()
        let sentMessageStore = SentMessageStore()
        let incomingMessageStore = IncomingMessageStore()
        let sendCache = SendCache()
        let receiptStore = ReceiptStore()

        // Open database
        guard database.open() else {
            logger.error("Failed to open Messages database. Exiting.")
            return
        }

        // Push incoming messages to SSE
        messagePoller.onNewMessages = { messages in
            for message in messages {
                incomingMessageStore.add(message)
            }
        }

        // Start poller
        messagePoller.start()

        // Setup Vapor app
        let env = try Environment.detect()
        let app = try await Application.make(env)

        // Reduce noisy request logs if desired
        app.logger.logLevel = Config.logLevelValue

        try healthRoutes(app)
        try statisticsRoutes(app, database: database)
        try contactsRoutes(app, contactsController: contactsController)
        try eventsRoutes(app, contactsController: contactsController, sentMessageStore: sentMessageStore, incomingMessageStore: incomingMessageStore)
        try chatRoutes(app, database: database)
        try messageRoutes(app, database: database, sentMessageStore: sentMessageStore, receiptStore: receiptStore)
        try sendRoutes(app, appleScriptSender: appleScriptSender, database: database, sentMessageStore: sentMessageStore, sendCache: sendCache, receiptStore: receiptStore)

        // Configure server
        app.http.server.configuration.hostname = Config.httpHost
        app.http.server.configuration.port = Config.httpPort
        
        // Error handling
        app.middleware.use(ErrorMiddleware { req, error in
            logger.error("HTTP error: \(error.localizedDescription)")
            return Response(status: .internalServerError)
        })
        
        // Startup message
        logger.info("""
        ╔═══════════════════════════════════════════════════════════╗
        ║  BlueBubbles Daemon Started Successfully                  ║
        ║                                                           ║
        ║  HTTP Server: http://\(Config.httpHost):\(Config.httpPort)              ║
        ║  Database: \(Config.messagesDBPath)      ║
        ║  Poll Interval: \(Config.pollInterval)s                              ║
        ║                                                           ║
        ║  Ready to accept connections from Node.js bridge          ║
        ╚═══════════════════════════════════════════════════════════╝
        """)
        
        // Start server (runs until interrupted)
        try await app.execute()
        try await app.asyncShutdown()
    }
}
