#!/usr/bin/env bash
# 用 UI 夹具在模拟器上渲染一屏，存成 PNG，供视觉自查。
#
# 用法：
#   bash scripts/pi-shot.sh <fixture-scenario> <输出名>
#   bash scripts/pi-shot.sh online-two-hosts projects
#
# 夹具清单见 apps/ios/PI-IOS/App/UITestFixture.swift 的 PI_IOS_UI_FIXTURE_SCENARIO 分支。
#
# 只能截「启动后落在的那一屏」。要截子页（设置 / 服务器表单 / 模型 / 安装 / 会话审批卡…）
# 请跑视觉验收夹具，它能导航到每一屏并附截图：
#   bash scripts/pi-test.sh PI-IOSUITests/VisualReviewUITests
#   xcrun xcresulttool export attachments --path /tmp/pi-uitest.xcresult --output-path .tmp/visual-review
#
# 注意：本脚本和编译、UI 测试共用同一把锁（/tmp/pi-ios-build.lock）。
# 以前不共用，导致别人跑 UI 测试时被这里的 simctl terminate 打断，
# 表现为 "Restarting after unexpected exit"，看起来像崩溃，其实是并发。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UDID="${PI_SIM_UDID:-08BEDA92-4CC5-4423-8D70-17A73BCA19C8}"
SCENARIO="${1:-}"
NAME="${2:-shot}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ -z "$SCENARIO" ]]; then
  echo "用法: bash scripts/pi-shot.sh <fixture-scenario> <输出名>" >&2
  exit 2
fi

exec python3 - "$ROOT" "$UDID" "$SCENARIO" "$NAME" <<'PY'
import fcntl, os, subprocess, sys, time
root, udid, scenario, name = sys.argv[1:5]

lock = open("/tmp/pi-ios-build.lock", "w")
fcntl.flock(lock, fcntl.LOCK_EX)

app = f"{root}/apps/ios/build/DerivedData/Build/Products/Debug-iphonesimulator/PI-IOS.app"
out = f"{root}/.tmp/shots"
os.makedirs(out, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")

def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, env=env, **kw)

run(["xcrun", "simctl", "bootstatus", udid, "-b"])
run(["xcrun", "simctl", "terminate", udid, "dev.piios.PI-IOS"])
r = run(["xcrun", "simctl", "install", udid, app])
if r.returncode != 0:
    print("install failed:", r.stderr[-400:], file=sys.stderr)
    sys.exit(1)

launch_env = dict(env, SIMCTL_CHILD_PI_IOS_UI_FIXTURE_SCENARIO=scenario)
r = subprocess.run(["xcrun", "simctl", "launch", udid, "dev.piios.PI-IOS"],
                   capture_output=True, text=True, env=launch_env)
if r.returncode != 0:
    print("launch failed:", r.stderr[-400:], file=sys.stderr)
    sys.exit(1)

time.sleep(float(os.environ.get("PI_SHOT_DELAY", "4")))
path = f"{out}/{name}.png"
r = run(["xcrun", "simctl", "io", udid, "screenshot", path])
if r.returncode != 0:
    print("screenshot failed:", r.stderr[-400:], file=sys.stderr)
    sys.exit(1)
print(path)
PY
