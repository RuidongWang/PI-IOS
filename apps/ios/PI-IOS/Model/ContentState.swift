import Foundation

/// 列表内容状态。
///
/// 这一版把五种现实分开，因为它决定了**页面能不能不靠提示文字说清自己**：
///
/// | 现实 | 状态 |
/// |---|---|
/// | 还没开始读 | `.idle` |
/// | 正在读（可能带着上一次的数据） | `.loading` |
/// | 读成功 | `.loaded` |
/// | 读失败（可能带着上一次的数据） | `.failed` |
///
/// 铁律：**只有 `.loaded` 且内容为空才允许显示空态**。
/// 读失败、断线、还没读，都不许渲染成「没有」——那会逼着页面再补一句提示去解释，
/// 正是要被砍掉的那类文字。
///
/// 对 AX 的价值：智能体只需要读 `presentation`，不用再从 `isLoading`/`error`/`isEmpty`
/// 三个布尔值的组合里猜页面现在是什么。
enum ContentState<Value> {
    case idle
    case loading(stale: Value?)
    case loaded(Value)
    case failed(reason: String, stale: Value?)

    /// 页面唯一需要消费的东西。
    enum Presentation {
        /// 正在读。`hasStale` 为真时可以同时把旧数据画出来。
        case loading(hasStale: Bool)
        /// 有内容可画。`isStale` 为真表示这是失败时保留的上一次数据。
        case content(Value, isStale: Bool)
        /// 读成功且确实为空。只有这一种情况可以显示空态。
        case empty
        /// 读失败且没有可复用的旧数据。
        case failed(reason: String)
    }

    func presentation() -> Presentation {
        switch self {
        case .idle:
            return .loading(hasStale: false)
        case let .loading(stale):
            return .loading(hasStale: stale != nil)
        case let .loaded(value):
            return Self.isEmpty(value) ? .empty : .content(value, isStale: false)
        case let .failed(reason, stale):
            if let stale, !Self.isEmpty(stale) {
                return .content(stale, isStale: true)
            }
            return .failed(reason: reason)
        }
    }

    /// 当前可画的数据（失败时是上一次成功的）。
    var value: Value? {
        switch self {
        case .idle, .failed(_, nil): return nil
        case .loading(let stale): return stale
        case let .loaded(value): return value
        case let .failed(_, stale): return stale
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        if case .idle = self { return true }
        return false
    }

    var failureReason: String? {
        if case let .failed(reason, _) = self { return reason }
        return nil
    }

    // MARK: - 变更

    mutating func beginLoading() {
        self = .loading(stale: value)
    }

    mutating func succeed(_ value: Value) {
        self = .loaded(value)
    }

    mutating func fail(_ reason: String) {
        self = .failed(reason: reason, stale: value)
    }

    /// 断开连接时用：把已取到的数据降级为 stale，而不是清空。
    /// 清空会让「断线」变成「没有」。
    mutating func markStale(reason: String) {
        self = .failed(reason: reason, stale: value)
    }

    private static func isEmpty(_ value: Value) -> Bool {
        if let collection = value as? any Collection { return collection.isEmpty }
        return false
    }
}

extension ContentState where Value == Void {
    static var loaded: ContentState<Void> { .loaded(()) }
}
