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
        return try verifiedVersion(from: result, toAtLeast: latest)
    }

    static func verifiedVersion(from result: SSHExecResult, toAtLeast latest: RemotePiVersion) throws -> RemotePiVersion {
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
    [ -n "${HOME:-}" ] || HOME=$(pwd)
    cd "$HOME" || exit 71
    PATH="$HOME/.local/bin:$HOME/bin:${PNPM_HOME:-$HOME/.local/share/pnpm}:$HOME/Library/pnpm:$HOME/.npm-global/bin:$HOME/.npm/bin:$HOME/.npm-packages/bin:$HOME/.bun/bin:$HOME/.volta/bin:$HOME/.local/share/fnm/aliases/default/bin:$HOME/.fnm/aliases/default/bin:$HOME/Library/Application Support/fnm/aliases/default/bin:$HOME/.local/share/mise/shims:$HOME/.asdf/shims:$HOME/.nodenv/shims:$HOME/.nodenv/bin:$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:${N_PREFIX:-$HOME/n}/bin:$HOME/.n/bin:$PATH:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin"
    export PATH

    prepend_dir_if_exists() {
        [ -d "$1" ] || return 1
        case ":$PATH:" in
            *":$1:"*) ;;
            *) PATH="$1:$PATH"; export PATH ;;
        esac
    }

    scan_node_bins() {
        root="$1"
        suffix="$2"
        [ -d "$root" ] || return 1
        ordered=$(
            for dir in "$root"/*; do
                [ -d "$dir/$suffix" ] || continue
                name=${dir##*/}
                clean=${name#v}
                printf '%s\t%s/%s\n' "$clean" "$dir" "$suffix"
            done | sort -t. -k1,1nr -k2,2nr -k3,3nr | cut -f2-
        )
        [ -n "$ordered" ] || return 1
        old_ifs=$IFS
        nl=$(printf '\n.')
        IFS=${nl%.}
        for bin_dir in $ordered; do
            if [ -x "$bin_dir/pi" ] && [ -x "$bin_dir/node" ]; then
                prepend_dir_if_exists "$bin_dir"
                IFS=$old_ifs
                return 0
            fi
        done
        for bin_dir in $ordered; do
            if ! command -v pi >/dev/null 2>&1 && [ -x "$bin_dir/pi" ]; then
                prepend_dir_if_exists "$bin_dir"
            fi
            if ! command -v node >/dev/null 2>&1 && [ -x "$bin_dir/node" ]; then
                prepend_dir_if_exists "$bin_dir"
            fi
            if command -v pi >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
                IFS=$old_ifs
                return 0
            fi
        done
        IFS=$old_ifs
        return 1
    }

    if ! command -v pi >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
        for nvm_candidate in "${NVM_DIR:-}" "$HOME/.nvm" "${XDG_CONFIG_HOME:-$HOME/.config}/nvm"; do
            [ -n "$nvm_candidate" ] || continue
            if [ -r "$nvm_candidate/nvm.sh" ]; then
                NVM_DIR="$nvm_candidate"
                export NVM_DIR
                . "$NVM_DIR/nvm.sh" --no-use >/dev/null 2>&1 || :
                nvm use --silent default >/dev/null 2>&1 || :
            fi
            if ! command -v pi >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
                scan_node_bins "$nvm_candidate/versions/node" "bin" || :
            fi
            if command -v pi >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
                break
            fi
        done
    fi

    if ! command -v pi >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
        for fnm_root in "${FNM_DIR:-}" "${XDG_DATA_HOME:-$HOME/.local/share}/fnm" "$HOME/.fnm" "$HOME/Library/Application Support/fnm"; do
            [ -n "$fnm_root" ] || continue
            scan_node_bins "$fnm_root/node-versions" "installation/bin" && break || :
        done
    fi

    if ! command -v pi >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        npm_prefix=$(npm prefix -g </dev/null 2>/dev/null || true)
        [ -z "$npm_prefix" ] || prepend_dir_if_exists "$npm_prefix/bin" || :
    fi

    if ! command -v pi >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
        if [ -n "${SHELL:-}" ] && [ -x "$SHELL" ]; then
            shell_path=$("$SHELL" -lc 'printf "\nPI_IOS_SHELL_PATH=%s\n" "$PATH"' </dev/null 2>/dev/null | sed -n 's/^PI_IOS_SHELL_PATH=//p' | tail -n 1)
            if [ -n "$shell_path" ]; then
                PATH="$PATH:$shell_path"
                export PATH
            fi
        fi
    fi

    pi_path=$(command -v pi) || exit 70
    case "$pi_path" in /*) ;; *) exit 70 ;; esac
    [ -x "$pi_path" ] || exit 70

    extract_pi_version() {
        non_empty=$(printf '%s\n' "$1" | tr -d '\r' | awk '
            {
                gsub(/\033\[[0-9;]*[A-Za-z]/, "")
                if (NF) lines[++n] = $0
            }
            END {
                for (i = 1; i <= n; i++) print lines[i]
            }
        ')
        line_count=$(printf '%s\n' "$non_empty" | awk 'NF { c++ } END { print c + 0 }')
        if [ "$line_count" -eq 1 ]; then
            single=$(printf '%s' "$non_empty" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            case "$single" in
                "pi v"[0-9]*|"pi "[0-9]*|"pi/"[0-9]*)
                    single=${single#pi }
                    single=${single#pi/}
                    ;;
            esac
            single=${single#v}
            printf '%s' "$single"
            return 0
        fi
        candidate=$(printf '%s\n' "$non_empty" | awk '
            {
                s = $0
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
                sub(/^pi[[:space:]\/]+/, "", s)
                sub(/^v/, "", s)
                if (s ~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$/) {
                    val = s
                }
            }
            END { if (val != "") print val }
        ')
        [ -n "$candidate" ] || return 1
        printf '%s' "$candidate"
    }
    """#

    static var probeScript: String {
        environment + "\n" + #"""
        raw_version=$("$pi_path" --version </dev/null) || exit 71
        version=$(extract_pi_version "$raw_version") || exit 71
        [ -n "$version" ] || exit 71
        printf 'PI_IOS_CLI_VERSION=%s\n' "$version"
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
        raw_version=$("$pi_path" --version </dev/null) || exit 71
        current_version=$(extract_pi_version "$raw_version") || exit 71
        [ "$current_version" = '\#(installed.value)' ] || exit 72
        help=$("$pi_path" update --help </dev/null 2>&1) || exit 73
        case "$help" in *--self*) ;; *) exit 73 ;; esac
        set -- update --self
        case "$help" in *--no-approve*) set -- "$@" --no-approve ;; esac
        "$pi_path" "$@" </dev/null >&2 || exit 74
        raw_updated=$("$pi_path" --version </dev/null) || exit 76
        updated=$(extract_pi_version "$raw_updated") || exit 76
        [ -n "$updated" ] || exit 76
        printf 'PI_IOS_CLI_VERSION=%s\n' "$updated"
        """# + "\n"
    }
}
