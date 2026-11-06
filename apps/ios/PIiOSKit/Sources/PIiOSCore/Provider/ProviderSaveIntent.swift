import Foundation

/// 本次提交对 API Key 的意图。
///
/// `nil`、空字符串、纯空白都表示「不改密钥」：`provider/update` 缺省 `apiKey`
/// 才会保留服务器原密钥；纯空白不能作为哨兵值写进请求。
public enum ProviderAPIKeyChange: Equatable, Sendable {
    case unchanged
    case replace(String)

    public init(input: String?) {
        guard let input else {
            self = .unchanged
            return
        }
        let trimmed = ECMAScriptString.trim(input)
        // 归一化一次：请求与 Keychain 都必须写入同一个值，不能让「服务器收到 A、
        // 本机存了带空白的 A'」这种分叉出现。
        self = trimmed.isEmpty ? .unchanged : .replace(trimmed)
    }

    /// 请求里应该携带的明文密钥；`nil` 表示省略该字段（保留原密钥）。
    public var requestValue: String? {
        if case .replace(let value) = self { return value }
        return nil
    }

    /// 本机 Keychain 应该写入的明文密钥；与 `requestValue` 永远是同一个值。
    public var keychainValue: String? { requestValue }

    public var isReplacement: Bool { requestValue != nil }
}

/// 提交前冻结的模型服务保存意图（U14 的「不可变提交值」）。
///
/// 请求构造、回执后的本机映射写入与 Keychain 写入都只读这份快照，不再读界面上的
/// 实时输入；保存期间后续输入即便变化，也不会被混进本次请求或本次本机写入。
public struct ProviderSaveIntent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case create
        case update(providerId: String)
    }

    public let kind: Kind
    /// 提交时所在的 Host；Keychain 写入必须按这个 id，不能回读「当前服务器」。
    public let hostID: UUID
    public let name: String
    public let baseURL: String
    public let models: [ProviderModelSpec]
    public let apiKeyChange: ProviderAPIKeyChange
    /// 提交时输入框里的原始文本，只用于判断「保存期间是否又被编辑」。
    public let apiKeyDraft: String
    public let legacyProviderId: String?
    public let hostV2Mirror: Bool?
    public let defaultModelID: String?

    public init(
        kind: Kind,
        hostID: UUID,
        name: String,
        baseURL: String,
        models: [ProviderModelSpec],
        apiKey: String?,
        apiKeyDraft: String? = nil,
        legacyProviderId: String? = nil,
        hostV2Mirror: Bool? = nil,
        defaultModelID: String? = nil
    ) {
        self.kind = kind
        self.hostID = hostID
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.apiKeyChange = ProviderAPIKeyChange(input: apiKey)
        self.apiKeyDraft = apiKeyDraft ?? apiKey ?? ""
        self.legacyProviderId = legacyProviderId
        self.hostV2Mirror = hostV2Mirror
        self.defaultModelID = defaultModelID
    }

    /// 更新类意图的目标 provider id；创建意图为 nil。
    public var providerId: String? {
        if case .update(let providerId) = kind { return providerId }
        return nil
    }

    public var isCreate: Bool { kind == .create }

    /// 发送给服务器的新密钥（缺省表示保留原密钥）。
    public var requestAPIKey: String? { apiKeyChange.requestValue }

    /// 回执成功后写入本机 Keychain 的密钥，与请求值严格同源。
    public var keychainAPIKey: String? { apiKeyChange.keychainValue }

    /// 创建意图必须先有密钥；返回 nil 表示可以提交。
    public var createRejection: String? {
        guard isCreate else { return nil }
        guard apiKeyChange.isReplacement else {
            return "请填写 API Key：v0.0.3 起密钥只保存在本机，创建时必须提供。"
        }
        return nil
    }

    /// 本次更新应该提交的完整输入，全部来自冻结值。
    public func updateInput() -> ProviderUpdateInput {
        ProviderUpdateInput(
            name: name,
            baseURL: baseURL,
            apiKey: requestAPIKey,
            models: models,
            defaultModelID: defaultModelID
        )
    }

    /// 保存完成后，界面上的密钥输入是否还等于提交值。
    /// `false` 表示用户（或后续逻辑）在保存期间又编辑过，不能按本次结果清空输入。
    public func apiKeyDraftIsUnchanged(_ current: String) -> Bool {
        current == apiKeyDraft
    }
}
