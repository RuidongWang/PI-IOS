import Foundation

/// Thread-safe, replayable single result, independent of an EventLoop lifetime.
/// Completion and registration can race; every waiter observes exactly one result.
final class NetworkResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func finish(_ result: Result<Value, Error>) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Value, Error>] in
            guard self.result == nil else { return [] }
            self.result = result
            let waiters = self.waiters
            self.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    func succeed(_ value: Value) { finish(.success(value)) }
    func fail(_ error: Error) { finish(.failure(error)) }
}
