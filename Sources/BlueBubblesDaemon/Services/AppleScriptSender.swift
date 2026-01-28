import Foundation

class AppleScriptSender {
    
    // MARK: - Send Text Message
    
    func sendMessage(to recipient: String, text: String) -> Bool {
        let script = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(recipient)" of targetService
            send "\(text)" to targetBuddy
        end tell
        """
        
        return executeAppleScript(script)
    }
    
    func sendMessage(toChatWithGuid chatGuid: String, text: String) -> Bool {
        // Extract recipient from chat GUID (simplified)
        // In production, you'd map chat GUID to recipient address
        let recipient = extractRecipient(from: chatGuid)
        
        guard !recipient.isEmpty else {
            logger.error("Could not extract recipient from chat GUID: \(chatGuid)")
            return false
        }
        
        return sendMessage(to: recipient, text: text)
    }
    
    // MARK: - Helper Methods
    
    private func executeAppleScript(_ script: String) -> Bool {
        let scriptPath = writeScriptToFile(script)
        
        guard !scriptPath.isEmpty else {
            logger.error("Failed to write AppleScript to file")
            return false
        }
        
        defer {
            try? FileManager.default.removeItem(atPath: scriptPath)
        }
        
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
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let errorOutput = String(data: data, encoding: .utf8) {
                    logger.error("AppleScript failed with status \(task.terminationStatus): \(errorOutput)")
                }
                return false
            }
        } catch {
            logger.error("Failed to execute AppleScript: \(error.localizedDescription)")
            return false
        }
    }
    
    private func writeScriptToFile(_ script: String) -> String {
        let tempDir = NSTemporaryDirectory()
        let scriptPath = tempDir.appending("/bluebubbles_script_\(UUID().uuidString).scpt")
        
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            return scriptPath
        } catch {
            logger.error("Failed to write script to file: \(error.localizedDescription)")
            return ""
        }
    }
    
    private func extractRecipient(from chatGuid: String) -> String {
        // Simplified extraction - in production, you'd query the database
        // to get the actual recipient address for this chat
        
        // Example: "chat123;+15551234567" -> "+15551234567"
        if let range = chatGuid.range(of: ";") {
            return String(chatGuid[range.upperBound...])
        }
        
        // Fallback: try to extract phone number pattern
        let phonePattern = "\\+[0-9]+"
        if let regex = try? NSRegularExpression(pattern: phonePattern),
           let match = regex.firstMatch(in: chatGuid, range: NSRange(chatGuid.startIndex..., in: chatGuid)) {
            return String(chatGuid[Range(match.range, in: chatGuid)!])
        }
        
        return ""
    }
    
    // MARK: - Alternative: Direct Messages.app Scripting
    
    func sendMessageDirect(recipient: String, text: String) -> Bool {
        let escapedText = text.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedRecipient = recipient.replacingOccurrences(of: "\"", with: "\\\"")
        
        let script = """
        tell application "Messages"
            send "\(escapedText)" to buddy "\(escapedRecipient)"
        end tell
        """
        
        return executeAppleScript(script)
    }
}