import Foundation

/// Queues file URLs opened from Finder before SwiftUI is ready to consume them.
enum OpenFileBridge {
    static let flushNotification = Notification.Name("PaperTape.OpenFileBridge.flush")

    private static let lock = NSLock()
    private static var queue: [URL] = []

    static func enqueue(_ url: URL) {
        lock.lock()
        queue.append(url)
        lock.unlock()
        requestFlush()
    }

    static func enqueueWithoutFlush(_ url: URL) {
        lock.lock()
        queue.append(url)
        lock.unlock()
    }

    static func hasPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !queue.isEmpty
    }

    static func drain() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        let items = queue
        queue.removeAll()
        return items
    }

    static func requestFlush() {
        NotificationCenter.default.post(name: flushNotification, object: nil)
    }
}
