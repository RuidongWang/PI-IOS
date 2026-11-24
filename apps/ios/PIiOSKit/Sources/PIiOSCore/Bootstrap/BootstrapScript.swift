import Foundation

/// Inputs for the POSIX bootstrap script that runs on the target Linux host.
///
/// The script is generated entirely on the client. Every value that can reach a
/// shell is validated here and then emitted as a single-quoted shell literal.
public struct BootstrapScriptConfiguration: Equatable, Sendable {
    public static let defaultPairingLifetimeMilliseconds = 10 * 60 * 1_000
    public static let defaultReadyTimeoutSeconds = 90
    public static let defaultPairTimeoutSeconds = 12 * 60
    public static let defaultStopTimeoutSeconds = 20
    public static let defaultVerifyTimeoutSeconds = 90

    public let release: PIAdaptorRelease
    public let attemptId: String
    public let hostPlatform: String
    public let hostArchitecture: String
    public let port: Int
    public let pairingLifetimeMilliseconds: Int
    public let readyTimeoutSeconds: Int
    public let pairTimeoutSeconds: Int
    public let stopTimeoutSeconds: Int
    public let verifyTimeoutSeconds: Int
    /// 强制重装：命中本地 receipt 也重新下载并激活，用于「版本没变但字节变了」的场景。
    public let force: Bool
    /// PI-adaptor installations default to PPT2 only. A separate legacy path may
    /// opt into PPT1; the normal install UI never exposes that override.
    public let allowLegacyPPT1: Bool
    public let direct: BootstrapDirectConfiguration?

    public init(
        release: PIAdaptorRelease,
        attemptId: String,
        hostPlatform: String = "linux",
        hostArchitecture: String,
        port: Int,
        pairingLifetimeMilliseconds: Int = BootstrapScriptConfiguration.defaultPairingLifetimeMilliseconds,
        readyTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultReadyTimeoutSeconds,
        pairTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultPairTimeoutSeconds,
        stopTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultStopTimeoutSeconds,
        verifyTimeoutSeconds: Int = BootstrapScriptConfiguration.defaultVerifyTimeoutSeconds,
        force: Bool = false,
        allowLegacyPPT1: Bool = false,
        direct: BootstrapDirectConfiguration? = nil
    ) throws {
        guard BootstrapScriptValidation.isAttemptId(attemptId) else {
            throw BootstrapScriptError.invalidAttemptId
        }
        guard (1...65_535).contains(port) else {
            throw BootstrapScriptError.invalidPort
        }
        let architecture = hostArchitecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hostPlatform.lowercased() == BootstrapPlatformProbe.supportedPlatform,
              BootstrapScriptValidation.isSafeLabel(hostPlatform),
              BootstrapScriptValidation.isSafeLabel(architecture),
              BootstrapPlatformProbe.target(forUnameMachine: architecture) == release.target else {
            throw BootstrapScriptError.invalidHostIdentity
        }
        guard (60_000...15 * 60 * 1_000).contains(pairingLifetimeMilliseconds) else {
            throw BootstrapScriptError.invalidPairingLifetime
        }
        for timeout in [
            readyTimeoutSeconds,
            pairTimeoutSeconds,
            stopTimeoutSeconds,
            verifyTimeoutSeconds,
        ] {
            guard (1...3_600).contains(timeout) else {
                throw BootstrapScriptError.invalidTimeout
            }
        }

        self.release = release
        self.attemptId = attemptId
        self.hostPlatform = hostPlatform.lowercased()
        self.hostArchitecture = architecture
        self.port = port
        self.pairingLifetimeMilliseconds = pairingLifetimeMilliseconds
        self.readyTimeoutSeconds = readyTimeoutSeconds
        self.pairTimeoutSeconds = pairTimeoutSeconds
        self.stopTimeoutSeconds = stopTimeoutSeconds
        self.verifyTimeoutSeconds = verifyTimeoutSeconds
        self.force = force
        self.allowLegacyPPT1 = allowLegacyPPT1
        self.direct = direct
    }
}

public enum BootstrapScriptError: Error, Equatable, CustomStringConvertible {
    case invalidAttemptId
    case invalidPort
    case invalidHostIdentity
    case invalidPairingLifetime
    case invalidTimeout
    case invalidDirectConfiguration

    public var description: String {
        switch self {
        case .invalidAttemptId:
            return "安装任务标识不合法。"
        case .invalidPort:
            return "端口必须在 1–65535 之间。"
        case .invalidHostIdentity:
            return "运行平台或架构不合法。"
        case .invalidPairingLifetime:
            return "配对令牌有效期必须在 1–15 分钟之间。"
        case .invalidTimeout:
            return "安装超时必须在 1–3600 秒之间。"
        case .invalidDirectConfiguration:
            return "直连主机必须是 DNS 或 IP，直连端口需与本地端口不同。"
        }
    }
}

enum BootstrapScriptValidation {
    private static let attemptCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )
    private static let labelCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )

    static func isAttemptId(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.utf8.count <= 96 && value.unicodeScalars.allSatisfy {
            $0.isASCII && attemptCharacters.contains($0)
        }
    }

    static func isSafeLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.unicodeScalars.allSatisfy {
            $0.isASCII && labelCharacters.contains($0)
        }
    }
}

