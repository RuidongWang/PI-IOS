import Foundation

// MARK: - GitHub 发布列表（只取选择需要的字段）

/// `GET /repos/{owner}/{repo}/releases` 的一个条目。
///
/// 只解码自动匹配需要的字段：标签、是否草稿、是否预发布、资产名。
/// 未识别的字段一律忽略，方便 GitHub 继续扩展响应。
public struct GitHubReleaseListEntry: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        /// GitHub 计算的资产摘要，形如 `sha256:<64 位十六进制>`；旧响应可能没有。
        public let digest: String?

        public init(name: String, digest: String? = nil) {
            self.name = name
            self.digest = digest
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case digest
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            digest = try container.decodeIfPresent(String.self, forKey: .digest)
        }
    }

    public let tagName: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    public init(tagName: String, draft: Bool, prerelease: Bool, assets: [Asset]) {
        self.tagName = tagName
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        draft = try container.decode(Bool.self, forKey: .draft)
        prerelease = try container.decode(Bool.self, forKey: .prerelease)
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }
}

// MARK: - 选中结果

/// 一个可以安装的发布坐标：版本、标签、下载根地址与目标架构的资产名。
public struct AdaptorReleaseCandidate: Equatable, Sendable {
    public let version: String
    public let releaseTag: String
    public let baseURL: String
    public let artifactName: String
    public let checksumURL: String
    /// GitHub API 直接给出的目标资产摘要；缺失或格式不对时为 `nil`，此时需读取 `.sha256`。
    public let pinnedChecksum: String?

    public init(
        version: String,
        releaseTag: String,
        baseURL: String,
        artifactName: String,
        checksumURL: String,
        pinnedChecksum: String? = nil
    ) {
        self.version = version
        self.releaseTag = releaseTag
        self.baseURL = baseURL
        self.artifactName = artifactName
        self.checksumURL = checksumURL
        self.pinnedChecksum = pinnedChecksum
    }
}

// MARK: - 纯选择逻辑

/// 从 GitHub 发布列表里挑选「最新稳定版 PI-adaptor」。
///
/// 规则（顺序即优先级）：
/// 1. 跳过草稿与预发布；
/// 2. 标签必须是 `pi-adaptor-v<数字点分版本>`，iOS App 的发布因此不会被误选；
/// 3. 必须同时存在目标架构的 `.tar.gz` 与 `.sha256` 资产。
///
/// 不满足条件的发布会被跳过，继续看下一个；都不满足时返回 `nil`，由调用方回退内置版本。
public enum AdaptorReleaseSelection {
    public static let tagPrefix = "pi-adaptor-v"

    public static func latest(
        from data: Data,
        target: BootstrapArtifactTarget,
        repository: String = PIAdaptorRelease.releaseRepository
    ) -> AdaptorReleaseCandidate? {
        guard let entries = try? JSONDecoder().decode([GitHubReleaseListEntry].self, from: data) else {
            return nil
        }
        return latest(from: entries, target: target, repository: repository)
    }

    public static func latest(
        from entries: [GitHubReleaseListEntry],
        target: BootstrapArtifactTarget,
        repository: String = PIAdaptorRelease.releaseRepository
    ) -> AdaptorReleaseCandidate? {
        for entry in entries where !entry.draft && !entry.prerelease {
            guard entry.tagName.hasPrefix(tagPrefix) else { continue }
            let rawVersion = String(entry.tagName.dropFirst(tagPrefix.count))
            guard isStableVersion(rawVersion) else { continue }
            guard let release = PIAdaptorRelease(
                version: rawVersion,
                target: target,
                repository: repository
            ) else { continue }

            let assetNames = Set(entry.assets.map(\.name))
            guard assetNames.contains(release.artifactName),
                  assetNames.contains(release.artifactName + ".sha256") else {
                continue
            }

            let baseURL = "https://github.com/\(repository)/releases/download/\(release.releaseTag)"
            return AdaptorReleaseCandidate(
                version: release.version,
                releaseTag: release.releaseTag,
                baseURL: baseURL,
                artifactName: release.artifactName,
                checksumURL: "\(baseURL)/\(release.artifactName).sha256",
                pinnedChecksum: entry.assets
                    .first { $0.name == release.artifactName }
                    .flatMap { sha256Digest(fromAPIDigest: $0.digest) }
            )
        }
        return nil
    }

    /// 把 GitHub API 的 `digest`（`sha256:<hex>`）转成发布脚本使用的裸摘要。
    public static func sha256Digest(fromAPIDigest value: String?) -> String? {
        guard let value,
              value.lowercased().hasPrefix("sha256:") else {
            return nil
        }
        return PIAdaptorRelease.normalizeChecksum(String(value.dropFirst("sha256:".count)))
    }

    /// 只接受数字点分版本（`1`、`1.2`、`1.2.3`）。
    ///
    /// GitHub 的 `prerelease` 标记已经挡掉常规预发布，但被标成正式发布的
    /// `-beta`、`+build` 标签仍会出现在列表里，这里再按版本形态挡一次。
    public static func isStableVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
        }
    }
}
