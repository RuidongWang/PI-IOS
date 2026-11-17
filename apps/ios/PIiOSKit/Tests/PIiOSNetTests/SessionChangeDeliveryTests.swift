import Foundation
import PIiOSCore
import XCTest
@testable import PIiOSNet

final class SessionChangeDeliveryTests: XCTestCase {
    func testThousandInvalidationsCoalesceWhileReliableUpdatesKeepOrderAndCount() async throws {
        let client = makeClient()
        let stream = await client.stream()
        let collected = Task { await Self.labelsUntilEnd(stream) }
        await client.enableSessionChangeCoalescing()
        var expected = ["sessionChanged"]
        let info = RACPServerInfo(
            protocolVersion: "1.0", serverName: "test", serverVersion: "1",
            hostId: "host", connectionId: "connection", roles: ["owner"]
        )
        for index in 0..<1_000 {
            await client.emitUpdateForTesting(.sessionChanged)
            if index.isMultiple(of: 200) {
                let reliable: [RACPClientUpdate] = [
                    .event(RACPEvent(sequence: index, epoch: "epoch")),
                    .ready(info),
                    .hostSnapshot(projects: [], sessions: []),
                    .state(.online),
                    .error(code: .invalidArgument, message: "error_\(index)"),
                ]
                for update in reliable {
                    expected.append(Self.label(update))
                    await client.emitUpdateForTesting(update)
                }
            }
        }
        await client.emitUpdateForTesting(.error(code: .invalidArgument, message: "END"))
        let labels = try await withNetworkDeadline(
            seconds: 3, timeoutError: { InvalidationTestError() }
        ) { await collected.value }
        XCTAssertEqual(labels, expected)
        let statistics = await client.sessionChangeDeliveryStatisticsForTesting()
        XCTAssertEqual(statistics.deliveries, 1)
        XCTAssertEqual(statistics.coalesced, 1_000)
        XCTAssertEqual(statistics.queued, 1)
        await client.stop()
    }

    func testDirtyDuringConsumptionEmitsAgainAfterFinishWithoutLostWakeup() async throws {
        let client = makeClient()
        let stream = await client.stream()
        var iterator = stream.makeAsyncIterator()
        await client.enableSessionChangeCoalescing()
        let first = await iterator.next()
        XCTAssertEqual(first.map(Self.label), "sessionChanged")
        let receiptValue = await client.beginSessionChangeConsumption()
        let receipt = try XCTUnwrap(receiptValue)
        for _ in 0..<1_000 { await client.emitUpdateForTesting(.sessionChanged) }
        let before = await client.sessionChangeDeliveryStatisticsForTesting()
        XCTAssertEqual(before.deliveries, 1, "dirty changes must wait for the current refresh")
        XCTAssertTrue(before.consuming)
        await client.finishSessionChangeConsumption(receipt)
        let second = await iterator.next()
        XCTAssertEqual(second.map(Self.label), "sessionChanged")
        let nextValue = await client.beginSessionChangeConsumption()
        let next = try XCTUnwrap(nextValue)
        XCTAssertNotEqual(next, receipt)
        await client.finishSessionChangeConsumption(next)
        let after = await client.sessionChangeDeliveryStatisticsForTesting()
        XCTAssertEqual(after.deliveries, 2)
        XCTAssertEqual(after.queued, 0)
        XCTAssertFalse(after.consuming)
        // A stale/double acknowledgement cannot clear a subsequent invalidation.
        await client.emitUpdateForTesting(.sessionChanged)
        await client.finishSessionChangeConsumption(receipt)
        let third = await iterator.next()
        XCTAssertEqual(third.map(Self.label), "sessionChanged")
        let finalReceipt = await client.beginSessionChangeConsumption()
        XCTAssertNotNil(finalReceipt)
        if let finalReceipt { await client.finishSessionChangeConsumption(finalReceipt) }
        await client.stop()
    }

    func testNewConnectionGenerationDoesNotMergeAndOldReceiptCannotAcknowledgeIt() async throws {
        let client = makeClient()
        let stream = await client.stream()
        var iterator = stream.makeAsyncIterator()
        await client.enableSessionChangeCoalescing()
        _ = await iterator.next()
        let oldValue = await client.beginSessionChangeConsumption()
        let old = try XCTUnwrap(oldValue)
        await client.setOnlineForTesting() // existing seam installs a fresh generation
        await client.emitUpdateForTesting(.sessionChanged)
        await client.finishSessionChangeConsumption(old)
        let update = await iterator.next()
        XCTAssertEqual(update.map(Self.label), "sessionChanged")
        let newValue = await client.beginSessionChangeConsumption()
        let new = try XCTUnwrap(newValue)
        XCTAssertNotEqual(new, old)
        await client.finishSessionChangeConsumption(new)
        let statistics = await client.sessionChangeDeliveryStatisticsForTesting()
        XCTAssertEqual(statistics.deliveries, 2)
        XCTAssertEqual(statistics.queued, 0)
        await client.stop()
    }