/// Generates the only script executed on the remote host.
///
/// Pairing-token stdout is consumed through an owner-only FIFO. It is never
/// redirected into a persistent log. The script pauses at `pair` and
/// `verify-device`; the runner performs those client-side callbacks and writes
/// a non-secret result marker so the script can advance.
public enum BootstrapScriptBuilder {
    public static func build(_ configuration: BootstrapScriptConfiguration) -> String {
        let release = configuration.release
        let assignments = [
            shellQuote(release.version),
            shellQuote(release.artifactURL),
            shellQuote(release.checksumURL),
            shellQuote(release.pinnedChecksum ?? ""),
            shellQuote(release.artifactName),
            shellQuote(release.bundleDirectoryName),
            shellQuote(release.target.rawValue),
            shellQuote(release.serverName),
            shellQuote(release.unitName),
            shellQuote(release.minimumNodeVersion),
            String(configuration.port),
            String(configuration.pairingLifetimeMilliseconds),
            String(configuration.readyTimeoutSeconds),
            String(configuration.pairTimeoutSeconds),
            String(configuration.stopTimeoutSeconds),
            String(configuration.verifyTimeoutSeconds),
            shellQuote(configuration.attemptId),
            shellQuote(configuration.hostPlatform),
            shellQuote(configuration.hostArchitecture),
            configuration.force ? "1" : "0",
            configuration.allowLegacyPPT1 ? "1" : "0",
            configuration.direct == nil ? "0" : "1",
            shellQuote(configuration.direct?.directName ?? ""),
            String(configuration.direct?.directPort ?? 0),
            shellQuote(configuration.direct?.sanExpression ?? ""),
        ]
        let variableNames = [
            "VERSION",
            "ARTIFACT_URL",
            "CHECKSUM_URL",
            "PINNED_SHA256",
            "ARTIFACT_NAME",
            "BUNDLE_DIR",
            "TARGET",
            "SERVER_NAME",
            "UNIT_NAME",
            "MIN_NODE_VERSION",
            "PORT",
            "PAIRING_LIFETIME_MS",
            "READY_TIMEOUT_SEC",
            "PAIR_TIMEOUT_SEC",
            "STOP_TIMEOUT_SEC",
            "VERIFY_TIMEOUT_SEC",
            "ATTEMPT_ID",
            "HOST_PLATFORM",
            "HOST_ARCH",
            "FORCE_INSTALL",
            "ALLOW_LEGACY_PPT1",
            "DIRECT_REQUESTED",
            "DIRECT_NAME",
            "DIRECT_PORT",
            "DIRECT_SAN",
        ]
        let assignmentBlock = zip(variableNames, assignments)
            .map { "\($0)=\($1)" }
            .joined(separator: "\n")

        return #"""
#!/bin/sh
# Generated by PI-IOS. Implements docs/api/ios-client.md section 5.
set -eu
umask 077

\#(assignmentBlock)

BASE="$HOME/.pi-adaptor"
RELEASES="$BASE/releases"
WORK="$BASE/.bootstrap"
ATTEMPT="$WORK/attempts/$ATTEMPT_ID"
STATE="$ATTEMPT/state.json"
LEGACY_STATE="$WORK/state.json"
RECEIPT="$WORK/install-receipt.json"
PAIR_JSON="$ATTEMPT/pair.json"
PAIR_RESULT="$ATTEMPT/pair.result"
PAIR_REJECT="$ATTEMPT/pair.reject"
VERIFY_RESULT="$ATTEMPT/verify.result"
CANCEL="$ATTEMPT/cancel"
LOCK="$WORK/active.lock"
PART="$WORK/$ARTIFACT_NAME.part"
CHECKSUM_FILE="$WORK/$ARTIFACT_NAME.sha256"
TRANSACTION_ACTIVE="$WORK/transaction.active"
TRANSACTION_PREVIOUS="$WORK/transaction.previous"
TRANSACTION_SERVICE="$WORK/transaction.service-active"
TRANSACTION_ENABLED="$WORK/transaction.service-enabled"
TRANSACTION_INSTALL_DIR="$WORK/transaction.install-dir"
TRANSACTION_ROLLBACK_SCRIPT="$WORK/transaction.rollback-install.sh"
TRANSACTION_RECEIPT_BACKUP="$WORK/transaction.receipt.previous"
TRANSACTION_LEGACY="$WORK/transaction.legacy-units"
TRANSACTION_UNIT_BACKUP="$WORK/transaction.unit.previous"
TRANSACTION_UNIT_ABSENT="$WORK/transaction.unit.absent"
TRANSACTION_TLS_BACKUP="$WORK/transaction.tls.previous"
TRANSACTION_TLS_ABSENT="$WORK/transaction.tls.absent"
ROLLBACK_SCRIPT="$WORK/install.sh"
DIRECT_ACTIVE=0
DIRECT_TLS="$BASE/tls"
DIRECT_TRUST="$ATTEMPT/direct-trust.json"

CURRENT_STEP="probe"
ARTIFACT_BYTES=0
DOWNLOADED_BYTES=0
EXPECTED_SHA256=""
SERVICE_STATE="absent"
MANUAL_PID=""
PAIR_READER_PID=""
DOWNLOAD_PID=""
STAGE=""
INSTALL_DIR=""
PREVIOUS_CURRENT_TARGET="none"
PREVIOUS_SERVICE_ACTIVE=0
PREVIOUS_SERVICE_ENABLED="disabled"
CURRENT_SERVICE_STOPPED=0
LEGACY_UNITS_STOPPED=""
LEGACY_UNITS_JSON="[]"
FAILURE_REASON=""
ROLLBACK_RESULT="not-needed"
ROLLBACK_STEP=""
ROLLBACK_REASON=""
SERVER_ARCH="unknown"
NODE_VERSION="unknown"
ACTUAL_VERSION=""

step() {
  printf '%s\n' "PI_HOST_BOOTSTRAP $1"
}

write_state() {
  next_step=$1
  status=$2
  error_code=${3:-}
  service_value=${4:-$SERVICE_STATE}
  output_state=${5:-$STATE}
  case "$next_step$status$error_code$service_value$ATTEMPT_ID$ARTIFACT_NAME$EXPECTED_SHA256" in
    *'"'*|*'\'*) return 1 ;;
  esac
  [ -d "$ATTEMPT" ] || return 1
  error_json='null'
  if [ -n "$error_code" ]; then
    details_reason=${FAILURE_REASON:-$error_code}
    actual_version_json=null
    [ -z "$ACTUAL_VERSION" ] || actual_version_json="\"$ACTUAL_VERSION\""
    error_json="{\"code\":\"$error_code\",\"details\":{\"reason\":\"$details_reason\",\"phase\":\"$next_step\",\"expectedName\":\"$SERVER_NAME\",\"expectedVersion\":\"$VERSION\",\"actualVersion\":$actual_version_json,\"installDirectory\":\"$INSTALL_DIR\",\"unitName\":\"$UNIT_NAME\",\"port\":$PORT,\"legacyUnits\":$LEGACY_UNITS_JSON,\"rollback\":\"$ROLLBACK_RESULT\",\"rollbackStep\":\"$ROLLBACK_STEP\",\"serverArch\":\"$SERVER_ARCH\",\"nodeVersion\":\"$NODE_VERSION\"}}"
  fi
  tmp="$output_state.tmp.$$"
  {
    printf '{"version":1,"attemptId":"%s","step":"%s","status":"%s",' "$ATTEMPT_ID" "$next_step" "$status"
    printf '"host":{"platform":"%s","arch":"%s"},' "$HOST_PLATFORM" "$HOST_ARCH"
    printf '"artifact":{"name":"%s","sha256":"%s","bytes":%s,"downloadedBytes":%s},' \
      "$ARTIFACT_NAME" "$EXPECTED_SHA256" "$ARTIFACT_BYTES" "$DOWNLOADED_BYTES"
    printf '"service":{"unitPath":"%s","state":"%s"},' "$HOME/.config/systemd/user/$UNIT_NAME" "$service_value"
    printf '"error":%s,"updatedAt":"%s"}\n' "$error_json" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$output_state"
}

refresh_legacy_units_json() {
  LEGACY_UNITS_JSON='[]'
  [ -f "$TRANSACTION_LEGACY" ] || return 0
  LEGACY_UNITS_JSON='['
  legacy_separator=''
  while IFS='|' read -r legacy_unit was_active was_enabled; do
    case "$legacy_unit" in
      pi-host.service|pi-host-v2.service) ;;
      *) continue ;;
    esac
    enabled_json=false
    case "$was_enabled" in
      enabled|enabled-runtime) enabled_json=true ;;
    esac
    LEGACY_UNITS_JSON="$LEGACY_UNITS_JSON$legacy_separator{\"unit\":\"$legacy_unit\",\"originalActive\":true,\"originalEnabled\":$enabled_json,\"originalEnableState\":\"$was_enabled\",\"portOccupied\":true}"
    legacy_separator=','
  done <"$TRANSACTION_LEGACY"
  LEGACY_UNITS_JSON="$LEGACY_UNITS_JSON]"
}

progress() {
  CURRENT_STEP=$1
  step "$1"
  write_state "$1" running || die "bootstrap-permissions"
}

