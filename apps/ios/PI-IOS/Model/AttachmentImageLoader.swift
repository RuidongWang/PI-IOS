import Foundation
import ImageIO
import CryptoKit
import Dispatch
import PIiOSCore

/// Immutable decoded pixels can cross the decode worker boundary. UIKit images
/// are created by the view on MainActor and never retained in this cache.
struct AttachmentBitmap: @unchecked Sendable {
    let image: CGImage
    var cost: Int { image.bytesPerRow * image.height }
}

struct AttachmentImageContent: Sendable {
    let bitmap: AttachmentBitmap
    /// Kept only by an open detail view, for sharing the verified original bytes.
    let original: Data
}

struct AttachmentImageKey: Hashable, Sendable {
    let hostID: UUID
    let connectionID: ObjectIdentifier
    let sessionID: String
    let attachmentID: String
    let sha256: String
    let byteLength: Int

    init(hostID: UUID, connectionID: ObjectIdentifier, attachment: RACPV2Attachment) {
        self.hostID = hostID
        self.connectionID = connectionID
        sessionID = attachment.sessionId
        attachmentID = attachment.id
        sha256 = attachment.sha256
        byteLength = attachment.byteLength
    }
}

enum AttachmentImageError: Error, Equatable {
    case invalidMetadata
    case invalidChunk
    case invalidDigest
    case invalidImage
    case readBudgetExceeded
}

