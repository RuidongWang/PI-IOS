#!/usr/bin/env bash
# 为 DeviceHub 仿真设备准备一份可直接上传的私钥副本。
#
# 做的事：
#   1. 从仓库根 .env 读 PI_IOS_SSH_KEY_PATH；
#   2. 若不是 OpenSSH 格式（云厂商导出的 PEM/.key 常见），复制一份并转成 OpenSSH；
#   3. 统一改名为 pi-test-key，权限 0600，输出到仓库外的临时目录；
#   4. 只打印路径与首行类型，不打印私钥内容。
#
# 产物目录默认 $TMPDIR/piios-device-key（仓库外，不入库）。
# 用法：apps/ios/scripts/prepare-device-key.sh [输出目录]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
OUT_DIR="${1:-${TMPDIR:-/tmp}/piios-device-key}"
SSH_KEYGEN="${SSH_KEYGEN_BIN:-ssh-keygen}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "找不到 $ENV_FILE：先 cp .env.example .env 并填写 PI_IOS_SSH_KEY_PATH" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

KEY_PATH="${PI_IOS_SSH_KEY_PATH:-}"
if [[ -z "$KEY_PATH" || ! -f "$KEY_PATH" ]]; then
  echo "PI_IOS_SSH_KEY_PATH 为空或文件不存在：$KEY_PATH" >&2
  exit 1
fi

if ! command -v "$SSH_KEYGEN" >/dev/null 2>&1; then
  echo "本机没有 $SSH_KEYGEN（需要 OpenSSH 客户端）" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
OUT="$OUT_DIR/pi-test-key"
rm -f "$OUT"
cp "$KEY_PATH" "$OUT"
chmod 600 "$OUT"

first_line() { head -n 1 "$1" 2>/dev/null || true; }

header="$(first_line "$OUT")"
case "$header" in
  *"BEGIN OPENSSH PRIVATE KEY"*)
    ;;
  *"BEGIN RSA PRIVATE KEY"*|*"BEGIN EC PRIVATE KEY"*|*"BEGIN PRIVATE KEY"*)
    # 转换在副本上做，不动原文件。
    # OpenSSH 8.9 起，-p 重写时默认输出 OPENSSH 格式；部分 9.x 才支持显式 -m OPENSSH。
    # 先试不带 -m 的写法，不行再试 -m OPENSSH。
    "$SSH_KEYGEN" -p -f "$OUT" -N '' -P '' >/dev/null 2>&1 </dev/null || true
    header="$(first_line "$OUT")"
    if [[ "$header" != *"BEGIN OPENSSH PRIVATE KEY"* ]]; then
      "$SSH_KEYGEN" -p -m OPENSSH -f "$OUT" -N '' -P '' >/dev/null 2>&1 </dev/null || true
      header="$(first_line "$OUT")"
    fi
    if [[ "$header" != *"BEGIN OPENSSH PRIVATE KEY"* ]]; then
      echo "自动转换失败（私钥可能带口令，或本机 $SSH_KEYGEN 不支持转换）。请手动处理：" >&2
      echo "  1) 若私钥带口令，先解密再重跑：$SSH_KEYGEN -p -f \"$KEY_PATH\"" >&2
      echo "  2) 若仍转不了，用 OpenSSH 9.x 执行：$SSH_KEYGEN -p -f \"$OUT\"" >&2
      exit 2
    fi
    ;;
  *)
    echo "无法识别的私钥格式，首行：$header" >&2
    exit 3
    ;;
esac

# 用公钥派生做一次可用性校验：不打印私钥内容，只验证能解析。
if ! "$SSH_KEYGEN" -y -f "$OUT" >/dev/null 2>&1 </dev/null; then
  echo "私钥无法解析（可能带口令）。请先解密后再准备：$SSH_KEYGEN -p -f \"$KEY_PATH\"" >&2
  exit 4
fi

echo "已准备：$OUT"
echo "格式：$header"
echo "下一步：在 DeviceHub 把该文件上传到仿真设备的「文件」App →「我的 iPhone」，文件名保持 pi-test-key。"
echo "上传完成后删除本地副本：rm -f \"$OUT\""
