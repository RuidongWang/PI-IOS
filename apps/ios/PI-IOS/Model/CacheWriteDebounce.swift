import Foundation

/// Trailing debounce with a hard maximum wait so continuous typing still saves.
struct CacheWriteDebounce {
    private var first: ContinuousClock.Instant?
    let quietPeriod: Duration = .milliseconds(400)
    let maximumWait: Duration = .seconds(1)

    mutating func delay(now: ContinuousClock.Instant = .now) -> Duration {
        if first == nil { first = now }
        return max(.zero, min(quietPeriod, maximumWait - first!.duration(to: now)))
    }

    mutating func reset() { first = nil }
}
