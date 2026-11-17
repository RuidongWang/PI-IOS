#!/usr/bin/env bash
# 串行化的 UI 测试入口（与 pi-build.sh 共用同一把锁，避免 DerivedData 互相踩坏）。
#
# 用法：
#   bash scripts/pi-test.sh                                  # 全量 PI-IOSUITests
#   bash scripts/pi-test.sh PI-IOSUITests/UIRegressionSuiteTests
#   bash scripts/pi-test.sh PI-IOSUITests/UIRegressionSuiteTests/testG01EmptyState
#   PI_SIM_UDID=<udid> bash scripts/pi-test.sh <only-testing>
#
# 为什么必须串行 + 独占模拟器：测试跑的时候别同时跑 pi-shot.sh 或另一个 xcodebuild，
# 否则 runner 会被 simctl terminate 打断，表现为 "Restarting after unexpected exit"，
# 看起来像崩溃，其实是外部干扰。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UDID="${PI_SIM_UDID:-08BEDA92-4CC5-4423-8D70-17A73BCA19C8}"
TARGET="${1:-PI-IOSUITests}"
LOG="${PI_TEST_LOG:-/tmp/pi-uitest.log}"

exec python3 - "$ROOT" "$UDID" "$TARGET" "$LOG" <<'PY'
import fcntl, subprocess, sys, shutil
root, udid, target, log = sys.argv[1:5]

# 编译与测试共用一把锁：任何时刻只有一个 xcodebuild 在跑。
lock = open("/tmp/pi-ios-build.lock", "w")
fcntl.flock(lock, fcntl.LOCK_EX)

common = [
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
]

build = subprocess.run(common + ["-only-testing:" + target.split("/")[0], "build-for-testing"],
                       capture_output=True, text=True)
if build.returncode != 0:
    out = (build.stdout or "") + (build.stderr or "")
    for line in out.splitlines():
        if ": error:" in line:
            print(line)
    print("TEST BUILD FAILED")
    sys.exit(1)

# xcodebuild 拒绝覆盖已存在的 result bundle，必须先清掉。
shutil.rmtree("/tmp/pi-uitest.xcresult", ignore_errors=True)

run = common + ["-resultBundlePath", "/tmp/pi-uitest.xcresult",
                "-only-testing:" + target, "test-without-building"]
with open(log, "w") as fh:
    proc = subprocess.run(run, stdout=fh, stderr=subprocess.STDOUT)

text = open(log, errors="replace").read()
for line in text.splitlines():
    if ("Test Case '" in line and ("passed" in line or "failed" in line)) \
            or "Executed " in line or line.startswith("TEST ") or "TEST EXECUTE" in line:
        print(line.strip())
print("EXIT:", proc.returncode)
sys.exit(proc.returncode)
PY
