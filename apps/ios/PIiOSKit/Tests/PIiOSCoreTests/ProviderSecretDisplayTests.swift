import Foundation
import XCTest
@testable import PIiOSCore

final class ProviderSecretDisplayTests: XCTestCase {
    // MARK: - 状态推导

    func testNoAuthProviderDoesNotNeedAKey() {
        let status = ProviderSecretDisplay.status(
            authKind: "none",
            hasApiKey: false,
            apiKeyMask: nil,
            keyStorage: nil,
            hasLocalKey: false
        )
        XCTAssertEqual(status, .notRequired)
        XCTAssertEqual(ProviderSecretDisplay.text(status), "无需密钥")
    }

    func testClientKeyStorageIsLocalOnlyEvenWhenServerSaysHasApiKey() {
        // 服务端新语义：authKind == "api_key" 时 hasApiKey=true、apiKeyMask=null、keyStorage="client"。
        let withKey = ProviderSecretDisplay.status(
            authKind: "api_key",
            hasApiKey: true,
            apiKeyMask: nil,
            keyStorage: "client",
            hasLocalKey: true
        )
        XCTAssertEqual(withKey, .localOnly(hasLocalKey: true))
        XCTAssertEqual(ProviderSecretDisplay.text(withKey), "密钥仅存本机")

        let withoutKey = ProviderSecretDisplay.status(
            authKind: "api_key",
            hasApiKey: true,
            apiKeyMask: nil,
            keyStorage: "client",
            hasLocalKey: false
        )
        XCTAssertEqual(ProviderSecretDisplay.text(withoutKey), "本机缺少密钥")
    }

    func testApiKeyMaskNilIsNeverRenderedAsNoSecret() {
        // 兼容没有 keyStorage 字段的新服务端 / 旧客户端缓存：hasApiKey=true + mask=nil 仍按本机判定。
        for hasLocalKey in [true, false] {
            let text = ProviderSecretDisplay.text(
                authKind: "api_key",
                hasApiKey: true,
                apiKeyMask: nil,
                keyStorage: nil,
                hasLocalKey: hasLocalKey
            )
            XCTAssertNotEqual(text, "无密钥")
            XCTAssertTrue(text == "密钥仅存本机" || text == "本机缺少密钥")
        }
    }

    func testLegacyServerMaskStillShowsServerManaged() {
        let status = ProviderSecretDisplay.status(
            authKind: "api_key",
            hasApiKey: true,
            apiKeyMask: "sk-…1234",
            keyStorage: nil,
            hasLocalKey: false
        )
        XCTAssertEqual(status, .serverManaged(mask: "sk-…1234"))
        XCTAssertEqual(ProviderSecretDisplay.text(status), "密钥 sk-…1234")
    }

    func testOldServerWithoutKeyIsReportedMissing() {
        let status = ProviderSecretDisplay.status(
            authKind: "api_key",
            hasApiKey: false,
            apiKeyMask: nil,
            keyStorage: nil,
            hasLocalKey: false
        )
        XCTAssertEqual(status, .missing)
        XCTAssertEqual(ProviderSecretDisplay.text(status), "无密钥")
    }

    // MARK: - 本机记录（无服务端 authKind）

    func testLocalRecordTextOnlyDependsOnKeychain() {
        XCTAssertEqual(ProviderSecretDisplay.localText(hasLocalKey: true), "密钥仅存本机")
        XCTAssertEqual(ProviderSecretDisplay.localText(hasLocalKey: false), "本机缺少密钥")
    }

    // MARK: - 缺失密钥时的下一步

    func testMissingKeyGuidanceOnlyAppliesToLocalMissingCase() {
        XCTAssertNil(ProviderSecretDisplay.missingKeyGuidance(.notRequired))
        XCTAssertNil(ProviderSecretDisplay.missingKeyGuidance(.localOnly(hasLocalKey: true)))
        XCTAssertNil(ProviderSecretDisplay.missingKeyGuidance(.serverManaged(mask: "…")))
        XCTAssertNil(ProviderSecretDisplay.missingKeyGuidance(.missing))

        let guidance = ProviderSecretDisplay.missingKeyGuidance(.localOnly(hasLocalKey: false))
        XCTAssertNotNil(guidance)
        XCTAssertTrue(guidance?.contains("重新填写 API Key") == true)
    }
}

final class RACPV2ProviderKeyStorageTests: XCTestCase {
    private let baseJSON = """
    {
      "id": "6f1c2a3e-4b5d-4c7e-8f90-a1b2c3d4e5f6",
      "name": "DeepSeek",
      "vendorKey": "deepseek",
      "type": "openai_compatible",
      "protocol": "openai_completions",
      "baseUrl": "https://api.deepseek.com",
      "authKind": "api_key",
      "hasApiKey": true,
      "apiKeyMask": null,
      "isDefault": true,
      "models": [],
      "createdAt": "2026-11-05T00:00:00.000Z",
      "updatedAt": "2026-11-05T00:00:00.000Z"
    }
    """

    func testDecodesOptionalKeyStorage() throws {
        var json = baseJSON
        json = json.replacingOccurrences(
            of: "\"apiKeyMask\": null,",
            with: "\"apiKeyMask\": null,\n  \"keyStorage\": \"client\","
        )
        let provider = try JSONDecoder().decode(RACPV2Provider.self, from: Data(json.utf8))
        XCTAssertEqual(provider.keyStorage, "client")
        XCTAssertTrue(provider.hasApiKey)
        XCTAssertNil(provider.apiKeyMask)
    }

    func testOlderServerWithoutKeyStorageStillDecodes() throws {
        let provider = try JSONDecoder().decode(RACPV2Provider.self, from: Data(baseJSON.utf8))
        XCTAssertNil(provider.keyStorage)
    }
}
