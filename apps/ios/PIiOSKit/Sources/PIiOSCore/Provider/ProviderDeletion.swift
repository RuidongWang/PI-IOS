import Foundation

/// 删除一个模型服务时可能被阻断的前置条件（此时没有发出删除请求）。
///
/// U07 要求两个管理入口对同一批分支给出一致结果；把「离线」「PI-adaptor 切换」
/// 这类本地前置条件也放进统一结果模型，界面就不必各自发明失败文案。
public enum ProviderDeletionBlockReason: Equatable, Sendable {
    /// PI-adaptor 不在线：无法确认服务器上的记录是否还在。
    case offline
    /// 删除过程中本机当前 PI-adaptor 身份变化：结果不能记到另一台服务器。
    case hostChanged
}

/// 删除回执的统一结果模型（U07）。
///
/// 两个删除入口（PI-adaptor Provider 页、模型服务详情）都必须先把服务器回执
/// 映射到这套分支，再决定「是否清本机映射」「是否清 Keychain」「是否需要用户跟进」。
/// 不允许任一入口把结构化业务失败当作成功继续清理本机数据。
public enum ProviderDeletionOutcome: Equatable, Sendable {
    /// 服务器明确完成删除。`summary == nil` 表示只走了 v2 `provider/delete`
    /// 这条没有 `PI_HOST_REMOVED` 回执的路径。
    case success(summary: ProviderRemoveSummary?)
    /// 服务器上本来就不存在该记录（`NOT_FOUND`）：按幂等完成处理，本机残留仍需清理。
    case alreadyAbsent
    /// 记录与密钥已删除，但默认模型因创建时间不可比未转移（契约 §4.2/§8 的四键例外）。
    case defaultTransferOrderUnknown(removedProviderId: String, secretCleared: Bool)
    /// 服务器明确失败：保留本机映射与 Keychain 线索，供用户处理后重试。
    case failure(ProviderRemoveFailureCode)
    /// 回执无法解析：结果不确定，保留本机映射与 Keychain 线索。
    case unparseable(reason: String)
    /// 本地前置条件不满足，未发出删除请求。
    case blocked(ProviderDeletionBlockReason)

    /// 把 legacy SSH 通道的 `PI_HOST_REMOVED` / `PI_HOST_FAILED` 回执映射成统一结果。
    ///
    /// `failure(.notFound)` 是幂等删除的正常结局，映射为 `.alreadyAbsent` 而不是失败，
    /// 与 `RemoteProviderOperations.removeProvider` 对 `NOT_FOUND` 的处理保持一致。
    public init(receipt: ProviderRemoveReceipt) {
        switch receipt {
        case .success(let summary):
            self = .success(summary: summary)
        case .defaultTransferOrderUnknown(let removedProviderId, let secretCleared):
            self = .defaultTransferOrderUnknown(
                removedProviderId: removedProviderId,
                secretCleared: secretCleared
            )
        case .failure(.notFound):
            self = .alreadyAbsent
        case .failure(let code):
            self = .failure(code)
        case .unparseable(let reason):
            self = .unparseable(reason: reason)
        }
    }

    /// 服务器侧是否已经确定删除（可继续清本机映射）。
    public var isCompleted: Bool {
        switch self {
        case .success, .alreadyAbsent, .defaultTransferOrderUnknown:
            return true
        case .failure, .unparseable, .blocked:
            return false
        }
    }

    /// 完成时才能移除本机映射；失败/不确定/被阻断都必须保留恢复线索。
    public var removesLocalRecord: Bool { isCompleted }

    /// 完成时才能清除本机 Keychain 中的 provider 密钥。
    public var clearsLocalKey: Bool { isCompleted }

    public var keepsRecoveryContext: Bool { !isCompleted }

    /// 是否「已删除但需要用户跟进」（当前只有默认项未转移的明确例外）。
    public var needsAttention: Bool {
        if case .defaultTransferOrderUnknown = self { return true }
        return false
    }
}

/// 一次删除实际走到的阶段，用于生成用户能读懂的结果说明。
///
/// U07 要求提示明确区分 v2 镜像、legacy 存储、默认模型三个阶段，但普通界面
/// 只能用用户语言描述（「服务器记录」「旧版服务记录」「默认模型」）。
public struct ProviderDeletionStages: Equatable, Sendable {
    /// 本次是否向 v2 PI-adaptor 发过删除请求。
    public var v2Requested: Bool
    /// v2 上的记录由本次删除。
    public var v2Removed: Bool
    /// v2 上原本就没有这条记录。
    public var v2AlreadyAbsent: Bool
    /// legacy SSH 存储中的记录由本次删除。
    public var legacyCleared: Bool
    /// legacy 存储中原本就没有这条记录。
    public var legacyAlreadyAbsent: Bool
    /// 本机映射是否已移除。
    public var localRecordRemoved: Bool
    /// 本机 Keychain 中的密钥是否已清除。
    public var localKeyCleared: Bool

    public init(
        v2Requested: Bool = false,
        v2Removed: Bool = false,
        v2AlreadyAbsent: Bool = false,
        legacyCleared: Bool = false,
        legacyAlreadyAbsent: Bool = false,
        localRecordRemoved: Bool = false,
        localKeyCleared: Bool = false
    ) {
        self.v2Requested = v2Requested
        self.v2Removed = v2Removed
        self.v2AlreadyAbsent = v2AlreadyAbsent
        self.legacyCleared = legacyCleared
        self.legacyAlreadyAbsent = legacyAlreadyAbsent
        self.localRecordRemoved = localRecordRemoved
        self.localKeyCleared = localKeyCleared
    }
}

