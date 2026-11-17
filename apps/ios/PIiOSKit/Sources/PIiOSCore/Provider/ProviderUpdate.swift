import Foundation

/// 已配置 Provider 的完整更新输入。由 UI 提交整组模型，避免只改首项而丢掉其他模型。
public struct ProviderUpdateInput: Equatable, Sendable {
    public var name: String
    public var baseURL: String
    /// nil、空字符串或纯空格表示密钥不变；含控制字符的空白输入是校验错误。
    public var apiKey: String?
    public var models: [ProviderModelSpec]
    public var defaultModelID: String?

    public init(
        name: String,
        baseURL: String,
        apiKey: String? = nil,
        models: [ProviderModelSpec],
        defaultModelID: String? = nil
    ) {
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.models = models
        self.defaultModelID = defaultModelID
    }
}

public struct ProviderUpdateComposition: Equatable, Sendable {
    public let input: ProviderUpdateInput
    public let fields: JSONValue
    public let issues: [ProviderImportIssue]

    public var isValid: Bool { issues.isEmpty }

    public init(input: ProviderUpdateInput, fields: JSONValue, issues: [ProviderImportIssue]) {
        self.input = input
        self.fields = fields
        self.issues = issues
    }
}

public enum ProviderUpdateComposer {
    public static func compose(
        existing: RACPV2Provider,
        input: ProviderUpdateInput
    ) -> ProviderUpdateComposition {
        var normalized = input
        normalized.name = ECMAScriptString.trim(input.name)
        normalized.baseURL = ECMAScriptString.trim(input.baseURL)
        let key = input.apiKey.map(ECMAScriptString.trim)
        normalized.apiKey = key?.isEmpty == false ? key : nil
        normalized.defaultModelID = resolvedDefaultModelID(
            previous: input.defaultModelID,
            models: normalized.models
        )

        // 校验沿用导入契约的文本、数值与思考档位规则，但不创建新 Provider，
        // 也不要求留空的密钥再次通过 secretValue 必填校验。
        let validationInput = ProviderCreateInput(
            name: normalized.name,
            vendorKey: existing.vendorKey,
            type: existing.type,
            protocol: validationProtocolName(for: existing),
            authKind: existing.authKind,
            baseUrl: normalized.baseURL,
            models: normalized.models,
            secretValue: validationSecret(for: existing, input: input),
            defaultModelId: normalized.defaultModelID
        )
        let issues = ProviderImportValidation.issues(
            in: ProviderImportPayload.make(inputs: [validationInput])
        )
        var fields: [String: JSONValue] = [
            "name": .string(normalized.name),
            "vendorKey": .string(existing.vendorKey),
            "type": .string(existing.type),
            "protocol": .string(existing.protocolName),
            "baseUrl": .string(normalized.baseURL),
            "authKind": .string(existing.authKind),
            "models": .array(normalized.models.map(modelJSON)),
        ]
        // PI-adaptor 的 provider/update 是完整模型替换；缺省 apiKey 才有“保留密钥”语义。
        if let apiKey = normalized.apiKey, existing.authKind != "none" {
            fields["apiKey"] = .string(apiKey)
        }
        return ProviderUpdateComposition(
            input: normalized,
            fields: .object(fields),
            issues: issues
        )
    }

    private static func validationProtocolName(for provider: RACPV2Provider) -> String {
        // provider/list 返回的是 PI-adaptor 的线路协议；导入校验使用创建协议枚举。
        // 这里只转换校验输入，provider/update 仍发送原协议名。
        provider.protocolName == "openai_completions" ? "openai_compatible" : provider.protocolName
    }

