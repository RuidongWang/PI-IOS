import XCTest
@testable import PIiOSCore

final class ConversationTurnPolicyTests: XCTestCase {
    func testTaskBoundaryRequiresUserInEarliestTurn() {
        XCTAssertFalse(ConversationTurnPolicy.hasTaskBoundary([]))
        XCTAssertTrue(ConversationTurnPolicy.hasTaskBoundary([
            item("u", role: "user"),
            item("a", role: "assistant"),
        ]))
        XCTAssertFalse(ConversationTurnPolicy.hasTaskBoundary([
            item("a", role: "assistant"),
            item("u", role: "user"),
        ]), "A nil-turn prefix cannot be guessed into the following task")
    }

    func testTaskBoundaryAcceptsUserInsideFirstReliableTurnSegmentOnly() {
        XCTAssertTrue(ConversationTurnPolicy.hasTaskBoundary([
            item("a1", role: "assistant", turnID: "turn-1"),
            item("u1", role: "user", turnID: "turn-1"),
            item("a2", role: "assistant", turnID: "turn-2"),
        ]))
        XCTAssertFalse(ConversationTurnPolicy.hasTaskBoundary([
            item("a1", role: "assistant", turnID: "turn-1"),
            item("a2", role: "assistant", turnID: "turn-2"),
            item("u2", role: "user", turnID: "turn-2"),
        ]))
    }

    func testIncompleteLeadingPrefixStopsAtFirstUser() {
        let items = [
            item("old-a", role: "assistant"),
            item("old-t", role: "tool"),
            item("u1", role: "user"),
            item("a1", role: "assistant"),
        ]
        XCTAssertEqual(ConversationTurnPolicy.incompleteLeadingPrefixCount(items), 2)
        XCTAssertEqual(ConversationTurnPolicy.incompleteLeadingPrefixCount([item("u", role: "user")]), 0)
        XCTAssertEqual(ConversationTurnPolicy.incompleteLeadingPrefixCount([item("a", role: "assistant")]), 0)
    }

    func testUsableTaskBoundaryAcceptsLegacyPrefixWithLaterUser() {
        XCTAssertTrue(ConversationTurnPolicy.hasUsableTaskBoundary([
            item("legacy-a", role: "assistant"),
            item("legacy-t", role: "tool"),
            item("u", role: "user"),
        ]))
        XCTAssertFalse(ConversationTurnPolicy.hasUsableTaskBoundary([
            item("a", role: "assistant"),
        ]))
        XCTAssertFalse(ConversationTurnPolicy.hasUsableTaskBoundary([
            item("a", role: "assistant", turnID: "turn-1"),
            item("u", role: "user", turnID: "turn-2"),
        ]), "a reliable turn id without its own user must still be backfilled")
    }

    func testKeyerStartsNewTurnAtUserAndIgnoresLateNonUserTurnIDs() {
        var keyer = ConversationTurnKeyer()
        XCTAssertEqual(keyer.key(itemID: "old-a", role: "assistant", turnID: "turn-old"), "turn:turn-old")
        XCTAssertEqual(keyer.key(itemID: "old-tool", role: "tool", turnID: nil), "turn:turn-old")
        XCTAssertEqual(keyer.key(itemID: "u1", role: "user", turnID: nil), "user:u1")
        XCTAssertEqual(keyer.key(itemID: "a1", role: "assistant", turnID: "late-turn"), "user:u1")
        XCTAssertEqual(keyer.key(itemID: "u2", role: "user", turnID: "turn-2"), "turn:turn-2")
        XCTAssertEqual(keyer.key(itemID: "t2", role: "tool", turnID: nil), "turn:turn-2")
    }

    func testKeysPreserveConservativeLegacyPrefix() {
        let items = [
            item("legacy-a", role: "assistant"),
            item("legacy-t", role: "tool"),
            item("u", role: "user"),
            item("a", role: "assistant"),
        ]
        XCTAssertEqual(ConversationTurnPolicy.keys(for: items), [
            "legacy-a": "legacy:legacy-a",
            "legacy-t": "legacy:legacy-a",
            "u": "user:u",
            "a": "user:u",
        ])
    }

    private func item(_ id: String, role: String, turnID: String? = nil) -> RACPItem {
        var payload: [String: JSONValue] = [
            "id": .string(id),
            "role": .string(role),
        ]
        if let turnID { payload["turnId"] = .string(turnID) }
        return RACPItem(id: id, payload: .object(payload))
    }
}
