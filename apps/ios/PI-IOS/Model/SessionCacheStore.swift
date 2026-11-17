import Foundation
import PIiOSCore
import PIiOSNet

/// UI facade for the shared serial cache owner. Synchronous reads access only
/// indexed memory; every canonical read/modify/write runs on the worker.
final class SessionCacheStore: @unchecked Sendable {
    typealias Entry = OfflineSessionCacheEntry
    typealias Snapshot = OfflineSessionCacheSnapshot
    typealias Cursor = OfflineSessionCursor
    typealias Approval = OfflineSessionApproval
    typealias Draft = OfflineSessionDraft
    typealias Session = OfflineSessionCacheSession
    typealias WriteLease = OfflineSessionCacheWriteLease
    typealias Permit = SessionCacheWorker.Permit
    typealias Outcome = SessionCacheWorker.Outcome
    typealias FlushResult = SessionCacheWorker.FlushResult

    struct SessionInput: Sendable {
        let view: RACPSessionView
        let summary: RACPSessionSummary?
        let mode: String
        let permission: String
        let modelID: String?
        let providerID: String?
        let hostID: UUID
        let sessionID: String
    }

    private let source = UUID()
    let worker: SessionCacheWorker

    init(offlineCacheLimit: Int, fileURL: URL? = SessionCacheStore.defaultURL()) {
        worker = .shared(fileURL: fileURL, limit: offlineCacheLimit, memory: nil)
    }

    init(offlineCacheLimit: Int, inMemory snapshot: Snapshot) {
        worker = .shared(fileURL: nil, limit: offlineCacheLimit, memory: snapshot)
    }

#if DEBUG
    init(
        offlineCacheLimit: Int,
        fileURL: URL,
        beforeHydratePublish: @escaping @Sendable () -> Void
    ) {
        worker = SessionCacheWorker.isolatedForTesting(
            fileURL: fileURL,
            limit: offlineCacheLimit,
            beforeHydratePublish: beforeHydratePublish
        )
    }
#endif

    deinit { worker.removeSource(source) }

    func withOfflineCacheLimit(_ limit: Int) -> SessionCacheStore {
        worker.updateLimit(limit)
        return self
    }

