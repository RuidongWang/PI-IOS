import Foundation
import PIiOSCore
import PIiOSNet

/// One owner per normalized backing file. Only `queue` touches the database and
/// canonical snapshot; the short lock protects admission fences and a read mirror.
final class SessionCacheWorker: @unchecked Sendable {
    enum Outcome: @unchecked Sendable {
        case committed
        case superseded
        case failed(Error)
    }

    struct Context: Equatable, Sendable {
        let clientID: UUID
        let generation: Int
        let hostID: UUID?
        let sessionID: String?
        let active: Bool

        func sameConnection(as other: Context) -> Bool {
            clientID == other.clientID && generation == other.generation
                && hostID == other.hostID && active == other.active
        }
    }

    private struct Grant {
        var context: Context
        var connection = UUID()
        var selection = UUID()
        var hostRevoked = false
        var revokedSessions: Set<String> = []
    }

    struct Permit: Sendable {
        fileprivate let source: UUID
        fileprivate let connection: UUID
        fileprivate let selection: UUID?
        fileprivate let hostID: UUID
        fileprivate let sessionID: String
        fileprivate let order: UInt64
        fileprivate let key: String
    }

    struct Status: Sendable {
        var ready = false
        var error: String?
        var revision: UInt64 = 0
    }

    /// Barrier result plus the status revision that was current when the failure
    /// snapshot was taken. A caller uses the revision to reject an older failure
    /// that a newer publish already recovered from.
    struct FlushResult: Sendable {
        let outcome: Outcome
        let statusRevision: UInt64
    }

    private static let registryLock = NSLock()
    private final class WeakOwner { weak var value: SessionCacheWorker?; init(_ value: SessionCacheWorker) { self.value = value } }
    private static var registry: [String: WeakOwner] = [:]

    static func shared(fileURL: URL?, limit: Int, memory: OfflineSessionCacheSnapshot?) -> SessionCacheWorker {
        guard let fileURL else { return SessionCacheWorker(fileURL: nil, limit: limit, memory: memory ?? .init()) }
        let key = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock()
        defer { registryLock.unlock() }
        registry = registry.filter { $0.value.value != nil }
        if let owner = registry[key]?.value { return owner }
        let owner = SessionCacheWorker(fileURL: fileURL, limit: limit, memory: nil)
        registry[key] = WeakOwner(owner)
        return owner
    }

    private let queue = DispatchQueue(label: "dev.piios.session-cache", qos: .utility)
    private let lock = NSLock()
    private let fileURL: URL?
    private var grants: [UUID: Grant] = [:]
    /// Both order maps are keyed by backing entity (host + session + kind),
    /// never by facade/source. Two facades observing the same session must still
    /// share one revision order or an older permit can overwrite a newer state.
    /// Permits admitted but not yet decided; a newer live admission blocks an
    /// older permit even before it commits.
    private var liveOrders: [String: Set<UInt64>] = [:]
    /// Highest order that reached the apply/commit path for an entity. It is
    /// deliberately independent of live admissions so abandoning a never
    /// submitted permit cannot reopen the door for an older write to overwrite
    /// already committed state.
    private var appliedOrders: [String: UInt64] = [:]
    private var nextOrder: UInt64 = 0
    private var pendingOperations = 0
    private var pendingMutations = 0
    private var status = Status()
    private var mirrorPublishPending = false
    private var observers: [UUID: @Sendable (Status) -> Void] = [:]
    private var mirror = OfflineSessionCacheSnapshot()
    private var sessionsByHost: [UUID: [String: OfflineCachedSession]] = [:]
    private var idsByHost: [UUID: [String]] = [:]
    private var limit: Int
    // The following fields belong exclusively to queue.
    private var snapshot = OfflineSessionCacheSnapshot()
    private var durableSnapshot = OfflineSessionCacheSnapshot()
    private var database: OfflineSessionCacheSQLite?
    private var loadFailure: Error?
    private var hydrated = false
    /// Last load/save failure, guarded by `lock` so `flush` can inspect it
    /// without entering the worker queue.
    private var failureState: Error?

