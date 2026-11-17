import XCTest
@testable import PIiOSCore

/// 运行版本兼容性口径：期望值取 App 内置版本，服务器「更新」不要求用户重装。
final class AdaptorRuntimeVersionPolicyTests: XCTestCase {
    private let bundled = PIAdaptorRelease.releaseVersion

    func testSameVersionIsCompatible() {
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: bundled
        ))
    }

    func testTagPrefixAndPrereleaseSuffixAreTolerated() {
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "v\(bundled)"
        ))
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "\(bundled)-beta"
        ))
    }

    /// 「服务器更新不要求重装」：显式钉住内置版本，本用例只验证相对关系，
    /// 不能随包内 PI-adaptor 版本号变化而失效（曾因写死 0.0.4 在升到 0.0.5 后误报）。
    func testNewerRuntimeIsCompatibleAndDoesNotAskForReinstall() {
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "0.0.4",
            bundledVersion: "0.0.3"
        ))
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "0.1.0",
            bundledVersion: "0.0.4"
        ))
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "1.0.0",
            bundledVersion: "0.1.0"
        ))
        // 真实内置版本：同版本必须兼容（不提示重装）。
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: bundled
        ))
    }

    func testOlderRuntimeIsIncompatible() {
        XCTAssertFalse(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "0.0.2"
        ))
    }

    func testUnparseableOrForeignServerIsIncompatible() {
        XCTAssertFalse(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "fixture-only"
        ))
        XCTAssertFalse(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: ""
        ))
        XCTAssertFalse(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-host",
            serverVersion: bundled
        ))
    }

    func testComparisonIsNumericNotLexicographic() {
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "0.0.10",
            bundledVersion: "0.0.9"
        ))
        XCTAssertFalse(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "0.0.9",
            bundledVersion: "0.0.10"
        ))
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "0.0.3",
            bundledVersion: "0.0.3.0"
        ))
    }

    func testMismatchMessageMentionsBundledExpectationAndActualRuntime() {
        let message = AdaptorRuntimeVersionPolicy.mismatchMessage(
            serverName: "pi-adaptor",
            serverVersion: "0.0.2"
        )
        XCTAssertTrue(message.contains("期望 pi-adaptor \(bundled)"))
        XCTAssertTrue(message.contains("实际 pi-adaptor 0.0.2"))
        XCTAssertTrue(message.contains("请重新安装 PI-adaptor"))
    }
}
