import XCTest

@testable import PIiOSCore

final class GitHubReleaseListTests: XCTestCase {
    // MARK: - 选中最新稳定发布

    func testSelectsNewestStableReleaseForTargetArchitecture() throws {
        let candidate = try XCTUnwrap(
            HostReleaseSelection.latest(from: Data(Self.json.utf8), target: .linuxArm64)
        )
        XCTAssertEqual(candidate.version, "1.4.2")
        XCTAssertEqual(candidate.releaseTag, "pi-adaptor-v1.4.2")
        XCTAssertEqual(candidate.artifactName, "pi-adaptor-1.4.2-linux-arm64.tar.gz")
        XCTAssertEqual(
            candidate.baseURL,
            "https://github.com/RuidongWang/PI-adaptor/releases/download/pi-adaptor-v1.4.2"
        )
        XCTAssertEqual(
            candidate.checksumURL,
            "https://github.com/RuidongWang/PI-adaptor/releases/download/pi-adaptor-v1.4.2/pi-adaptor-1.4.2-linux-arm64.tar.gz.sha256"
        )

        let x64 = try XCTUnwrap(
            HostReleaseSelection.latest(from: Data(Self.json.utf8), target: .linuxX64)
        )
        XCTAssertEqual(x64.version, "1.4.2")
        XCTAssertEqual(x64.artifactName, "pi-adaptor-1.4.2-linux-x64.tar.gz")
    }

    func testRepositoryAppearsInDownloadURLs() throws {
        let candidate = try XCTUnwrap(
            HostReleaseSelection.latest(
                from: Data(Self.json.utf8),
                target: .linuxX64,
                repository: "Example/Other"
            )
        )
        XCTAssertEqual(
            candidate.baseURL,
            "https://github.com/Example/Other/releases/download/pi-adaptor-v1.4.2"
        )
    }

    // MARK: - 跳过不稳定与非 Host 发布

    func testSkipsDraftPrereleaseAndForeignTags() {
        let entries = [
            Self.entry(tag: "pi-adaptor-v9.9.9", assets: ["pi-adaptor-9.9.9-linux-arm64.tar.gz"], draft: true),
            Self.entry(tag: "pi-adaptor-v8.8.8", assets: ["pi-adaptor-8.8.8-linux-arm64.tar.gz"], prerelease: true),
            Self.entry(tag: "ios-v7.7.7", assets: ["ios-7.7.7.zip"]),
            Self.entry(tag: "pi-adaptor-v6.6.6-beta.1", assets: ["pi-adaptor-6.6.6-beta.1-linux-arm64.tar.gz"]),
            Self.entry(tag: "pi-adaptor-v5.5.5+build", assets: ["pi-adaptor-5.5.5+build-linux-arm64.tar.gz"]),
        ]
        XCTAssertNil(HostReleaseSelection.latest(from: entries, target: .linuxArm64))
    }

    func testSkipsReleaseMissingTargetArtifactOrChecksum() {
        let entries = [
            Self.entry(
                tag: "pi-adaptor-v3.0.0",
                assets: ["pi-adaptor-3.0.0-linux-arm64.tar.gz"] // 缺 .sha256
            ),
            Self.entry(
                tag: "pi-adaptor-v2.0.0",
                assets: ["pi-adaptor-2.0.0-linux-x64.tar.gz", "pi-adaptor-2.0.0-linux-x64.tar.gz.sha256"]
            ),
        ]
        XCTAssertNil(HostReleaseSelection.latest(from: entries, target: .linuxArm64))
        XCTAssertEqual(
            HostReleaseSelection.latest(from: entries, target: .linuxX64)?.version,
            "2.0.0",
            "缺 .sha256 的发布要跳过，继续找可用的旧发布"
        )
    }

    func testUsesOlderReleaseWhenNewestLacksTheArchitecture() throws {
        let entries = [
            Self.entry(tag: "pi-adaptor-v2.0.0", assets: ["pi-adaptor-2.0.0-linux-x64.tar.gz", "pi-adaptor-2.0.0-linux-x64.tar.gz.sha256"]),
            Self.entry(
                tag: "pi-adaptor-v1.9.0",
                assets: [
                    "pi-adaptor-1.9.0-linux-arm64.tar.gz",
                    "pi-adaptor-1.9.0-linux-arm64.tar.gz.sha256",
                    "pi-adaptor-1.9.0-linux-x64.tar.gz",
                    "pi-adaptor-1.9.0-linux-x64.tar.gz.sha256",
                ]
            ),
        ]
        XCTAssertEqual(HostReleaseSelection.latest(from: entries, target: .linuxArm64)?.version, "1.9.0")
        XCTAssertEqual(HostReleaseSelection.latest(from: entries, target: .linuxX64)?.version, "2.0.0")
    }

