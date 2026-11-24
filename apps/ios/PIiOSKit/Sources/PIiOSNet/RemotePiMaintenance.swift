import Foundation
import PIiOSCore

public enum RemotePiMaintenanceError: LocalizedError, Sendable {
    case notInstalled
    case invalidVersion
    case latestUnavailable
    case versionChanged
    case alreadyCurrent
    case unsupportedUpdate
    case busy
    case updateFailed
    case updateUnverified

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "在此 SSH 账户的 PATH 中未找到 Pi CLI。"
        case .invalidVersion: "无法读取服务器上的 Pi CLI 版本。"
        case .latestUnavailable: "暂时无法获取 Pi 官方最新版本，请重试。"
        case .versionChanged: "服务器上的 Pi 版本已变化，请重新查询。"
        case .alreadyCurrent: "服务器上的 Pi 已达到所查的最新版本。"
        case .unsupportedUpdate: "此 Pi CLI 不支持自更新，请通过其原安装方式升级。"
        case .busy: "这台服务器正在进行 Pi 升级，请稍后重试。"
        case .updateFailed: "Pi 自更新命令未完成。请重新查询当前版本。"
        case .updateUnverified: "未能确认 Pi 已升级到目标版本。请重新查询。"
        }
    }
}

public enum RemotePiMaintenance {
    public static func installedVersion(using transport: SSHTransport) async throws -> RemotePiVersion {
        let result = try await transport.exec("sh -s", stdin: Data(probeScript.utf8), timeout: 20)
        return try version(from: result)
    }

    public static func latestVersion() async throws -> RemotePiVersion {
        let endpoint = URL(string: "https://pi.dev/api/latest-version")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url == endpoint else { throw RemotePiMaintenanceError.latestUnavailable }
            return try latestVersion(from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw RemotePiMaintenanceError.latestUnavailable
        }
    }

    public static func upgrade(
        from installed: RemotePiVersion,
        toAtLeast latest: RemotePiVersion,
        using transport: SSHTransport
    ) async throws -> RemotePiVersion {
        guard installed.needsUpgrade(to: latest) else { throw RemotePiMaintenanceError.alreadyCurrent }
        let result: SSHExecResult
        do {
            result = try await transport.exec("sh -s", stdin: Data(upgradeScript(from: installed).utf8), timeout: 240)
        } catch {
            throw RemotePiMaintenanceError.updateUnverified
        }
        let verified = try version(from: result)
        guard !verified.needsUpgrade(to: latest) else { throw RemotePiMaintenanceError.updateUnverified }
        return verified
    }

    static func version(from result: SSHExecResult) throws -> RemotePiVersion {
        switch result.exitStatus {
        case 0: break
        case 70: throw RemotePiMaintenanceError.notInstalled
        case 72: throw RemotePiMaintenanceError.versionChanged
        case 73: throw RemotePiMaintenanceError.unsupportedUpdate
        case 74: throw RemotePiMaintenanceError.updateFailed
        case 75: throw RemotePiMaintenanceError.busy
        case 76: throw RemotePiMaintenanceError.updateUnverified
        default: throw RemotePiMaintenanceError.invalidVersion
        }
        let prefix = "PI_IOS_CLI_VERSION="
        let versions = result.stdoutText.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(prefix) }
        guard versions.count == 1, let line = versions.first,
              let version = RemotePiVersion(String(line.dropFirst(prefix.count))) else {
            throw RemotePiMaintenanceError.invalidVersion
        }
        return version
    }

    static func latestVersion(from data: Data) throws -> RemotePiVersion {
        struct Release: Decodable { let version: String }
        guard data.count <= 16_384, let release = try? JSONDecoder().decode(Release.self, from: data),
              let latest = RemotePiVersion(release.version), !latest.isPrerelease else {
            throw RemotePiMaintenanceError.latestUnavailable
        }
        return latest
    }

    private static let environment = #"""
    cd "$HOME" || exit 71
    PATH="$PATH:$HOME/.local/bin:$HOME/bin:${PNPM_HOME:-$HOME/.local/share/pnpm}:$HOME/.npm-global/bin:$HOME/.bun/bin"
    export PATH
    if ! command -v pi >/dev/null 2>&1 && [ -r "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
        NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
        export NVM_DIR
        . "$NVM_DIR/nvm.sh" --no-use
        nvm use --silent default >/dev/null 2>&1 || :
    fi
    pi_path=$(command -v pi) || exit 70
    case "$pi_path" in /*) ;; *) exit 70 ;; esac
    """#

    static var probeScript: String {
        environment + "\n" + #"""
        version=$("$pi_path" --version </dev/null) || exit 71
        printf 'PI_IOS_CLI_VERSION=%s\n' "${version#v}"
        """# + "\n"
    }

    static func upgradeScript(from installed: RemotePiVersion) -> String {
        environment + "\n" + #"""
        if command -v flock >/dev/null 2>&1; then
            umask 077
            lock_dir="$HOME/.cache/pi-ios"
            mkdir -p "$lock_dir" || exit 74
            exec 9>>"$lock_dir/pi-cli-update.lock"
            flock -n 9 || exit 75
        fi
        version=$("$pi_path" --version </dev/null) || exit 71
        [ "${version#v}" = '\#(installed.value)' ] || exit 72
        help=$("$pi_path" update --help </dev/null 2>&1) || exit 73
        case "$help" in *--self*) ;; *) exit 73 ;; esac
        set -- update --self
        case "$help" in *--no-approve*) set -- "$@" --no-approve ;; esac
        "$pi_path" "$@" </dev/null >&2 || exit 74
        updated=$("$pi_path" --version </dev/null) || exit 76
        printf 'PI_IOS_CLI_VERSION=%s\n' "${updated#v}"
        """# + "\n"
    }
}
