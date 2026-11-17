import CryptoKit
import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import XCTest
import PIiOSCore
import PIiOSNet

@testable import PI_IOS

final class AttachmentImageLoaderTests: XCTestCase {
    private let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testMultiChunkReadUsesBoundedRequestsAndVerifiesDigest() async throws {
        let data = Self.patternedData(count: 5 * 1024 * 1024 + 17)
        let metadata = Self.makeAttachment(data: data)
        let probe = ReadProbe()
        let loader = AttachmentImageLoader()

        let output = try await loader.original(attachment: metadata) { offset, length in
            await probe.record(offset: offset, length: length)
            return Self.chunkResponse(data: data, attachment: metadata, offset: offset, length: length)
        }

        XCTAssertEqual(output, data)
        let calls = await probe.snapshot()
        XCTAssertGreaterThan(calls.count, 1)
        var expectedOffset = 0
        for (index, call) in calls.enumerated() {
            XCTAssertLessThanOrEqual(call.length, AttachmentImageLoader.chunkLimit)
            XCTAssertLessThan(((call.length + 2) / 3) * 4, 4 * 1024 * 1024)
            XCTAssertEqual(call.offset, expectedOffset)
            expectedOffset += call.length
            if index < calls.count - 1 {
                XCTAssertEqual(call.length, AttachmentImageLoader.chunkLimit)
            }
        }
        XCTAssertEqual(expectedOffset, data.count)
    }

    func testExactlyTwentyMiBIsAcceptedAtTheBoundary() async throws {
        let data = Data(count: AttachmentImageLoader.fileLimit)
        let metadata = Self.makeAttachment(data: data)
        let probe = ReadProbe()
        let loader = AttachmentImageLoader()

        let output = try await loader.original(attachment: metadata) { offset, length in
            await probe.record(offset: offset, length: length)
            return Self.chunkResponse(data: data, attachment: metadata, offset: offset, length: length)
        }

        XCTAssertEqual(output.count, AttachmentImageLoader.fileLimit)
        let calls = await probe.snapshot()
        XCTAssertEqual(calls.count, AttachmentImageLoader.fileLimit / AttachmentImageLoader.chunkLimit)
        XCTAssertTrue(calls.allSatisfy { $0.length <= AttachmentImageLoader.chunkLimit })
        XCTAssertEqual(calls.last?.length, AttachmentImageLoader.chunkLimit)
    }

    func testMetadataOverTwentyMiBIsRejectedBeforeAnyRead() async throws {
        let metadata = Self.makeAttachment(
            data: Data([0x01]),
            byteLength: AttachmentImageLoader.fileLimit + 1
        )
        let probe = ReadProbe()
        let loader = AttachmentImageLoader()

        do {
            _ = try await loader.original(attachment: metadata) { offset, length in
                await probe.record(offset: offset, length: length)
                return Self.chunkResponse(data: Data([0x01]), attachment: metadata, offset: offset, length: length)
            }
            XCTFail("超过 20 MiB 的附件必须在读取前失败")
        } catch let error as AttachmentImageError {
            XCTAssertEqual(error, .invalidMetadata)
        }
        let calls = await probe.snapshot()
        XCTAssertTrue(calls.isEmpty)
    }

    func testEmptyFileCompletesTransferButCannotDecodeAsImage() async throws {
        let metadata = Self.makeAttachment(data: Data())
        let loader = AttachmentImageLoader()

        let original = try await loader.original(attachment: metadata) { offset, length in
            Self.chunkResponse(data: Data(), attachment: metadata, offset: offset, length: length)
        }
        XCTAssertTrue(original.isEmpty)

        do {
            _ = try await loader.thumbnail(
                key: AttachmentImageKey(hostID: hostID, connectionID: ObjectIdentifier(self), attachment: metadata),
                attachment: metadata
            ) { offset, length in
                Self.chunkResponse(data: Data(), attachment: metadata, offset: offset, length: length)
            }
            XCTFail("0 字节附件不能解码为图片成功态")
        } catch let error as AttachmentImageError {
            XCTAssertEqual(error, .invalidImage)
        }
    }

