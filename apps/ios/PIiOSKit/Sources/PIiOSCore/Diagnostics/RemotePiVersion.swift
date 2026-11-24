import Foundation

public struct RemotePiVersion: Equatable, Sendable {
    public let value: String
    public let isPrerelease: Bool
    private let parts: SemverParts

    public init?(_ text: String) {
        var version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") { version.removeFirst() }
        let pattern = #"\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z"#
        guard version.utf8.count <= 128, version.range(of: pattern, options: .regularExpression) != nil,
              let parts = SemverParts(version) else { return nil }
        self.value = version
        self.parts = parts
        self.isPrerelease = version.prefix { $0 != "+" }.contains("-")
    }

    public func needsUpgrade(to stable: Self) -> Bool {
        !stable.isPrerelease && (parts < stable.parts || (parts == stable.parts && isPrerelease))
    }
}
