import XCTest

@testable import PIiOSCore

final class MarkdownParserTests: XCTestCase {
    func testHeadingsParagraphsAndThematicBreak() {
        let blocks = MarkdownParser.blocks(from: """
        # 一级标题
        ## 二级标题 ##

        第一段第一行
        第一段第二行

        ---
        """)

        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "一级标题"),
            .heading(level: 2, text: "二级标题"),
            .paragraph(text: "第一段第一行\n第一段第二行"),
            .thematicBreak,
        ])
    }

    func testPipeTableKeepsHeaderAndRows() {
        let blocks = MarkdownParser.blocks(from: """
        | 文件系统 | 大小 | 使用率 |
        |----------|------|--------|
        | /dev/sda1 | 194G | 23% |
        | /dev/sda15 | 98M | 7% |
        """)

        XCTAssertEqual(blocks, [
            .table(
                header: ["文件系统", "大小", "使用率"],
                rows: [["/dev/sda1", "194G", "23%"], ["/dev/sda15", "98M", "7%"]]
            ),
        ])
    }

    func testTableRowIsPaddedToHeaderWidth() {
        let blocks = MarkdownParser.blocks(from: """
        | a | b | c |
        | - | - | - |
        | 1 |
        """)

        XCTAssertEqual(blocks, [
            .table(header: ["a", "b", "c"], rows: [["1", "", ""]]),
        ])
    }

    func testBulletOrderedTaskAndNestedLists() {
        let blocks = MarkdownParser.blocks(from: """
        - 第一项
          - 嵌套项
        1. 有序项
        - [x] 已完成
        - [ ] 未完成
        """)

        guard case .list(let items) = blocks.first, blocks.count == 1 else {
            return XCTFail("应解析为一个列表块，实际 \(blocks)")
        }
        XCTAssertEqual(items, [
            MarkdownListItem(marker: .bullet, indent: 0, text: "第一项"),
            MarkdownListItem(marker: .bullet, indent: 1, text: "嵌套项"),
            MarkdownListItem(marker: .ordered(1), indent: 0, text: "有序项"),
            MarkdownListItem(marker: .task(checked: true), indent: 0, text: "已完成"),
            MarkdownListItem(marker: .task(checked: false), indent: 0, text: "未完成"),
        ])
    }

    func testFencedCodeBlockKeepsRawTextAndLanguage() {
        let blocks = MarkdownParser.blocks(from: """
        前文

        ```bash
        df -h
        | not | a | table |
        ```

        后文
        """)

        XCTAssertEqual(blocks, [
            .paragraph(text: "前文"),
            .codeBlock(language: "bash", code: "df -h\n| not | a | table |"),
            .paragraph(text: "后文"),
        ])
    }

    func testUnclosedFenceStillRendersRemainingTextAsCode() {
        let blocks = MarkdownParser.blocks(from: "```\nls -la\n")

        XCTAssertEqual(blocks, [.codeBlock(language: nil, code: "ls -la")])
    }

    func testQuoteAndLooseList() {
        let blocks = MarkdownParser.blocks(from: """
        > 引用第一行
        > 引用第二行

        - 第一项

        - 第二项

        段落
        """)

        XCTAssertEqual(blocks, [
            .quote(text: "引用第一行\n引用第二行"),
            .list(items: [
                MarkdownListItem(marker: .bullet, indent: 0, text: "第一项"),
                MarkdownListItem(marker: .bullet, indent: 0, text: "第二项"),
            ]),
            .paragraph(text: "段落"),
        ])
    }

    func testIndentedContinuationStaysInListItem() {
        let blocks = MarkdownParser.blocks(from: """
        - 第一行
          第二行
        - 下一项
        """)

        XCTAssertEqual(blocks, [
            .list(items: [
                MarkdownListItem(marker: .bullet, indent: 0, text: "第一行\n第二行"),
                MarkdownListItem(marker: .bullet, indent: 0, text: "下一项"),
            ]),
        ])
    }

    func testPlainTextWithoutMarkersIsOneParagraph() {
        let text = "这里是当前系统的磁盘信息：\n根分区已用 23%。"

        XCTAssertEqual(MarkdownParser.blocks(from: text), [.paragraph(text: text)])
    }
}
