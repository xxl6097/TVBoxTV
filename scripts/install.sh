#!/usr/bin/env bash
# 把编译好的 HAP 装到智慧屏并启动。
#   ./scripts/install.sh                  # 默认用 TV_IP（或 192.168.1.207:33609）
#   ./scripts/install.sh 192.168.1.50     # 指定电视 IP（无线调试）
#   ./scripts/install.sh 192.168.1.50 x.hap
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVECO="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
# 自测装设备用 debug 包（build/debug/ 下的 -debug-signed.hap）。
# release 目录现在是 .app（App Pack），不能 hdc install，别用它装机。
if [ -n "${2:-}" ]; then
  HAP="$2"
else
  HAP="$(ls -t "$ROOT"/build/debug/*.hap 2>/dev/null | head -1)"
  [ -n "$HAP" ] || HAP="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
fi
# 第一个参数既可以是纯 IP（默认拼 5555），也可以是「IP:端口」（无线调试随机端口时用这种）
TV_ADDR="${1:-${TV_IP:-192.168.1.207:33609}}"

# --- 找 hdc ---
HDC="${HDC:-}"
if [ -z "$HDC" ]; then
  for c in "$DEVECO"/sdk/*/openharmony/toolchains/hdc "$DEVECO"/sdk/*/*/toolchains/hdc \
           "$DEVECO"/tools/hdc "$HOME"/ohsdk/sdk/*/darwin/toolchains/hdc; do
    [ -x "$c" ] && HDC="$c" && break
  done
fi
if [ -z "$HDC" ] && command -v hdc >/dev/null 2>&1; then
  HDC="$(command -v hdc)"
fi
if [ -z "$HDC" ]; then
  echo "✗ 找不到 hdc（它在 DevEco Studio 的 SDK toolchains 里）"
  echo "  装好 DevEco 后重试，或指定：DEVECO_HOME=... ./scripts/install.sh"
  exit 1
fi
echo "→ hdc : $HDC"

if [ ! -f "$HAP" ]; then
  echo "✗ 找不到 HAP：$HAP"
  echo "  先跑 ./scripts/build.sh"
  exit 2
fi
echo "→ HAP : $HAP ($(du -h "$HAP" | cut -f1))"

# --- 连设备 ---
# 坑一：DevEco Studio 常驻时会用自己的 hdc server 占住默认端口，
#       两边版本不同就报 `need connect-key? please confirm a device`。
#       这里统一先 kill 再 start，保证只有一个干净的 server。
# 坑二：install 必须带 -t <ConnectKey>，否则多目标/会话重建时同样报 need connect-key。
"$HDC" kill >/dev/null 2>&1
sleep 1
"$HDC" start >/dev/null 2>&1
sleep 2

if [ -n "$TV_ADDR" ]; then
  case "$TV_ADDR" in
    *:*) KEY="$TV_ADDR" ;;
    *)   KEY="$TV_ADDR:5555" ;;
  esac
  echo "→ 连接设备 $KEY …"
  # tconn 在重复连接时会挂住，用 perl alarm 兜一层超时（macOS 没有 timeout）
  perl -e 'alarm 12; exec @ARGV' "$HDC" tconn "$KEY" 2>&1 || true
  sleep 1
else
  KEY=""
fi

TARGETS="$("$HDC" list targets 2>/dev/null | grep -v '^\s*$' | grep -v 'Empty')"
if [ -z "$TARGETS" ]; then
  cat <<'EOF'
✗ 没有可用设备。按顺序检查：

  1) 智慧屏：设置 → 关于本机 → 连点「软件版本号」5 次 → 开发者选项
     → 打开「USB 调试」和「无线调试」
  2) 电视和这台 Mac 必须在同一个局域网（现在这台 Mac 在别的网段就不行）
  3) 电视 IP 在：设置 → 网络 → 当前网络；然后重跑：
       ./scripts/install.sh <电视IP>
  4) hdc 版本太旧也会认不到设备，用 DevEco 自带的那份（脚本已自动优先用）
EOF
  exit 3
fi
echo "→ 设备 : $TARGETS"

# --- 打印 UDID（签名要把这串加进调试证书）---
UDID="$("$HDC" shell bm get -u 2>/dev/null | tr -d '\r' | tail -1)"
[ -n "$UDID" ] && echo "→ UDID : $UDID"

# --- 装 ---
echo "→ 安装中…"
OUT="$(perl -e 'alarm 180; exec @ARGV' "$HDC" ${KEY:+-t "$KEY"} install -r "$HAP" 2>&1)"
echo "$OUT"
case "$OUT" in
  *"success"*|*"Success"*)
    echo "→ 启动…"
    "$HDC" ${KEY:+-t "$KEY"} shell aa start -a EntryAbility -b com.hong.tv || true
    echo "✓ 完事，去电视上找「夜帧影视」"
    ;;
  *"9568289"*|*"signature"*|*"verify"*)
    cat <<'EOF'
✗ 签名校验失败。常见原因：签名证书里没有这台电视的 UDID。

  打开 DevEco → 连上电视 → Project Structure → Signing Configs
  → 重新勾一次自动签名（会重新拉设备列表），再 build 一次。
EOF
    exit 4
    ;;
  *)
    echo "✗ 安装失败，看上面的原始输出"
    exit 5
    ;;
esac
