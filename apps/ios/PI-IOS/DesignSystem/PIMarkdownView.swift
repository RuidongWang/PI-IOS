import SwiftUI
import UIKit
import PIiOSCore

/// 会话里 Agent 消息的 Markdown 渲染。
///
/// 块级结构（标题 / 列表 / 代码块 / 引用 / 表格 / 分隔线）由 `MarkdownParser` 切分，
/// 行内语法（粗体、斜体、行内代码、链接）交给 `AttributedString(markdown:)`。
/// 模型在终端场景里几乎必然返回表格与围栏代码块，纯 `Text` 只会把 `|`、`**`、`` ` `` 原样显示。
struct PIMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = PIMarkdownBlockCache.shared.blocks(for: text)
        VStack(alignment: .leading, spacing: PISpacing.s12) {
            ForEach(blocks.indices, id: \.self) { index in
                block(blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func block(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(PIMarkdownInline.attributed(text, role: .heading(level: level)))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? PISpacing.s4 : 0)

        case .paragraph(let text):
            Text(PIMarkdownInline.attributed(text, role: .body))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let items):
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                ForEach(items.indices, id: \.self) { index in
                    listRow(items[index])
                }
            }

        case .codeBlock(let language, let code):
            codeBlock(language: language, code: code)

        case .quote(let text):
            HStack(alignment: .top, spacing: PISpacing.s8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(PIColor.separator)
                    .frame(width: 3)
                Text(PIMarkdownInline.attributed(text, role: .quote))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .table(let header, let rows):
            tableView(header: header, rows: rows)

        case .thematicBreak:
            Rectangle()
                .fill(PIColor.separator)
                .frame(height: 1)
                .padding(.vertical, PISpacing.s4)
        }
    }

    private func listRow(_ item: MarkdownListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PISpacing.s8) {
            marker(item.marker)
            Text(PIMarkdownInline.attributed(item.text, role: .list))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(item.indent) * 14)
    }

    @ViewBuilder
    private func marker(_ marker: MarkdownListItem.Marker) -> some View {
        switch marker {
        case .bullet:
            Text("•")
                .font(PIFont.body)
                .foregroundStyle(PIColor.text2)
                .frame(minWidth: 10, alignment: .leading)
        case .ordered(let number):
            Text("\(number).")
                .font(PIFont.body)
                .foregroundStyle(PIColor.text2)
                .frame(minWidth: 18, alignment: .trailing)
        case .task(let checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(checked ? PIColor.accent : PIColor.text3)
                .frame(minWidth: 10, alignment: .leading)
        }
    }

    private func codeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(PIFont.metaSmall)
                    .foregroundStyle(PIColor.text3)
                    .padding(.horizontal, PISpacing.s12)
                    .padding(.top, PISpacing.s8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(PIColor.text)
                    .textSelection(.enabled)
                    .padding(PISpacing.s12)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
    }

    /// 表格：横向可滚动，列为按内容量出的固定宽度。
    ///
    /// 之前用 `Grid` + `fixedSize(horizontal:)` 放在横向 `ScrollView` 里：测量阶段拿到
    /// 的是无限宽度提案，每行只按单行高度排版；真正布局时单元格又被 `maxWidth` 收窄成
    /// 多行，行高没跟上，长文本就压到下一行上。这里先把每列宽度算出来，行内单元格再用
    /// 显式宽度排版，测量与布局使用同一约束，行高自然由最高单元格决定。
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        let widths = (0..<max(columnCount, 1)).map { column in
            tableColumnWidth(
                header: column < header.count ? header[column] : "",
                rows: rows.map { column < $0.count ? $0[column] : "" }
            )
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(widths.indices, id: \.self) { column in
                        tableCell(
                            column < header.count ? header[column] : "",
                            role: .tableHeader,
                            isHeader: true
                        )
                        .frame(width: widths[column], alignment: .leading)
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(widths.indices, id: \.self) { column in
                            tableCell(
                                column < rows[row].count ? rows[row][column] : "",
                                role: .tableCell,
                                isHeader: false
                            )
                            .frame(width: widths[column], alignment: .leading)
                        }
                    }
                }
            }
            // 列宽已固定，网格宽度就是各列之和；GridRow 会把同一行的单元格拉成一致高度，
            // 表头底色与分隔线不会因为某格多行而断开。
            .fixedSize(horizontal: true, vertical: false)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PIColor.separator, lineWidth: 1)
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 列宽 = 最长内容的单行宽度（含单元格左右内边距），夹在 [56, 220]。
    private func tableColumnWidth(header: String, rows: [String]) -> CGFloat {
        let font = UIFont.systemFont(
            ofSize: PIMarkdownTextRole.tableCell.size,
            weight: .semibold
        )
        var widest: CGFloat = 0
        for value in [header] + rows {
            let plain = value
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "~~", with: "")
                .replacingOccurrences(of: "`", with: "")
            let width = (plain as NSString).size(withAttributes: [.font: font]).width
            widest = max(widest, width)
        }
        let horizontalPadding = PISpacing.s8 * 2
        return min(max(widest.rounded(.up) + horizontalPadding, 56), 220)
    }

    private func tableCell(_ text: String, role: PIMarkdownTextRole, isHeader: Bool) -> some View {
        Text(PIMarkdownInline.attributed(text, role: role))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, PISpacing.s8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHeader ? PIColor.surface2 : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PIColor.separator)
                    .frame(height: 1)
            }
    }
}

