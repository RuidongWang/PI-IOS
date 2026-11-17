import XCTest

@testable import PIiOSCore

/// 离线缓存的 PI-adaptor 分区、去重和保留上限。
final class OfflineSessionCachePolicyTests: XCTestCase {
    private let hostA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let hostB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testCachedConversationPreservesRolesAndCollapsesLongToolOutput() {
        let output = String(repeating: "网络接收错误。", count: 10_000)
        let entries = [
            OfflineSessionCacheEntry(id: "user", sessionId: "s", hostID: hostA,
                text: "同步今日数据", createdAt: base, kind: "message", role: "user"),
            OfflineSessionCacheEntry(id: "empty", sessionId: "s", hostID: hostA,
                text: "", createdAt: base, kind: "message", role: "assistant"),
            OfflineSessionCacheEntry(id: "tool", sessionId: "s", hostID: hostA,
                text: output, createdAt: base, kind: "tool_call", role: "tool",
                toolName: "Bash", status: "completed", turnId: "turn-1"),
            OfflineSessionCacheEntry(id: "answer", sessionId: "s", hostID: hostA,
                text: "**同步完成**", createdAt: base, kind: "message", role: "assistant")
        ]
        let items = entries.map(\.conversationItem)
        XCTAssertEqual(items[0].role, "user")
        XCTAssertEqual(items[2].text, output, "Presentation must not truncate stored output")
        XCTAssertEqual(items[2].toolName, "Bash")
        XCTAssertEqual(items[2].status, "completed")
        XCTAssertEqual(items[2].turnId, "turn-1")
        let rows = ToolCallGroupingPolicy.rows(for: items)
        XCTAssertEqual(rows.count, 3)
        guard case .toolGroup(let group) = rows[1] else {
            return XCTFail("Cached tool output must use the same collapsed group as live output")
        }
        XCTAssertEqual(group.items.map(\.id), ["tool"])
        XCTAssertEqual(rows.last?.anchorItemID, "answer")
    }

    func testLegacyCachedToolRoleAndEmptyToolStillRenderAsTools() {
        let entry = OfflineSessionCacheEntry(id: "tool", sessionId: "s", hostID: hostA,
            text: "", createdAt: base, role: "toolResult")
        XCTAssertTrue(entry.conversationItem.isToolItem)
        XCTAssertEqual(ToolCallGroupingPolicy.rows(for: [entry.conversationItem]).count, 1)
    }

    func testHostPartitionKeepsSameSessionAndItemIDsSeparate() {
        let entries = [
            entry("itm_1", session: "ses_1", host: hostA, offset: 0, text: "A"),
            entry("itm_1", session: "ses_1", host: hostB, offset: 1, text: "B"),
        ]

        XCTAssertNotEqual(
            OfflineSessionCachePolicy.itemKey(hostID: hostA, sessionID: "ses_1", itemID: "itm_1"),
            OfflineSessionCachePolicy.itemKey(hostID: hostB, sessionID: "ses_1", itemID: "itm_1")
        )
        let pruned = OfflineSessionCachePolicy.prunedEntries(entries, offlineCacheLimit: 200)
        XCTAssertEqual(pruned.count, 2)
        XCTAssertEqual(
            OfflineSessionCachePolicy.cachedEntries(entries, hostID: hostA, sessionID: "ses_1").map(\.text),
            ["A"]
        )
        XCTAssertEqual(
            OfflineSessionCachePolicy.cachedEntries(entries, hostID: hostB, sessionID: "ses_1").map(\.text),
            ["B"]
        )
    }

    func testEmptyHostNeverReturnsEntriesFromOtherHosts() {
        let entries = [entry("itm_1", session: "ses_1", host: hostA, offset: 0)]

        XCTAssertEqual(
            OfflineSessionCachePolicy.cachedEntries(entries, hostID: nil, sessionID: "ses_1"),
            []
        )
        XCTAssertEqual(OfflineSessionCachePolicy.sessionIDs(entries, hostID: nil), [])
    }

