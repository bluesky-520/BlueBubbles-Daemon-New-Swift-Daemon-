import Foundation
import Contacts

/// Watches macOS Contacts for changes using CNContactStore notifications.
/// When the address book changes, invalidation ensures clients get fresh data.
public final class ContactsWatcher {
    private var notificationObserver: NSObjectProtocol?
    private let onChange: () -> Void
    private let store: CNContactStore

    public init(store: CNContactStore = CNContactStore(), onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logger.info("ContactsWatcher: Contacts database changed, triggering sync")
            self?.onChange()
        }

        logger.info("ContactsWatcher: Started monitoring for contact changes")
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
