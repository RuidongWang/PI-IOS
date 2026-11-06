import Foundation
import XCTest

@testable import PIiOSNet

/// 诊断通道只允许非秘密字段（契约 §12），并且必须能给出最近一段失败序列。
final class ConnectionDiagnosticsTests: XCTestCase {
    func testRingBufferKeepsOnlyLatestEvents() {
        let diagnostics = ConnectionDiagnostics(capacity: 2)
        for detail in ["a", "b", "c"] {
            diagnostics.record(kind: .phase, detail: detail)
        }
        XCTAssertEqual(diagnostics.snapshot().map(\.detail), ["b", "c"])
        diagnostics.clear()
        XCTAssertTrue(diagnostics.snapshot().isEmpty)
    }

    func testShortIDIsAShortNonSecretPrefix() {
        let uuid = UUID(uuidString: "12345678-9ABC-DEF0-1234-567890ABCDEF")!
        XCTAssertEqual(ConnectionDiagnostics.shortID(uuid), "12345678")
        XCTAssertEqual(ConnectionDiagnostics.shortID(uuid).count, 8)
    }

    func testPhaseNamesAreStableNonSecretStrings() {
        XCTAssertEqual(ConnectionPhase.connecting(.direct).diagnosticName, "connecting.direct")
        XCTAssertEqual(ConnectionPhase.handshaking(.ssh).diagnosticName, "handshaking.ssh")
        XCTAssertEqual(ConnectionPhase.verifyingIdentity(.direct).diagnosticName, "verifyingIdentity.direct")
        XCTAssertEqual(ConnectionPhase.restoring(.direct).diagnosticName, "restoring.direct")
        XCTAssertEqual(ConnectionPhase.online(.ssh).diagnosticName, "online.ssh")
        XCTAssertEqual(ConnectionPhase.reconnecting(.ssh, attempt: 2, delay: 4).diagnosticName, "reconnecting.ssh.2")
        XCTAssertEqual(ConnectionPhase.fallingBack.diagnosticName, "fallingBack")
        XCTAssertEqual(ConnectionPhase.failed.diagnosticName, "failed")
        XCTAssertNil(ConnectionPhase.failed.diagnosticRoute)
        XCTAssertEqual(ConnectionPhase.online(.direct).diagnosticRoute, .direct)
    }

    func testEventRoundTripsAllAllowedFields() {
        let event = ConnectionDiagnosticEvent(
            kind: .failure,
            intent: "1234abcd",
            route: .direct,
            phase: "handshaking.direct",
            elapsedMs: 812,
            category: .connectTimeout,
            httpStatus: 504,
            closeCode: 1006,
            budgetSeconds: 8,
            detail: "budget-expired"
        )
        let diagnostics = ConnectionDiagnostics(capacity: 4)
        diagnostics.record(event)
        XCTAssertEqual(diagnostics.snapshot(), [event])
    }
}
