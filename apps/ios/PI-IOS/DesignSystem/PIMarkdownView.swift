import SwiftUI
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

    private func tableView(header: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        tableCell(header[column], role: .tableHeader, isHeader: true)
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            tableCell(
                                column < rows[row].count ? rows[row][column] : "",
                                role: .tableCell,
                                isHeader: false
                            )
                        }
                    }
                }
            }
            // 让表格按内容宽度收边：否则 Grid 会撑满视口，表头灰色背景只盖住前几列，
            // 右边留出一条没有内容的空框。
            .fixedSize(horizontal: true, vertical: false)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PIColor.separator, lineWidth: 1)
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tableCell(_ text: String, role: PIMarkdownTextRole, isHeader: Bool) -> some View {
        Text(PIMarkdownInline.attributed(text, role: role))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, PISpacing.s8)
            .padding(.vertical, 7)
            .frame(minWidth: 56, maxWidth: 220, alignment: .leading)
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
