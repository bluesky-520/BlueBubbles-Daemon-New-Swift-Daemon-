import Foundation
import SQLite3

class MessagesDatabase {
    private let dbPath: String
    private var db: OpaquePointer?
    
    private(set) var lastProcessedRowId: Int64 = 0
    
    init(dbPath: String = Config.messagesDBPath) {
        self.dbPath = dbPath
    }
    
    deinit {
        close()
    }
    
    // MARK: - Database Connection
    
    func open() -> Bool {
        let result = sqlite3_open(dbPath, &db)
        
        if result != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to open database: \(errorMessage)")
            return false
        }
        
        logger.info("Successfully opened Messages database: \(dbPath)")
        return true
    }
    
    func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
            logger.info("Closed Messages database")
        }
    }

    var isOpen: Bool {
        db != nil
    }

    func updateLastProcessedRowId(_ newValue: Int64) {
        lastProcessedRowId = newValue
    }
    
    // MARK: - Chat Operations
    
    func getAllChats() -> [Chat] {
        guard let db = db else {
            logger.error("Database not open")
            return []
        }
        
        var chats: [Chat] = []
        
        let query = """
        SELECT 
            chat.guid AS guid,
            chat.display_name AS display_name,
            MAX(message.date) AS last_message_date,
            COUNT(message.ROWID) AS message_count
        FROM chat
        LEFT JOIN chat_message_join ON chat.ROWID = chat_message_join.chat_id
        LEFT JOIN message ON chat_message_join.message_id = message.ROWID
        GROUP BY chat.ROWID
        ORDER BY last_message_date DESC
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let guid = String(cString: sqlite3_column_text(statement, 0))
                let displayName = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? guid
                let lastMessageDate = sqlite3_column_int64(statement, 2)
                // let messageCount = sqlite3_column_int(statement, 3)
                
                let chat = Chat(
                    guid: guid,
                    displayName: displayName,
                    lastMessageDate: lastMessageDate > 0 ? lastMessageDate : nil,
                    unreadCount: 0,  // TODO: Calculate unread
                    isArchived: false
                )
                
                chats.append(chat)
            }
            
            sqlite3_finalize(statement)
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to fetch chats: \(errorMessage)")
        }
        
        logger.debug("Fetched \(chats.count) chats from database")
        return chats
    }
    
    // MARK: - Message Operations
    
    func getMessages(forChatGuid chatGuid: String, limit: Int = 50, before: Int64? = nil) -> [Message] {
        guard let db = db else {
            logger.error("Database not open")
            return []
        }
        
        var messages: [Message] = []
        
        var query = """
        SELECT 
            message.guid AS guid,
            message.text AS text,
            message.date AS date,
            message.date_read AS date_read,
            message.is_from_me AS is_from_me,
            message.subject AS subject,
            message.error AS error,
            message.associated_message_guid AS associated_message_guid,
            message.associated_message_type AS associated_message_type,
            handle.id AS handle_id,
            handle.id AS handle_address
        FROM message
        JOIN chat_message_join ON message.ROWID = chat_message_join.message_id
        JOIN chat ON chat_message_join.chat_id = chat.ROWID
        LEFT JOIN handle ON message.handle_id = handle.ROWID
        WHERE chat.guid = ?
        """
        
        var params: [Any] = [chatGuid]
        
        if let beforeDate = before {
            query += " AND message.date < ?"
            params.append(beforeDate)
        }
        
        query += """
        ORDER BY message.date DESC
        LIMIT ?
        """
        params.append(limit)
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            // Bind chat GUID
            sqlite3_bind_text(statement, 1, chatGuid, -1, nil)
            
            // Bind before date if present
            if before != nil {
                sqlite3_bind_int64(statement, 2, before!)
            }
            
            // Bind limit
            let limitIndex = before != nil ? 3 : 2
            sqlite3_bind_int(statement, Int32(limitIndex), Int32(limit))
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let guid = String(cString: sqlite3_column_text(statement, 0))
                let text = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let dateCreated = sqlite3_column_int64(statement, 2)
                let dateRead = sqlite3_column_int64(statement, 3)
                let isFromMe = sqlite3_column_int(statement, 4) == 1
                let subject = sqlite3_column_text(statement, 5).map { String(cString: $0) }
                let error = Int(sqlite3_column_int(statement, 6))
                let associatedMessageGuid = sqlite3_column_text(statement, 7).map { String(cString: $0) }
                let associatedMessageType = sqlite3_column_text(statement, 8).map { String(cString: $0) }
                let handleId = sqlite3_column_text(statement, 9).map { String(cString: $0) } ?? ""
                let sender = sqlite3_column_text(statement, 10).map { String(cString: $0) } ?? "Unknown"
                
                let message = Message(
                    guid: guid,
                    text: text,
                    sender: sender,
                    handleId: handleId,
                    dateCreated: dateCreated,
                    dateRead: dateRead > 0 ? dateRead : nil,
                    isFromMe: isFromMe,
                    type: "text",
                    attachments: getAttachments(forMessageGuid: guid),
                    subject: subject,
                    error: error != 0 ? error : nil,
                    associatedMessageGuid: associatedMessageGuid,
                    associatedMessageType: associatedMessageType,
                    chatGuid: chatGuid
                )
                
                messages.append(message)
            }
            
            sqlite3_finalize(statement)
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to fetch messages for chat \(chatGuid): \(errorMessage)")
        }
        
        // Reverse to get chronological order
        return messages.reversed()
    }
    
    func getAttachments(forMessageGuid messageGuid: String) -> [Attachment] {
        guard let db = db else { return [] }
        
        var attachments: [Attachment] = []
        
        let query = """
        SELECT 
            attachment.guid AS guid,
            attachment.filename AS filename,
            attachment.mime_type AS mime_type,
            attachment.transfer_name AS transfer_name,
            attachment.total_bytes AS total_bytes
        FROM attachment
        JOIN message_attachment_join ON attachment.ROWID = message_attachment_join.attachment_id
        JOIN message ON message_attachment_join.message_id = message.ROWID
        WHERE message.guid = ?
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, messageGuid, -1, nil)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let guid = String(cString: sqlite3_column_text(statement, 0))
                let filename = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                let mimeType = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "application/octet-stream"
                let transferName = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                let totalBytes = sqlite3_column_int64(statement, 4)
                
                let attachment = Attachment(
                    guid: guid,
                    filename: filename,
                    mimeType: mimeType,
                    transferName: transferName,
                    totalBytes: totalBytes
                )
                
                attachments.append(attachment)
            }
            
            sqlite3_finalize(statement)
        }
        
        return attachments
    }
    
    // MARK: - Polling for New Messages
    
    func getNewMessages(since lastRowId: Int64) -> ([Message], Int64) {
        guard let db = db else { return ([], lastRowId) }
        
        var messages: [Message] = []
        var maxRowId = lastRowId
        
        let query = """
        SELECT 
            message.ROWID,
            message.guid,
            message.text,
            message.date,
            message.date_read,
            message.is_from_me,
            handle.address,
            handle.id,
            chat.guid AS chat_guid
        FROM message
        LEFT JOIN handle ON message.handle_id = handle.ROWID
        JOIN chat_message_join ON message.ROWID = chat_message_join.message_id
        JOIN chat ON chat_message_join.chat_id = chat.ROWID
        WHERE message.ROWID > ?
        ORDER BY message.ROWID ASC
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, lastRowId)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let rowId = sqlite3_column_int64(statement, 0)
                let guid = String(cString: sqlite3_column_text(statement, 1))
                let text = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let dateCreated = sqlite3_column_int64(statement, 3)
                let dateRead = sqlite3_column_int64(statement, 4)
                let isFromMe = sqlite3_column_int(statement, 5) == 1
                let sender = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? "Unknown"
                let handleId = sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? ""
                let chatGuid = String(cString: sqlite3_column_text(statement, 8))
                
                let message = Message(
                    guid: "\(chatGuid):\(guid)",
                    text: text,
                    sender: sender,
                    handleId: handleId,
                    dateCreated: dateCreated,
                    dateRead: dateRead > 0 ? dateRead : nil,
                    isFromMe: isFromMe,
                    type: "text",
                    chatGuid: chatGuid
                )
                
                messages.append(message)
                maxRowId = max(maxRowId, rowId)
            }
            
            sqlite3_finalize(statement)
        }
        
        if !messages.isEmpty {
            logger.debug("Found \(messages.count) new messages since row \(lastRowId)")
        }
        
        return (messages, maxRowId)
    }
    
    // MARK: - Handle Lookup
    
    func getHandle(forId handleId: Int64) -> Handle? {
        guard let db = db else { return nil }
        
        let query = "SELECT ROWID, id, service, uncanonicalized_id FROM handle WHERE ROWID = ?"
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, handleId)
            
            if sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let address = String(cString: sqlite3_column_text(statement, 1))
                let service = String(cString: sqlite3_column_text(statement, 2))
                let uncanonicalizedId = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                
                let handle = Handle(
                    id: id,
                    address: address,
                    service: service,
                    uncanonicalizedId: uncanonicalizedId
                )
                
                sqlite3_finalize(statement)
                return handle
            }
            
            sqlite3_finalize(statement)
        }
        
        return nil
    }
}