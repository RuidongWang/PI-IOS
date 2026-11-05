import Foundation
import PIiOSCore

public protocol RACPV2Requesting: Sendable {
    func v2Request<R: Decodable & Sendable>(
        method: String,
        params: JSONValue,
        timeout: TimeInterval
    ) async throws -> R
}

extension RACPClient: RACPV2Requesting {}

public struct RACPProviderDiscoveryError: Error, Equatable, Sendable {
    public let code: String
    public let upstreamStatus: Int?
    public let reason: String?

    public init(code: String, upstreamStatus: Int? = nil, reason: String? = nil) {
        self.code = code
        self.upstreamStatus = upstreamStatus
        self.reason = reason
    }
}

/// PI-adaptor provider management and model discovery over the active RACP connection.
/// Provider writes and ad-hoc discovery never invoke a provider CLI or SSH exec.
public enum RemoteProviderOperations {
    public static let userVisibleTimeout: TimeInterval = 10

    private struct DiscoveryEnvelope: Decodable, Sendable {
        var models: [RACPV2ProviderModel]
    }

    /// Daily model discovery always uses the caller's active RACP connection.
    /// The ad-hoc key exists only in this request payload; no SSH exec, logs or idempotency key.
    public static func discoverModels(
        client: any RACPV2Requesting,
        requestURL: String,
        apiKey: String,
        timeout: TimeInterval = userVisibleTimeout
    ) async throws -> [DiscoveredModel] {
        guard !requestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.isEmpty
        else { throw ModelListError.invalidEndpoint }
        let envelope: DiscoveryEnvelope
        do {
            envelope = try await client.v2Request(
                method: RACPV2Method.providerDiscover.rawValue,
                params: .object([
                    "baseUrl": .string(requestURL),
                    "apiKey": .string(apiKey),
                    "context": .object([
                        "requestId": .string("req_\(UUID().uuidString)"),
                    ]),
                ]),
                timeout: timeout
            )
        } catch {
            throw discoveryError(error)
        }
        guard !envelope.models.isEmpty else { throw ModelListError.emptyList }
        return envelope.models.map { model in
            DiscoveredModel(
                modelId: model.id,
                displayName: model.displayName,
                // FROZEN §10.4: 128000/8192 are generic wire defaults, not measured capacity.
                contextWindow: model.contextWindow == 128_000 ? nil : model.contextWindow,
                maxTokens: model.maxTokens == 8_192 ? nil : model.maxTokens,
                thinkingLevels: model.thinkingLevels.isEmpty ? nil : model.thinkingLevels,
                defaultThinkingLevel: model.defaultThinkingLevel.flatMap {
                    model.thinkingLevels.contains($0) ? $0 : nil
                }
            )
        }.sorted { $0.modelId.localizedStandardCompare($1.modelId) == .orderedAscending }
    }

    private static func discoveryError(_ error: Error) -> ModelListError {
        if let error = error as? RACPProviderDiscoveryError {
            if error.code == "UPSTREAM_UNAVAILABLE" {
                return .remote(status: error.upstreamStatus ?? 0, message: error.code)
            }
            return discoveryError(code: error.code)
        }
        if case .server(let code, _) = error as? RACPClientError {
            return discoveryError(code: code.rawValue)
        }
        if case .server(let code, _) = error as? RACPV2Error {
            return discoveryError(code: code)
        }
        if case .timedOut = error as? RACPClientError {
            return .network(.timeout)
        }
        return .network(.unknown)
    }

    private static func discoveryError(code: String) -> ModelListError {
        switch code {
        case "UNAUTHORIZED": return .remote(status: 401, message: code)
        case "INVALID_ARGUMENT", "ENDPOINT_REJECTED": return .invalidEndpoint
        case "UPSTREAM_TIMEOUT": return .network(.timeout)
        case "UPSTREAM_RESPONSE_INVALID", "PAYLOAD_TOO_LARGE": return .invalidResponse
        case "UPSTREAM_UNAVAILABLE": return .network(.unknown)
        default: return .remote(status: 0, message: code)
        }
    }

