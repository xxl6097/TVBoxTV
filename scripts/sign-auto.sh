#!/usr/bin/env bash
# 换设备后的一键签名 + 装机。
#
# 调试描述文件（.p7b）里白名单了具体设备的 UDID，换机器必然报
#   9568423 the device is unauthorized
# 而重新签发必须由 DevEco 带着华为账号登录态向 AGC 申请（OAuth 需要服务端下发的
# client_secret，命令行无法复现）。所以本脚本做的是：
#
#   1. 读当前设备 UDID，检查签名凭证里有没有它
#   2. 没有 → 打开 DevEco 工程，等你在里面点一次自动签名
#   3. 一旦凭证更新并包含该 UDID → 自动编译 + 安装 + 启动
#
# 用法：
#   ./scripts/sign-auto.sh              # 默认等 15 分钟
#   ./scripts/sign-auto.sh --wait 1800  # 自定义等待秒数
#   TV_IP=192.168.1.50:5555 ./scripts/sign-auto.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CDIR="$HOME/.ohos/config"
WAIT=900
[ "${1:-}" = "--wait" ] && WAIT="${2:-900}"

# ---------- 读设备 UDID ----------
echo "→ 连接设备…"
UDID="$("$ROOT/scripts/hdcx.sh" shell "bm get -u" 2>/dev/null | tr -d '\r' | grep -E '^[0-9A-F]{32,}' | tail -1)"
if [ -z "$UDID" ]; then
  echo "✗ 读不到设备 UDID。先确认电视/设备在线："
  echo "    ./scripts/hdcx.sh shell \"echo ok\""
  exit 2
fi
echo "→ 设备 UDID : $UDID"

# ---------- 检查凭证是否覆盖该 UDID ----------
# 返回 0 = 已覆盖
p7b_covers() {
  local f="$1"
  [ -f "$f" ] || return 1
  python3 - "$f" "$UDID" <<'PY'
import sys, re
p, udid = sys.argv[1], sys.argv[2]
try:
    d = open(p, 'rb').read()
except OSError:
    sys.exit(1)
m = re.search(rb'\{[\s\S]{200,}\}', d)
if not m:
    sys.exit(1)
s = m.group(0).decode('utf-8', 'ignore')
ids = re.search(r'"device-ids"\s*:\s*\[([^\]]*)\]', s)
if not ids:
    sys.exit(1)
sys.exit(0 if udid in ids.group(1) else 1)
PY
}

# 找 build-profile 里指定的那个 profile
PROFILE="$(perl -ne 'print "$1\n" if /"profile"\s*:\s*"([^"]+)"/' "$ROOT/build-profile.json5" 2>/dev/null | head -1)"
[ -n "$PROFILE" ] && echo "→ 当前凭证 : $(basename "$PROFILE")"

if [ -n "$PROFILE" ] && p7b_covers "$PROFILE"; then
  echo "✓ 凭证已包含本机 UDID，直接装机"
else
  echo
  echo "───────────────────────────────────────────────"
  echo "凭证里没有这台设备，需要在 DevEco 里签一次："
  echo
  echo "  1) 工程马上会自动打开"
  echo "  2) 右上角确认已登录华为账号"
  echo "  3) 按 ⇧F10（或点 ▶ Run）"
  echo "  4) 弹「Automatically generate signature」→ OK"
  echo
  echo "签完不用管，本脚本会自动编译并装到设备上（最多等 $((WAIT/60)) 分钟）"
  echo "───────────────────────────────────────────────"
  echo
  open -a "/Applications/DevEco-Studio.app" "$ROOT" 2>/dev/null || \
    open -a "DevEco-Studio" "$ROOT" 2>/dev/null || \
    echo "（没能自动打开 IDE，请手动打开 $ROOT）"

  echo "→ 等待签名凭证更新…"
  ok=0
  for _ in $(seq 1 $((WAIT / 5))); do
    sleep 5
    # DevEco 可能覆盖原文件，也可能新建一个，两种都认
    if [ -n "$PROFILE" ] && p7b_covers "$PROFILE"; then
      ok=1; break
    fi
    for f in "$CDIR"/*.p7b; do
      case "$f" in *backup*) continue ;; esac
      if p7b_covers "$f"; then
        PROFILE="$f"; ok=1; break
      fi
    done
    [ "$ok" = "1" ] && break
    printf '.'
  done
  echo
  if [ "$ok" != "1" ]; then
    echo "✗ 等待超时，凭证仍未包含本机 UDID"
    echo "  确认 IDE 里该工程已连上本设备（Device Manager 能看到），再重跑本脚本"
    exit 3
  fi
  echo "✓ 凭证已更新：$(basename "$PROFILE")"

  # DevEco 可能把 material 指向新文件，同步回 build-profile，保证 hvigor 用的是新凭证
  if [ -n "$PROFILE" ] && ! perl -ne 'exit 0 if /"profile"\s*:\s*"\Q'"$PROFILE"'\E"/' "$ROOT/build-profile.json5"; then
    echo "→ 同步 build-profile 的 profile 路径"
    cp "$ROOT/build-profile.json5" "$ROOT/build-profile.json5.bak-$(date +%H%M%S)"
    perl -i -pe 's{"profile"\s*:\s*"[^"]+"}{"profile": "'"$PROFILE"'"}' "$ROOT/build-profile.json5"
  fi
fi

# ---------- 编译并装机 ----------
echo
echo "→ 编译…"
"$ROOT/scripts/build.sh" 2>&1 | tail -6
HAP="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
[ -f "$HAP" ] || { echo "✗ 没产出 HAP"; exit 4; }

echo "→ 安装…"
OUT="$("$ROOT/scripts/hdcx.sh" install -r "$HAP" 2>&1 | tr -d '\r')"
echo "$OUT" | tail -2
case "$OUT" in
  *success*|*Success*)
    echo "→ 启动…"
    "$ROOT/scripts/hdcx.sh" shell "aa start -a EntryAbility -b com.hong.tv" 2>&1 | tr -d '\r' | tail -1
    echo "✓ 已装到设备"
    ;;
  *)
    echo "✗ 安装失败，看上面输出"
    exit 5
    ;;
esac
