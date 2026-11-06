import CryptoKit
import Foundation
import Security

// MARK: - 实际叶证书固定 + anchor-only SecTrust

public enum DirectTLSTrustEvaluator {
    public static func evaluate(
        trust: SecTrust,
        endpointHost: String,
        expectedCertificateSHA256: String,
        verifyDate: Date = Date()
    ) throws {
        func reject() throws -> Never {
            throw RACPConnectionError(category: .tlsTrust)
        }

        guard let presented = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              presented.count == 1,
              let leaf = presented.first,
              isSelfSigned(leaf),
              isCertificateAuthorityFalse(leaf)
        else { try reject() }

        let der = SecCertificateCopyData(leaf) as Data
        let actualPin = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard isCanonicalPin(expectedCertificateSHA256),
              constantTimeEqual(Array(actualPin.utf8), Array(expectedCertificateSHA256.utf8))
        else { try reject() }

        // 必须使用本次实际呈现的同一 leaf 对象，禁止替换成预存 DER 或系统 CA。
        guard SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, endpointHost as CFString)) == errSecSuccess,
              SecTrustSetVerifyDate(trust, verifyDate as CFDate) == errSecSuccess
        else { try reject() }
        SecTrustSetNetworkFetchAllowed(trust, false)

        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { try reject() }
    }

    public static func certificateSHA256(_ certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalPin(_ pin: String) -> Bool {
        pin.count == 64
            && pin == pin.lowercased()
            && pin.allSatisfy { $0.isHexDigit }
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func isSelfSigned(_ certificate: SecCertificate) -> Bool {
        guard let subject = SecCertificateCopyNormalizedSubjectSequence(certificate),
              let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate)
        else { return false }
        // 最终签名自洽仍由下面的 SecTrust 求值验证；这里先排除明显非自签证书。
        return (subject as Data) == (issuer as Data)
    }

    private static func isCertificateAuthorityFalse(_ certificate: SecCertificate) -> Bool {
        // SecCertificateCopyValues is macOS-only. Parse the actual DER on all platforms.
        (try? DirectDERX509.criticalLeafCAFalse(SecCertificateCopyData(certificate) as Data)) == true
    }
}

// MARK: - URLSession delegate 共享状态

/// TLS/重定向结论必须优先于后续超时分类（契约 §4.2 第 5-6 条）。
final class DirectRACPSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var trustFailed = false
    private var redirectRejected = false

    func recordTrustFailure() {
        lock.lock(); trustFailed = true; lock.unlock()
    }

    func recordRedirect() {
        lock.lock(); redirectRejected = true; lock.unlock()
    }

    func category() -> ConnectionFailureCategory? {
        lock.lock()
        defer { lock.unlock() }
        if trustFailed { return .tlsTrust }
        if redirectRejected { return .endpoint }
        return nil
    }
}

// MARK: - 101 单次结算闸门

/// 升级成功的唯一判据是
/// `URLSessionWebSocketDelegate.urlSession(_:webSocketTask:didOpenWithProtocol:)`。
///
/// 不再用 `sendPing` 的 pong：pong 只是"服务端应用层还活着"的额外证据，单次丢失会被
/// 误判成 Upgrade 失败并触发 SSH 回退。open / 失败 / 取消 三者在这里锁内单次结算，
/// delegate 的迟到回调、URLSession 的错误回调与调用方取消不会互相覆盖。
final class DirectWebSocketOpenGate: @unchecked Sendable {
    enum Outcome: Equatable {
        case opened(negotiatedProtocol: String?)
        case failed(RACPConnectionError)
    }

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []
    private var opened = false

    /// open 是否已经发生（即使闸门已被取消先行结算）。
    var didOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func settleOpen(negotiatedProtocol: String?) {
        settle(.opened(negotiatedProtocol: negotiatedProtocol), opened: true)
    }