    private static func validationSecret(
        for provider: RACPV2Provider,
        input: ProviderUpdateInput
    ) -> String? {
        guard provider.authKind != "none" else { return nil }
        // nil、空字符串和纯空格保留服务器密钥。
        // 保留原始空白让共用校验器报告错误，而不是把哨兵值写入更新载荷。
        if let key = input.apiKey, !key.isEmpty {
            // 纯空格视为没有编辑密钥；制表符/换行等控制字符不能静默忽略。
            if ECMAScriptString.trim(key).isEmpty,
               !key.unicodeScalars.contains(where: { $0.value <= 0x1F || $0.value == 0x7F }) {
                return "unchanged-secret-placeholder"
            }
            return key
        }
        return "unchanged-secret-placeholder"
    }

    /// v2 的模型字段转换；扩展能力只从本机旧镜像保留，不臆造服务器值。
    public static func modelSpec(_ model: RACPV2ProviderModel) -> ProviderModelSpec {
        ProviderModelSpec(
            id: model.id, contextWindow: model.contextWindow, maxTokens: model.maxTokens,
            thinkingLevels: model.thinkingLevels, defaultThinkingLevel: model.defaultThinkingLevel,
            alias: model.displayName == model.id ? nil : model.displayName,
            supportsImages: model.supportsImages
        )
    }

    /// 保留仍存在的默认模型；被删除后选择剩余模型中的第一项，避免本机绑定悬空。
    ///
    /// 这是「请求/编辑表单」层的兜底：它把 `nil` 也补成首项，方便旧一次性模型 ID
    /// 表单继续工作。本机默认模型记录必须用 `ProviderDefaultModelRecorder`：那里
    /// 区分「用户明确选择」与「本机原有默认」，否则给任意服务改个名字都会把它变成
    /// 默认模型。
    public static func resolvedDefaultModelID(
        previous: String?,
        models: [ProviderModelSpec]
    ) -> String? {
        previous.flatMap { id in models.contains(where: { $0.id == id }) ? id : nil }
            ?? models.first?.id
    }

    public static func modelJSON(_ model: ProviderModelSpec) -> JSONValue {
        .object([
            "id": .string(model.id),
            "displayName": .string(model.alias ?? model.id),
            "contextWindow": .number(Double(model.contextWindow)),
            "maxTokens": .number(Double(model.maxTokens)),
            "thinkingLevels": .array(model.thinkingLevels.map(JSONValue.string)),
            "defaultThinkingLevel": model.defaultThinkingLevel.map(JSONValue.string) ?? .null,
            "supportsImages": .bool(model.supportsImages ?? false),
        ])
    }
}

/// 本机「默认模型」写入规则（host 级单选项）。
///
/// 默认模型决定设置页「默认模型」一行显示哪个服务的哪个模型。它必须是**用户
/// 明确选择过**的值，不能在编辑服务信息、刷新模型列表这类旁路操作里被顺手改掉；
/// 原来的实现用 `resolvedDefaultModelID(previous:models:)` 兜底成首项，导致：
/// - 用户点「设为默认」时，传入的新选择被本机旧默认覆盖，界面看似切换、退出即还原；
/// - 任何没有默认项的 provider 只要被编辑一次就会抢走全局默认。
///
/// 规则按优先级：
/// 1. `explicit` 合法（在本次模型清单里）→ 用户明确选择，优先；
/// 2. `previous` 合法 → 保留本机原有默认；
/// 3. `previous` 非空但模型已被移出清单 → 这是原本持有默认的 provider，转移到首项；
/// 4. 该 host 之前没有任何 provider 且服务端声明了默认（首条导入）→ 首项；
/// 5. 其余一律 nil：不凭空制造默认项。
public enum ProviderDefaultModelRecorder {
    public static func resolvedDefaultModelID(
        explicit: String?,
        previous: String?,
        models: [ProviderModelSpec],
        serverDefaultSet: Bool,
        isOnlyProviderOnHost: Bool
    ) -> String? {
        let modelIDs = Set(models.map(\.id))
        if let explicit, modelIDs.contains(explicit) { return explicit }
        if let previous, modelIDs.contains(previous) { return previous }
        if previous != nil { return models.first?.id }
        if isOnlyProviderOnHost, serverDefaultSet { return models.first?.id }
        return nil
    }
}
