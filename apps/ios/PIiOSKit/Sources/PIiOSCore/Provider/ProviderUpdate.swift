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
