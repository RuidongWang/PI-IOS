import Foundation
import PIiOSCore

// MARK: - HTTP 边界

/// 解析发布所需的最小 HTTP 能力。测试注入桩实现，生产用 `URLSessionAdaptorReleaseHTTP`。
public protocol AdaptorReleaseHTTP: Sendable {
    /// 返回响应体与状态码。网络错误、超时等以 `AdaptorReleaseHTTPError` 抛出。
    func data(for url: URL) async throws -> (Data, Int)
}

public enum AdaptorReleaseHTTPError: Error, Equatable, Sendable {
    case timedOut
    case cancelled
    case network
    case invalidResponse
}

/// 只读 GitHub 发布列表与校验文件的短连接会话。
public struct URLSessionAdaptorReleaseHTTP: AdaptorReleaseHTTP {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
    }

    public func data(for url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // 不发送 Authorization：App 不内置任何 GitHub 令牌。
        request.setValue("PI-IOS", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AdaptorReleaseHTTPError.invalidResponse
            }
            return (data, http.statusCode)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw AdaptorReleaseHTTPError.timedOut
            case .cancelled: throw AdaptorReleaseHTTPError.cancelled
            default: throw AdaptorReleaseHTTPError.network
            }
        }
    }
}

// MARK: - 解析结果

public enum AdaptorReleaseResolutionSource: Equatable, Sendable {
    /// GitHub 上的最新稳定发布。
    case latest
    /// 内置版本；附带固定短语说明原因，可直接展示给用户。
    case fallback(reason: String)

    public var isFallback: Bool {
        if case .fallback = self { return true }
        return false
    }

    public var fallbackReason: String? {
        if case let .fallback(reason) = self { return reason }
        return nil
    }

    /// 一句话来源描述，供界面直接展示。
    public var displayName: String {
        switch self {
        case .latest:
            return "GitHub 最新稳定发布"
        case let .fallback(reason):
            return "内置回退版本（\(reason)）"
        }
    }
}

public struct AdaptorReleaseResolution: Equatable, Sendable {
    public let release: PIAdaptorRelease
    public let source: AdaptorReleaseResolutionSource

    public init(release: PIAdaptorRelease, source: AdaptorReleaseResolutionSource) {
        self.release = release
        self.source = source
    }

    public var usedFallback: Bool {
        if case .fallback = source { return true }
        return false
    }

    public var fallbackReason: String? {
        if case let .fallback(reason) = source { return reason }
        return nil
    }
}

/// 供 `ConnectionModel` 注入的解析能力。
public protocol AdaptorReleaseResolving: Sendable {
    func resolve(
        target: BootstrapArtifactTarget,
        fallbackBaseURL: String
    ) async -> AdaptorReleaseResolution?
}

// MARK: - 发布目录

