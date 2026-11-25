import Foundation
import XCTest
import PIiOSCore
@testable import PIiOSNet

/// Boundary tests model pinned v0.21.0 approval results.
final class SessionIdempotencyRetryTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("request-keys.json") }
    private var store: SessionRequestKeyStore { SessionRequestKeyStore(fileURL: fileURL) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func identity(_ action: SessionRequestAction) -> SessionRequestIdentity {
        SessionRequestIdentity(hostID: "fixture-host", sessionID: "fixture-session", itemID: itemID(action), action: action)
    }

    private func itemID(_ action: SessionRequestAction) -> String? {
        switch action {
        case .sessionCreate, .turn: return nil
        default: return "approval"
        }
    }

    func testTurnAcceptedBeforeTimeoutIsNotExecutedTwiceAfterRelaunch() throws {
        try verifyAcceptedRetry(.turn(text: "fixture message"))
    }

    func testApprovalAndContractReturnAlreadyResolvedAfterLostAcknowledgement() throws {
        try verifyAcceptedRetry(.approval(decision: .allowOnce, permissionMode: nil))
        try verifyAcceptedRetry(.contract(decision: .approve, permissionMode: .ask))
    }

    private func verifyAcceptedRetry(_ action: SessionRequestAction) throws {
        let first = try store.prepare(identity(action))
        let model = SessionViewModel()
        applySnapshot(to: model, revision: 3)
        let contract: Bool
        if case .contract = action { contract = true } else { contract = false }
        var host = FixtureHost(contract: contract)
        let original = try frame(action, attempt: first, model: model)
        XCTAssertThrowsError(try host.receive(original, dropResponse: true)) {
            XCTAssertEqual($0 as? RACPClientError, .timedOut("fixture response"))
        }
        let restarted = SessionRequestKeyStore(fileURL: fileURL)
        let retried = try restarted.prepare(identity(action), admission: .queue)
        XCTAssertEqual(retried, first)
        applySnapshot(to: model, revision: 9)
        let retry = try frame(action, attempt: retried, model: model, requestID: "retry")
        XCTAssertNotEqual(original.value(at: ["params", "context", "requestId"]), retry.value(at: ["params", "context", "requestId"]))
        let result = try host.receive(retry)
        if itemID(action) != nil {
            XCTAssertEqual(result.value(at: ["alreadyResolved"])?.boolValue, true)
            XCTAssertEqual(retry.value(at: ["params", "context", "expectedRevision"])?.intValue, 9)
        } else { XCTAssertNil(retry.value(at: ["params", "admission"])) }
        XCTAssertEqual(host.executionCount, 1)
        try restarted.acknowledge(retried)
        XCTAssertNotEqual(try store.prepare(identity(action)).idempotencyKey, first.idempotencyKey)
    }

    func testUnacceptedApprovalRetryUsesCurrentCardRevisionWithSameKey() throws {
        let action = SessionRequestAction.approval(decision: .allowOnce, permissionMode: nil)
        let first = try store.prepare(identity(action))
        let model = SessionViewModel()
        applySnapshot(to: model, revision: 3)
        var host = FixtureHost(approvalRevision: 9)
        assertCode(.approvalStale) { try host.receive(frame(action, attempt: first, model: model)) }
        XCTAssertEqual(host.executionCount, 0)
        applySnapshot(to: model, revision: 9)
        let retry = try store.prepare(identity(action))
        XCTAssertEqual(first, retry)
        _ = try host.receive(frame(action, attempt: retry, model: model))
        XCTAssertEqual(host.executionCount, 1)
    }

    func testMissingDisallowedPermissionAndInvalidToolDecisionAreRejected() throws {
        let model = SessionViewModel()
        applySnapshot(to: model, revision: 3)
        let action = SessionRequestAction.contract(decision: .approve, permissionMode: .auto)
        let attempt = try store.prepare(identity(action))
        var host = FixtureHost(contract: true)
        assertCode(.invalidArgument) { try host.receive(frame(action, attempt: attempt, model: model)) }
        let missingMode = try encoded(.approvalRespond, RACPApprovalRespondParams(approvalId: "approval", contractDecision: .approve, context: RACPContext(requestId: "missing", idempotencyKey: attempt.idempotencyKey, expectedRevision: 3)), requestID: "missing")
        assertCode(.invalidArgument) { try host.receive(missingMode) }
        var tool = FixtureHost()
        assertCode(.invalidArgument) { try tool.receive(frame(action, attempt: attempt, model: model)) }
        XCTAssertEqual(host.executionCount + tool.executionCount, 0)
    }

    func testTurnKeyReusedWithChangedPayloadConflicts() throws {
        let action = SessionRequestAction.turn(text: "first")
        let attempt = try store.prepare(identity(action))
        let model = SessionViewModel()
        var host = FixtureHost()
        _ = try host.receive(frame(action, attempt: attempt, model: model))
        assertCode(.idempotencyConflict) { try host.receive(frame(.turn(text: "changed"), attempt: attempt, model: model)) }
        XCTAssertEqual(host.executionCount, 1)
    }

    private func assertCode(_ code: RACPErrorCode, _ body: () throws -> JSONValue, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            guard case let RACPClientError.server(actual, _) = $0 else { return XCTFail("Expected server error", file: file, line: line) }
            XCTAssertEqual(actual, code, file: file, line: line)
        }
    }

    private func applySnapshot(to model: SessionViewModel, revision: Int) {
        model.applySnapshot(RACPSnapshot(cursor: RACPCursor(epoch: "fixture", sequence: revision), revision: 1000,
            pendingApprovals: [RACPApprovalRequest(id: "approval", payload: .object(["revision": .number(Double(revision))]))]), replayComplete: false)
    }

    private func encoded<P: Encodable>(_ method: RACPMethod, _ params: P, requestID: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(RACPRequest(id: .string(requestID), method: method, params: params)))
    }

    private func frame(_ action: SessionRequestAction, attempt: SessionRequestAttempt, model: SessionViewModel, requestID: String = "first") throws -> JSONValue {
        let revision = model.expectedRevisionForApproval(id: "approval")
        let context = RACPContext(requestId: requestID, idempotencyKey: attempt.idempotencyKey, expectedRevision: revision)
        switch action {
        case .sessionCreate(var params):
            params.context = context
            return try encoded(.sessionCreate, params, requestID: requestID)
        case .turn(let text):
            return try encoded(.turnStart, RACPTurnStartParams(sessionId: "fixture-session", admission: attempt.admission, input: RACPTurnInput(text: text), context: context), requestID: requestID)
        case .turnAttachments(let text, let attachmentIds):
            return try encoded(
                .turnStart,
                RACPTurnStartParams(
                    sessionId: "fixture-session",
                    admission: attempt.admission,
                    input: RACPTurnInput(
                        text: text,
                        attachments: attachmentIds.map(JSONValue.string)
                    ),
                    context: context
                ),
                requestID: requestID
            )
        case .approval, .contract:
            return try encoded(.approvalRespond, RACPApprovalRespondParams(approvalId: "approval", action: action, context: context), requestID: requestID)
        }
    }
}

