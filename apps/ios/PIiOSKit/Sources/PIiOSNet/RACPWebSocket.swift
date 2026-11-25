import Foundation
import NIOCore
import CryptoKit

// MARK: - WebSocket over 已建立的 SSH direct-tcpip 通道

public enum RACPWebSocketError: Error, Equatable, CustomStringConvertible {
    case upgradeRejected(status: Int)
    case protocolViolation(String)
    case closed

    public var description: String {
        switch self {
        case .upgradeRejected(let status):
            return "WebSocket 升级被拒绝：HTTP \(status)"
        case .protocolViolation(let detail):
            return "WebSocket 协议异常：\(detail)"
        case .closed:
            return "WebSocket 连接已关闭"
        }
    }
}

/// 在一条已建立的字节流通道上完成 WebSocket 客户端握手，并收发**文本帧**。
///
/// 契约 §2.1：路径 `/v1/racp/ws`，升级请求必须携带子协议 `pi-racp.v1.jsonrpc`；
/// §2.3：设备令牌放 `Authorization: Bearer <token>` 请求头（不进 URL、不进日志）。
protocol RACPSocket: AnyObject {
    var inbound: AsyncStream<Data> { get }
    /// SSH 可报告完整消息之前的入站字节进度；不支持分块观测的通路保持 nil。
    var receiveProgress: RACPReceiveProgress? { get }
    /// 可等待的单次结构化终态；旧测试 socket 由默认实现兼容。
    var terminationError: RACPSocketTermination { get async }
    func send(text: String) async throws
    func close() async
    /// Terminates the socket with an explicit local intent. Failure recycling
    /// must not be recorded as a user cancel, otherwise the connection loop
    /// treats it as terminal and stops reconnecting.
    func abort(_ termination: RACPSocketTermination) async
    func waitUntilClosed() async
    func registerInboundReader(_ reader: Task<Void, Never>)
}

/// 仅保存字节计数和单调时钟，不保存报文或凭证。NIO 与 actor 通过锁内快照共享。
final class RACPReceiveProgress: @unchecked Sendable {
    struct Snapshot: Sendable {
        let bytes: UInt64
        let lastReceivedAt: ContinuousClock.Instant?
    }

    private let lock = NSLock()
    private var bytes: UInt64 = 0
    private var lastReceivedAt: ContinuousClock.Instant?

    func record(bytes count: Int) {
        guard count > 0 else { return }
        lock.lock()
        bytes &+= UInt64(count)
        lastReceivedAt = .now
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(bytes: bytes, lastReceivedAt: lastReceivedAt)
    }
}

extension RACPSocket {
    func registerInboundReader(_ reader: Task<Void, Never>) {}
    var receiveProgress: RACPReceiveProgress? { nil }

    /// Legacy/test sockets keep their old physical-close behavior. Production
    /// sockets override this to preserve the intended termination category.
    func abort(_ termination: RACPSocketTermination) async { await close() }

    var terminationError: RACPSocketTermination {
        get async {
            await waitUntilClosed()
            return RACPSocketTermination(closeCode: 1006, reason: "")
        }
    }
}

public final class RACPWebSocket: RACPSocket, @unchecked Sendable {
    /// 契约 §2.1 的上游常量。
    public static let path = "/v1/racp/ws"
    public static let subprotocol = "pi-racp.v2.jsonrpc"

    private let channel: Channel
    private let handler: WebSocketClientHandler
    private let lifecycle: SSHConnectionLifecycle
    let lifecycleID = UUID()
    private let closeTask = NetworkCloseTask()
    private let lock = NSLock()
    private var closing = false
    private var reader: Task<Void, Never>?
    private let socketClosed: NetworkResult<Void>
    private let closeGrace: TimeInterval
    private let continuation: AsyncStream<Data>.Continuation
    private let terminationState: RACPSocketTerminationState
    let receiveProgress: RACPReceiveProgress?
    /// 入站文本消息（已按帧拼回完整消息）。
    public let inbound: AsyncStream<Data>

