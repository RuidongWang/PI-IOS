import Foundation

/// Validation for the short-lived `ppt2.` token printed by PI-adaptor.
public enum RACPPairingToken {
    public static func normalize(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count > "ppt2.".count,
              token.hasPrefix("ppt2."),
              !token.contains(where: { $0.isWhitespace })
        else {
            return nil
        }
        return token
    }
}
