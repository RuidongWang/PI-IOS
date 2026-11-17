import CoreGraphics
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import PI_IOS

final class ConversationStabilityHelpersTests: XCTestCase {
#if DEBUG
    func testOrderedIDProbeDetectsMissingDuplicateAndReorderedItems() {
        let ids = (1...1_500).map { "identity-\($0)" }
        let baseline = ConversationStabilityIdentity.digest(orderedItemIDs: ids)
        XCTAssertEqual(baseline.count, 16)
        XCTAssertEqual(baseline, ConversationStabilityIdentity.digest(orderedItemIDs: ids))
        XCTAssertNotEqual(baseline, ConversationStabilityIdentity.digest(orderedItemIDs: Array(ids.dropLast())))
        var duplicated = ids
        duplicated[750] = duplicated[749]
        XCTAssertEqual(duplicated.count, ids.count, "same count must not hide duplicate IDs")
        XCTAssertNotEqual(baseline, ConversationStabilityIdentity.digest(orderedItemIDs: duplicated))
        var reordered = ids
        reordered.swapAt(749, 750)
        XCTAssertNotEqual(baseline, ConversationStabilityIdentity.digest(orderedItemIDs: reordered))
        XCTAssertEqual(ConversationStabilityIdentity.digest(orderedItemIDs: []), "e3b0c44298fc1c14")
    }
#endif

    func testCachedPreviewIsBoundedAndIncludesOldReadingAnchor() {
        let range = ConversationPreviewWindow.range(count: 3_500, anchorIndex: 2_500)
        XCTAssertEqual(range.count, 80)
        XCTAssertTrue(range.contains(2_500))
        XCTAssertEqual(ConversationPreviewWindow.range(count: 3_500, anchorIndex: nil), 0..<80)
        XCTAssertEqual(ConversationPreviewWindow.range(count: 3_500, anchorIndex: 3_499), 3_420..<3_500)
        XCTAssertEqual(ConversationPreviewWindow.range(count: 3, anchorIndex: 99), 0..<3)
        XCTAssertEqual(ConversationPreviewWindow.range(count: 0, anchorIndex: 0), 0..<0)
        XCTAssertEqual(ConversationPreviewWindow.range(count: 3_500, anchorIndex: 2_500, limit: 160).count, 160)
    }

    func testRestoreConfirmationUsesTheSwiftUIVisualOrigin() {
        XCTAssertTrue(ConversationViewportGeometry.isAnchorAlignedAtViewportTop(measuredMinY: 0))
        XCTAssertTrue(ConversationViewportGeometry.isAnchorAlignedAtViewportTop(measuredMinY: 1.5))
        XCTAssertFalse(ConversationViewportGeometry.isAnchorAlignedAtViewportTop(measuredMinY: 20))
    }

    func testFirstVisibleExcludesPreviousRowTouchingViewportBoundary() {
        let frames: [String: CGRect] = [
            "15": CGRect(x: 0, y: -107.666667, width: 300, height: 107.666668),
            "16": CGRect(x: 0, y: 0, width: 300, height: 107.666667)
        ]
        XCTAssertEqual(ConversationViewportGeometry.firstVisibleItemID(frames: frames, viewportBottom: 600), "16")
    }

    func testAlignedTargetStaysFirstVisibleAtTheToleranceEdge() {
        let frames: [String: CGRect] = [
            "15": CGRect(x: 0, y: -106.166667, width: 300, height: 107.666667),
            "16": CGRect(x: 0, y: 1.5, width: 300, height: 107.666667)
        ]
        XCTAssertTrue(
            ConversationViewportGeometry.isAnchorAlignedAtViewportTop(measuredMinY: 1.5)
        )
        XCTAssertEqual(
            ConversationViewportGeometry.firstVisibleItemID(frames: frames, viewportBottom: 600),
            "16",
            "A restore confirmed within tolerance must report the same row as first visible"
        )
    }

    func testRestoreContentOffsetMatchesTheConfirmedViewportGeometry() {
        let adjustedTopInset: CGFloat = 20
        let anchorContentMinY: CGFloat = 180
        let contentOffsetY = ConversationViewportGeometry.restoreContentOffsetY(
            anchorContentMinY: anchorContentMinY,
            adjustedTopInset: adjustedTopInset
        )

        XCTAssertEqual(contentOffsetY, 160)
        XCTAssertEqual(
            ConversationViewportGeometry.viewportMinY(contentMinY: anchorContentMinY, contentOffsetY: contentOffsetY),
            adjustedTopInset,
            "UIKit conversion is distinct from SwiftUI named-space visual frames"
        )
        XCTAssertTrue(ConversationViewportGeometry.isAnchorAlignedAtViewportTop(measuredMinY: 0))
    }