cleanup_manual() {
  if [ -n "$PAIR_READER_PID" ]; then
    kill "$PAIR_READER_PID" 2>/dev/null || true
    wait "$PAIR_READER_PID" 2>/dev/null || true
    PAIR_READER_PID=""
  fi
  if [ -n "$MANUAL_PID" ] && kill -0 "$MANUAL_PID" 2>/dev/null; then
    kill "$MANUAL_PID" 2>/dev/null || true
    waited=0
    while kill -0 "$MANUAL_PID" 2>/dev/null && [ "$waited" -lt "$STOP_TIMEOUT_SEC" ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$MANUAL_PID" 2>/dev/null; then
      kill -KILL "$MANUAL_PID" 2>/dev/null || true
    fi
    wait "$MANUAL_PID" 2>/dev/null || true
  fi
  MANUAL_PID=""
}

cleanup_download() {
  if [ -n "$DOWNLOAD_PID" ]; then
    kill "$DOWNLOAD_PID" 2>/dev/null || true
    wait "$DOWNLOAD_PID" 2>/dev/null || true
    DOWNLOAD_PID=""
  fi
}

redact_pair_stderr() {
  [ -f "$ATTEMPT/pair.err" ] || return 0
  token=""
  if [ -f "$PAIR_JSON" ]; then
    token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PAIR_JSON" 2>/dev/null || true)
  fi
  if [ -n "$token" ]; then
    redacted="$ATTEMPT/pair.err.redacted.$$"
    sed "s/$token/<redacted>/g" "$ATTEMPT/pair.err" >"$redacted" 2>/dev/null || return 1
    chmod 600 "$redacted" 2>/dev/null || return 1
    mv -f "$redacted" "$ATTEMPT/pair.err" || return 1
  fi
}

record_transaction() {
  current_link="$BASE/current"
  if [ -L "$current_link" ]; then
    previous=$(readlink "$current_link" 2>/dev/null || true)
    # install.sh 也接受指向 $BASE/releases 的绝对路径；统一成相对形式，
    # 否则会被误判成 invalid。
    case "$previous" in
      "$BASE"/releases/*) previous=${previous#"$BASE"/} ;;
    esac
    case "$previous" in
      releases/*)
        # 悬空的 current（上一次失败或旧目录被删）不能原样留着：
        # install.sh 的 resolve_previous_current 要求 previous 目录真实存在，
        # 否则每次重装都在 activate 阶段报 state-mismatch；回滚脚本同样会
        # 失败，把真正的失败原因盖成 rollback-failed。先清掉坏链接再装。
        if [ -d "$BASE/$previous" ] && [ ! -L "$BASE/$previous" ]; then
          PREVIOUS_CURRENT_TARGET=$previous
        else
          rm -f "$current_link"
          PREVIOUS_CURRENT_TARGET="none"
        fi
        ;;
      *) PREVIOUS_CURRENT_TARGET="invalid" ;;
    esac
  elif [ -e "$current_link" ]; then
    PREVIOUS_CURRENT_TARGET="invalid"
  else
    PREVIOUS_CURRENT_TARGET="none"
  fi
  printf '%s\n' "$PREVIOUS_CURRENT_TARGET" >"$TRANSACTION_PREVIOUS"
  chmod 600 "$TRANSACTION_PREVIOUS"

  if systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; then
    PREVIOUS_SERVICE_ACTIVE=1
  else
    PREVIOUS_SERVICE_ACTIVE=0
  fi
  printf '%s\n' "$PREVIOUS_SERVICE_ACTIVE" >"$TRANSACTION_SERVICE"
  chmod 600 "$TRANSACTION_SERVICE"

  # 安装流程会 `systemctl --user enable`，回滚时必须恢复原来的 enable 状态，
  # 否则一次失败的安装会留下开机自启的 unit。
  PREVIOUS_SERVICE_ENABLED=$(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null | sed -n '1p')
  [ -n "$PREVIOUS_SERVICE_ENABLED" ] || PREVIOUS_SERVICE_ENABLED="disabled"
  case "$PREVIOUS_SERVICE_ENABLED" in
    *[!A-Za-z0-9-]*) PREVIOUS_SERVICE_ENABLED="unknown" ;;
  esac
  printf '%s\n' "$PREVIOUS_SERVICE_ENABLED" >"$TRANSACTION_ENABLED"
  chmod 600 "$TRANSACTION_ENABLED"

  printf '%s\n' "$INSTALL_DIR" >"$TRANSACTION_INSTALL_DIR"
  chmod 600 "$TRANSACTION_INSTALL_DIR"
  cp "$ROLLBACK_SCRIPT" "$TRANSACTION_ROLLBACK_SCRIPT" 2>/dev/null || {
    printf '%s\n' "PI_HOST_BOOTSTRAP_FAILED install-failed" >&2
    exit 1
  }
  chmod 700 "$TRANSACTION_ROLLBACK_SCRIPT"

  rm -f "$TRANSACTION_RECEIPT_BACKUP"
  rm -f "$TRANSACTION_LEGACY"
  # Preserve the previous unit file itself: rollback used to restore only the
  # release link and service states, so a failed upgrade could leave the old
  # service running with the new unit's port/paths (or lose customizations).
  unit_path="$HOME/.config/systemd/user/$UNIT_NAME"
  rm -f "$TRANSACTION_UNIT_BACKUP" "$TRANSACTION_UNIT_ABSENT"
  if [ -f "$unit_path" ]; then
    cp "$unit_path" "$TRANSACTION_UNIT_BACKUP"
    chmod 600 "$TRANSACTION_UNIT_BACKUP"
  else
    : >"$TRANSACTION_UNIT_ABSENT"
    chmod 600 "$TRANSACTION_UNIT_ABSENT"
  fi
  LEGACY_UNITS_JSON='[]'
  if [ -f "$RECEIPT" ]; then
    cp "$RECEIPT" "$TRANSACTION_RECEIPT_BACKUP"
    chmod 600 "$TRANSACTION_RECEIPT_BACKUP"
  fi
  rm -rf "$TRANSACTION_TLS_BACKUP"
  rm -f "$TRANSACTION_TLS_ABSENT"
  printf '%s\n' "$ATTEMPT_ID" >"$TRANSACTION_ACTIVE.next" &&
    mv -f "$TRANSACTION_ACTIVE.next" "$TRANSACTION_ACTIVE" || die "bootstrap-permissions"
}

attempt_committed() {
  committed_attempt=$1
  case "$committed_attempt" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  committed_state="$WORK/attempts/$committed_attempt/state.json"
  [ -f "$committed_state" ] || return 1
  IFS= read -r state_line <"$committed_state" || return 1
  case "$state_line" in
    '{"version":1,"attemptId":"'"$committed_attempt"'","step":"done","status":"ok",'*) return 0 ;;
    *) return 1 ;;
  esac
}

clear_transaction() {
  rm -f "$TRANSACTION_ACTIVE" || return 1
  rm -f "$TRANSACTION_PREVIOUS" "$TRANSACTION_SERVICE" "$TRANSACTION_ENABLED" \
    "$TRANSACTION_INSTALL_DIR" "$TRANSACTION_ROLLBACK_SCRIPT" "$TRANSACTION_RECEIPT_BACKUP" \
    "$TRANSACTION_LEGACY" "$TRANSACTION_UNIT_BACKUP" "$TRANSACTION_UNIT_ABSENT" \
    "$TRANSACTION_TLS_ABSENT" && rm -rf "$TRANSACTION_TLS_BACKUP"
}

restore_tls() {
  if [ -e "$TRANSACTION_TLS_BACKUP" ] || [ -L "$TRANSACTION_TLS_BACKUP" ]; then
    rm -rf "$DIRECT_TLS" && mv "$TRANSACTION_TLS_BACKUP" "$DIRECT_TLS"
  elif [ -f "$TRANSACTION_TLS_ABSENT" ]; then
    rm -rf "$DIRECT_TLS"
  fi
}

restore_legacy_units() {
  [ -f "$TRANSACTION_LEGACY" ] || return 0
  restore_ok=1
  while IFS='|' read -r unit was_active was_enabled; do
    case "$unit" in
      pi-host.service|pi-host-v2.service) ;;
      *) continue ;;
    esac
    case "$was_enabled" in
      enabled)
        systemctl --user enable "$unit" >/dev/null 2>&1 || restore_ok=0
        ;;
      enabled-runtime)
        systemctl --user enable --runtime "$unit" >/dev/null 2>&1 || restore_ok=0
        ;;
      linked|linked-runtime)
        # The link itself was never removed; stopping the service is sufficient.
        ;;
      *)
        # Other transient/static states are not persistent enablement and were
        # neither disabled during activation nor re-enabled during rollback.
        ;;
    esac
    if [ "$was_active" = "active" ]; then
      if ! systemctl --user start "$unit" >/dev/null 2>&1 ||
         ! systemctl --user is-active --quiet "$unit" >/dev/null 2>&1; then
        restore_ok=0
      fi
    fi
    restored_enabled=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
    [ "$restored_enabled" = "$was_enabled" ] || restore_ok=0
  done <"$TRANSACTION_LEGACY"
  [ "$restore_ok" = 1 ]
}

restore_service_enablement() {
  previous_enabled=$PREVIOUS_SERVICE_ENABLED
  [ ! -f "$TRANSACTION_ENABLED" ] || previous_enabled=$(cat "$TRANSACTION_ENABLED" 2>/dev/null || printf 'disabled')
  case "$previous_enabled" in
    enabled|linked|linked-runtime|alias)
      systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 || return 1
      ;;
    enabled-runtime)
      systemctl --user disable "$UNIT_NAME" >/dev/null 2>&1 || return 1
      systemctl --user enable --runtime "$UNIT_NAME" >/dev/null 2>&1 || return 1
      ;;
    disabled|masked|masked-runtime|not-found)
      # 安装可能在 enable 之前就失败（例如解包/校验阶段），此时 unit 还没被
      # 启用甚至还没写入；先确认当前确已启用再 disable，避免把一次本不需要
      # 回滚的失败误报成 rollback-failed。
      if systemctl --user is-enabled "$UNIT_NAME" >/dev/null 2>&1; then
        systemctl --user disable "$UNIT_NAME" >/dev/null 2>&1 || return 1
      fi
      ;;
    *)
      # static/indirect/generated/transient 等状态没有可恢复的持久 enablement。
      ;;
  esac
  return 0
}

rollback_transaction() {
  [ -f "$TRANSACTION_ACTIVE" ] || return 0
  if attempt_committed "$(cat "$TRANSACTION_ACTIVE" 2>/dev/null || true)"; then
    clear_transaction
    return $?
  fi
  ROLLBACK_RESULT="attempted"
  ROLLBACK_STEP=""
  ROLLBACK_REASON=""
  rollback_ok=1
  if systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; then
    if ! systemctl --user stop "$UNIT_NAME" >/dev/null 2>&1; then
      ROLLBACK_STEP="stop-unit"
      rollback_ok=0
    fi
    if systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; then
      ROLLBACK_STEP="stop-unit"
      rollback_ok=0
    fi
  fi

  previous=$PREVIOUS_CURRENT_TARGET
  failed_install=$INSTALL_DIR
  [ ! -f "$TRANSACTION_PREVIOUS" ] || previous=$(cat "$TRANSACTION_PREVIOUS" 2>/dev/null || printf 'none')
  [ ! -f "$TRANSACTION_INSTALL_DIR" ] || failed_install=$(cat "$TRANSACTION_INSTALL_DIR" 2>/dev/null || true)
  [ -n "$failed_install" ] || failed_install="none"

  # 事务里记录的 previous 可能已经被删掉（上次回滚没做完，或用户清理了
  # releases），也可能本身就是无效值（current 不是软链）。回滚脚本要求
  # previous 是真实存在的 release 目录，照原样传过去只会让恢复也失败；
  # 这些情况一律按 none 处理，由脚本清掉坏的 current。
  case "$previous" in
    releases/*) previous_path="$BASE/$previous" ;;
    "$BASE"/releases/*) previous_path=$previous ;;
    none) previous_path="" ;;
    *) previous_path="invalid" ;;
  esac
  if [ "$previous_path" = "invalid" ] ||
     { [ -n "$previous_path" ] && { [ ! -d "$previous_path" ] || [ -L "$previous_path" ]; }; }; then
    previous="none"
  fi

  # current 只应该是软链。早期异常留下的同名目录会让回滚脚本的 rm 失败，
  # 先移到同目录的隐藏名字里保留数据，再让脚本按 none 清理。
  if [ "$previous" = "none" ]; then
    for name in current current.next; do
      link="$BASE/$name"
      if [ -e "$link" ] && [ ! -L "$link" ]; then
        mv "$link" "$BASE/.$name.invalid.$$" 2>/dev/null || true
      fi
    done
  fi

  rm -f "$WORK/rollback.error"
  if [ -x "$TRANSACTION_ROLLBACK_SCRIPT" ] &&
     "$TRANSACTION_ROLLBACK_SCRIPT" --rollback \
       --home "$BASE" \
       --previous-current-target "$previous" \
       --failed-install-dir "$failed_install" >/dev/null 2>"$WORK/rollback.error"; then
    :
  else
    ROLLBACK_STEP="restore-install"
    ROLLBACK_REASON=$(script_failure_reason "$WORK/rollback.error")
    rollback_ok=0
  fi

  restore_tls || { ROLLBACK_STEP="restore-tls"; rollback_ok=0; }

  # Restore the unit file (or remove a newly-created one) before daemon-reload
  # and before re-enabling/starting the old service.
  unit_path="$HOME/.config/systemd/user/$UNIT_NAME"
  if [ -f "$TRANSACTION_UNIT_BACKUP" ]; then
    mkdir -p "$(dirname "$unit_path")" 2>/dev/null || true
    if cp "$TRANSACTION_UNIT_BACKUP" "$unit_path" 2>/dev/null; then
      chmod 644 "$unit_path" 2>/dev/null || true
    else
      ROLLBACK_STEP="restore-unit"; rollback_ok=0
    fi
  elif [ -f "$TRANSACTION_UNIT_ABSENT" ]; then
    rm -f "$unit_path" 2>/dev/null || true
  fi
  systemctl --user daemon-reload >/dev/null 2>&1 || { ROLLBACK_STEP="restore-unit"; rollback_ok=0; }

  if [ -f "$TRANSACTION_RECEIPT_BACKUP" ]; then
    if ! cp "$TRANSACTION_RECEIPT_BACKUP" "$RECEIPT" 2>/dev/null || ! chmod 600 "$RECEIPT" 2>/dev/null; then
      ROLLBACK_STEP="restore-receipt"; rollback_ok=0
    fi
  else
    rm -f "$RECEIPT" || { ROLLBACK_STEP="restore-receipt"; rollback_ok=0; }
  fi

  restore_service_enablement || { ROLLBACK_STEP="restore-enablement"; rollback_ok=0; }

  previous_service_active=$(cat "$TRANSACTION_SERVICE" 2>/dev/null || printf '%s' "$PREVIOUS_SERVICE_ACTIVE")
  if [ "$previous_service_active" = 1 ]; then
    if ! systemctl --user start "$UNIT_NAME" >/dev/null 2>&1 ||
       ! systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; then
      ROLLBACK_STEP="restart-previous"
      rollback_ok=0
    fi
  fi

  # Legacy units are recovery for the pre-install environment, never evidence
  # of PI-adaptor success. Restore them only when there was no previous
  # PI-adaptor target or the PI-adaptor rollback itself failed.
  if [ "$previous" = "none" ] || [ "$rollback_ok" = 0 ]; then
    restore_legacy_units || { ROLLBACK_STEP="restore-legacy"; rollback_ok=0; }
  fi

  if [ "$rollback_ok" = 1 ]; then
    clear_transaction || { ROLLBACK_STEP="cleanup-rollback"; ROLLBACK_RESULT="failed"; return 1; }
    ROLLBACK_RESULT="succeeded"
    ROLLBACK_STEP=""
    ROLLBACK_REASON=""
    return 0
  fi

  ROLLBACK_RESULT="failed"
  return 1
}

cleanup() {
  cleanup_download
  cleanup_manual
  redact_pair_stderr || true
  rm -f "$PAIR_JSON" "$PAIR_JSON".tmp.* "$ATTEMPT/pair.fifo" "$WORK/manual.pid" \
    "$PAIR_RESULT" "$VERIFY_RESULT" "$CANCEL" "$LEGACY_STATE.next.$$"
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  rm -rf "$DIRECT_TLS.staging.$$"
  rm -rf "$LOCK"
}

die() {
  failure_code=$1
  FAILURE_REASON=${2:-$failure_code}
  trap - HUP INT TERM
  if [ "$CURRENT_STEP" = "done" ] && attempt_committed "$ATTEMPT_ID"; then
    clear_transaction || true
    exit 0
  fi
  cleanup_download
  cleanup_manual
  redact_pair_stderr || true
  rm -f "$PAIR_JSON" "$PAIR_JSON".tmp.* "$ATTEMPT/pair.fifo" "$PAIR_RESULT" "$VERIFY_RESULT"
  refresh_legacy_units_json
  rollback_transaction || ROLLBACK_RESULT="failed"
  if [ "$ROLLBACK_RESULT" = "failed" ]; then
    # 回滚失败不能盖掉真正的失败原因：把原始失败码和回滚卡住的位置一起
    # 汇报，否则用户只能看到无信息量的 rollback-failed。
    FAILURE_REASON="${failure_code}（回滚失败${ROLLBACK_STEP:+：$ROLLBACK_STEP}${ROLLBACK_REASON:+，$ROLLBACK_REASON}）"
    write_state "$CURRENT_STEP" failed "rollback-failed" || true
    printf '%s\n' "PI_HOST_BOOTSTRAP_FAILED rollback-failed" >&2
    printf '%s\n' "PI_HOST_FAILED {\"code\":\"HOST_BOOTSTRAP_FAILED\",\"step\":\"rollback-failed\",\"originalStep\":\"$failure_code\"}"
    exit 1
  fi
  write_state "$CURRENT_STEP" failed "$failure_code" || true
  printf '%s\n' "PI_HOST_BOOTSTRAP_FAILED $failure_code" >&2
  printf '%s\n' "PI_HOST_FAILED {\"code\":\"HOST_BOOTSTRAP_FAILED\",\"step\":\"$failure_code\"}"
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

# install.sh 把真实原因写进 stderr 的 JSON；提取出来作为失败原因，
# 否则界面只能看到笼统的 install-failed。只接受安全字符。
script_failure_reason() {
  reason=$(sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | sed -n '1p')
  printf '%s' "$reason" | LC_ALL=C grep -Eq '^[A-Za-z0-9._[:space:]-]{1,120}$' || reason=""
  printf '%s' "$reason"
}

sha256_of() {
  if need sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif need shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 127
  fi
}

fetch() {
  url=$1
  destination=$2
  if need curl; then
    curl -fsSL --connect-timeout 20 --max-time 900 -o "$destination" "$url"
  elif need wget; then
    wget -q --timeout=900 -O "$destination" "$url"
  else
    return 127
  fi
}

resume_download() {
  url=$1
  destination=$2
  if need curl; then
    exec curl -fL -C - --connect-timeout 20 --max-time 900 -o "$destination" "$url"
  elif need wget; then
    exec wget -c -q --timeout=900 -O "$destination" "$url"
  else
    return 127
  fi
}

download_artifact() {
  resume_download "$ARTIFACT_URL" "$PART" &
  DOWNLOAD_PID=$!
  while kill -0 "$DOWNLOAD_PID" 2>/dev/null; do
    [ ! -f "$CANCEL" ] || die "download-failed" "cancelled"
    if [ -f "$PART" ]; then
      DOWNLOADED_BYTES=$(wc -c <"$PART" | tr -d ' ')
      write_state download running || true
    fi
    sleep 1
  done
  status=0
  wait "$DOWNLOAD_PID" || status=$?
  DOWNLOAD_PID=""
  DOWNLOADED_BYTES=0
  [ ! -f "$PART" ] || DOWNLOADED_BYTES=$(wc -c <"$PART" | tr -d ' ')
  if [ "$status" -ne 0 ] && [ -f "$PART" ] && [ -n "$EXPECTED_SHA256" ]; then
    # curl reports HTTP 416 when a resumed file is already complete. Accept it
    # only when the pinned digest proves that the bytes are exact.
    completed_sha256=$(sha256_of "$PART" 2>/dev/null || true)
    if [ "$completed_sha256" = "$EXPECTED_SHA256" ]; then
      status=0
    fi
  fi
  return "$status"
}

stop_manual_process() {
  requested_pid=$1
  [ -n "$requested_pid" ] || return 0
  kill -0 "$requested_pid" 2>/dev/null || return 0
  command_line=$(ps -p "$requested_pid" -o command= 2>/dev/null || true)
  case "$command_line" in
    *"$BASE/current/dist/main.js"*"--pair"*) ;;
    *) return 0 ;;
  esac
  kill -TERM "$requested_pid" 2>/dev/null || true
  waited=0
  while kill -0 "$requested_pid" 2>/dev/null && [ "$waited" -lt "$STOP_TIMEOUT_SEC" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$requested_pid" 2>/dev/null; then
    kill -KILL "$requested_pid" 2>/dev/null || true
  fi
  sleep 1
  ! kill -0 "$requested_pid" 2>/dev/null
}

if [ -z "${HOME:-}" ]; then
  printf '%s\n' "PI_HOST_BOOTSTRAP_FAILED no-home" >&2
  printf '%s\n' "PI_HOST_FAILED {\"code\":\"HOST_BOOTSTRAP_FAILED\",\"step\":\"no-home\"}"
  exit 1
fi
mkdir -p "$ATTEMPT" || exit 1
chmod 700 "$BASE" "$WORK" "$ATTEMPT" 2>/dev/null || exit 1

reject_busy() {
  printf '%s\n' busy >"$ATTEMPT/start"
  exit 75
}

exec 9>"$WORK/install.flock" || exit 1
lock_status=0
flock -n -E 75 9 || lock_status=$?
[ "$lock_status" -ne 75 ] || reject_busy
[ "$lock_status" -eq 0 ] || exit 1

if ! mkdir "$LOCK" 2>/dev/null; then
  # The pid file is written just after the lock directory is created. Give the
  # winner a short window instead of deleting a fresh lock in that gap.
  attempts=0
  while [ ! -s "$LOCK/pid" ] && [ "$attempts" -lt 20 ]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  old_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    old_command=$(ps -p "$old_pid" -o command= 2>/dev/null || true)
    case "$old_command" in
      *bootstrap.sh*)
        reject_busy
        ;;
    esac
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || reject_busy
fi
trap cleanup EXIT
printf '%s\n' "$$" >"$LOCK/pid" || die "bootstrap-permissions"
trap 'die "stage-failed" "cancelled"' HUP INT TERM
rm -f "$PAIR_RESULT" "$VERIFY_RESULT" "$PAIR_REJECT"
# Released Hosts read the shared path to bind their trust output to this attempt.
[ ! -d "$LEGACY_STATE" ] && ln -s "attempts/$ATTEMPT_ID/state.json" "$LEGACY_STATE.next.$$" &&
  mv -f "$LEGACY_STATE.next.$$" "$LEGACY_STATE" || die "bootstrap-permissions"
printf '%s\n' "$ATTEMPT_ID" >"$WORK/latest-attempt.$$" &&
  mv -f "$WORK/latest-attempt.$$" "$WORK/latest-attempt" || die "bootstrap-permissions"
printf '%s\n' ready >"$ATTEMPT/start" || die "bootstrap-permissions"

# 诊断信息要在此之前采好，否则恢复事务失败时 state.json 里只有 unknown。
SERVER_ARCH=$(uname -m 2>/dev/null | sed -n '1p' || true)
[ -n "$SERVER_ARCH" ] || SERVER_ARCH="unknown"
case "$SERVER_ARCH" in *[!A-Za-z0-9._+-]*) SERVER_ARCH="unknown" ;; esac
NODE_VERSION=$(node -v 2>/dev/null | sed -n '1p' || true)
[ -n "$NODE_VERSION" ] || NODE_VERSION="unknown"
case "$NODE_VERSION" in *[!A-Za-z0-9._+-]*) NODE_VERSION="unknown" ;; esac

if [ -f "$TRANSACTION_ACTIVE" ]; then
  previous_attempt=$(cat "$TRANSACTION_ACTIVE" 2>/dev/null || true)
  if attempt_committed "$previous_attempt"; then
    if ! clear_transaction; then
      write_state probe failed "bootstrap-permissions" || true
      exit 1
    fi
  else
    previous_pid=$(cat "$WORK/manual.pid" 2>/dev/null || true)
    stop_manual_process "$previous_pid" || die "host-stop-timeout"
    PREVIOUS_CURRENT_TARGET=$(cat "$TRANSACTION_PREVIOUS" 2>/dev/null || printf 'none')
    PREVIOUS_SERVICE_ACTIVE=$(cat "$TRANSACTION_SERVICE" 2>/dev/null || printf '0')
    PREVIOUS_SERVICE_ENABLED=$(cat "$TRANSACTION_ENABLED" 2>/dev/null || printf 'disabled')
    INSTALL_DIR=$(cat "$TRANSACTION_INSTALL_DIR" 2>/dev/null || true)
    refresh_legacy_units_json
    if ! rollback_transaction; then
      FAILURE_REASON="recovery（回滚失败${ROLLBACK_STEP:+：$ROLLBACK_STEP}${ROLLBACK_REASON:+，$ROLLBACK_REASON}）"
      write_state probe failed "rollback-failed" || true
      printf '%s\n' "PI_HOST_BOOTSTRAP_FAILED rollback-failed" >&2
      printf '%s\n' "PI_HOST_FAILED {\"code\":\"HOST_BOOTSTRAP_FAILED\",\"step\":\"rollback-failed\",\"originalStep\":\"recovery\"}"
      exit 1
    fi
  fi
fi
find "$WORK/attempts" -mindepth 1 -maxdepth 1 -type d ! -name "$ATTEMPT_ID" -mtime +1 \
  -exec rm -rf {} + 2>/dev/null || true

step "probe"
ARTIFACT_BYTES=0
DOWNLOADED_BYTES=0
write_state probe running || die "bootstrap-permissions"

need tar || die "missing-tar"
need mkfifo || die "missing-tar"
need bash || die "missing-bash"
sha256_of /dev/null >/dev/null 2>&1 || die "missing-sha256-tool"

# 失败诊断：Node 太旧只会在 install.sh 内部报 install-failed，这里前置
# 判定，并保证 state.json 里已有服务器架构与 Node 版本。
if ! need node; then
  NODE_VERSION="missing"
  die "missing-node"
fi
node_path=$(command -v node)
"$node_path" -e '
  const parse = (value) => value.split(".").map((part) => Number(part));
  const current = parse(process.versions.node);
  const minimum = parse(process.argv[1]);
  for (let i = 0; i < 3; i += 1) {
    if (current[i] > minimum[i]) process.exit(0);
    if (current[i] < minimum[i]) process.exit(1);
  }
' "$MIN_NODE_VERSION" 2>/dev/null || die "node-too-old"

check_host_version() {
  version_status=0
  ACTUAL_VERSION=$("$node_path" -e '
    const { readFileSync } = require("node:fs");
    const [source, value, requested] = process.argv.slice(1);
    const readyPrefix = "PI_HOST_READY ";
    if (source === "ready" && !value.startsWith(readyPrefix)) process.exit(2);
    const actual = JSON.parse(source === "ready" ? value.slice(readyPrefix.length) : readFileSync(value, "utf8")).version;
    const versionPattern = /^v?[0-9]+(?:\.[0-9]+)*(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
    if (typeof actual !== "string" || actual.trim() !== actual ||
        !versionPattern.test(actual) || !versionPattern.test(requested)) {
      process.exit(2);
    }
    const parts = (version) => version.replace(/^v/, "").split(/[+-]/, 1)[0].split(".").map(BigInt);
    const installed = parts(actual);
    const target = parts(requested);
    for (let index = 0; index < Math.max(installed.length, target.length); index++) {
      const left = installed[index] ?? 0n;
      const right = target[index] ?? 0n;
      if (left === right) continue;
      if (left > right) process.exitCode = 3;
      break;
    }
    process.stdout.write(actual);
  ' "$1" "$2" "$VERSION" 2>/dev/null) || version_status=$?
  case "$version_status" in
    0) ;;
    3) die "downgrade-blocked" ;;
    *) ACTUAL_VERSION=""; die "$3" ;;
  esac
}

check_downgrade() {
  ACTUAL_VERSION=""
  if [ -f "$BASE/current/package.json" ] || [ -f "$BASE/current/dist/main.js" ]; then
    check_host_version file "$BASE/current/package.json" "installed-version-unknown"
  fi

  # A changed current symlink cannot identify a process that started earlier.
  running_state=$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)
  case "$running_state" in
    inactive|failed|unknown) return 0 ;;
    active|reloading|refreshing|activating|deactivating) ;;
    *) ACTUAL_VERSION=""; die "running-version-unknown" ;;
  esac
  ACTUAL_VERSION=""
  running_unit=$(systemctl --user show "$UNIT_NAME" --property=MainPID --property=InvocationID 2>/dev/null) ||
    die "running-version-unknown"
  running_pid=$(printf '%s\n' "$running_unit" | sed -n 's/^MainPID=//p')
  running_invocation=$(printf '%s\n' "$running_unit" | sed -n 's/^InvocationID=//p')
  case "$running_pid" in ''|0|*[!0-9]*) die "running-version-unknown" ;; esac
  case "$running_invocation" in ''|*[!0-9a-f]*) die "running-version-unknown" ;; esac
  [ "${#running_invocation}" -eq 32 ] || die "running-version-unknown"
  running_ready=$(journalctl --user-unit="$UNIT_NAME" --boot --no-pager --output=cat \
    --grep='^PI_HOST_READY ' --lines=1 "_PID=$running_pid" "_SYSTEMD_INVOCATION_ID=$running_invocation" 2>/dev/null) ||
    die "running-version-unknown"
  [ "$running_unit" = "$(systemctl --user show "$UNIT_NAME" --property=MainPID --property=InvocationID 2>/dev/null)" ] ||
    die "running-version-unknown"
  check_host_version ready "$running_ready" "running-version-unknown"
}

check_downgrade

progress "resolve"
[ ! -f "$CANCEL" ] || die "download-failed" "cancelled"
rm -f "$CHECKSUM_FILE"
fetch "$CHECKSUM_URL" "$CHECKSUM_FILE" || die "download-failed"
chmod 600 "$CHECKSUM_FILE" 2>/dev/null || die "artifact-permissions"
EXPECTED_SHA256=$(
  awk -v expected="$ARTIFACT_NAME" '
    length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ {
      name = $2
      sub(/^\*/, "", name)
      count = split(name, parts, "/")
      if (parts[count] == expected) {
        print tolower($1)
        exit
      }
    }
  ' "$CHECKSUM_FILE"
)
printf '%s\n' "$EXPECTED_SHA256" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || die "checksum-mismatch"
printf '%s\n' "$PINNED_SHA256" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || die "checksum-mismatch"
if [ "$EXPECTED_SHA256" != "$PINNED_SHA256" ]; then
  die "checksum-mismatch"