    func settleFailure(_ error: RACPConnectionError) {
        settle(.failed(error), opened: false)
    }

    func settleCanceled() {
        settle(.failed(RACPConnectionError(category: .canceled)), opened: false)
    }

    /// 任意次数、任意时刻可等待；已结算时立即返回同一结果。
    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func settle(_ value: Outcome, opened: Bool) {
        lock.lock()
        if opened { self.opened = true }
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = value
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }
}

// MARK: - URLSession delegate：拒绝所有重定向、执行 direct TLS challenge、结算 101

final class DirectRACPSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let endpointHost: String
    let expectedCertificateSHA256: String
    let state: DirectRACPSessionState
    let gate: DirectWebSocketOpenGate
    /// open 之后的 close/error 必须能写入 socket 终态；弱引用避免 session → delegate → socket 循环。
    private weak var socket: DirectRACPWebSocket?

    init(
        endpointHost: String,
        expectedCertificateSHA256: String,
        state: DirectRACPSessionState = DirectRACPSessionState(),
        gate: DirectWebSocketOpenGate = DirectWebSocketOpenGate()
    ) {
        self.endpointHost = endpointHost
        self.expectedCertificateSHA256 = expectedCertificateSHA256
        self.state = state
        self.gate = gate
        super.init()
    }

    func attach(socket: DirectRACPWebSocket) {
        self.socket = socket
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        state.recordRedirect()
        // 包括同 origin：不跟随、不转发 Authorization。
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        do {
            try DirectTLSTrustEvaluator.evaluate(
                trust: trust,
                endpointHost: endpointHost,
                expectedCertificateSHA256: expectedCertificateSHA256
            )
            completionHandler(.useCredential, URLCredential(trust: trust))
        } catch {
            state.recordTrustFailure()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: URLSessionWebSocketDelegate

    /// 101 成功的唯一判据。`protocol` 是服务端协商出的子协议（未协商为 nil）。
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        gate.settleOpen(negotiatedProtocol: `protocol`)
        ConnectionDiagnostics.shared.record(
            kind: .directOpen,
            phase: `protocol` == nil ? "open.no-protocol" : "open",
            detail: "gate.open"
        )
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let termination = RACPSocketTermination(
            closeCode: Int(closeCode.rawValue),
            reason: reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        )
        let opened = gate.didOpen
        if opened {
            // open 后立刻 close：必须在这里落终态，否则要等 handshake 的请求超时才失败。
            socket?.recordDelegateTermination(termination)
        } else {
            gate.settleFailure(RACPConnectionError(category: termination.category))
        }
        ConnectionDiagnostics.shared.record(
            kind: .directClose,
            category: termination.category,
            closeCode: termination.closeCode,
            detail: opened ? "close.after-open" : "close.before-open"
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let webSocketTask = task as? URLSessionWebSocketTask
        if gate.didOpen {
            // open 之后的传输错误：只要还没有终态，就按 1006 落定，别让上层等超时。
            guard socket?.terminationSnapshot() == nil else { return }
            guard let error else { return }
            let mapped = DirectRACPWebSocket.map(error, task: webSocketTask, state: state)
            socket?.recordDelegateTermination(
                RACPSocketTermination(closeCode: 1006, reason: "", category: mapped.category)
            )
            ConnectionDiagnostics.shared.record(
                kind: .directClose,
                category: mapped.category,
                closeCode: 1006,
                detail: "error.after-open"
            )
            return
        }
        guard error != nil || socket?.terminationSnapshot() == nil else { return }
        if let error {
            gate.settleFailure(DirectRACPWebSocket.map(error, task: webSocketTask, state: state))
        } else {
            gate.settleFailure(RACPConnectionError(category: .socketInterrupted))
        }
        ConnectionDiagnostics.shared.record(
            kind: .directOpen,
            category: state.category(),
            detail: "gate.failed"
        )
    }
}

// MARK: - 原生 WSS socket

public final class DirectRACPWebSocket: RACPSocket, @unchecked Sendable {
    public let inbound: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let terminationState = RACPSocketTerminationState()
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let sessionDelegate: DirectRACPSessionDelegate
    private let lock = NSLock()
    private var receiveTask: Task<Void, Never>?
    private var closed = false

    public static func validatedEndpoint(_ endpoint: URL) throws -> URL {
        guard endpoint.scheme == "wss",
              let host = endpoint.host,
              !host.isEmpty,
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              endpoint.path == RACPWebSocket.path,
              !endpoint.absoluteString.hasSuffix("/"),
              endpoint.port != 0,
              !endpoint.absoluteString.contains(where: { $0.isWhitespace })
        else { throw RACPConnectionError(category: .endpoint) }
        if let port = endpoint.port, !(1...65_535).contains(port) {
            throw RACPConnectionError(category: .endpoint)
        }
        return endpoint
    }

    static func authorizedRequest(endpoint: URL, bearerToken: String) throws -> URLRequest {
        let endpoint = try validatedEndpoint(endpoint)
        guard bearerToken.hasPrefix("pdt2."),
              !bearerToken.contains(where: { $0.isWhitespace })
        else { throw RACPConnectionError(category: .authentication) }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(RACPWebSocket.subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    public static func connect(
        endpoint: URL,
        bearerToken: String,
        certificateSHA256: String
    ) async throws -> DirectRACPWebSocket {
        let request = try authorizedRequest(endpoint: endpoint, bearerToken: bearerToken)
        guard let host = request.url?.host else { throw RACPConnectionError(category: .endpoint) }

        let state = DirectRACPSessionState()
        let gate = DirectWebSocketOpenGate()
        let delegate = DirectRACPSessionDelegate(
            endpointHost: host,
            expectedCertificateSHA256: certificateSHA256,
            state: state,
            gate: gate
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        let socket = DirectRACPWebSocket(task: task, session: session, sessionDelegate: delegate)
        delegate.attach(socket: socket)

        // 先 resume，再用 delegate 的 didOpenWithProtocol 判定 101；取消时必须自行结算闸门，
        // 否则预算到点后要等 URLSession 回调才能退出。
        let outcome = await withTaskCancellationHandler {
            task.resume()
            return await gate.wait()
        } onCancel: {
            gate.settleCanceled()
            task.cancel()
        }

        if case .failed(let error) = outcome {
            await socket.close()
            throw error
        }
        guard case .opened(let negotiatedProtocol) = outcome else {
            await socket.close()
            throw RACPConnectionError(category: .internal)
        }
        do {
            guard negotiatedProtocol == RACPWebSocket.subprotocol else {
                throw RACPConnectionError(category: .protocol)
            }
            socket.startReceiving()
            // open 后立刻 close（例如 1008 device revoked）必须在 connect 阶段暴露，
            // 否则 handshake 要等到请求超时才失败，且分类会退化成 socketInterrupted。
            if let termination = socket.terminationSnapshot() {
                throw termination
            }
            return socket
        } catch {
            await socket.close()
            if let termination = error as? RACPSocketTermination { throw termination }
            throw Self.map(error, task: task, state: state)
        }
    }

    private init(
        task: URLSessionWebSocketTask,
        session: URLSession,
        sessionDelegate: DirectRACPSessionDelegate
    ) {
        self.task = task
        self.session = session
        self.sessionDelegate = sessionDelegate
        var sink: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { sink = $0 }
        self.continuation = sink
    }

    public var terminationError: RACPSocketTermination {
        get async { await terminationState.wait() }
    }

    public func send(text: String) async throws {
        let isClosed = lock.withLock { closed }
        guard !isClosed else {
            // 已落定的远端终态（如 1008 device revoked）原样抛出：握手阶段若只剩
            // socketInterrupted，会触发一次没有意义的 SSH 回退。
            if let termination = terminationState.snapshot() { throw termination }
            throw RACPConnectionError(category: .socketInterrupted)
        }
        do {
            try await task.send(.string(text))
        } catch {
            throw Self.map(error, task: task, state: sessionDelegate.state)
        }
    }

    public func close() async {
        var reader: Task<Void, Never>?
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            reader = receiveTask
            receiveTask = nil
            return true
        }
        guard shouldClose else { return }

        task.cancel(with: .normalClosure, reason: nil)
        reader?.cancel()
        continuation.finish()
        terminationState.finish(RACPSocketTermination(closeCode: 1000, reason: "", category: .canceled))
        session.finishTasksAndInvalidate()
    }

    public func waitUntilClosed() async {
        _ = await terminationError
    }

    /// 已落定的终态（没有则为 nil）。用于 connect 在 open 后立刻发现远端 close。
    func terminationSnapshot() -> RACPSocketTermination? {
        terminationState.snapshot()
    }

    /// URLSession delegate 观察到的 open 后终态。与 `finishRemotely` 一样只结算一次，
    /// 这样 receiveLoop 尚未启动时也能让 `terminationError` 立刻可用。
    func recordDelegateTermination(_ termination: RACPSocketTermination) {
        finishRemotely(termination)
    }

    private func startReceiving() {
        lock.lock()
        guard receiveTask == nil, !closed else {
            lock.unlock()
            return
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        lock.unlock()
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    continuation.yield(Data(text.utf8))
                case .data:
                    let reason = Data("text only".utf8)
                    task.cancel(with: .unsupportedData, reason: reason)
                    finishRemotely(RACPSocketTermination(closeCode: 1003, reason: "text only"))
                    return
                @unknown default:
                    finishRemotely(RACPSocketTermination(closeCode: 1003, reason: "text only"))
                    return
                }
            }
        } catch {
            let code = Int(task.closeCode.rawValue)
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if task.closeCode != .invalid, code != 1006 {
                finishRemotely(RACPSocketTermination(closeCode: code, reason: reason))
            } else {
                let mapped = Self.map(error, task: task, state: sessionDelegate.state)
                finishRemotely(RACPSocketTermination(closeCode: 1006, reason: "", category: mapped.category))
            }
        }
    }

    fileprivate func finishRemotely(_ termination: RACPSocketTermination) {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        continuation.finish()
        terminationState.finish(termination)
        session.finishTasksAndInvalidate()
    }

    static func connectionError(forHTTPStatus status: Int) -> RACPConnectionError {
        switch status {
        case 300...399:
            return RACPConnectionError(category: .endpoint, httpStatus: status)
        case 400:
            return RACPConnectionError(category: .protocol, httpStatus: status)
        case 401, 403:
            return RACPConnectionError(category: .authentication, httpStatus: status)
        case 404, 426:
            return RACPConnectionError(category: .endpoint, httpStatus: status)
        case 429:
            return RACPConnectionError(category: .rateLimited, httpStatus: status)
        case 502, 503, 504:
            return RACPConnectionError(category: .tcp, httpStatus: status)
        case 101:
            return RACPConnectionError(category: .protocol, httpStatus: status)
        default:
            // 200/500/501 and every unlisted status are not transport failures.
            return RACPConnectionError(category: .internal, httpStatus: status)
        }
    }

    static func map(
        _ error: Error,
        task: URLSessionWebSocketTask?,
        state: DirectRACPSessionState
    ) -> RACPConnectionError {
        if let category = state.category() {
            return RACPConnectionError(category: category)
        }
        if let response = task?.response as? HTTPURLResponse {
            return connectionError(forHTTPStatus: response.statusCode)
        }
        if let error = error as? RACPConnectionError { return error }
        if Task.isCancelled { return RACPConnectionError(category: .canceled) }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .cannotFindHost, .dnsLookupFailed:
                return RACPConnectionError(category: .dns)
            case .timedOut:
                return RACPConnectionError(category: .connectTimeout)
            case .notConnectedToInternet:
                return RACPConnectionError(category: .offline)
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
                return RACPConnectionError(category: .tlsTrust)
            case .cancelled:
                return RACPConnectionError(category: .socketInterrupted)
            case .networkConnectionLost:
                return RACPConnectionError(category: .socketInterrupted)
            default:
                return RACPConnectionError(category: .tcp)
            }
        }
        return RACPConnectionError(category: .socketInterrupted)
    }
}

