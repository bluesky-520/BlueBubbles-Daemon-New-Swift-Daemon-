import Foundation
import Logging

struct Config {
    // HTTP Server Configuration
    static let httpHost = "127.0.0.1"
    static let httpPort: Int = 8081
    
    // Messages Database Path
    static var messagesDBPath: String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(homeDir)/Library/Messages/chat.db"
    }
    
    // Polling Configuration
    static let pollInterval: TimeInterval = 1.0  // seconds
    
    // Logging
    static let logLevel: String = "info"  // debug, info, warning, error

    static var logLevelValue: Logger.Level {
        switch logLevel.lowercased() {
        case "trace":
            return .trace
        case "debug":
            return .debug
        case "warning", "warn":
            return .warning
        case "error":
            return .error
        default:
            return .info
        }
    }
    
    // Security
    static let requireAuth = false  // Set to true in production
    static let authToken = "your-secret-token"  // Change this!
}