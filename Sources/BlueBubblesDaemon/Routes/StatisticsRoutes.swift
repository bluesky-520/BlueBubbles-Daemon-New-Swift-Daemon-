import Vapor

/// Statistics routes matching official BlueBubbles server API format
func statisticsRoutes(_ routes: RoutesBuilder, database: MessagesDatabase) throws {
    
    // GET /statistics/totals - { handles, messages, chats, attachments }
    routes.get("statistics", "totals") { req async throws -> [String: Int] in
        let onlyParam = try? req.query.get(String.self, at: "only")
        let only: [String]? = onlyParam.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        return database.getStatisticsTotals(only: only)
    }
    
    // GET /statistics/media - { images, videos, locations }
    routes.get("statistics", "media") { req async throws -> [String: Int] in
        let onlyParam = try? req.query.get(String.self, at: "only")
        let only: [String]? = onlyParam.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        return database.getStatisticsMedia(only: only)
    }
}
