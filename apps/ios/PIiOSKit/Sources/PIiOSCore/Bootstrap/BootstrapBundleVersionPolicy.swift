import Foundation

/// 本机 App 版本与内置 PI-adaptor 回退版本的一致性检查。
///
/// 发布门禁（`scripts/check-host-release-consistency.py` 与
/// `AdaptorReleaseManifestTests`）要求「App MARKETING_VERSION == `host-release.json`
/// == `BootstrapRelease`」。这条不变量在运行时再兜一层：一旦 App 构建与内置
/// 发布坐标漂移（例如只升了 App 版本却还 pin 着上一版 PI-adaptor），安装页必须
/// 明确告诉用户「解析不到 GitHub 最新发布时，本次安装会装成内置的旧版本」，
/// 而不是静默装完旧版本、让用户以为升级了。
public enum BootstrapBundleVersionPolicy {
    /// 返回需要展示的提示；版本一致、App 版本缺失或无法解析时返回 `nil`。
    public static func fallbackWarning(
        appVersion: String?,
        bundledReleaseVersion: String
    ) -> String? {
        guard let rawAppVersion = appVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAppVersion.isEmpty,
              let appVersion = PIAdaptorRelease.canonicalVersion(rawAppVersion) else {
            return nil
        }
        guard appVersion != bundledReleaseVersion else { return nil }
        return "App \(appVersion) · 内置 \(bundledReleaseVersion)。"
            + "解析不到最新发布时会安装内置版本；请换配套构建。"
    }
}