    static func defaultURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("PIiOS", isDirectory: true).appendingPathComponent("session-cache.sqlite")
    }

    static func legacyJSONURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("session-cache-v1.json")
    }

    static func defaultRequestKeyURL() -> URL? {
        defaultURL()?.deletingLastPathComponent().appendingPathComponent("request-keys-v1.json")
    }

    func observe(_ callback: @escaping @Sendable (SessionCacheWorker.Status) -> Void) {
        worker.observe(source: source, callback)
    }

    var status: SessionCacheWorker.Status { worker.currentStatus() }
    var hasPendingMutations: Bool { worker.hasPendingMutations }
    var turnLimit: Int { worker.turnLimit() }
    /// Compatibility alias; the configured unit is a complete turn.
    var itemLimit: Int { turnLimit }

    func updateContext(clientID: UUID, generation: Int, hostID: UUID?, sessionID: String?, active: Bool) {
        worker.updateContext(source: source, context: .init(clientID: clientID, generation: generation,
                                                          hostID: hostID, sessionID: sessionID, active: active))
    }

    func permit(for lease: WriteLease, draft: Bool) -> Permit? { worker.permit(source: source, lease: lease, draft: draft) }
    func abandon(_ permit: Permit) { worker.abandon(permit) }
    func loadSnapshot() -> Snapshot { worker.mirroredSnapshot() }
    func cachedSession(hostID: UUID?, sessionID: String) -> OfflineCachedSession? { worker.cachedSession(hostID: hostID, sessionID: sessionID) }
    func sessionIDs(hostID: UUID?) -> [String] { worker.sessionIDs(hostID: hostID) }
    func waitUntilReady() async { await worker.waitUntilReady() }
    func flush() async -> Outcome { await worker.flush() }
    func flushResult() async -> FlushResult { await worker.flushResult() }

    func reconcile(hostID: UUID, authoritative: Set<String>) { worker.reconcile(hostID: hostID, authoritative: authoritative) }
    func removeSessions(hostID: UUID, sessionIDs: Set<String>) { worker.delete(hostID: hostID, sessionIDs: sessionIDs) }
    func removeHost(_ hostID: UUID) { worker.delete(hostID: hostID, sessionIDs: nil) }

    func saveSession(_ input: SessionInput, permit: Permit) async -> Outcome {
        await withCheckedContinuation { continuation in
            worker.submit(permit, mutation: { snapshot in Self.apply(input, to: &snapshot) }, completion: { continuation.resume(returning: $0) })
        }
    }

    func saveDraft(sessionID: String, hostID: UUID, text: String, idempotencyKey: String?, permit: Permit) {
        worker.submit(permit, mutation: { snapshot in
            let previous = snapshot.drafts.first { $0.hostID == hostID && $0.sessionId == sessionID }
            let shouldKeep = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && idempotencyKey != nil
            if shouldKeep, previous?.text == text, previous?.idempotencyKey == idempotencyKey { return }
            if !shouldKeep && previous == nil { return }
            snapshot.drafts.removeAll { $0.hostID == hostID && $0.sessionId == sessionID }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let idempotencyKey {
                snapshot.drafts.append(Draft(hostID: hostID, sessionId: sessionID, text: text,
                                             idempotencyKey: idempotencyKey, updatedAt: Date()))
            }
        })
    }

    private static func apply(_ input: SessionInput, to snapshot: inout Snapshot) {
        let now = Date()
        let view = input.view
        let hostID = input.hostID
        let sessionID = input.sessionID
        let existing = snapshot.cachedSession(hostID: hostID, sessionID: sessionID)
        let existingEntries = existing?.entries ?? []
        // Dates are anchors even when hasMoreHistory=false replaces the old rows.
        // Only the decision to merge old entries depends on hasMoreHistory.
        let existingDates = Dictionary(existingEntries.map { ($0.id, $0.createdAt) }, uniquingKeysWith: { max($0, $1) })
        let existingByID = Dictionary(existingEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let originalDates = view.items.map { cacheCreatedAt(from: $0.payload) }
        let knownDates = view.items.enumerated().map { index, item in
            originalDates[index] ?? existingDates[item.id]
        }
        let resolvedDates = resolvingDates(knownDates, now: now)
        var turnKeyer = ConversationTurnKeyer()
        let projected = view.items.enumerated().map { index, item -> (Entry, Bool) in
            let turnId = turnKeyer.key(itemID: item.id, role: item.role, turnID: item.turnId)
            let previous = existingByID[item.id]
            let unchanged = previous?.text == (item.text ?? "") && previous?.kind == item.kind
                && previous?.role == item.role && previous?.toolName == item.toolName
                && previous?.status == item.status && previous?.turnId == turnId
                && previous?.epoch == view.cursor?.epoch
            return (Entry(id: item.id, sessionId: sessionID, hostID: hostID,
                          text: item.text ?? "", createdAt: resolvedDates[index],
                          kind: item.kind, role: item.role, toolName: item.toolName, status: item.status,
                          epoch: view.cursor?.epoch,
                          sequence: item.payload.value(at: ["sequence"])?.intValue
                            ?? (unchanged ? previous?.sequence : nil) ?? view.cursor?.sequence,
                          turnId: turnId), originalDates[index] != nil)
        }
        let entriesToMerge = view.hasMoreHistory ? existingEntries : []
        let merged = OfflineSessionCachePolicy.merged(entriesToMerge, with: projected.map { $0.0 })
        let originalIDs = Set(projected.filter { $0.1 }.map { $0.0.id })
        let retained = merged.filter { !originalIDs.contains($0.id) }
        let entries = OfflineSessionCachePolicy.merged(retained, with: projected.map { $0.0 })
        let previousMetadata = snapshot.cachedSessionMetadata(hostID: hostID, sessionID: sessionID)
        let approvals = view.pendingApprovals.map { card in
            Approval(id: card.id, sessionId: sessionID, hostID: hostID,
                     payload: CacheFieldPolicy.redactedForCache(card.payload), revision: card.revision,
                     status: card.status ?? "pending", decision: card.payload.value(at: ["decision"])?.stringValue,
                     createdAt: cacheCreatedAt(from: card.payload)
                        ?? existing?.approvals.first(where: { $0.id == card.id })?.createdAt ?? now)
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
        let cursor = view.cursor.map { value in
            let unchanged = existing?.cursor?.epoch == value.epoch && existing?.cursor?.sequence == value.sequence
            return Cursor(hostID: hostID, sessionId: sessionID, epoch: value.epoch,
                          sequence: value.sequence, updatedAt: unchanged ? existing!.cursor!.updatedAt : now)
        }
        var metadata = input.summary.map { summary in
            Session(hostID: hostID, id: sessionID, title: summary.title,
                    projectID: summary.projectId, mode: input.mode,
                    permissionMode: input.permission, modelID: input.modelID,
                    providerID: input.providerID, epoch: view.cursor?.epoch,
                    sequence: view.cursor?.sequence, updatedAt: previousMetadata?.updatedAt ?? now)
        }
        let unchanged = existingEntries == entries && existing?.cursor == cursor
            && (existing?.approvals ?? []) == approvals && previousMetadata == metadata
        if unchanged { return }
        metadata?.updatedAt = now
        // Drafts are independent mutations and survive session replacement.
        snapshot.removeSession(hostID: hostID, sessionID: sessionID)
        snapshot.entries.append(contentsOf: entries)
        if let metadata { snapshot.sessions.append(metadata) }
        if let cursor { snapshot.cursors.append(cursor) }
        snapshot.approvals.append(contentsOf: approvals)
    }

    /// Resolves only missing dates from ordered known(original/existing) anchors.
    /// Known values remain untouched; prepended rows never become newer merely
    /// because they were first persisted in a later save.
    private static func resolvingDates(_ anchors: [Date?], now: Date) -> [Date] {
        let knownIndices = anchors.indices.filter { anchors[$0] != nil }
        guard let firstKnown = knownIndices.first, let lastKnown = knownIndices.last else {
            return anchors.indices.map { now.addingTimeInterval(Double($0) * 0.000_001) }
        }
        var resolved = anchors
        if firstKnown > 0, let anchor = anchors[firstKnown] {
            for index in 0..<firstKnown {
                resolved[index] = anchor.addingTimeInterval(-Double(firstKnown - index) * 0.000_001)
            }
        }
        if lastKnown + 1 < anchors.count, let anchor = anchors[lastKnown] {
            for index in (lastKnown + 1)..<anchors.count {
                resolved[index] = anchor.addingTimeInterval(Double(index - lastKnown) * 0.000_001)
            }
        }
        if knownIndices.count > 1 {
            var left = firstKnown
            for right in knownIndices.dropFirst() {
                if right - left > 1, let leftDate = anchors[left], let rightDate = anchors[right] {
                    let interval = rightDate.timeIntervalSince(leftDate)
                    for index in (left + 1)..<right {
                        let ratio = Double(index - left) / Double(right - left)
                        resolved[index] = leftDate.addingTimeInterval(interval * ratio)
                    }
                }
                left = right
            }
        }
        // Every index is either known, outside an extreme anchor, or between two anchors.
        return resolved.map { $0 ?? now }
    }

    private static func cacheCreatedAt(from payload: JSONValue) -> Date? {
        for key in ["createdAt", "created_at"] {
            guard let value = payload.value(at: [key]) else { continue }
            switch value {
            case .number(let raw): return dateFromEpoch(raw)
            case .string(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let epoch = Double(trimmed), let date = dateFromEpoch(epoch) { return date }
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return fractional.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
            default: continue
            }
        }
        return nil
    }

    private static func dateFromEpoch(_ raw: Double) -> Date? {
        guard raw.isFinite, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw >= 100_000_000_000 ? raw / 1_000 : raw)
    }
}
