import Foundation
import NIOCore
import NIOPosix
import XCTest

@testable import PIiOSNet

/// These tests use real loopback NIO channels. They exercise the same
/// OPEN → CLOSING → CLOSED ordering used in production without any SSH
/// credentials, so they also run under SWIFTNIO_STRICT=1.
final class SSHShutdownLifecycleTests: XCTestCase {
    func testConcurrentCloseJoinsOneShutdownAndRejectsSubmissions() async throws {
        let fixture = try await LocalChannelFixture.make()
        let transport = fixture.transport

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { await transport.close() }
            }
            for await _ in group {}
        }

        XCTAssertFalse(transport.lifecycle.execute {})
        XCTAssertFalse(transport.lifecycle.executeCleanup {})
        XCTAssertFalse(
            transport.lifecycle.registerChild(UUID()) { Task {} },
            "a closing lifecycle must reject late children"
        )
        await fixture.shutdown()
    }

    func testReaderRequestedCloseDoesNotJoinItself() async throws {
        let fixture = try await LocalChannelFixture.make()
        let gate = AsyncGate()
        XCTAssertTrue(
            fixture.transport.lifecycle.registerChild(UUID()) {
                Task { await gate.wait() }
            }
        )

        let returned = XCTestExpectation(description: "reader-initiated close returned")
        let reader = Task {
            await RACPInboundContext.$socketID.withValue(
                ObjectIdentifier(fixture.clientChannel)
            ) {
                await fixture.transport.close()
                returned.fulfill()
            }
        }

        await fulfillment(of: [returned], timeout: 2)
        gate.open()
        await fixture.shutdown()
        await reader.value
    }

    func testBorrowedConnectionDoesNotCloseSuppliedTransport() async throws {
        let fixture = try await LocalChannelFixture.make()
        let socket = CountingSocket()
        let connection = RACPConnection(
            socket: socket,
            route: .ssh,
            transport: fixture.transport,
            ownsTransport: false
        )

        await connection.close()
        XCTAssertEqual(socket.closeCount, 1)
        XCTAssertTrue(
            fixture.transport.lifecycle.execute {},
            "borrowed SSH parent/group must stay open"
        )
        await fixture.shutdown()
    }

    func testOwnedConnectionClosesSocketOnceThenTransport() async throws {
        let fixture = try await LocalChannelFixture.make()
        let socket = CountingSocket()
        let connection = RACPConnection(
            socket: socket,
            route: .ssh,
            transport: fixture.transport,
            ownsTransport: true
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { await connection.close() }
            }
            for await _ in group {}
        }

        XCTAssertEqual(socket.closeCount, 1)
        XCTAssertFalse(fixture.transport.lifecycle.execute {})
        await fixture.shutdown()
    }

    func testCloseForcesChannelWhenCloseFrameFlushStalls() async throws {
        let fixture = try await LoopbackWebSocketFixture.make(closeGrace: 0.05)
        try await fixture.clientChannel.pipeline.addHandler(
            StallOutboundWritesHandler(),
            position: .first
        ).get()

        let started = ContinuousClock.now
        await fixture.socket.close()
        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        XCTAssertFalse(fixture.clientChannel.isActive)
        await fixture.shutdown()
    }

    func testReaderRequestedWebSocketCloseDoesNotJoinItself() async throws {
        let fixture = try await LoopbackWebSocketFixture.make(closeGrace: 0.02)
        let returned = XCTestExpectation(description: "reader-initiated socket close returned")
        let start = AsyncGate()
        let reader = Task {
            await start.wait()
            await RACPInboundContext.$socketID.withValue(
                ObjectIdentifier(fixture.socket)
            ) {
                await fixture.socket.close()
                returned.fulfill()
            }
        }
        fixture.socket.registerInboundReader(reader)
        start.open()

        await fulfillment(of: [returned], timeout: 2)
        let started = ContinuousClock.now
        await fixture.socket.close()
        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        await reader.value
        await fixture.shutdown()
    }

    func testConcurrentSocketCloseWritesOneCloseFrameAndJoinsOneCompletion() async throws {
        let fixture = try await LoopbackWebSocketFixture.make(closeGrace: 0.02)
        let closeFrames = LockedCounter()
        try await fixture.clientChannel.pipeline.addHandler(
            CountingCloseFrameOutboundHandler(counter: closeFrames),
            position: .first
        ).get()

        let started = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask { await fixture.socket.close() }
            }
            for await _ in group {}
        }

        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        XCTAssertEqual(closeFrames.value, 1)
        XCTAssertFalse(fixture.clientChannel.isActive)
        await fixture.shutdown()
    }

    func testPeerTerminationRequestsCleanupWithoutJoiningReader() async throws {
        let fixture = try await LoopbackWebSocketFixture.make(
            closeGrace: 0.02,
            closeAfterUpgrade: true
        )
        let reader = Task {
            for await _ in fixture.socket.inbound {}
        }
        fixture.socket.registerInboundReader(reader)

        _ = await fixture.socket.terminationError
        let started = ContinuousClock.now
        await fixture.socket.close()
        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        await reader.value
        await fixture.shutdown()
    }

    func testLocalCloseRemainsUserCancel() async throws {
        let fixture = try await LoopbackWebSocketFixture.make(closeGrace: 0.02)

        await fixture.socket.close()
        let termination = await fixture.socket.terminationError
        XCTAssertEqual(termination.category, .canceled)
        XCTAssertEqual(termination.closeCode, 1000)
        await fixture.shutdown()
    }

    func testAbortRecordsTransportInterruptedInsteadOfUserCancel() async throws {
        let fixture = try await LoopbackWebSocketFixture.make(closeGrace: 0.02)

        await fixture.socket.abort(.transportAborted)
        let termination = await fixture.socket.terminationError
        XCTAssertEqual(termination.category, .socketInterrupted)
        XCTAssertEqual(termination.closeCode, 1006)
        await fixture.shutdown()
    }

    func testRemoteCloseTerminationWinsOverLaterLocalCancel() async throws {
        let fixture = try await LoopbackWebSocketFixture.make(
            closeGrace: 0.02,
            closeFrameAfterUpgrade: (code: 1008, reason: "device revoked")
        )

        let remote = await fixture.socket.terminationError
        XCTAssertEqual(remote.category, .deviceRevoked)
        XCTAssertEqual(remote.closeCode, 1008)

        await fixture.socket.close()
        let afterLocalClose = await fixture.socket.terminationError
        XCTAssertEqual(
            afterLocalClose,
            remote,
            "a remote first terminal state must not be rewritten as a local cancel"
        )
        await fixture.shutdown()
    }

    func testCloseOwnerRemainsJoinableUntilPhysicalChannelCloses() async throws {
        let fixture = try await LoopbackWebSocketFixture.make(closeGrace: 0.001)
        let entered = XCTestExpectation(description: "event loop deliberately blocked")
        let unblock = DispatchSemaphore(value: 0)
        XCTAssertTrue(fixture.lifecycle.execute {
            entered.fulfill()
            // Fault injection only: a caller may leave while the owner must
            // retain cleanup until this real channel can physically close.
            _ = unblock.wait(timeout: .now() + 10)
        })
        await fulfillment(of: [entered], timeout: 2)
        let closed = LockedCounter()
        let waiter = Task {
            await fixture.socket.close()
            closed.increment()
        }
        do {
            try await withNetworkDeadline(
                seconds: 0.05,
                timeoutError: { RACPWebSocketError.closed }
            ) { await fixture.socket.close() }
            XCTFail("the caller's budget must expire while the event loop is blocked")
        } catch is RACPWebSocketError {}
        try await Task.sleep(for: .seconds(RACPWebSocket.closeJoinTimeout + 0.1))
        XCTAssertEqual(closed.value, 0, "physical close has not happened; owner cannot report completion")
        XCTAssertEqual(fixture.lifecycle.diagnosticsForTesting.children, 1)
        XCTAssertTrue(fixture.clientChannel.isActive)
        unblock.signal()
        await waiter.value
        XCTAssertEqual(closed.value, 1)
        XCTAssertFalse(fixture.clientChannel.isActive)
        await fixture.shutdown()
    }

    func testHundredLoopbackLifecyclesReturnChannelsAndReadersToBaseline() async throws {
        let started = ContinuousClock.now
        let activeReaders = LockedCounter()
        for round in 0..<100 {
            let fixture = try await LoopbackWebSocketFixture.make(closeGrace: 0.001)
            let closeFrames = LockedCounter()
            try await fixture.clientChannel.pipeline.addHandler(
                CountingCloseFrameOutboundHandler(counter: closeFrames),
                position: .first
            ).get()
            let readerStarted = AsyncGate()
            let reader = Task {
                await RACPInboundContext.$socketID.withValue(ObjectIdentifier(fixture.socket)) {
                    activeReaders.increment()
                    defer { activeReaders.decrement() }
                    readerStarted.open()
                    for await _ in fixture.socket.inbound {}
                    // A reader-triggered close races external joins. It must
                    // request cleanup and return rather than await its own join.
                    await fixture.socket.close()
                }
            }
            fixture.socket.registerInboundReader(reader)
            await readerStarted.wait()
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<12 {
                    group.addTask {
                        if index.isMultiple(of: 2) {
                            await fixture.socket.close()
                        } else {
                            await fixture.lifecycle.close()
                        }
                    }
                }
                for await _ in group {}
            }
            await reader.value
            let diagnostics = fixture.lifecycle.diagnosticsForTesting
            XCTAssertEqual(diagnostics.shutdownRuns, 1, "round \(round)")
            XCTAssertEqual(diagnostics.children, 0, "round \(round)")
            XCTAssertTrue(diagnostics.closed, "round \(round)")
            XCTAssertEqual(closeFrames.value, 1, "round \(round)")
            XCTAssertFalse(fixture.socket.hasInboundReaderForTesting, "round \(round)")
            XCTAssertEqual(activeReaders.value, 0, "round \(round)")
            XCTAssertFalse(fixture.clientChannel.isActive, "round \(round)")
            XCTAssertFalse(fixture.lifecycle.execute {}, "sealed owner must not submit")
            XCTAssertFalse(fixture.lifecycle.executeCleanup {}, "late callback must not submit")
            await fixture.shutdown()
            XCTAssertFalse(fixture.serverChannel.isActive, "round \(round)")
        }
        XCTAssertEqual(activeReaders.value, 0)
        XCTAssertLessThan(started.duration(to: .now), .seconds(60))
    }

    func testCloseAfterSealedLifecycleDoesNotScheduleOnShutdownLoop() async throws {
        let fixture = try await LoopbackWebSocketFixture.make(closeGrace: 0.02)
        fixture.lifecycle.removeChild(fixture.socket.lifecycleID)
        await fixture.lifecycle.close()
        XCTAssertFalse(fixture.clientChannel.isActive)

        // The lifecycle is sealed and its event loop is shut down. Scheduling
        // the close frame or falling back to channel.close() here would submit
        // to a dead loop; this must be a complete no-op.
        fixture.socket.scheduleCloseForTesting()
        await fixture.socket.close()

        fixture.serverChannel.close(promise: nil)
        try? await fixture.serverChannel.closeFuture.get()
        try? await fixture.serverGroup.shutdownGracefully()
    }
}

