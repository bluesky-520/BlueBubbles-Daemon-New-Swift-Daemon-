import Foundation

/// Sends messages and attachments via Messages.app using AppleScript.
/// Uses account index (1 = iMessage, 2 = SMS) and participant/chat id for compatibility across macOS versions.
class AppleScriptSender {

    // MARK: - Public API

    /// Sends a message (and optional attachments) to a chat by guid, trying chat identifier then recipients.
    func sendMessage(
        toChatWithGuid chatGuid: String,
        text: String,
        chatIdentifier: String? = nil,
        recipients: [String] = [],
        attachmentPaths: [String]? = nil
    ) -> Bool {
        let serviceType = serviceFromGuid(chatGuid)
        // Only use chat identifier when it matches the requested service (iMessage vs SMS), so we don't send to the wrong thread (e.g. green when blue was requested).
        if let chatId = chatIdentifier, !chatId.isEmpty, chatIdentifierMatchesService(chatId, serviceType: serviceType) {
            if sendToChatIdentifier(chatId, text: text, attachmentPaths: attachmentPaths) {
                return true
            }
        }
        if !recipients.isEmpty {
            return sendToRecipients(recipients: recipients, serviceType: serviceType, text: text, attachmentPaths: attachmentPaths)
        }
        let recipient = extractRecipient(from: chatGuid)
        guard !recipient.isEmpty else { return false }
        return sendToRecipients(recipients: [recipient], serviceType: serviceType, text: text, attachmentPaths: attachmentPaths)
    }

    // MARK: - Send by chat identifier

    /// Sends to an existing chat using Messages.app "chat id". Prefer when the client has a chat_identifier.
    func sendToChatIdentifier(_ chatIdentifier: String, text: String, attachmentPaths: [String]? = nil) -> Bool {
        let escapedText = escapeForAppleScript(text)
        let escapedChatId = escapeForAppleScript(chatIdentifier)
        let paths = attachmentPaths ?? []
        let fileBlock = appleScriptFileListBlock(paths: paths)
        let sendPart = text.isEmpty ? "" : "send \"\(escapedText)\" to targetChat\n            "
        let filesPart = paths.isEmpty ? "" : appleScriptSendFilesBlock().replacingOccurrences(of: "TARGET_REF", with: "targetChat")
        let script = """
        \(fileBlock)
        tell application "Messages"
            set targetChat to chat id "\(escapedChatId)"
            \(sendPart)\(filesPart)
        end tell
        """
        return executeAppleScript(script)
    }

    // MARK: - Send by participants + account

    /// Numeric account index: 1 = iMessage, 2 = SMS (avoids "whose service type" -1728 on some macOS).
    private func accountIndex(forServiceType serviceType: String) -> Int {
        serviceType == "SMS" ? 2 : 1
    }

    /// Sends to one or more recipients using account by index. Single recipient uses direct send to participant.
    func sendToRecipients(
        recipients: [String],
        serviceType: String,
        text: String,
        attachmentPaths: [String]? = nil
    ) -> Bool {
        guard !recipients.isEmpty else { return false }
        let escapedText = escapeForAppleScript(text)
        let idx = accountIndex(forServiceType: serviceType)
        let paths = attachmentPaths ?? []

        if recipients.count == 1 {
            return sendToSingleRecipient(recipient: recipients[0], accountIndex: idx, text: escapedText, attachmentPaths: paths, serviceType: serviceType)
        }
        return sendToMultipleRecipients(recipients: recipients, accountIndex: idx, text: escapedText, attachmentPaths: paths, serviceType: serviceType)
    }

    /// Single recipient: send directly to participant (avoids "Can't get text chat" on some macOS).
    private func sendToSingleRecipient(
        recipient: String,
        accountIndex idx: Int,
        text: String,
        attachmentPaths: [String],
        serviceType: String
    ) -> Bool {
        let escapedRecipient = escapeForAppleScript(recipient)
        let fileBlock = appleScriptFileListBlock(paths: attachmentPaths)
        let sendPart = text.isEmpty ? "" : "send \"\(text)\" to targetParticipant\n            "
        let filesPart = attachmentPaths.isEmpty ? "" : appleScriptSendFilesBlock().replacingOccurrences(of: "TARGET_REF", with: "targetParticipant")
        let script = """
        \(fileBlock)
        tell application "Messages"
            if (count of accounts) < \(idx) then
                error "No \(serviceType) account available"
            end if
            set targetAccount to account \(idx)
            set targetParticipant to participant "\(escapedRecipient)" of targetAccount
            \(sendPart)\(filesPart)
        end tell
        """
        return executeAppleScript(script)
    }

