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
    /// v2 PI-adaptor 上的 provider id。
    let providerId: String
    /// legacy SSH 存储里的 provider id（镜像记录可能与 v2 id 不同）。
    let legacyProviderId: String?
    /// `true` = v2 记录，`false` = 仅 legacy，`nil` = 旧记录需要探测。
    let hostV2Mirror: Bool?
    /// 本机映射记录的 `StoredModelProvider.id`；没有本机记录时为 nil。
    let localRecordId: String?
    /// 用于结果提示的服务名称。
    let displayName: String
    /// 删除成功后应清除的本机 Keychain 密钥 id（v2 id 与 legacy id）。
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

        // 1) v2 PI-adaptor 镜像。
        if target.hostV2Mirror ?? true {
            stages.v2Requested = true
            guard connection.state.isOnline else {
                return report(.blocked(.offline), stages: stages, target: target)
            }
            do {
                try await connection.deleteAdaptorProvider(id: target.providerId)
                stages.v2Removed = true
            } catch let error as RACPV2Error {
                if case .server(let code, _) = error, code == "NOT_FOUND" {
                    // 幂等删除：服务器上已经查不到这条记录，继续清理其余部分。
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
        }

        // 2) legacy SSH 存储。旧记录没有 `hostV2Mirror` 标记时要探测：
        //    未执行过 v2 删除的旧记录，其 id 就是 legacy id。
        var legacyId = target.legacyProviderId
        if legacyId == nil, target.hostV2Mirror != true, !stages.v2Removed {
            legacyId = target.providerId
        }
        var serverOutcome: ProviderDeletionOutcome?
        if let legacyProviderId = legacyId {
            do {
                let receipt = try await connection.removeProvider(
                    record: target.host,
                    providerId: legacyProviderId
                )
                guard model.canApplyProviderOperation(operation) else {
                    return report(.blocked(.hostChanged), stages: stages, target: target)
                }
                let outcome = ProviderDeletionOutcome(receipt: receipt)
                switch outcome {
                case .success(let summary):
                    stages.legacyCleared = summary?.effect == .deleted
                    stages.legacyAlreadyAbsent = summary?.effect == .absent
                    serverOutcome = outcome
                case .alreadyAbsent:
                    stages.legacyAlreadyAbsent = true
                    serverOutcome = outcome
                case .defaultTransferOrderUnknown:
                    stages.legacyCleared = true
                    serverOutcome = outcome
                case .failure, .unparseable, .blocked:
                    // 业务失败 / 回执不可解析：本机映射与密钥线索必须保留。
                    return report(outcome, stages: stages, target: target)
                }
            } catch {
                return failureReport(error, stages: stages, target: target)
            }
        }

        // 3) 本机映射与 Keychain。只有前面所有服务器阶段都确定完成才会到这里。
        if let localRecordId = target.localRecordId {
            guard model.removeLocalProvider(id: localRecordId, context: operation) else {
                return report(.blocked(.hostChanged), stages: stages, target: target)
            }
            stages.localRecordRemoved = true
        }

        let finalOutcome: ProviderDeletionOutcome
        if let serverOutcome {
            finalOutcome = serverOutcome
        } else if stages.v2AlreadyAbsent {
            finalOutcome = .alreadyAbsent
        } else {
            finalOutcome = .success(summary: nil)
        }
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
            if KeychainStore.loadProviderKey(hostID: hostID, providerId: providerId) == nil {
                continue
            }
            _ = KeychainStore.deleteProviderKey(hostID: hostID, providerId: providerId)
            if KeychainStore.loadProviderKey(hostID: hostID, providerId: providerId) != nil {
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