    public static func importProviders(
        client: any RACPV2Requesting,
        payload: ProviderImportPayload,
        timeout: TimeInterval = userVisibleTimeout
    ) async throws -> ProviderImportReceipt {
        guard payload.version == ProviderImportPayload.supportedVersion else {
            return .failure(.init(code: .invalidRequest))
        }
        let budget = ProviderOperationBudget(timeout: timeout)
        var imported: [ProviderImportImported] = []
        var defaultSet = false
        for entry in payload.providers {
            do {
                let result: ProviderEnvelope = try await client.v2Request(
                    method: RACPV2Method.providerCreate.rawValue,
                    params: .object([
                        "provider": providerCreateValue(for: entry),
                        "context": writeContext(
                            prefix: "provider_import",
                            stableSuffix: entry.sourceId
                        ),
                    ]),
                    timeout: try budget.remaining()
                )
                imported.append(
                    ProviderImportImported(
                        sourceId: entry.sourceId,
                        providerId: result.provider.id
                    )
                )
                if payload.defaultModel?.sourceId == entry.sourceId {
                    defaultSet = result.provider.isDefault
                        && result.provider.models.contains {
                            $0.id == payload.defaultModel?.modelId
                        }
                }
            } catch is ProviderOperationDeadlineExceeded {
                return .failure(ProviderImportFailure(code: .timeout))
            } catch let error as RACPV2Error {
                return .failure(ProviderImportFailure(code: importFailure(for: error)))
            } catch let error as RACPClientError {
                // 真实 RACP 客户端抛的是 `RACPClientError`；只匹配 `RACPV2Error`
                // 会让服务端错误码退化成「导入失败」，用户看不到可行动的原因。
                return .failure(
                    ProviderImportFailure(code: importFailure(forServerCode: serverCode(of: error)))
                )
            }
        }
        return .success(
            ProviderImportSuccess(
                imported: imported,
                skipped: [],
                defaultSet: defaultSet
            )
        )
    }

    public static func removeProvider(
        client: any RACPV2Requesting,
        providerId: String,
        timeout: TimeInterval = userVisibleTimeout
    ) async throws -> ProviderRemoveReceipt {
        guard !providerId.isEmpty else {
            return .failure(.invalidRequest)
        }
        let budget = ProviderOperationBudget(timeout: timeout)
        do {
            let result: DeleteEnvelope = try await client.v2Request(
                method: RACPV2Method.providerDelete.rawValue,
                params: .object([
                    "providerId": .string(providerId),
                    "confirmProviderId": .string(providerId),
                    "context": writeContext(
                        prefix: "provider_delete",
                        stableSuffix: providerId
                    ),
                ]),
                timeout: try budget.remaining()
            )
            let remaining: Int
            if let remainingTimeout = try? budget.remaining() {
                remaining = (try? await providerList(
                    client: client,
                    timeout: remainingTimeout
                ).count) ?? -1
            } else {
                remaining = -1
            }
            return .success(
                ProviderRemoveSummary(
                    providerId: providerId,
                    effect: result.deleted ? .deleted : .absent,
                    secretCleared: true,
                    defaultMoved: nil,
                    remaining: remaining,
                    remainingEligible: remaining
                )
            )
        } catch is ProviderOperationDeadlineExceeded {
            return .failure(.timeout)
        } catch let error as RACPV2Error {
            if case .server(let code, _) = error, code == "NOT_FOUND" {
                return absentReceipt(providerId: providerId)
            }
            return .failure(removeFailure(for: error))
        } catch let error as RACPClientError {
            // 真实 RACP 客户端抛 `RACPClientError`。NOT_FOUND 是幂等删除的正常结局：
            // 服务端已经没有这条记录，本机残留应由调用方清理，而不是报「删除未完成」。
            switch error {
            case .server(let code, _) where code == .notFound:
                return absentReceipt(providerId: providerId)
            case .server(let code, _):
                return .failure(removeFailure(forServerCode: code.rawValue))
            case .notConnected:
                return .failure(.adminUnavailable)
            case .timedOut:
                return .failure(.timeout)
            case .protocolMismatch, .malformedFrame:
                return .failure(.responseInvalid)
            }
        }
    }

    /// 目标 provider 在服务端已不存在：按成功处理，调用方继续清理本机记录。
    private static func absentReceipt(providerId: String) -> ProviderRemoveReceipt {
        .success(
            ProviderRemoveSummary(
                providerId: providerId,
                effect: .absent,
                secretCleared: true,
                defaultMoved: nil,
                remaining: 0,
                remainingEligible: 0
            )
        )
    }

    /// 两种客户端错误类型里取服务端错误码（`nil` 表示不是服务端拒绝）。
    private static func serverCode(of error: Error) -> String? {
        if case .server(let code, _) = error as? RACPV2Error { return code }
        if case .server(let code, _) = error as? RACPClientError { return code.rawValue }
        return nil
    }