fi
write_state resolve running || die "bootstrap-permissions"

reuse=0
manifest_sha256=""
if [ "$FORCE_INSTALL" = 1 ]; then
  # 强制重装：不信任任何本地 receipt，重新下载并激活（用户点「重新安装」时走这里）。
  progress "force"
elif [ -f "$RECEIPT" ] && [ -L "$BASE/current" ] && [ -f "$BASE/current/SHA256SUMS" ]; then
  receipt_fields=$(node -e '
    const fs = require("fs");
    try {
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write([
        value.schemaVersion,
        value.version,
        value.target,
        value.assetSha256,
        value.installedManifestSha256,
        value.bundleDirectory,
        value.installDirectory,
        value.entrypoint,
        value.unitName,
      ].map((item) => item == null ? "" : String(item)).join("\n"));
    } catch {
      process.exit(1);
    }
  ' "$RECEIPT" 2>/dev/null || true)
  receipt_schema=$(printf '%s\n' "$receipt_fields" | sed -n '1p')
  receipt_version=$(printf '%s\n' "$receipt_fields" | sed -n '2p')
  receipt_target=$(printf '%s\n' "$receipt_fields" | sed -n '3p')
  receipt_asset=$(printf '%s\n' "$receipt_fields" | sed -n '4p')
  receipt_manifest=$(printf '%s\n' "$receipt_fields" | sed -n '5p')
  receipt_bundle=$(printf '%s\n' "$receipt_fields" | sed -n '6p')
  receipt_install=$(printf '%s\n' "$receipt_fields" | sed -n '7p')
  receipt_entrypoint=$(printf '%s\n' "$receipt_fields" | sed -n '8p')
  receipt_unit=$(printf '%s\n' "$receipt_fields" | sed -n '9p')
  manifest_sha256=$(sha256_of "$BASE/current/SHA256SUMS") || die "missing-sha256-tool"
  expected_target="releases/$VERSION-$EXPECTED_SHA256"
  receipt_install_matches=0
  if [ -n "$receipt_install" ] && [ -d "$receipt_install" ] && [ -d "$BASE/$expected_target" ]; then
    receipt_install_matches=$(node -e '
      const fs = require("fs");
      try {
        const actual = fs.realpathSync(process.argv[1]);
        const expected = fs.realpathSync(process.argv[2]);
        process.stdout.write(actual === expected ? "1" : "0");
      } catch {
        process.stdout.write("0");
      }
    ' "$receipt_install" "$BASE/$expected_target")
  fi
  if [ "$receipt_schema" = "1" ] &&
     [ "$receipt_version" = "$VERSION" ] &&
     [ "$receipt_target" = "$TARGET" ] &&
     [ "$receipt_asset" = "$EXPECTED_SHA256" ] &&
     [ "$receipt_manifest" = "$manifest_sha256" ] &&
     [ "$receipt_bundle" = "pi-adaptor-$VERSION-$TARGET" ] &&
     [ "$receipt_install_matches" = "1" ] &&
     [ "$receipt_entrypoint" = "dist/main.js" ] &&
     [ "$receipt_unit" = "$UNIT_NAME" ] &&
     [ "$(readlink "$BASE/current" 2>/dev/null || true)" = "$expected_target" ] &&
     "$BASE/current/scripts/install.sh" --verify \
       --install-dir "$BASE/current" \
       --version "$VERSION" \
       --target "$TARGET" \
       --asset-sha256 "$EXPECTED_SHA256" \
       --manifest-sha256 "$manifest_sha256" >/dev/null 2>&1; then
    reuse=1
    step "reuse"
  fi
fi

if [ "$reuse" = 0 ]; then
  progress "download"
  download_artifact || die "download-failed"
  [ -f "$PART" ] || die "download-failed"
  chmod 600 "$PART" 2>/dev/null || die "artifact-permissions"
  ARTIFACT_BYTES=$DOWNLOADED_BYTES
  write_state download running || die "bootstrap-permissions"

  progress "verify"
  actual_sha256=$(sha256_of "$PART") || die "missing-sha256-tool"
  if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
    rm -f "$PART"
    die "checksum-mismatch"
  fi

  progress "extract"
  STAGE=$(mktemp -d "$BASE/.stage.XXXXXX") || die "stage-failed"
  unpack="$STAGE/unpack"
  mkdir -p "$unpack" || die "extract-failed"
  tar -xzf "$PART" -C "$unpack" || die "extract-failed"
  [ -d "$unpack/$BUNDLE_DIR" ] || die "unexpected-archive-layout"
  [ -f "$unpack/$BUNDLE_DIR/dist/main.js" ] || die "unexpected-archive-layout"
  [ -f "$unpack/$BUNDLE_DIR/scripts/install.sh" ] || die "unexpected-archive-layout"
  [ -f "$unpack/$BUNDLE_DIR/SHA256SUMS" ] || die "unexpected-archive-layout"
  manifest_sha256=$(sha256_of "$unpack/$BUNDLE_DIR/SHA256SUMS") || die "missing-sha256-tool"
  cp "$unpack/$BUNDLE_DIR/scripts/install.sh" "$ROLLBACK_SCRIPT" || die "install-failed"
  chmod 700 "$ROLLBACK_SCRIPT"
  INSTALL_DIR="$RELEASES/$VERSION-$EXPECTED_SHA256"
  [ ! -f "$CANCEL" ] || die "stage-failed" "cancelled"
  check_downgrade
  record_transaction
  progress "activate"
  if ! "$unpack/$BUNDLE_DIR/scripts/install.sh" --install \
    --bundle "$unpack/$BUNDLE_DIR" \
    --home "$BASE" \
    --version "$VERSION" \
    --target "$TARGET" \
    --asset-sha256 "$EXPECTED_SHA256" \
    --manifest-sha256 "$manifest_sha256" >/dev/null 2>"$WORK/install.error"; then
    die "install-failed" "$(script_failure_reason "$WORK/install.error")"
  fi
  rm -f "$WORK/install.error"
  rm -f "$PART"
else
  cp "$BASE/current/scripts/install.sh" "$ROLLBACK_SCRIPT" || die "install-failed"
  chmod 700 "$ROLLBACK_SCRIPT"
  INSTALL_DIR="$RELEASES/$VERSION-$EXPECTED_SHA256"
  [ ! -f "$CANCEL" ] || die "stage-failed" "cancelled"
  check_downgrade
  record_transaction
  progress "activate"
  if ! "$ROLLBACK_SCRIPT" --install \
    --bundle "$BASE/current" \
    --home "$BASE" \
    --version "$VERSION" \
    --target "$TARGET" \
    --asset-sha256 "$EXPECTED_SHA256" \
    --manifest-sha256 "$manifest_sha256" >/dev/null 2>"$WORK/install.error"; then
    die "install-failed" "$(script_failure_reason "$WORK/install.error")"
  fi
  rm -f "$WORK/install.error"
fi

if ! "$ROLLBACK_SCRIPT" --verify \
  --install-dir "$BASE/current" \
  --version "$VERSION" \
  --target "$TARGET" \
  --asset-sha256 "$EXPECTED_SHA256" \
  --manifest-sha256 "$manifest_sha256" >/dev/null 2>"$WORK/verify.error"; then
  die "installed-verification-failed" "$(script_failure_reason "$WORK/verify.error")"
fi
rm -f "$WORK/verify.error"
installed_version=$(node -e '
  const fs = require("fs");
  process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version || ""));
' "$BASE/current/package.json" 2>/dev/null || true)
[ "$installed_version" = "$VERSION" ] || die "installed-verification-failed"

# Optional direct TLS. Failure leaves the complete loopback/SSH pairing path available.
if [ "$DIRECT_REQUESTED" = 1 ]; then
  if [ ! -d "$DIRECT_TLS" ] || chmod 700 "$DIRECT_TLS"; then
    previous_name=$(cat "$DIRECT_TLS/direct-name" 2>/dev/null || true)
    reuse_ok=0
    if [ "$previous_name" = "$DIRECT_NAME" ] && [ -f "$DIRECT_TLS/direct-cert.pem" ] && [ -f "$DIRECT_TLS/direct-key.pem" ] && \
       openssl x509 -in "$DIRECT_TLS/direct-cert.pem" -noout -checkend 2592000 >/dev/null 2>&1 && \
       openssl x509 -in "$DIRECT_TLS/direct-cert.pem" -noout -text 2>/dev/null | grep -q 'CA:FALSE' && \
       openssl x509 -in "$DIRECT_TLS/direct-cert.pem" -noout -ext subjectAltName 2>/dev/null | grep -Fq "$DIRECT_SAN" && \
       [ "$(openssl x509 -in "$DIRECT_TLS/direct-cert.pem" -noout -pubkey 2>/dev/null)" = "$(openssl pkey -in "$DIRECT_TLS/direct-key.pem" -pubout 2>/dev/null)" ] && \
       [ "$(stat -c '%a' "$DIRECT_TLS/direct-key.pem" 2>/dev/null || printf '600')" = "600" ]; then
      reuse_ok=1
    fi
    if [ "$reuse_ok" != 1 ]; then
      tls_staging="$DIRECT_TLS.staging.$$"
      rm -rf "$tls_staging"
      if mkdir -p "$tls_staging" && chmod 700 "$tls_staging" && \
        openssl req -x509 -newkey rsa:3072 -sha256 -days 825 -nodes \
          -keyout "$tls_staging/direct-key.pem" \
          -out "$tls_staging/direct-cert.pem" \
          -subj "/CN=pi-adaptor" \
          -addext "basicConstraints=critical,CA:FALSE" \
          -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
          -addext "extendedKeyUsage=serverAuth" \
          -addext "subjectAltName=$DIRECT_SAN" \
          >/dev/null 2>&1 && \
        openssl pkey -in "$tls_staging/direct-key.pem" -check -noout >/dev/null 2>&1 && \
        openssl x509 -in "$tls_staging/direct-cert.pem" -noout -checkend 0 -text 2>/dev/null | grep -q 'CA:FALSE' && \
        chmod 600 "$tls_staging/direct-key.pem" && \
        printf '%s\n' "$DIRECT_NAME" >"$tls_staging/direct-name" && \
        chmod 600 "$tls_staging/direct-name"; then
        if [ -e "$DIRECT_TLS" ] || [ -L "$DIRECT_TLS" ]; then
          mv "$DIRECT_TLS" "$TRANSACTION_TLS_BACKUP" || die "bootstrap-permissions"
        else
          : >"$TRANSACTION_TLS_ABSENT" || die "bootstrap-permissions"
        fi
        if mv "$tls_staging" "$DIRECT_TLS"; then
          DIRECT_ACTIVE=1
        else
          restore_tls || die "bootstrap-permissions"
        fi
      else
        rm -rf "$tls_staging"
      fi
    else
      # The validated reuse path above already set DIRECT_ACTIVE.
      DIRECT_ACTIVE=1
    fi
  fi
fi

# Node 版本已在 probe 阶段前置检查；这里只需要可执行路径写进 unit。
node=$(command -v node) || die "missing-node"

progress "write-unit"
unit_dir="$HOME/.config/systemd/user"
mkdir -p "$unit_dir" || die "unit-failed"
unit_path="$unit_dir/$UNIT_NAME"
unit_tmp="$unit_dir/.$UNIT_NAME.$$"
{
  printf '%s\n' '[Unit]'
  printf '%s\n' 'Description=PI-adaptor'
  printf '%s\n' 'After=network.target'
  printf '%s\n' ''
  printf '%s\n' '[Service]'
  printf '%s\n' 'Type=simple'
  printf 'Environment="PI_ADAPTOR_HOME=%s"\n' "$BASE"
  printf 'Environment="PI_ADAPTOR_PORT=%s"\n' "$PORT"
  printf 'Environment="PI_ADAPTOR_HOST_ID=pi-adaptor-%s"\n' "$HOST_ARCH"
  printf 'Environment="PI_ADAPTOR_DIRECT_ENABLED=%s"\n' "$DIRECT_ACTIVE"
  if [ "$DIRECT_ACTIVE" = 1 ]; then
    printf 'Environment="PI_ADAPTOR_DIRECT_HOST=0.0.0.0"\n'
    printf 'Environment="PI_ADAPTOR_DIRECT_PORT=%s"\n' "$DIRECT_PORT"
    printf 'Environment="PI_ADAPTOR_DIRECT_CERTIFICATE_FILE=%s"\n' "$DIRECT_TLS/direct-cert.pem"
    printf 'Environment="PI_ADAPTOR_DIRECT_PRIVATE_KEY_FILE=%s"\n' "$DIRECT_TLS/direct-key.pem"
  fi
  printf 'ExecStart="%s" "%s/current/dist/main.js" --home "%s" --port %s\n' \
    "$node" "$BASE" "$BASE" "$PORT"
  printf 'WorkingDirectory=%s\n' "$BASE"
  printf '%s\n' 'Restart=on-failure'
  printf '%s\n' 'RestartSec=2'
  printf '%s\n' 'NoNewPrivileges=yes'
  printf '%s\n' ''
  printf '%s\n' '[Install]'
  printf '%s\n' 'WantedBy=default.target'
} >"$unit_tmp" || die "unit-failed"
chmod 644 "$unit_tmp" 2>/dev/null || die "unit-failed"
mv -f "$unit_tmp" "$unit_path" || die "unit-failed"
SERVICE_STATE="written"
write_state "write-unit" running "" "written" || die "bootstrap-permissions"
systemctl --user daemon-reload >/dev/null 2>&1 || die "unit-failed"
install_user=$(id -un)
if [ "$(loginctl show-user "$install_user" --property=Linger --value 2>/dev/null || true)" != yes ]; then
  loginctl enable-linger "$install_user" >/dev/null 2>&1 || die "unit-failed"
fi
# 只 start 不 enable 的话，重启后服务不会自动拉起，设备会失联。
systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 || die "unit-failed"

progress "start-pair"
systemctl --user stop "$UNIT_NAME" >/dev/null 2>&1 || true
if systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; then
  die "unit-failed"
fi

for legacy_unit in pi-host.service pi-host-v2.service; do
  legacy_active=$(systemctl --user show "$legacy_unit" \
    --property=ActiveState 2>/dev/null | sed -n 's/^ActiveState=//p' | head -n 1)
  if [ "$legacy_active" = "active" ]; then
    legacy_exec=$(systemctl --user show "$legacy_unit" \
      --property=ExecStart 2>/dev/null | sed -n 's/^ExecStart=//p' | head -n 1)
    if printf '%s\n' "$legacy_exec" |
       grep -Eq -- "(^|[[:space:]])--port(=|[[:space:]])$PORT([[:space:];}]|$)"; then
      legacy_enabled=$(systemctl --user is-enabled "$legacy_unit" 2>/dev/null || printf 'disabled')
      case "$legacy_enabled" in
        ''|*[!A-Za-z0-9-]*) legacy_enabled="unknown" ;;
      esac
      printf '%s|active|%s\n' "$legacy_unit" "$legacy_enabled" >>"$TRANSACTION_LEGACY"
      chmod 600 "$TRANSACTION_LEGACY" 2>/dev/null || die "bootstrap-permissions"
      LEGACY_UNITS_STOPPED="$LEGACY_UNITS_STOPPED $legacy_unit"
      systemctl --user stop "$legacy_unit" >/dev/null 2>&1 ||
        die "unit-failed" "legacy-service-conflict"
      case "$legacy_enabled" in
        enabled)
          systemctl --user disable "$legacy_unit" >/dev/null 2>&1 ||
            die "unit-failed" "legacy-service-conflict"
          ;;
        enabled-runtime)
          systemctl --user disable --runtime "$legacy_unit" >/dev/null 2>&1 ||
            die "unit-failed" "legacy-service-conflict"
          ;;
        linked|linked-runtime)
          # Stopping the process must not unlink a user-managed unit.
          ;;
        *)
          # Static, generated, transient and other non-persistent states cannot
          # be disabled without changing user-managed enablement.
          ;;
      esac
    fi
  fi
