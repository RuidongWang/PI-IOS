import CoreGraphics
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// SwiftUI named-space frames already use the visual viewport origin. Insets
/// belong only to UIKit content-offset conversion, never to frame confirmation.
enum ConversationViewportGeometry {
    static let restoreAlignmentTolerance: CGFloat = 2

    static func isAnchorAlignedAtViewportTop(
        measuredMinY: CGFloat,
        tolerance: CGFloat = ConversationViewportGeometry.restoreAlignmentTolerance
    ) -> Bool {
        abs(measuredMinY) <= tolerance
    }

    static func restoreContentOffsetY(
        anchorContentMinY: CGFloat,
        adjustedTopInset: CGFloat
    ) -> CGFloat {
        anchorContentMinY - adjustedTopInset
    }

    static func firstVisibleItemID(frames: [String: CGRect], viewportBottom: CGFloat) -> String? {
        frames.filter { $0.value.maxY > restoreAlignmentTolerance && $0.value.minY < viewportBottom }
            .min { $0.value.minY < $1.value.minY }?.key
    }

    static func viewportMinY(
        contentMinY: CGFloat,
        contentOffsetY: CGFloat
    ) -> CGFloat {
        contentMinY - contentOffsetY
    }

    /// The row anchor is installed after SwiftUI's top spacing, so paging must
    /// add that spacing back when preserving the original item's visual top.
    static func pagingContentMinY(
        anchorMinY: CGFloat,
        topSpacing: CGFloat
    ) -> CGFloat {
        anchorMinY + topSpacing
    }
}

/// Only an actually applied paging correction may replace the saved reading
/// position. A cancel or a timeout keeps the previous logical anchor intact.
enum ConversationPagingPositionOutcome: Equatable {
    case notInserted
    case applied
    case unapplied
    case cancelled

    var recordsVisiblePosition: Bool {
        self == .notInserted || self == .applied
    }
}

enum ConversationRestoreOutcome: Equatable {
    case confirmed
    case timedOut
    case cancelled

    var preservesSavedPosition: Bool {
        self != .confirmed
    }

    var offersLocalRetry: Bool {
        self == .timedOut
    }
}

enum AttachmentShareFormat: Equatable {
    case png
    case jpeg
    case webp

    init(mimeType: String, fileName: String) {
        let normalizedMime = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedMime {
        case "image/png":
            self = .png
            return
        case "image/jpeg", "image/jpg":
            self = .jpeg
            return
        case "image/webp":
            self = .webp
            return
        default:
            break
        }

        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "png":
            self = .png
        case "webp":
            self = .webp
        default:
            self = .jpeg
        }
    }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .webp: return WebPOriginalContentType.contentType
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .webp: return "webp"
        }
    }

    func normalizedFileName(_ original: String) -> String {
        let lastComponent = URL(fileURLWithPath: original)
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutExtension = (lastComponent as NSString).deletingPathExtension
        let stem = withoutExtension.isEmpty ? "image" : withoutExtension
        return "\(stem).\(fileExtension)"
    }
}

protocol AttachmentOriginalContentType: Sendable {
    static var contentType: UTType { get }
}

enum PNGOriginalContentType: AttachmentOriginalContentType {
    static let contentType = UTType.png
}

enum JPEGOriginalContentType: AttachmentOriginalContentType {
    static let contentType = UTType.jpeg
}

enum WebPOriginalContentType: AttachmentOriginalContentType {
    static let contentType = UTType(mimeType: "image/webp")
        ?? .data
}

/// Shares the verified original bytes with a concrete image UTI and a file
/// name that matches that UTI. The transferable never re-encodes the image.
struct AttachmentOriginal<ContentType: AttachmentOriginalContentType>: Transferable, Sendable {
    let data: Data
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: ContentType.contentType) { original in
            original.data
        }
        .suggestedFileName { original in
            original.fileName
        }
    }
}

/// Index window over newest-first cached entries. A saved reading anchor is
/// kept inside the first bounded window, without laying out the whole cache.
enum ConversationPreviewWindow {
    static func range(count: Int, anchorIndex: Int?, limit: Int = 80) -> Range<Int> {
        guard count > 0, limit > 0 else { return 0..<0 }
        let size = min(count, limit)
        let anchor = anchorIndex.flatMap { (0..<count).contains($0) ? $0 : nil }
        let start = anchor.map { max(0, min($0 - size / 2, count - size)) } ?? 0
        return start..<(start + size)
    }
}
