#!/usr/bin/env bash
# 华为智慧屏无线调试的 hdc 封装。
#
# 为什么需要它：这台电视的无线调试会话存活很短，`hdc tconn` 建好后
# 隔一个 shell 调用就失效（报 "Not match target founded, check connect-key"）。
# 所以每次操作都必须在同一条命令里「kill → start → tconn → 执行」。
#
#   ./scripts/hdcx.sh shell "param get const.product.model"
#   ./scripts/hdcx.sh install -r entry/build/.../entry-default-signed.hap
#   ./scripts/hdcx.sh file send local.hap /data/local/tmp/x.hap
#
# 电视地址用环境变量覆盖：TV_IP=192.168.1.207:33609 ./scripts/hdcx.sh ...
set -uo pipefail

TV="${TV_IP:-192.168.1.207:33609}"

HDC="${HDC:-}"
if [ -z "$HDC" ]; then
  for c in /Applications/DevEco-Studio.app/Contents/sdk/*/openharmony/toolchains/hdc \
           /Applications/DevEco-Studio.app/Contents/sdk/*/*/toolchains/hdc \
           "$HOME"/ohsdk/sdk/*/darwin/toolchains/hdc; do
    [ -x "$c" ] && HDC="$c" && break
  done
fi
if [ -z "$HDC" ] && command -v hdc >/dev/null 2>&1; then
  HDC="$(command -v hdc)"
fi
[ -z "$HDC" ] && { echo "✗ 找不到 hdc" >&2; exit 1; }

# 只在会话不存在时重连，避免每次都 kill 掉别人的（比如 DevEco 占着）
CUR="$("$HDC" list targets 2>/dev/null | tr -d '\r' | grep -c "$TV" || true)"
if [ "$CUR" = "0" ]; then
  "$HDC" kill >/dev/null 2>&1
  sleep 0.4
  "$HDC" start >/dev/null 2>&1
  sleep 0.6
  perl -e 'alarm 12; exec @ARGV' "$HDC" tconn "$TV" >/dev/null 2>&1
  sleep 0.4
fi

perl -e 'alarm 300; exec @ARGV' "$HDC" -t "$TV" "$@"
