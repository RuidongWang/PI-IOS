import Foundation
import PIiOSCore
import XCTest

@testable import PIiOSNet

final class AdaptorReleaseCatalogTests: XCTestCase {
    private let digest = String(repeating: "0123456789abcdef", count: 4)
    private let listURL = "https://api.github.com/repos/RuidongWang/PI-adaptor/releases?per_page=20"
    private let arm64ChecksumURL =
        "https://github.com/RuidongWang/PI-adaptor/releases/download/pi-adaptor-v1.4.2/pi-adaptor-1.4.2-linux-arm64.tar.gz.sha256"

    // MARK: - 正常解析

    func testResolvesLatestStableReleaseWithPinnedChecksum() async throws {
        let http = StubReleaseHTTP(replies: [
            listURL: .ok(Data(Self.listJSON.utf8), 200),
            arm64ChecksumURL: .ok(Data("\(digest)  pi-adaptor-1.4.2-linux-arm64.tar.gz\n".utf8), 200),
        ])
        let catalog = AdaptorReleaseCatalog(http: http, clientVersion: "1.4.2")

        let resolved = await catalog.resolve(target: .linuxArm64, fallbackBaseURL: "https://example.test/fallback")
        let resolution = try XCTUnwrap(resolved)
        XCTAssertEqual(resolution.source, .latest)
        XCTAssertFalse(resolution.usedFallback)
        XCTAssertNil(resolution.fallbackReason)
        XCTAssertEqual(resolution.release.version, "1.4.2")
        XCTAssertEqual(resolution.release.artifactName, "pi-adaptor-1.4.2-linux-arm64.tar.gz")
        XCTAssertEqual(
            resolution.release.artifactURL,
            "https://github.com/RuidongWang/PI-adaptor/releases/download/pi-adaptor-v1.4.2/pi-adaptor-1.4.2-linux-arm64.tar.gz"
        )
        XCTAssertEqual(resolution.release.pinnedChecksum, digest)
        let requested = await http.requestedURLs.map(\.absoluteString)
        XCTAssertEqual(Set(requested), [listURL, arm64ChecksumURL])
    }

    func testAPIAssetDigestSkipsChecksumDownload() async throws {
        let http = StubReleaseHTTP(replies: [
            listURL: .ok(Data(Self.listJSONWithDigest.utf8), 200),
        ])
        let catalog = AdaptorReleaseCatalog(http: http)

        let resolved = await catalog.resolve(target: .linuxArm64, fallbackBaseURL: "https://example.test/fallback")
        let resolution = try XCTUnwrap(resolved)
        XCTAssertEqual(resolution.source, .latest)
        XCTAssertEqual(resolution.release.version, "1.4.2")
        XCTAssertEqual(resolution.release.pinnedChecksum, digest)
        let requested = await http.requestedURLs.map(\.absoluteString)
        XCTAssertEqual(requested, [listURL], "有 API 摘要时不应再访问 github.com")
    }

    // MARK: - 网络与状态码回退

    func testNetworkFailureFallsBackToCompiledRelease() async throws {
        let http = StubReleaseHTTP(replies: [listURL: .failure(.network)])
        let resolution = try await resolve(http: http)
        try assertFallback(resolution, reason: "无法连接 GitHub")
    }

    func testTimeoutFallsBackWithFixedReason() async throws {
        let http = StubReleaseHTTP(replies: [listURL: .failure(.timedOut)])
        let resolution = try await resolve(http: http)
        try assertFallback(resolution, reason: "查询 GitHub 超时")
    }

    func testNonOKStatusFallsBackWithStatusReason() async throws {
        let http = StubReleaseHTTP(replies: [listURL: .ok(Data(), 500)])
        let resolution = try await resolve(http: http)
        try assertFallback(resolution, reason: "GitHub 返回状态 500")
    }

    func testRateLimitFallsBack() async throws {
        let http = StubReleaseHTTP(replies: [listURL: .ok(Data(), 403)])
        let resolution = try await resolve(http: http)
        try assertFallback(resolution, reason: "GitHub 请求次数受限")
    }

