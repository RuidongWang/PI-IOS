import XCTest

@testable import PIiOSCore

final class ApprovalInputPreviewTests: XCTestCase {
    func testCommandStringIsShownWithShellPrompt() {
        let payload = JSONValue.object([
            "toolName": .string("bash"),
            "input": .string("rm -rf build && pnpm test\n"),
        ])

        XCTAssertEqual(ApprovalInputPreview.text(from: payload), "$ rm -rf build && pnpm test")
    }

    func testCommandObjectIsShownWithShellPrompt() {
        let payload = JSONValue.object([
            "input": .object(["command": .string("git status"), "timeout": .number(30)]),
        ])

        XCTAssertEqual(ApprovalInputPreview.text(from: payload), "$ git status")
    }

    func testGenericInputIsRenderedAsSortedJSON() {
        let payload = JSONValue.object([
            "input": .object([
                "path": .string("a.txt"),
                "options": .object(["z": .bool(true), "a": .number(1.5)]),
            ]),
        ])

        XCTAssertEqual(
            ApprovalInputPreview.text(from: payload),
            "{\"options\": {\"a\": 1.5, \"z\": true}, \"path\": \"a.txt\"}"
        )
    }

    func testEscapesQuotesAndControlCharacters() {
        let payload = JSONValue.object([
            "input": .object(["text": .string("say \"hi\"\n\tend")]),
        ])

        XCTAssertEqual(
            ApprovalInputPreview.text(from: payload),
            "{\"text\": \"say \\\"hi\\\"\\n\\tend\"}"
        )
    }

    func testMissingOrEmptyInputReturnsNil() {
        XCTAssertNil(ApprovalInputPreview.text(from: .object([:])))
        XCTAssertNil(ApprovalInputPreview.text(from: .object(["input": .null])))
        XCTAssertNil(ApprovalInputPreview.text(from: .object(["input": .string("   ")])))
        XCTAssertNil(ApprovalInputPreview.text(from: .object(["input": .object([:])])))
        XCTAssertNil(ApprovalInputPreview.text(from: .object(["input": .array([])])))
    }

    func testLongInputIsTruncatedWithNotice() {
        let command = String(repeating: "a", count: 40)
        let payload = JSONValue.object(["input": .string(command)])

        let preview = ApprovalInputPreview.text(from: payload, limit: 10)

        XCTAssertEqual(preview, "$ aaaaaaaa\n…（输入已截断）")
    }
}
