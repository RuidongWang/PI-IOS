import Foundation

/// 运行中的 PI-adaptor 是否与客户端兼容。
///
/// 安装回执（`HostRecord.installReceipt`）只记录「本机上一次安装了什么」，不是
/// 「本机期望服务器运行什么」：服务器可能被另一台设备或手工升级/回滚。之前设置页
/// 用回执版本当期望值，导致服务器升级到更新的 0.0.3 后仍提示「运行版本不匹配…请重新
/// 安装」，用户会误以为连接建立后立刻断开、必须重装。
///
/// 这里的口径：
/// * 服务器名不是 `pi-adaptor` → 不兼容（旧版 pi-host 之类）。
/// * 服务器版本无法解析 → 不兼容（不能静默放过未知值）。
/// * 服务器版本 **低于** App 内置的 PI-adaptor 版本 → 不兼容（缺少本版客户端依赖的能力）。
/// * 相同或 **更高** → 兼容：协议向后兼容，不要求用户重装旧包。
public enum AdaptorRuntimeVersionPolicy {
    /// App 内置（当前包会安装）的 PI-adaptor 版本，作为兼容性下限。
    public static var bundledVersion: String { PIAdaptorRelease.releaseVersion }

    public static func isCompatible(
        serverName: String,
        serverVersion: String,
        bundledVersion: String = AdaptorRuntimeVersionPolicy.bundledVersion
    ) -> Bool {
        guard serverName == PIAdaptorRelease.runtimeServerName else { return false }
        guard let actual = SemverParts(serverVersion),
              let minimum = SemverParts(bundledVersion) else {
            return false
        }
        return actual >= minimum
    }

    /// 设置页错误文案；只在 `isCompatible == false` 且连接在线时展示。
    public static func mismatchMessage(
        serverName: String,
        serverVersion: String,
        bundledVersion: String = AdaptorRuntimeVersionPolicy.bundledVersion
    ) -> String {
        "运行版本不匹配：期望 \(PIAdaptorRelease.runtimeServerName) \(bundledVersion)，"
            + "实际 \(serverName) \(serverVersion)。请重新安装 PI-adaptor。"
    }
}

/// 只解析 `major[.minor[.patch]]` 的数字段；无法解析时返回 nil，绝不把未知值当成兼容。
struct SemverParts: Comparable, Equatable, Sendable {
    private let parts: [Int]

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        // 只取开头的数字/点前缀：`0.0.3-beta` → `0.0.3`；`fixture-only` → 空 → nil。
        let numeric = text.prefix { $0.isNumber || $0 == "." }
        guard !numeric.isEmpty else { return nil }
        var parsed: [Int] = []
        for component in numeric.split(separator: ".", omittingEmptySubsequences: false) {
            guard !component.isEmpty, let value = Int(component) else { return nil }
            parsed.append(value)
        }
        guard !parsed.isEmpty else { return nil }
        // 去掉末尾的 0，让 1.2 与 1.2.0 等价。
        while parsed.count > 1, parsed.last == 0 { parsed.removeLast() }
        self.parts = parsed
    }

    static func < (lhs: SemverParts, rhs: SemverParts) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
