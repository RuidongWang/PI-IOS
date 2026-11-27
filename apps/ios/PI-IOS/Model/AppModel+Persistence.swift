import Foundation
import Combine
import SwiftUI
import UIKit
import PIiOSCore
import PIiOSNet


extension AppModel {
    // MARK: - 持久化

    var snapshot: PersistedState {
        var state = PersistedState(
            hosts: hosts,
            offlineCacheLimit: offlineCacheLimit,
            modelProviders: modelProviders,
            lastSessionId: lastSessionId,
            lastProjectId: lastProjectId,
            projectBindings: projectBindings,
            sessionBindings: sessionBindings,
            lastSessionByHost: lastSessionByHost,
            lastProjectByHost: lastProjectByHost,
            collapsedProjectGroups: collapsedProjectGroups,
            projectBrowserPaths: projectBrowserPaths,
            readingPositionsByHost: usesUITestFixture ? readingPositionsByHost : [:],
            logConfiguration: logConfiguration
        )
        state.pendingHostCredentialCleanup = pendingHostCredentialCleanup.isEmpty ? nil : pendingHostCredentialCleanup
        return state
    }

    @discardableResult
    func persist(_ preparedState: PersistedState? = nil) -> Bool {
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
#if DEBUG
        if let persistenceOverrideForTesting { return persistenceOverrideForTesting() }
#endif
        guard !usesUITestFixture else { return true }
        guard canPersistLoadedState else {
            if generation == persistenceGeneration {
                saveError = "本机状态读取失败且原文件仍在，已暂停保存；请重启应用重试。"
            }
            return false
        }
        do {
            let state = preparedState ?? snapshot
            if let stateFileURL {
                try StateFile.save(state, to: stateFileURL)
            } else {
                try StateFile.save(state)
            }
            if generation == persistenceGeneration {
                saveError = nil
            }
            return true
        } catch {
            PILog.warn("StateFile", "保存失败：\(error.localizedDescription)")
            if generation == persistenceGeneration {
                saveError = "保存本机记录失败：\(error.localizedDescription)"
            }
            return false
        }
    }

    struct PersistAttempt {
        let succeeded: Bool
        let generation: UInt64
    }

    @discardableResult
    func persistAsync() async -> Bool {
        let attempt = await persistAsyncTracked()
        return attempt.succeeded
    }

    /// Async save that reports the generation it owns, so a barrier caller can
    /// tell whether a newer accepted write superseded its result.
    func persistAsyncTracked() async -> PersistAttempt {
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        func attempt(_ succeeded: Bool) -> PersistAttempt {
            PersistAttempt(succeeded: succeeded, generation: generation)
        }
#if DEBUG
        if let persistenceOverrideForTesting { return attempt(persistenceOverrideForTesting()) }
#endif
        guard !usesUITestFixture else { return attempt(true) }
        guard canPersistLoadedState else {
            if !Task.isCancelled, generation == persistenceGeneration {
                saveError = "本机状态读取失败且原文件仍在，已暂停保存；请重启应用重试。"
            }
            return attempt(false)
        }
        let state = snapshot
        do {
            if let stateFileURL {
                try await StateFile.saveAsync(state, to: stateFileURL)
            } else {
                try await StateFile.saveAsync(state)
            }
            if !Task.isCancelled, generation == persistenceGeneration {
                saveError = nil
            }
            return attempt(true)
        } catch {
            PILog.warn("StateFile", "保存失败：\(error.localizedDescription)")
            if !Task.isCancelled, generation == persistenceGeneration {
                saveError = "保存本机记录失败：\(error.localizedDescription)"
            }
            return attempt(false)
        }
    }
}