done
if ps -eo pid=,args= 2>/dev/null |
   grep -E 'pi-host\.js' | grep -E -- "--port[ =]$PORT([[:space:]]|$)" >/dev/null 2>&1; then
  die "unit-failed" "legacy-service-conflict"
fi
if need ss && ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q .; then
  die "unit-failed" "legacy-service-conflict"
fi
if ! need ss && need lsof &&
   lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "unit-failed" "legacy-service-conflict"
fi

previous_pid=$(cat "$WORK/manual.pid" 2>/dev/null || true)
stop_manual_process "$previous_pid" || die "host-stop-timeout"
rm -f "$PAIR_JSON" "$PAIR_RESULT" "$PAIR_REJECT" "$VERIFY_RESULT" "$ATTEMPT/pair.fifo"

mkfifo "$ATTEMPT/pair.fifo" || die "host-start-failed"
chmod 600 "$ATTEMPT/pair.fifo" 2>/dev/null || die "bootstrap-permissions"
: >"$ATTEMPT/pair.err"
chmod 600 "$ATTEMPT/pair.err" 2>/dev/null || die "bootstrap-permissions"

# The manual and systemd processes must use the same isolated root.
rm -f "$DIRECT_TRUST"
if [ "$DIRECT_ACTIVE" = 1 ]; then
  PI_ADAPTOR_DIRECT_HOST="0.0.0.0"
  PI_ADAPTOR_DIRECT_PORT="$DIRECT_PORT"
  PI_ADAPTOR_DIRECT_CERTIFICATE_FILE="$DIRECT_TLS/direct-cert.pem"
  PI_ADAPTOR_DIRECT_PRIVATE_KEY_FILE="$DIRECT_TLS/direct-key.pem"
  export PI_ADAPTOR_DIRECT_HOST PI_ADAPTOR_DIRECT_PORT
  export PI_ADAPTOR_DIRECT_CERTIFICATE_FILE PI_ADAPTOR_DIRECT_PRIVATE_KEY_FILE
