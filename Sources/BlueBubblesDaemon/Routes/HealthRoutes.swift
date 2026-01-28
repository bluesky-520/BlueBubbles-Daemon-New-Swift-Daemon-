import Vapor

struct HealthResponse: Content {
    let status: String
    let timestamp: Double
    let databaseAccessible: Bool
    let uptime: TimeInterval
}

func healthRoutes(_ app: Application) throws {
    
    // MARK: - GET /ping
    
    app.get("ping") { req async throws -> HTTPStatus in
        logger.debug("Health check requested")
        return .ok
    }
    
    // MARK: - GET /health
    
    app.get("health") { req async throws -> HealthResponse in
        let databaseAccessible = FileManager.default.fileExists(atPath: Config.messagesDBPath)
        
        return HealthResponse(
            status: "ok",
            timestamp: Date().timeIntervalSince1970 * 1000,
            databaseAccessible: databaseAccessible,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }
}