private struct DirectDERTLV {
    var tag: UInt8
    var content: Data
}

private struct DirectDERReader {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    var nextTag: UInt8? {
        index < data.endIndex ? data[index] : nil
    }

    var isAtEnd: Bool { index == data.endIndex }

    mutating func read(expectedTag: UInt8? = nil) throws -> DirectDERTLV {
        guard index < data.endIndex else { throw DirectDERError.malformed }
        let tag = data[index]
        index = data.index(after: index)
        if let expectedTag, tag != expectedTag { throw DirectDERError.malformed }
        guard index < data.endIndex else { throw DirectDERError.malformed }
        let first = data[index]
        index = data.index(after: index)
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard (1...4).contains(count), data.distance(from: index, to: data.endIndex) >= count else {
                throw DirectDERError.malformed
            }
            for _ in 0..<count {
                length = (length << 8) | Int(data[index])
                index = data.index(after: index)
            }
        }
        guard length >= 0, data.distance(from: index, to: data.endIndex) >= length else {
            throw DirectDERError.malformed
        }
        let end = data.index(index, offsetBy: length)
        let content = Data(data[index..<end])
        index = end
        return DirectDERTLV(tag: tag, content: content)
    }

    mutating func readBoolean() throws -> Bool {
        let value = try read(expectedTag: 0x01)
        guard value.content.count == 1, let byte = value.content.first else {
            throw DirectDERError.malformed
        }
        return byte != 0
    }
}