    // MARK: - 解析容错

    func testMalformedPayloadReturnsNil() {
        XCTAssertNil(HostReleaseSelection.latest(from: Data("not json".utf8), target: .linuxArm64))
        XCTAssertNil(HostReleaseSelection.latest(from: Data("{}".utf8), target: .linuxArm64))
        XCTAssertNil(HostReleaseSelection.latest(from: Data("[]".utf8), target: .linuxArm64))
    }

    func testUnknownFieldsAreIgnored() throws {
        let json = """
        [{
          "id": 49,
          "tag_name": "pi-adaptor-v1.0.0",
          "name": "PI-adaptor 1.0.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"id": 1, "name": "pi-adaptor-1.0.0-linux-arm64.tar.gz", "size": 1024},
            {"id": 2, "name": "pi-adaptor-1.0.0-linux-arm64.tar.gz.sha256", "size": 64}
          ]
        }]
        """
        let candidate = try XCTUnwrap(
            HostReleaseSelection.latest(from: Data(json.utf8), target: .linuxArm64)
        )
        XCTAssertEqual(candidate.version, "1.0.0")
    }

    // MARK: - 资产摘要

    func testCandidateCarriesAPIAssetDigest() throws {
        let digest = String(repeating: "ab", count: 32)
        let json = """
        [{
          "tag_name": "pi-adaptor-v1.0.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"name": "pi-adaptor-1.0.0-linux-arm64.tar.gz", "digest": "sha256:\(digest.uppercased())"},
            {"name": "pi-adaptor-1.0.0-linux-arm64.tar.gz.sha256", "digest": null}
          ]
        }]
        """
        let candidate = try XCTUnwrap(
            HostReleaseSelection.latest(from: Data(json.utf8), target: .linuxArm64)
        )
        XCTAssertEqual(candidate.pinnedChecksum, digest, "应规范化成裸小写摘要")
    }

    func testInvalidAPIAssetDigestIsIgnored() throws {
        for digest in ["md5:abcd", "sha256:not-hex", "sha256:", "sha256:\(String(repeating: "a", count: 63))"] {
            let json = """
            [{
              "tag_name": "pi-adaptor-v1.0.0",
              "draft": false,
              "prerelease": false,
              "assets": [
                {"name": "pi-adaptor-1.0.0-linux-arm64.tar.gz", "digest": "\(digest)"},
                {"name": "pi-adaptor-1.0.0-linux-arm64.tar.gz.sha256"}
              ]
            }]
            """
            let candidate = try XCTUnwrap(
                HostReleaseSelection.latest(from: Data(json.utf8), target: .linuxArm64)
            )
            XCTAssertNil(candidate.pinnedChecksum, digest)
        }
    }

    // MARK: - 稳定版本形态

    func testStableVersionRequiresNumericDotComponents() {
        for value in ["1", "1.2", "1.2.3", "10.20.30"] {
            XCTAssertTrue(HostReleaseSelection.isStableVersion(value), value)
        }
        for value in ["", ".", ".1", "1.", "1..2", "1.2.3-beta.1", "1.2.3+build", "v1.2.3", "1.2.3/evil", "１.２"] {
            XCTAssertFalse(HostReleaseSelection.isStableVersion(value), value)
        }
    }

    // MARK: - 工具

    private static func entry(
        tag: String,
        assets: [String],
        draft: Bool = false,
        prerelease: Bool = false
    ) -> GitHubReleaseListEntry {
        GitHubReleaseListEntry(
            tagName: tag,
            draft: draft,
            prerelease: prerelease,
            assets: assets.map { GitHubReleaseListEntry.Asset(name: $0) }
        )
    }

    private static let json = """
    [
      {
        "tag_name": "ios-v9.9.9",
        "draft": false,
        "prerelease": false,
        "assets": [{"name": "PI-IOS-9.9.9.zip"}]
      },
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
      },
      {
        "tag_name": "pi-adaptor-v1.3.0",
        "draft": false,
        "prerelease": false,
        "assets": [
          {"name": "pi-adaptor-1.3.0-linux-arm64.tar.gz"},
          {"name": "pi-adaptor-1.3.0-linux-arm64.tar.gz.sha256"}
        ]
      }
    ]
    """
}