/// One application-wide budget covers downloads AND decoding (including detail).
/// Waiting cancellation removes its continuation; every granted permit is returned.
actor AttachmentImageLoader {
    static let shared = AttachmentImageLoader()
    static let chunkLimit = 256 * 1024
    static let fileLimit = 20 * 1024 * 1024
    static let maximumReadRequests = 1_024
    static let maximumReadDuration: TimeInterval = 300
    static let thumbnailPixelLimit = 1024
    static let detailPixelLimit = 4096
    typealias Read = @Sendable (_ offset: Int, _ length: Int) async throws -> RACPV2AttachmentReadResult

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct Cached {
        let bitmap: AttachmentBitmap
        var access: UInt64
    }
    private let concurrencyLimit: Int
    private let cacheLimit: Int
    private let now: @Sendable () -> TimeInterval
    private let decodeObserver: (@Sendable (Bool) -> Void)?
    private var active = 0
    private var peak = 0
    private var waiters: [Waiter] = []
    private var cache: [AttachmentImageKey: Cached] = [:]
    private var cacheCost = 0
    private var clock: UInt64 = 0

    init(
        concurrencyLimit: Int = 2,
        cacheLimit: Int = 32 * 1024 * 1024,
        now: @escaping @Sendable () -> TimeInterval = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        },
        decodeObserver: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.concurrencyLimit = min(2, max(1, concurrencyLimit))
        self.cacheLimit = max(0, cacheLimit)
        self.now = now
        self.decodeObserver = decodeObserver
    }

    struct Metrics: Sendable {
        let active: Int
        let waiting: Int
        let peak: Int
        let cachedBytes: Int
        let cachedCount: Int
    }
    func metrics() -> Metrics {
        Metrics(active: active, waiting: waiters.count, peak: peak,
                cachedBytes: cacheCost, cachedCount: cache.count)
    }

    func thumbnail(key: AttachmentImageKey, attachment: RACPV2Attachment, read: @escaping Read) async throws -> AttachmentBitmap {
        try Task.checkCancellation()
        if var cached = cache[key] {
            clock &+= 1
            cached.access = clock
            cache[key] = cached
            return cached.bitmap
        }
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        // Another waiter may have completed this same key while we waited.
        if let cached = cache[key] { return cached.bitmap }
        let data = try await readOriginal(attachment: attachment, read: read)
        let bitmap = try await Self.decode(
            data,
            maximumPixel: Self.thumbnailPixelLimit,
            observer: decodeObserver
        )
        try Task.checkCancellation()
        insert(bitmap, for: key)
        return bitmap
    }

    func detail(attachment: RACPV2Attachment, read: @escaping Read) async throws -> AttachmentImageContent {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let data = try await readOriginal(attachment: attachment, read: read)
        let bitmap = try await Self.decode(
            data,
            maximumPixel: Self.detailPixelLimit,
            observer: decodeObserver
        )
        try Task.checkCancellation()
        return AttachmentImageContent(bitmap: bitmap, original: data)
    }

    /// Also used by regressions to exercise the production reassembly state machine
    /// at the exact 20 MiB boundary without requiring a 20 MiB image allocation.
    func original(attachment: RACPV2Attachment, read: @escaping Read) async throws -> Data {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await readOriginal(attachment: attachment, read: read)
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if active < concurrencyLimit {
            active += 1
            peak = max(peak, active)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // Ownership transfers directly to the resumed waiter; active is unchanged.
            waiters.removeFirst().continuation.resume()
        }
    }

    private func readOriginal(attachment: RACPV2Attachment, read: Read) async throws -> Data {
        // pi-adaptor stores attachment kind as input/output; older fixtures used image.
        let readableKinds: Set<String> = ["input", "output", "image"]
        guard readableKinds.contains(attachment.kind), attachment.mimeType.hasPrefix("image/"),
              attachment.state == "ready", (0...Self.fileLimit).contains(attachment.byteLength),
              attachment.sha256.count == 64,
              attachment.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw AttachmentImageError.invalidMetadata
        }
        let startedAt = now()
        var requestCount = 0
        var data = Data()
        data.reserveCapacity(attachment.byteLength)
        var digest = SHA256()
        repeat {
            try Task.checkCancellation()
            guard requestCount < Self.maximumReadRequests,
                  now() - startedAt <= Self.maximumReadDuration else {
                throw AttachmentImageError.readBudgetExceeded
            }
            requestCount += 1
            let remaining = attachment.byteLength - data.count
            // Empty files still need a response EOF, but will fail image decoding.
            let requested = min(Self.chunkLimit, max(1, remaining))
            let response = try await read(data.count, requested)
            try Task.checkCancellation()
            guard now() - startedAt <= Self.maximumReadDuration else {
                throw AttachmentImageError.readBudgetExceeded
            }
            guard Self.matchesIdentity(response.attachment, target: attachment) else {
                throw AttachmentImageError.invalidMetadata
            }
            // Bound before Base64 decoding as well, including hostile oversized data.
            let encodedLimit = ((requested + 2) / 3) * 4
            guard response.dataBase64.utf8.count <= encodedLimit,
                  let chunk = Data(base64Encoded: response.dataBase64),
                  chunk.count <= requested, chunk.count <= remaining else {
                throw AttachmentImageError.invalidChunk
            }
            data.append(chunk)
            digest.update(data: chunk)
            if response.eof {
                guard data.count == attachment.byteLength else { throw AttachmentImageError.invalidChunk }
                let actualDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
                guard actualDigest == attachment.sha256.lowercased() else { throw AttachmentImageError.invalidDigest }
                return data
            }
            guard !chunk.isEmpty, data.count < attachment.byteLength else { throw AttachmentImageError.invalidChunk }
        } while true
    }

    private static func matchesIdentity(
        _ response: RACPV2Attachment,
        target: RACPV2Attachment
    ) -> Bool {
        response.id == target.id
            && response.sessionId == target.sessionId
            && response.byteLength == target.byteLength
            && response.sha256.caseInsensitiveCompare(target.sha256) == .orderedSame
            && response.state == "ready"
    }

    private static func decode(
        _ data: Data,
        maximumPixel: Int,
        observer: (@Sendable (Bool) -> Void)?
    ) async throws -> AttachmentBitmap {
        let worker = Task.detached(priority: .userInitiated) { () throws -> AttachmentBitmap in
            try Task.checkCancellation()
            observer?(Thread.isMainThread)
            return try autoreleasepool {
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
                      CGImageSourceGetCount(source) > 0 else { throw AttachmentImageError.invalidImage }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixel,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                      image.width <= maximumPixel, image.height <= maximumPixel else {
                    throw AttachmentImageError.invalidImage
                }
                return AttachmentBitmap(image: image)
            }
        }
        // Join even on cancellation so decoding still occupies its global permit.
        return try await withTaskCancellationHandler {
            let bitmap = try await worker.value
            try Task.checkCancellation()
            return bitmap
        } onCancel: {
            worker.cancel()
        }
    }

    private func insert(_ bitmap: AttachmentBitmap, for key: AttachmentImageKey) {
        guard bitmap.cost <= cacheLimit else { return }
        if let replaced = cache.removeValue(forKey: key) { cacheCost -= replaced.bitmap.cost }
        while cacheCost + bitmap.cost > cacheLimit, let oldest = cache.min(by: { $0.value.access < $1.value.access }) {
            cacheCost -= oldest.value.bitmap.cost
            cache.removeValue(forKey: oldest.key)
        }
        clock &+= 1
        cache[key] = Cached(bitmap: bitmap, access: clock)
        cacheCost += bitmap.cost
    }
}
