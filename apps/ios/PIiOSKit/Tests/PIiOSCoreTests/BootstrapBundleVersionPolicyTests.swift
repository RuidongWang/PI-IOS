import XCTest

@testable import PIiOSCore

final class BootstrapBundleVersionPolicyTests: XCTestCase {
    func testNoWarningWhenAppVersionMatchesBundledRelease() {
        XCTAssertNil(
            BootstrapBundleVersionPolicy.fallbackWarning(
                appVersion: "0.0.3",
                bundledReleaseVersion: "0.0.3"
            )
        )
        XCTAssertNil(
            BootstrapBundleVersionPolicy.fallbackWarning(
                appVersion: "v0.0.3",
                bundledReleaseVersion: "0.0.3"
            ),
            "App 版本允许一个 v 前缀"
        )
    }

    func testWarningWhenBundledReleaseLagsAppVersion() throws {
        let warning = try XCTUnwrap(
            BootstrapBundleVersionPolicy.fallbackWarning(
                appVersion: "0.0.3",
                bundledReleaseVersion: "0.0.2"
            )
        )
        XCTAssertTrue(warning.contains("0.0.3"), warning)
        XCTAssertTrue(warning.contains("0.0.2"), warning)
        XCTAssertTrue(warning.contains("内置"), warning)
    }

    func testNoWarningWithoutUsableAppVersion() {
        XCTAssertNil(
            BootstrapBundleVersionPolicy.fallbackWarning(
                appVersion: nil,
                bundledReleaseVersion: "0.0.3"
            )
        )
        XCTAssertNil(
            BootstrapBundleVersionPolicy.fallbackWarning(
                appVersion: "  ",
                bundledReleaseVersion: "0.0.3"
            )
        )
        XCTAssertNil(
            BootstrapBundleVersionPolicy.fallbackWarning(
                appVersion: "0.0.3 beta",
                bundledReleaseVersion: "0.0.2"
            ),
            "无法安全解析的版本不展示提示"
        )
    }
}
