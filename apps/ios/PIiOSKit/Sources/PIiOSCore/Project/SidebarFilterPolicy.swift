import Foundation

/// 侧栏搜索的纯规则：在线与离线分组共用同一套匹配、展开与空态判定（U01）。
///
/// 旧实现的问题是「同一个搜索框有两套语义」：在线分组自己写了
/// 「标题或项目名包含查询」，离线分组完全不过滤，折叠状态也只让在线分组
/// 跟随搜索变化。于是断网后输入查询，列表看起来像坏了——不是没命中，而是根本没筛。
public enum SidebarFilterPolicy {
    /// 查询归一化：去两端空白 + 小写。返回空串表示「没有搜索」。
    public static func normalizedQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 会话是否命中：没有查询时全部命中；否则**标题或所属项目名**包含查询
    /// （大小写不敏感，中文直接子串匹配）。
    ///
    /// 查询在内部再做一次归一化：调用方本应传 `normalizedQuery(_:)` 的结果，
    /// 但传原始字符串也必须得到一致结果（少一个「忘了 lowercased」的坑）。
    public static func matches(title: String, projectName: String, query: String) -> Bool {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty else { return true }
        return title.lowercased().contains(needle) || projectName.lowercased().contains(needle)
    }

    /// 分组是否还有内容：查询为空时一律保留（交给「没有活跃会话」空态去表达）；
    /// 否则项目名命中或任一标题命中才算命中。
    public static func keepsGroup(
        projectName: String,
        sessionTitles: [String],
        query: String
    ) -> Bool {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty else { return true }
        if projectName.lowercased().contains(needle) { return true }
        return sessionTitles.contains { $0.lowercased().contains(needle) }
    }

    /// 分组是否折叠：搜索期间强制展开；清空搜索后恢复用户原来的折叠状态。
    public static func isCollapsed(storedCollapsed: Bool, query: String) -> Bool {
        query.isEmpty && storedCollapsed
    }

    /// 搜索期间不允许切换折叠：否则刚展开的分组会被点回去，看起来又像搜索失效。
    public static func canToggleGroup(query: String) -> Bool {
        query.isEmpty
    }

    /// 离线侧栏空态文案：区分「本机没有缓存」与「有缓存但没命中」。
    ///
    /// 没有查询时保持既有文案不变（既有行为：缓存里的会话都落在归档/删除项目下时也用它）。
    public static func offlineEmptyMessage(hasCachedSessions: Bool, query: String) -> String {
        if hasCachedSessions, !query.isEmpty {
            return "本机缓存中无匹配。"
        }
        return "尚未连接服务器，本机也没有缓存的历史。"
    }
}
