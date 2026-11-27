import Foundation

/// Actor-confined delivery bookkeeping for payload-free invalidations only.
/// Reliable updates never enter this coalescer. Queued receipt IDs correspond
/// one-for-one to signals already placed on AsyncStream, including revoked
/// signals: keeping those placeholders lets the consumer skip exactly the old
/// signal without accidentally acknowledging a newer scope.
struct SessionChangeDelivery {
    struct Key: Equatable {
        let client: UUID
        let generation: UUID?
        let session: String?
        let attachmentGeneration: Int
    }

    struct Statistics: Equatable {
        var invalidations = 0
        var deliveries = 0
        var coalesced = 0
        var queued = 0
        var consuming = false
    }

    private struct Delivery {
        let id: UUID
        let key: Key
        var consuming = false
        var dirty = false
    }

    private var current: Delivery?
    private var queuedReceipts: [UUID] = []
    private var counts = Statistics()

    mutating func invalidate(_ key: Key) -> Bool {
        counts.invalidations += 1
        revokeIfChanged(key)
        if var delivery = current {
            if delivery.consuming { delivery.dirty = true }
            current = delivery
            counts.coalesced += 1
            return false
        }
        enqueue(key)
        return true
    }

    mutating func begin(_ key: Key) -> UUID? {
        revokeIfChanged(key)
        guard !queuedReceipts.isEmpty else { return nil }
        let receipt = queuedReceipts.removeFirst()
        guard var delivery = current,
              delivery.id == receipt, delivery.key == key,
              !delivery.consuming else { return nil }
        delivery.consuming = true
        current = delivery
        return receipt
    }

    /// Returns true only when consumption raced another invalidation. The caller
    /// must place exactly one new signal after the preceding consumption ended.
    mutating func finish(_ receipt: UUID, key: Key) -> Bool {
        revokeIfChanged(key)
        guard let delivery = current, delivery.id == receipt,
              delivery.key == key, delivery.consuming else { return false }
        current = nil
        guard delivery.dirty else { return false }
        enqueue(key)
        return true
    }

    mutating func revoke() { current = nil }

    /// Rolls back an unconsumed pending delivery when the underlying stream
    /// fails to enqueue `.sessionChanged`, preventing subsequent invalidations
    /// from coalescing onto a lost signal forever.
    mutating func rollbackPending(_ key: Key) {
        guard let delivery = current, delivery.key == key, !delivery.consuming else { return }
        queuedReceipts.removeAll { $0 == delivery.id }
        current = nil
        counts.deliveries = max(0, counts.deliveries - 1)
    }

    var statistics: Statistics {
        var result = counts
        result.queued = queuedReceipts.count
        result.consuming = current?.consuming == true
        return result
    }

    private mutating func revokeIfChanged(_ key: Key) {
        if let current, current.key != key { self.current = nil }
    }

    private mutating func enqueue(_ key: Key) {
        let delivery = Delivery(id: UUID(), key: key)
        current = delivery
        queuedReceipts.append(delivery.id)
        counts.deliveries += 1
    }
}
