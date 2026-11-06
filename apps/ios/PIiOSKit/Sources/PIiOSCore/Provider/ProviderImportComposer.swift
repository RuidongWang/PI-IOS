import Foundation

/// String-backed model form values. The composer owns all conversion and
/// normalization so the view has no hidden wire-format rules.
public struct ProviderModelDraftInput: Equatable, Sendable {
    public var base: ProviderModelSpec
    public var modelId: String
    public var displayName: String
    public var contextWindow: String
    public var maxTokens: String
    public var thinkingLevels: String
    public var defaultThinkingLevel: String

    public init(
        base: ProviderModelSpec,
        modelId: String,
        displayName: String,
        contextWindow: String,
        maxTokens: String,
        thinkingLevels: String,
        defaultThinkingLevel: String
    ) {
        self.base = base
        self.modelId = modelId
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.thinkingLevels = thinkingLevels
        self.defaultThinkingLevel = defaultThinkingLevel
    }
}

public struct ProviderImportComposition: Equatable, Sendable {
    public let input: ProviderCreateInput
    public let payload: ProviderImportPayload
    public let issues: [ProviderImportIssue]

    public var isValid: Bool { issues.isEmpty }

    public init(
        input: ProviderCreateInput,
        payload: ProviderImportPayload,
        issues: [ProviderImportIssue]
    ) {
        self.input = input
        self.payload = payload
        self.issues = issues
    }
}

/// Pure UI-to-wire mapping for a single OpenAI-compatible provider.
public enum ProviderImportComposer {
    public static func modelSpec(from draft: ProviderModelDraftInput) -> ProviderModelSpec {
        var spec = draft.base
        spec.id = ECMAScriptString.trim(draft.modelId)

        let alias = ECMAScriptString.trim(draft.displayName)
        spec.alias = alias.isEmpty || alias == spec.id ? nil : alias
        spec.contextWindow = Int(ECMAScriptString.trim(draft.contextWindow)) ?? -1
        spec.maxTokens = Int(ECMAScriptString.trim(draft.maxTokens)) ?? -1
        spec.thinkingLevels = draft.thinkingLevels
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",")
            .map { ECMAScriptString.trim(String($0)) }
            .filter { !$0.isEmpty }

        let defaultLevel = ECMAScriptString.trim(draft.defaultThinkingLevel)
        spec.defaultThinkingLevel = defaultLevel.isEmpty ? nil : defaultLevel
        return normalize(spec)
    }

    public static func compose(
        serviceName: String,
        baseURL: String,
        apiKey: String,
        models: [ProviderModelSpec],
        setDefaultModel: Bool,
        vendorKey requestedVendorKey: String = "custom",
        wireProtocol: String = "openai_compatible"
    ) -> ProviderImportComposition {
        let normalizedBaseURL = ECMAScriptString.trim(baseURL)
        let normalizedName = ECMAScriptString.trim(serviceName)
        let normalizedVendorKey = ECMAScriptString.trim(requestedVendorKey)
        let normalizedModels = models.map(normalize)
        let defaultModelId = setDefaultModel ? normalizedModels.first?.id : nil
        let normalizedProtocol = ECMAScriptString.trim(wireProtocol)

        let input = ProviderCreateInput(
            name: normalizedName.isEmpty
                ? defaultServiceName(for: normalizedBaseURL)
                : normalizedName,
            vendorKey: normalizedVendorKey.isEmpty ? "custom" : normalizedVendorKey,
            type: isSupportedProtocol(normalizedProtocol) ? "custom" : "openai_compatible",
            protocol: normalizedProtocol.isEmpty ? "openai_compatible" : normalizedProtocol,
            authKind: "api_key_and_base_url",
            baseUrl: normalizedBaseURL,
            models: normalizedModels,
            secretValue: ECMAScriptString.trim(apiKey),
            apiStyle: apiStyle(for: normalizedProtocol),
            defaultModelId: defaultModelId
        )
        let payload = ProviderImportPayload.make(
            inputs: [input],
            defaultSelection: defaultModelId.map {
                ProviderImportDefaultSelection(providerIndex: 0, modelId: $0)
            }
        )
        return ProviderImportComposition(
            input: input,
            payload: payload,
            issues: ProviderImportValidation.issues(in: payload)
        )
    }

    /// 线路协议对应的上游 `apiStyle`（契约 §4.3 的取值集合）。
    public static func apiStyle(for wireProtocol: String) -> String {
        switch ECMAScriptString.trim(wireProtocol) {
        case "openai-completions": return "chat_completions"
        case "openai-responses": return "responses"
        case "anthropic-messages": return "anthropic_messages"
        case "google-generative-ai": return "google_generative_ai"
        default: return "chat_completions"
        }
    }

    public static func isSupportedProtocol(_ wireProtocol: String) -> Bool {
        ProviderVendorSchema.supportedProtocols.contains(ECMAScriptString.trim(wireProtocol))
    }

    /// `vendorKey` 在服务器上必须唯一。四种协议各自一个前缀，再按 Base URL
    /// 取稳定后缀，同一网关重复导入会得到同一个 key，不同网关不会互相冲突。
    public static func vendorKey(for wireProtocol: String, baseURL: String) -> String {
        let normalized = ECMAScriptString.trim(wireProtocol)
        let prefix = normalized.isEmpty ? "custom" : normalized
        let url = ECMAScriptString.trim(baseURL)
        guard !url.isEmpty else { return prefix }
        var hash: UInt32 = 2_166_136_261
        for byte in url.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return "\(prefix)-\(String(hash, radix: 16))"
    }

    public static func defaultServiceName(for rawURL: String) -> String {
        let normalizedURL = ECMAScriptString.trim(rawURL)
        guard let components = URLComponents(string: normalizedURL),
              let leaf = components.path.split(separator: "/").last,
              !leaf.isEmpty
        else { return "Custom" }
        let text = String(leaf).replacingOccurrences(of: "-", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func normalize(_ original: ProviderModelSpec) -> ProviderModelSpec {
        var spec = original
        spec.id = ECMAScriptString.trim(spec.id)

        if let alias = spec.alias {
            let trimmed = ECMAScriptString.trim(alias)
            spec.alias = trimmed.isEmpty || trimmed == spec.id ? nil : trimmed
        }
        if let source = spec.contextWindowSource {
            spec.contextWindowSource = ECMAScriptString.trim(source)
        }
        if let source = spec.maxTokensSource {
            spec.maxTokensSource = ECMAScriptString.trim(source)
        }
        spec.thinkingLevels = spec.thinkingLevels.map(ECMAScriptString.trim)
        if let defaultLevel = spec.defaultThinkingLevel {
            let trimmed = ECMAScriptString.trim(defaultLevel)
            spec.defaultThinkingLevel = trimmed.isEmpty ? nil : trimmed
        }
        if let thinkingProtocol = spec.thinkingProtocol {
            let trimmed = ECMAScriptString.trim(thinkingProtocol)
            spec.thinkingProtocol = trimmed.isEmpty ? nil : trimmed
        }
        return spec
    }
}
