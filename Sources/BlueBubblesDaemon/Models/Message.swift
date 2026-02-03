import Vapor

struct Message: Content, Equatable {
    let guid: String
    let text: String?
    let sender: String
    let handleId: String
    let dateCreated: Int64
    let dateRead: Int64?
    let isFromMe: Bool
    let type: String
    let attachments: [Attachment]?
    let subject: String?
    let error: Int?
    let associatedMessageGuid: String?
    let associatedMessageType: String?
    let chatGuid: String?
    
    // MARK: - Initialization
    
    init(
        guid: String,
        text: String?,
        sender: String,
        handleId: String,
        dateCreated: Int64,
        dateRead: Int64? = nil,
        isFromMe: Bool = false,
        type: String = "text",
        attachments: [Attachment]? = nil,
        subject: String? = nil,
        error: Int? = nil,
        associatedMessageGuid: String? = nil,
        associatedMessageType: String? = nil,
        chatGuid: String? = nil
    ) {
        self.guid = guid
        self.text = text
        self.sender = sender
        self.handleId = handleId
        self.dateCreated = dateCreated
        self.dateRead = dateRead
        self.isFromMe = isFromMe
        self.type = type
        self.attachments = attachments
        self.subject = subject
        self.error = error
        self.associatedMessageGuid = associatedMessageGuid
        self.associatedMessageType = associatedMessageType
        self.chatGuid = chatGuid
    }
}

struct Attachment: Content, Equatable {
    let guid: String
    let filename: String
    let uti: String?
    let mimeType: String
    let transferName: String?
    let totalBytes: Int64
    /// Optional ROWID for BlueBubbles client compatibility (originalROWID).
    let originalROWID: Int64?

    init(guid: String, filename: String, uti: String? = nil, mimeType: String, transferName: String?, totalBytes: Int64, originalROWID: Int64? = nil) {
        self.guid = guid
        self.filename = filename
        self.uti = uti
        self.mimeType = mimeType
        self.transferName = transferName
        self.totalBytes = totalBytes
        self.originalROWID = originalROWID
    }

    enum CodingKeys: String, CodingKey {
        case guid, filename, mimeType, transferName, totalBytes, uti
        case originalROWID
    }
}