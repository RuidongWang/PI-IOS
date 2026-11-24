#!/usr/bin/env bash
# 串行化的 App 单测与 UI 测试入口（与 pi-build.sh 共用 DerivedData 锁）。
#
# 用法：
#   bash scripts/pi-test.sh                                  # 默认功能 UI
#   bash scripts/pi-test.sh PI-IOSTests                       # App 单测
#   bash scripts/pi-test.sh PI-IOSUITests/UIRegressionSuiteTests
#   bash scripts/pi-test.sh PI-IOSUITests/UIRegressionSuiteTests/testG01EmptyState
#   bash scripts/pi-test.sh PI-IOSUITests/VisualReviewUITests   # 按需截图
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
RESULT="${PI_TEST_RESULT:-/tmp/pi-uitest.xcresult}"

exec python3 - "$ROOT" "$UDID" "$TARGET" "$LOG" "$RESULT" <<'PY'
import fcntl, os, subprocess, sys, shutil
root, udid, target, log, result = sys.argv[1:6]

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

with open(log, "w") as fh:
    build = subprocess.run(common + ["-only-testing:" + target.split("/")[0], "build-for-testing"],
                           stdout=fh, stderr=subprocess.STDOUT)
if build.returncode != 0:
    with open(log, errors="replace") as fh:
        for line in fh:
            if "error:" in line:
                print(line.strip())
    print("TEST BUILD FAILED")
    sys.exit(build.returncode)

# 只替换本脚本的固定结果路径。调用方提供的归档路径须为新路径。
if result == "/tmp/pi-uitest.xcresult":
    shutil.rmtree(result, ignore_errors=True)

run = common + ["-resultBundlePath", result, "-only-testing:" + target]
if target == "PI-IOSUITests":
    run += ["-skip-testing:PI-IOSUITests/VisualReviewUITests"]
run += ["test-without-building"]
environment = os.environ.copy()
if target.split("/")[:2] == ["PI-IOSUITests", "VisualReviewUITests"]:
    environment["TEST_RUNNER_PI_IOS_VISUAL_REVIEW"] = "1"
with open(log, "a") as fh:
    proc = subprocess.run(run, stdout=fh, stderr=subprocess.STDOUT, env=environment)

with open(log, errors="replace") as fh:
    for line in fh:
        if ("Test Case '" in line and any(status in line for status in (" passed ", " failed ", " skipped "))) \
                or "Executed " in line or "TEST EXECUTE" in line:
            print(line.strip())
print("EXIT:", proc.returncode)
sys.exit(proc.returncode)
PY
