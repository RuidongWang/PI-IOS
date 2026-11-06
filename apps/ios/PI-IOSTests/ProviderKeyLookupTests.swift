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
        let hostID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let otherHostID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let providerID = "provider_alpha"
        let otherProviderID = "provider_beta"
        let key = "sk-test-client-only"

        let written = KeychainStore.saveProviderKey(key, hostID: hostID, providerId: providerID)
            && KeychainStore.saveProviderKey("sk-other", hostID: otherHostID, providerId: providerID)
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
