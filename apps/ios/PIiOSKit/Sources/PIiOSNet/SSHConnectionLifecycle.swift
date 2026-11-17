import Foundation
import NIOCore

/// Shared by an SSH parent and all of its WebSocket children. The same lock
/// orders submissions against shutdown; an isActive check alone cannot do so.
final class SSHConnectionLifecycle: @unchecked Sendable {
    private typealias ChildClose = @Sendable () -> Task<Void, Never>
    private enum Phase { case open, closing, sealed, closed }
    private let lock = NSLock()
    private var phase: Phase = .open
    private let parent: Channel
    private let shutdown: @Sendable () async -> Void
    private let closeTask = NetworkCloseTask()
    private var children: [UUID: ChildClose] = [:]
#if DEBUG
    private var shutdownRuns = 0

    struct Diagnostics {
        let children: Int
        let shutdownRuns: Int
        let closed: Bool
    }

    var diagnosticsForTesting: Diagnostics {
        lock.withLock {
            Diagnostics(children: children.count, shutdownRuns: shutdownRuns, closed: phase == .closed)
        }
    }
#endif

    init(parent: Channel, shutdown: @escaping @Sendable () async -> Void) {
        self.parent = parent
        self.shutdown = shutdown
    }

    /// New operations are rejected as soon as the owner requests shutdown.
    @discardableResult
    func execute(_ operation: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard phase == .open else { return false }
            parent.eventLoop.execute(operation)
            return true
        }
    }

    /// Existing children can finish physical close until the shutdown owner has
    /// joined them. After that point even late termination callbacks cannot submit.
    @discardableResult
    func executeCleanup(_ operation: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard phase == .open || phase == .closing else { return false }
            parent.eventLoop.execute(operation)
            return true
        }
    }

    func registerChild(
        _ id: UUID,
        close: @escaping @Sendable () -> Task<Void, Never>
    ) -> Bool {
        lock.withLock {
            guard phase == .open else { return false }
            children[id] = close
            return true
        }
    }

    func removeChild(_ id: UUID) {
        lock.withLock { _ = children.removeValue(forKey: id) }
    }

    @discardableResult
    func requestClose() -> Task<Void, Never> {
        // Snapshot children, then release the lifecycle lock before invoking
        // them. A child close may take its own lock (and call back into
        // executeCleanup), so holding this lock while calling would invert
        // against the child -> lifecycle ordering used by send/close.
        let children = lock.withLock { () -> [ChildClose] in
            if phase == .open { phase = .closing }
            return Array(self.children.values)
        }
        return closeTask.request { [self] in
            // Request every child before joining any: physical close unblocks
            // writes/readers, including a reader that initiated this shutdown.
            let completions = children.map { $0() }
            for completion in completions { await completion.value }
            _ = executeCleanup { [parent] in parent.close(promise: nil) }
            try? await parent.closeFuture.get()
            lock.withLock {
                phase = .sealed
#if DEBUG
                shutdownRuns += 1
#endif
            }
            await shutdown()
            lock.withLock {
                self.children.removeAll()
                phase = .closed
            }
        }
    }

    func close() async { await requestClose().value }
}

/// An inbound reader may request shutdown, but cannot await cleanup that joins
/// that very reader. Detached cleanup owners do not inherit this task-local value.
enum RACPInboundContext {
    @TaskLocal static var socketID: ObjectIdentifier?
}
