import Foundation
import XCTest
import PIiOSCore

@testable import PI_IOS

/// The provider API key is now client-only: it is never persisted on the server
/// and is resolved from the local Keychain for the currently selected host when a
/// turn is sent. These tests pin the (host, provider) scoping used by that lookup.
@MainActor
final class ProviderKeyLookupTests: XCTestCase {
    func testLookupIsScopedByCurrentHostAndProvider() throws {
        // Random scope: never overwrite or delete a real user's Keychain entry.
        let hostID = UUID()
        let otherHostID = UUID()
        let providerID = "provider_alpha"
        let otherProviderID = "provider_beta"
        let key = "sk-test-client-only"

        let endpoint = "https://provider.invalid/v1"
        let written = KeychainStore.saveProviderKey(key, hostID: hostID, providerId: providerID, baseURL: endpoint)
            && KeychainStore.saveProviderKey("sk-other", hostID: otherHostID, providerId: providerID, baseURL: endpoint)
        guard written else {
            throw XCTSkip("模拟器 Keychain 不可写，跳过 provider key lookup 用例")
        }
        defer {
            _ = KeychainStore.deleteProviderKey(hostID: hostID, providerId: providerID)
            _ = KeychainStore.deleteProviderKey(hostID: hostID, providerId: otherProviderID)
            _ = KeychainStore.deleteProviderKey(hostID: otherHostID, providerId: providerID)
        }

        let model = ConnectionModel()
        model.setCacheHostID(hostID)
        XCTAssertEqual(model.providerKeyForCurrentHost(providerID), key)
        XCTAssertNil(model.providerKeyForCurrentHost(otherProviderID))
        XCTAssertNil(model.providerKeyForCurrentHost("provider_unknown"))

        model.setCacheHostID(otherHostID)
        XCTAssertEqual(model.providerKeyForCurrentHost(providerID), "sk-other")

        model.setCacheHostID(nil)
        XCTAssertNil(model.providerKeyForCurrentHost(providerID))
    }

    func testLookupNeverWaitsForAConnection() {
        // The lookup is local-only; a missing key is `nil` (the server then answers
        // PROVIDER_SECRET_MISSING), it must never fall back to a cached/in-memory key.
        let model = ConnectionModel()
        XCTAssertNil(model.providerKeyForCurrentHost("provider_alpha"))
    }
}

/// 「provider 已同步到服务器、key 是否同步」的回归：legacy 映射记录可能把明文
/// 只留在 `legacyProviderId` 下，发送路径按会话绑定的 v2 id 取 key 时必须回退。
@MainActor
final class ProviderKeyLegacyFallbackTests: XCTestCase {
    private let hostID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        _ = KeychainStore.deleteProviderKey(hostID: hostID, providerId: "prv_v2")
        _ = KeychainStore.deleteProviderKey(hostID: hostID, providerId: "prv_legacy")
        try? FileManager.default.removeItem(at: root)
    }

    func testTurnKeyFallsBackToLegacyProviderID() throws {
        let key = "sk-legacy-only"
        guard KeychainStore.set(
            Data(key.utf8),
            service: "dev.piios.providerkey",
            account: "provider-key:\(hostID.uuidString.lowercased()):prv_legacy"
        ) else {
            throw XCTSkip("模拟器 Keychain 不可写，跳过 provider key fallback 用例")
        }

        let model = makeModel()
        XCTAssertEqual(
            model.providerCredentialForTurn(providerId: "prv_v2", hostID: hostID)?.value,
            key,
            "v2 id 没有明文时必须回退到本机记录里的 legacy id"
        )
        XCTAssertEqual(
            model.connection.session.providerCredential?("prv_v2")?.value,
            key,
            "会话发送注入的解析器也必须走同一回退"
        )
        XCTAssertEqual(model.connection.session.providerCredential?("prv_v2")?.baseURL, "https://legacy.invalid")
        XCTAssertNil(model.providerCredentialForTurn(providerId: "prv_unknown", hostID: hostID))

        let host = try XCTUnwrap(model.currentHost)
        let context = try XCTUnwrap(model.providerOperationContext(for: host))
        let changed = ProviderCreateInput(
            name: "Edited mirror", vendorKey: "fixture", type: "openai_compatible",
            protocol: "openai_completions", authKind: "api_key", baseUrl: "https://new.invalid",
            models: []
        )
        XCTAssertTrue(model.recordImportedProvider(
            context: context, input: changed, providerId: "prv_v2", serverDefaultSet: false,
            legacyProviderId: "prv_legacy", hostV2Mirror: true
        ))
        XCTAssertEqual(model.connection.session.providerCredential?("prv_v2")?.baseURL, "https://legacy.invalid")
    }

    func testDirectProviderIDKeyWinsOverLegacyFallback() throws {
        guard KeychainStore.saveProviderKey("sk-legacy", hostID: hostID, providerId: "prv_legacy", baseURL: "https://legacy.invalid"),
              KeychainStore.saveProviderKey("sk-v2", hostID: hostID, providerId: "prv_v2", baseURL: "https://v2.invalid")
        else {
            throw XCTSkip("模拟器 Keychain 不可写，跳过 provider key fallback 用例")
        }

        let model = makeModel()
        let credential = model.providerCredentialForTurn(providerId: "prv_v2", hostID: hostID)
        XCTAssertEqual(credential?.value, "sk-v2")
        XCTAssertEqual(credential?.baseURL, "https://v2.invalid")
    }

    private func makeModel() -> AppModel {
        let host = HostRecord(
            id: hostID,
            name: "Key Host",
            host: "127.0.0.1",
            port: 22,
            username: "tester",
            authKind: .password,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isCurrent: true,
            pairedAt: nil
        )
        let provider = StoredModelProvider(
            providerId: "prv_v2",
            legacyProviderId: "prv_legacy",
            hostV2Mirror: true,
            hostID: hostID,
            name: "Legacy Mirror",
            baseURL: "https://legacy.invalid",
            apiStyle: "chat_completions",
            models: [StoredModelBinding(spec: ProviderModelSpec(
                id: "legacy-model",
                contextWindow: 32_000,
                maxTokens: 4_096,
                thinkingLevels: []
            ))],
            defaultModelId: nil,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return AppModel(
            seed: PersistedState(hosts: [host], modelProviders: [provider]),
            logStore: PILogger(directoryURL: root.appendingPathComponent("logs", isDirectory: true))
        )
    }
}
