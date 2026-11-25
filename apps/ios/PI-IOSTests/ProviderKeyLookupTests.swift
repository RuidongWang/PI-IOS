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

@MainActor
final class ProviderKeyDirectLookupTests: XCTestCase {
    private let hostID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        _ = KeychainStore.deleteProviderKey(hostID: hostID, providerId: "prv_v2")
        try? FileManager.default.removeItem(at: root)
    }

    func testTurnKeyResolvesDirectProviderIDAndStoredEndpoint() throws {
        let key = "sk-direct-key"
        guard KeychainStore.set(
            Data(key.utf8),
            service: "dev.piios.providerkey",
            account: "provider-key:\(hostID.uuidString.lowercased()):prv_v2"
        ) else {
            throw XCTSkip("模拟器 Keychain 不可写，跳过 provider key lookup 用例")
        }

        let model = makeModel()
        XCTAssertEqual(model.providerCredentialForTurn(providerId: "prv_v2", hostID: hostID)?.value, key)
        XCTAssertEqual(model.connection.session.providerCredential?("prv_v2")?.value, key)
        XCTAssertEqual(model.connection.session.providerCredential?("prv_v2")?.baseURL, "https://v2.invalid")
        XCTAssertNil(model.providerCredentialForTurn(providerId: "prv_unknown", hostID: hostID))

        let host = try XCTUnwrap(model.currentHost)
        let context = try XCTUnwrap(model.providerOperationContext(for: host))
        let changed = ProviderCreateInput(
            name: "Edited service", vendorKey: "fixture", type: "openai_compatible",
            protocol: "openai_completions", authKind: "api_key", baseUrl: "https://new.invalid",
            models: []
        )
        XCTAssertTrue(model.recordImportedProvider(
            context: context, input: changed, providerId: "prv_v2", serverDefaultSet: false
        ))
        XCTAssertEqual(model.connection.session.providerCredential?("prv_v2")?.baseURL, "https://new.invalid")
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
            hostID: hostID,
            name: "Primary Service",
            baseURL: "https://v2.invalid",
            apiStyle: "chat_completions",
            models: [StoredModelBinding(spec: ProviderModelSpec(
                id: "model-1",
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