fi
PI_ADAPTOR_HOME="$BASE" \
PI_ADAPTOR_DIRECT_ENABLED="$DIRECT_ACTIVE" \
"$node" "$BASE/current/dist/main.js" \
  --home "$BASE" \
  --port "$PORT" \
  --pair \
  --pairing-lifetime-ms "$PAIRING_LIFETIME_MS" \
  >"$ATTEMPT/pair.fifo" 2>"$ATTEMPT/pair.err" </dev/null 9>&- &
MANUAL_PID=$!
printf '%s\n' "$MANUAL_PID" >"$WORK/manual.pid"
chmod 600 "$WORK/manual.pid" 2>/dev/null || die "bootstrap-permissions"

(
  ready_host=""
  ready_port=""
  token=""
  expires_at=0
  while IFS= read -r line; do
    case "$line" in
      'PI_HOST_READY '*)
        ready_json=${line#PI_HOST_READY }
        candidate_host=$(printf '%s\n' "$ready_json" | sed -n 's/.*"host"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        candidate_port=$(printf '%s\n' "$ready_json" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        if { [ "$candidate_host" = "127.0.0.1" ] || [ "$candidate_host" = "::1" ]; } && \
           [ -n "$candidate_port" ] && [ "$candidate_port" -ge 1 ] && [ "$candidate_port" -le 65535 ]; then
          ready_host=$candidate_host
          ready_port=$candidate_port
        fi
        ;;
      'PI_HOST_DIRECT_TRUST '*)
        trust_json=${line#PI_HOST_DIRECT_TRUST }
        trust_attempt=$(printf '%s\n' "$trust_json" | sed -n 's/.*"attemptId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        if [ "$trust_attempt" = "$ATTEMPT_ID" ]; then
          trust_tmp="$DIRECT_TRUST.tmp.$$"
          printf '%s\n' "$trust_json" >"$trust_tmp" || exit 1
          chmod 600 "$trust_tmp" 2>/dev/null || exit 1
          mv -f "$trust_tmp" "$DIRECT_TRUST" || exit 1
        fi
        ;;
      'PI_HOST_PAIRING_TOKEN '*)
        token_json=${line#PI_HOST_PAIRING_TOKEN }
        candidate=$(printf '%s\n' "$token_json" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        case "$candidate" in
          ppt2.*) ;;
          ppt1.*)
            if [ "$ALLOW_LEGACY_PPT1" != 1 ]; then
              printf '%s\n' legacy-pairing-token >"$PAIR_REJECT"
              continue
            fi
            ;;
          *) candidate="" ;;
        esac
        case "$candidate" in
          '') ;;
          *[!A-Za-z0-9._-]*) candidate="" ;;
        esac
        candidate_expires=$(printf '%s\n' "$token_json" | sed -n 's/.*"expiresAt"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        case "$candidate_expires" in
          ''|*[!0-9]*) candidate_expires=0 ;;
        esac
        if [ -n "$candidate" ]; then
          token=$candidate
          expires_at=$candidate_expires
        fi
        ;;
    esac
    if [ -n "$ready_host" ] && [ -n "$ready_port" ] && [ -n "$token" ] && [ ! -f "$PAIR_JSON" ]; then
      pair_tmp="$PAIR_JSON.tmp.$$"
      printf '{"token":"%s","expiresAt":%s,"host":"%s","port":%s}\n' \
        "$token" "$expires_at" "$ready_host" "$ready_port" >"$pair_tmp" || exit 1
      chmod 600 "$pair_tmp" 2>/dev/null || exit 1
      mv -f "$pair_tmp" "$PAIR_JSON" || exit 1
    fi
  done <"$ATTEMPT/pair.fifo"
) 9>&- &
PAIR_READER_PID=$!