    public static func bindingStatus(
        client: any RACPV2Requesting,
        sessionId: String,
        timeout: TimeInterval = userVisibleTimeout
    ) async throws -> ProviderBindingReceipt {
        guard !sessionId.isEmpty else {
            return .failure(.invalidRequest)
        }
        let budget = ProviderOperationBudget(timeout: timeout)
        do {
            let session: SessionEnvelope = try await client.v2Request(
                method: RACPV2Method.sessionGet.rawValue,
                params: .object(["sessionId": .string(sessionId)]),
                timeout: try budget.remaining()
            )
            let providers = try await providerList(
                client: client,
                timeout: try budget.remaining()
            )
            let providerId = session.session.providerId
            let modelId = session.session.modelId
            let observedAt = ISO8601DateFormatter().string(from: Date())
            func status(
                available: Bool?,
                reason: String?,
                effective: Bool
            ) -> ProviderBindingStatus {
                ProviderBindingStatus(
                    sessionId: sessionId,
                    pinnedProviderId: providerId,
                    pinnedModelId: modelId,
                    pinnedThinkingLevel: session.session.thinkingLevel,
                    effectiveProviderId: effective ? providerId : nil,
                    effectiveModelId: effective ? modelId : nil,
                    available: available,
                    unavailableReason: reason,
                    unknownInputs: [],
                    observedAt: observedAt
                )
            }
            guard let providerId, !providerId.isEmpty,
                  let modelId, !modelId.isEmpty
            else {
                return .success(status(available: false, reason: "no_candidate", effective: false))
            }
            guard let provider = providers.first(where: { $0.id == providerId }) else {
                return .success(status(available: false, reason: "provider_missing", effective: false))
            }
            guard !provider.models.isEmpty else {
                return .success(status(available: false, reason: "models_empty", effective: false))
            }
            guard provider.models.contains(where: { $0.id == modelId }) else {
                return .success(status(available: false, reason: "model_removed", effective: false))
            }
            if provider.authKind != "none", !provider.hasApiKey {
                return .success(status(available: false, reason: "secret_missing", effective: false))
            }
            return .success(status(available: true, reason: nil, effective: true))
        } catch is ProviderOperationDeadlineExceeded {
            return .failure(.timeout)
        } catch let error as RACPV2Error {
            return .failure(importFailure(for: error))
        }
    }

    private struct ProviderEnvelope: Decodable, Sendable {
        var provider: RACPV2Provider
    }

    private struct ProviderListEnvelope: Decodable, Sendable {
        var providers: [RACPV2Provider]
    }

    private struct DeleteEnvelope: Decodable, Sendable {
        var deleted: Bool
    }

    private struct SessionEnvelope: Decodable, Sendable {
        struct Session: Decodable, Sendable {
            var providerId: String?
            var modelId: String?
            var thinkingLevel: String?
        }
        var session: Session
    }

    private struct ProviderOperationDeadlineExceeded: Error {}

    private struct ProviderOperationBudget {
        private let deadline: ContinuousClock.Instant

        init(timeout: TimeInterval) {
            deadline = ContinuousClock.now.advanced(
                by: .seconds(max(0, timeout))
            )
        }

        func remaining() throws -> TimeInterval {
            let components = ContinuousClock.now
                .duration(to: deadline)
                .components
            let seconds = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            guard seconds > 0 else {
                throw ProviderOperationDeadlineExceeded()
            }
            return seconds
        }
    }

    private static func providerList(
        client: any RACPV2Requesting,
        timeout: TimeInterval
    ) async throws -> [RACPV2Provider] {
        let result: ProviderListEnvelope = try await client.v2Request(
            method: RACPV2Method.providerList.rawValue,
            params: .object([:]),
            timeout: timeout
        )
        return result.providers
    }

    private static func providerCreateValue(
        for entry: ProviderImportEntry
    ) -> JSONValue {
        let input = entry.input
        var fields: [String: JSONValue] = [
            "name": .string(input.name),
            "vendorKey": .string(providerVendorKey(for: entry)),
            "type": .string(input.type),
            "protocol": .string(input.protocol),
            "baseUrl": .string(input.baseUrl ?? ""),
            "authKind": .string(
                input.authKind == "none" ? "none" : "api_key"
            ),
            "models": .array(input.models.map(providerModelValue)),
        ]
        if input.authKind != "none",
           let secret = input.secretValue,
           !secret.isEmpty {
            fields["apiKey"] = .string(secret)
        }
        return .object(fields)
    }

    private static func providerVendorKey(
        for entry: ProviderImportEntry
    ) -> String {
        "pi-ios-\(entry.sourceId)"
    }

