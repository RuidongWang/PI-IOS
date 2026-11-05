import Foundation
import XCTest
import PIiOSNet

@testable import PI_IOS

final class DirectTLSPinTests: XCTestCase {
    func testDirectPinUsesIndependentKeychainAccountAndRoundTrips() throws {
        let hostID = UUID()
        let otherHostID = UUID()
        defer {
            KeychainStore.deleteDirectTLSTrustPin(hostID: hostID)
            KeychainStore.deleteDirectTLSTrustPin(hostID: otherHostID)
        }
        KeychainStore.deleteDirectTLSTrustPin(hostID: hostID)
        KeychainStore.deleteDirectTLSTrustPin(hostID: otherHostID)
        XCTAssertEqual(
            KeychainStore.directTLSAccount(hostID: hostID),
            "host-direct-tls:\(hostID.uuidString.lowercased())"
        )
        let pin = DirectTLSTrustPin(
            hostId: "host_uuid",
            certificateSHA256: String(repeating: "a", count: 64),
            authorizedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(KeychainStore.saveDirectTLSTrustPin(pin, hostID: hostID))
        XCTAssertEqual(KeychainStore.loadDirectTLSTrustPin(hostID: hostID), pin)

        var updated = pin
        updated.certificateSHA256 = String(repeating: "b", count: 64)
        updated.authorizedAt = Date(timeIntervalSince1970: 1_700_000_100)
        XCTAssertTrue(KeychainStore.saveDirectTLSTrustPin(updated, hostID: hostID))
        XCTAssertEqual(KeychainStore.loadDirectTLSTrustPin(hostID: hostID), updated)

        var other = pin
        other.hostId = "other_host"
        other.certificateSHA256 = String(repeating: "c", count: 64)
        XCTAssertTrue(KeychainStore.saveDirectTLSTrustPin(other, hostID: otherHostID))
        XCTAssertEqual(KeychainStore.loadDirectTLSTrustPin(hostID: hostID), updated)
        XCTAssertEqual(KeychainStore.loadDirectTLSTrustPin(hostID: otherHostID), other)
        XCTAssertTrue(KeychainStore.deleteDirectTLSTrustPin(hostID: hostID))
        XCTAssertNil(KeychainStore.loadDirectTLSTrustPin(hostID: hostID))
    }
}
