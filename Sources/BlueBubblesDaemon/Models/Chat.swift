import Vapor

struct Chat: Content, Equatable {
    let guid: String
    let displayName: String
    let lastMessageDate: Int64?
    let unreadCount: Int
    let isArchived: Bool
    
    // MARK: - Initialization
    
    init(
        guid: String,
        displayName: String,
        lastMessageDate: Int64? = nil,
        unreadCount: Int = 0,
        isArchived: Bool = false
    ) {
        self.guid = guid
        self.displayName = displayName
        self.lastMessageDate = lastMessageDate
        self.unreadCount = unreadCount
        self.isArchived = isArchived
    }
}