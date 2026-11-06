import Foundation
import XCTest
@testable import PIiOSCore

final class ProviderSaveIntentTests: XCTestCase {
    private let hostID = UUID(uuidString: "6f1c2a3e-4b5d-4c7e-8f90-a1b2c3d4e5f6")!

    private func model(_ id: String = "alpha") -> ProviderModelSpec {
        ProviderModelSpec(id: id, contextWindow: 128_000, maxTokens: 16_384, thinkingLevels: [])
    }

    private func intent(
        kind: ProviderSaveIntent.Kind = .update(providerId: "provider-1"),
        apiKey: String?,
        apiKeyDraft: String? = nil,
        models: [ProviderModelSpec]? = nil
    ) -> ProviderSaveIntent {
        ProviderSaveIntent(
            kind: kind,
            hostID: hostID,
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            models: models ?? [model()],
            apiKey: apiKey,
            apiKeyDraft: apiKeyDraft,
            defaultModelID: "alpha"
        )
    }

    // MARK: - nil / 空 / 纯空白 = 不改密钥

    func testNilEmptyAndWhitespaceMeanUnchanged() {
        for input in [nil, "", "   ", "\n\t"] as [String?] {
            XCTAssertEqual(
                ProviderAPIKeyChange(input: input),
                .unchanged,
                "「\(input ?? "nil")」必须表示不改密钥"
            )
            XCTAssertNil(intent(apiKey: input).requestAPIKey)
            XCTAssertNil(intent(apiKey: input).keychainAPIKey)
        }
    }

    func testReplacementIsTrimmedOnce() {
        XCTAssertEqual(
            ProviderAPIKeyChange(input: "  sk-live-123  "),
            .replace("sk-live-123")
        )
        // 内部换行属于控制字符，不能被静默当成合法密钥的一部分吞掉/接受。
        XCTAssertEqual(
            ProviderAPIKeyChange(input: "sk-li\nve"),
            .replace("sk-li\nve")
        )
    }

    // MARK: - 请求值与 Keychain 值严格同源

    func testRequestAndKeychainUseTheSameFrozenValue() {
        let intent = self.intent(apiKey: " sk-live-123 ")
        XCTAssertEqual(intent.requestAPIKey, "sk-live-123")
        XCTAssertEqual(intent.keychainAPIKey, intent.requestAPIKey)
        XCTAssertEqual(intent.updateInput().apiKey, intent.requestAPIKey)
    }

    func testUpdateInputOnlyCarriesFrozenValues() {
        let intent = self.intent(apiKey: "sk-live-A")
        let input = intent.updateInput()
        XCTAssertEqual(input.name, "DeepSeek")
        XCTAssertEqual(input.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(input.apiKey, "sk-live-A")
        XCTAssertEqual(input.models.map(\.id), ["alpha"])
        XCTAssertEqual(input.defaultModelID, "alpha")
    }

    func testIntentIsValueSnapshotAndSurvivesLaterDraftEdits() {
        var models = [model("alpha")]
        let intent = self.intent(apiKey: "sk-live-A", models: models)
        // 模拟保存期间界面继续编辑：改的是新的数组/字符串，不应影响已冻结的意图。
        models[0].id = "beta"
        let laterDraft = "sk-live-B"
        XCTAssertEqual(intent.models.map(\.id), ["alpha"])
        XCTAssertEqual(intent.requestAPIKey, "sk-live-A")
        XCTAssertEqual(intent.keychainAPIKey, "sk-live-A")
        XCTAssertNotEqual(intent.requestAPIKey, laterDraft)
    }

    func testDraftComparisonDetectsLaterEdits() {
        let intent = self.intent(apiKey: "A", apiKeyDraft: "A")
        XCTAssertTrue(intent.apiKeyDraftIsUnchanged("A"))
        XCTAssertFalse(intent.apiKeyDraftIsUnchanged("B"))
    }

    // MARK: - 创建/更新差异

    func testCreateRequiresANewKey() {
        XCTAssertEqual(intent(kind: .create, apiKey: "  ").createRejection != nil, true)
        XCTAssertNil(intent(kind: .create, apiKey: "test-key-create").createRejection)
        XCTAssertNil(intent(kind: .create, apiKey: "test-key-create").providerId)
    }

    func testUpdateCarriesProviderIdAndAllowsNoKeyChange() {
        let intent = self.intent(kind: .update(providerId: "provider-9"), apiKey: "")
        XCTAssertEqual(intent.providerId, "provider-9")
        XCTAssertNil(intent.createRejection)
        XCTAssertNil(intent.updateInput().apiKey)
    }
}
