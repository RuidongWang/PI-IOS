import Foundation

/// 模型服务密钥的归属状态（`keyStorage` / `hasApiKey` / `apiKeyMask` 的组合语义）。
///
/// 服务端新语义（v0.0.3 起）：`authKind == "api_key"` 时返回 `hasApiKey: true`、
/// `apiKeyMask: null`、可选 `keyStorage: "client"`；密钥只存在于本机 Keychain。
/// 因此 `apiKeyMask == nil` **不能**再被解释成「无密钥」，必须再查本机 Keychain。
public enum ProviderSecretStatus: Equatable, Sendable {
    /// `authKind == "none"`：这类服务本来就不需要密钥。
    case notRequired
    /// 密钥只在本机 Keychain；`hasLocalKey` 说明本机是否真的还有这份密钥。
    case localOnly(hasLocalKey: Bool)
    /// 旧服务端仍返回掩码：密钥在服务器侧托管。
    case serverManaged(mask: String)
    /// 服务端声明没有密钥（旧语义），本机也没有可用的替代说明。
    case missing
}

public enum ProviderSecretDisplay {
    /// 由服务端 provider 视图字段 + 本机 Keychain 查询结果推导状态。
    public static func status(
        authKind: String,
        hasApiKey: Bool,
        apiKeyMask: String?,
        keyStorage: String?,
        hasLocalKey: Bool
    ) -> ProviderSecretStatus {
        if authKind == "none" {
            return .notRequired
        }
        // 新服务端显式声明密钥只存本机：即使 hasApiKey 为 true 也要看本机 Keychain。
        if keyStorage == "client" {
            return .localOnly(hasLocalKey: hasLocalKey)
        }
        if let mask = apiKeyMask, !mask.isEmpty {
            return .serverManaged(mask: mask)
        }
        if hasApiKey {
            // 新语义下 apiKeyMask 为 null；只有本机 Keychain 能说明密钥是否真的可用。
            return .localOnly(hasLocalKey: hasLocalKey)
        }
        return .missing
    }

    public static func text(_ status: ProviderSecretStatus) -> String {
        switch status {
        case .notRequired:
            return "无需密钥"
        case .localOnly(let hasLocalKey):
            return hasLocalKey ? "密钥仅存本机" : "本机缺少密钥"
        case .serverManaged(let mask):
            return "密钥 \(mask)"
        case .missing:
            return "无密钥"
        }
    }

    /// 便捷入口：直接取展示文案。
    public static func text(
        authKind: String,
        hasApiKey: Bool,
        apiKeyMask: String?,
        keyStorage: String?,
        hasLocalKey: Bool
    ) -> String {
        text(status(
            authKind: authKind,
            hasApiKey: hasApiKey,
            apiKeyMask: apiKeyMask,
            keyStorage: keyStorage,
            hasLocalKey: hasLocalKey
        ))
    }

    /// 本机模型记录没有服务端 `authKind`/`hasApiKey`，只能按本机 Keychain 展示。
    public static func localText(hasLocalKey: Bool) -> String {
        text(.localOnly(hasLocalKey: hasLocalKey))
    }

    /// 本机缺少密钥时给用户的下一步说明；有密钥或不需要密钥时返回 nil。
    public static func missingKeyGuidance(_ status: ProviderSecretStatus) -> String? {
        guard case .localOnly(false) = status else { return nil }
        return "本机没有该模型服务的密钥，发送时会被服务器拒绝。请在“模型服务”里重新填写 API Key。"
    }
}
