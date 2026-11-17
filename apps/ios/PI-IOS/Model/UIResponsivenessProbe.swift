import Foundation

/// Thread-safe diagnostic state. A display-link gap is not evidence that the
/// main queue was continuously blocked; this independently measures responses.
final class UIResponsivenessProbe: @unchecked Sendable {
    enum Event: Equatable {
        case dispatch(UInt64)
        case delayed(milliseconds: Double)
        case idle
    }
    struct Snapshot {
        let pendingMilliseconds: Double
        let sinceResponseMilliseconds: Double
    }

    private let lock = NSLock()
    private let threshold: TimeInterval
    private var active = false
    private var nextID: UInt64 = 0
    private var pending: (id: UInt64, started: TimeInterval, reported: Bool)?
    private var lastResponse: TimeInterval = 0

    init(threshold: TimeInterval = 0.25) { self.threshold = threshold }

    func start(now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        active = true
        nextID &+= 1
        pending = nil
        lastResponse = now
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        active = false
        pending = nil
    }

    func tick(now: TimeInterval) -> Event {
        lock.lock(); defer { lock.unlock() }
        guard active else { return .idle }
        if var probe = pending {
            let age = max(0, now - probe.started)
            guard age >= threshold, !probe.reported else { return .idle }
            probe.reported = true
            pending = probe
            return .delayed(milliseconds: age * 1_000)
        }
        nextID &+= 1
        pending = (nextID, now, false)
        return .dispatch(nextID)
    }

    @discardableResult
    func acknowledge(_ id: UInt64, now: TimeInterval) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard active, let probe = pending, probe.id == id else { return nil }
        pending = nil
        lastResponse = now
        return max(0, now - probe.started) * 1_000
    }

    func snapshot(now: TimeInterval) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            pendingMilliseconds: pending.map { max(0, now - $0.started) * 1_000 } ?? 0,
            sinceResponseMilliseconds: active ? max(0, now - lastResponse) * 1_000 : 0
        )
    }
}
