import Foundation

/// 回答草稿的作用域：服务器（host）+ 会话 + 提问卡。
///
/// 视图层用 `storageKey` 作为字典键，切换服务器或会话后即使遇到同名 `inputId`
/// 也不会把 A 会话选中的答案带到 B 会话（U06 / AC-11.1）。
public struct AnswerDraftScope: Hashable, Sendable {
    public let hostID: String
    public let sessionID: String
    public let inputID: String

    public init(hostID: String, sessionID: String, inputID: String) {
        self.hostID = hostID
        self.sessionID = sessionID
        self.inputID = inputID
    }

    /// 稳定且不会因分隔符撞键的字典键：先写长度再写内容，任意字符都不会造成歧义。
    public var storageKey: String {
        [hostID, sessionID, inputID]
            .map { "\($0.count):\($0)" }
            .joined(separator: "|")
    }
}

/// 提交回答的结构化结果。视图只在成功或明确失效时清空已选答案（U06）。
public enum InputAnswerOutcome: Equatable, Sendable {
    /// 服务器已受理回答。
    case submitted
    /// 可重试的失败（网络中断、超时、5xx 等）：必须保留用户已选答案。
    case failed(reason: String)
    /// 服务器明确拒收这张卡（已过期 / 版本冲突 / 不存在）：继续留着选择没有意义。
    case noLongerActionable(reason: String)
    /// 提交前后刷新发现提问已由其他端处理、不再出现在快照里：明确终态。
    case stale(reason: String)

    /// 只有成功或明确失效才清空已选答案；普通失败保留草稿。
    public var clearsDraft: Bool {
        switch self {
        case .submitted, .noLongerActionable, .stale:
            return true
        case .failed:
            return false
        }
    }

    /// 供视图/日志展示的说明；`nil` 表示无需额外文案。
    public var reason: String? {
        switch self {
        case .submitted:
            return nil
        case .failed(let reason), .noLongerActionable(let reason), .stale(let reason):
            return reason
        }
    }
}

/// 回答提交失败后的分诊策略：把一次失败映射成「保留草稿重试」还是「明确失效」。
///
/// - 服务器给出能证明卡片已不可处理的错误码 → 失效；
/// - 刷新后发现提问已不在快照里（其他端回答了）→ 失效；
/// - 其余（超时、断网、5xx）→ 保留草稿。
public enum AnswerDraftPolicy {
    public static func outcomeAfterFailure(
        serverCode: RACPErrorCode?,
        cardStillPending: Bool,
        reason: String
    ) -> InputAnswerOutcome {
        if !cardStillPending {
            return .stale(reason: "该提问已由其他端处理：\(reason)")
        }
        if let serverCode, DecisionPolicy.marksCardStale(after: serverCode) {
            return .noLongerActionable(
                reason: "该提问已失效：\(ConnectionFailureClassifier.userMessage(forRACPCode: serverCode))"
            )
        }
        return .failed(reason: reason)
    }
}
