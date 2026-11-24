#!/usr/bin/env bash
# 全量功能回归。详细日志和 Xcode 结果各自保留在本次运行目录。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="${PI_VERIFY_REPORT:-/tmp/pi-verify-report.txt}"
LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pi-verify.XXXXXX") || exit 1
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PI_SIM_UDID="${PI_SIM_UDID:-D42DED1E-C917-4CFE-A872-DB228D9F08FF}"
# Clear the opt-in values that can activate external tests in this aggregate run.
for live_gate in PI_SSH_HOST PI_BOOTSTRAP_SSH_HOST PI_DIRECT_ENDPOINT PI_REAL_DIRECT_URL \
  PI_IOS_EXPECTED_HOST PI_IOS_LIVE_RELEASE_INSTALL PI_IOS_CODE_FIX_E2E PI_IOS_RUN_LIVE \
  PI_IOS_LIVE_CHAT PI_IOS_TWO_HOST_KEYCHAIN PI_IOS_DELETE_HOST_B; do
  unset "$live_gate" "TEST_RUNNER_$live_gate"
done
: > "$REPORT" || exit 1
FAILED_STAGES=()

say() { printf '%s\n' "$@" | tee -a "$REPORT"; }

record_failure() {
  local stage
  for stage in "${FAILED_STAGES[@]:-}"; do
    if [ "$stage" = "$1" ]; then return; fi
  done
  FAILED_STAGES+=("$1")
}

run_stage() {
  local stage=$1
  shift
  say "=== $stage ==="
  "$@" > "$LOG_DIR/$stage.log" 2>&1
  local status=$?
  say "$stage EXIT=$status log=$LOG_DIR/$stage.log"
  if [ "$status" -ne 0 ]; then record_failure "$stage"; fi
}

report_xctest() {
  local stage=$1 bundle=$2 log=$3 summary total skipped failures
  summary=$(awk -v suite="Test Suite '$bundle.xctest'" '
    index($0, suite " passed") == 1 || index($0, suite " failed") == 1 {
      if (getline && $0 ~ /Executed [0-9]+ tests?/) result = $0
    }
    END { if (result != "") { sub(/^[[:space:]]+/, "", result); print result } }
  ' "$log" 2>/dev/null)
  if [[ "$summary" =~ ^Executed\ ([0-9]+)\ tests?,\ with\ (([0-9]+)\ tests?\ skipped\ and\ )?([0-9]+)\ failures? ]]; then
    total=${BASH_REMATCH[1]}
    skipped=${BASH_REMATCH[3]:-0}
    failures=${BASH_REMATCH[4]}
    say "$stage $summary"
    if [ "$total" -le "$skipped" ] || [ "$failures" -ne 0 ]; then record_failure "$stage"; fi
  else
    say "$stage 缺少 $bundle 的测试结果"
    record_failure "$stage"
  fi
}

state_file_regression() {
  arch -arm64 swiftc "$ROOT/apps/ios/PI-IOS/Model/StateFile.swift" \
    "$ROOT/apps/ios/tests/StateFileRegression.swift" -o "$LOG_DIR/state-file-regression" &&
    "$LOG_DIR/state-file-regression"
}

say "详细日志与 Xcode 结果目录 $LOG_DIR"
run_stage L1-typecheck pnpm --dir "$ROOT/apps/pi-adaptor" typecheck
run_stage L1-host env NO_COLOR=1 pnpm --dir "$ROOT/apps/pi-adaptor" test
if ! grep -E '^[[:space:]]*(Test Files|Tests)[[:space:]]' "$LOG_DIR/L1-host.log" | tee -a "$REPORT"; then
  say "L1-host 缺少 Vitest 测试结果"
  record_failure L1-host
fi

run_stage L2-swift arch -arm64 swift test --package-path "$ROOT/apps/ios/PIiOSKit" --disable-sandbox \
  --skip 'RealLongHistoryConnectionTests/testRealLongHistoryBeforeFixClosesWith1009'
report_xctest L2-core PIiOSCoreTests "$LOG_DIR/L2-swift.log"
report_xctest L2-net PIiOSNetTests "$LOG_DIR/L2-swift.log"

run_stage L2b-state state_file_regression
grep -F 'StateFile regression checks passed' "$LOG_DIR/L2b-state.log" | tee -a "$REPORT"

run_stage L2b-app env PI_TEST_LOG="$LOG_DIR/app-xcode.log" PI_TEST_RESULT="$LOG_DIR/app.xcresult" \
  bash "$ROOT/scripts/pi-test.sh" PI-IOSTests
report_xctest L2b-app PI-IOSTests "$LOG_DIR/app-xcode.log"

run_stage L3-ui env PI_TEST_LOG="$LOG_DIR/ui-xcode.log" PI_TEST_RESULT="$LOG_DIR/ui.xcresult" \
  bash "$ROOT/scripts/pi-test.sh" PI-IOSUITests
report_xctest L3-ui PI-IOSUITests "$LOG_DIR/ui-xcode.log"

if [ "${#FAILED_STAGES[@]}" -gt 0 ]; then
  say "FAILED_STAGES:${FAILED_STAGES[*]}" "DONE"
  exit 1
fi
say "DONE"
