import Foundation

/// An independently owned operation races a deadline. Unlike TaskGroup, the caller
/// never joins a future that ignores cancellation. Resource owners must arrange
/// physical close when abandoning network work; late results are fenced by them.
func withNetworkDeadline<T: Sendable>(
    seconds: TimeInterval,
    timeoutError: @escaping @Sendable () -> Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = NetworkDeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            let worker = Task {
                do { race.finish(.success(try await operation())) }
                catch { race.finish(.failure(error)) }
            }
            let timer = Task {
                do { try await Task.sleep(for: .seconds(max(0, seconds))) }
                catch { return }
                race.finish(.failure(timeoutError()))
            }
            race.register([worker, timer])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

private final class NetworkDeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let result = lock.withLock { () -> Result<T, Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func register(_ tasks: [Task<Void, Never>]) {
        let completed = lock.withLock { () -> Bool in
            guard result == nil else { return true }
            self.tasks = tasks
            return false
        }
        if completed { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<T, Error>) {
        let completion = lock.withLock { () -> (CheckedContinuation<T, Error>?, [Task<Void, Never>])? in
            guard self.result == nil else { return nil }
            self.result = result
            let completion = (continuation, tasks)
            continuation = nil
            tasks = []
            return completion
        }
        guard let (continuation, tasks) = completion else { return }
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

/// Every caller joins the same independently owned close. Calling request() from
/// a reader is safe: it starts cleanup without waiting for that reader to join itself.
final class NetworkCloseTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    @discardableResult
    func request(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            if let task { return task }
            let task = Task.detached { await operation() }
            self.task = task
            return task
        }
    }
}
