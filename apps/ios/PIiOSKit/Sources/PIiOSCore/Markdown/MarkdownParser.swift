import Foundation

// MARK: - 块级结构

/// 会话消息里模型最常返回的块级 Markdown 结构。
///
/// 只做「显示得出来」所需要的那一小撮语法（标题、段落、列表、代码块、引用、表格、分隔线），
/// 不追求完整 CommonMark：链接、粗体、斜体、行内代码等行内语法交给
/// `AttributedString(markdown:)` 处理，这里只负责切块。
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case list(items: [MarkdownListItem])
    case codeBlock(language: String?, code: String)
    case quote(text: String)
    case table(header: [String], rows: [[String]])
    case thematicBreak
}

/// 列表项。嵌套列表通过 `indent` 表达，任务列表保留勾选态。
public struct MarkdownListItem: Equatable, Sendable {
    public enum Marker: Equatable, Sendable {
        case bullet
        case ordered(Int)
        case task(checked: Bool)
    }

    public let marker: Marker
    /// 以两个空格为一层的缩进层级（0 为顶层）。
    public let indent: Int
    public let text: String

    public init(marker: Marker, indent: Int, text: String) {
        self.marker = marker
        self.indent = indent
        self.text = text
    }
}

// MARK: - 解析

/// 轻量块级 Markdown 解析。纯函数，无 UI 依赖，放在 Core 里便于单测。
public enum MarkdownParser {
    public static func blocks(from text: String) -> [MarkdownBlock] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fenceOpening(trimmed) {
                let (code, next) = codeBlock(lines: lines, openingAt: index, marker: fence.marker)
                blocks.append(.codeBlock(language: fence.language, code: code))
                index = next
                continue
            }

            if let heading = heading(from: trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                let (quote, next) = quote(lines: lines, startingAt: index)
                blocks.append(.quote(text: quote))
                index = next
                continue
            }

            if let table = table(lines: lines, startingAt: index) {
                blocks.append(table.block)
                index = table.next
                continue
            }

            if listMarker(in: line) != nil {
                let (items, next) = listItems(lines: lines, startingAt: index)
                if !items.isEmpty {
                    blocks.append(.list(items: items))
                }
                index = next
                continue
            }

