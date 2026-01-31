import Vapor

struct Chat: Content, Equatable {
    let guid: String
    let displayName: String
    let lastMessageDate: Int64?
    let lastMessageText: String?
    let unreadCount: Int
    let isArchived: Bool

    init(
        guid: String,
        displayName: String,
        lastMessageDate: Int64? = nil,
        lastMessageText: String? = nil,
        unreadCount: Int = 0,
        isArchived: Bool = false
    ) {
        self.guid = guid
        self.displayName = displayName
        self.lastMessageDate = lastMessageDate
        self.lastMessageText = lastMessageText
        self.unreadCount = unreadCount
        self.isArchived = isArchived
    }
}