    public static func connect(
        on channel: Channel,
        path: String = RACPWebSocket.path,
        subprotocol: String = RACPWebSocket.subprotocol,
        bearerToken: String?,
        timeout: TimeInterval = 10
    ) async throws -> RACPWebSocket {
        try await connect(
            on: channel,
            lifecycle: SSHConnectionLifecycle(parent: channel, shutdown: {}),
            path: path,
            subprotocol: subprotocol,
            bearerToken: bearerToken,
            timeout: timeout
        )
    }

    static func connect(
        on channel: Channel,
        lifecycle: SSHConnectionLifecycle,
        path: String = RACPWebSocket.path,
        subprotocol: String = RACPWebSocket.subprotocol,
        bearerToken: String?,
        timeout: TimeInterval = 10,
        closeGrace: TimeInterval = 0.2
    ) async throws -> RACPWebSocket {
        let key = WebSocketHandshake.makeKey()
        let request = WebSocketHandshake.request(
            path: path,
            hostHeader: "127.0.0.1",
            subprotocol: subprotocol,
            key: key,
            bearerToken: bearerToken
        )
        let expectedAccept = WebSocketHandshake.accept(for: key)
        let ready = channel.eventLoop.makePromise(of: Void.self)
        // Capture channel closure while the event loop is definitely alive. After
        // the owner seals the lifecycle and shuts the group down, awaiting NIO's
        // `closeFuture` would submit its completion to a dead loop: a logged
        // ERROR (fatalError under SWIFTNIO_STRICT) and, for `get()`, a wait that
        // can never be resumed.
        let socketClosed = NetworkResult<Void>()
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation = $0 }
        let terminationState = RACPSocketTerminationState()
        let receiveProgress = RACPReceiveProgress()
        let handler = WebSocketClientHandler(
            request: request,
            expectedAccept: expectedAccept,
            expectedSubprotocol: subprotocol,
            receiveProgress: receiveProgress,
            closeGrace: closeGrace,
            onText: { continuation.yield($0) },
            onTermination: { termination in
                terminationState.finish(termination)
            },
            onClosed: { termination in
                terminationState.finish(termination)
                continuation.finish()
            },
            ready: ready
        )
        try await channel.eventLoop.submit {
            channel.closeFuture.whenComplete { _ in socketClosed.succeed(()) }
            try channel.pipeline.syncOperations.addHandler(handler)
        }.get()
        do {
            try await withTimeout(seconds: timeout, phase: "WebSocket 升级") {
                try await handler.waitUntilUpgraded()
            }
        } catch {
            ConnectionDiagnostics.shared.record(kind: .sshStage, detail: "ws.upgrade-failed")
            // Same shutdown ordering as performClose: only submit the physical
            // close while the lifecycle still accepts cleanup. Once sealed the
            // owner has already closed the parent/child, so do not schedule on
            // a shut-down loop.
            if lifecycle.executeCleanup({ channel.close(promise: nil) }) {
                _ = try? await Self.joinClosed(socketClosed)
            }
            throw error
        }
        ConnectionDiagnostics.shared.record(kind: .sshStage, detail: "ws.upgraded")
        let socket = RACPWebSocket(
            channel: channel,
            handler: handler,
            inbound: stream,
            continuation: continuation,
            terminationState: terminationState,
            receiveProgress: receiveProgress,
            lifecycle: lifecycle,
            socketClosed: socketClosed,
            closeGrace: closeGrace
        )
        let registered = lifecycle.registerChild(socket.lifecycleID) { [weak socket] in
            socket?.requestClose() ?? Task {}
        }
        guard registered else {
            // The lifecycle owner is already shutting down. Request close but
            // do not join: cleanup may have been sealed, and the owner still
            // owns physical channel/parent teardown.
            _ = socket.requestClose(.localCanceled)
            throw RACPWebSocketError.closed
        }
        continuation.onTermination = { [weak socket] _ in
            _ = socket?.requestClose()
        }
        return socket
    }

    private init(
        channel: Channel,
        handler: WebSocketClientHandler,
        inbound: AsyncStream<Data>,
        continuation: AsyncStream<Data>.Continuation,
        terminationState: RACPSocketTerminationState,
        receiveProgress: RACPReceiveProgress,
        lifecycle: SSHConnectionLifecycle,
        socketClosed: NetworkResult<Void>,
        closeGrace: TimeInterval
    ) {
        self.channel = channel
        self.handler = handler
        self.inbound = inbound
        self.continuation = continuation
        self.terminationState = terminationState
        self.receiveProgress = receiveProgress
        self.lifecycle = lifecycle
        self.socketClosed = socketClosed
        self.closeGrace = closeGrace
    }

    public var terminationError: RACPSocketTermination {
        get async { await terminationState.wait() }
    }

    /// 发送一条文本帧（JSON-RPC 帧）。
    public func send(text: String) async throws {
        let frame = WebSocketFrame(opcode: .text, payload: Data(text.utf8))
        let bytes = try WebSocketFrameEncoder.encode(frame, maskKey: WebSocketFrameEncoder.randomMaskKey())
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        // Admission and the actual write submission share the same lock with
        // close scheduling. A text frame admitted before close is therefore
        // ordered before the close frame; a frame arriving after close can
        // never be written behind it.
        let write = lock.withLock { () -> EventLoopFuture<Void>? in
            guard !closing else { return nil }
            return channel.writeAndFlush(buffer)
        }
        guard let write else { throw RACPWebSocketError.closed }
        try await write.get()
    }

    /// Every caller joins the same completion. A caller inside the inbound reader
    /// only requests close and returns, so cleanup never joins that reader itself.
    public func close() async {
        await close(termination: .localCanceled)
    }

    func abort(_ termination: RACPSocketTermination) async {
        await close(termination: termination)
    }

    private func close(termination: RACPSocketTermination) async {
        let completion = requestClose(termination)
        if RACPInboundContext.socketID != ObjectIdentifier(self) {
            await completion.value
        }
    }

    /// 通道关闭（含对端断开）时恢复，用于驱动退避重连。
    public func waitUntilClosed() async {
        _ = try? await Self.joinClosed(socketClosed)
    }

    /// Upper bound for joining the physical close. It must outlive a normal
    /// grace-window force close but never hang cleanup forever.
    static let closeJoinTimeout: TimeInterval = 2

    /// Waits for the completion captured on the event loop at connect time.
    /// Never awaits NIO's `closeFuture` here: once the lifecycle owner has shut
    /// the group down, submitting that future's completion logs
    /// `Cannot schedule tasks on an EventLoop that has already shut down`
    /// (fatalError under SWIFTNIO_STRICT) and can leave the waiter suspended.
    private static func joinClosed(_ socketClosed: NetworkResult<Void>) async throws {
        try await withNetworkDeadline(
            seconds: closeJoinTimeout,
            timeoutError: { RACPWebSocketError.closed }
        ) {
            try await socketClosed.wait()
        }
    }

    func registerInboundReader(_ reader: Task<Void, Never>) {
        let cancel = lock.withLock { () -> Bool in
            guard !closing else { return true }
            self.reader = reader
            return false
        }
        if cancel { reader.cancel() }
    }

    @discardableResult
    fileprivate func requestClose(
        _ termination: RACPSocketTermination = .localCanceled
    ) -> Task<Void, Never> {
        // Enter CLOSING and settle the local termination in the same critical
        // section. The first result wins: a remote close already recorded by
        // the inbound handler must not be rewritten as a local user cancel.
        let shouldScheduleCloseFrame = lock.withLock { () -> Bool in
            guard !closing else { return false }
            closing = true
            terminationState.finish(termination)
            return true
        }
        // Called after the lock is released, so any send admitted before this
        // point has already submitted its write and the close frame follows it.
        if shouldScheduleCloseFrame {
            scheduleCloseFrameAndForce()
        }
        return closeTask.request { [self] in
            await performClose()
        }
    }

    private func performClose() async {
        let reader = lock.withLock { self.reader }
        reader?.cancel()
        continuation.finish()
        // The owner must not report CLOSED or unregister the child merely
        // because a caller's bounded wait expired. This replayable result was
        // captured while the loop was alive, so joining it submits no NIO work.
        // stopBestEffort/closeBounded can still stop waiting while this owned
        // cleanup task remains joinable until physical channel closure.
        _ = try? await socketClosed.wait()
        reader?.cancel()
        await reader?.value
        lock.withLock { self.reader = nil }
        lifecycle.removeChild(lifecycleID)
    }

    /// Closing must not await a close-frame flush. The frame is best effort and
    /// the channel is force-closed when the grace window expires.
    private func scheduleCloseFrameAndForce() {
        let scheduled = lifecycle.executeCleanup { [self] in
            // The lifecycle owner closes/seals the parent before shutting the
            // event loop down. Once cleanup is rejected or the channel is
            // already inactive there is nothing left to schedule; falling back
            // to channel.close() would submit to a possibly shut-down loop.
            guard channel.isActive else { return }
            let frame = WebSocketFrame(opcode: .close, payload: Data())
            if let bytes = try? WebSocketFrameEncoder.encode(
                frame,
                maskKey: WebSocketFrameEncoder.randomMaskKey()
            ) {
                var buffer = channel.allocator.buffer(capacity: bytes.count)
                buffer.writeBytes(bytes)
                channel.writeAndFlush(buffer, promise: nil)
            }
            let force: () -> Void = { channel.close(promise: nil) }
            if closeGrace > 0 {
                let milliseconds = Int64((closeGrace * 1_000).rounded(.up))
                channel.eventLoop.scheduleTask(in: .milliseconds(milliseconds), force)
            } else {
                force()
            }
        }
        _ = scheduled
    }

