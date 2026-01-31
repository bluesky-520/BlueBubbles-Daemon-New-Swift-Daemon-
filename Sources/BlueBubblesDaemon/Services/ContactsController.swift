import Contacts
import Foundation
import Vapor

final class ContactsController {
    private let store = CNContactStore()
    private let cacheQueue = DispatchQueue(label: "bluebubbles.contacts.cache")
    private var cachedContacts: [ContactResponse] = []
    private var cacheValid = false
    private var watcher: ContactsWatcher?
    private var onContactsChanged: (() -> Void)?
    private let fetchTimeoutSeconds: Double = 15

    /// Timestamp when contacts last changed; used by SSE /events to notify clients.
    private(set) var lastContactsChangeTime: Date = Date()
    private let changeTimeQueue = DispatchQueue(label: "bluebubbles.contacts.changetime")

    init() {
        watcher = ContactsWatcher(store: store) { [weak self] in
            self?.handleContactsChanged()
        }
    }

    /// Set callback for when contacts are updated (e.g. to drive SSE)
    func setOnContactsChanged(_ callback: @escaping () -> Void) {
        onContactsChanged = callback
    }

    func getLastContactsChangeTime() -> Date {
        changeTimeQueue.sync { lastContactsChangeTime }
    }

    private func handleContactsChanged() {
        logger.info("ContactsController: Contacts changed, invalidating cache")
        cacheQueue.async { [weak self] in
            self?.cachedContacts = []
            self?.cacheValid = false
        }
        changeTimeQueue.async { [weak self] in
            self?.lastContactsChangeTime = Date()
        }
        onContactsChanged?()
    }

    func list(on app: Application, limit: Int? = nil, offset: Int? = nil, extraProperties: [String] = []) async throws -> [ContactResponse] {
        await Task.yield()
        let includeAvatar = shouldIncludeAvatar(extraProperties)
        let cached = cacheQueue.sync { (cachedContacts, cacheValid) }
        if cached.1, !cached.0.isEmpty {
            let data = applyPagination(cached.0, limit: limit, offset: offset)
            return includeAvatar ? data : data.map { withAvatar($0, avatar: "") }
        }

        do {
            let contacts = try await fetchContactsWithTimeout(on: app)
            let data = applyPagination(contacts, limit: limit, offset: offset)
            return includeAvatar ? data : data.map { withAvatar($0, avatar: "") }
        } catch {
            logger.warning("Contacts fetch failed: \(error.localizedDescription)")
            let fallback = cacheQueue.sync { cachedContacts }
            let data = applyPagination(fallback, limit: limit, offset: offset)
            return includeAvatar ? data : data.map { withAvatar($0, avatar: "") }
        }
    }

