import Foundation

/// Owns block-based notification registrations and removes them from the same centre
/// that created them.
///
/// `NotificationCenter` retains block observer tokens until they are explicitly removed.
/// Keeping the centre beside the token makes lifecycle symmetry hard to get wrong when a
/// controller observes both the default centre and `NSWorkspace.notificationCenter`.
nonisolated final class NotificationObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func insert(_ token: NSObjectProtocol, center: NotificationCenter) {
        lock.lock()
        observations.append((center, token))
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let owned = observations
        observations.removeAll(keepingCapacity: true)
        lock.unlock()
        for observation in owned {
            observation.center.removeObserver(observation.token)
        }
    }

    deinit {
        for observation in observations {
            observation.center.removeObserver(observation.token)
        }
    }
}
