#!/usr/bin/env bash
# 模拟器操作封装。真机不在线时用它跑验证。
#
#   ./scripts/emuctl.sh shot             截图到 /tmp/emu-shot.png
#   ./scripts/emuctl.sh dump             打印当前界面的文字与坐标
#   ./scripts/emuctl.sh tap X Y          点一下（像素坐标）
#   ./scripts/emuctl.sh swipe X1 Y1 X2 Y2 [ms]
#   ./scripts/emuctl.sh key back|home
#   ./scripts/emuctl.sh install          重新安装已编译的 HAP
#   ./scripts/emuctl.sh start|stop|restart
#   ./scripts/emuctl.sh log [行数]       看应用日志（BOXN 标签）
#   ./scripts/emuctl.sh clear            清应用数据（验证首启流程用）
#   ./scripts/emuctl.sh devinfo          设备分辨率与密度
#
# 为什么单独封装：hdc 对模拟器必须带 -t 127.0.0.1:5555，而真机是 IP:PORT，
# 每次手写容易漏；另外 dumpLayout 的输出要先落盘再拉回来才能解析。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
TGT="${EMU_TARGET:-127.0.0.1:5555}"
PKG=com.hong.tv
# 自测装模拟器用 debug 包；release 目录现在是 .app（App Pack），不能 hdc install
HAP="$(ls -t "$ROOT"/build/debug/*.hap 2>/dev/null | head -1)"
[ -n "$HAP" ] || HAP="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"

[ -x "$HDC" ] || { echo "✗ 找不到 hdc：$HDC"; exit 1; }

# 会话不在就重连；模拟器的 tconn 是幂等的
connect() {
  local cur
  cur="$("$HDC" list targets 2>/dev/null | tr -d '\r' | grep -c "$TGT" || true)"
  if [ "$cur" = "0" ]; then
    "$HDC" tconn "$TGT" >/dev/null 2>&1
    sleep 1
  fi
}

sh_() { "$HDC" -t "$TGT" shell "$1" 2>&1 | tr -d '\r'; }

cmd="${1:-}"
case "$cmd" in
  devinfo)
    connect
    sh_ "wm size; wm density"
    ;;
  shot)
    connect
    out="${2:-/tmp/emu-shot.png}"
    sh_ "snapshot_display -f /data/local/tmp/_s.jpeg" >/dev/null
    "$HDC" -t "$TGT" file recv /data/local/tmp/_s.jpeg "$out" >/dev/null 2>&1
    echo "✓ $out"
    ;;
  dump)
    connect
    sh_ "uitest dumpLayout -p /data/local/tmp/_l.json" >/dev/null
    "$HDC" -t "$TGT" file recv /data/local/tmp/_l.json /tmp/_l.json >/dev/null 2>&1
    python3 - <<'PYEOF'
import json
d = json.load(open('/tmp/_l.json', encoding='utf-8'))
rows = []
def walk(n):
    a = n.get('attributes', {})
    t = (a.get('text', '') or '').strip()
    b = a.get('bounds', '')
    if t:
        rows.append((t, b))
    for c in n.get('children', []):
        walk(c)
walk(d)
for t, b in rows:
    print('%-52s %s' % (t[:50].replace('\n', ' '), b))
PYEOF
    ;;
  tap)
    connect
    sh_ "uitest uiInput click $2 $3" >/dev/null
    echo "✓ tap $2 $3"
    ;;
  swipe)
    connect
    sh_ "uitest uiInput swipe $2 $3 $4 $5 ${6:-350}" >/dev/null
    echo "✓ swipe $2 $3 → $4 $5"
    ;;
  key)
    connect
    case "${2:-back}" in
      back) sh_ "uitest uiInput keyEvent Back" >/dev/null ;;
      home) sh_ "uitest uiInput keyEvent Home" >/dev/null ;;
      *) sh_ "uitest uiInput keyEvent $2" >/dev/null ;;
    esac
    echo "✓ key ${2:-back}"
    ;;
  install)
    connect
    [ -f "$HAP" ] || { echo "✗ 没有产物，先 ./scripts/build.sh"; exit 2; }
    "$HDC" -t "$TGT" install -r "$HAP" 2>&1 | tail -3
    ;;
  start)
    connect
    sh_ "aa start -a EntryAbility -b $PKG" | tail -2
    ;;
  stop)
    connect
    sh_ "aa force-stop $PKG" >/dev/null
    echo "✓ stopped"
    ;;
  restart)
    connect
    sh_ "aa force-stop $PKG" >/dev/null
    sleep 1
    sh_ "aa start -a EntryAbility -b $PKG" | tail -2
    ;;
  clear)
    connect
    sh_ "bm clean -n $PKG -d" | tail -1
    ;;
  log)
    connect
    sh_ "hilog -x -T BOXN 2>/dev/null | tail -${2:-30}"
    ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
