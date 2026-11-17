import Foundation
import Combine
import PIiOSCore

/// Read-only extension projections. All async commits are leased to a Host and connection.
@MainActor
final class ExtensionCatalogModel: ObservableObject {
    struct Context: Hashable {
        let hostID: UUID?
        let generation: Int
        let remoteHostID: String?
        let online: Bool
        let inventorySupported: Bool
        let sessionSupported: Bool
    }

    struct SessionKey: Hashable {
        let hostID: UUID
        let sessionID: String
    }

    @Published private(set) var context = Context(hostID: nil, generation: 0, remoteHostID: nil,
                                                online: false, inventorySupported: false, sessionSupported: false)
    @Published private var inventories: [UUID: ContentState<RACPExtensionInventory>] = [:]
    @Published private var sessions: [SessionKey: ContentState<RACPSessionExtensions>] = [:]
    @Published private var readTimes: [SessionKey: Date] = [:]
    private var inventoryRequests: [UUID: UUID] = [:]
    private var sessionRequests: [SessionKey: UUID] = [:]
    private var eventRevisions: [SessionKey: Int] = [:]
    private var eventCursors: [SessionKey: RACPCursor] = [:]
    private var order: [SessionKey] = []
    private var inventoryOrder: [UUID] = []
    private let limit: Int

    init(limit: Int = 50) { self.limit = max(1, limit) }

    var inventory: ContentState<RACPExtensionInventory> {
        guard let hostID = context.hostID else { return .idle }
        return inventories[hostID] ?? .idle
    }

    func sessionState(_ sessionID: String) -> ContentState<RACPSessionExtensions> {
        guard let hostID = context.hostID else { return .idle }
        return sessions[SessionKey(hostID: hostID, sessionID: sessionID)] ?? .idle
    }

    func sessionResultLabel(_ sessionID: String) -> String {
        switch sessionState(sessionID) {
        case .loaded(let result): return result.latestLabel
        case .loading, .failed: return "上次读取的加载结果"
        case .idle: return "尚未读取"
        }
    }

    func lastRead(_ sessionID: String) -> Date? {
        guard let hostID = context.hostID else { return nil }
        return readTimes[SessionKey(hostID: hostID, sessionID: sessionID)]
    }

    func setContext(_ next: Context) {
        guard context != next else { return }
        if let host = next.hostID, let remote = next.remoteHostID {
            let inventoryMismatch = inventories[host]?.value.map { $0.hostId != remote } ?? false
            let sessionMismatch = sessions.contains { key, state in
                key.hostID == host && state.value.map { $0.hostId != remote } == true
            }
            if inventoryMismatch || sessionMismatch { removeHost(host) }
        }
        inventoryRequests.removeAll()
        sessionRequests.removeAll()
        eventCursors.removeAll()
        // A cached result remains historical until revalidated on this connection.
        for host in Array(inventories.keys) { inventories[host]?.markStale(reason: "连接已变化") }
        for key in Array(sessions.keys) { sessions[key]?.markStale(reason: "连接已变化") }
        context = next
    }

    func refreshInventory(fetch: () async throws -> RACPExtensionInventory) async {
        let lease = context
        guard let host = lease.hostID, lease.online, lease.inventorySupported else { return }
        guard inventoryRequests[host] == nil else { return }
        let request = UUID()
        inventoryRequests[host] = request
        inventories[host] = .loading(stale: inventories[host]?.value)
        inventoryOrder.removeAll { $0 == host }
        inventoryOrder.append(host)
        while inventoryOrder.count > limit {
            let removed = inventoryOrder.removeFirst()
            inventories[removed] = nil
            inventoryRequests[removed] = nil
        }
        defer { if inventoryRequests[host] == request { inventoryRequests[host] = nil } }
        do {
            let result = try await fetch()
            guard context == lease, inventoryRequests[host] == request else { return }
            guard lease.remoteHostID == nil || lease.remoteHostID == result.hostId else {
                throw ExtensionReadError.identityMismatch
            }
            inventories[host] = .loaded(result)
        } catch {
            guard context == lease, inventoryRequests[host] == request else { return }
            inventories[host] = .failed(reason: errorText(error), stale: inventories[host]?.value)
        }
    }

