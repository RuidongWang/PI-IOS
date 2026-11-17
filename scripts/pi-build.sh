#!/usr/bin/env bash
# 串行化的增量编译入口。
#
# 为什么需要它：所有人共用同一份 DerivedData，多个 xcodebuild 并发会互相踩坏产物。
# 这个脚本用文件锁把编译串行化，增量约 8 秒，比每人各建一份 DerivedData 便宜得多。
#
# 用法：
#   bash scripts/pi-build.sh            # 编译 App
#   bash scripts/pi-build.sh --tests    # 连 UI 测试 target 一起 build-for-testing
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UDID="${PI_SIM_UDID:-08BEDA92-4CC5-4423-8D70-17A73BCA19C8}"
ACTION="build"
ONLY_TESTING=()
if [[ "${1:-}" == "--tests" ]]; then
  ACTION="build-for-testing"
  ONLY_TESTING=(-only-testing:PI-IOSUITests)
fi

LOCK=/tmp/pi-ios-build.lock
exec python3 - "$LOCK" "$ROOT" "$UDID" "$ACTION" "${ONLY_TESTING[@]:-}" <<'PY'
import fcntl, os, subprocess, sys
lock, root, udid, action, *extra = sys.argv[1:]
extra = [e for e in extra if e]
fh = open(lock, "w")
fcntl.flock(fh, fcntl.LOCK_EX)
cmd = [
    "arch", "-arm64", "env",
    "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer",
    "xcodebuild",
    "-project", f"{root}/apps/ios/PI-IOS.xcodeproj",
    "-scheme", "PI-IOS",
    "-destination", f"platform=iOS Simulator,id={udid}",
    "-derivedDataPath", f"{root}/apps/ios/build/DerivedData",
    "-clonedSourcePackagesDirPath", f"{root}/apps/ios/build/DerivedData/SourcePackages",
    "-onlyUsePackageVersionsFromResolvedFile",
    "-parallel-testing-enabled", "NO",
    *extra,
    action,
]
r = subprocess.run(cmd, capture_output=True, text=True)
out = (r.stdout or "") + (r.stderr or "")
errors = [l for l in out.splitlines() if ": error:" in l]
for line in errors[:40]:
    print(line)
tail = [l for l in out.splitlines() if "BUILD SUCCEEDED" in l or "BUILD FAILED" in l]
print(tail[-1] if tail else "BUILD RESULT UNKNOWN")
sys.exit(0 if r.returncode == 0 else 1)
PY
