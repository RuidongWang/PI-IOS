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
    /// 稳定的无障碍标识（`域.对象`）。测试按它定位消息块，不再依赖正文文案。
    var identifier: String? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let blocks = PIMarkdownBlockCache.shared.blocks(for: text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { index in
                block(blocks[index])
                    .padding(.top, topPadding(for: blocks, at: index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .modifier(PIMarkdownIdentifier(identifier: identifier))
    }

    private func topPadding(for blocks: [MarkdownBlock], at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        if case .heading(let level, _) = blocks[index] {
            return level <= 2 ? PISpacing.s16 : PISpacing.s12
        }
        if case .heading(_, _) = blocks[index - 1] {
            return PISpacing.s8
        }
        return PISpacing.s12
    }

    @ViewBuilder
    private func block(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(PIMarkdownInline.attributed(text, role: .heading(level: level), dynamicTypeSize: dynamicTypeSize))
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            Text(PIMarkdownInline.attributed(text, role: .body, dynamicTypeSize: dynamicTypeSize))
                .lineSpacing(5)
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
            // quiet-v2 §2：accent 只用于可交互，引用条改为发丝线分层。
            HStack(alignment: .top, spacing: PISpacing.s8) {
                Rectangle()
                    .fill(PIColor.separator)
                    .frame(width: 2)
                Text(PIMarkdownInline.attributed(text, role: .quote, dynamicTypeSize: dynamicTypeSize))
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
            Text(PIMarkdownInline.attributed(item.text, role: .list, dynamicTypeSize: dynamicTypeSize))
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
                .font(PIMarkdownTypography.font(role: .list, dynamicTypeSize: dynamicTypeSize))
                .foregroundStyle(PIColor.text2)
                .frame(minWidth: 10, alignment: .leading)
        case .ordered(let number):
            Text("\(number).")
                .font(PIMarkdownTypography.font(role: .list, dynamicTypeSize: dynamicTypeSize))
                .foregroundStyle(PIColor.text2)
                .frame(minWidth: 18, alignment: .trailing)
        case .task(let checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(PIMarkdownTypography.font(role: .list, dynamicTypeSize: dynamicTypeSize))
                // 勾选是状态，不是可交互元素：不上 accent。
                .foregroundStyle(checked ? PIColor.text2 : PIColor.text3)
                .frame(minWidth: 10, alignment: .leading)
        }
    }

    private func codeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                // quiet-v2 §3：不写 tracking、不做全大写；语言名只是机器数据的标签。
                Text(language)
                    .font(PIMarkdownTypography.font(role: .language, dynamicTypeSize: dynamicTypeSize, monospaced: true))
                    .foregroundStyle(PIColor.text2)
                    .padding(.horizontal, PISpacing.s12)
                    .padding(.top, PISpacing.s8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(PIMarkdownTypography.font(role: .code, dynamicTypeSize: dynamicTypeSize, monospaced: true))
                    .foregroundStyle(PIColor.text)
                    .textSelection(.enabled)
                    .padding(PISpacing.s12)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
        )
    }

    private func tableView(header: [String], rows: [[String]]) -> some View {
        PIMarkdownTableView(header: header, rows: rows, dynamicTypeSize: dynamicTypeSize)
    }
}

/// 固定列宽让同一 GridRow 按最高单元格撑高；外框留在滚动容器上，宽表只滚动内部内容。
private struct PIMarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let dynamicTypeSize: DynamicTypeSize

    @State private var availableWidth: CGFloat = 0

    private static let cellHorizontalPadding: CGFloat = PISpacing.s12
    private static let cellVerticalPadding: CGFloat = PISpacing.s12
    private static let cellLineSpacing: CGFloat = 4

    var body: some View {
        let widths = columnWidths
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(widths.indices, id: \.self) { column in
                        tableCell(
                            column < header.count ? header[column] : "",
                            role: .tableHeader,
                            isHeader: true,
                            showsDivider: !rows.isEmpty
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
                                isHeader: false,
                                showsDivider: row < rows.count - 1
                            )
                            .frame(width: widths[column], alignment: .leading)
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
        )
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateAvailableWidth(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        updateAvailableWidth(newWidth)
                    }
            }
        )
    }

    /// 内容较窄时均分剩余宽度；内容较宽时保留固有列宽，仅由内部 ScrollView 横滚。
    private var columnWidths: [CGFloat] {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        let base = (0..<max(columnCount, 1)).map { column in
            intrinsicColumnWidth(
                header: column < header.count ? header[column] : "",
                rows: rows.map { column < $0.count ? $0[column] : "" }
            )
        }
        let remaining = availableWidth - base.reduce(0, +)
        guard remaining > 0 else { return base }
        let expansion = remaining / CGFloat(base.count)
        return base.map { $0 + expansion }
    }

    /// UIFont 测量与 Text 使用同一 Dynamic Type 档位，切换字号后由 body 重新计算。
    private func intrinsicColumnWidth(header: String, rows: [String]) -> CGFloat {
        let headerFont = PIMarkdownTypography.uiFont(role: .tableHeader, dynamicTypeSize: dynamicTypeSize)
        let cellFont = PIMarkdownTypography.uiFont(role: .tableCell, dynamicTypeSize: dynamicTypeSize)
        var widest = measuredWidth(of: header, font: headerFont)
        for value in rows {
            widest = max(widest, measuredWidth(of: value, font: cellFont))
        }
        let horizontalPadding = Self.cellHorizontalPadding * 2
        return min(max(widest.rounded(.up) + horizontalPadding, 56), 220)
    }

    private func measuredWidth(of value: String, font: UIFont) -> CGFloat {
        let plain = value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "`", with: "")
        return (plain as NSString).size(withAttributes: [.font: font]).width
    }

    private func updateAvailableWidth(_ width: CGFloat) {
        guard width > 0, abs(width - availableWidth) > 0.5 else { return }
        availableWidth = width
    }

    private func tableCell(
        _ text: String,
        role: PIMarkdownTextRole,
        isHeader: Bool,
        showsDivider: Bool
    ) -> some View {
        Text(PIMarkdownInline.attributed(text, role: role, dynamicTypeSize: dynamicTypeSize))
            .lineSpacing(Self.cellLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Self.cellHorizontalPadding)
            .padding(.vertical, Self.cellVerticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isHeader ? PIColor.surface2 : Color.clear)
            .overlay(alignment: .bottom) {
                if showsDivider {
                    Rectangle()
                        .fill(PIColor.separator)
                        .frame(height: PIMetrics.hairline)
                }
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
    case code
    case language

    /// Large 基准：H1 20 / H2 17 / H3 16 / 正文 16 / 表格与代码 13。
    var size: CGFloat {
        switch self {
        case .body, .list, .quote:
            return 16
        case .heading(let level):
            switch level {
            case 1: return 20
            case 2: return 17
            case 3: return 16
            default: return 15
            }
        case .tableHeader, .tableCell, .code:
            return 13
        case .language:
            return 12
        }
    }

    var weight: UIFont.Weight {
        switch self {
        case .heading, .tableHeader:
            return .semibold
        default:
            return .regular
        }
    }

    var textStyle: UIFont.TextStyle {
        switch self {
        case .heading(let level):
            switch level {
            case 1: return .title3
            case 2: return .headline
            default: return .callout
            }
        case .body, .list, .quote:
            return .callout
        case .tableHeader, .tableCell, .code:
            return .footnote
        case .language:
            return .caption1
        }
    }

    var color: Color {
        switch self {
        case .quote, .language:
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
        case .code: return "code"
        case .language: return "language"
        }
    }
}

private enum PIMarkdownTypography {
    static func font(
        role: PIMarkdownTextRole,
        dynamicTypeSize: DynamicTypeSize,
        weight: UIFont.Weight? = nil,
        monospaced: Bool = false,
        sizeAdjustment: CGFloat = 0
    ) -> Font {
        Font(uiFont(
            role: role,
            dynamicTypeSize: dynamicTypeSize,
            weight: weight,
            monospaced: monospaced,
            sizeAdjustment: sizeAdjustment
        ))
    }

    static func uiFont(
        role: PIMarkdownTextRole,
        dynamicTypeSize: DynamicTypeSize,
        weight: UIFont.Weight? = nil,
        monospaced: Bool = false,
        sizeAdjustment: CGFloat = 0
    ) -> UIFont {
        let size = max(role.size + sizeAdjustment, 1)
        let weight = weight ?? role.weight
        let base = monospaced
            ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        let traits = UITraitCollection(
            preferredContentSizeCategory: dynamicTypeSize.piMarkdownContentSizeCategory
        )
        return UIFontMetrics(forTextStyle: role.textStyle)
            .scaledFont(for: base, compatibleWith: traits)
    }
}

private extension DynamicTypeSize {
    var piMarkdownContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        default: return .large
        }
    }
}

