import Foundation
import SQLite3

/// SQLite destructor that copies the string (pointer valid only during bind call)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

class MessagesDatabase {
    private let dbPath: String
    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.bluebubbles.messagesdb.serial")
    
    private(set) var lastProcessedRowId: Int64 = 0
    
    init(dbPath: String = Config.messagesDBPath) {
        self.dbPath = dbPath
    }
    
    deinit {
        close()
    }
    
    // MARK: - Database Connection
    
    func open() -> Bool {
        dbQueue.sync {
            openUnlocked()
        }
    }
    
    private func openUnlocked() -> Bool {
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
        dbQueue.sync {
            closeUnlocked()
        }
    }
    
    private func closeUnlocked() {
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
        dbQueue.sync {
            getAllChatsUnlocked()
        }
    }
    
    /// True when last message has no text worth showing (nil, empty, whitespace, or only ￼ placeholder).
    private func lastMessageHasNoMeaningfulText(_ text: String?) -> Bool {
        guard let s = text else { return true }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let withoutPlaceholder = trimmed.replacingOccurrences(of: "\u{FFFC}", with: "") // object replacement char ￼
        return withoutPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns [chatGuid: [ChatParticipant]] for all chats (one query).
    private func getAllParticipantsByChatGuidUnlocked() -> [String: [ChatParticipant]] {
        guard let db = db else { return [:] }
        let query = """
        SELECT chat.guid, handle.id
        FROM chat
        JOIN chat_handle_join ON chat.ROWID = chat_handle_join.chat_id
        JOIN handle ON handle.ROWID = chat_handle_join.handle_id
        ORDER BY chat.ROWID, chat_handle_join.handle_id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: [ChatParticipant]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let guid = String(cString: sqlite3_column_text(statement, 0))
            let address = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            result[guid, default: []].append(ChatParticipant(address: address))
        }
        return result
    }
    
    private func getAllChatsUnlocked() -> [Chat] {
        guard let db = db else {
            logger.error("Database not open")
            return []
        }
        
        let participantsByGuid = getAllParticipantsByChatGuidUnlocked()
        var chats: [Chat] = []
        
        let query = """
        SELECT 
            chat.guid AS guid,
            chat.display_name AS display_name,
            MAX(message.date) AS last_message_date,
            (SELECT message.text FROM chat_message_join cmj2
             JOIN message ON cmj2.message_id = message.ROWID
             WHERE cmj2.chat_id = chat.ROWID
             ORDER BY message.date DESC LIMIT 1) AS last_message_text,
            (SELECT message.attributedBody FROM chat_message_join cmj2
             JOIN message ON cmj2.message_id = message.ROWID
             WHERE cmj2.chat_id = chat.ROWID
             ORDER BY message.date DESC LIMIT 1) AS last_message_attributed_body,
            (SELECT COUNT(*) FROM message_attachment_join maj
             WHERE maj.message_id = (SELECT message.ROWID FROM chat_message_join cmj3
              JOIN message ON cmj3.message_id = message.ROWID
              WHERE cmj3.chat_id = chat.ROWID
              ORDER BY message.date DESC LIMIT 1)) AS last_message_attachment_count,
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
                var lastMessageText = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                let lastMessageAttributedBody: Data? = {
                    guard let blob = sqlite3_column_blob(statement, 4) else { return nil }
                    let bytes = sqlite3_column_bytes(statement, 4)
                    guard bytes > 0 else { return nil }
                    return Data(bytes: blob, count: Int(bytes))
                }()
                if (lastMessageText == nil || lastMessageText?.isEmpty == true),
                   let extracted = AttributedBodyDecoder.extractText(from: lastMessageAttributedBody) {
                    lastMessageText = extracted
                }
                let lastMessageAttachmentCount = Int(sqlite3_column_int(statement, 5))
                if lastMessageHasNoMeaningfulText(lastMessageText),
                   lastMessageAttachmentCount > 0 {
                    lastMessageText = lastMessageAttachmentCount == 1
                        ? "Attachment: 1 Photo"
                        : "Attachment: \(lastMessageAttachmentCount) Photos"
                }
                
                let participants = participantsByGuid[guid] ?? []
                
                let chat = Chat(
                    guid: guid,
                    displayName: displayName,
                    lastMessageDate: lastMessageDate > 0 ? lastMessageDate : nil,
                    lastMessageText: lastMessageText,
                    unreadCount: 0,
                    isArchived: false,
                    participants: participants
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
    
    /// Returns the chat_identifier for AppleScript "chat id" (e.g. iMessage;-;+1234567890).
    func getChatIdentifier(forChatGuid chatGuid: String) -> String? {
        dbQueue.sync {
            getChatIdentifierUnlocked(forChatGuid: chatGuid)
        }
    }
    
    private func getChatIdentifierUnlocked(forChatGuid chatGuid: String) -> String? {
        guard let db = db else { return nil }
        let query = "SELECT chat_identifier FROM chat WHERE guid = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, chatGuid, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: cString)
    }
    
    /// Returns participant handles for a chat (for buddy-based send fallback).
    func getChatRecipients(forChatGuid chatGuid: String) -> [String] {
        dbQueue.sync {
            getChatRecipientsUnlocked(forChatGuid: chatGuid)
        }
    }
    
    private func getChatRecipientsUnlocked(forChatGuid chatGuid: String) -> [String] {
        guard let db = db else { return [] }
        let query = """
        SELECT handle.id FROM handle
        JOIN chat_handle_join ON chat_handle_join.handle_id = handle.ROWID
        JOIN chat ON chat.ROWID = chat_handle_join.chat_id
        WHERE chat.guid = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, chatGuid, -1, nil)
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                result.append(String(cString: cString))
            }
        }
        return result
    }
    
    // MARK: - Message Operations
    
    func getMessages(forChatGuid chatGuid: String, limit: Int = 50, before: Int64? = nil) -> [Message] {
        dbQueue.sync {
            getMessagesUnlocked(forChatGuid: chatGuid, limit: limit, before: before)
        }
    }
    
    private func getMessagesUnlocked(forChatGuid chatGuid: String, limit: Int = 50, before: Int64? = nil) -> [Message] {
        guard let db = db else {
            logger.error("Database not open")
            return []
        }
        
        var messages: [Message] = []
        
        // Step 1: Get chat.ROWID for this guid (avoids string binding in main query)
        var getChatStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ROWID FROM chat WHERE guid = ? LIMIT 1", -1, &getChatStmt, nil) == SQLITE_OK else {
            logger.error("Failed to prepare chat ROWID query")
            return []
        }
        defer { sqlite3_finalize(getChatStmt) }
        
        _ = chatGuid.withCString { cStr in
            sqlite3_bind_text(getChatStmt, 1, cStr, -1, SQLITE_TRANSIENT)
        }
        guard sqlite3_step(getChatStmt) == SQLITE_ROW else {
            logger.info("No chat found for guid: \(chatGuid)")
            return []
        }
        let chatRowId = sqlite3_column_int64(getChatStmt, 0)
        
        // Step 2: Get messages by chat ROWID (integer only, no string binding)
        // attributedBody: on Ventura+, text is stored here when message.text is NULL
        var query = """
        SELECT 
            message.guid,
            message.text,
            message.attributedBody,
            message.date,
            message.date_read,
            message.is_from_me,
            message.subject,
            message.error,
            message.associated_message_guid,
            message.associated_message_type,
            COALESCE(handle.id, '') AS handle_id
        FROM message
        JOIN chat_message_join ON message.ROWID = chat_message_join.message_id
        LEFT JOIN handle ON message.handle_id = handle.ROWID
        WHERE chat_message_join.chat_id = \(chatRowId)
        """
        if let beforeDate = before {
            query += " AND message.date < \(beforeDate)"
        }
        query += " ORDER BY message.date DESC LIMIT \(limit)"
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            logger.error("Failed to prepare messages query: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(statement) }
        
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guidPtr = sqlite3_column_text(statement, 0) else { continue }
            let guid = String(cString: guidPtr)
            var text = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let attributedBodyData: Data? = {
                guard let blob = sqlite3_column_blob(statement, 2) else { return nil }
                let bytes = sqlite3_column_bytes(statement, 2)
                guard bytes > 0 else { return nil }
                return Data(bytes: blob, count: Int(bytes))
            }()
            let dateCreated = sqlite3_column_int64(statement, 3)
            let dateRead = sqlite3_column_int64(statement, 4)
            let isFromMe = sqlite3_column_int(statement, 5) == 1
            let subject = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            let error = Int(sqlite3_column_int(statement, 7))
            let associatedMessageGuid = sqlite3_column_text(statement, 8).map { String(cString: $0) }
            let associatedMessageType = sqlite3_column_text(statement, 9).map { String(cString: $0) }
            let handleId = sqlite3_column_text(statement, 10).map { String(cString: $0) } ?? ""
            
            // Fallback: on Ventura+, text is often in attributedBody when message.text is NULL
            if (text == nil || text?.isEmpty == true), let extracted = AttributedBodyDecoder.extractText(from: attributedBodyData) {
                text = extracted
            }
            
            let message = Message(
                guid: guid,
                text: text,
                sender: handleId.isEmpty ? "Unknown" : handleId,
                handleId: handleId,
                dateCreated: dateCreated,
                dateRead: dateRead > 0 ? dateRead : nil,
                isFromMe: isFromMe,
                type: "text",
                attachments: getAttachmentsUnlocked(forMessageGuid: guid),
                subject: subject,
                error: error != 0 ? error : nil,
                associatedMessageGuid: associatedMessageGuid,
                associatedMessageType: associatedMessageType,
                chatGuid: chatGuid
            )
            messages.append(message)
        }
        
        return messages.reversed()
    }
    
    func getAttachments(forMessageGuid messageGuid: String) -> [Attachment] {
        dbQueue.sync {
            getAttachmentsUnlocked(forMessageGuid: messageGuid)
        }
    }
    
    private func getAttachmentsUnlocked(forMessageGuid messageGuid: String) -> [Attachment] {
        guard let db = db else { return [] }
        
        var attachments: [Attachment] = []
        
        // Match official BlueBubbles: join message_attachment_join to get attachments for this message.
        // Use COALESCE for uti (older DBs may not have it); guard NULL guid.
        let query = """
        SELECT 
            attachment.ROWID AS attachment_rowid,
            attachment.guid AS guid,
            attachment.filename AS filename,
            COALESCE(attachment.uti, '') AS uti,
            COALESCE(attachment.mime_type, 'application/octet-stream') AS mime_type,
            attachment.transfer_name AS transfer_name,
            attachment.total_bytes AS total_bytes
        FROM attachment
        JOIN message_attachment_join ON attachment.ROWID = message_attachment_join.attachment_id
        JOIN message ON message_attachment_join.message_id = message.ROWID
        WHERE message.guid = ?
        """
        
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, messageGuid, -1, SQLITE_TRANSIENT)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let guidPtr = sqlite3_column_text(statement, 1) else { continue }
                let guid = String(cString: guidPtr)
                let filename = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                let uti = sqlite3_column_text(statement, 3).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
                let mimeType = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "application/octet-stream"
                let transferName = sqlite3_column_text(statement, 5).map { String(cString: $0) }
                let totalBytes = sqlite3_column_int64(statement, 6)
                let rowid = sqlite3_column_int64(statement, 0)
                
                let attachment = Attachment(
                    guid: guid,
                    filename: filename,
                    uti: uti,
                    mimeType: mimeType,
                    transferName: transferName,
                    totalBytes: totalBytes,
                    originalROWID: rowid
                )
                
                attachments.append(attachment)
            }
        }
        
        return attachments
    }

    /// Returns attachment metadata and resolved file path for streaming. Path is nil if file not found.
    func getAttachmentByGuid(_ attachmentGuid: String) -> (attachment: Attachment, path: String)? {
        dbQueue.sync {
            getAttachmentByGuidUnlocked(attachmentGuid)
        }
    }

    private func getAttachmentByGuidUnlocked(_ attachmentGuid: String) -> (attachment: Attachment, path: String)? {
        guard let db = db else { return nil }
        let query = """
        SELECT ROWID, guid, filename, COALESCE(uti, '') AS uti, COALESCE(mime_type, 'application/octet-stream') AS mime_type, transfer_name, total_bytes
        FROM attachment WHERE guid = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, attachmentGuid, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let rowid = sqlite3_column_int64(statement, 0)
        guard let guidPtr = sqlite3_column_text(statement, 1) else { return nil }
        let guid = String(cString: guidPtr)
        let filename = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
        let uti = sqlite3_column_text(statement, 3).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        let mimeType = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "application/octet-stream"
        let transferName = sqlite3_column_text(statement, 5).map { String(cString: $0) }
        let totalBytes = sqlite3_column_int64(statement, 6)
        let attachment = Attachment(
            guid: guid,
            filename: filename,
            uti: uti,
            mimeType: mimeType,
            transferName: transferName,
            totalBytes: totalBytes,
            originalROWID: rowid
        )
        let path = resolveAttachmentPath(filename: filename, transferName: transferName, guid: guid)
        return (attachment, path)
    }

    /// Resolve file path: use filename if absolute and exists; else try Messages/Attachments/XX/guid/filename.
    /// Tries: absolute filename, Attachments/first2/guid/name, Attachments/guid/name (fallback), then best guess.
    private func resolveAttachmentPath(filename: String, transferName: String?, guid: String) -> String {
        let fm = FileManager.default
        if !filename.isEmpty && filename.hasPrefix("/") && fm.fileExists(atPath: filename) {
            return filename
        }
        let messagesDir = (dbPath as NSString).deletingLastPathComponent
        let first2 = guid.count >= 2 ? String(guid.prefix(2)) : "00"
        let name = !filename.isEmpty ? (filename as NSString).lastPathComponent : (transferName ?? guid)
        // Standard layout: Attachments/at/at_1_XXX/FileName.png
        let withFirst2 = (messagesDir as NSString).appendingPathComponent("Attachments/\(first2)/\(guid)/\(name)")
        if fm.fileExists(atPath: withFirst2) {
            return withFirst2
        }
        // Some layouts use Attachments/guid/name without the first2 segment
        let withoutFirst2 = (messagesDir as NSString).appendingPathComponent("Attachments/\(guid)/\(name)")
        if fm.fileExists(atPath: withoutFirst2) {
            return withoutFirst2
        }
        if !filename.isEmpty {
            let byFilename = (messagesDir as NSString).appendingPathComponent("Attachments/\(first2)/\(guid)/\(filename)")
            if fm.fileExists(atPath: byFilename) { return byFilename }
        }
        return withFirst2
    }
    
    // MARK: - Polling for New Messages
    
    func getNewMessages(since lastRowId: Int64) -> ([Message], Int64) {
        dbQueue.sync {
            getNewMessagesUnlocked(since: lastRowId)
        }
    }
    
    private func getNewMessagesUnlocked(since lastRowId: Int64) -> ([Message], Int64) {
        guard let db = db else { return ([], lastRowId) }
        
        var messages: [Message] = []
        var maxRowId = lastRowId
        
        let query = """
        SELECT 
            message.ROWID,
            message.guid,
            message.text,
            message.attributedBody,
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
                var text = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let attributedBodyData: Data? = {
                    guard let blob = sqlite3_column_blob(statement, 3) else { return nil }
                    let bytes = sqlite3_column_bytes(statement, 3)
                    guard bytes > 0 else { return nil }
                    return Data(bytes: blob, count: Int(bytes))
                }()
                let dateCreated = sqlite3_column_int64(statement, 4)
                let dateRead = sqlite3_column_int64(statement, 5)
                let isFromMe = sqlite3_column_int(statement, 6) == 1
                let sender = sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? "Unknown"
                let handleId = sqlite3_column_text(statement, 8).map { String(cString: $0) } ?? ""
                let chatGuid = String(cString: sqlite3_column_text(statement, 9))
                
                if (text == nil || text?.isEmpty == true), let extracted = AttributedBodyDecoder.extractText(from: attributedBodyData) {
                    text = extracted
                }
                
                let attachments = getAttachmentsUnlocked(forMessageGuid: guid)
                let message = Message(
                    guid: "\(chatGuid):\(guid)",
                    text: text,
                    sender: sender,
                    handleId: handleId,
                    dateCreated: dateCreated,
                    dateRead: dateRead > 0 ? dateRead : nil,
                    isFromMe: isFromMe,
                    type: "text",
                    attachments: attachments.isEmpty ? nil : attachments,
                    subject: nil,
                    error: nil,
                    associatedMessageGuid: nil,
                    associatedMessageType: nil,
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
    
    // MARK: - Statistics (matches official BlueBubbles server format)
    
    /// Returns database totals: handles, messages, chats, attachments.
    /// Supports `only` filter: handle, message, chat, attachment (comma-separated).
    func getStatisticsTotals(only: [String]? = nil) -> [String: Int] {
        dbQueue.sync {
            getStatisticsTotalsUnlocked(only: only)
        }
    }
    
    private func getStatisticsTotalsUnlocked(only: [String]?) -> [String: Int] {
        guard let db = db else { return [:] }
        let items = only ?? ["handle", "message", "chat", "attachment"]
        let set = Set(items.map { $0.lowercased().replacingOccurrences(of: "s$", with: "", options: .regularExpression) })
        var result: [String: Int] = [:]
        
        if set.contains("handle") {
            if let count = runCountQuery(db, "SELECT COUNT(*) FROM handle") {
                result["handles"] = count
            }
        }
        if set.contains("message") {
            if let count = runCountQuery(db, "SELECT COUNT(*) FROM message") {
                result["messages"] = count
            }
        }
        if set.contains("chat") {
            if let count = runCountQuery(db, "SELECT COUNT(*) FROM chat") {
                result["chats"] = count
            }
        }
        if set.contains("attachment") {
            if let count = runCountQuery(db, "SELECT COUNT(*) FROM attachment") {
                result["attachments"] = count
            }
        }
        return result
    }
    
    /// Returns media totals: images, videos, locations (matches official server).
    /// Supports `only` filter: image, video, location (comma-separated).
    func getStatisticsMedia(only: [String]? = nil) -> [String: Int] {
        dbQueue.sync {
            getStatisticsMediaUnlocked(only: only)
        }
    }
    
    private func getStatisticsMediaUnlocked(only: [String]?) -> [String: Int] {
        guard let db = db else { return [:] }
        let items = only ?? ["image", "video", "location"]
        let set = Set(items.map { $0.lowercased().replacingOccurrences(of: "s$", with: "", options: .regularExpression) })
        var result: [String: Int] = [:]
        
        if set.contains("image") {
            if let count = runCountQuery(db, "SELECT COUNT(*) FROM attachment WHERE mime_type LIKE 'image/%'") {
                result["images"] = count
            }
        }
        if set.contains("video") {
            if let count = runCountQuery(db, "SELECT COUNT(*) FROM attachment WHERE mime_type LIKE 'video/%'") {
                result["videos"] = count
            }
        }
        if set.contains("location") {
            // Text-based location sharing (works across macOS versions; balloon_bundle_id may not exist on older DBs)
            let locQuery = """
                SELECT COUNT(DISTINCT m.ROWID) FROM message m
                WHERE m.text LIKE '%maps.apple.com%' OR m.text LIKE '%maps.google.com%' OR m.text LIKE 'geo:%'
            """
            if let count = runCountQuery(db, locQuery) {
                result["locations"] = count
            }
        }
        return result
    }
    
    private func runCountQuery(_ db: OpaquePointer?, _ sql: String) -> Int? {
        guard let db = db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }
}