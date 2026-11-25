import Foundation

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

