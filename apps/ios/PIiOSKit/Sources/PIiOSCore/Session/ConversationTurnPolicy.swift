import Foundation

/// Stable turn boundaries for ordered host history within one host + session scope.
public enum ConversationTurnPolicy {
    /// Whether the earliest turn waiting for publication contains its task boundary.
    /// Item status is deliberately not treated as a turn terminal state.
    public static func hasTaskBoundary(_ items: [RACPItem]) -> Bool {
        guard let first = items.first else { return false }
        if first.role == "user" { return true }
        guard let turnID = Self.reliableTurnID(first.turnId) else { return false }

        // A reliable turn id allows an older page to begin in the middle of a turn,
        // but only the first contiguous segment belongs to that earliest turn.
        for item in items {
            guard Self.reliableTurnID(item.turnId) == turnID else { break }
            if item.role == "user" { return true }
        }
        return false
    }

    /// Leading items that belong to a turn whose start is older than the loaded
    /// window. The window can still be shown from the first user task onwards;
    /// the omitted tail stays reachable through explicit earlier-history loading.
    /// Returns 0 when the window already starts at a task boundary or contains
    /// no user item to anchor a visible task.
    public static func incompleteLeadingPrefixCount(_ items: [RACPItem]) -> Int {
        guard !items.isEmpty, !hasTaskBoundary(items) else { return 0 }
        return items.firstIndex { $0.role == "user" } ?? 0
    }

    /// Whether the window can be published after hiding a legacy leading prefix.
    ///
    /// PI-adaptor currently reports `turnId: null` for every historical item, so
    /// a page that starts in the middle of an older turn can never satisfy
    /// `hasTaskBoundary`; without this check the client walks the entire session
    /// backwards until it reaches the first item (a system message). The window
    /// is usable when its leading items have no reliable turn id and a user item
    /// exists later to cut at.
    public static func hasUsableTaskBoundary(_ items: [RACPItem]) -> Bool {
        guard let first = items.first else { return false }
        if hasTaskBoundary(items) { return true }
        guard first.role != "user", reliableTurnID(first.turnId) == nil else { return false }
        return items.contains { $0.role == "user" }
    }

    /// Input is ordered old → new and deduplicated by item id.
    public static func keys(for items: [RACPItem]) -> [String: String] {
        var keyer = ConversationTurnKeyer()
        var result: [String: String] = [:]
        result.reserveCapacity(items.count)
        for item in items {
            result[item.id] = keyer.key(itemID: item.id, role: item.role, turnID: item.turnId)
        }
        return result
    }

    private static func reliableTurnID(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return raw
    }
}

/// Stateful projection for an ordered old → new item sequence.
public struct ConversationTurnKeyer {
    private var currentKey: String?

    public init() {}

    public mutating func key(itemID: String, role: String?, turnID: String?) -> String {
        let reliableTurnID = turnID.flatMap { raw in
            raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
        }
        if role == "user" {
            currentKey = reliableTurnID.map { "turn:\($0)" } ?? "user:\(itemID)"
        } else if currentKey == nil {
            currentKey = reliableTurnID.map { "turn:\($0)" } ?? "legacy:\(itemID)"
        }
        // Once a turn starts, later/missing turn ids on non-user rows must not split it.
        return currentKey ?? "legacy:\(itemID)"
    }
}