    func testSessionClientAndAttachScopesNeverMergeOrAcceptRevokedReceipt() throws {
        let client = UUID()
        let generation = UUID()
        func key(_ session: String, client identity: UUID? = nil, attach: Int = 1) -> SessionChangeDelivery.Key {
            .init(client: identity ?? client, generation: generation, session: session, attachmentGeneration: attach)
        }
        var delivery = SessionChangeDelivery()
        XCTAssertTrue(delivery.invalidate(key("a")))
        XCTAssertTrue(delivery.invalidate(key("b")))
        XCTAssertNil(delivery.begin(key("b")), "the old queued signal must not consume the new receipt")
        let b = try XCTUnwrap(delivery.begin(key("b")))
        XCTAssertTrue(delivery.invalidate(key("b", attach: 2)))
        XCTAssertFalse(delivery.finish(b, key: key("b", attach: 2)))
        let next = try XCTUnwrap(delivery.begin(key("b", attach: 2)))
        let differentClient = key("b", client: UUID(), attach: 2)
        XCTAssertTrue(delivery.invalidate(differentClient))
        XCTAssertFalse(delivery.finish(next, key: differentClient))
        let last = try XCTUnwrap(delivery.begin(differentClient))
        XCTAssertFalse(delivery.finish(last, key: differentClient))
        XCTAssertEqual(delivery.statistics.deliveries, 4)
        XCTAssertEqual(delivery.statistics.queued, 0)
    }

    func testReducerFinalStateAndAllReliableEventsSurviveWithAndWithoutOptIn() async throws {
        for enabled in [false, true] {
            let client = makeClient()
            let stream = await client.stream()
            let collected = Task { await Self.labelsUntilEnd(stream) }
            if enabled { await client.enableSessionChangeCoalescing() }
            for sequence in 1...1_000 {
                let event = """
                {"jsonrpc":"2.0","method":"events/event","params":{"sequence":\(sequence),"epoch":"epoch","item":{"id":"item","kind":"message","text":"revision_\(sequence)"}}}
                """
                await client.receiveForTesting(Data(event.utf8))
            }
            let final = await client.sessionView()
            XCTAssertEqual(final.items.last?.text, "revision_1000")
            await client.emitUpdateForTesting(.error(code: .invalidArgument, message: "END"))
            let labels = try await withNetworkDeadline(
                seconds: 3, timeoutError: { InvalidationTestError() }
            ) { await collected.value }
            XCTAssertEqual(labels.filter { $0.hasPrefix("event:") }, (1...1_000).map { "event:\($0)" })
            XCTAssertEqual(labels.filter { $0 == "sessionChanged" }.count, enabled ? 1 : 1_000)
            let statistics = await client.sessionChangeDeliveryStatisticsForTesting()
            XCTAssertEqual(statistics.deliveries, enabled ? 1 : 0)
            await client.stop()
        }
    }

    private func makeClient() -> RACPClient {
        RACPClient(testingSocket: InvalidationSocket(), subscriptionId: nil, subscribedSessionId: "session")
    }

    private static func labelsUntilEnd(_ stream: AsyncStream<RACPClientUpdate>) async -> [String] {
        var labels: [String] = []
        for await update in stream {
            if case .error(_, let message) = update, message == "END" { break }
            labels.append(label(update))
        }
        return labels
    }

    private static func label(_ update: RACPClientUpdate) -> String {
        switch update {
        case .sessionChanged: return "sessionChanged"
        case .event(let event): return "event:\(event.sequence)"
        case .ready: return "ready"
        case .hostSnapshot: return "hostSnapshot"
        case .state: return "state"
        case .error(_, let message): return message ?? "error"
        case .hostChanged: return "hostChanged"
        }
    }
}

private struct InvalidationTestError: Error {}

private final class InvalidationSocket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    init() {
        let stream = AsyncStream<Data>.makeStream()
        inbound = stream.stream
        continuation = stream.continuation
    }
    func send(text: String) async throws {}
    func close() async { continuation.finish() }
    func waitUntilClosed() async {}
}