/// 解析「当前最新稳定版 PI-adaptor」。
///
/// 数据来源都是公开 GET：
/// 1. `https://api.github.com/repos/<repo>/releases?per_page=20`
/// 2. 仅当发布列表没给出资产 `digest` 时，读取选中发布里的 `<artifact>.sha256`
///
/// 任何一步失败都回退到内置发布并附固定原因，绝不把远端文本拼进提示，
/// 也绝不因为解析失败而阻止安装。
public actor AdaptorReleaseCatalog: AdaptorReleaseResolving {
    public static let defaultRepository = PIAdaptorRelease.releaseRepository
    public static let releasesPageSize = 20
    public static let listCacheLifetime: TimeInterval = 600
    public static let maximumListBytes = 512 * 1_024
    public static let maximumChecksumBytes = 4 * 1_024

    private struct ListCacheEntry {
        let data: Data
        let storedAt: Date
    }

    private let http: any AdaptorReleaseHTTP
    private let repository: String
    private let listCacheLifetime: TimeInterval
    private let now: @Sendable () -> Date

    private var listCache: [String: ListCacheEntry] = [:]

    private enum HTTPStatusError: Error {
        case status(Int)
    }

    public init(
        http: any AdaptorReleaseHTTP = URLSessionAdaptorReleaseHTTP(),
        repository: String = AdaptorReleaseCatalog.defaultRepository,
        listCacheLifetime: TimeInterval = AdaptorReleaseCatalog.listCacheLifetime,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.repository = repository
        self.listCacheLifetime = listCacheLifetime
        self.now = now
    }

    public func resolve(
        target: BootstrapArtifactTarget,
        fallbackBaseURL: String = PIAdaptorRelease.defaultPatchedBaseURL
    ) async -> AdaptorReleaseResolution? {
        do {
            return try await resolveLatest(target: target, fallbackBaseURL: fallbackBaseURL)
        } catch let HTTPStatusError.status(code) {
            return fallback(target: target, baseURL: fallbackBaseURL, reason: Self.statusReason(code))
        } catch {
            return fallback(
                target: target,
                baseURL: fallbackBaseURL,
                reason: Self.reason(for: error)
            )
        }
    }

    // MARK: 主流程

    private func resolveLatest(
        target: BootstrapArtifactTarget,
        fallbackBaseURL: String
    ) async throws -> AdaptorReleaseResolution? {
        let listData = try await releasesList()
        guard let candidate = AdaptorReleaseSelection.latest(
            from: listData,
            target: target,
            repository: repository
        ) else {
            return fallback(
                target: target,
                baseURL: fallbackBaseURL,
                reason: Self.noCandidateReason(in: listData, target: target, repository: repository)
            )
        }

        // GitHub API 已给出资产摘要时直接使用，少一次 github.com 请求；
        // 旧接口或 GitHub Enterprise 没有该字段时再读取 adjacent `.sha256`。
        let digest: String
        if let pinned = candidate.pinnedChecksum {
            digest = pinned
        } else {
            guard let checksumURL = URL(string: candidate.checksumURL) else {
                return fallback(target: target, baseURL: fallbackBaseURL, reason: "校验摘要无效")
            }
            let (checksumData, status) = try await http.data(for: checksumURL)
            guard status == 200 else {
                return fallback(
                    target: target,
                    baseURL: fallbackBaseURL,
                    reason: Self.statusReason(status)
                )
            }
            guard checksumData.count <= Self.maximumChecksumBytes else {
                return fallback(target: target, baseURL: fallbackBaseURL, reason: "校验摘要无效")
            }
            let text = String(decoding: checksumData, as: UTF8.self)
            guard let parsed = PIAdaptorRelease.parseChecksumFile(text, artifactName: candidate.artifactName) else {
                return fallback(target: target, baseURL: fallbackBaseURL, reason: "校验摘要无效")
            }
            digest = parsed
        }

        guard let release = PIAdaptorRelease(
            version: candidate.version,
            target: target,
            baseURL: candidate.baseURL,
            pinnedChecksum: digest
        ) else {
            return fallback(target: target, baseURL: fallbackBaseURL, reason: "校验摘要无效")
        }
        return AdaptorReleaseResolution(release: release, source: .latest)
    }

    private func releasesList() async throws -> Data {
        if let cached = listCache[repository],
           now().timeIntervalSince(cached.storedAt) < listCacheLifetime {
            return cached.data
        }

        guard let url = URL(
            string: "https://api.github.com/repos/\(repository)/releases?per_page=\(Self.releasesPageSize)"
        ) else {
            throw AdaptorReleaseHTTPError.invalidResponse
        }
        let (data, status) = try await http.data(for: url)
        guard status == 200 else {
            throw HTTPStatusError.status(status)
        }
        guard data.count <= Self.maximumListBytes else {
            throw AdaptorReleaseHTTPError.invalidResponse
        }
        listCache[repository] = ListCacheEntry(data: data, storedAt: now())
        return data
    }

    // MARK: 回退

    private func fallback(
        target: BootstrapArtifactTarget,
        baseURL: String,
        reason: String
    ) -> AdaptorReleaseResolution? {
        guard let release = PIAdaptorRelease.patched(target: target, baseURL: baseURL) else {
            return nil
        }
        return AdaptorReleaseResolution(release: release, source: .fallback(reason: reason))
    }

    // MARK: 固定原因文案

    private static func reason(for error: Error) -> String {
        guard let error = error as? AdaptorReleaseHTTPError else {
            return "无法连接 GitHub"
        }
        switch error {
        case .timedOut:
            return "查询 GitHub 超时"
        case .cancelled:
            return "已取消查询 GitHub"
        case .network:
            return "无法连接 GitHub"
        case .invalidResponse:
            return "GitHub 返回的信息无法识别"
        }
    }

    private static func statusReason(_ status: Int) -> String {
        switch status {
        case 403, 429:
            return "GitHub 请求次数受限"
        default:
            return "GitHub 返回状态 \(status)"
        }
    }

    /// 列表能解析但没有可用发布时，尽量给出更具体的原因。
    private static func noCandidateReason(
        in data: Data,
        target: BootstrapArtifactTarget,
        repository: String
    ) -> String {
        guard let entries = try? JSONDecoder().decode([GitHubReleaseListEntry].self, from: data) else {
            return "GitHub 返回的信息无法识别"
        }
        var sawStableTag = false
        var sawArtifact = false
        for entry in entries where !entry.draft && !entry.prerelease {
            guard entry.tagName.hasPrefix(AdaptorReleaseSelection.tagPrefix) else { continue }
            let rawVersion = String(entry.tagName.dropFirst(AdaptorReleaseSelection.tagPrefix.count))
            guard AdaptorReleaseSelection.isStableVersion(rawVersion) else { continue }
            sawStableTag = true
            guard let release = PIAdaptorRelease(
                version: rawVersion,
                target: target,
                repository: repository
            ) else { continue }
            let assetNames = Set(entry.assets.map(\.name))
            if assetNames.contains(release.artifactName) {
                sawArtifact = true
            }
        }
        if sawArtifact {
            return "发布缺少校验文件"
        }
        if sawStableTag {
            return "发布缺少目标架构的安装包"
        }
        return "没有找到可用的稳定发布"
    }
}
