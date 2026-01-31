import Foundation
import Vapor

/// Contact address entry for phone numbers or emails (matches BlueBubbles NativeBackend)
struct ContactAddressEntry: Content {
    let address: String
    let id: String?
}

/// BlueBubbles contact response schema (matches official server / NativeBackend)
struct ContactResponse: Content {
    let phoneNumbers: [ContactAddressEntry]
    let emails: [ContactAddressEntry]
    let firstName: String?
    let lastName: String?
    let displayName: String
    let nickname: String?
    let birthday: String?
    let avatar: String
    let sourceType: String
    let id: String
}