    func testEmptyChunkBeforeEOFFails() async throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let metadata = Self.makeAttachment(data: data)
        let loader = AttachmentImageLoader()

        do {
            _ = try await loader.original(attachment: metadata) { _, _ in
                RACPV2AttachmentReadResult(attachment: metadata, dataBase64: "", eof: false)
            }
            XCTFail("非 EOF 的空块必须失败，不能无进展重试")
        } catch let error as AttachmentImageError {
            XCTAssertEqual(error, .invalidChunk)
        }
    }

    func testPositiveShortReadBeforeEOFContinues() async throws {
        let data = Data((0..<10).map { UInt8($0) })
        let metadata = Self.makeAttachment(data: data)
        let probe = ReadProbe()
        let loader = AttachmentImageLoader()

        let output = try await loader.original(attachment: metadata) { offset, length in
            await probe.record(offset: offset, length: length)
            return Self.chunkResponse(
                data: data,
                attachment: metadata,
                offset: offset,
                length: min(length, 3)
            )
        }

        XCTAssertEqual(output, data)
        let calls = await probe.snapshot()
        XCTAssertEqual(calls.map(\.offset), [0, 3, 6, 9])
    }

    func testReasonableShortReadsStayWithinRequestBudget() async throws {
        let data = Self.patternedData(count: 4 * 1024 * 1024)
        let metadata = Self.makeAttachment(data: data)
        let probe = ReadProbe()
        let loader = AttachmentImageLoader()

        let output = try await loader.original(attachment: metadata) { offset, length in
            await probe.record(offset: offset, length: length)
            return Self.chunkResponse(
                data: data,
                attachment: metadata,
                offset: offset,
                length: min(length, 32 * 1024)
            )
        }

        XCTAssertEqual(output, data)
        let calls = await probe.snapshot()
        XCTAssertEqual(calls.count, data.count / (32 * 1024))
        XCTAssertLessThan(calls.count, AttachmentImageLoader.maximumReadRequests)
        XCTAssertGreaterThanOrEqual(
            AttachmentImageLoader.maximumReadRequests,
            AttachmentImageLoader.fileLimit / (32 * 1024),
            "请求预算至少应允许 20 MiB 全程使用 32 KiB 短读"
        )
    }

    func testPathologicalOneByteShortReadsStopAtRequestBudget() async throws {
        XCTAssertEqual(AttachmentImageLoader.maximumReadRequests, 1_024)
        let data = Data(count: AttachmentImageLoader.fileLimit)
        let metadata = Self.makeAttachment(data: data)
        let probe = ReadProbe()
        let loader = AttachmentImageLoader()

        do {
            _ = try await loader.original(attachment: metadata) { offset, length in
                await probe.record(offset: offset, length: length)
                return RACPV2AttachmentReadResult(
                    attachment: metadata,
                    dataBase64: Data([0x00]).base64EncodedString(),
                    eof: false
                )
            }
            XCTFail("1 字节短读不能无限占用许可")
        } catch let error as AttachmentImageError {
            XCTAssertEqual(error, .readBudgetExceeded)
        }

        let calls = await probe.snapshot()
        XCTAssertEqual(calls.count, AttachmentImageLoader.maximumReadRequests)
        let metrics = await loader.metrics()
        XCTAssertEqual(metrics.active, 0)
        XCTAssertEqual(metrics.waiting, 0)
    }

    func testSlowShortReadsStopAtDurationBudget() async throws {
        XCTAssertEqual(AttachmentImageLoader.maximumReadDuration, 300)
        let clock = TestClock()
        let data = Data(count: AttachmentImageLoader.fileLimit)
        let metadata = Self.makeAttachment(data: data)
        let probe = ReadProbe()
        let loader = AttachmentImageLoader(now: { clock.now() })

        do {
            _ = try await loader.original(attachment: metadata) { offset, length in
                await probe.record(offset: offset, length: length)
                clock.advance(by: 60)
                return RACPV2AttachmentReadResult(
                    attachment: metadata,
                    dataBase64: Data([0x00]).base64EncodedString(),
                    eof: false
                )
            }
            XCTFail("总读取时长超过预算必须失败")
        } catch let error as AttachmentImageError {
            XCTAssertEqual(error, .readBudgetExceeded)
        }

        let calls = await probe.snapshot()
        XCTAssertEqual(calls.count, 6)
        XCTAssertLessThan(calls.count, AttachmentImageLoader.maximumReadRequests)
        let metrics = await loader.metrics()
        XCTAssertEqual(metrics.active, 0)
    }

    func testFullChunkWithoutEOFFails() async throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let metadata = Self.makeAttachment(data: data)
        let loader = AttachmentImageLoader()

        do {
            _ = try await loader.original(attachment: metadata) { _, _ in
                RACPV2AttachmentReadResult(
                    attachment: metadata,
                    dataBase64: data.base64EncodedString(),
                    eof: false
                )
            }
            XCTFail("累计长度已耗尽仍返回非 EOF 必须失败")
        } catch let error as AttachmentImageError {
            XCTAssertEqual(error, .invalidChunk)
        }
    }

    func testPrematureEOFFails() async throws {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let metadata = Self.makeAttachment(data: data)
        let loader = AttachmentImageLoader()

        do {
            _ = try await loader.original(attachment: metadata) { offset, length in
                Self.chunkResponse(
                    data: data.prefix(4),
                    attachment: metadata,
                    offset: offset,
                    length: min(length, 4),
                    eof: true
                )
            }
            XCTFail("EOF 时累计长度不足必须失败")
        } catch let error as AttachmentImageError {
            XCTAssertEqual(error, .invalidChunk)
        }
    }

    func testChunkOverrunFails() async throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let metadata = Self.makeAttachment(data: data)
        let loader = AttachmentImageLoader()

        do {
            _ = try await loader.original(attachment: metadata) { _, _ in
                RACPV2AttachmentReadResult(
                    attachment: metadata,
                    dataBase64: Data([0x01, 0x02, 0x03, 0x04, 0x05]).base64EncodedString(),
                    eof: true
                )
            }
            XCTFail("单块实际字节数超过请求长度必须失败")
        } catch let error as AttachmentImageError {
            XCTAssertEqual(error, .invalidChunk)
        }
    }

    func testMetadataIdentityMismatchFails() async throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let metadata = Self.makeAttachment(id: "target", data: data)
        let loader = AttachmentImageLoader()

        for field in ["id", "sessionId", "byteLength", "sha256", "state"] {
            var returned = metadata
            switch field {
            case "id": returned.id = "other"
            case "sessionId": returned.sessionId = "other-session"
            case "byteLength": returned.byteLength += 1
            case "sha256": returned.sha256 = String(repeating: "a", count: 64)
            case "state": returned.state = "uploading"
            default: break
            }
            do {
                _ = try await loader.original(attachment: metadata) { _, _ in
                    RACPV2AttachmentReadResult(
                        attachment: returned,
                        dataBase64: data.base64EncodedString(),
                        eof: true
                    )
                }
                XCTFail("\(field) 不一致必须失败")
            } catch let error as AttachmentImageError {
                XCTAssertEqual(error, .invalidMetadata, field)
            }
        }
    }

    func testSecondChunkMetadataMismatchFails() async throws {
        let data = Data(count: AttachmentImageLoader.chunkLimit + 1)
        let metadata = Self.makeAttachment(data: data)
        let probe = ReadProbe()
        let loader = AttachmentImageLoader()

        do {
            _ = try await loader.original(attachment: metadata) { offset, length in
                await probe.record(offset: offset, length: length)
                guard offset > 0 else {
                    return Self.chunkResponse(
                        data: data,
                        attachment: metadata,
                        offset: offset,
                        length: length
                    )
                }
                var returned = metadata
                returned.sha256 = String(repeating: "f", count: 64)
                return RACPV2AttachmentReadResult(
                    attachment: returned,
                    dataBase64: data.subdata(in: offset..<(offset + length)).base64EncodedString(),
                    eof: true
                )
            }
            XCTFail("第二块元数据不一致必须失败")
        } catch let error as AttachmentImageError {
            XCTAssertEqual(error, .invalidMetadata)
        }

        let calls = await probe.snapshot()
        XCTAssertEqual(calls.count, 2)
        let metrics = await loader.metrics()
        XCTAssertEqual(metrics.active, 0)
    }

    func testChunkMayDifferInNonIdentityMetadata() async throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let metadata = Self.makeAttachment(data: data)
        var returned = metadata
        returned.fileName = "server-copy.jpg"
        returned.mimeType = "image/jpeg"
        returned.kind = "output"
        returned.createdAt = "2025-01-01T00:00:00Z"
        let loader = AttachmentImageLoader()

        let output = try await loader.original(attachment: metadata) { _, _ in
            RACPV2AttachmentReadResult(
                attachment: returned,
                dataBase64: data.base64EncodedString(),
                eof: true
            )
        }

        XCTAssertEqual(output, data)
    }

    func testInvalidBase64Fails() async throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let metadata = Self.makeAttachment(data: data)
        let loader = AttachmentImageLoader()

        do {
            _ = try await loader.original(attachment: metadata) { _, _ in
                RACPV2AttachmentReadResult(attachment: metadata, dataBase64: "!!!!!!!!", eof: false)
            }
            XCTFail("非法 Base64 必须失败")
        } catch let error as AttachmentImageError {
            XCTAssertEqual(error, .invalidChunk)
        }
    }

    func testDigestMismatchFails() async throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let metadata = Self.makeAttachment(data: data, sha256: String(repeating: "0", count: 64))
        let loader = AttachmentImageLoader()

        do {
            _ = try await loader.original(attachment: metadata) { offset, length in
                Self.chunkResponse(data: data, attachment: metadata, offset: offset, length: length)
            }
            XCTFail("完整内容摘要不一致必须失败")
        } catch let error as AttachmentImageError {
            XCTAssertEqual(error, .invalidDigest)
        }
    }

    func testCancelledWaiterReleasesQueueWithoutConsumingPermit() async throws {
        let data = Data([0x01, 0x02, 0x03])
        let metadata = Self.makeAttachment(data: data)
        let loader = AttachmentImageLoader(concurrencyLimit: 1)
        let gate = ReadGate()

        let first = Task {
            try await loader.original(attachment: metadata) { offset, length in
                await gate.wait()
                return Self.chunkResponse(data: data, attachment: metadata, offset: offset, length: length)
            }
        }
        try await waitUntil {
            let metrics = await loader.metrics()
            return metrics.active == 1
        }

        let second = Task {
            try await loader.original(attachment: metadata) { offset, length in
                Self.chunkResponse(data: data, attachment: metadata, offset: offset, length: length)
            }
        }
        try await waitUntil {
            let metrics = await loader.metrics()
            return metrics.waiting == 1
        }

        second.cancel()
        try await waitUntil {
            let metrics = await loader.metrics()
            return metrics.waiting == 0
        }
        do {
            _ = try await second.value
            XCTFail("取消的等待者必须抛 CancellationError")
        } catch is CancellationError {
        }

        await gate.releaseAll()
        _ = try await first.value
        try await waitUntil {
            let metrics = await loader.metrics()
            return metrics.active == 0
        }
    }

    func testConcurrentJobsAreCappedAtTwoAndPeakIsReported() async throws {
        let data = Data([0x01, 0x02, 0x03])
        let metadata = Self.makeAttachment(data: data)
        let loader = AttachmentImageLoader(concurrencyLimit: 2)
        let gate = ReadGate()

        let tasks = (0..<6).map { _ in
            Task {
                try await loader.original(attachment: metadata) { offset, length in
                    await gate.wait()
                    return Self.chunkResponse(data: data, attachment: metadata, offset: offset, length: length)
                }
            }
        }

        try await waitUntil {
            let metrics = await loader.metrics()
            return metrics.active == 2
        }
        let saturated = await loader.metrics()
        XCTAssertEqual(saturated.active, 2)
        XCTAssertEqual(saturated.waiting, 4)
        XCTAssertEqual(saturated.peak, 2)

        for task in tasks { task.cancel() }
        await gate.releaseAll()
        for task in tasks { _ = try? await task.value }
        try await waitUntil {
            let metrics = await loader.metrics()
            return metrics.active == 0 && metrics.waiting == 0
        }
        let drained = await loader.metrics()
        XCTAssertEqual(drained.peak, 2)
    }

    func testCancelDuringActiveReadStopsNextChunkAndReleasesPermit() async throws {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let metadata = Self.makeAttachment(data: data)
        let key = AttachmentImageKey(
            hostID: hostID,
            connectionID: ObjectIdentifier(self),
            attachment: metadata
        )
        let loader = AttachmentImageLoader(concurrencyLimit: 1)
        let gate = ReadGate()
        let probe = ReadProbe()

        let task = Task {
            try await loader.thumbnail(key: key, attachment: metadata) { offset, length in
                await probe.record(offset: offset, length: length)
                await gate.wait()
                return Self.chunkResponse(
                    data: data,
                    attachment: metadata,
                    offset: offset,
                    length: min(length, 1)
                )
            }
        }

        try await waitUntil {
            let calls = await probe.snapshot()
            let metrics = await loader.metrics()
            return calls.count == 1 && metrics.active == 1
        }
        task.cancel()
        await gate.releaseAll()

        do {
            _ = try await task.value
            XCTFail("读取中被取消必须抛 CancellationError")
        } catch is CancellationError {
        }

        let calls = await probe.snapshot()
        XCTAssertEqual(calls.count, 1, "取消后不得再排下一块")
        let metrics = await loader.metrics()
        XCTAssertEqual(metrics.active, 0)
        XCTAssertEqual(metrics.waiting, 0)
        XCTAssertEqual(metrics.cachedCount, 0)
        XCTAssertEqual(metrics.cachedBytes, 0)
    }

    func testCancelDuringDecodeJoinsWorkerThenReleasesPermit() async throws {
        let data = try Self.pngData(width: 1_024, height: 1_024)
        let metadata = Self.makeAttachment(data: data)
        let control = DecodeControl()
        let loader = AttachmentImageLoader(concurrencyLimit: 1, decodeObserver: { _ in
            control.recordAndWait()
        })
        let key = AttachmentImageKey(
            hostID: hostID,
            connectionID: ObjectIdentifier(self),
            attachment: metadata
        )

        let task = Task {
            try await loader.thumbnail(key: key, attachment: metadata) { offset, length in
                Self.chunkResponse(
                    data: data,
                    attachment: metadata,
                    offset: offset,
                    length: length
                )
            }
        }

        try await waitUntil { control.hasEntered }
        task.cancel()
        try await Task.sleep(for: .milliseconds(50))
        let decoding = await loader.metrics()
        XCTAssertEqual(decoding.active, 1, "取消解码仍应等待 worker 结束并继续占用许可")

        control.releaseDecode()

        do {
            _ = try await task.value
            XCTFail("解码中被取消必须在 worker 结束后抛 CancellationError")
        } catch is CancellationError {
        }

        try await waitUntil {
            await loader.metrics().active == 0
        }
        let metrics = await loader.metrics()
        XCTAssertEqual(metrics.waiting, 0)
        XCTAssertEqual(metrics.cachedCount, 0)
        XCTAssertEqual(metrics.cachedBytes, 0)
    }

    func testThumbnailIsDecodedOffMainAndBoundedTo1024Pixels() async throws {
        let data = try Self.pngData(width: 8_000, height: 64)
        let metadata = Self.makeAttachment(data: data)
        let observer = DecodeThreadProbe()
        let loader = AttachmentImageLoader(decodeObserver: { observer.record(isMain: $0) })
        let token = NSObject()

        let bitmap = try await loader.thumbnail(
            key: AttachmentImageKey(
                hostID: hostID,
                connectionID: ObjectIdentifier(token),
                attachment: metadata
            ),
            attachment: metadata
        ) { offset, length in
            Self.chunkResponse(data: data, attachment: metadata, offset: offset, length: length)
        }

        XCTAssertFalse(observer.snapshot.first ?? true, "ImageIO 下采样必须在后台执行")
        let largestEdge = max(bitmap.image.width, bitmap.image.height)
        XCTAssertLessThanOrEqual(largestEdge, AttachmentImageLoader.thumbnailPixelLimit)
        XCTAssertLessThan(largestEdge, 8_000, "缩略图不能保留 8,000 像素原图尺寸")
        XCTAssertGreaterThan(bitmap.cost, 0)

        let metrics = await loader.metrics()
        XCTAssertEqual(metrics.cachedCount, 1)
        XCTAssertGreaterThan(metrics.cachedBytes, 0)
        XCTAssertLessThanOrEqual(metrics.cachedBytes, 32 * 1024 * 1024)
    }

    func testTwentyThumbnailLoadsShareTwoPermitsAndDownsampleEightKPixelSource() async throws {
        let data = try Self.pngData(width: 8_000, height: 64)
        let loader = AttachmentImageLoader(concurrencyLimit: 2)
        let gate = ReadGate()
        let token = NSObject()

        let tasks = (0..<20).map { index in
            let attachment = Self.makeAttachment(id: "concurrent-\(index)", data: data)
            let key = AttachmentImageKey(
                hostID: hostID,
                connectionID: ObjectIdentifier(token),
                attachment: attachment
            )
            return Task {
                try await loader.thumbnail(key: key, attachment: attachment) { offset, length in
                    await gate.wait()
                    return Self.chunkResponse(
                        data: data,
                        attachment: attachment,
                        offset: offset,
                        length: length
                    )
                }
            }
        }

        try await waitUntil {
            let metrics = await loader.metrics()
            return metrics.active == 2 && metrics.waiting == 18
        }
        let saturated = await loader.metrics()
        XCTAssertEqual(saturated.active, 2)
        XCTAssertEqual(saturated.peak, 2)

        await gate.releaseAll()

        var largestEdge = 0
        for task in tasks {
            let bitmap = try await task.value
            largestEdge = max(largestEdge, max(bitmap.image.width, bitmap.image.height))
        }
        XCTAssertLessThanOrEqual(largestEdge, AttachmentImageLoader.thumbnailPixelLimit)
        XCTAssertLessThan(largestEdge, 8_000)

        let metrics = await loader.metrics()
        XCTAssertEqual(metrics.active, 0)
        XCTAssertEqual(metrics.waiting, 0)
        XCTAssertEqual(metrics.peak, 2)
        XCTAssertEqual(metrics.cachedCount, 20)
        XCTAssertLessThanOrEqual(metrics.cachedBytes, 32 * 1024 * 1024)
    }

    func testThumbnailCacheEvictsToStayWithinBudget() async throws {
        let firstData = try Self.pngData(width: 64, height: 32, red: 0.1)
        let secondData = try Self.pngData(width: 64, height: 32, red: 0.8)
        let first = Self.makeAttachment(id: "first", data: firstData)
        let second = Self.makeAttachment(id: "second", data: secondData)
        let token = NSObject()
        let probeLoader = AttachmentImageLoader()
        let firstBitmap = try await probeLoader.thumbnail(
            key: AttachmentImageKey(
                hostID: hostID,
                connectionID: ObjectIdentifier(token),
                attachment: first
            ),
            attachment: first
        ) { offset, length in
            Self.chunkResponse(data: firstData, attachment: first, offset: offset, length: length)
        }
        let cacheLimit = firstBitmap.cost + firstBitmap.cost / 2
        let loader = AttachmentImageLoader(cacheLimit: cacheLimit)

        _ = try await loader.thumbnail(
            key: AttachmentImageKey(
                hostID: hostID,
                connectionID: ObjectIdentifier(token),
                attachment: first
            ),
            attachment: first
        ) { offset, length in
            Self.chunkResponse(data: firstData, attachment: first, offset: offset, length: length)
        }
        _ = try await loader.thumbnail(
            key: AttachmentImageKey(
                hostID: hostID,
                connectionID: ObjectIdentifier(token),
                attachment: second
            ),
            attachment: second
        ) { offset, length in
            Self.chunkResponse(data: secondData, attachment: second, offset: offset, length: length)
        }

        let metrics = await loader.metrics()
        XCTAssertLessThanOrEqual(metrics.cachedCount, 1)
        XCTAssertLessThanOrEqual(metrics.cachedBytes, cacheLimit)
    }

    func testThumbnailCacheIsScopedToHostIdentity() async throws {
        let data = try Self.pngData(width: 128, height: 64)
        let attachment = Self.makeAttachment(data: data)
        let loader = AttachmentImageLoader()
        let token = NSObject()
        let otherHostID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let probe = ReadProbe()

        let firstKey = AttachmentImageKey(
            hostID: hostID,
            connectionID: ObjectIdentifier(token),
            attachment: attachment
        )
        let otherKey = AttachmentImageKey(
            hostID: otherHostID,
            connectionID: ObjectIdentifier(token),
            attachment: attachment
        )

        _ = try await loader.thumbnail(key: firstKey, attachment: attachment) { offset, length in
            await probe.record(offset: offset, length: length)
            return Self.chunkResponse(data: data, attachment: attachment, offset: offset, length: length)
        }
        _ = try await loader.thumbnail(key: otherKey, attachment: attachment) { offset, length in
            await probe.record(offset: offset, length: length)
            return Self.chunkResponse(data: data, attachment: attachment, offset: offset, length: length)
        }
        let afterBothHosts = await probe.snapshot()
        XCTAssertEqual(afterBothHosts.count, 2, "不同 Host 不能共用缩略图缓存")

        _ = try await loader.thumbnail(key: firstKey, attachment: attachment) { offset, length in
            await probe.record(offset: offset, length: length)
            return Self.chunkResponse(data: data, attachment: attachment, offset: offset, length: length)
        }
        let afterCacheHit = await probe.snapshot()
        XCTAssertEqual(afterCacheHit.count, 2, "同一 Host 再次加载应命中缓存")
        let metrics = await loader.metrics()
        XCTAssertEqual(metrics.cachedCount, 2)
    }

    func testDetailReturnsVerifiedOriginalBytes() async throws {
        let data = try Self.pngData(width: 2_048, height: 1_024)
        let metadata = Self.makeAttachment(data: data)
        let loader = AttachmentImageLoader()

        let content = try await loader.detail(attachment: metadata) { offset, length in
            Self.chunkResponse(data: data, attachment: metadata, offset: offset, length: length)
        }

        XCTAssertEqual(content.original, data, "分享原图必须使用经过摘要校验的原始字节")
        XCTAssertLessThanOrEqual(
            max(content.bitmap.image.width, content.bitmap.image.height),
            AttachmentImageLoader.detailPixelLimit
        )
    }

    func testImageKeyIsolatesHostConnectionAndContentIdentity() {
        let data = Data([0x01, 0x02, 0x03])
        let attachment = Self.makeAttachment(data: data)
        let firstToken = NSObject()
        let secondToken = NSObject()

        let baseline = AttachmentImageKey(
            hostID: hostID,
            connectionID: ObjectIdentifier(firstToken),
            attachment: attachment
        )
        XCTAssertEqual(
            baseline,
            AttachmentImageKey(
                hostID: hostID,
                connectionID: ObjectIdentifier(firstToken),
                attachment: attachment
            )
        )
        XCTAssertNotEqual(
            baseline,
            AttachmentImageKey(
                hostID: UUID(),
                connectionID: ObjectIdentifier(firstToken),
                attachment: attachment
            )
        )
        XCTAssertNotEqual(
            baseline,
            AttachmentImageKey(
                hostID: hostID,
                connectionID: ObjectIdentifier(secondToken),
                attachment: attachment
            )
        )

        var changed = attachment
        changed.sha256 = String(repeating: "a", count: 64)
        XCTAssertNotEqual(
            baseline,
            AttachmentImageKey(
                hostID: hostID,
                connectionID: ObjectIdentifier(firstToken),
                attachment: changed
            )
        )
    }

    func testReadFailureMidTransferStopsNextChunkReturnsPermitAndDoesNotCache() async throws {
        let data = Self.patternedData(count: AttachmentImageLoader.chunkLimit * 2 + 17)
        let metadata = Self.makeAttachment(data: data)
        let key = AttachmentImageKey(hostID: hostID, connectionID: ObjectIdentifier(self), attachment: metadata)
        let loader = AttachmentImageLoader(concurrencyLimit: 1)
        let probe = ReadProbe()

        do {
            _ = try await loader.thumbnail(key: key, attachment: metadata) { offset, length in
                await probe.record(offset: offset, length: length)
                if offset > 0 { throw URLError(.networkConnectionLost) }
                return Self.chunkResponse(data: data, attachment: metadata, offset: offset, length: length)
            }
            XCTFail("途中断线必须传播失败，不能发布半张图")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }

        let calls = await probe.snapshot()
        XCTAssertEqual(calls.map(\.offset), [0, AttachmentImageLoader.chunkLimit], "抛错后不得排第三块")
        let failed = await loader.metrics()
        XCTAssertEqual(failed.active, 0)
        XCTAssertEqual(failed.waiting, 0)
        XCTAssertEqual(failed.cachedBytes, 0)
        XCTAssertEqual(failed.cachedCount, 0)

        // Exercise another real loader operation: the one available permit must
        // be usable after the failure, not merely reported as free by metrics.
        let recoveryData = Data([0x01, 0x02, 0x03])
        let recovery = Self.makeAttachment(id: "after-read-failure", data: recoveryData)
        let output = try await loader.original(attachment: recovery) { offset, length in
            Self.chunkResponse(data: recoveryData, attachment: recovery, offset: offset, length: length)
        }
        XCTAssertEqual(output, recoveryData)
        let recovered = await loader.metrics()
        XCTAssertEqual(recovered.active, 0)
        XCTAssertEqual(recovered.waiting, 0)
        XCTAssertEqual(recovered.cachedCount, 0)
    }

    // MARK: - Helpers

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0

        func now() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return time
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            time += interval
            lock.unlock()
        }
    }

    private final class DecodeControl: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var entered = false

        func recordAndWait() {
            lock.lock()
            entered = true
            lock.unlock()
            release.wait()
        }

        var hasEntered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return entered
        }

        func releaseDecode() {
            release.signal()
        }
    }

    private actor ReadProbe {
        struct Call: Sendable {
            let offset: Int
            let length: Int
        }

        private var calls: [Call] = []

        func record(offset: Int, length: Int) {
            calls.append(Call(offset: offset, length: length))
        }

        func snapshot() -> [Call] { calls }
    }

    private actor ReadGate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func releaseAll() {
            isOpen = true
            let pending = continuations
            continuations.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    private final class DecodeThreadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []

        func record(isMain: Bool) {
            lock.lock()
            values.append(isMain)
            lock.unlock()
        }

        var snapshot: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private struct WaitTimeout: Error {}

    private func waitUntil(
        timeout: TimeInterval = 8,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitTimeout()
    }

    private static func makeAttachment(
        id: String = "attachment-1",
        sessionID: String = "session-1",
        data: Data,
        sha256: String? = nil,
        byteLength: Int? = nil
    ) -> RACPV2Attachment {
        RACPV2Attachment(
            id: id,
            sessionId: sessionID,
            kind: "input",
            fileName: "image.png",
            mimeType: "image/png",
            byteLength: byteLength ?? data.count,
            sha256: sha256 ?? digest(data),
            state: "ready",
            createdAt: "2024-01-01T00:00:00Z"
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func patternedData(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<count {
                bytes[index] = UInt8((index &* 31) % 251)
            }
        }
        return data
    }

    private static func chunkResponse(
        data: Data,
        attachment: RACPV2Attachment,
        offset: Int,
        length: Int,
        eof: Bool? = nil
    ) -> RACPV2AttachmentReadResult {
        let safeOffset = min(max(0, offset), data.count)
        let available = max(0, data.count - safeOffset)
        let actualLength = min(max(0, length), available)
        let chunk = data.subdata(in: safeOffset..<(safeOffset + actualLength))
        return RACPV2AttachmentReadResult(
            attachment: attachment,
            dataBase64: chunk.base64EncodedString(),
            eof: eof ?? (safeOffset + chunk.count >= data.count)
        )
    }

    private static func pngData(
        width: Int,
        height: Int,
        red: CGFloat = 0.1
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageFixtureError.context
        }
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw ImageFixtureError.image
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw ImageFixtureError.destination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageFixtureError.finalize
        }
        return output as Data
    }

    private enum ImageFixtureError: Error {
        case context
        case image
        case destination
        case finalize
    }
}