waited=0
while [ ! -s "$PAIR_JSON" ]; do
  [ -f "$CANCEL" ] && die "pair-failed" "cancelled"
  if [ -s "$PAIR_REJECT" ]; then
    reason=$(cat "$PAIR_REJECT" 2>/dev/null || printf 'pair-failed')
    die "pair-failed" "$reason"
  fi
  if ! kill -0 "$MANUAL_PID" 2>/dev/null; then
    if grep -q '^PI_HOST_FAILED ' "$ATTEMPT/pair.err" 2>/dev/null; then
      die "host-start-failed"
    fi
    die "host-exited"
  fi
  [ "$waited" -lt "$READY_TIMEOUT_SEC" ] || die "ready-timeout"
  sleep 1
  waited=$((waited + 1))
done

CURRENT_STEP="pair"
step "pair"
write_state "pair" running || die "bootstrap-permissions"

waited=0
while [ ! -s "$PAIR_RESULT" ]; do
  [ -f "$CANCEL" ] && die "pair-failed" "cancelled"
  if ! kill -0 "$MANUAL_PID" 2>/dev/null; then
    die "host-exited"
  fi
  [ "$waited" -lt "$PAIR_TIMEOUT_SEC" ] || die "pair-failed"
  sleep 1
  waited=$((waited + 1))
