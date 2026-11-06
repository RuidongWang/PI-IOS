import Foundation

// MARK: - 双通路公开状态（FROZEN direct-racp-ssh-fallback/1.0.0 §6–§9）

public enum ConnectionPreference: String, Codable, Sendable {
    case sshOnly
    case directPreferred
}

public enum ConnectionRoute: String, Codable, Sendable {
    case direct
    case ssh
}

public enum ConnectionFailureCategory: String, Codable, Equatable, Sendable {
    case configuration
    case offline
    case dns
    case tcp
    case connectTimeout
    case socketInterrupted
    case heartbeatFailed
    case tlsTrust
    case authentication
    case deviceRevoked
    case hostKey
    case hostIdentity
    case `protocol`
    case endpoint
    case permission
    case validation
    case notFound
    case conflict
    case rateLimited
    case providerUpstream
    case business
    case `internal`
    case canceled
}

public enum ConnectionPhase: Equatable, Sendable {
    case offline
    case connecting(ConnectionRoute)
    case handshaking(ConnectionRoute)
    case authenticating(ConnectionRoute)
    case verifyingIdentity(ConnectionRoute)
    case restoring(ConnectionRoute)
    case fallingBack
    case online(ConnectionRoute)
    case reconnecting(ConnectionRoute, attempt: Int, delay: TimeInterval)
    case failed
}

public struct RouteFailure: Equatable, Sendable {
    public var route: ConnectionRoute
    public var phase: ConnectionPhase
    public var category: ConnectionFailureCategory
    public var retryAfterMs: Int?

    public init(
        route: ConnectionRoute,
        phase: ConnectionPhase,
        category: ConnectionFailureCategory,
        retryAfterMs: Int? = nil
    ) {
        self.route = route
        self.phase = phase
        self.category = category
        self.retryAfterMs = retryAfterMs
    }
}

public struct ConnectionStatus: Equatable, Sendable {
    public var phase: ConnectionPhase
    public var activeRoute: ConnectionRoute?
    public var activeGeneration: UUID?
    public var candidateGeneration: UUID?
    public var promotionFenced: Bool
    public var directFailure: RouteFailure?
    public var sshFailure: RouteFailure?

    public init(
        phase: ConnectionPhase = .offline,
        activeRoute: ConnectionRoute? = nil,
        activeGeneration: UUID? = nil,
        candidateGeneration: UUID? = nil,
        promotionFenced: Bool = false,
        directFailure: RouteFailure? = nil,
        sshFailure: RouteFailure? = nil
    ) {
        self.phase = phase
        self.activeRoute = activeRoute
        self.activeGeneration = activeGeneration
        self.candidateGeneration = candidateGeneration
        self.promotionFenced = promotionFenced
        self.directFailure = directFailure
        self.sshFailure = sshFailure
    }
}

public struct RACPConnectionBudgets: Equatable, Sendable {
    public var directConnect: TimeInterval
    public var sshConnect: TimeInterval
    public var restore: TimeInterval

    public init(
        directConnect: TimeInterval = 8,
        sshConnect: TimeInterval = 20,
        restore: TimeInterval = 30
    ) {
        self.directConnect = directConnect
        self.sshConnect = sshConnect
        self.restore = restore
    }

    public static let `default` = RACPConnectionBudgets()
}

public struct DirectTLSTrustPin: Codable, Equatable, Sendable {
    public var hostId: String
    public var certificateSHA256: String
    public var authorizedAt: Date

    public init(hostId: String, certificateSHA256: String, authorizedAt: Date) {
        self.hostId = hostId
        self.certificateSHA256 = certificateSHA256
        self.authorizedAt = authorizedAt
    }
}

public struct DirectRACPConfiguration: Equatable, Sendable {
    public var endpoint: URL
    public var certificateSHA256: String
    public var adaptorHostId: String

    public init(endpoint: URL, certificateSHA256: String, adaptorHostId: String) {
        self.endpoint = endpoint
        self.certificateSHA256 = certificateSHA256
        self.adaptorHostId = adaptorHostId
    }
}

/// 非秘密的稳定传输错误。底层响应正文、Authorization 与 URL query 永不进入 description。
public struct RACPConnectionError: Error, Equatable, Sendable, CustomStringConvertible {
    public var category: ConnectionFailureCategory
    public var httpStatus: Int?
    public var retryAfterMs: Int?

    public init(
        category: ConnectionFailureCategory,
        httpStatus: Int? = nil,
        retryAfterMs: Int? = nil
    ) {
        self.category = category
        self.httpStatus = httpStatus
        self.retryAfterMs = retryAfterMs
    }

    public var description: String { "RACP connection failed: \(category.rawValue)" }
}

/// RFC 6455 单次终态。未知 reason 仅保留给结构化诊断，description 不回显远端文本。
public struct RACPSocketTermination: Error, Equatable, Sendable, CustomStringConvertible {
    public let closeCode: Int
    public let reason: String
    public let category: ConnectionFailureCategory

    public init(closeCode: Int, reason: String) {
        self.closeCode = closeCode
        self.reason = reason
        self.category = Self.category(for: closeCode, reason: reason)
    }

    init(closeCode: Int, reason: String, category: ConnectionFailureCategory) {
        self.closeCode = closeCode
        self.reason = reason
        self.category = category
    }

    public init(closePayload: Data) {
        guard closePayload.count >= 2 else {
            self.init(closeCode: 1006, reason: "")
            return
        }
        let code = Int(closePayload[closePayload.startIndex]) << 8
            | Int(closePayload[closePayload.index(after: closePayload.startIndex)])
        let reasonData = closePayload.dropFirst(2)
        guard let reason = String(data: reasonData, encoding: .utf8) else {
            self.init(closeCode: code, reason: "", category: .protocol)
            return
        }
        self.init(closeCode: code, reason: reason)
    }

    private static func category(for code: Int, reason: String) -> ConnectionFailureCategory {
        switch (code, reason) {
        case (1008, "device revoked"): return .deviceRevoked
        case (1008, "rate limited"): return .rateLimited
        case (1008, _): return .protocol
        case (1009, _): return .validation
        case (1003, _): return .protocol
        // 1000 是 WebSocket 的正常关闭，不代表用户主动 stop。SSH 与 Direct 的主动
        // 关闭路径都显式使用本地 `.canceled`；远端或中间设备发来的 1000 仍须重连。
        case (1000, _): return .socketInterrupted
        default: return .socketInterrupted
        }
    }

    public var description: String { "RACP socket terminated: \(category.rawValue) (\(closeCode))" }
}

/// 线程安全的单次终态；支持多个等待者，且只接受第一个结果。
final class RACPSocketTerminationState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RACPSocketTermination?
    private var waiters: [CheckedContinuation<RACPSocketTermination, Never>] = []

    func wait() async -> RACPSocketTermination {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// 已落定的终态（没有则为 nil），供 open 后立即 close/错误路径同步检查。
    func snapshot() -> RACPSocketTermination? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func finish(_ termination: RACPSocketTermination) {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return
        }
        value = termination
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: termination)
        }
    }
}