#if DEBUG
    var hasInboundReaderForTesting: Bool { lock.withLock { reader != nil } }

    /// Exercises the sealed-lifecycle close path without relying on
    /// nondeterministic callback ordering. Must be a no-op once cleanup is
    /// rejected; never fall back to scheduling on a shut-down loop.
    func scheduleCloseForTesting() {
        scheduleCloseFrameAndForce()
    }
#endif
}

// MARK: - 握手文本

enum WebSocketHandshake {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func makeKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64EncodedString()
    }

    static func accept(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    /// 渲染 HTTP/1.1 升级请求。令牌只出现在 `Authorization` 头里（契约 §2.3）。
    static func request(
        path: String,
        hostHeader: String,
        subprotocol: String,
        key: String,
        bearerToken: String?
    ) -> String {
        var lines = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeader)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: \(subprotocol)",
        ]
        if let bearerToken, !bearerToken.isEmpty {
            lines.append("Authorization: Bearer \(bearerToken)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    struct Response {
        var status: Int
        var headers: [String: String]
    }

    /// 解析手响应；`nil` 表示字节还不够。
    static func parse(_ data: Data) -> Response? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: terminator) else { return nil }
        let head = data[data.startIndex..<range.lowerBound]
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ")
        let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return Response(status: status, headers: headers)
    }
}

