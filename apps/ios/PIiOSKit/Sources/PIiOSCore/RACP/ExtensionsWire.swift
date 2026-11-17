import Foundation

/// Extension states remain strings so newer Host states do not break older clients.
public struct RACPExtensionDiagnostic: Codable, Equatable, Sendable {
    public var stage: String
    public var severity: String
    public var code: String
    public var message: String
    public var occurredAt: String
}

public struct RACPExtensionInventoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var configuredVersion: String?
    public var entryPath: String
    public var enabled: Bool
    public var compatibility: String
    public var entryState: String
    public var diagnostics: [RACPExtensionDiagnostic]
}

public struct RACPExtensionRuntimeEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var configuredVersion: String?
    public var loadState: String
    public var skipReason: String?
    public var registeredTools: [String]
    public var activeTools: [String]
    public var registeredCommands: [String]
    public var mobileInvocable: Bool
    public var diagnostics: [RACPExtensionDiagnostic]
}

public struct RACPExtensionSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var hostId: String
    public var sessionId: String
    public var turnId: String
    public var configRevision: String
    public var revision: Int
    public var startedAt: String
    public var completedAt: String?
    public var phase: String
    public var entries: [RACPExtensionRuntimeEntry]
    public var diagnostics: [RACPExtensionDiagnostic]

    public var loadedCount: Int { entries.filter { $0.loadState == "loaded" }.count }
    public var failedCount: Int { entries.filter { $0.loadState == "failed" }.count }
}

public struct RACPExtensionInventory: Codable, Equatable, Sendable {
    public var hostId: String
    public var configRevision: String
    public var userLoadingEnabled: Bool
    public var capturedAt: String
    public var entries: [RACPExtensionInventoryEntry]
}

public struct RACPSessionExtensions: Codable, Equatable, Sendable {
    public var hostId: String
    public var sessionId: String
    public var configRevision: String
    public var userLoadingEnabled: Bool
    public var runningTurnId: String?
    public var latestAttempt: RACPExtensionSnapshot?
    public var previousCompleted: RACPExtensionSnapshot?

    public init(hostId: String, sessionId: String, configRevision: String, userLoadingEnabled: Bool,
                runningTurnId: String?, latestAttempt: RACPExtensionSnapshot?, previousCompleted: RACPExtensionSnapshot?) {
        self.hostId = hostId
        self.sessionId = sessionId
        self.configRevision = configRevision
        self.userLoadingEnabled = userLoadingEnabled
        self.runningTurnId = runningTurnId
        self.latestAttempt = latestAttempt
        self.previousCompleted = previousCompleted
    }

    public var latestLabel: String {
        guard let latestAttempt else { return "尚未运行" }
        if latestAttempt.configRevision != configRevision { return "此前配置的加载结果" }
        if latestAttempt.turnId == runningTurnId { return "本轮加载结果" }
        return "最近一轮加载结果"
    }
}

public extension RACPEvent {
    /// Only accept matching session/turn identities from the raw event envelope.
    var extensionSnapshot: RACPExtensionSnapshot? {
        guard payload.value(at: ["kind"])?.stringValue == "session.extensions.updated",
              payload.value(at: ["scope"])?.stringValue == "session",
              let value = payload.value(at: ["payload"]),
              let snapshot = try? RACPExtensionSnapshot.decoded(from: value),
              snapshot.sessionId == payload.value(at: ["sessionId"])?.stringValue,
              snapshot.turnId == payload.value(at: ["turnId"])?.stringValue,
              snapshot.revision > 0 else { return nil }
        return snapshot
    }
}
