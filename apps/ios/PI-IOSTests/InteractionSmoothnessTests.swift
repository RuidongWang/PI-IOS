import Foundation
import XCTest
import PIiOSCore
import PIiOSNet
@testable import PI_IOS

@MainActor
final class InteractionSmoothnessTests: XCTestCase {
    func testOpeningFeedbackIsSynchronousAndBlocksOldSessionWrites() {
        let session = SessionController()
        session.bind(client: nil, online: true)
        session.applyModelAvailability(availableStatus())
        session.draftText = "Keep this draft"
        XCTAssertTrue(session.canSend)

        session.prepareToOpen(sessionId: "S2")
        XCTAssertEqual(session.openingSessionID, "S2")
        XCTAssertTrue(session.isAttaching)
        XCTAssertFalse(session.sendAdmission.isAllowed)
        XCTAssertFalse(session.canInterrupt)
        XCTAssertFalse(session.hasRecentModelAvailability())
        XCTAssertEqual(session.draftText, "Keep this draft")
    }

    func testFailedOpenRetainsDestinationAndStopsSpinner() async {
        let session = SessionController()
        await session.attach(sessionId: "S2")
        XCTAssertEqual(session.openingSessionID, "S2")
        XCTAssertFalse(session.isAttaching)
        XCTAssertNotNil(session.lastError)
        session.detach()
        XCTAssertNil(session.openingSessionID)
        XCTAssertFalse(session.isAttaching)
    }

    func testCancelOnlyCancelsTheMatchingOpeningTarget() {
        let session = SessionController()
        session.prepareToOpen(sessionId: "S1")
        session.prepareToOpen(sessionId: "S2")
        session.cancelPendingAttach(for: "S1")
        XCTAssertEqual(session.openingSessionID, "S2")
        XCTAssertTrue(session.isAttaching)
        session.cancelPendingAttach(for: "S2")
        XCTAssertNil(session.openingSessionID)
        XCTAssertFalse(session.isAttaching)
    }

    func testSuccessfulCheckExpiresAndDisconnectInvalidatesIt() {
        let session = SessionController()
        session.bind(client: nil, online: true)
        session.applyModelAvailability(availableStatus())
        XCTAssertTrue(session.hasRecentModelAvailability())
        XCTAssertFalse(session.hasRecentModelAvailability(now: Date().addingTimeInterval(31)))
        XCTAssertFalse(session.hasRecentModelAvailability(now: Date().addingTimeInterval(-1)))
        session.setOnline(false)
        XCTAssertFalse(session.hasRecentModelAvailability())
        session.bind(client: nil, online: false)
        XCTAssertFalse(session.hasRecentModelAvailability())
    }

    func testCheckingOrUnavailableStateNeverReusesPreviousSuccess() {
        let session = SessionController()
        session.applyModelAvailability(availableStatus())
        session.markModelAvailabilityChecking()
        XCTAssertFalse(session.hasRecentModelAvailability())
        session.applyModelAvailability(availableStatus())
        session.markModelUnavailable("removed")
        XCTAssertFalse(session.hasRecentModelAvailability())
    }

    func testSwitchingCancelsFrozenSendAndPreservesDraft() async {
        let session = SessionController()
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = "S1"
        session.configureUITestSnapshots(["S1": snapshot])
        await session.attach(sessionId: "S1")
        session.draftText = "Keep this instruction"
        let intent = session.makeSendIntent()
        XCTAssertNotNil(intent)
        session.prepareToOpen(sessionId: "S2")
        await session.send(expected: intent)
        XCTAssertEqual(session.draftText, "Keep this instruction")
        XCTAssertTrue(session.notice?.contains("本次发送已取消") == true)
    }

    private func availableStatus() -> ProviderBindingStatus {
        ProviderBindingStatus(
            sessionId: "S1", pinnedProviderId: "provider", pinnedModelId: "model",
            pinnedThinkingLevel: nil, effectiveProviderId: "provider", effectiveModelId: "model",
            available: true, unavailableReason: nil, unknownInputs: [], observedAt: "fixture"
        )
    }
}