// MARK: - Fixtures

private final class LocalChannelFixture: @unchecked Sendable {
    let serverGroup: MultiThreadedEventLoopGroup
    let serverChannel: Channel
    let clientChannel: Channel
    let transport: SSHTransport

    private let lock = NSLock()
    private var didShutdown = false

    private init(
        serverGroup: MultiThreadedEventLoopGroup,
        serverChannel: Channel,
        clientChannel: Channel,
        transport: SSHTransport
    ) {
        self.serverGroup = serverGroup
        self.serverChannel = serverChannel
        self.clientChannel = clientChannel
        self.transport = transport
    }

    static func make() async throws -> LocalChannelFixture {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let serverChannel = try await ServerBootstrap(group: serverGroup)
                .serverChannelOption(ChannelOptions.backlog, value: 4)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeSucceededVoidFuture()
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            let port = try XCTUnwrap(serverChannel.localAddress?.port)
            let clientChannel = try await ClientBootstrap(group: clientGroup)
                .connect(host: "127.0.0.1", port: port)
                .get()
            let transport = SSHTransport.testing(
                channel: clientChannel,
                group: clientGroup
            )
            return LocalChannelFixture(
                serverGroup: serverGroup,
                serverChannel: serverChannel,
                clientChannel: clientChannel,
                transport: transport
            )
        } catch {
            try? await serverGroup.shutdownGracefully()
            try? await clientGroup.shutdownGracefully()
            throw error
        }
    }

    func shutdown() async {
        let shouldShutdown = lock.withLock { () -> Bool in
            guard !didShutdown else { return false }
            didShutdown = true
            return true
        }
        guard shouldShutdown else { return }
        await transport.close()
        serverChannel.close(promise: nil)
        try? await serverChannel.closeFuture.get()
        try? await serverGroup.shutdownGracefully()
    }
}

