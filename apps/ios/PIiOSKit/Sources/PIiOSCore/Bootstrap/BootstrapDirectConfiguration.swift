import Foundation

/// Optional direct listener inputs for bootstrap. `directName` is used only for
/// OpenSSL SAN generation; it is never treated as runtime config or an endpoint.
public struct BootstrapDirectConfiguration: Equatable, Sendable {
    public let directName: String
    public let directPort: Int

    public init(directName: String, directPort: Int, loopbackPort: Int) throws {
        guard (1...65_535).contains(directPort), directPort != loopbackPort,
              let canonical = Self.canonicalDirectName(directName)
        else { throw BootstrapScriptError.invalidDirectConfiguration }
        self.directName = canonical
        self.directPort = directPort
    }

    public var sanExpression: String {
        if directName.contains(":") { return "IP:\(directName)" }
        let labels = directName.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return "IP:\(directName)"
        }
        return "DNS:\(directName)"
    }

    private static func canonicalDirectName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("://"), !value.contains("/"), !value.contains("@"),
              !value.contains("?"), !value.contains("#"), !value.contains("%"),
              !value.contains(where: { $0.isWhitespace })
        else { return nil }
        if value.contains(":") {
            // IPv6 input for SAN is the bare address (no brackets, port or zone).
            guard EndpointPolicy.ipv6Groups(value) != nil else { return nil }
            return value.lowercased()
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            for label in labels {
                guard let number = Int(label), (0...255).contains(number),
                      String(number) == label
                else { return nil }
            }
            return value
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard value.rangeOfCharacter(from: allowed.inverted) == nil,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }),
              labels.allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") })
        else { return nil }
        return value.lowercased()
    }
}
