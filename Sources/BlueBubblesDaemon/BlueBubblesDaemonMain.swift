import Vapor
import Logging

@main
struct BlueBubblesDaemon {
    static func main() throws {
        logger.info("🚀 Starting BlueBubbles Daemon...")
        
        // Initialize services
        let database = MessagesDatabase()
        let appleScriptSender = AppleScriptSender()
        let messagePoller = MessagePoller(database: database)
        let contactsController = ContactsController()
        
        // Open database
        guard database.open() else {
            logger.error("Failed to open Messages database. Exiting.")
            return
        }
        
        // Start poller
        messagePoller.start()
        
        // Setup Vapor app
        let env = try Environment.detect()
        let app = Application(env)
        defer { app.shutdown() }

        // Reduce noisy request logs if desired
        app.logger.logLevel = Config.logLevelValue
        
        try healthRoutes(app)
        try contactsRoutes(app, contactsController: contactsController)
        try chatRoutes(app, database: database)
        try messageRoutes(app, database: database)
        try sendRoutes(app, appleScriptSender: appleScriptSender)

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
        
        // Start server
        try app.run()
    }
}