// MARK: - 通道 Handler

private final class WebSocketClientHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let request: String
    private let expectedAccept: String
    private let expectedSubprotocol: String
    private let receiveProgress: RACPReceiveProgress
    private let closeGrace: TimeInterval
    private let onText: @Sendable (Data) -> Void
    private let onTermination: @Sendable (RACPSocketTermination) -> Void
    private let onClosed: @Sendable (RACPSocketTermination) -> Void
    private let ready: EventLoopPromise<Void>
    private var buffered = Data()
    /// HTTP upgrade response headers are untrusted and can arrive in unbounded
    /// chunks before the terminating CRLFCRLF. Cap the pre-upgrade buffer.
    private static let maximumHandshakeBytes = 16 * 1024
    private var decoder = WebSocketFrameDecoder()
    private var upgraded = false
    private var upgradeFailure: Error?
    private var closeTermination: RACPSocketTermination?

    init(
        request: String,
        expectedAccept: String,
        expectedSubprotocol: String,
        receiveProgress: RACPReceiveProgress,
        closeGrace: TimeInterval,
        onText: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (RACPSocketTermination) -> Void,
        onClosed: @escaping @Sendable (RACPSocketTermination) -> Void,
        ready: EventLoopPromise<Void>
    ) {
        self.request = request
        self.expectedAccept = expectedAccept
        self.expectedSubprotocol = expectedSubprotocol
        self.receiveProgress = receiveProgress
        self.closeGrace = closeGrace
        self.onText = onText
        self.onTermination = onTermination
        self.onClosed = onClosed
        self.ready = ready
    }

    func waitUntilUpgraded() async throws {
        try await ready.futureResult.get()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if !upgraded {
            var buffer = context.channel.allocator.buffer(capacity: request.utf8.count)
            buffer.writeString(request)
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if upgraded { receiveProgress.record(bytes: buffer.readableBytes) }
        buffered.append(Data(buffer.readableBytesView))
        if !upgraded {
            if buffered.count > Self.maximumHandshakeBytes {
                upgradeFailure = RACPWebSocketError.protocolViolation("WebSocket 升级响应头超过上限")
                ready.fail(upgradeFailure!)
                context.close(promise: nil)
                return
            }
            guard let response = WebSocketHandshake.parse(buffered) else { return }
            let terminator = Data("\r\n\r\n".utf8)
            let consumed = buffered.range(of: terminator)!.upperBound
            let rest = buffered.suffix(from: consumed)
            buffered = Data(rest)
            guard response.status == 101 else {
                upgradeFailure = RACPWebSocketError.upgradeRejected(status: response.status)
                ready.fail(upgradeFailure!)
                context.close(promise: nil)
                return
            }
            guard response.headers["sec-websocket-accept"] == expectedAccept else {
                upgradeFailure = RACPWebSocketError.protocolViolation("Sec-WebSocket-Accept 不匹配")
                ready.fail(upgradeFailure!)
                context.close(promise: nil)
                return
            }
            if let negotiated = response.headers["sec-websocket-protocol"],
               negotiated != expectedSubprotocol {
                upgradeFailure = RACPWebSocketError.protocolViolation("子协议协商为 \(negotiated)")
                ready.fail(upgradeFailure!)
                context.close(promise: nil)
                return
            }
            upgraded = true
            ready.succeed(())
        }
        decoder.append(buffered)
        buffered = Data()
        do {
            for frame in try decoder.drainFrames() {
                switch frame.opcode {
                case .text:
                    onText(frame.payload)
                case .binary:
                    // 契约 §2.1：只接受文本帧，二进制帧以 1003 关闭。
                    recordTermination(
                        RACPSocketTermination(closeCode: 1003, reason: "text only")
                    )
                    var payload = context.channel.allocator.buffer(capacity: 2)
                    payload.writeInteger(UInt16(1003))
                    sendClose(context: context, payload: payload)
                case .ping:
                    sendPong(context: context, payload: frame.payload)
                case .close:
                    // Record the remote first terminal state as soon as it is
                    // observed, before a concurrent local close can settle the
                    // state as "canceled".
                    recordTermination(
                        RACPSocketTermination(closePayload: frame.payload)
                    )
                    context.close(promise: nil)
                case .pong, .continuation:
                    break
                }
            }
        } catch {
            upgradeFailure = error
            if case WebSocketFramingError.payloadTooLarge = error {
                recordTermination(
                    RACPSocketTermination(closeCode: 1009, reason: "payload too large")
                )
            } else {
                recordTermination(
                    RACPSocketTermination(closeCode: 1002, reason: "")
                )
            }
            context.close(promise: nil)
        }
    }

    private func recordTermination(_ termination: RACPSocketTermination) {
        if closeTermination == nil {
            closeTermination = termination
        }
        onTermination(termination)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !upgraded {
            ready.fail(upgradeFailure ?? RACPWebSocketError.closed)
        }
        onClosed(closeTermination ?? RACPSocketTermination(closeCode: 1006, reason: ""))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !upgraded {
            upgradeFailure = error
            ready.fail(error)
        }
        context.close(promise: nil)
    }

    private func sendPong(context: ChannelHandlerContext, payload: Data) {
        guard let bytes = try? WebSocketFrameEncoder.encode(
            WebSocketFrame(opcode: .pong, payload: payload),
            maskKey: WebSocketFrameEncoder.randomMaskKey()
        ) else { return }
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func sendClose(context: ChannelHandlerContext, payload: ByteBuffer) {
        var payload = payload
        let data = Data(payload.readableBytesView)
        payload.clear()
        guard let bytes = try? WebSocketFrameEncoder.encode(
            WebSocketFrame(opcode: .close, payload: data),
            maskKey: WebSocketFrameEncoder.randomMaskKey()
        ) else { return }
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)

        let force: () -> Void = { context.close(promise: nil) }
        if closeGrace > 0 {
            let milliseconds = Int64((closeGrace * 1_000).rounded(.up))
            context.eventLoop.scheduleTask(in: .milliseconds(milliseconds), force)
        } else {
            force()
        }
    }
}