    func vcfString(on app: Application) async throws -> String {
        let isAuthorized = try await requestAccessIfNeeded()
        guard isAuthorized else {
            throw Abort(.forbidden, reason: "Contacts not authorized")
        }

        return try await app.threadPool.runIfActive { [store] in
            let keys: [CNKeyDescriptor] = [
                CNContactVCardSerialization.descriptorForRequiredKeys()
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = true

            var contacts: [CNContact] = []
            try store.enumerateContacts(with: request) { contact, _ in
                contacts.append(contact)
            }

            let data = try CNContactVCardSerialization.data(with: contacts)
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private func shouldIncludeAvatar(_ extraProps: [String]) -> Bool {
        let lower = extraProps.map { $0.lowercased() }
        return lower.contains("avatar") || lower.contains("contactimage") || lower.contains("contactthumbnailimage")
    }

    private func withAvatar(_ contact: ContactResponse, avatar: String) -> ContactResponse {
        ContactResponse(
            phoneNumbers: contact.phoneNumbers,
            emails: contact.emails,
            firstName: contact.firstName,
            lastName: contact.lastName,
            displayName: contact.displayName,
            nickname: contact.nickname,
            birthday: contact.birthday,
            avatar: avatar,
            sourceType: contact.sourceType,
            id: contact.id
        )
    }

    private func applyPagination(_ contacts: [ContactResponse], limit: Int?, offset: Int?) -> [ContactResponse] {
        let safeOffset = max(offset ?? 0, 0)
        let maxLimit = 5_000
        let safeLimit = limit.map { min(max($0, 1), maxLimit) }

        guard safeOffset < contacts.count else { return [] }
        let endIndex: Int
        if let safeLimit {
            endIndex = min(safeOffset + safeLimit, contacts.count)
        } else {
            endIndex = contacts.count
        }
        return Array(contacts[safeOffset..<endIndex])
    }

    private func requestAccessIfNeeded() async throws -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return true
        case .notDetermined:
            return try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(for: .contacts) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func fetchContacts(on app: Application) async throws -> [ContactResponse] {
        let isAuthorized = try await requestAccessIfNeeded()
        guard isAuthorized else {
            logger.warning("Contacts not authorized; returning cached contacts")
            return cacheQueue.sync { cachedContacts }
        }

        let contacts = try await app.threadPool.runIfActive { [store] in
            let keys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactNicknameKey as CNKeyDescriptor,
                CNContactBirthdayKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactImageDataAvailableKey as CNKeyDescriptor,
                CNContactThumbnailImageDataKey as CNKeyDescriptor,
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
            ]

            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = true

            var results: [ContactResponse] = []
            try store.enumerateContacts(with: request) { [weak self] contact, _ in
                guard let self else { return }

                let phoneNumbers = dedupeAddressEntries(
                    contact.phoneNumbers.compactMap { entry in
                        let raw = entry.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !raw.isEmpty else { return nil }
                        return ContactAddressEntry(address: raw, id: entry.identifier)
                    }
                )

                let emails = dedupeAddressEntries(
                    contact.emailAddresses.compactMap { entry in
                        let raw = String(entry.value).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !raw.isEmpty else { return nil }
                        return ContactAddressEntry(address: raw, id: entry.identifier)
                    }
                )

                if phoneNumbers.isEmpty, emails.isEmpty { return }

                let displayName = displayNameForContact(contact)
                let firstName = contact.givenName.isEmpty ? nil : contact.givenName
                let lastName = contact.familyName.isEmpty ? nil : contact.familyName
                let nickname = contact.nickname.isEmpty ? nil : contact.nickname
                let birthday = birthdayString(from: contact.birthday)
                let avatar = avatarBase64(for: contact)

                results.append(ContactResponse(
                    phoneNumbers: phoneNumbers,
                    emails: emails,
                    firstName: firstName,
                    lastName: lastName,
                    displayName: displayName,
                    nickname: nickname,
                    birthday: birthday,
                    avatar: avatar,
                    sourceType: "api",
                    id: contact.identifier
                ))
            }

            logger.info("Contacts fetched: \(results.count)")
            return results
        }

        cacheQueue.sync {
            cachedContacts = contacts
            cacheValid = true
        }
        return contacts
    }

    private func fetchContactsWithTimeout(on app: Application) async throws -> [ContactResponse] {
        let start = Date()
        do {
            let results = try await withTimeout(seconds: fetchTimeoutSeconds) {
                try await self.fetchContacts(on: app)
            }
            let elapsed = Date().timeIntervalSince(start)
            logger.info("Contacts fetch completed in \(String(format: "%.2f", elapsed))s")
            return results
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            logger.warning("Contacts fetch failed after \(String(format: "%.2f", elapsed))s: \(error)")
            throw error
        }
    }

    private func displayNameForContact(_ contact: CNContact) -> String {
        let fullNameKeys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        if contact.areKeysAvailable(fullNameKeys),
           let formatted = CNContactFormatter.string(from: contact, style: .fullName),
           !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return formatted
        }

        if !contact.organizationName.isEmpty {
            return contact.organizationName
        }

        let combined = [contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !combined.isEmpty {
            return combined
        }

        if !contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contact.nickname
        }

        return ""
    }

    private func avatarBase64(for contact: CNContact) -> String {
        guard contact.imageDataAvailable, let data = contact.thumbnailImageData else {
            return ""
        }
        return data.base64EncodedString()
    }

    private func birthdayString(from components: DateComponents?) -> String? {
        guard let components else { return nil }
        if let year = components.year, let month = components.month, let day = components.day {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        if let month = components.month, let day = components.day {
            return String(format: "%02d-%02d", month, day)
        }
        return nil
    }

    private func dedupeAddressEntries(_ entries: [ContactAddressEntry]) -> [ContactAddressEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            guard !seen.contains(entry.address) else { return false }
            seen.insert(entry.address)
            return true
        }
    }
}

private enum ContactsFetchError: Error {
    case timeout
}

private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let nanos = UInt64(seconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanos)
            throw ContactsFetchError.timeout
        }
        guard let result = try await group.next() else {
            throw ContactsFetchError.timeout
        }
        group.cancelAll()
        return result
    }
}
