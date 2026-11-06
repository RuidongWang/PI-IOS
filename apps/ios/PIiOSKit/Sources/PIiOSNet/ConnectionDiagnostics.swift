import Foundation
import os

// MARK: - 非秘密连接诊断

/// 一次连接意图内的稳定诊断事件。
///
/// 契约 §12 允许记录 route/phase/listener/耗时/HTTP status/稳定错误分类；禁止记录
/// Authorization、pdt/ppt、SSH 密码/私钥/passphrase、TLS 私钥、payload 正文、
/// 含秘密的完整 URL/query。因此本类型的字段只接受枚举、数字与固定短码。
public struct ConnectionDiagnosticEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// 状态机阶段变化（含 attempt 开始）。
        case phase
        /// 一次失败（分类 + 可选 HTTP status / close code）。
        case failure
        /// direct WSS 的 101 结论（delegate open 或失败）。
        case directOpen
        /// direct WSS 的关闭/终态（含 open 后立即 close）。
        case directClose
        /// SSH 建连里程碑（TCP 已连、握手/认证完成、通道打开、WS 升级）。
        case sshStage
        /// 收到了既无 id 也无 method、但带 error 的帧（以前被静默丢弃）。
        case droppedFrame
        /// 旧连接资源关闭（记录耗时，用于发现 teardown 卡死）。
        case teardown
    }

    public var timestamp: Date
    public var kind: Kind
    /// 本次意图/候选 generation 的非秘密短标识（UUID 前 8 位）。
    public var intent: String?
    public var route: ConnectionRoute?
    public var phase: String?
    public var elapsedMs: Int?
    public var category: ConnectionFailureCategory?
    public var httpStatus: Int?
    public var closeCode: Int?
    public var budgetSeconds: Double?
    /// 固定短码，例如 `gate.open`、`ssh.tcp-connected`。不得放入远端正文。
    public var detail: String?

    public init(
        timestamp: Date = Date(),
        kind: Kind,
        intent: String? = nil,
        route: ConnectionRoute? = nil,
        phase: String? = nil,
        elapsedMs: Int? = nil,
        category: ConnectionFailureCategory? = nil,
        httpStatus: Int? = nil,
        closeCode: Int? = nil,
        budgetSeconds: Double? = nil,
        detail: String? = nil
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.intent = intent
        self.route = route
        self.phase = phase
        self.elapsedMs = elapsedMs
        self.category = category
        self.httpStatus = httpStatus
        self.closeCode = closeCode
        self.budgetSeconds = budgetSeconds
        self.detail = detail
    }
}

/// os_log + 内存环形缓冲。缓冲用于在设备/模拟器上直接读取最近失败序列，
/// 补上「客户端侧没有可用失败日志」的缺口；os_log 让 Console.app / `log stream` 可过滤。
public final class ConnectionDiagnostics: @unchecked Sendable {
    public static let shared = ConnectionDiagnostics()

    private let logger = Logger(subsystem: "dev.piios.net", category: "racp")
    private let lock = NSLock()
    private var events: [ConnectionDiagnosticEvent] = []
    private let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    /// UUID 前 8 位：足够区分一次意图，且不含任何秘密。
    public static func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8)).lowercased()
    }

    /// `ContinuousClock` 时长转毫秒（负值归零）。
    public static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        let components = duration.components
        let milliseconds = components.seconds * 1000
            + components.attoseconds / 1_000_000_000_000_000
        return max(0, Int(milliseconds))
    }

    public func record(_ event: ConnectionDiagnosticEvent) {
        lock.lock()
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        lock.unlock()
        logger.debug(
            """
            racp event kind=\(event.kind.rawValue, privacy: .public) \
            detail=\(event.detail ?? "-", privacy: .public) \
            intent=\(event.intent ?? "-", privacy: .public) \
            route=\(event.route?.rawValue ?? "-", privacy: .public) \
            phase=\(event.phase ?? "-", privacy: .public) \
            elapsedMs=\(event.elapsedMs ?? -1, privacy: .public) \
            category=\(event.category?.rawValue ?? "-", privacy: .public) \
            httpStatus=\(event.httpStatus ?? -1, privacy: .public) \
            closeCode=\(event.closeCode ?? -1, privacy: .public) \
            budgetSeconds=\(event.budgetSeconds ?? -1, privacy: .public)
            """
        )
    }

    public func record(
        kind: ConnectionDiagnosticEvent.Kind,
        intent: String? = nil,
        route: ConnectionRoute? = nil,
        phase: String? = nil,
        elapsedMs: Int? = nil,
        category: ConnectionFailureCategory? = nil,
        httpStatus: Int? = nil,
        closeCode: Int? = nil,
        budgetSeconds: Double? = nil,
        detail: String? = nil
    ) {
        record(ConnectionDiagnosticEvent(
            kind: kind,
            intent: intent,
            route: route,
            phase: phase,
            elapsedMs: elapsedMs,
            category: category,
            httpStatus: httpStatus,
            closeCode: closeCode,
            budgetSeconds: budgetSeconds,
            detail: detail
        ))
    }

    public func snapshot() -> [ConnectionDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    public func clear() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
}

extension ConnectionPhase {
    /// 非秘密稳定名，用于诊断与测试断言。
    var diagnosticName: String {
        switch self {
        case .offline: return "offline"
        case .connecting(let route): return "connecting.\(route.rawValue)"
        case .handshaking(let route): return "handshaking.\(route.rawValue)"
        case .authenticating(let route): return "authenticating.\(route.rawValue)"
        case .verifyingIdentity(let route): return "verifyingIdentity.\(route.rawValue)"
        case .restoring(let route): return "restoring.\(route.rawValue)"
        case .fallingBack: return "fallingBack"
        case .online(let route): return "online.\(route.rawValue)"
        case .reconnecting(let route, let attempt, _): return "reconnecting.\(route.rawValue).\(attempt)"
        case .failed: return "failed"
        }
    }

    /// 阶段自带的 route（`offline`/`fallingBack`/`failed` 没有）。
    var diagnosticRoute: ConnectionRoute? {
        switch self {
        case .connecting(let route), .handshaking(let route), .authenticating(let route),
             .verifyingIdentity(let route), .restoring(let route), .online(let route),
             .reconnecting(let route, _, _):
            return route
        case .offline, .fallingBack, .failed:
            return nil
        }
    }
}