    private static func providerModelValue(
        _ model: ProviderModelSpec
    ) -> JSONValue {
        .object([
            "id": .string(model.id),
            "displayName": .string(model.alias ?? model.id),
            "contextWindow": .number(Double(model.contextWindow)),
            "maxTokens": .number(Double(model.maxTokens)),
            "thinkingLevels": .array(model.thinkingLevels.map(JSONValue.string)),
            "defaultThinkingLevel": model.defaultThinkingLevel.map(JSONValue.string) ?? .null,
            "supportsImages": .bool(model.supportsImages ?? false),
        ])
    }

    private static func writeContext(
        prefix: String,
        stableSuffix: String
    ) -> JSONValue {
        .object([
            "requestId": .string("req_\(UUID().uuidString)"),
            "idempotencyKey": .string("\(prefix)_\(stableSuffix)"),
        ])
    }

    private static func importFailure(for error: RACPV2Error) -> ProviderImportFailureCode {
        guard case .server(let code, _) = error else { return .importFailed }
        return importFailure(forServerCode: code)
    }

    private static func importFailure(forServerCode code: String?) -> ProviderImportFailureCode {
        switch code {
        case "INVALID_ARGUMENT", "INVALID_REQUEST": return .invalidRequest
        case "PAYLOAD_TOO_LARGE": return .payloadTooLarge
        case "TIMEOUT", "DEADLINE_EXCEEDED": return .timeout
        case "CONFLICT": return .conflict
        default: return .importFailed
        }
    }

    private static func removeFailure(for error: RACPV2Error) -> ProviderRemoveFailureCode {
        guard case .server(let code, _) = error else { return .removeFailed }
        return removeFailure(forServerCode: code)
    }

    private static func removeFailure(forServerCode code: String?) -> ProviderRemoveFailureCode {
        switch code {
        case "INVALID_ARGUMENT", "INVALID_REQUEST": return .invalidRequest
        case "PAYLOAD_TOO_LARGE": return .payloadTooLarge
        case "TIMEOUT", "DEADLINE_EXCEEDED": return .timeout
        default: return .removeFailed
        }
    }

}

/// Explicit compatibility path for pre-PI-adaptor `pi-host` installations.
/// PI-adaptor installs and normal provider operations must never call this CLI.
public enum LegacyRemoteProviderOperations {
    public static func importProviders(
        transport: SSHTransport,
        payload: Data,
        dataDir: String? = nil,
        timeout: TimeInterval = RemoteProviderOperations.userVisibleTimeout
    ) async throws -> ProviderImportReceipt {
        let result = try await transport.exec(
            command("provider-import", dataDir: dataDir),
            stdin: payload,
            timeout: timeout
        )
        return ProviderImportReceiptParser.parse(
            stdout: result.stdoutText,
            exitCode: Int32(clamping: result.exitStatus)
        )
    }

    public static func removeProvider(
        transport: SSHTransport,
        payload: Data,
        dataDir: String? = nil,
        timeout: TimeInterval = RemoteProviderOperations.userVisibleTimeout
    ) async throws -> ProviderRemoveReceipt {
        let result = try await transport.exec(
            command("provider-remove", dataDir: dataDir),
            stdin: payload,
            timeout: timeout
        )
        return ProviderRemoveReceiptParser.parse(
            stdout: result.stdoutText,
            exitCode: Int32(clamping: result.exitStatus)
        )
    }

    public static func bindingStatus(
        transport: SSHTransport,
        sessionId: String,
        dataDir: String? = nil,
        timeout: TimeInterval = RemoteProviderOperations.userVisibleTimeout
    ) async throws -> ProviderBindingReceipt {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(BindingStatusInput(sessionId: sessionId))
        let result = try await transport.exec(
            command("provider-binding-status", dataDir: dataDir),
            stdin: payload,
            timeout: timeout
        )
        return ProviderBindingReceiptParser.parse(
            stdout: result.stdoutText,
            exitCode: Int32(clamping: result.exitStatus)
        )
    }

    private struct BindingStatusInput: Codable {
        var version = 1
        var sessionId: String
    }

    private static func command(_ subcommand: String, dataDir: String?) -> String {
        var command =
            "node \"$HOME/.pi-desktop/pi-host/current/pi-host.js\" \(subcommand)"
        if let dataDir {
            let quoted = "'" + dataDir.replacingOccurrences(of: "'", with: "'\\''") + "'"
            command += " --data-dir \(quoted)"
        }
        return command
    }
}