// MARK: - 文本角色

enum PIMarkdownTextRole {
    case body
    case heading(level: Int)
    case list
    case quote
    case tableHeader
    case tableCell

    /// 字号沿用 design-system.md §2.2：正文 15，标题按层级收缩，表格/代码用小一号。
    var size: CGFloat {
        switch self {
        case .body, .list:
            return 15
        case .heading(let level):
            switch level {
            case 1: return 20
            case 2: return 17
            case 3: return 16
            default: return 15
            }
        case .quote:
            return 15
        case .tableHeader, .tableCell:
            return 13
        }
    }

    var weight: Font.Weight {
        switch self {
        case .heading:
            return .semibold
        case .tableHeader:
            return .semibold
        default:
            return .regular
        }
    }

    var color: Color {
        switch self {
        case .quote:
            return PIColor.text2
        default:
            return PIColor.text
        }
    }

    var cacheKey: String {
        switch self {
        case .body: return "body"
        case .heading(let level): return "h\(level)"
        case .list: return "list"
        case .quote: return "quote"
        case .tableHeader: return "th"
        case .tableCell: return "td"
        }
    }
}

// MARK: - 行内语法

enum PIMarkdownInline {
    static func attributed(_ text: String, role: PIMarkdownTextRole) -> AttributedString {
        let key = "\(role.cacheKey)|\(text)" as NSString
        if let cached = PIMarkdownInlineCache.shared.value(forKey: key) {
            return cached
        }

        var value: AttributedString
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: text, options: options) {
            value = parsed
        } else {
            value = AttributedString(text)
        }

        let baseFont = Font.system(size: role.size, weight: role.weight)
        value.font = baseFont
        value.foregroundColor = role.color

        for run in value.runs {
            guard let intent = run.inlinePresentationIntent else {
                if run.link != nil {
                    value[run.range].foregroundColor = PIColor.accent
                }
                continue
            }
            if intent.contains(.stronglyEmphasized) {
                value[run.range].font = .system(size: role.size, weight: role.weight == .regular ? .semibold : .bold)
            }
            if intent.contains(.emphasized) {
                value[run.range].font = .system(size: role.size, weight: role.weight).italic()
            }
            if intent.contains(.code) {
                value[run.range].font = .system(size: role.size - 0.5, design: .monospaced)
            }
            if run.link != nil {
                value[run.range].foregroundColor = PIColor.accent
            }
        }

        PIMarkdownInlineCache.shared.setValue(value, forKey: key, cost: text.utf8.count)
        return value
    }
}

// MARK: - 缓存

/// SwiftUI 在滚动时会反复求值整页 body；不缓存的话每条消息、每个段落都会重新解析。
private final class MarkdownBlockBox {
    let blocks: [MarkdownBlock]
    init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
}

final class PIMarkdownBlockCache {
    static let shared = PIMarkdownBlockCache()

    private let cache = NSCache<NSString, MarkdownBlockBox>()

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 4 * 1024 * 1024
    }

    func blocks(for text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let cached = cache.object(forKey: key) {
            return cached.blocks
        }
        let blocks = MarkdownParser.blocks(from: text)
        cache.setObject(MarkdownBlockBox(blocks), forKey: key, cost: text.utf8.count)
        return blocks
    }
}

private final class MarkdownAttributedBox {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

private final class PIMarkdownInlineCache {
    static let shared = PIMarkdownInlineCache()

    private let cache = NSCache<NSString, MarkdownAttributedBox>()

    private init() {
        cache.countLimit = 1024
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func value(forKey key: NSString) -> AttributedString? {
        cache.object(forKey: key)?.value
    }

    func setValue(_ value: AttributedString, forKey key: NSString, cost: Int) {
        cache.setObject(MarkdownAttributedBox(value), forKey: key, cost: cost)
    }
}
