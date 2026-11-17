import Foundation

/// Correlates operation stages without logging payloads or credentials.
public struct PILogOperation: Sendable {
    public let id: String
    private let category: String
    private let name: String
    private let started: ContinuousClock.Instant

    public init(_ category: String, _ name: String, fields: String = "") {
        id = String(UUID().uuidString.prefix(8)).lowercased()
        self.category = category
        self.name = name
        started = ContinuousClock.now
        PILog.debug(category, "\(name) start \(fields) op=\(id)")
    }

    public var elapsedMilliseconds: Int {
        let value = started.duration(to: ContinuousClock.now).components
        return Int(value.seconds * 1_000 + value.attoseconds / 1_000_000_000_000_000)
    }

    public func finish(outcome: String, fields: String = "") {
        PILog.debug(category, "\(name) end \(fields) op=\(id) outcome=\(outcome) elapsedMs=\(elapsedMilliseconds)")
    }
}