public enum ProviderDeletionTone: Equatable, Sendable {
    case success
    case needsAttention
    case failure
}

/// 删除结果对用户可见的形态：语气 + 标题前缀 + 说明。
public struct ProviderDeletionPresentation: Equatable, Sendable {
    public let tone: ProviderDeletionTone
    /// 成功类结果的标题前缀，例如「已删除模型服务「DeepSeek」」；失败为 nil。
    public let headline: String?
    public let message: String

    public init(tone: ProviderDeletionTone, headline: String?, message: String) {
        self.tone = tone
        self.headline = headline
        self.message = message
    }
}

/// 把统一结果模型翻译成用户语言（U07 的「三个阶段用用户语言解释」）。
public enum ProviderDeletionPresenter {
    /// 服务器成功回执的详情文案。保留既有措辞，避免同一结果在两条入口出现两套说法。
    public static func summaryText(_ summary: ProviderRemoveSummary) -> String {
        guard summary.effect == .deleted else {
            return "服务器上已不存在该记录；本机残留记录已清理，本次没有再次执行删除。"
        }
        var parts = ["服务器已删除记录与密钥。"]
        switch summary.defaultMoved {
        case .moved(let providerId, let modelId):
            parts.append("默认模型已转给 \(providerId.prefix(8))… / \(modelId)。")
        case .notMoved(let reason):
            parts.append(reason == "no_remaining"
                ? "已无剩余模型服务，请重新添加。"
                : "没有合格的候选模型，默认模型未转移，请重新选择。")
        case nil:
            break
        }
        if summary.remainingEligible == 0 {
            parts.append("当前已无可用模型服务。")
        }
        return parts.joined(separator: " ")
    }

    public static func present(
        outcome: ProviderDeletionOutcome,
        stages: ProviderDeletionStages,
        providerName: String
    ) -> ProviderDeletionPresentation {
        let headline = "已删除模型服务「\(providerName)」"
        switch outcome {
        case .success(let summary):
            var parts: [String] = []
            if let summary {
                parts.append(summaryText(summary))
            } else {
                parts.append("已从 PI-adaptor 删除该模型服务的记录与密钥。")
            }
            parts.append(contentsOf: stageNotes(stages, includeServerAbsent: summary == nil))
            return ProviderDeletionPresentation(
                tone: .success,
                headline: headline,
                message: parts.joined(separator: " ")
            )
        case .alreadyAbsent:
            var parts = ["服务器上已不存在该记录，本次没有再次执行删除。"]
            parts.append(contentsOf: stageNotes(stages, includeServerAbsent: true))
            return ProviderDeletionPresentation(
                tone: .success,
                headline: headline,
                message: parts.joined(separator: " ")
            )
        case .defaultTransferOrderUnknown(_, let secretCleared):
            // 契约 §4.2/§8 的明确例外：已删记录，但默认项因 createdAt 不可比未转移。
            var parts = [secretCleared
                ? "服务器已删除记录与密钥，但默认模型因创建时间不可比未转移，请重新选择默认模型。"
                : "服务器已删除记录，但密钥未清除且默认模型未转移，请人工在服务器上处理。"]
            parts.append(contentsOf: stageNotes(stages, includeServerAbsent: false))
            return ProviderDeletionPresentation(
                tone: .needsAttention,
                headline: headline,
                message: parts.joined(separator: " ")
            )
        case .failure(let code):
            return ProviderDeletionPresentation(
                tone: .failure,
                headline: nil,
                message: "\(code.displayMessage)\n本机映射与密钥线索已保留，处理后可回到原入口重试。"
            )
        case .unparseable(let reason):
            return ProviderDeletionPresentation(
                tone: .failure,
                headline: nil,
                message: "服务器回执无法解析：\(reason)。本机映射与密钥线索已保留，请在服务器上人工确认后再处理。"
            )
        case .blocked(.offline):
            return ProviderDeletionPresentation(
                tone: .failure,
                headline: nil,
                message: "服务器离线：无法确认删除结果，本机映射与密钥线索已保留。请连接后重试。"
            )
        case .blocked(.hostChanged):
            return ProviderDeletionPresentation(
                tone: .failure,
                headline: nil,
                message: "PI-adaptor 在删除过程中已切换：本机映射未改动，请到原 PI-adaptor 上核对删除结果。"
            )
        }
    }

    /// 只描述本次实际走到的阶段，不臆造未执行的步骤；服务器删除本身已由主文案说明。
    private static func stageNotes(
        _ stages: ProviderDeletionStages,
        includeServerAbsent: Bool
    ) -> [String] {
        var notes: [String] = []
        if includeServerAbsent && stages.v2AlreadyAbsent {
            notes.append("PI-adaptor 上原本已没有这条记录。")
        }
        if stages.legacyCleared {
            notes.append("旧版服务记录也已一并清理。")
        } else if includeServerAbsent && stages.legacyAlreadyAbsent {
            notes.append("旧版服务里原本也没有这条记录。")
        }
        if stages.localRecordRemoved {
            notes.append("本机记录已清理。")
        }
        if stages.localKeyCleared {
            notes.append("本机密钥已清除。")
        } else if stages.localRecordRemoved {
            notes.append("本机密钥未能清除，请重试删除或到系统 Keychain 中手动清理。")
        }
        return notes
    }
}
