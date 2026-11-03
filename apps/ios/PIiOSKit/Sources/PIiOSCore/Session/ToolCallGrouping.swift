import Foundation

/// 一组连续的批量工具调用。
///
/// 会话线程里同一轮任务常会连续出现多次工具调用（bash、grep、read…），
/// 这些调用属于「中间过程」，对用户的价值主要是知道发生过什么、是否成功。
/// 把它们合并成一条可折叠条目，默认只占一行摘要。
public struct ToolCallGroup: Equatable, Sendable {
    public let id: String
    public let items: [RACPItem]

    public init(items: [RACPItem]) {
        precondition(!items.isEmpty, "工具调用分组不能为空")
        self.items = items
        // 用首条 item id 做稳定标识：流式追加时组内数量变化不会重建视图身份，
        // 用户已经展开的分组不会因为又完成一次工具调用而被收起。
        self.id = "tool-group:\(items[0].id)"
    }

    public var count: Int { items.count }

    public var title: String { "\(count) 次工具调用" }

    /// 组内工具名汇总，例如 `bash ×4、grep`。最多列三种，避免窄屏挤成多行。
    public var toolSummary: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in items {
            let trimmed = item.toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? "工具"
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let shown = order.prefix(3).map { name in
            let count = counts[name, default: 0]
            return count > 1 ? "\(name) ×\(count)" : name
        }
        var text = shown.joined(separator: "、")
        if order.count > 3 { text += " 等" }
        return text
    }

    /// 组状态汇总：运行中 > 有失败 > 已取消 > 已完成。
    public var statusSummary: String {
        if items.contains(where: { ToolStatusPresentation.isRunning($0.status) }) {
            return "运行中"
        }
        if items.contains(where: { ToolStatusPresentation.isFailure($0.status) }) {
            return "有失败"
        }
        if items.contains(where: { ToolStatusPresentation.isCancelled($0.status) }) {
            return "已取消"
        }
        if items.allSatisfy({ ToolStatusPresentation.isCompleted($0.status) }) {
            return "已完成"
        }
        return "已结束"
    }

    /// 组内条目是否仍在运行（用于转圈/弱化等展示）。
    public var isRunning: Bool {
        items.contains { ToolStatusPresentation.isRunning($0.status) }
    }

    public var hasFailure: Bool {
        items.contains { ToolStatusPresentation.isFailure($0.status) }
    }
}

/// 工具状态的展示映射。Host 返回的是协议字符串（`completed` / `running`…），
/// 直接显示会让中文界面里出现英文，这里统一转成用户能读的文案。
public enum ToolStatusPresentation {
    public static func label(for raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "completed", "complete", "success", "succeeded", "done", "ok":
            return "已完成"
        case "running", "streaming", "in_progress", "in-progress", "pending", "started":
            return "运行中"
        case "failed", "failure", "error":
            return "失败"
        case "cancelled", "canceled", "aborted", "interrupted":
            return "已取消"
        default:
            return raw
        }
    }

    public static func isRunning(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.lowercased() {
        case "running", "streaming", "in_progress", "in-progress", "pending", "started":
            return true
        default:
            return false
        }
    }

    public static func isFailure(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.lowercased() {
        case "failed", "failure", "error":
            return true
        default:
            return false
        }
    }

    public static func isCancelled(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.lowercased() {
        case "cancelled", "canceled", "aborted", "interrupted":
            return true
        default:
            return false
        }
    }

    public static func isCompleted(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.lowercased() {
        case "completed", "complete", "success", "succeeded", "done", "ok":
            return true
        default:
            return false
        }
    }
}

/// 会话线程的一行：普通条目，或合并后的工具调用组。
public enum ConversationRow: Equatable, Sendable {
    case item(RACPItem)
    case toolGroup(ToolCallGroup)

    public var id: String {
        switch self {
        case let .item(item): return item.id
        case let .toolGroup(group): return group.id
        }
    }

    /// 滚动定位 / 阅读位置恢复使用真实 item id；分组用首条 item 作为锚点。
    public var anchorItemID: String {
        switch self {
        case let .item(item): return item.id
        case let .toolGroup(group): return group.items.first?.id ?? group.id
        }
    }

    public var isToolLike: Bool {
        switch self {
        case .item(let item): return item.isToolItem
        case .toolGroup: return true
        }
    }
}

/// 线程行的折叠策略。
///
/// 只有满足两个条件才合并：
/// 1. 连续工具调用达到 `minimumGroupCount`；
/// 2. 这一串调用后面还有非工具条目（最终回复或下一轮用户消息）。
///
/// 第二条是关键：本轮仍在进行、工具还在追加时保持逐条紧凑展示，
/// 让用户能看到执行进度；结果落定并出现最终回复后，中间过程再收成一条摘要。
public enum ToolCallGroupingPolicy {
    public static let minimumGroupCount = 2

    public static func rows(for items: [RACPItem]) -> [ConversationRow] {
        var rows: [ConversationRow] = []
        var run: [RACPItem] = []

        func flushRun(followedByNonTool: Bool) {
            guard !run.isEmpty else { return }
            if followedByNonTool, run.count >= minimumGroupCount {
                rows.append(.toolGroup(ToolCallGroup(items: run)))
            } else {
                rows.append(contentsOf: run.map(ConversationRow.item))
            }
            run.removeAll(keepingCapacity: true)
        }

        for item in items {
            if item.isToolItem {
                run.append(item)
            } else {
                flushRun(followedByNonTool: true)
                rows.append(.item(item))
            }
        }
        flushRun(followedByNonTool: false)
        return rows
    }

    /// 把任意 item id 映射到它所在行的锚点 id（分组内条目映射到组首条）。
    public static func anchorItemID(for itemID: String, in rows: [ConversationRow]) -> String {
        for row in rows {
            switch row {
            case let .item(item):
                if item.id == itemID { return item.id }
            case let .toolGroup(group):
                if group.items.contains(where: { $0.id == itemID }) {
                    return group.items[0].id
                }
            }
        }
        return itemID
    }
}
