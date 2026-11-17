#if DEBUG
import Foundation
import PIiOSCore

/// Synthetic, opt-in UI data. No server response or successful module load is implied.
enum ExtensionUITestData {
    static func configure(_ fixture: inout UITestFixture, scenario: String) {
        guard let catalog = fixture.catalog, let hostID = fixture.state.hosts.first(where: { $0.isCurrent })?.id else { return }
        var info = catalog.info
        var capabilities = info.capabilities?.objectValue ?? [:]
        capabilities["extensionInventory"] = .bool(scenario != "extensions-unsupported")
        capabilities["sessionExtensions"] = .bool(scenario != "extensions-unsupported")
        info.capabilities = .object(capabilities)
        let updated = UITestFixture.Catalog(projects: catalog.projects, sessions: catalog.sessions, info: info)
        fixture.catalog = updated
        fixture.catalogs[hostID] = updated
        if scenario == "extensions-unsupported" { return }
        let time = "2026-11-12T12:00:00.000Z"
        let diagnostic: [String: Any] = ["stage": "load", "severity": "error", "code": "LOAD_FAILED",
                                         "message": "缺少依赖 fixture-dependency", "occurredAt": time]
        let inventoryEntries: [[String: Any]] = [
            ["id": "browser", "name": "Browser Tools", "configuredVersion": "1.0.0", "entryPath": "/srv/pi-extensions/browser/index.ts",
             "enabled": true, "compatibility": "headless-reviewed", "entryState": "valid", "diagnostics": []],
            ["id": "helper", "name": "Project Helper", "configuredVersion": NSNull(), "entryPath": "/srv/pi-extensions/helper/index.ts",
             "enabled": true, "compatibility": "headless-reviewed", "entryState": "valid", "diagnostics": []]
        ]
        fixture.extensionInventory = decode([
            "hostId": info.hostId, "configRevision": "fixture-config", "userLoadingEnabled": scenario != "extensions-empty",
            "capturedAt": time, "entries": scenario == "extensions-empty" ? [] : inventoryEntries
        ])
        let runtime: [[String: Any]] = [
            ["id": "browser", "name": "Browser Tools", "configuredVersion": "1.0.0", "loadState": "loaded", "skipReason": NSNull(),
             "registeredTools": ["browser_search", "browser_open"], "activeTools": ["browser_search"], "registeredCommands": ["browse"],
             "mobileInvocable": false, "diagnostics": []],
            ["id": "helper", "name": "Project Helper", "configuredVersion": NSNull(), "loadState": "failed", "skipReason": NSNull(),
             "registeredTools": [], "activeTools": [], "registeredCommands": [], "mobileInvocable": false, "diagnostics": [diagnostic]]
        ]
        for session in catalog.sessions {
            let snapshot: [String: Any] = [
                "id": "fixture-snapshot-\(session.id)", "hostId": info.hostId, "sessionId": session.id, "turnId": "fixture-turn",
                "configRevision": "fixture-config", "revision": 1, "startedAt": time, "completedAt": time,
                "phase": "ready", "entries": scenario == "extensions-empty" ? [] : runtime, "diagnostics": []
            ]
            fixture.sessionExtensions[session.id] = decode([
                "hostId": info.hostId, "sessionId": session.id, "configRevision": "fixture-config",
                "userLoadingEnabled": scenario != "extensions-empty", "runningTurnId": NSNull(),
                "latestAttempt": scenario == "extensions-never-run" ? NSNull() : snapshot as Any, "previousCompleted": NSNull()
            ])
        }
        if scenario == "extensions-offline" {
            fixture.connectionState = .offline(reason: "fixture offline")
            let date = Date(timeIntervalSince1970: 1_794_484_800)
            fixture.cache.sessions = catalog.sessions.map { summary in
                OfflineSessionCacheSession(hostID: hostID, id: summary.id, title: summary.title,
                    projectID: summary.projectId, mode: "agent", permissionMode: "ask", modelID: "alpha-pro",
                    providerID: "prv_alpha", epoch: "fixture-offline", sequence: 1, updatedAt: date)
            }
            fixture.cache.entries = catalog.sessions.map { summary in
                OfflineSessionCacheEntry(id: "offline-\(summary.id)", sessionId: summary.id, hostID: hostID,
                    text: "Offline extension fixture", createdAt: date)
            }
        }
        fixture.extensionReadFailure = scenario == "extensions-error"
    }

    private static func decode<T: Decodable>(_ object: [String: Any]) -> T {
        do { return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object)) }
        catch { preconditionFailure("invalid extension UI fixture: \(error)") }
    }
}
#endif