    func testPagingContentTopExcludesTheRowTopSpacing() {
        let viewportY = ConversationViewportGeometry.viewportMinY(
            contentMinY: ConversationViewportGeometry.pagingContentMinY(
                anchorMinY: 359,
                topSpacing: 0
            ),
            contentOffsetY: 100
        )
        let correctedOffset = ConversationViewportGeometry.pagingContentMinY(
            anchorMinY: 359,
            topSpacing: 12
        ) - viewportY

        XCTAssertEqual(
            ConversationViewportGeometry.pagingContentMinY(
                anchorMinY: 359,
                topSpacing: 12
            ),
            371,
            "content top sits 12pt below the padded row top"
        )
        XCTAssertEqual(
            correctedOffset,
            112,
            "the offset must move with the 12pt spacer so the preserved item keeps its visual top"
        )
    }

    func testOnlyAnAppliedPagingCorrectionMayReplaceTheReadingPosition() {
        XCTAssertTrue(ConversationPagingPositionOutcome.applied.recordsVisiblePosition)
        XCTAssertTrue(ConversationPagingPositionOutcome.notInserted.recordsVisiblePosition)
        XCTAssertFalse(ConversationPagingPositionOutcome.unapplied.recordsVisiblePosition)
        XCTAssertFalse(ConversationPagingPositionOutcome.cancelled.recordsVisiblePosition)
    }

    func testRestoreTimeoutOffersRetryWithoutReplacingTheSavedPosition() {
        XCTAssertTrue(ConversationRestoreOutcome.timedOut.preservesSavedPosition)
        XCTAssertTrue(ConversationRestoreOutcome.timedOut.offersLocalRetry)
        XCTAssertFalse(ConversationRestoreOutcome.confirmed.preservesSavedPosition)
        XCTAssertFalse(ConversationRestoreOutcome.confirmed.offersLocalRetry)
        XCTAssertTrue(ConversationRestoreOutcome.cancelled.preservesSavedPosition)
        XCTAssertFalse(ConversationRestoreOutcome.cancelled.offersLocalRetry)
    }

    @MainActor
    func testViewportMeasurementUnregistersOnlyItsOwnAnchor() {
        let measurement = ConversationViewportMeasurement()
        let anchor = UIView()
        let otherAnchor = UIView()

        measurement.register(anchor, itemID: "row")
        XCTAssertEqual(measurement.registeredAnchorCount, 1)

        measurement.unregister(otherAnchor, itemID: "row")
        XCTAssertEqual(measurement.registeredAnchorCount, 1)

        measurement.unregister(anchor, itemID: "row")
        XCTAssertEqual(measurement.registeredAnchorCount, 0)
    }

    func testShareFormatUsesConcreteImageTypesInsteadOfGenericImage() {
        XCTAssertEqual(
            AttachmentShareFormat(mimeType: "image/png", fileName: "photo.bin"),
            .png
        )
        XCTAssertEqual(
            AttachmentShareFormat(mimeType: "image/jpeg", fileName: "photo.bin"),
            .jpeg
        )
        XCTAssertEqual(
            AttachmentShareFormat(mimeType: "image/webp", fileName: "photo.bin"),
            .webp
        )
        XCTAssertEqual(
            AttachmentShareFormat(mimeType: "", fileName: "photo.PNG"),
            .png
        )

        XCTAssertEqual(UTType.png, AttachmentShareFormat.png.contentType)
        XCTAssertEqual(UTType.jpeg, AttachmentShareFormat.jpeg.contentType)
        XCTAssertEqual(
            AttachmentShareFormat.webp.contentType.preferredMIMEType,
            "image/webp"
        )
        XCTAssertNotEqual(UTType.image, AttachmentShareFormat.png.contentType)
    }

    func testShareFileNameTracksTheConcreteContentType() {
        XCTAssertEqual(
            AttachmentShareFormat.png.normalizedFileName("capture.png"),
            "capture.png"
        )
        XCTAssertEqual(
            AttachmentShareFormat.jpeg.normalizedFileName("capture.png"),
            "capture.jpg"
        )
        XCTAssertEqual(
            AttachmentShareFormat.webp.normalizedFileName("capture"),
            "capture.webp"
        )
    }
}
