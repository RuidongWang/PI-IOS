import Foundation
import PIiOSCore
import PIiOSNet

#if DEBUG
struct ConnectionFixtureState {
    var isActive = false
    var providerBindingStatuses: [String: ProviderBindingStatus] = [:]
    var adaptorUnitSnapshot: AdaptorUnitSnapshot?
    var updatableProviders: [RACPV2Provider] = []
    var extensionInventory: RACPExtensionInventory?
    var sessionExtensions: [String: RACPSessionExtensions] = [:]
    var extensionReadFailure = false
    var catalogs: [UUID: UITestFixture.Catalog] = [:]
    var connectionState: RACPTunnelState?
    var supportsRevoke = false
}

/// 测试夹具里不访问网络：直接回退内置版本，并给出可展示的原因。
private struct FixtureAdaptorReleaseCatalog: AdaptorReleaseResolving {
    func resolve(
        target: BootstrapArtifactTarget,
        fallbackBaseURL: String
    ) async -> AdaptorReleaseResolution? {
        guard let release = PIAdaptorRelease.patched(target: target, baseURL: fallbackBaseURL) else {
            return nil
        }
        return AdaptorReleaseResolution(release: release, source: .fallback(reason: "测试环境不访问网络"))
    }
}

private extension RACPV2Provider {
    static func fixtureForUpdate(
        existing: RACPV2Provider,
        input: ProviderUpdateInput
    ) -> RACPV2Provider {
        var provider = existing
        provider.name = input.name
        provider.baseUrl = input.baseURL
        provider.models = input.models.map { spec in
            let data = try! JSONEncoder().encode(ProviderUpdateComposer.modelJSON(spec))
            var model = try! JSONDecoder().decode(RACPV2ProviderModel.self, from: data)
            model.id = spec.id
            model.displayName = spec.alias ?? spec.id
            return model
        }
        provider.updatedAt = "fixture-updated"
        return provider
    }
}
#else
struct ConnectionFixtureState {}
#endif

extension ConnectionModel {
    static func fixtureReleaseCatalog(for fixture: UITestFixture?) -> (any AdaptorReleaseResolving)? {
#if DEBUG
        fixture == nil ? nil : FixtureAdaptorReleaseCatalog()
#else
        nil
#endif
    }

    static func makeFixtureCacheStore(fixture: UITestFixture) -> SessionCacheStore {
#if DEBUG
        SessionCacheStore(
            offlineCacheLimit: PersistedState.defaultOfflineCacheLimit,
            inMemory: fixture.cache
        )
#else
        SessionCacheStore(offlineCacheLimit: PersistedState.defaultOfflineCacheLimit)
#endif
    }

    func applyInitialUITestFixture(_ fixture: UITestFixture) {
#if DEBUG
        fixtureState = ConnectionFixtureState(
            isActive: true,
            providerBindingStatuses: fixture.providerBindingStatuses,
            adaptorUnitSnapshot: fixture.adaptorUnitSnapshot,
            updatableProviders: fixture.updatableProviders,
            extensionInventory: fixture.extensionInventory,
            sessionExtensions: fixture.sessionExtensions,
            extensionReadFailure: fixture.extensionReadFailure,
            catalogs: fixture.catalogs,
            connectionState: fixture.connectionState,
            supportsRevoke: fixture.supportsFixtureRevoke
        )
        session.configureUITestSnapshots(fixture.sessionSnapshots)
        if let catalog = fixture.catalog {
            projects = catalog.projects
            sessions = catalog.sessions
            info = catalog.info
            hasLoadedCatalog = true
            state = .online
        }
        if let fixtureConnectionState = fixtureState.connectionState {
            state = fixtureConnectionState
        }
        connectionStatus = fixture.connectionStatus ?? ConnectionStatus()
#endif
    }

    func configureSessionUITestFixture(_ fixture: UITestFixture?) {
#if DEBUG
        session.configureUITestInterruption(enabled: fixture?.supportsFixtureInterrupt == true)
#endif
    }

    func applyFixtureHostSelection(_ hostID: UUID?) {
#if DEBUG
        if let hostID, let catalog = fixtureState.catalogs[hostID] {
            applyFixtureCatalog(catalog)
        }
        if fixtureState.isActive, !state.isOnline, let hostID,
           let inventory = fixtureState.extensionInventory,
           info?.hostId == inventory.hostId {
            extensions.seedForFixture(hostID: hostID, inventory: inventory, results: fixtureState.sessionExtensions)
        }
#endif
    }

    func applyFixtureCatalog(_ catalog: UITestFixture.Catalog?) {
#if DEBUG
        guard let catalog else { return }
        projects = catalog.projects
        sessions = catalog.sessions
        info = catalog.info
        hasLoadedCatalog = true
        catalogError = nil
        state = fixtureState.connectionState ?? .online
#endif
    }

    func fixtureProviderBindingStatusResult(sessionId: String) -> ProviderBindingReceipt? {
#if DEBUG
        guard let status = fixtureAdaptorV2BindingStatusResult(sessionId: sessionId) else { return nil }
        return .success(status)
#else
        nil
#endif
    }