            let (paragraph, next) = paragraph(lines: lines, startingAt: index)
            if !paragraph.isEmpty {
                blocks.append(.paragraph(text: paragraph))
            }
            index = max(next, index + 1)
        }

        return blocks
    }

    // MARK: 代码块

    private static func fenceOpening(_ trimmed: String) -> (marker: String, language: String?)? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
            return (marker, language?.isEmpty == false ? language : nil)
        }
        return nil
    }

    private static func codeBlock(
        lines: [String],
        openingAt index: Int,
        marker: String
    ) -> (code: String, next: Int) {
        var code: [String] = []
        var cursor = index + 1
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(marker),
               trimmed.dropFirst(marker.count).allSatisfy({ $0 == "`" || $0 == "~" || $0.isWhitespace }) {
                cursor += 1
                break
            }
            code.append(lines[cursor])
            cursor += 1
        }
        while code.last?.isEmpty == true {
            code.removeLast()
        }
        return (code.joined(separator: "\n"), cursor)
    }

    // MARK: 标题与分隔线

    private static func heading(from trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // 去掉可选的收尾 #（`## 标题 ##`）。
        while text.hasSuffix("#") {
            text.removeLast()
        }
        return (hashes.count, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let markers = trimmed.filter { !$0.isWhitespace }
        guard markers.count >= 3, let first = markers.first, "-*_".contains(first) else { return false }
        return markers.allSatisfy { $0 == first }
    }

    // MARK: 引用

    private static func quote(lines: [String], startingAt index: Int) -> (text: String, next: Int) {
        var parts: [String] = []
        var cursor = index
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var body = trimmed.dropFirst()
            if body.first == " " {
                body = body.dropFirst()
            }
            if !body.isEmpty {
                parts.append(String(body))
            }
            cursor += 1
        }
        return (parts.joined(separator: "\n"), cursor)
    }

    // MARK: 表格

    private static func table(lines: [String], startingAt index: Int) -> (block: MarkdownBlock, next: Int)? {
        let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|"), index + 1 < lines.count else { return nil }
        let header = splitRow(headerLine)
        guard !header.isEmpty, isTableSeparator(lines[index + 1], columnCount: header.count) else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|") else { break }
            var cells = splitRow(trimmed)
            if cells.count < header.count {
                cells += Array(repeating: "", count: header.count - cells.count)
            } else if cells.count > header.count {
                cells = Array(cells.prefix(header.count))
            }
            rows.append(cells)
            cursor += 1
        }
        return (.table(header: header, rows: rows), cursor)
    }

    private static func isTableSeparator(_ line: String, columnCount: Int) -> Bool {
        let cells = splitRow(line.trimmingCharacters(in: .whitespaces))
        guard cells.count == columnCount, !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func splitRow(_ line: String) -> [String] {
        var content = line
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: 列表

    private static func listMarker(in line: String) -> (marker: MarkdownListItem.Marker, indent: Int, text: String)? {
        let indent = leadingIndent(of: line)
        let rest = line.dropFirst(indentCharacters(in: line))
        guard let first = rest.first else { return nil }

        if "-*+".contains(first) {
            let after = rest.dropFirst()
            guard let separator = after.first, separator.isWhitespace else { return nil }
            var body = String(after.drop(while: { $0.isWhitespace }))
            if body.count >= 3, body.hasPrefix("["), body.dropFirst(2).first == "]" {
                let state = body[body.index(body.startIndex, offsetBy: 1)]
                if state == " " || state.lowercased() == "x" {
                    body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    return (.task(checked: state.lowercased() == "x"), indent, body)
                }
            }
            return (.bullet, indent, body)
        }

        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let remainder = rest.dropFirst(digits.count)
        guard let punctuation = remainder.first, punctuation == "." || punctuation == ")" else { return nil }
        let after = remainder.dropFirst()
        guard let separator = after.first, separator.isWhitespace else { return nil }
        return (.ordered(Int(digits) ?? 1), indent, String(after.drop(while: { $0.isWhitespace })))
    }

    private static func listItems(lines: [String], startingAt index: Int) -> (items: [MarkdownListItem], next: Int) {
        var items: [MarkdownListItem] = []
        var cursor = index

        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // 松散列表：空行之后仍是列表项就继续，否则列表结束。
                var probe = cursor + 1
                while probe < lines.count, lines[probe].trimmingCharacters(in: .whitespaces).isEmpty {
                    probe += 1
                }
                if probe < lines.count, listMarker(in: lines[probe]) != nil {
                    cursor = probe
                    continue
                }
                break
            }

            if let marker = listMarker(in: line) {
                items.append(MarkdownListItem(marker: marker.marker, indent: marker.indent, text: marker.text))
                cursor += 1
                continue
            }

            // 标题、代码块、表格等块开始标记出现时，列表结束。
            if startsBlock(trimmed, lines: lines, at: cursor) {
                break
            }

            // 惰性续行：模型常把一条列表项折行，按 CommonMark 归到上一项。
            guard let last = items.indices.last else { break }
            items[last] = MarkdownListItem(
                marker: items[last].marker,
                indent: items[last].indent,
                text: items[last].text + "\n" + trimmed
            )
            cursor += 1
        }

        return (items, max(cursor, index + 1))
    }

    // MARK: 段落

    private static func paragraph(lines: [String], startingAt index: Int) -> (text: String, next: Int) {
        var parts: [String] = []
        var cursor = index
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if !parts.isEmpty, startsBlock(trimmed, lines: lines, at: cursor) { break }
            parts.append(trimmed)
            cursor += 1
        }
        return (parts.joined(separator: "\n"), cursor)
    }

    /// 当前行是否开启一个新的块（不含普通段落文本）。
    private static func startsBlock(_ trimmed: String, lines: [String], at index: Int) -> Bool {
        if fenceOpening(trimmed) != nil { return true }
        if heading(from: trimmed) != nil { return true }
        if isThematicBreak(trimmed) { return true }
        if trimmed.hasPrefix(">") { return true }
        if listMarker(in: trimmed) != nil { return true }
        if table(lines: lines, startingAt: index) != nil { return true }
        return false
    }

    // MARK: 缩进

    private static func leadingIndent(of line: String) -> Int {
        var indent = 0
        for character in line {
            switch character {
            case " ": indent += 1
            case "\t": indent += 4
            default: return min(indent / 2, 8)
            }
        }
        return min(indent / 2, 8)
    }

    private static func indentCharacters(in line: String) -> Int {
        var count = 0
        for character in line {
            guard character == " " || character == "\t" else { break }
            count += 1
        }
        return count
    }
}
