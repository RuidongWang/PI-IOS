import Foundation
import PIiOSCore

/// 删除结果回传给展示页的类型。
///
/// 详情页关闭后由父页面展示：部分结果（密钥未清、默认模型未转移）不能被
/// 一条通用「已删除」盖掉。
enum ProviderDeletionNotice: Equatable {
    case success(String)
    case needsAttention(String)
}

/// 一次删除的目标与本机线索（U07 的共享输入）。
///
/// 两个入口（PI-adaptor Provider 页、模型服务详情）各自把已有信息填进来，
/// 之后的分支判断、文案与「是否清本机」全部由 `ProviderDeletionUseCase` 统一决定。
struct ProviderDeletionTarget {
    let host: HostRecord
    let providerId: String
    let localRecordId: String?
    let displayName: String
    let keychainProviderIds: [String]
}

/// 两个删除入口共用的删除用例结果。
struct ProviderDeletionReport: Equatable {
    let presentation: ProviderDeletionPresentation
    let localRecordRemoved: Bool

    var tone: ProviderDeletionTone { presentation.tone }
    var message: String { presentation.message }
    var isCompleted: Bool { presentation.tone != .failure }
    /// 失败时给 alert 的文案；成功时 nil。
    var failureMessage: String? { presentation.tone == .failure ? presentation.message : nil }

    /// 详情页关闭后交给父页面的提示；失败没有 notice（详情页留在原地报错）。
    var notice: ProviderDeletionNotice? {
        switch presentation.tone {
        case .failure:
            return nil
        case .success:
            return .success(presentation.headline ?? presentation.message)
        case .needsAttention:
            guard let headline = presentation.headline else {
                return .needsAttention(presentation.message)
            }
            return .needsAttention("\(headline)：\(presentation.message)")
        }
    }
}

/// U07：把「v2 删除 → legacy 删除 → 清本机映射/密钥」收敛成一个共享用例。
///
/// 顺序与分支必须与模型服务详情页既有的正确实现一致：
/// - `NOT_FOUND` 视为幂等完成；
/// - 业务失败 / 回执不可解析 / 默认项未转移时保留本机映射与 Keychain 线索；
/// - 只有服务器侧确定完成后才清本机；
/// - 每阶段后核对 PI-adaptor 身份代次，避免结果记到另一台服务器。
@MainActor
struct ProviderDeletionUseCase {
    let model: AppModel
    let connection: ConnectionModel

    func delete(_ target: ProviderDeletionTarget) async -> ProviderDeletionReport {
        guard let operation = model.providerOperationContext(for: target.host) else {
            return report(.blocked(.hostChanged), stages: ProviderDeletionStages(), target: target)
        }

        var stages = ProviderDeletionStages()

        guard connection.state.isOnline else {
            return report(.blocked(.offline), stages: stages, target: target)
        }
        do {
            try await connection.deleteAdaptorProvider(id: target.providerId)
            stages.v2Removed = true
        } catch let error as RACPV2Error {
            if case .server(let code, _) = error, code == "NOT_FOUND" {
                stages.v2AlreadyAbsent = true
            } else {
                return failureReport(error, stages: stages, target: target)
            }
        } catch {
            return failureReport(error, stages: stages, target: target)
        }
        guard model.canApplyProviderOperation(operation) else {
            return report(.blocked(.hostChanged), stages: stages, target: target)
        }

        if let localRecordId = target.localRecordId {
            guard model.removeLocalProvider(id: localRecordId, context: operation) else {
                return report(.blocked(.hostChanged), stages: stages, target: target)
            }
            stages.localRecordRemoved = true
        }

        let finalOutcome: ProviderDeletionOutcome = stages.v2AlreadyAbsent ? .alreadyAbsent : .success(summary: nil)
        if finalOutcome.clearsLocalKey {
            stages.localKeyCleared = clearLocalKeys(target)
        }
        return report(finalOutcome, stages: stages, target: target)
    }

    /// 清除本机保存的 provider 密钥；返回「清除后确实没有残留」。
    /// 本来就没有密钥时也算已清（没有可删除的项不是失败）。
    private func clearLocalKeys(_ target: ProviderDeletionTarget) -> Bool {
        var allGone = true
        var seen = Set<String>()
        for providerId in target.keychainProviderIds where !providerId.isEmpty {
            guard seen.insert(providerId).inserted else { continue }
            let hostID = target.host.id
            let status = KeychainStore.providerKeyStatus(hostID: hostID, providerId: providerId)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else {
                // 读取失败不等于不存在：保留“未清干净”的事实，让用户可重试。
                allGone = false
                continue
            }
            _ = KeychainStore.deleteProviderKey(hostID: hostID, providerId: providerId)
            if KeychainStore.providerKeyStatus(hostID: hostID, providerId: providerId) != errSecItemNotFound {
                allGone = false
            }
        }
        return allGone
    }

    private func report(
        _ outcome: ProviderDeletionOutcome,
        stages: ProviderDeletionStages,
        target: ProviderDeletionTarget
    ) -> ProviderDeletionReport {
        let name = target.displayName.isEmpty ? target.providerId : target.displayName
        return ProviderDeletionReport(
            presentation: ProviderDeletionPresenter.present(
                outcome: outcome,
                stages: stages,
                providerName: name
            ),
            localRecordRemoved: stages.localRecordRemoved
        )
    }

    /// 传输层异常（未拿到结构化回执）：结果不确定，保留本机映射与密钥线索。
    private func failureReport(
        _ error: Error,
        stages: ProviderDeletionStages,
        target: ProviderDeletionTarget
    ) -> ProviderDeletionReport {
        ProviderDeletionReport(
            presentation: ProviderDeletionPresentation(
                tone: .failure,
                headline: nil,
                message: "\(ConnectionErrorText.describe(error))\n本机映射与密钥线索已保留，处理后可回到原入口重试。"
            ),
            localRecordRemoved: stages.localRecordRemoved
        )
    }
}
