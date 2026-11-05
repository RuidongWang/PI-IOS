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

// MARK: - URLSession delegate：拒绝所有重定向并执行 direct TLS challenge

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

final class DirectRACPSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let endpointHost: String
    let expectedCertificateSHA256: String
    let state: DirectRACPSessionState

    init(
        endpointHost: String,
        expectedCertificateSHA256: String,
        state: DirectRACPSessionState = DirectRACPSessionState()
    ) {
        self.endpointHost = endpointHost
        self.expectedCertificateSHA256 = expectedCertificateSHA256
        self.state = state
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
        let delegate = DirectRACPSessionDelegate(
            endpointHost: host,
            expectedCertificateSHA256: certificateSHA256,
            state: state
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        let socket = DirectRACPWebSocket(task: task, session: session, sessionDelegate: delegate)

        do {
            try await withTaskCancellationHandler {
                try await socket.confirmUpgrade()
            } onCancel: {
                task.cancel()
            }
            let negotiated = (task.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Sec-WebSocket-Protocol")
            guard negotiated == RACPWebSocket.subprotocol else {
                throw RACPConnectionError(category: .protocol)
            }
            socket.startReceiving()
            return socket
        } catch {
            let mapped = Self.map(error, task: task, state: state)
            await socket.close()
            throw mapped
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
        terminationState.finish(RACPSocketTermination(closeCode: 1000, reason: ""))
        session.finishTasksAndInvalidate()
    }

    public func waitUntilClosed() async {
        _ = await terminationError
    }

    private func confirmUpgrade() async throws {
        // task.resume() 本身不证明 Upgrade 成功；pong 只在 WS handshake 完成后到达。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
            task.resume()
        }
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

    private func finishRemotely(_ termination: RACPSocketTermination) {
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

    private static func map(
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

