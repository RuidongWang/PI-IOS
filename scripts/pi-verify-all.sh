#!/usr/bin/env bash
# 全量验证流水线：L2 领域层 + L3 全量 UI。
# 之所以单独成一个脚本：本机的会话管理器会随会话销毁杀掉子进程，
# 用 setsid 把它挂到独立 session，跑完把结果写进 /tmp/pi-verify-report.txt。
set -u -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT=/tmp/pi-verify-report.txt
L2_LOG=/tmp/pi-l2-run.$$.log
FULL_LOG=/tmp/pi-full-uitest.$$.log
: > "$REPORT"
FAILED_STAGES=()

record_failure() {
  FAILED_STAGES+=("$1")
}

say() { echo "$@" | tee -a "$REPORT"; }

say "=== L2: swift test (PIiOSKit) ==="
arch -arm64 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path "$ROOT/apps/ios/PIiOSKit" --disable-sandbox \
  > "$L2_LOG" 2>&1
L2_EXIT=$?
say "L2_EXIT:$L2_EXIT"
grep -E "Test Suite 'PIiOS(Net|Core)Tests.xctest' (passed|failed)" -A1 "$L2_LOG" \
  | grep -E "passed|failed|Executed" | tee -a "$REPORT"
L2_FAILURES=$(grep -cE "^Test Case .* failed" "$L2_LOG" || true)
say "L2_FAILURES:$L2_FAILURES"
if [ "$L2_EXIT" -ne 0 ] || [ "$L2_FAILURES" -ne 0 ]; then record_failure L2; fi

say ""
say "=== L3: 全量 PI-IOSUITests（已含 UIRegressionSuiteTests，不重复跑主套件） ==="
PI_SIM_UDID="${PI_SIM_UDID:-D42DED1E-C917-4CFE-A872-DB228D9F08FF}" \
PI_TEST_LOG="$FULL_LOG" \
  bash "$ROOT/scripts/pi-test.sh" PI-IOSUITests > /dev/null 2>&1
FULL_EXIT=$?
say "FULL_EXIT:$FULL_EXIT"
if [ "$FULL_EXIT" -ne 0 ] || [ ! -s "$FULL_LOG" ]; then record_failure L3; fi

say ""
say "=== 汇总 ==="
for f in "$FULL_LOG"; do
  say "--- $(basename "$f") ---"
  grep -E "^Test Case .* failed" "$f" | sed 's/^.*UIRegressionSuiteTests //;s/^.*\.//' | head -40 | tee -a "$REPORT"
  grep -E "Executed [0-9]+ tests" "$f" | tail -1 | tee -a "$REPORT"
  grep -E "TEST (SUCCEEDED|FAILED)" "$f" | tail -1 | tee -a "$REPORT"
done
if [ "${#FAILED_STAGES[@]}" -gt 0 ]; then
  say "FAILED_STAGES:${FAILED_STAGES[*]}"
  say "DONE"
  exit 1
fi
say "DONE"
