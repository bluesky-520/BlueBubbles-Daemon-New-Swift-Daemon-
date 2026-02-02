import Foundation

/// Lightweight in-memory set of tempGuids for in-flight sends. Prevents duplicate sends and allows
/// clients to correlate requests. No DB or polling—efficient add/remove only.
final class SendCache {
    private let lock = NSLock()
    private var guids: Set<String> = []
    private let maxCount = 10_000

    /// Returns true if added, false if already present (idempotent add).
    func add(_ tempGuid: String) -> Bool {
        guard !tempGuid.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        if guids.contains(tempGuid) { return false }
        if guids.count >= maxCount {
            guids.remove(guids.first!)
        }
        guids.insert(tempGuid)
        return true
    }

    func remove(_ tempGuid: String) {
        guard !tempGuid.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guids.remove(tempGuid)
    }

    func contains(_ tempGuid: String) -> Bool {
        guard !tempGuid.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return guids.contains(tempGuid)
    }
}