    func refreshSession(_ sessionID: String, fetch: () async throws -> RACPSessionExtensions) async {
        let lease = context
        guard let host = lease.hostID, lease.online, lease.sessionSupported else { return }
        let key = SessionKey(hostID: host, sessionID: sessionID)
        guard sessionRequests[key] == nil else { return }
        let request = UUID()
        sessionRequests[key] = request
        sessions[key] = .loading(stale: sessions[key]?.value)
        touch(key)
        defer { if sessionRequests[key] == request { sessionRequests[key] = nil } }
        // An event received during a query invalidates that response. One follow-up
        // read covers the normal query/event race without an unbounded retry loop.
        for attempt in 0..<2 {
            let eventRevision = eventRevisions[key, default: 0]
            do {
                var result = try await fetch()
                guard context == lease, sessionRequests[key] == request else { return }
                guard result.sessionId == sessionID,
                      lease.remoteHostID == nil || result.hostId == lease.remoteHostID,
                      [result.latestAttempt, result.previousCompleted].compactMap({ $0 }).allSatisfy({
                          $0.hostId == result.hostId && $0.sessionId == sessionID && $0.revision > 0
                      }) else { throw ExtensionReadError.identityMismatch }
                if eventRevisions[key, default: 0] != eventRevision {
                    if attempt == 0 { continue }
                    if let latest = sessions[key]?.value {
                        sessions[key] = .failed(reason: "状态正在变化，下拉重新读取", stale: latest)
                    } else {
                        sessions[key] = .failed(reason: "状态正在变化，请重新读取", stale: nil)
                    }
                    return
                }
                if let previous = sessions[key]?.value?.latestAttempt,
                   let latest = result.latestAttempt, latest.id == previous.id,
                   latest.revision < previous.revision {
                    result.latestAttempt = previous
                }
                sessions[key] = .loaded(result)
                readTimes[key] = Date()
                return
            } catch {
                guard context == lease, sessionRequests[key] == request else { return }
                sessions[key] = .failed(reason: errorText(error), stale: sessions[key]?.value)
                return
            }
        }
    }

    /// Called only after the transport's normal routing, cursor validation and ACK.
    /// True asks the owner for an authoritative refresh (also covers missing metadata).
    func observe(_ snapshot: RACPExtensionSnapshot, epoch: String?, sequence: Int?) -> Bool {
        guard let host = context.hostID, context.online, context.sessionSupported,
              context.remoteHostID == nil || context.remoteHostID == snapshot.hostId else { return false }
        let key = SessionKey(hostID: host, sessionID: snapshot.sessionId)
        if let epoch, let sequence {
            if let cursor = eventCursors[key], cursor.epoch == epoch, sequence <= cursor.sequence { return false }
            eventCursors[key] = RACPCursor(epoch: epoch, sequence: sequence)
        }
        if let state = sessions[key], var result = state.value,
           let old = result.latestAttempt, old.id == snapshot.id {
            guard snapshot.revision > old.revision else { return false }
            result.latestAttempt = snapshot
            // An event cannot validate cached policy/current-turn identity after reconnect.
            switch state {
            case .loaded: sessions[key] = .loaded(result)
            case .loading: sessions[key] = .loading(stale: result)
            case .failed(let reason, _): sessions[key] = .failed(reason: reason, stale: result)
            case .idle: break
            }
            readTimes[key] = Date()
        }
        // A different snapshot ID may be a queued old event delivered after a
        // newer query. Only an authoritative read may select a different round.
        eventRevisions[key, default: 0] += 1
        touch(key)
        return true
    }

    func removeSessions(_ ids: Set<String>, hostID: UUID) {
        for key in Array(sessions.keys) where key.hostID == hostID && ids.contains(key.sessionID) { remove(key) }
    }

    func removeHost(_ hostID: UUID) {
        inventoryRequests[hostID] = nil
        inventories[hostID] = nil
        inventoryOrder.removeAll { $0 == hostID }
        for key in Set(order + Array(sessionRequests.keys)) where key.hostID == hostID { remove(key) }
    }

    private func touch(_ key: SessionKey) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit { remove(order[0]) }
    }


    private func remove(_ key: SessionKey) {
        sessions[key] = nil
        sessionRequests[key] = nil
        readTimes[key] = nil
        eventRevisions[key] = nil
        eventCursors[key] = nil
        order.removeAll { $0 == key }
    }

    private func errorText(_ error: Error) -> String {
        if error is CancellationError { return "读取已取消" }
        if error is ExtensionReadError { return "服务器返回的扩展身份不匹配" }
        // Raw server errors may contain paths or credentials. Keep diagnostic detail
        // in the explicitly sanitized extension records rather than this transport error.
        return "无法读取扩展，请重新读取"
    }

#if DEBUG
    func seedForFixture(hostID: UUID, inventory: RACPExtensionInventory, results: [String: RACPSessionExtensions]) {
        inventories[hostID] = .failed(reason: "未连接", stale: inventory)
        for (id, result) in results {
            let key = SessionKey(hostID: hostID, sessionID: id)
            sessions[key] = .failed(reason: "未连接", stale: result)
            readTimes[key] = ISO8601DateFormatter().date(from: result.latestAttempt?.startedAt ?? "")
            touch(key)
        }
    }
#endif

    private enum ExtensionReadError: Error { case identityMismatch }
}
