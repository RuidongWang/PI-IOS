import Foundation
import SQLite3
import XCTest
@testable import PIiOSCore

final class OfflineSessionCacheIncrementalTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("cache.sqlite") }
    private let host = UUID()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testDraftUpdateLeaves3500EncryptedMessagesUntouchedAndNoOpSkipsTransaction() throws {
        let database = try OfflineSessionCacheSQLite(url: url)
        let old = OfflineSessionCacheSnapshot(entries: (0..<3500).map {
            entry("item-\($0)", session: "session", host: host)
        }, drafts: [draft("old")])
        try database.save(old)
        let encryptedBefore = try query("SELECT text FROM items ORDER BY id")
        var next = old
        next.drafts[0].text = "latest draft"
        next.drafts[0].updatedAt = date.addingTimeInterval(1)
        let stats = try database.saveChanges(from: old, to: next)
        XCTAssertEqual(stats.changedTables, ["drafts"])
        XCTAssertEqual(stats.deletedRows, 1)
        XCTAssertEqual(stats.insertedRows, 1)
        XCTAssertEqual(stats.transactionCount, 1)
        XCTAssertEqual(try query("SELECT text FROM items ORDER BY id"), encryptedBefore)
        XCTAssertEqual(try database.loadSnapshot().drafts, next.drafts)
        let noOp = try database.saveChanges(from: next, to: next)
        XCTAssertEqual(noOp.transactionCount, 0)
        XCTAssertEqual(noOp.insertedRows + noOp.deletedRows, 0)
        print("CACHE_EVIDENCE entries=3500 draftUpdate inserted=\(stats.insertedRows) deleted=\(stats.deletedRows) elapsedMs=\(stats.elapsedMilliseconds) noOpTransactions=\(noOp.transactionCount)")
    }

    func testCompositeKeysPreserveSameIDsAcrossHostsAndSessionsIncludingNilHost() throws {
        let otherHost = UUID()
        let old = OfflineSessionCacheSnapshot(entries: [
            entry("same", session: "a", host: host),
            entry("same", session: "b", host: host),
            entry("same", session: "a", host: otherHost),
            entry("same", session: "a", host: nil)
        ], approvals: [approval(session: "a"), approval(session: "b")])
        let database = try OfflineSessionCacheSQLite(url: url)
        try database.save(old)
        var next = old
        next.entries.removeFirst()
        next.entries[0].text = "changed b"
        next.approvals.removeFirst()
        let stats = try database.saveChanges(from: old, to: next)
        XCTAssertEqual(stats.deletedRows, 3)
        XCTAssertEqual(stats.insertedRows, 1)
        let loaded = try database.loadSnapshot()
        XCTAssertEqual(Set(loaded.entries.map { "\($0.hostID?.uuidString ?? "nil")/\($0.sessionId)/\($0.text)" }),
                       Set(next.entries.map { "\($0.hostID?.uuidString ?? "nil")/\($0.sessionId)/\($0.text)" }))
        XCTAssertEqual(loaded.approvals, next.approvals)
    }

    func testAllTablesRollbackTogetherThenRetryFromDurableBaseline() throws {
        let database = try OfflineSessionCacheSQLite(url: url)
        let old = OfflineSessionCacheSnapshot(
            sessions: [.init(hostID: host, id: "session", title: "old", projectID: nil,
                             mode: nil, permissionMode: nil, modelID: nil, providerID: nil,
                             epoch: "epoch", sequence: 1, updatedAt: date)],
            entries: [entry("item", session: "session", host: host)],
            cursors: [.init(hostID: host, sessionId: "session", epoch: "epoch", sequence: 1, updatedAt: date)],
            approvals: [approval(session: "session")], drafts: [draft("old")])
        try database.save(old)
        var next = old
        next.sessions[0].title = "new"
        next.entries.removeAll()
        next.cursors[0].sequence = 2
        next.approvals[0].revision = 2
        next.drafts[0].text = "new"
        try execute("CREATE TRIGGER reject_draft BEFORE INSERT ON drafts BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        XCTAssertThrowsError(try database.saveChanges(from: old, to: next))
        XCTAssertEqual(try database.loadSnapshot(), old)
        try execute("DROP TRIGGER reject_draft")
        let stats = try database.saveChanges(from: old, to: next)
        XCTAssertEqual(stats.changedTables.count, 5)
        XCTAssertEqual(try database.loadSnapshot(), next)
    }

    func testDuplicateKeysFailBeforeAnyMutation() throws {
        let database = try OfflineSessionCacheSQLite(url: url)
        let old = OfflineSessionCacheSnapshot(drafts: [draft("old")])
        try database.save(old)
        var next = old
        next.drafts.append(draft("duplicate"))
        XCTAssertThrowsError(try database.saveChanges(from: old, to: next))
        XCTAssertEqual(try database.loadSnapshot(), old)
    }

    private func entry(_ id: String, session: String, host: UUID?) -> OfflineSessionCacheEntry {
        .init(id: id, sessionId: session, hostID: host, text: "message-\(session)", createdAt: date)
    }
    private func draft(_ text: String) -> OfflineSessionDraft {
        .init(hostID: host, sessionId: "session", text: text, idempotencyKey: "stable-key", updatedAt: date)
    }
    private func approval(session: String) -> OfflineSessionApproval {
        .init(id: "same", sessionId: session, hostID: host, payload: .object([:]), revision: 1,
              status: "pending", decision: nil, createdAt: date)
    }
    private func execute(_ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw OfflineSessionCacheSQLite.DatabaseError(message: String(cString: sqlite3_errmsg(handle)))
        }
    }
    private func query(_ sql: String) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(String(cString: sqlite3_column_text(statement, 0))) }
        return rows
    }
}
