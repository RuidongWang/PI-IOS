import XCTest

@testable import PIiOSCore

/// 本机默认模型写入规则：显式选择 > 原默认 > 同一 provider 内转移 > 首条导入。
/// 规则与 UI 交互分开测试，避免只能在模拟器 UI 测试里验证。
final class ProviderDefaultModelRecorderTests: XCTestCase {
    func testExplicitSelectionWinsOverPreviousDefault() {
        XCTAssertEqual(
            ProviderDefaultModelRecorder.resolvedDefaultModelID(
                explicit: "second",
                previous: "first",
                models: [spec("first"), spec("second")],
                serverDefaultSet: false,
                isOnlyProviderOnHost: false
            ),
            "second",
            "用户点「设为默认」时必须优先于本机旧默认"
        )
    }

    func testNilExplicitKeepsPreviousDefault() {
        XCTAssertEqual(
            ProviderDefaultModelRecorder.resolvedDefaultModelID(
                explicit: nil,
                previous: "first",
                models: [spec("first"), spec("second")],
                serverDefaultSet: false,
                isOnlyProviderOnHost: false
            ),
            "first",
            "编辑服务信息不能改默认模型"
        )
    }

    func testNilExplicitWithoutPreviousStaysNil() {
        XCTAssertNil(
            ProviderDefaultModelRecorder.resolvedDefaultModelID(
                explicit: nil,
                previous: nil,
                models: [spec("first"), spec("second")],
                serverDefaultSet: true,
                isOnlyProviderOnHost: false
            ),
            "已有其他服务持有默认时，新服务不能凭空成为默认"
        )
    }

    func testRemovedPreviousDefaultTransfersWithinSameProvider() {
        XCTAssertEqual(
            ProviderDefaultModelRecorder.resolvedDefaultModelID(
                explicit: nil,
                previous: "removed",
                models: [spec("remaining-a"), spec("remaining-b")],
                serverDefaultSet: false,
                isOnlyProviderOnHost: false
            ),
            "remaining-a",
            "原本持有默认的 provider 失去该模型后，应在自己剩余模型里转移"
        )
    }

    func testFirstProviderImportUsesServerDefault() {
        XCTAssertEqual(
            ProviderDefaultModelRecorder.resolvedDefaultModelID(
                explicit: nil,
                previous: nil,
                models: [spec("first"), spec("second")],
                serverDefaultSet: true,
                isOnlyProviderOnHost: true
            ),
            "first"
        )
        XCTAssertNil(
            ProviderDefaultModelRecorder.resolvedDefaultModelID(
                explicit: nil,
                previous: nil,
                models: [],
                serverDefaultSet: true,
                isOnlyProviderOnHost: true
            )
        )
    }

    func testInvalidExplicitAndInvalidPreviousFallBackToNilForNonOwner() {
        XCTAssertNil(
            ProviderDefaultModelRecorder.resolvedDefaultModelID(
                explicit: "ghost",
                previous: nil,
                models: [spec("first")],
                serverDefaultSet: false,
                isOnlyProviderOnHost: false
            ),
            "非法 explicit 不能写入本机记录；没有原默认时保持 nil"
        )
    }

    private func spec(_ id: String) -> ProviderModelSpec {
        ProviderModelSpec(
            id: id,
            contextWindow: 128_000,
            maxTokens: 8_192,
            thinkingLevels: []
        )
    }
}