private enum DirectDERError: Error {
    case malformed
}

private enum DirectDERX509 {
    static func criticalLeafCAFalse(_ der: Data) throws -> Bool {
        var certificateReader = DirectDERReader(der)
        let certificate = try certificateReader.read(expectedTag: 0x30)
        var certificateFields = DirectDERReader(certificate.content)
        let tbs = try certificateFields.read(expectedTag: 0x30)
        var fields = DirectDERReader(tbs.content)
        if fields.nextTag == 0xA0 { _ = try fields.read() }
        for _ in 0..<6 { _ = try fields.read() }

        while let tag = fields.nextTag {
            let field = try fields.read()
            guard tag == 0xA3 else { continue }
            var extensionWrapper = DirectDERReader(field.content)
            let extensions = try extensionWrapper.read(expectedTag: 0x30)
            var extensionList = DirectDERReader(extensions.content)
            var result: Bool?
            while extensionList.nextTag != nil {
                let item = try extensionList.read(expectedTag: 0x30)
                var extensionFields = DirectDERReader(item.content)
                let oid = try extensionFields.read(expectedTag: 0x06)
                guard oid.content == Data([0x55, 0x1D, 0x13]) else { continue }
                guard result == nil else { throw DirectDERError.malformed }
                var critical = false
                if extensionFields.nextTag == 0x01 {
                    critical = try extensionFields.readBoolean()
                }
                let value = try extensionFields.read(expectedTag: 0x04)
                var constraintsReader = DirectDERReader(value.content)
                let constraints = try constraintsReader.read(expectedTag: 0x30)
                var constraintsFields = DirectDERReader(constraints.content)
                var isCA = false
                if constraintsFields.nextTag == 0x01 {
                    isCA = try constraintsFields.readBoolean()
                }
                result = critical && !isCA && constraintsFields.isAtEnd
            }
            return result ?? false
        }
        return false
    }
}

