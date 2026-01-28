import Foundation

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
    
    // Security
    static let requireAuth = false  // Set to true in production
    static let authToken = "your-secret-token"  // Change this!
}