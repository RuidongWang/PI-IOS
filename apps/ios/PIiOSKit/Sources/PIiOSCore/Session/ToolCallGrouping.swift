import Foundation

/// 一轮对话里最终回复之前的中间过程分组。
///
/// 同一轮任务产生的工具调用（bash、grep、read…）以及工具之间的过渡说明都是
/// 「中间过程」，对用户的价值主要是知道发生过什么、是否成功。把它们合并成一条
/// 可折叠条目，默认只占一行摘要；单次工具调用同样成组，保证折叠入口一致。
public struct ToolCallGroup: Equatable, Sendable {
    public let id: String
    public let items: [RACPItem]

    public init(id: String, items: [RACPItem]) {
        precondition(!items.isEmpty, "工具调用分组不能为空")
        self.id = id
        self.items = items
    }

    /// 以首条 item 作为分组标识的旧入口，只用于没有用户消息锚点的历史片段。
    /// 有用户消息的轮次必须传轮次锚点 id，否则组内条目变化会改变视图身份。
    public init(items: [RACPItem]) {
        precondition(!items.isEmpty, "工具调用分组不能为空")
        self.init(id: "tool-group:\(items[0].id)", items: items)
    }

    /// 组内的工具调用条目（中间过程可能还包含 Agent 的过渡消息）。
    public var toolItems: [RACPItem] { items.filter(\.isToolItem) }

    /// 组内工具调用次数；过渡消息不计数，折叠行仍以「N 次工具调用」为主信息。
    public var count: Int { toolItems.count }

    /// 组内过渡消息条数。
    public var messageCount: Int { items.count - count }

    public var title: String { "\(count) 次工具调用" }

    /// 组内工具名汇总，例如 `bash ×4、grep`。最多列三种，避免窄屏挤成多行。
    public var toolSummary: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in toolItems {
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
        if toolItems.contains(where: { ToolStatusPresentation.isRunning($0.status) }) {
            return "运行中"
        }
        if toolItems.contains(where: { ToolStatusPresentation.isFailure($0.status) }) {
            return "有失败"
        }
        if toolItems.contains(where: { ToolStatusPresentation.isCancelled($0.status) }) {
            return "已取消"
        }
        if toolItems.allSatisfy({ ToolStatusPresentation.isCompleted($0.status) }) {
            return "已完成"
        }
        return "已结束"
    }

    /// 组内条目是否仍在运行（用于转圈/弱化等展示）。
    public var isRunning: Bool {
        toolItems.contains { ToolStatusPresentation.isRunning($0.status) }
    }

    public var hasFailure: Bool {
        toolItems.contains { ToolStatusPresentation.isFailure($0.status) }
    }
}

/// 工具状态的展示映射。PI-adaptor 返回的是协议字符串（`completed` / `running`…），
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
/// 一轮对话从用户消息开始，到该轮最后一条非工具回复结束。策略把「最终回复之前」
/// 的全部中间过程（工具调用 + 工具之间的过渡消息）合并成一条可折叠分组：
///
/// - 只产生一次工具调用也成组，折叠入口不因调用次数而消失；
/// - 分组以用户消息 id 作为稳定标识，流式追加条目、最终回复到达、再次发起工具
///   调用都不会更换视图身份，用户手动展开/收起的状态在整轮生命周期内保持一致；
/// - 没有工具调用的轮次（纯文本往来）不产生分组，避免把正常多轮对话折叠起来；
/// - 没有用户消息锚点的历史片段（分页截断等）沿用旧规则：连续工具调用达到
///   `minimumGroupCount` 且后面跟着非工具条目才合并。
public enum ToolCallGroupingPolicy {
    public static let minimumGroupCount = 2

    public static func rows(for items: [RACPItem]) -> [ConversationRow] {
        var rows: [ConversationRow] = []
        var segment: [RACPItem] = []
        var turnAnchorID: String?

        func flushSegment() {
            rows.append(contentsOf: segmentRows(segment, turnAnchorID: turnAnchorID))
            segment.removeAll(keepingCapacity: true)
        }

        for item in items {
            if item.role == "user", !item.isToolItem {
                flushSegment()
                rows.append(.item(item))
                turnAnchorID = item.id
            } else {
                segment.append(item)
            }
        }
        flushSegment()
        return rows
    }

    /// 一轮对话内部的排版：中间过程一组，最终回复单独展示。
    ///
    /// 末尾是工具调用时说明这一轮还没结束（可能仍在运行），此时没有最终回复，
    /// 已产生的条目都算中间过程；末尾是非工具条目时它就是最终回复。
    private static func segmentRows(
        _ items: [RACPItem],
        turnAnchorID: String?
    ) -> [ConversationRow] {
        guard !items.isEmpty else { return [] }
        guard let turnAnchorID else {
            return legacyRows(for: items)
        }

        let finalReply = items.last.flatMap { $0.isToolItem ? nil : $0 }
        let intermediateItems = finalReply == nil ? items : Array(items.dropLast())

        var rows: [ConversationRow] = []
        if intermediateItems.contains(where: \.isToolItem) {
            rows.append(.toolGroup(ToolCallGroup(
                id: "tool-group:turn:\(turnAnchorID)",
                items: intermediateItems
            )))
        } else {
            rows.append(contentsOf: intermediateItems.map(ConversationRow.item))
        }
        if let finalReply {
            rows.append(.item(finalReply))
        }
        return rows
    }

    /// 没有用户消息锚点的历史片段保持旧行为。
    private static func legacyRows(for items: [RACPItem]) -> [ConversationRow] {
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