private final class LoopbackWebSocketFixture: @unchecked Sendable {
    let serverGroup: MultiThreadedEventLoopGroup
    let clientGroup: MultiThreadedEventLoopGroup
    let serverChannel: Channel
    let clientChannel: Channel
    let socket: RACPWebSocket
    let lifecycle: SSHConnectionLifecycle

    private let lock = NSLock()
    private var didShutdown = false

    private init(
        serverGroup: MultiThreadedEventLoopGroup,
        clientGroup: MultiThreadedEventLoopGroup,
        serverChannel: Channel,
        clientChannel: Channel,
        socket: RACPWebSocket,
        lifecycle: SSHConnectionLifecycle
    ) {
        self.serverGroup = serverGroup
        self.clientGroup = clientGroup
        self.serverChannel = serverChannel
        self.clientChannel = clientChannel
        self.socket = socket
        self.lifecycle = lifecycle
    }

    static func make(
        closeGrace: TimeInterval,
        closeAfterUpgrade: Bool = false,
        closeFrameAfterUpgrade: (code: Int, reason: String)? = nil
    ) async throws -> LoopbackWebSocketFixture {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var serverChannel: Channel?
        var clientChannel: Channel?
        do {
            let server = try await ServerBootstrap(group: serverGroup)
                .serverChannelOption(ChannelOptions.backlog, value: 4)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(
                        LoopbackWebSocketServerHandler(
                            closeAfterUpgrade: closeAfterUpgrade,
                            closeFrameAfterUpgrade: closeFrameAfterUpgrade
                        )
                    )
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            serverChannel = server
            let port = try XCTUnwrap(server.localAddress?.port)
            let client = try await ClientBootstrap(group: clientGroup)
                .connect(host: "127.0.0.1", port: port)
                .get()
            clientChannel = client
            // Only the lifecycle owner shuts the event loop down, matching
            // production ordering. Tearing the group down behind an open
            // lifecycle lets a late cleanup submit onto a dead loop.
            let lifecycle = SSHConnectionLifecycle(parent: client) {
                try? await clientGroup.shutdownGracefully()
            }
            let socket = try await RACPWebSocket.connect(
                on: client,
                lifecycle: lifecycle,
                bearerToken: nil,
                closeGrace: closeGrace
            )
            return LoopbackWebSocketFixture(
                serverGroup: serverGroup,
                clientGroup: clientGroup,
                serverChannel: server,
                clientChannel: client,
                socket: socket,
                lifecycle: lifecycle
            )
        } catch {
            clientChannel?.close(promise: nil)
            serverChannel?.close(promise: nil)
            try? await serverGroup.shutdownGracefully()
            try? await clientGroup.shutdownGracefully()
            throw error
        }
    }