    func fixtureAdaptorV2BindingStatusResult(sessionId: String) -> ProviderBindingStatus? {
#if DEBUG
        guard fixtureState.isActive else { return nil }
        return fixtureState.providerBindingStatuses[sessionId]
#else
        nil
#endif
    }

    func fixtureRefreshExtensionInventoryIfApplicable() async -> Bool {
#if DEBUG
        guard fixtureState.isActive, let inventory = fixtureState.extensionInventory else {
            return false
        }
        await extensions.refreshInventory {
            if self.fixtureState.extensionReadFailure { throw CancellationError() }
            return inventory
        }
        return true
#else
        false
#endif
    }

    func fixtureRefreshSessionExtensionsIfApplicable(_ sessionID: String) async -> Bool {
#if DEBUG
        guard fixtureState.isActive, let result = fixtureState.sessionExtensions[sessionID] else {
            return false
        }
        await extensions.refreshSession(sessionID) {
            if self.fixtureState.extensionReadFailure { throw CancellationError() }
            return result
        }
        return true
#else
        false
#endif
    }

    func fixtureUpdateAdaptorProviderIfApplicable(
        id: String,
        input: ProviderUpdateInput
    ) throws -> RACPV2Provider? {
#if DEBUG
        guard fixtureState.isActive else { return nil }
        guard let existing = fixtureState.updatableProviders.first(where: { $0.id == id }) else {
            throw RACPV2Error.server(code: "NOT_FOUND", message: "模型服务不存在")
        }
        let composition = ProviderUpdateComposer.compose(existing: existing, input: input)
        guard composition.isValid else {
            throw ProviderImportValidationFailure(issues: composition.issues)
        }
        logProviderUpdate(id: id, composition: composition)
        let updated = RACPV2Provider.fixtureForUpdate(
            existing: existing, input: composition.input
        )
        fixtureState.updatableProviders = fixtureState.updatableProviders.map {
            $0.id == id ? updated : $0
        }
        return updated
#else
        nil
#endif
    }

    func fixtureAdaptorUnitSnapshotIfApplicable() throws -> AdaptorUnitSnapshot? {
#if DEBUG
        guard fixtureState.isActive else { return nil }
        guard let snapshot = fixtureState.adaptorUnitSnapshot else {
            throw AdaptorUnitParseError.missingField("fixture AdaptorUnitSnapshot")
        }
        return snapshot
#else
        nil
#endif
    }

    func fixtureConnectIfApplicable(hostID: UUID, hostLabel: Substring) -> Bool {
#if DEBUG
        guard fixtureState.isActive else { return false }
        PILog.debug("Connection", "connect fixture host=\(hostLabel)")
        applyFixtureCatalog(fixtureState.catalogs[hostID])
        return true
#else
        false
#endif
    }

    func fixtureWaitUntilOnlineResult() -> Bool? {
#if DEBUG
        guard fixtureState.isActive else { return nil }
        return state.isOnline
#else
        nil
#endif
    }

    func fixtureVerifyConnectionLivenessResult() -> Bool? {
#if DEBUG
        guard fixtureState.isActive else { return nil }
        return state.isOnline
#else
        nil
#endif
    }

    func fixtureArchiveSessionIfApplicable(
        sessionId: String,
        archived: Bool
    ) throws -> RACPSessionSummary? {
#if DEBUG
        guard fixtureState.isActive else { return nil }
        guard state.isOnline else { throw RACPClientError.notConnected }
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else {
            throw RACPClientError.protocolMismatch("归档目标不存在")
        }
        invalidateCatalogLoads()
        var updated = sessions[index]
        updated.status = archived ? "archived" : "idle"
        sessions[index] = updated
        return updated
#else
        nil
#endif
    }

    func fixtureDeleteSessionIfApplicable(
        sessionId: String,
        confirmSessionId: String
    ) throws -> RACPV2SessionDeleteResult? {
#if DEBUG
        guard fixtureState.isActive else { return nil }
        guard state.isOnline else { throw RACPClientError.notConnected }
        guard sessionId == confirmSessionId else {
            throw RACPClientError.protocolMismatch("删除确认目标不一致")
        }
        guard sessions.contains(where: { $0.id == sessionId }) else {
            throw RACPClientError.protocolMismatch("删除目标不存在")
        }
        invalidateCatalogLoads()
        removeCachedSessions([sessionId])
        sessions.removeAll { $0.id == sessionId }
        // 夹具只证明 UI 删除成功链路；真实 Host 行为由 Host/集成测试覆盖。
        let payload = "{\"deleted\":true,\"sessionId\":\"\(sessionId)\"}"
        return try JSONDecoder().decode(RACPV2SessionDeleteResult.self, from: Data(payload.utf8))
#else
        nil
#endif
    }

    func fixtureRevokeDeviceMessageIfApplicable() -> String? {
#if DEBUG
        guard fixtureState.isActive, fixtureState.supportsRevoke else { return nil }
        return Self.deviceRevokedMessage
#else
        nil
#endif
    }
}
