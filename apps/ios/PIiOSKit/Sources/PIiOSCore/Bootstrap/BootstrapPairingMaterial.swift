import Foundation

/// Token material handed from the owner-only remote file to the pairing
/// callback. This value must never be logged or persisted on the client.
public struct BootstrapPairingMaterial: Codable, Equatable, Sendable {
    public let token: String
    public let expiresAt: Int64
    public let host: String
    public let port: Int

    public init(
        token: String,
        expiresAt: Int64,
        host: String,
        port: Int
    ) throws {
        guard token.hasPrefix("ppt2."),
              token.utf8.count > "ppt2.".count,
              token.unicodeScalars.allSatisfy({
                  $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
              }),
              host == "127.0.0.1" || host == "::1",
              (1...65_535).contains(port) else {
            throw BootstrapPairingMaterialError.invalid
        }
        self.token = token
        self.expiresAt = expiresAt
        self.host = host
        self.port = port
    }

    public var redactedDescription: String {
        "配对令牌（已隐藏），目标 \(host):\(port)"
    }
}

public enum BootstrapPairingMaterialError: Error, Equatable {
    case invalid
}