private struct FixtureHost {
    let contract: Bool
    let approvalRevision: Int
    private var turnInputs: [String: JSONValue] = [:]
    private var approvalResolved = false
    private(set) var executionCount = 0

    init(contract: Bool = false, approvalRevision: Int = 3) {
        self.contract = contract
        self.approvalRevision = approvalRevision
    }

    mutating func receive(_ frame: JSONValue, dropResponse: Bool = false) throws -> JSONValue {
        func fail(_ code: RACPErrorCode) -> RACPClientError { .server(code: code, message: "fixture") }
        guard let method = frame.value(at: ["method"])?.stringValue, let params = frame.value(at: ["params"]),
              let requestID = params.value(at: ["context", "requestId"])?.stringValue, !requestID.isEmpty,
              let key = params.value(at: ["context", "idempotencyKey"])?.stringValue, !key.isEmpty
        else { throw fail(.invalidArgument) }
        let result: JSONValue
        switch method {
        case "turn/start":
            guard params.value(at: ["sessionId"])?.stringValue == "fixture-session",
                  let input = params.value(at: ["input"]), input.value(at: ["text"])?.stringValue != nil
            else { throw fail(.invalidArgument) }
            if let previous = turnInputs[key] {
                guard previous == input else { throw fail(.idempotencyConflict) }
            } else { turnInputs[key] = input; executionCount += 1 }
            result = .object(["accepted": .bool(true), "turn": .object(["id": .string("turn-fixture")])])
        case "approval/respond":
            guard params.value(at: ["approvalId"])?.stringValue == "approval" else { throw fail(.notFound) }
            if approvalResolved {
                result = .object(["approvalId": .string("approval"), "status": .string("resolved"), "alreadyResolved": .bool(true)])
            } else {
                if let expected = params.value(at: ["context", "expectedRevision"])?.intValue,
                   expected != approvalRevision { throw fail(.approvalStale) }
                guard let decision = params.value(at: ["decision"])?.stringValue,
                      (contract ? ["approve", "reject"] : ["allow-once", "allow-session", "deny"]).contains(decision)
                else { throw fail(.invalidArgument) }
                if contract && decision == "approve" {
                    guard params.value(at: ["permissionMode"])?.stringValue == "ask" else { throw fail(.invalidArgument) }
                }
                result = .object(["approvalId": .string("approval"), "status": .string("resolved"), "alreadyResolved": .bool(false)])
                approvalResolved = true
                executionCount += 1
            }
        default: throw fail(.methodNotFound)
        }
        if dropResponse { throw RACPClientError.timedOut("fixture response") }
        return result
    }
}