    func testNewerFallbackIsUnavailableToOlderClient() async {
        let http = StubReleaseHTTP(replies: [listURL: .ok(Data(), 403)])
        let catalog = AdaptorReleaseCatalog(http: http, clientVersion: "0.0.5")
        let resolved = await catalog.resolve(target: .linuxArm64)
        XCTAssertNil(resolved)
    }

    func testPublishedClientMinimumAlsoProtectsBundledRelease() async throws {
        let bundled = try XCTUnwrap(PIAdaptorRelease.patched(target: .linuxArm64))
        let json = """
        [{"tag_name":"\(bundled.releaseTag)","draft":false,"prerelease":false,
          "body":"<!-- pi-ios-min-version: 999.0.0 -->",
          "assets":[{"name":"\(bundled.artifactName)"},
                    {"name":"\(bundled.artifactName).sha256"}]}]
        """
        let catalog = AdaptorReleaseCatalog(http: StubReleaseHTTP(replies: [listURL: .ok(Data(json.utf8), 200)]))
        let resolved = await catalog.resolve(target: .linuxArm64)
        XCTAssertNil(resolved)
    }

    func testMalformedRefreshAndRateLimitAfterRestartPreserveBundledMinimum() async throws {
        let bundled = try XCTUnwrap(PIAdaptorRelease.patched(target: .linuxArm64))
        let json = """
        [{"tag_name":"\(bundled.releaseTag)","draft":false,"prerelease":false,
          "body":"<!-- pi-ios-min-version: 999.0.0 -->",
          "assets":[{"name":"\(bundled.artifactName)"},{"name":"\(bundled.artifactName).sha256"}]}]
        """
        let suite = "PIAdaptorReleaseCatalogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = StubReleaseHTTP(sequence: [listURL: [
            .ok(Data(json.utf8), 200),
            .ok(Data("<html>temporary error</html>".utf8), 200),
            .ok(Data(), 403),
        ]])
        let catalog = AdaptorReleaseCatalog(http: http, listCacheLifetime: 0, compatibilityDefaults: defaults)
        let first = await catalog.resolve(target: .linuxArm64)
        XCTAssertNil(first)
        let malformed = await catalog.resolve(target: .linuxArm64)
        XCTAssertNil(malformed)

        let restarted = AdaptorReleaseCatalog(http: http, compatibilityDefaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let limited = await restarted.resolve(target: .linuxX64)
        XCTAssertNil(limited)
    }

    func testSlowOlderRefreshCannotOverwriteTheNewerCompatibilityDecision() async throws {
        let bundled = try XCTUnwrap(PIAdaptorRelease.patched(target: .linuxArm64))
        func list(minimum: String) -> Data {
            Data("""
            [{"tag_name":"\(bundled.releaseTag)","draft":false,"prerelease":false,
              "body":"<!-- pi-ios-min-version: \(minimum) -->",
              "assets":[{"name":"\(bundled.artifactName)","digest":"sha256:\(digest)"},
                        {"name":"\(bundled.artifactName).sha256"}]}]
            """.utf8)
        }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let http = OverlappingReleaseHTTP(newest: list(minimum: "999.0.0"), started: signal)
        let catalog = AdaptorReleaseCatalog(http: http, listCacheLifetime: 0)
        let slow = Task { await catalog.resolve(target: .linuxArm64) }
        var requests = started.makeAsyncIterator()
        _ = await requests.next()

        let newer = await catalog.resolve(target: .linuxArm64)
        XCTAssertNil(newer)
        await http.finishFirstRequest(with: list(minimum: "0.0.6"))
        let stale = await slow.value
        XCTAssertNil(stale)
    }

    func testMalformedListFallsBack() async throws {
        let http = StubReleaseHTTP(replies: [listURL: .ok(Data("<html>rate limited</html>".utf8), 200)])
        let resolution = try await resolve(http: http)
        try assertFallback(resolution, reason: "GitHub 返回的信息无法识别")
    }

    // MARK: - 资产与摘要

    func testMissingStableReleaseFallsBack() async throws {
        let json = """
        [{"tag_name":"ios-v1.0.0","draft":false,"prerelease":false,"assets":[]}]
        """
        let http = StubReleaseHTTP(replies: [listURL: .ok(Data(json.utf8), 200)])
        let resolution = try await resolve(http: http)
        try assertFallback(resolution, reason: "没有找到可用的稳定发布")
    }

    func testMissingArtifactFallsBack() async throws {
        let json = """
        [{"tag_name":"pi-adaptor-v1.4.2","draft":false,"prerelease":false,
          "assets":[{"name":"pi-adaptor-1.4.2-linux-x64.tar.gz"},
                    {"name":"pi-adaptor-1.4.2-linux-x64.tar.gz.sha256"}]}]
        """
        let http = StubReleaseHTTP(replies: [listURL: .ok(Data(json.utf8), 200)])
        let resolution = try await resolve(http: http)
        try assertFallback(resolution, reason: "发布缺少目标架构的安装包")
    }

    func testMissingChecksumAssetFallsBack() async throws {
        let json = """
        [{"tag_name":"pi-adaptor-v1.4.2","draft":false,"prerelease":false,
          "assets":[{"name":"pi-adaptor-1.4.2-linux-arm64.tar.gz"}]}]
        """
        let http = StubReleaseHTTP(replies: [listURL: .ok(Data(json.utf8), 200)])
        let resolution = try await resolve(http: http)
        try assertFallback(resolution, reason: "发布缺少校验文件")
    }

    func testInvalidChecksumResponsesFallBack() async throws {
        let other = String(repeating: "f", count: 64)
        let validLine = "\(digest)  pi-adaptor-1.4.2-linux-arm64.tar.gz\n"
        let padding = AdaptorReleaseCatalog.maximumChecksumBytes + 1 - validLine.utf8.count
        let oversized = validLine + String(repeating: "\n", count: padding)
        let cases: [(name: String, data: Data)] = [
            ("摘要格式错误", Data("not-a-digest  pi-adaptor-1.4.2-linux-arm64.tar.gz\n".utf8)),
            ("摘要对应另一架构", Data("\(other)  pi-adaptor-1.4.2-linux-x64.tar.gz\n".utf8)),
            ("含有效摘要的校验文件超限", Data(oversized.utf8)),
        ]
        for (name, data) in cases {
            let http = StubReleaseHTTP(replies: [
                listURL: .ok(Data(Self.listJSON.utf8), 200),
                arm64ChecksumURL: .ok(data, 200),
            ])
            let resolution = try await resolve(http: http, message: name)
            try assertFallback(resolution, reason: "校验摘要无效", message: name)
        }
    }

    // MARK: - 缓存

    func testReleaseListIsCachedBetweenResolves() async throws {
        let http = StubReleaseHTTP(replies: [
            listURL: .ok(Data(Self.listJSON.utf8), 200),
            arm64ChecksumURL: .ok(Data("\(digest)  pi-adaptor-1.4.2-linux-arm64.tar.gz\n".utf8), 200),
        ])
        let catalog = AdaptorReleaseCatalog(http: http, clientVersion: "1.4.2")

        _ = await catalog.resolve(target: .linuxArm64)
        _ = await catalog.resolve(target: .linuxArm64)

        let requested = await http.requestedURLs.map(\.absoluteString)
        XCTAssertEqual(requested.filter { $0 == listURL }.count, 1, "10 分钟内不应重复请求发布列表")
        XCTAssertEqual(requested.filter { $0 == arm64ChecksumURL }.count, 2)
    }

    // MARK: - 工具

    private func resolve(http: StubReleaseHTTP, message: String = "") async throws -> AdaptorReleaseResolution {
        let catalog = AdaptorReleaseCatalog(http: http, clientVersion: "1.4.2")
        let resolved = await catalog.resolve(target: .linuxArm64, fallbackBaseURL: "https://example.test/fallback")
        return try XCTUnwrap(resolved, message)
    }

    private func assertFallback(
        _ resolution: AdaptorReleaseResolution,
        reason: String,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(resolution.usedFallback, message, file: file, line: line)
        XCTAssertEqual(resolution.source, .fallback(reason: reason), message, file: file, line: line)
        XCTAssertEqual(resolution.release.version, PIAdaptorRelease.releaseVersion, message, file: file, line: line)
        XCTAssertEqual(
            resolution.release.pinnedChecksum,
            PIAdaptorRelease.patchedChecksums[.linuxArm64],
            message,
            file: file,
            line: line
        )
        XCTAssertEqual(
            resolution.release.artifactURL,
            "https://example.test/fallback/pi-adaptor-\(PIAdaptorRelease.releaseVersion)-linux-arm64.tar.gz",
            message,
            file: file,
            line: line
        )
    }

    private static let listJSONWithDigest = """
    [
      {
        "tag_name": "pi-adaptor-v1.4.2",
        "draft": false,
        "prerelease": false,
        "body": "<!-- pi-ios-min-version: \(PIAdaptorRelease.releaseVersion) -->",
        "assets": [
          {"name": "pi-adaptor-1.4.2-linux-arm64.tar.gz",
           "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
          {"name": "pi-adaptor-1.4.2-linux-arm64.tar.gz.sha256"},
          {"name": "pi-adaptor-1.4.2-linux-x64.tar.gz"},
          {"name": "pi-adaptor-1.4.2-linux-x64.tar.gz.sha256"}
        ]
      }
    ]
    """

    private static let listJSON = """
    [
      {
        "tag_name": "pi-adaptor-v1.5.0-rc.1",
        "draft": false,
        "prerelease": true,
        "assets": [
          {"name": "pi-adaptor-1.5.0-rc.1-linux-arm64.tar.gz"},
          {"name": "pi-adaptor-1.5.0-rc.1-linux-arm64.tar.gz.sha256"}
        ]
      },
      {
        "tag_name": "pi-adaptor-v1.4.2",
        "draft": false,
        "prerelease": false,
        "assets": [
          {"name": "pi-adaptor-1.4.2-linux-arm64.tar.gz"},
          {"name": "pi-adaptor-1.4.2-linux-arm64.tar.gz.sha256"},
          {"name": "pi-adaptor-1.4.2-linux-x64.tar.gz"},
          {"name": "pi-adaptor-1.4.2-linux-x64.tar.gz.sha256"}
        ]
      }
    ]
    """
}

