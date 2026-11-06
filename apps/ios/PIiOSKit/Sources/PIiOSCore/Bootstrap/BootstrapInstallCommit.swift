import Foundation

/// Frozen identity of the HostRecord an installation was started for.
///
/// U15: the installed device token belongs to the PI-adaptor that was verified at
/// the end of the bootstrap SSH session. That identity must be compared with the
/// current local record **before** the staged token is promoted, otherwise a
/// record re-pointed to another server could receive the old server's token.
public struct InstallTargetSnapshot: Equatable, Sendable {
    public let hostID: UUID
    public let host: String
    public let sshPort: Int
    public let username: String
    public let hostPort: Int?
    public let directEndpoint: String?
    public let identityGeneration: Int

    public init(
        hostID: UUID,
        host: String,
        sshPort: Int,
        username: String,
        hostPort: Int?,
        directEndpoint: String?,
        identityGeneration: Int
    ) {
        self.hostID = hostID
        self.host = host
        self.sshPort = sshPort
        self.username = username
        self.hostPort = hostPort
        self.directEndpoint = directEndpoint
        self.identityGeneration = identityGeneration
    }

    /// Full identity equality, including the mutation generation. Any identity
    /// change means the install result can no longer be attributed to the current
    /// record.
    ///
    /// `hostPort` is deliberately **not** compared: it is the loopback RACP port
    /// discovered over SSH during the install itself (`onResolvedHostPort` writes
    /// it without bumping the identity generation). A manual edit of the port does
    /// bump `identityGeneration`, so it is still rejected.
    public func matches(_ other: Self) -> Bool {
        hostID == other.hostID
            && host == other.host
            && sshPort == other.sshPort
            && username == other.username
            && directEndpoint == other.directEndpoint
            && identityGeneration == other.identityGeneration
    }
}

/// Outcome of the single, controlled commit section that runs after the remote
/// runtime verification succeeded.
public enum BootstrapPairingCommitResult: Equatable, Sendable {
    /// Identity matched, the install receipt was persisted, and the staged token
    /// was promoted to the active Keychain record.
    case committed
    /// The local record no longer matches the frozen target. Nothing was
    /// promoted; only this attempt's staged credential may be cleaned up.
    case staleTarget
    /// Identity matched but the local state file could not be written. The token
    /// must not be promoted on top of a receipt that does not exist.
    case receiptPersistenceFailed(String)
    /// Receipt and identity were committed, but the staged token could not be
    /// written as the active one; this attempt's staging is cleaned up.
    case tokenPromotionFailed
}

public enum BootstrapInstallCommitPolicy {
    /// Decides whether a completed install may commit to the current record.
    ///
    /// `existingAdaptorHostId` is the currently recorded PI-adaptor identity (if
    /// any). When it is already present it must equal the adaptor hostId that the
    /// runtime verification obtained for this attempt, so a record that was
    /// re-paired to a different PI-adaptor can never accept the old token.
    public static func canCommit(
        expected: InstallTargetSnapshot,
        current: InstallTargetSnapshot,
        existingAdaptorHostId: String?,
        committedAdaptorHostId: String
    ) -> Bool {
        guard expected.matches(current) else { return false }
        if let existing = existingAdaptorHostId, !existing.isEmpty {
            return existing == committedAdaptorHostId
        }
        return true
    }
}

public enum BootstrapInstallCommitCoordinator {
    /// The one controlled commit point for a successful install:
    /// 1. re-check the frozen target identity and write the install receipt exactly once;
    /// 2. only then promote the staged device token;
    /// 3. on every failure clean up only this attempt's staging.
    ///
    /// `writeReceipt` must not mutate the record when it returns `.staleTarget`;
    /// `cleanupAttempt` must never touch the active device token.
    @discardableResult
    public static func commit(
        writeReceipt: () async -> BootstrapPairingCommitResult,
        promoteStaged: () async -> Bool,
        cleanupAttempt: () async -> Void
    ) async -> BootstrapPairingCommitResult {
        let receipt = await writeReceipt()
        switch receipt {
        case .committed:
            guard await promoteStaged() else {
                await cleanupAttempt()
                return .tokenPromotionFailed
            }
            return .committed
        case .staleTarget, .receiptPersistenceFailed, .tokenPromotionFailed:
            await cleanupAttempt()
            return receipt
        }
    }
}
