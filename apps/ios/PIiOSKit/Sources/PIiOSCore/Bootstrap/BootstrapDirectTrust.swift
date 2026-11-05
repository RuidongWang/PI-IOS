import Foundation

public struct BootstrapDirectTrust: Equatable, Sendable {
    public let schemaVersion: Int
    public let attemptId: String
    public let hostId: String
    public let certificateSHA256: String
    public let notBefore: Date
    public let notAfter: Date

    private static let keys: Set<String> = [
        "schemaVersion", "attemptId", "hostId", "certificateSha256", "notBefore", "notAfter",
    ]

    public static func parse(data: Data, expectedAttemptId: String) throws -> BootstrapDirectTrust {
        guard data.count <= 4096,
              let text = String(data: data, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == keys,
              let schema = dictionary["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(),
              schema.intValue == 1,
              let attemptId = dictionary["attemptId"] as? String,
              attemptId == expectedAttemptId,
              BootstrapScriptValidation.isAttemptId(attemptId),
              let hostId = dictionary["hostId"] as? String,
              !hostId.isEmpty,
              !hostId.contains(where: { $0.isWhitespace }),
              let pin = dictionary["certificateSha256"] as? String,
              pin.count == 64,
              pin == pin.lowercased(),
              pin.allSatisfy(\.isHexDigit),
              let notBeforeText = dictionary["notBefore"] as? String,
              let notAfterText = dictionary["notAfter"] as? String,
              let notBefore = parseDate(notBeforeText),
              let notAfter = parseDate(notAfterText),
              notAfter > notBefore
        else { throw BootstrapDirectTrustError.invalid }
        return BootstrapDirectTrust(
            schemaVersion: 1,
            attemptId: attemptId,
            hostId: hostId,
            certificateSHA256: pin,
            notBefore: notBefore,
            notAfter: notAfter
        )
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

public enum BootstrapDirectTrustError: Error, Equatable, CustomStringConvertible {
    case invalid

    public var description: String { "DIRECT_TRUST_INVALID" }
}

public extension BootstrapRemoteCommand {
    static func readDirectTrust(attemptId: String) -> String {
        guard BootstrapScriptValidation.isAttemptId(attemptId) else { return "exit 64" }
        return #"path="$HOME/.pi-adaptor/.bootstrap/direct-trust.json"; if [ ! -e "$path" ]; then exit 0; fi; [ -f "$path" ] && [ ! -L "$path" ] || exit 73; [ "$(stat -c %u "$path")" = "$(id -u)" ] || exit 73; [ "$(stat -c %a "$path")" = "600" ] || exit 73; bytes=$(stat -c %s "$path") || exit 73; [ "$bytes" -le 4096 ] || exit 73; cat "$path""#
    }

    static func clearDirectTrust(attemptId: String) -> String {
        guard BootstrapScriptValidation.isAttemptId(attemptId) else { return "exit 0" }
        let expected = "'" + attemptId.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return #"path="$HOME/.pi-adaptor/.bootstrap/direct-trust.json"; [ -f "$path" ] || exit 0; actual=$(sed -n 's/.*"attemptId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$path" 2>/dev/null || true); [ "$actual" = \#(expected) ] && rm -f "$path" || true"#
    }
}