    func shutdown() async {
        let shouldShutdown = lock.withLock { () -> Bool in
            guard !didShutdown else { return false }
            didShutdown = true
            return true
        }
        guard shouldShutdown else { return }
        await socket.close()
        // Joinable and idempotent: children, parent channel and event-loop
        // group are all closed once, inside the lifecycle owner.
        await lifecycle.close()
        serverChannel.close(promise: nil)
        try? await serverChannel.closeFuture.get()
        try? await serverGroup.shutdownGracefully()
    }
}

private final class LoopbackWebSocketServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let closeAfterUpgrade: Bool
    private let closeFrameAfterUpgrade: (code: Int, reason: String)?
    private var buffered = Data()
    private var upgraded = false

    init(
        closeAfterUpgrade: Bool,
        closeFrameAfterUpgrade: (code: Int, reason: String)? = nil
    ) {
        self.closeAfterUpgrade = closeAfterUpgrade
        self.closeFrameAfterUpgrade = closeFrameAfterUpgrade
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        buffered.append(contentsOf: buffer.readableBytesView)
        guard !upgraded else { return }

        let terminator = Data("\r\n\r\n".utf8)
        guard let range = buffered.range(of: terminator) else { return }
        let head = String(decoding: buffered[..<range.lowerBound], as: UTF8.self)
        buffered.removeSubrange(..<range.upperBound)

        guard let key = headerValue("sec-websocket-key", in: head) else {
            context.close(promise: nil)
            return
        }
        let accept = WebSocketHandshake.accept(for: key)
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "Sec-WebSocket-Protocol: \(RACPWebSocket.subprotocol)",
            "",
            "",
        ].joined(separator: "\r\n")
        var outbound = context.channel.allocator.buffer(capacity: response.utf8.count)
        outbound.writeString(response)
        context.writeAndFlush(NIOAny(outbound), promise: nil)
        upgraded = true

        if closeAfterUpgrade {
            context.eventLoop.scheduleTask(in: .milliseconds(250)) {
                context.close(promise: nil)
            }
        }
        if let closeFrameAfterUpgrade {
            context.eventLoop.scheduleTask(in: .milliseconds(10)) {
                Self.sendCloseFrame(closeFrameAfterUpgrade, context: context)
            }
        }
    }

    private static func sendCloseFrame(
        _ close: (code: Int, reason: String),
        context: ChannelHandlerContext
    ) {
        var payload = Data()
        payload.append(UInt8((close.code >> 8) & 0xFF))
        payload.append(UInt8(close.code & 0xFF))
        payload.append(contentsOf: Data(close.reason.utf8))
        var frame = Data([0x88])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        }
        frame.append(payload)
        var outbound = context.channel.allocator.buffer(capacity: frame.count)
        outbound.writeBytes(frame)
        context.writeAndFlush(NIOAny(outbound), promise: nil)
    }

    private func headerValue(_ name: String, in head: String) -> String? {
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name
            else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

private final class StallOutboundWritesHandler: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        // Intentionally drop the write (and leave non-nil promises pending) to
        // model a close-frame flush that never reaches the peer.
    }
}

private final class CountingCloseFrameOutboundHandler: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let counter: LockedCounter

    init(counter: LockedCounter) {
        self.counter = counter
    }

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        let buffer = unwrapOutboundIn(data)
        if let first = buffer.readableBytesView.first, first & 0x0F == 0x08 {
            counter.increment()
        }
        context.write(data, promise: promise)
    }
}

private final class CountingSocket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var closeCalls = 0
    private var closed = false

    init() {
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    var closeCount: Int {
        lock.withLock { closeCalls }
    }

    func send(text: String) async throws {}

    func close() async {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            closeCalls += 1
            return true
        }
        guard shouldClose else { return }
        continuation.finish()
    }

    func waitUntilClosed() async {
        await Task.yield()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    func decrement() {
        lock.withLock { count -= 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard !opened else { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func open() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !opened else { return [] }
            opened = true
            let waiters = self.waiters
            self.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
