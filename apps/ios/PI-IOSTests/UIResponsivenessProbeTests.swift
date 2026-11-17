import XCTest
@testable import PI_IOS

final class UIResponsivenessProbeTests: XCTestCase {
    func testBinaryIdentityIsAvailableWithoutFileReads() {
        XCTAssertNotNil(UUID(uuidString: PIBuildIdentity.current))
    }

    func testOnlyOneProbeIsPendingAndDelayIsReportedOnce() {
        let probe = UIResponsivenessProbe()
        probe.start(now: 0)
        guard case .dispatch(let id) = probe.tick(now: 0) else { return XCTFail("missing probe") }
        XCTAssertEqual(probe.tick(now: 0.1), .idle)
        XCTAssertEqual(probe.tick(now: 0.3), .delayed(milliseconds: 300))
        XCTAssertEqual(probe.tick(now: 0.5), .idle)
        XCTAssertEqual(probe.acknowledge(id, now: 0.6), 600)
        guard case .dispatch = probe.tick(now: 0.7) else { return XCTFail("next probe missing") }
    }

    func testInactiveAndPreviousSceneCallbacksCannotReportAStall() {
        let probe = UIResponsivenessProbe()
        XCTAssertEqual(probe.tick(now: 5), .idle)
        probe.start(now: 5)
        guard case .dispatch(let old) = probe.tick(now: 5) else { return XCTFail() }
        probe.stop()
        XCTAssertEqual(probe.tick(now: 50), .idle)
        XCTAssertNil(probe.acknowledge(old, now: 50))
        probe.start(now: 60)
        guard case .dispatch(let current) = probe.tick(now: 60) else { return XCTFail() }
        XCTAssertNotEqual(old, current)
        XCTAssertNil(probe.acknowledge(old, now: 60.1))
        XCTAssertNotNil(probe.acknowledge(current, now: 60.1))
    }

    func testRecentMainProgressCanCoexistWithAnUnrelatedDisplayGap() {
        let probe = UIResponsivenessProbe()
        probe.start(now: 0)
        guard case .dispatch(let id) = probe.tick(now: 8) else { return XCTFail() }
        probe.acknowledge(id, now: 8.01)
        let state = probe.snapshot(now: 8.02)
        XCTAssertEqual(state.pendingMilliseconds, 0)
        XCTAssertLessThan(state.sinceResponseMilliseconds, 20)
    }
}