// MARK: - 桩

private actor StubReleaseHTTP: AdaptorReleaseHTTP {
    enum Reply {
        case ok(Data, Int)
        case failure(AdaptorReleaseHTTPError)
    }

    private var replies: [String: [Reply]]
    private(set) var requestedURLs: [URL] = []

    init(replies: [String: Reply]) {
        self.replies = replies.mapValues { [$0] }
    }

    init(sequence: [String: [Reply]]) {
        self.replies = sequence
    }

    func data(for url: URL) async throws -> (Data, Int) {
        requestedURLs.append(url)
        let key = url.absoluteString
        guard let reply = replies[key]?.first else {
            throw AdaptorReleaseHTTPError.network
        }
        if (replies[key]?.count ?? 0) > 1 {
            replies[key]?.removeFirst()
        }
        switch reply {
        case let .ok(data, status):
            return (data, status)
        case let .failure(error):
            throw error
        }
    }
}

private actor OverlappingReleaseHTTP: AdaptorReleaseHTTP {
    let newest: Data
    let started: AsyncStream<Void>.Continuation
    private var firstRequest: CheckedContinuation<Data, Never>?

    init(newest: Data, started: AsyncStream<Void>.Continuation) {
        self.newest = newest
        self.started = started
    }

    func data(for url: URL) async throws -> (Data, Int) {
        if firstRequest != nil { return (newest, 200) }
        let reply = await withCheckedContinuation { continuation in
            firstRequest = continuation
            started.yield()
            started.finish()
        }
        return (reply, 200)
    }

    func finishFirstRequest(with data: Data) {
        firstRequest?.resume(returning: data)
        firstRequest = nil
    }
}