done
pair_result=$(cat "$PAIR_RESULT" 2>/dev/null || true)
redact_pair_stderr || die "bootstrap-permissions"
rm -f "$PAIR_JSON" "$PAIR_RESULT"
[ "$pair_result" = "ok" ] || die "pair-failed"

progress "stop-manual"
manual_to_stop=$MANUAL_PID
cleanup_manual
kill -0 "$manual_to_stop" 2>/dev/null && die "host-stop-timeout"
rm -f "$ATTEMPT/pair.fifo" "$WORK/manual.pid"

progress "start-unit"
systemctl --user start "$UNIT_NAME" >/dev/null 2>&1 || die "unit-failed"
systemctl --user is-active --quiet "$UNIT_NAME" >/dev/null 2>&1 || die "unit-failed"
SERVICE_STATE="active"
CURRENT_SERVICE_STOPPED=0
write_state "start-unit" running "" "active" || die "bootstrap-permissions"

progress "verify-device"
waited=0
while [ ! -s "$VERIFY_RESULT" ]; do
  [ -f "$CANCEL" ] && die "verify-device-failed" "cancelled"
  [ "$waited" -lt "$VERIFY_TIMEOUT_SEC" ] || die "verify-device-failed"
  sleep 1
  waited=$((waited + 1))
done
verify_result=$(cat "$VERIFY_RESULT" 2>/dev/null || true)
rm -f "$VERIFY_RESULT"
[ "$verify_result" = "ok" ] || die "verify-device-failed"

CURRENT_STEP="done"
step "done"
# Rename the active journal into the success state so even an older installer sees the commit.
write_state "done" ok "" "active" "$TRANSACTION_ACTIVE" &&
  mv -f "$TRANSACTION_ACTIVE" "$STATE" || die "receipt-failed"
clear_transaction || true
"""#
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The non-secret progress commands used between polling reads.
public enum BootstrapRemoteCommand {
    /// One exec performs the only platform probe used by the whole run.
    public static let probe = #"printf 'platform=%s\narch=%s\n' "$(uname -s)" "$(uname -m)""#

    public static func scoped(_ command: String, attemptId: String) -> String {
        guard BootstrapScriptValidation.isAttemptId(attemptId) else { return "exit 64" }
        return #"attempt="$HOME/.pi-adaptor/.bootstrap/attempts/\#(attemptId)""# + "\n" + command
    }

    public static let installScript = #"umask 077; mkdir -p "${attempt%/*}" && mkdir "$attempt" && cat > "$attempt/bootstrap.sh" && chmod 700 "$attempt/bootstrap.sh""#

    public static let launch = #"""
    umask 077
    for tool in setsid nohup flock; do command -v "$tool" >/dev/null 2>&1 || exit 69; done
    cd "$attempt" || exit 1
    setsid nohup /bin/sh ./bootstrap.sh >bootstrap.log 2>&1 </dev/null &
    launcher_pid=$!
    waited=0
    while [ "$waited" -lt 60 ]; do
      case "$(cat start 2>/dev/null)" in
        ready) printf 'pid=%s\n' "$launcher_pid"; exit 0 ;;
        busy) cd / && rm -rf "$attempt"; exit 75 ;;
      esac
      sleep 0.1
      waited=$((waited + 1))
    done
    : >cancel
    exit 1
    """#

    public static let readState = #"cat "$attempt/state.json" 2>/dev/null || true"#

    public static let readPairing = #"cat "$attempt/pair.json" 2>/dev/null || true"#

    public static let writePairingOK = #"umask 077; printf '%s\n' ok > "$attempt/pair.result" && chmod 600 "$attempt/pair.result""#

    public static let writePairingFailed = #"umask 077; printf '%s\n' failed > "$attempt/pair.result" && chmod 600 "$attempt/pair.result""#

    public static let writeVerificationOK = #"umask 077; printf '%s\n' ok > "$attempt/verify.result" && chmod 600 "$attempt/verify.result""#

    public static let writeVerificationFailed = #"umask 077; printf '%s\n' failed > "$attempt/verify.result" && chmod 600 "$attempt/verify.result""#

    public static let cancel = #"umask 077; printf '%s\n' cancel > "$attempt/cancel" && chmod 600 "$attempt/cancel""#
}

/// Token material handed from the owner-only remote file to the pairing
/// callback. This value must never be logged or persisted on the client.
public struct BootstrapPairingMaterial: Codable, Equatable, Sendable {
    public let token: String
    public let expiresAt: Int64
    public let host: String
    public let port: Int

    public init(
        token: String,
        expiresAt: Int64,
        host: String,
        port: Int,
        allowLegacyPPT1: Bool = false
    ) throws {
        let isPPT2 = token.hasPrefix("ppt2.")
        let isPPT1 = allowLegacyPPT1 && token.hasPrefix("ppt1.")
        guard isPPT2 || isPPT1,
              token.utf8.count > "ppt2.".count,
              token.unicodeScalars.allSatisfy({
                  $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
              }),
              host == "127.0.0.1" || host == "::1",
              (1...65_535).contains(port) else {
            throw BootstrapPairingMaterialError.invalid
        }
        self.token = token
        self.expiresAt = expiresAt
        self.host = host
        self.port = port
    }

    public var redactedDescription: String {
        "配对令牌（已隐藏），目标 \(host):\(port)"
    }
}

public enum BootstrapPairingMaterialError: Error, Equatable {
    case invalid
}