    /// Multiple recipients: build participant list (use "contents of p") then make text chat and send.
    private func sendToMultipleRecipients(
        recipients: [String],
        accountIndex idx: Int,
        text: String,
        attachmentPaths: [String],
        serviceType: String
    ) -> Bool {
        let participantList = recipients.map { "\"\(escapeForAppleScript($0))\"" }.joined(separator: ", ")
        let fileBlock = appleScriptFileListBlock(paths: attachmentPaths)
        let sendPart = text.isEmpty ? "" : "send \"\(text)\" to targetChat\n            "
        let filesPart = attachmentPaths.isEmpty ? "" : appleScriptSendFilesBlock().replacingOccurrences(of: "TARGET_REF", with: "targetChat")
        let script = """
        \(fileBlock)
        tell application "Messages"
            if (count of accounts) < \(idx) then
                error "No \(serviceType) account available"
            end if
            set targetAccount to account \(idx)
            set targetParticipants to {}
            repeat with p in {\(participantList)}
                set end of targetParticipants to (participant (contents of p) of targetAccount)
            end repeat
            set targetChat to make new text chat with properties {participants:targetParticipants}
            \(sendPart)\(filesPart)
        end tell
        """
        return executeAppleScript(script)
    }

    // MARK: - Attachment helpers (AppleScript)

    /// Builds script that populates `fileList` from POSIX paths *outside* "tell application Messages" to avoid sandbox issues.
    private func appleScriptFileListBlock(paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        let escapedPaths = paths.map { path in
            let safe = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(safe)\""
        }.joined(separator: ", ")
        return """
        set fileList to {}
        repeat with path in {\(escapedPaths)}
            set end of fileList to (POSIX file (contents of path))
        end repeat

        """
    }

    /// Builds script that sends each item in `fileList` to TARGET_REF (replace with targetChat or targetParticipant).
    private func appleScriptSendFilesBlock() -> String {
        """
        repeat with f in fileList
            send f to TARGET_REF
        end repeat
        """
    }

    // MARK: - Script execution

    private func executeAppleScript(_ script: String) -> Bool {
        let scriptPath = writeScriptToFile(script)
        guard !scriptPath.isEmpty else {
            logger.error("Failed to write AppleScript to file")
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = [scriptPath]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                logger.info("AppleScript executed successfully")
                return true
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let errorOutput = String(data: data, encoding: .utf8) {
                logger.error("AppleScript failed with status \(task.terminationStatus): \(errorOutput)")
            }
            return false
        } catch {
            logger.error("Failed to execute AppleScript: \(error.localizedDescription)")
            return false
        }
    }

    private func writeScriptToFile(_ script: String) -> String {
        let tempDir = NSTemporaryDirectory()
        let scriptPath = tempDir.appending("bluebubbles_script_\(UUID().uuidString).scpt")
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            return scriptPath
        } catch {
            logger.error("Failed to write script to file: \(error.localizedDescription)")
            return ""
        }
    }

    // MARK: - Escaping and GUID parsing

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// GUID format: "iMessage;-;+123" or "SMS;-;+123". Returns the address part.
    private func extractRecipient(from chatGuid: String) -> String {
        let separator = ";-;"
        if let range = chatGuid.range(of: separator) {
            return String(chatGuid[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let range = chatGuid.range(of: ";") {
            return String(chatGuid[range.upperBound...])
        }
        let phonePattern = "\\+[0-9]+"
        if let regex = try? NSRegularExpression(pattern: phonePattern),
           let match = regex.firstMatch(in: chatGuid, range: NSRange(chatGuid.startIndex..., in: chatGuid)) {
            return String(chatGuid[Range(match.range, in: chatGuid)!])
        }
        return ""
    }

    /// GUID format: "iMessage;-;address" or "SMS;-;address". Returns "SMS" or "iMessage".
    private func serviceFromGuid(_ chatGuid: String) -> String {
        if chatGuid.hasPrefix("SMS;-;") || chatGuid.hasPrefix("SMS;") { return "SMS" }
        return "iMessage"
    }

    /// True when chat_identifier's service (iMessage vs SMS) matches the requested service, so we don't send to the wrong thread.
    private func chatIdentifierMatchesService(_ chatIdentifier: String, serviceType: String) -> Bool {
        let idIsSMS = chatIdentifier.hasPrefix("SMS;-;") || chatIdentifier.hasPrefix("SMS;")
        return (serviceType == "SMS" && idIsSMS) || (serviceType == "iMessage" && !idIsSMS)
    }
}
