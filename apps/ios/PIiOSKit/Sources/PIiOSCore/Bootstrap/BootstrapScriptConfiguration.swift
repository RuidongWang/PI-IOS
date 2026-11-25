import Foundation

/// Inputs for the POSIX bootstrap script that runs on the target Linux host.
///
/// The script is generated entirely on the client. Every value that can reach a
/// shell is validated here and then emitted as a single-quoted shell literal.
public struct BootstrapScriptConfiguration: Equatable, Sendable {
    public static let defaultPairingLifetimeMilliseconds = 10 * 60 * 1_000
    public static let defaultReadyTimeoutSeconds = 90
    public static let defaultPairTimeoutSeconds = 12 * 60
    public static let defaultStopTimeoutSeconds = 20
    public static let defaultVerifyTimeoutSeconds = 90

    public let release: PIAdaptorRelease
    public let attemptId: String
    public let hostPlatform: String
    public let hostArchitecture: String
    public let port: Int
    public let pairingLifetimeMilliseconds: Int
    public let readyTimeoutSeconds: Int
    public let pairTimeoutSeconds: Int
    public let stopTimeoutSeconds: Int
    public let verifyTimeoutSeconds: Int
    /// 强制重装：命中本地 receipt 也重新下载并激活，用于「版本没变但字节变了」的场景。
    public let force: Bool
    public let direct: BootstrapDirectConfiguration?

    public init(
        release: PIAdaptorRelease,
        attemptId: String,
        hostPlatform: String = "linux",
        hostArchitecture: String,
        port: Int,
        pairingLifetimeMilliseconds: Int = BootstrapScriptConfiguration.defaultPairingLifetimeMilliseconds,
        readyTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultReadyTimeoutSeconds,
        pairTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultPairTimeoutSeconds,
        stopTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultStopTimeoutSeconds,
        verifyTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultVerifyTimeoutSeconds,
        force: Bool = false,
        direct: BootstrapDirectConfiguration? = nil
    ) throws {
        guard BootstrapScriptValidation.isAttemptId(attemptId) else {
            throw BootstrapScriptError.invalidAttemptId
        }
        guard (1...65_535).contains(port) else {
            throw BootstrapScriptError.invalidPort
        }
        let architecture = hostArchitecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hostPlatform.lowercased() == BootstrapPlatformProbe.supportedPlatform,
              BootstrapScriptValidation.isSafeLabel(hostPlatform),
              BootstrapScriptValidation.isSafeLabel(architecture),
              BootstrapPlatformProbe.target(forUnameMachine: architecture) == release.target else {
            throw BootstrapScriptError.invalidHostIdentity
        }
        guard (60_000...15 * 60 * 1_000).contains(pairingLifetimeMilliseconds) else {
            throw BootstrapScriptError.invalidPairingLifetime
        }
        for timeout in [
            readyTimeoutSeconds,
            pairTimeoutSeconds,
            stopTimeoutSeconds,
            verifyTimeoutSeconds,
        ] {
            guard (1...3_600).contains(timeout) else {
                throw BootstrapScriptError.invalidTimeout
            }
        }

        self.release = release
        self.attemptId = attemptId
        self.hostPlatform = hostPlatform.lowercased()
        self.hostArchitecture = architecture
        self.port = port
        self.pairingLifetimeMilliseconds = pairingLifetimeMilliseconds
        self.readyTimeoutSeconds = readyTimeoutSeconds
        self.pairTimeoutSeconds = pairTimeoutSeconds
        self.stopTimeoutSeconds = stopTimeoutSeconds
        self.verifyTimeoutSeconds = verifyTimeoutSeconds
        self.force = force
        self.direct = direct
    }
}

public enum BootstrapScriptError: Error, Equatable, CustomStringConvertible {
    case invalidAttemptId
    case invalidPort
    case invalidHostIdentity
    case invalidPairingLifetime
    case invalidTimeout
    case invalidDirectConfiguration

    public var description: String {
        switch self {
        case .invalidAttemptId:
            return "安装任务标识不合法。"
        case .invalidPort:
            return "端口必须在 1–65535 之间。"
        case .invalidHostIdentity:
            return "运行平台或架构不合法。"
        case .invalidPairingLifetime:
            return "配对令牌有效期必须在 1–15 分钟之间。"
        case .invalidTimeout:
            return "安装超时必须在 1–3600 秒之间。"
        case .invalidDirectConfiguration:
            return "直连主机必须是 DNS 或 IP，直连端口需与本地端口不同。"
        }
    }
}

enum BootstrapScriptValidation {
    private static let attemptCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )
    private static let labelCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )

    static func isAttemptId(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.utf8.count <= 96 && value.unicodeScalars.allSatisfy {
            $0.isASCII && attemptCharacters.contains($0)
        }
    }

    static func isSafeLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.unicodeScalars.allSatisfy {
            $0.isASCII && labelCharacters.contains($0)
        }
    }
}

