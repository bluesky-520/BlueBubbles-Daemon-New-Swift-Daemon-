import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Extracts plain text from Apple Messages attributedBody BLOB.
/// On macOS Ventura+, message content is stored in attributedBody instead of text.
/// Format can be NSKeyedArchiver (modern) or NSArchiver (legacy) depending on macOS version.
enum AttributedBodyDecoder {
    
    /// Decode attributedBody BLOB and return plain text. Returns nil on failure or empty result.
    /// Tries NSKeyedUnarchiver first, then legacy NSUnarchiver (used by many chat.db records).
    static func extractText(from data: Data?) -> String? {
        guard let data = data, !data.isEmpty else { return nil }
        
        // Try NSKeyedUnarchiver first (modern format)
        if let text = extractViaKeyedUnarchiver(data) {
            return text
        }
        
        // Fallback: legacy NSArchiver format (common in iMessage/SMS chat.db)
        return extractViaLegacyUnarchiver(data)
    }
    
    private static func extractViaKeyedUnarchiver(_ data: Data) -> String? {
        do {
            // NSAttributedString archives include font, paragraph, color attributes
            let allowedClasses: [AnyClass] = [
                NSAttributedString.self,
                NSMutableAttributedString.self,
                NSString.self,
                NSDictionary.self,
                NSArray.self,
                NSNumber.self,
                NSNull.self,
                NSValue.self,
                NSParagraphStyle.self,
                NSMutableParagraphStyle.self,
                NSFont.self,
                NSColor.self,
                NSURL.self
            ]
            let obj = try NSKeyedUnarchiver.unarchivedObject(ofClasses: allowedClasses, from: data)
            return extractString(from: obj)
        } catch {
            return nil
        }
    }
    
    @available(macOS, deprecated: 10.13, message: "Uses NSUnarchiver for legacy format - intentionally")
    private static func extractViaLegacyUnarchiver(_ data: Data) -> String? {
        // Legacy NSArchiver format - required for many iMessage/SMS records (deprecated API required)
        guard let u = NSUnarchiver(forReadingWith: data) else { return nil }
        let obj = u.decodeObject()
        return extractString(from: obj)
    }
    
    private static func extractString(from obj: Any?) -> String? {
        guard let obj = obj else { return nil }
        if let attrStr = obj as? NSAttributedString, !attrStr.string.isEmpty {
            return attrStr.string
        }
        if let dict = obj as? NSDictionary {
            for (_, value) in dict {
                if let s = extractString(from: value) { return s }
            }
        }
        if let arr = obj as? NSArray {
            for item in arr {
                if let s = extractString(from: item) { return s }
            }
        }
        return nil
    }
}