    func testPrunesToTwentySessionsAndTwoHundredItemsPerSession() {
        var entries: [OfflineSessionCacheEntry] = []
        for sessionIndex in 0..<25 {
            for itemIndex in 0..<205 {
                entries.append(
                    entry(
                        "itm_\(itemIndex)",
                        session: "ses_\(sessionIndex)",
                        host: hostA,
                        offset: TimeInterval(sessionIndex * 1_000 + itemIndex),
                        turnId: "turn:\(itemIndex)"
                    )
                )
            }
        }

        let pruned = OfflineSessionCachePolicy.prunedEntries(entries, offlineCacheLimit: 200)
        XCTAssertEqual(pruned.count, 20 * 200)
        XCTAssertFalse(pruned.contains { $0.sessionId == "ses_0" })
        XCTAssertFalse(pruned.contains { $0.sessionId == "ses_4" })
        XCTAssertTrue(pruned.contains { $0.sessionId == "ses_24" })
        XCTAssertFalse(pruned.contains {
            $0.sessionId == "ses_24" && $0.id == "itm_0"
        })
    }

    func testDeduplicatesSameSessionItemButKeepsNewestText() {
        let entries = [
            entry("itm_1", session: "ses_1", host: hostA, offset: 0, text: "old"),
            entry("itm_1", session: "ses_1", host: hostA, offset: 1, text: "new"),
        ]

        let deduplicated = OfflineSessionCachePolicy.deduplicatedEntries(entries)
        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated.first?.text, "new")
        XCTAssertEqual(
            OfflineSessionCachePolicy.prunedEntries(entries, offlineCacheLimit: 200).map(\.text),
            ["new"]
        )
    }

    func testDeduplicatedEntriesUsesSequenceBeforeItemKeyForEqualDates() {
        let entries = [
            entry("a", session: "ses_1", host: hostA, offset: 0, sequence: 1),
            entry("z", session: "ses_1", host: hostA, offset: 0, sequence: 9),
        ]
        XCTAssertEqual(
            OfflineSessionCachePolicy.deduplicatedEntries(entries).map(\.id),
            ["z", "a"],
            "同 createdAt 且 sequence 均非空时必须按 sequence 新→旧，而不是 id 字典序"
        )

        let missingSequence = [
            entry("a", session: "ses_1", host: hostA, offset: 0, sequence: nil),
            entry("z", session: "ses_1", host: hostA, offset: 0, sequence: 9),
        ]
        XCTAssertEqual(
            OfflineSessionCachePolicy.deduplicatedEntries(missingSequence).map(\.id),
            ["a", "z"],
            "任一 sequence 缺失时保持 itemKey tie-break"
        )
    }

    func testCompositeKeysDoNotCollideForColonContainingIdentifiers() {
        let firstSession = "a:b"
        let firstItem = "c"
        let secondSession = "a"
        let secondItem = "b:c"

        XCTAssertNotEqual(
            OfflineSessionCachePolicy.itemKey(
                hostID: hostA,
                sessionID: firstSession,
                itemID: firstItem
            ),
            OfflineSessionCachePolicy.itemKey(
                hostID: hostA,
                sessionID: secondSession,
                itemID: secondItem
            )
        )

        let entries = [
            entry(firstItem, session: firstSession, host: hostA, offset: 0, text: "first"),
            entry(secondItem, session: secondSession, host: hostA, offset: 1, text: "second"),
        ]
        XCTAssertEqual(
            Set(OfflineSessionCachePolicy.deduplicatedEntries(entries).map(\.text)),
            Set(["first", "second"])
        )
    }

    func testTurnPruningKeepsEveryItemInNewestTurns() {
        let entries = [
            entry("old-user", session: "ses_1", host: hostA, offset: 0, turnId: "turn:old"),
            entry("old-reply", session: "ses_1", host: hostA, offset: 1, turnId: "turn:old"),
            entry("new-user", session: "ses_1", host: hostA, offset: 2, turnId: "turn:new"),
            entry("new-tool", session: "ses_1", host: hostA, offset: 3, turnId: "turn:new"),
            entry("new-reply", session: "ses_1", host: hostA, offset: 4, turnId: "turn:new"),
        ]

        let pruned = OfflineSessionCachePolicy.prunedEntries(entries, offlineCacheLimit: 1)

        XCTAssertEqual(Set(pruned.map(\.id)), ["new-user", "new-tool", "new-reply"])
        XCTAssertEqual(Set(pruned.map(\.turnId)), ["turn:new"])
    }

    func testOrderedLegacyEntriesDeriveAndPersistUserBoundaryKeys() {
        let entries = [
            entry("u1", session: "ses_1", host: hostA, offset: 0, role: "user", sequence: 1),
            entry("a1", session: "ses_1", host: hostA, offset: 1, role: "assistant", sequence: 2),
            entry("u2", session: "ses_1", host: hostA, offset: 2, role: "user", sequence: 3),
            entry("t2", session: "ses_1", host: hostA, offset: 3, role: "toolResult", sequence: 4),
        ]

        let pruned = OfflineSessionCachePolicy.prunedEntries(entries, offlineCacheLimit: 1)

        XCTAssertEqual(Set(pruned.map(\.id)), ["u2", "t2"])
        XCTAssertEqual(Set(pruned.map(\.turnId)), ["user:u2"])
    }

    func testAmbiguousLegacySubsetIsOneConservativeUnit() throws {
        let entries = [
            entry("u2", session: "ses_1", host: hostA, offset: 0, role: "user", sequence: nil),
            entry("u1", session: "ses_1", host: hostA, offset: 0, role: "user", sequence: nil),
            entry("a1", session: "ses_1", host: hostA, offset: 1, role: "assistant", sequence: nil),
        ]

        let pruned = OfflineSessionCachePolicy.prunedEntries(entries, offlineCacheLimit: 1)

        XCTAssertEqual(pruned.count, 3, "保守 legacy 单元允许超过 N，不能按 user 猜配或拆碎")
        let keys = Set(pruned.map(\.turnId))
        XCTAssertEqual(keys.count, 1)
        let key = try XCTUnwrap(keys.compactMap { $0 }.first)
        XCTAssertTrue(key.hasPrefix("legacy:"))

        let duplicateOrderKeys = [
            entry("u2", session: "ses_1", host: hostA, offset: 0, role: "user", sequence: 1),
            entry("u1", session: "ses_1", host: hostA, offset: 0, role: "user", sequence: 1),
            entry("a1", session: "ses_1", host: hostA, offset: 1, role: "assistant", sequence: 1),
        ]
        let duplicatePruned = OfflineSessionCachePolicy.prunedEntries(duplicateOrderKeys, offlineCacheLimit: 1)
        XCTAssertEqual(duplicatePruned.count, 3)
        XCTAssertEqual(Set(duplicatePruned.map(\.turnId)), keys)

        let minimumItemKey = entries.map {
            OfflineSessionCachePolicy.itemKey(hostID: hostA, sessionID: "ses_1", itemID: $0.id)
        }.min()
        XCTAssertEqual(key, "legacy:\(try XCTUnwrap(minimumItemKey))")
    }

    private func entry(
        _ id: String,
        session: String,
        host: UUID?,
        offset: TimeInterval,
        text: String = "text",
        role: String? = nil,
        sequence: Int? = nil,
        turnId: String? = nil
    ) -> OfflineSessionCacheEntry {
        OfflineSessionCacheEntry(
            id: id,
            sessionId: session,
            hostID: host,
            text: text,
            createdAt: base.addingTimeInterval(offset),
            role: role,
            sequence: sequence,
            turnId: turnId
        )
    }
}