// MARK: - 行内语法

enum PIMarkdownInline {
    static func attributed(
        _ text: String,
        role: PIMarkdownTextRole,
        dynamicTypeSize: DynamicTypeSize
    ) -> AttributedString {
        let contentSizeCategory = dynamicTypeSize.piMarkdownContentSizeCategory.rawValue
        let key = "\(role.cacheKey)|\(contentSizeCategory)|\(text)" as NSString
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

        value.font = PIMarkdownTypography.font(role: role, dynamicTypeSize: dynamicTypeSize)
        value.foregroundColor = role.color

        for run in value.runs {
            let intent = run.inlinePresentationIntent
            let isStrong = intent?.contains(.stronglyEmphasized) == true
            let isEmphasized = intent?.contains(.emphasized) == true
            let isCode = intent?.contains(.code) == true
            if isStrong || isEmphasized || isCode {
                let weight = isStrong ? (role.weight == .regular ? .semibold : .bold) : role.weight
                var font = PIMarkdownTypography.font(
                    role: role,
                    dynamicTypeSize: dynamicTypeSize,
                    weight: weight,
                    monospaced: isCode,
                    sizeAdjustment: isCode ? -0.5 : 0
                )
                if isEmphasized {
                    font = font.italic()
                }
                value[run.range].font = font
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

private struct PIMarkdownIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            // `.contain` 让容器成为真实的无障碍元素（否则 identifier 可能落不到节点上），
            // 子文本仍然逐段可读、可选中。
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
        } else {
            content
        }
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
