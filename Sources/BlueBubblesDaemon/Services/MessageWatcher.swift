import Foundation
import Darwin

final class MessageWatcher {
    private let filePaths: [String]
    private let poller: MessagePoller
    private let debounceDelay: TimeInterval
    private let queue = DispatchQueue(label: "com.bluebubbles.messagewatcher")

    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?

    init(filePaths: [String], poller: MessagePoller, debounceDelay: TimeInterval = 0.5) {
        self.filePaths = filePaths
        self.poller = poller
        self.debounceDelay = debounceDelay
    }

    deinit {
        stop()
    }

    func start() {
        logger.info("Starting message watcher for: \(filePaths.joined(separator: ", "))")
        setupWatchers()
        // Initial poll to seed cache
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.poller.pollNow()
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        retryWorkItem?.cancel()
        debounceWorkItem = nil
        retryWorkItem = nil
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    private func setupWatchers() {
        stop()
        var missing: [String] = []

        for path in filePaths {
            if !FileManager.default.fileExists(atPath: path) {
                missing.append(path)
                continue
            }
            if !addWatcher(for: path) {
                missing.append(path)
            }
        }

        if !missing.isEmpty {
            logger.warning("Message watcher missing files: \(missing.joined(separator: ", "))")
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.setupWatchers()
        }
        retryWorkItem = work
        queue.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    private func addWatcher(for path: String) -> Bool {
        let fd = open(path, O_EVTONLY)
        if fd < 0 {
            logger.warning("Failed to watch file: \(path)")
            return false
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self, weak source] in
            guard let self = self, let source = source else { return }
            let data = source.data
            if data.contains(.delete) || data.contains(.rename) {
                logger.info("Message DB file changed (rename/delete): \(path)")
                self.setupWatchers()
                return
            }
            self.schedulePoll()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        sources.append(source)
        return true
    }

    private func schedulePoll() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.poller.pollNow()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }
}
