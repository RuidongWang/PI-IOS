import Foundation
import PIiOSCore
import XCTest

@testable import PIiOSNet

final class HostV2ClientLifecycleTests: XCTestCase {
    func testReplacingEventStreamFinishesPreviousStream() async {
        let client = HostV2Client()
        let first = await client.stream()
        _ = await client.stream()
        var iterator = first.makeAsyncIterator()
        let value = await iterator.next()
        XCTAssertNil(value)
        await client.close()
    }

    func testDisconnectFinishesPendingRequestAndEventStream() async throws {
        let socket = ClosingV2Socket()
        let client = HostV2Client()
        await client.attachForTesting(socket)
        let stream = await client.stream()
        let result = Task { try await client.request(.projectList, params: .object([:]), timeout: 10) }
        await fulfillment(of: [socket.sent], timeout: 2)
        await socket.close()
        do {
            _ = try await result.value
            XCTFail("请求应在连接关闭后失败")
        } catch let error as RACPV2Error {
            guard case .notConnected = error else { return XCTFail("错误类型不正确：\(error)") }
        }
        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        XCTAssertNil(value)
    }

    func testExternalCloseJoinsRegisteredReader() async throws {
        let socket = ReaderAwareV2Socket()
        let client = HostV2Client()
        await client.attachForTesting(socket)
        XCTAssertNotNil(socket.registeredReader, "attach must wire the inbound reader")

        await client.close()

        XCTAssertEqual(socket.closeCount, 1)
        XCTAssertTrue(socket.didJoinReader, "close must join the registered reader")
    }

    func testReaderCompletionClosesWithoutJoiningItself() async throws {
        let socket = ReaderAwareV2Socket()
        let client = HostV2Client()
        await client.attachForTesting(socket)

        socket.finishInbound()

        let deadline = ContinuousClock.now + .seconds(2)
        while socket.closeCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(socket.closeCount, 1)
        XCTAssertTrue(
            socket.wasClosedFromReader,
            "the reader must run with RACPInboundContext so close does not join itself"
        )
        await client.close()
    }
}

private final class ReaderAwareV2Socket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var reader: Task<Void, Never>?
    private var closeCalls = 0
    private var closed = false
    private var closedFromReader = false
    private var joinedReader = false

    init() {
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    var registeredReader: Task<Void, Never>? {
        lock.withLock { reader }
    }

    var closeCount: Int {
        lock.withLock { closeCalls }
    }

    var wasClosedFromReader: Bool {
        lock.withLock { closedFromReader }
    }

    var didJoinReader: Bool {
        lock.withLock { joinedReader }
    }

    func registerInboundReader(_ reader: Task<Void, Never>) {
        lock.withLock { self.reader = reader }
    }

    func send(text: String) async throws {}

    func close() async {
        let insideReader = RACPInboundContext.socketID == ObjectIdentifier(self)
        let reader = lock.withLock { () -> Task<Void, Never>? in
            guard !closed else { return nil }
            closed = true
            closeCalls += 1
            closedFromReader = insideReader
            return self.reader
        }
        guard let reader else { return }
        continuation.finish()
        guard !insideReader else { return }
        await reader.value
        lock.withLock { joinedReader = true }
    }

    func waitUntilClosed() async {}

    func finishInbound() {
        continuation.finish()
    }
}

private final class ClosingV2Socket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    let sent = XCTestExpectation(description: "request sent")
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    func send(text: String) async throws { sent.fulfill() }
    func close() async { continuation.finish() }
    func waitUntilClosed() async {}
}
