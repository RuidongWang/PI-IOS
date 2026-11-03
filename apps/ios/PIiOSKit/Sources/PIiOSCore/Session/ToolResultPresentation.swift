import Foundation

/// Bounded presentation for tool results. The model payload may be very large,
/// but SwiftUI should never be asked to lay out the entire result on first draw.
public struct ToolResultPresentation: Equatable, Sendable {
    public let preview: String
    public let originalUTF8Bytes: Int
    public let previewUTF8Bytes: Int
    public let maxPreviewUTF8Bytes: Int

    public var isTruncated: Bool { originalUTF8Bytes > previewUTF8Bytes }

    public init(
        text: String,
        maxPreviewUTF8Bytes: Int = 32 * 1024
    ) {
        let cap = max(0, maxPreviewUTF8Bytes)
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text.index(after: index)
            let byteCount = text[index..<next].utf8.count
            guard used + byteCount <= cap else { break }
            used += byteCount
            end = next
        }
        preview = String(text[..<end])
        previewUTF8Bytes = used
        originalUTF8Bytes = text.utf8.count
        self.maxPreviewUTF8Bytes = cap
    }

    public var truncationNotice: String? {
        guard isTruncated else { return nil }
        return "结果过长：共 \(Self.byteCount(originalUTF8Bytes))，当前仅渲染前 \(Self.byteCount(previewUTF8Bytes))。"
    }

    /// 折叠态一行摘要：取正文第一段有意义的行（跳过空行与代码围栏），
    /// 超过 `maxCharacters` 个字符时截断并补省略号。
    /// 只看前 4 KiB，避免为了折叠态摘要去扫描整段大结果。
    public func summary(maxCharacters: Int = 80) -> String? {
        guard maxCharacters > 0 else { return nil }
        let window = preview.prefix(4 * 1024)
        let line = window
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") }
        guard var summary = line, !summary.isEmpty else { return nil }
        if summary.count > maxCharacters {
            summary = String(summary.prefix(maxCharacters))
                .trimmingCharacters(in: .whitespaces) + "…"
        }
        return summary
    }

    private static func byteCount(_ value: Int) -> String {
        if value >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(value) / Double(1024 * 1024))
        }
        if value >= 1024 {
            return String(format: "%.1f KB", Double(value) / 1024)
        }
        return "\(value) B"
    }
}
