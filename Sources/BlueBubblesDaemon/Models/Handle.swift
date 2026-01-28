import Foundation

struct Handle: Codable {
    let id: Int64
    let address: String  // phone number or email
    let service: String  // "iMessage" or "SMS"
    let uncanonicalizedId: String?
}