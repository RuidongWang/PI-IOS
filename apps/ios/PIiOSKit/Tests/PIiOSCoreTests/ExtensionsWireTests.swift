import XCTest
@testable import PIiOSCore

final class ExtensionsWireTests: XCTestCase {
    func testHostGoldenResponsesDecodeWithSwiftTypes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../pi-adaptor/docs/api/pi-adaptor.golden.json").standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Host golden fixture is available only in the complete workspace")
        }
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let requests = try XCTUnwrap(golden["requests"] as? [[String: Any]])
        let responses = try XCTUnwrap(golden["responses"] as? [[String: Any]])
        for method in ["extension/list", "session/extensions"] {
            let index = try XCTUnwrap(requests.firstIndex { $0["method"] as? String == method }, "missing Host fixture: \(method)")
            let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(responses[index]["result"]))
            if method == "extension/list" {
                let decoded = try JSONDecoder().decode(RACPExtensionInventory.self, from: data)
                XCTAssertFalse(decoded.hostId.isEmpty)
            } else {
                let decoded = try JSONDecoder().decode(RACPSessionExtensions.self, from: data)
                XCTAssertFalse(decoded.sessionId.isEmpty)
            }
        }
    }

    func testUnrunAndDisabledAreNotAnEmptySuccessfulSnapshot() throws {
        let result = try JSONDecoder().decode(RACPSessionExtensions.self, from: Data(#"{"hostId":"h","sessionId":"s","configRevision":"c","userLoadingEnabled":false,"runningTurnId":null,"latestAttempt":null,"previousCompleted":null}"#.utf8))
        XCTAssertNil(result.latestAttempt)
        XCTAssertFalse(result.userLoadingEnabled)
        XCTAssertEqual(result.latestLabel, "尚未运行")
        XCTAssertEqual(RACPMethod.extensionList.rawValue, "extension/list")
        XCTAssertEqual(RACPMethod.sessionExtensions.rawValue, "session/extensions")
    }

    func testUnknownRuntimeStatesAndDiagnosticStagesRemainDecodable() throws {
        let item = try JSONDecoder().decode(RACPExtensionRuntimeEntry.self, from: Data(#"{"id":"e","name":"Future","configuredVersion":null,"loadState":"future-state","skipReason":"future-reason","registeredTools":[],"activeTools":[],"registeredCommands":[],"mobileInvocable":false,"diagnostics":[{"stage":"future-stage","severity":"notice","code":"NEW","message":"detail","occurredAt":"2026-11-12T12:00:00Z"}]}"#.utf8))
        XCTAssertEqual(item.loadState, "future-state")
        XCTAssertEqual(item.diagnostics.first?.stage, "future-stage")
        XCTAssertEqual(try JSONDecoder().decode(RACPExtensionRuntimeEntry.self, from: JSONEncoder().encode(item)), item)
    }

    func testEnvelopeIdentityMustMatchExtensionEvent() throws {
        let valid = try event(session: "s", turn: "t")
        XCTAssertEqual(valid.extensionSnapshot?.id, "snap")
        XCTAssertNil(try event(session: "other", turn: "t").extensionSnapshot)
        XCTAssertNil(try event(session: "s", turn: "other").extensionSnapshot)
        XCTAssertNil(try event(session: "s", turn: "t", scope: "host").extensionSnapshot)
    }

    func testHistoryLabelsUseCurrentTurnAndConfigurationRatherThanDate() throws {
        let snapshot = try XCTUnwrap(try event(session: "s", turn: "t").extensionSnapshot)
        var result = RACPSessionExtensions(hostId: "h", sessionId: "s", configRevision: "c", userLoadingEnabled: true,
                                           runningTurnId: "t", latestAttempt: snapshot, previousCompleted: nil)
        XCTAssertEqual(result.latestLabel, "本轮加载结果")
        result.runningTurnId = nil
        XCTAssertEqual(result.latestLabel, "最近一轮加载结果")
        result.configRevision = "changed"
        XCTAssertEqual(result.latestLabel, "此前配置的加载结果")
    }

    private func event(session: String, turn: String, scope: String = "session") throws -> RACPEvent {
        try RACPEvent.decoded(from: .object([
            "scope": .string(scope), "kind": .string("session.extensions.updated"),
            "sessionId": .string(session), "turnId": .string(turn), "epoch": .string("ep"), "sequence": .number(3),
            "payload": .object([
                "id": .string("snap"), "hostId": .string("h"), "sessionId": .string("s"), "turnId": .string("t"),
                "configRevision": .string("c"), "revision": .number(1), "startedAt": .string("2026-11-12T12:00:00Z"),
                "completedAt": .null, "phase": .string("ready"), "entries": .array([]), "diagnostics": .array([])
            ])
        ]))
    }
}
