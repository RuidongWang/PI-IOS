import Foundation

/// 「全局 Skill」安装请求的**不可变快照**。
///
/// 为什么要有这个类型：安装是一次跨网络等待，而来源表单在等待期间仍然可编辑。
/// 旧实现 `await` 之后又去读 `sourceValue` / `subdir` / `ref` / `replace`，
/// 于是「提交时填的来源」和「回执后清空/重试的来源」可能不是同一份。
/// 这里在点击时冻结一次，后续所有判断（发送载荷、是否清空、重试）只看它。
public struct SkillInstallRequest: Equatable, Sendable {
    /// 与 PI-adaptor `skill/install` 的 `source.type` 对齐。
    public static let gitSourceType = "git"
    public static let directorySourceType = "directory"

    public var sourceType: String
    public var location: String
    public var subdir: String
    public var reference: String
    public var replace: Bool

    public init(
        sourceType: String,
        location: String,
        subdir: String = "",
        reference: String = "",
        replace: Bool = false
    ) {
        self.sourceType = sourceType
        // 只裁剪来源与可选字段两端的空白：纯空白等同于没填，不能当成有效来源。
        self.location = Self.trimmed(location)
        self.subdir = Self.trimmed(subdir)
        self.reference = Self.trimmed(reference)
        self.replace = replace
    }

    /// 来源是否足够发起安装（只做「非空」这一条前端能确定的判断）。
    public var isValid: Bool { !location.isEmpty }

    public var isGit: Bool { sourceType == Self.gitSourceType }

    /// 与 PI-adaptor 的 `source` 载荷一致：`git` 用 `url`，目录用 `path`；
    /// `subdir` / `ref` 只在非空时出现（空字符串不能当成「指定了空子目录」）。
    public func sourcePayload() -> JSONValue {
        var payload: [String: JSONValue] = ["type": .string(sourceType)]
        if isGit {
            payload["url"] = .string(location)
            if !reference.isEmpty { payload["ref"] = .string(reference) }
        } else {
            payload["path"] = .string(location)
        }
        if !subdir.isEmpty { payload["subdir"] = .string(subdir) }
        return .object(payload)
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 全局 Skill 安装的阶段。
///
/// 阶段存在的目的：让「未受理 / 正在安装 / 已安装但列表没刷新 / 安装失败」这四种
/// 用户可见状态互不混淆，并让按钮在等待期间既禁用又说明原因（U08）。
public enum SkillInstallPhase: Equatable, Sendable {
    /// 没有进行中的安装，也没有待处理结果。
    case idle
    /// 安装请求已发出，等待 PI-adaptor 回执。持有冻结的请求快照。
    case installing(SkillInstallRequest)
    /// 安装已成功，正在刷新已安装列表（此时仍不允许再次提交）。
    case refreshingList
    /// 安装已成功，但列表刷新失败：本机列表可能过期，**不要**提示重新安装。
    case installedListStale(message: String)
    /// 安装失败：保留来源输入，允许用同一份来源重试。
    case failed(message: String)

    /// 正在等待网络结果（安装或安装后的列表刷新）。
    public var isSubmitting: Bool {
        switch self {
        case .installing, .refreshingList:
            return true
        case .idle, .installedListStale, .failed:
            return false
        }
    }

    /// 已确认安装成功但列表尚未刷新成功。
    public var isInstalledPendingListRefresh: Bool {
        if case .installedListStale = self { return true }
        return false
    }

    /// 本次安装冻结下来的请求快照（只在 `installing` 阶段有值）。
    public var request: SkillInstallRequest? {
        if case let .installing(request) = self { return request }
        return nil
    }

    /// 需要就近展示的说明；`nil` 表示无需额外解释。
    public var statusMessage: String? {
        switch self {
        case .idle, .installing, .refreshingList:
            return nil
        case let .installedListStale(message), let .failed(message):
            return message
        }
    }

    /// 安装按钮的标题：等待期间必须体现当前阶段，不能停留在「安装 Skill」。
    public var buttonTitle: String {
        switch self {
        case .idle:
            return "安装 Skill"
        case .installing:
            return "正在安装…"
        case .refreshingList:
            return "正在刷新列表…"
        case .failed:
            return "重试安装"
        case .installedListStale:
            // 安装已经成功，这里再点只会再装一次同样的来源：标题必须中性，
            // 「列表未更新」的下一步由横幅里的「重新读取列表」承担。
            return "安装 Skill"
        }
    }
}

/// 安装阶段状态机：只做状态迁移与「这次点击是否受理」的判断，不持有网络或 UI。
///
/// 使用约定（Screen 侧）：
/// 1. 点击时先构造 `SkillInstallRequest` 快照，再 `begin(request)`；
/// 2. 回执成功 → `installSucceeded()`，随后刷新列表：成功 `listRefreshSucceeded()`（返回 true 才清空来源），
///    失败 `listRefreshFailed(_:)`；
/// 3. 回执失败 → `installFailed(_:)`，来源保留，允许重试。
public struct SkillInstallMachine: Equatable, Sendable {
    public private(set) var phase: SkillInstallPhase

    public init(phase: SkillInstallPhase = .idle) {
        self.phase = phase
    }

    /// 是否允许开始新的安装（安装中与安装后刷新列表期间都不允许）。
    public var canStartNewInstall: Bool { !phase.isSubmitting }

    /// 受理一次安装请求。
    ///
    /// 返回 `false` 表示这次点击被忽略：要么来源无效，要么已有安装/刷新在途。
    /// 这样即使界面因为一次渲染延迟还允许点击，也不会发出第二个请求。
    @discardableResult
    public mutating func begin(_ request: SkillInstallRequest) -> Bool {
        guard request.isValid, canStartNewInstall else { return false }
        phase = .installing(request)
        return true
    }

    /// 安装回执成功，进入列表刷新阶段。
    public mutating func installSucceeded() {
        guard case .installing = phase else { return }
        phase = .refreshingList
    }

    /// 安装回执失败（网络、服务端拒绝、来源不可用等）：保留来源，允许用同一份来源重试。
    public mutating func installFailed(_ message: String) {
        guard case .installing = phase else { return }
        phase = .failed(message: message)
    }

    /// 列表刷新成功。返回 `true` 表示「安装成功且列表已是最新」，调用方可以清空来源输入。
    @discardableResult
    public mutating func listRefreshSucceeded() -> Bool {
        guard phase == .refreshingList || phase.isInstalledPendingListRefresh else { return false }
        phase = .idle
        return true
    }

    /// 安装成功之后的列表刷新失败：这是**部分成功**，不能报成安装失败，也不能提示再装一次。
    public mutating func listRefreshFailed(_ message: String) {
        guard phase == .refreshingList else { return }
        phase = .installedListStale(message: message)
    }

    /// 用户主动关掉「列表未更新」提示（不代表列表已刷新）。
    public mutating func dismissStaleNotice() {
        guard phase.isInstalledPendingListRefresh else { return }
        phase = .idle
    }
}