    /// Tests pause the real adapter immediately before its commit fence.
    private var commitHook: (@Sendable () -> Void)?
    var beforeCommitForTesting: (@Sendable () -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return commitHook
        }
        set {
            lock.lock(); commitHook = newValue; lock.unlock()
        }
    }
    /// Tests inject a real write failure after a healthy hydrate, or block the
    /// real adapter while observing MainActor progress.
    private var writeHook: (@Sendable () throws -> Void)?
    var beforeWriteForTesting: (@Sendable () throws -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return writeHook
        }
        set {
            lock.lock(); writeHook = newValue; lock.unlock()
        }
    }
#if DEBUG
    enum TestStage: Sendable, Equatable { case afterRead, beforeCommit, beforeWrite, beforePublish, finished }
    private var stageHook: (@Sendable (TestStage) -> Void)?
    var stageHookForTesting: (@Sendable (TestStage) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stageHook }
        set { lock.lock(); stageHook = newValue; lock.unlock() }
    }
    private func visitTestStage(_ stage: TestStage) { stageHookForTesting?(stage) }
#endif

    /// Tests accept a deletion while hydrate is paused before publishing.
    private var hydrateHook: (@Sendable () -> Void)?

    private init(
        fileURL: URL?,
        limit: Int,
        memory: OfflineSessionCacheSnapshot?,
        hydrateHook: (@Sendable () -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.limit = limit
        self.hydrateHook = hydrateHook
        if let memory {
            snapshot = OfflineSessionCachePolicy.prunedSnapshot(memory, offlineCacheLimit: limit)
            durableSnapshot = snapshot
            hydrated = true
            publish(snapshot, ready: true, error: nil)
        } else {
            enqueueOperation { self.hydrate() }
        }
    }

#if DEBUG
    static func isolatedForTesting(
        fileURL: URL,
        limit: Int,
        beforeHydratePublish: @escaping @Sendable () -> Void
    ) -> SessionCacheWorker {
        SessionCacheWorker(
            fileURL: fileURL,
            limit: limit,
            memory: nil,
            hydrateHook: beforeHydratePublish
        )
    }
#endif

    func updateContext(source: UUID, context: Context) {
        lock.lock()
        defer { lock.unlock() }
        if var grant = grants[source], grant.context.sameConnection(as: context) {
            if grant.context.sessionID != context.sessionID {
                grant.selection = UUID()
            }
            grant.context = context
            grants[source] = grant
        } else {
            grants[source] = Grant(context: context)
        }
    }

    func removeSource(_ source: UUID) {
        lock.lock()
        grants.removeValue(forKey: source)
        observers.removeValue(forKey: source)
        lock.unlock()
    }

    func observe(source: UUID, _ observer: @escaping @Sendable (Status) -> Void) {
        lock.lock()
        observers[source] = observer
        let current = status
        lock.unlock()
        observer(current)
    }

    func currentStatus() -> Status {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    /// Hydration/flush barriers alone are reads. Admitted permits, queued writes,
    /// and failed writes still require the normal lifecycle flush barrier.
    var hasPendingMutations: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingMutations > 0 || !liveOrders.isEmpty || failureState != nil
    }

    func cachedSession(hostID: UUID?, sessionID: String) -> OfflineCachedSession? {
        lock.lock(); defer { lock.unlock() }
        guard let hostID else { return nil }
        return sessionsByHost[hostID]?[sessionID]
    }

    func sessionIDs(hostID: UUID?) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let hostID else { return [] }
        return idsByHost[hostID] ?? []
    }

    func mirroredSnapshot() -> OfflineSessionCacheSnapshot {
        lock.lock(); defer { lock.unlock() }
        return mirror
    }

    func turnLimit() -> Int {
        lock.lock(); defer { lock.unlock() }
        return CacheRetention.turnsPerSessionLimit(offlineCacheLimit: limit)
    }

    /// Compatibility alias; the configured unit is a complete turn.
    func itemLimit() -> Int { turnLimit() }

    func waitUntilReady() async {
        while !currentStatus().ready {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }
    }

    func updateLimit(_ limit: Int) {
        lock.lock(); self.limit = limit; lock.unlock()
        // Policy changes prune the in-memory projection; like hydration they do
        // not submit a disk write. Network mutations still queue behind them.
        enqueueOperation {
            guard self.loadFailure == nil else {
                self.endOperation()
                return
            }
            self.snapshot = self.pruned(self.snapshot)
            let published = self.publish(
                self.snapshot,
                ready: true,
                error: self.currentLoadError(),
                onlyIfPendingEquals: 1
            )
            if !published {
                self.lock.lock(); self.mirrorPublishPending = true; self.lock.unlock()
            }
            self.endOperation()
        }
    }

    func permit(source: UUID, lease: OfflineSessionCacheWriteLease, draft: Bool) -> Permit? {
        lock.lock(); defer { lock.unlock() }
        guard let grant = grants[source], grant.context.active, !grant.hostRevoked,
              !grant.revokedSessions.contains(lease.sessionID),
              lease.isCurrentHost(clientID: grant.context.clientID, connectionGeneration: grant.context.generation, hostID: grant.context.hostID),
              draft || grant.context.sessionID == lease.sessionID else { return nil }
        nextOrder &+= 1
        let key = entityKey(hostID: lease.hostID, sessionID: lease.sessionID, draft: draft)
        liveOrders[key, default: []].insert(nextOrder)
        return Permit(source: source, connection: grant.connection, selection: draft ? nil : grant.selection,
                      hostID: lease.hostID, sessionID: lease.sessionID, order: nextOrder, key: key)
    }

    /// A permit that was never submitted must not keep a later order alive and
    /// suppress an earlier accepted write. Only remove the exact live admission;
    /// the applied floor recorded by an earlier commit must stay in place.
    func abandon(_ permit: Permit) {
        lock.lock(); defer { lock.unlock() }
        removeLiveOrderLocked(permit)
    }

    private func valid(_ permit: Permit) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return validLocked(permit)
    }

    /// Caller holds the admission/mirror lock, including at final publication.
    private func validLocked(_ permit: Permit) -> Bool {
        guard let grant = grants[permit.source], grant.context.active, !grant.hostRevoked,
              grant.connection == permit.connection,
              !grant.revokedSessions.contains(permit.sessionID),
              (appliedOrders[permit.key] ?? 0) <= permit.order,
              (liveOrders[permit.key] ?? []).allSatisfy({ $0 <= permit.order }) else { return false }
        return permit.selection.map { $0 == grant.selection && grant.context.sessionID == permit.sessionID } ?? true
    }

    /// Admission happens synchronously; no unstructured Task may reorder inputs.
    func submit(_ permit: Permit, mutation: @escaping @Sendable (inout OfflineSessionCacheSnapshot) -> Void,
                completion: @escaping @Sendable (Outcome) -> Void = { _ in }) {
        let queuedAt = ContinuousClock.now
        enqueueOperation(mutating: true) {
            guard self.valid(permit) else {
                self.finishAdmission(permit)
                self.endOperation()
                completion(.superseded)
                return
            }
            self.commit(permit: permit, queuedAt: queuedAt, valid: { self.valid(permit) }, mutation: mutation) { outcome in
                self.endOperation()
                completion(outcome)
            }
        }
    }

    func delete(hostID: UUID, sessionIDs: Set<String>?) {
        let queuedAt = ContinuousClock.now
        // Revoke before queueing the deletion. Old jobs paused at the commit hook
        // fail their second fence; a commit already in progress precedes this barrier.
        lock.lock()
        for source in Array(grants.keys) where grants[source]?.context.hostID == hostID {
            if let sessionIDs { grants[source]?.revokedSessions.formUnion(sessionIDs) }
            else { grants[source]?.hostRevoked = true }
        }
        removeLatestOrders(hostID: hostID, sessionIDs: sessionIDs)
        enqueueOperationLocked(mutating: true) {
            self.commit(queuedAt: queuedAt, valid: { true }, mutation: { snapshot in
                if let sessionIDs {
                    for id in sessionIDs { snapshot.removeSessionAndDraft(hostID: hostID, sessionID: id) }
                } else { snapshot.removeHost(hostID) }
            }, completion: { _ in self.endOperation() })
        }
        lock.unlock()
    }

    func reconcile(hostID: UUID, authoritative: Set<String>) {
        let queuedAt = ContinuousClock.now
        enqueueOperation(mutating: true) {
            let removed = Set(self.snapshot.sessionIDs(hostID: hostID)).subtracting(authoritative)
            guard !removed.isEmpty else {
                self.endOperation()
                return
            }
            self.lock.lock()
            for source in Array(self.grants.keys) where self.grants[source]?.context.hostID == hostID {
                self.grants[source]?.revokedSessions.formUnion(removed)
            }
            self.removeLatestOrders(hostID: hostID, sessionIDs: removed)
            self.lock.unlock()
            self.commit(queuedAt: queuedAt, valid: { true }, mutation: { snapshot in
                for id in removed { snapshot.removeSessionAndDraft(hostID: hostID, sessionID: id) }
            }, completion: { _ in self.endOperation() })
        }
    }

    func flush() async -> Outcome {
        let result = await flushResult()
        return result.outcome
    }

    func flushResult() async -> FlushResult {
        // 日志：每次 flush 的开始/结束（耗时、条数、结果）；成功只记 debug，失败用 warn。
        let logStartedAt = Date()
        PILog.debug("Cache", "cache flush start")
        let result: FlushResult = await withCheckedContinuation { continuation in
            lock.lock()
            enqueueOperationLocked {
                self.lock.lock()
                let failure = self.failureState
                let revision = self.status.revision
                self.lock.unlock()
                self.endOperation()
                let outcome: Outcome = failure.map { Outcome.failed($0) } ?? .committed
                if case .failed(let error) = outcome {
                    PILog.warn(
                        "Cache",
                        "cache flush failed sessions=\(self.snapshot.sessions.count) entries=\(self.snapshot.entries.count) elapsedMs=\(Int(Date().timeIntervalSince(logStartedAt) * 1000)) error=\(error.localizedDescription)"
                    )
                } else {
                    PILog.debug(
                        "Cache",
                        "cache flush end sessions=\(self.snapshot.sessions.count) entries=\(self.snapshot.entries.count) elapsedMs=\(Int(Date().timeIntervalSince(logStartedAt) * 1000))"
                    )
                }
                continuation.resume(returning: FlushResult(outcome: outcome, statusRevision: revision))
            }
            lock.unlock()
        }
        return result
    }

    private func enqueueOperation(mutating: Bool = false, _ work: @escaping @Sendable () -> Void) {
        lock.lock()
        enqueueOperationLocked(mutating: mutating, work)
        lock.unlock()
    }

    /// Caller must hold `lock`; enqueueing under the admission lock makes a
    /// concurrent `flush` observe either all of this operation or none of it.
    private func enqueueOperationLocked(mutating: Bool = false, _ work: @escaping @Sendable () -> Void) {
        pendingOperations += 1
        if mutating { pendingMutations += 1 }
        queue.async {
            defer {
                if mutating {
                    self.lock.lock(); self.pendingMutations -= 1; self.lock.unlock()
                }
            }
            work()
        }
    }

    private func endOperation() {
        lock.lock()
        pendingOperations = max(0, pendingOperations - 1)
        let needsFallbackPublish = pendingOperations == 0
            && hydrated
            && (!status.ready || mirrorPublishPending)
        lock.unlock()
        guard needsFallbackPublish else { return }
        _ = publish(
            snapshot,
            ready: true,
            error: currentFailure()?.localizedDescription,
            onlyIfPendingEquals: 0
        )
    }

    private func hydrate() {
        do {
            try loadFromDisk()
            hydrateHook?()
            setFailure(nil)
            lock.lock(); hydrated = true; lock.unlock()
            // A deletion/mutation accepted during hydrate is already queued after
            // this operation. Publishing the disk mirror here would briefly make
            // the deleted entity visible as "ready" again.
            _ = publish(snapshot, ready: true, error: nil, onlyIfPendingEquals: 1)
        } catch {
            loadFailure = error
            setFailure(error)
            lock.lock(); hydrated = true; lock.unlock()
            publish(snapshot, ready: true, error: error.localizedDescription)
        }
        endOperation()
    }

    private func loadFromDisk() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileURL.pathExtension.lowercased() == "json" {
            durableSnapshot = try OfflineSessionCacheFile.load(from: fileURL)?.snapshot ?? .init()
        } else {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try OfflineSessionCacheSQLite.migrateLegacyJSON(from: SessionCacheStore.legacyJSONURL(for: fileURL), to: fileURL)
            }
            let loaded = try OfflineSessionCacheSQLite(url: fileURL)
            durableSnapshot = try loaded.loadSnapshot()
            database = loaded
        }
        snapshot = pruned(durableSnapshot)
    }

    private func retryEncryptedCacheLoad() {
        guard let loadFailure else { return }
        switch loadFailure {
        case OfflineCacheEncryptionError.unavailable, OfflineSessionCacheSQLiteError.decryptionFailed:
            // Re-read the durable state before accepting a write after Keychain recovery.
            guard (try? loadFromDisk()) != nil else { return }
            self.loadFailure = nil
            setFailure(nil)
            lock.lock(); mirrorPublishPending = true; lock.unlock()
        default:
            break
        }
    }

    private func commit(permit: Permit? = nil, queuedAt: ContinuousClock.Instant, valid: () -> Bool,
                        mutation: (inout OfflineSessionCacheSnapshot) -> Void,
                        completion: (Outcome) -> Void) {
        let waiting = queuedAt.duration(to: .now).components
        let queueWaitMs = waiting.seconds * 1_000 + waiting.attoseconds / 1_000_000_000_000_000
        let operation = PILogOperation("Cache", "cache write", fields: "entries=\(snapshot.entries.count) queueWaitMs=\(queueWaitMs)")
        var outcome = "superseded"
        var writeStatistics: OfflineSessionCacheSQLite.WriteStatistics?
        defer {
            operation.finish(outcome: outcome, fields: "entries=\(snapshot.entries.count) inserted=\(writeStatistics?.insertedRows ?? 0) deleted=\(writeStatistics?.deletedRows ?? 0) transactions=\(writeStatistics?.transactionCount ?? 0)")
        }
        retryEncryptedCacheLoad()
        guard let failure = loadFailure else {
            var next = snapshot
#if DEBUG
            defer { visitTestStage(.finished) }
            visitTestStage(.afterRead)
#endif
            mutation(&next)
            next = pruned(next)
            beforeCommitForTesting?()
#if DEBUG
            visitTestStage(.beforeCommit)
#endif
            guard valid() else {
                if let permit { finishAdmission(permit) }
                completion(.superseded)
                return
            }
            do {
                let writeHook = beforeWriteForTesting
                try writeHook?()
#if DEBUG
                visitTestStage(.beforeWrite)
#endif
                // Admission may change while the adapter is waiting for IO. Recheck
                // at the actual write boundary, after every potentially blocking hook.
                guard valid() else {
                    if let permit { finishAdmission(permit) }
                    completion(.superseded)
                    return
                }
                let needsInitialJSON = fileURL.map {
                    $0.pathExtension.lowercased() == "json" && !FileManager.default.fileExists(atPath: $0.path)
                } ?? false
                let needsWrite = next != durableSnapshot || needsInitialJSON
                if let fileURL, needsWrite {
                    if fileURL.pathExtension.lowercased() == "json" {
                        try OfflineSessionCacheFile.save(.init(snapshot: next), to: fileURL)
                    } else {
                        guard let database else { throw CocoaError(.fileWriteUnknown) }
                        writeStatistics = try database.saveChanges(from: durableSnapshot, to: next)
                        try? FileManager.default.removeItem(at: SessionCacheStore.legacyJSONURL(for: fileURL))
                    }
                }
                outcome = needsWrite ? "committed" : "unchanged"
                // Advance immediately after SQL success, even if context changes
                // before UI publication. Future deltas must reflect actual disk.
                durableSnapshot = next
                snapshot = next
                if let permit { markApplied(permit) }
                guard valid() else { outcome = "superseded"; completion(.superseded); return }
                setFailure(nil)
                let published = publish(next, ready: true, error: nil, permit: permit)
                if !published { outcome = "superseded" }
                completion(published ? .committed : .superseded)
            } catch {
                guard valid() else {
                    if let permit { finishAdmission(permit) }
                    completion(.superseded)
                    return
                }
                // Keep the logical desired state. A failed deletion must stay
                // deleted in the mirror and in the next accepted mutation, so a
                // later successful write cannot resurrect what the caller removed.
                snapshot = next
                if let permit { markApplied(permit) }
                outcome = "failed"
                PILog.warn("Cache", "cache write failed op=\(operation.id) error=\(error.localizedDescription)")
                setFailure(error)
                let published = publish(next, ready: true, error: error.localizedDescription, permit: permit)
                completion(published ? .failed(error) : .superseded)
            }
            return
        }
        outcome = "failed"
        PILog.warn("Cache", "cache write failed op=\(operation.id) error=\(failure.localizedDescription)")
        if let permit { finishAdmission(permit) }
        completion(.failed(failure))
    }

    private func pruned(_ value: OfflineSessionCacheSnapshot) -> OfflineSessionCacheSnapshot {
        lock.lock(); let limit = self.limit; lock.unlock()
        return OfflineSessionCachePolicy.prunedSnapshot(value, offlineCacheLimit: limit)
    }

    private func currentLoadError() -> String? {
        lock.lock(); defer { lock.unlock() }
        return status.error
    }

    private func currentFailure() -> Error? {
        lock.lock(); defer { lock.unlock() }
        return failureState
    }

    private func setFailure(_ error: Error?) {
        lock.lock(); failureState = error; lock.unlock()
    }

    private func entityKey(hostID: UUID, sessionID: String, draft: Bool) -> String {
        [hostID.uuidString, sessionID, draft ? "draft" : "session"].joined(separator: "|")
    }

    private func finishAdmission(_ permit: Permit) {
        lock.lock(); defer { lock.unlock() }
        removeLiveOrderLocked(permit)
    }

    /// Records that this order reached the apply path (committed, or failed
    /// after the desired snapshot was updated). The floor outlives the live
    /// admission so a later abandon of a newer permit cannot reopen it.
    private func markApplied(_ permit: Permit) {
        lock.lock(); defer { lock.unlock() }
        if permit.order > (appliedOrders[permit.key] ?? 0) {
            appliedOrders[permit.key] = permit.order
        }
        removeLiveOrderLocked(permit)
    }

    /// Caller must hold `lock`.
    private func removeLiveOrderLocked(_ permit: Permit) {
        liveOrders[permit.key]?.remove(permit.order)
        if liveOrders[permit.key]?.isEmpty == true {
            liveOrders.removeValue(forKey: permit.key)
        }
    }

    /// Caller must hold `lock`.
    private func removeLatestOrders(hostID: UUID, sessionIDs: Set<String>?) {
        if let sessionIDs {
            let prefixes = sessionIDs.map { "\(hostID.uuidString)|\($0)|" }
            liveOrders = liveOrders.filter { entry in
                !prefixes.contains { entry.key.hasPrefix($0) }
            }
            appliedOrders = appliedOrders.filter { entry in
                !prefixes.contains { entry.key.hasPrefix($0) }
            }
        } else {
            let prefix = "\(hostID.uuidString)|"
            liveOrders = liveOrders.filter { !$0.key.hasPrefix(prefix) }
            appliedOrders = appliedOrders.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    @discardableResult
    private func publish(
        _ value: OfflineSessionCacheSnapshot,
        ready: Bool,
        error: String?,
        onlyIfPendingEquals expectedPending: Int? = nil,
        permit: Permit? = nil
    ) -> Bool {
        // Compare outside the short admission lock. Identical values do not
        // rebuild the history indexes or notify SwiftUI a second time.
        lock.lock()
        let previous = mirror
        let previousStatus = status
        lock.unlock()
        if previous == value && previousStatus.ready == ready && previousStatus.error == error {
            lock.lock(); defer { lock.unlock() }
            if let permit, !validLocked(permit) { return false }
            if let expectedPending, pendingOperations != expectedPending { return false }
            mirrorPublishPending = false
            return true
        }
        // Build lookup indexes on the worker, never while a SwiftUI getter runs.
        let hosts = Set(value.sessions.map(\.hostID) + value.entries.map(\.hostID)
            + value.cursors.map(\.hostID) + value.approvals.map(\.hostID) + value.drafts.map(\.hostID)).compactMap { $0 }
        var indexed: [UUID: [String: OfflineCachedSession]] = [:]
        var ids: [UUID: [String]] = [:]
        for host in hosts {
            ids[host] = value.sessionIDs(hostID: host)
            for id in ids[host] ?? [] { indexed[host, default: [:]][id] = value.cachedSession(hostID: host, sessionID: id) }
        }
#if DEBUG
        if permit != nil { visitTestStage(.beforePublish) }
#endif
        lock.lock()
        if let permit, !validLocked(permit) {
            lock.unlock()
            return false
        }
        if let expectedPending, pendingOperations != expectedPending {
            lock.unlock()
            return false
        }
        let next = Status(ready: ready, error: error, revision: status.revision &+ 1)
        mirror = value
        sessionsByHost = indexed
        idsByHost = ids
        status = next
        mirrorPublishPending = false
        let callbacks = Array(observers.values)
        lock.unlock()
        for callback in callbacks { callback(next) }
        return true
    }
}
