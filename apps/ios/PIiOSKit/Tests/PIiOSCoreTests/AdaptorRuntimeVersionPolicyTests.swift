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

    func testNewerRuntimeIsCompatibleAndDoesNotAskForReinstall() {
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "0.0.4"
        ))
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "0.1.0"
        ))
        XCTAssertTrue(AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: "pi-adaptor",
            serverVersion: "1.0.0"
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
