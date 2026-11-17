import Foundation
import XCTest
import PIiOSNet

@testable import PI_IOS

final class PersistedStateMigrationTests: XCTestCase {
    func testLegacyStateDecodeSaveReloadKeepsIdentityAssociationsAndDefaults() throws {
        let hostID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let legacy = """
        {
          "version": 1,
          "hosts": [{
            "id": "\(hostID.uuidString)",
            "name": "Legacy",
            "host": "192.0.2.10",
            "port": 22,
            "username": "pi",
            "authKind": "password",
            "createdAt": "2024-01-01T00:00:00Z",
            "isCurrent": true,
            "pairedAt": "2024-01-01T00:01:40Z",
            "hostPort": 33381,
            "keyFileName": "legacy.pem"
          }],
          "offlineCacheLimit": 200,
          "modelProviders": [],
          "lastSessionId": "session_legacy",
          "lastProjectId": "project_legacy",
          "projectBindings": [],
          "sessionBindings": [],
          "lastSessionByHost": {"\(hostID.uuidString)": "session_legacy"},
          "lastProjectByHost": {"\(hostID.uuidString)": "project_legacy"},
          "collapsedProjectGroups": [],
          "projectBrowserPaths": {},
          "readingPositionsByHost": {}
        }
        """
        // Never touch the app's real state file: use an isolated temp URL for
        // both read and write so a crash cannot destroy existing user data.
        let originalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: originalURL) }
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-state-\(UUID().uuidString).json")
        try Data(legacy.utf8).write(to: legacyURL)
        defer { try? FileManager.default.removeItem(at: legacyURL) }
        let decoded = StateFile.load(from: legacyURL)
        XCTAssertNil(decoded.warning)
        let host = try XCTUnwrap(decoded.state.hosts.first)
        XCTAssertEqual(host.id, hostID)
        XCTAssertEqual(host.hostPort, 33381)
        XCTAssertNotNil(host.pairedAt)
        XCTAssertEqual(host.connectionPreference, .sshOnly)
        XCTAssertNil(host.directEndpoint)
        XCTAssertNil(host.adaptorHostId)
        XCTAssertEqual(decoded.state.lastSessionByHost[hostID.uuidString], "session_legacy")
        XCTAssertEqual(decoded.state.lastProjectByHost[hostID.uuidString], "project_legacy")

        try StateFile.save(decoded.state, to: originalURL)
        let reloaded = StateFile.load(from: originalURL)
        XCTAssertNil(reloaded.warning)
        XCTAssertEqual(reloaded.state, decoded.state)
        let saved = try Data(contentsOf: originalURL)
        let text = String(decoding: saved, as: UTF8.self)
        XCTAssertFalse(text.contains("deviceToken"))
        XCTAssertFalse(text.contains("privateKey"))
        XCTAssertFalse(text.contains("certificateSHA256"))
        XCTAssertTrue(text.contains("sshOnly"))
    }

    func testDirectEndpointValidationDoesNotEnablePreference() throws {
        var draft = HostDraft()
        draft.host = "localhost"
        draft.username = "pi"
        draft.secret = "password"
        draft.directEndpoint = "wss://localhost:9443/v1/racp/ws"
        draft.connectionPreference = .directPreferred
        XCTAssertTrue(HostValidator.validate(draft).isValid)
        XCTAssertEqual(
            HostValidator.canonicalDirectEndpoint(draft.directEndpoint),
            "wss://localhost:9443/v1/racp/ws"
        )
        for invalid in [
            "https://localhost/v1/racp/ws",
            "wss://localhost/v1/racp/ws/",
            "wss://localhost/v1/racp/ws?token=secret",
            "wss://user@localhost/v1/racp/ws",
        ] {
            draft.directEndpoint = invalid
            XCTAssertFalse(HostValidator.validate(draft).isValid, invalid)
        }
    }
}
