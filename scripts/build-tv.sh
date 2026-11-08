#!/usr/bin/env bash
# 一条命令出「可直接装到真机/电视」的调试包，并可选安装。
#
#   ./scripts/build-tv.sh                              # 只构建，产出 build/debug/*-debug-signed.hap
#   ./scripts/build-tv.sh --install 192.168.100.176:5555   # 构建 + 装到电视
#   ./scripts/build-tv.sh --install 192.168.10.168:37713   # 构建 + 装到手机
#
# 为什么不用 hvigor 的 signingConfigs：
#   hvigor 要求 storePassword / keyPassword 是 DevEco 加密后的密文（长度 ≥ 32），
#   写明文直接被拒：「The length of the storePassword or keyPassword field is
#   less than 32」，而密文只能由 DevEco 图形界面生成。为了不依赖 IDE，这里：
#     1) hvigor 出**未签名** hap（build-profile 里 signingConfigs 保持为空）
#     2) 用 SDK 自带的 hap-sign-tool.jar 补签（它接受明文口令）
#     3) 需要时 hdc install -r 装到设备
#
# 签名材料（AGC 下发的调试描述文件 + 自签密钥库）：
#   $SIGN_DIR/hongmengyingshi-debug.p12   私钥库，别名 debugkey，口令见 HMY_STOREPASS
#   $SIGN_DIR/hongmengyingshi-debug.cer   叶子证书
#   $SIGN_DIR/hongmengyingshi-debug.p7b   debug Profile：bundle-name=com.hong.tv
#                                         设备白名单含手机 + 电视 EDIS-760E，有效期至 2027-11-03
# 与 scripts/sign-release.sh 的区别：那个出上架用 .app（release，装了会报
# 9568322 not trusted app source）；这个出真机自测用 .hap（debug）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

DEVECO="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
JAR="$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
JAVA="$DEVECO/jbr/Contents/Home/bin/java"
[ -x "$JAVA" ] || JAVA="$(command -v java)"
HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw"
[ -x "$ROOT/hvigorw" ] && HVIGOR="$ROOT/hvigorw"

SIGN_DIR="${SIGN_DIR:-$HOME/.ohos/debug-key}"
P12="$SIGN_DIR/hongmengyingshi-debug.p12"
CER="$SIGN_DIR/hongmengyingshi-debug.cer"
P7B="$SIGN_DIR/hongmengyingshi-debug.p7b"
ALIAS="${HMY_ALIAS:-debugkey}"
PASS="${HMY_STOREPASS:-het002402}"

BUNDLE="com.hong.tv"
UNSIGNED="$ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"
OUT_DIR="$ROOT/build/debug"

TARGET_DEV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) TARGET_DEV="${2:-}"; shift 2 || shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

for f in "$P12" "$CER" "$P7B" "$JAR"; do
  [ -f "$f" ] || { echo "✗ 找不到：$f"; exit 3; }
done

# ---------- 0. Profile 自检：包名、类型、有效期、设备白名单 ----------
read -r KIND PBUNDLE NOTAFTER DEVIDS <<<"$(python3 - "$P7B" <<'PYEOF'
import re, sys
d = open(sys.argv[1], 'rb').read().decode('utf-8', 'ignore')
def one(pat):
    m = re.search(pat, d)
    return m.group(1) if m else ''
ids = re.search(r'"device-ids"\s*:\s*\[(.*?)\]', d)
ids = ' '.join(re.findall(r'"([^"]+)"', ids.group(1))) if ids else ''
print(one(r'"type"\s*:\s*"([^"]+)"'), one(r'"bundle-name"\s*:\s*"([^"]+)"'),
      one(r'"not-after"\s*:\s*(\d+)'), ids or '-')
PYEOF
)"
echo "→ Profile：type=$KIND  bundle=$PBUNDLE  设备数=$(echo "$DEVIDS" | wc -w | tr -d ' ')"
if [ "$KIND" != "debug" ]; then
  echo "✗ 这不是调试 Profile（type=$KIND），装真机会报 9568322"; exit 4
fi
if [ "$PBUNDLE" != "$BUNDLE" ]; then
  echo "✗ Profile 包名 $PBUNDLE ≠ 工程 $BUNDLE"; exit 5
fi
NOW=$(date +%s)
if [ -n "$NOTAFTER" ] && [ "$NOW" -gt "$NOTAFTER" ]; then
  echo "✗ Profile 已过期（$(date -r "$NOTAFTER" '+%Y-%m-%d')），回 AGC 重新签发"; exit 6
fi

# ---------- 1. 编译未签名 hap ----------
# DEVECO_SDK_HOME 必须指到 Contents/sdk（含 default 子目录的那一层）。
# 指到 .../sdk/default 会报 00303312「Cannot find the corresponding SDK version」。
export DEVECO_SDK_HOME="$DEVECO/sdk"
[ -d "$DEVECO/tools/node" ] && export NODE_HOME="$DEVECO/tools/node"
export PATH="$DEVECO/tools/node/bin:$PATH"

echo "→ 编译（debug）…"
LOG="${TMPDIR:-/tmp}/hmy-tv-build.log"
"$HVIGOR" --mode module -p product=default -p buildMode=debug assembleHap --no-daemon > "$LOG" 2>&1
if ! grep -q "BUILD SUCCESSFUL" "$LOG"; then
  echo "✗ 编译失败，日志：$LOG"
  grep -n "Error Message" "$LOG" | head -6
  exit 7
fi
[ -f "$UNSIGNED" ] || { echo "✗ 没有未签名包：$UNSIGNED"; exit 7; }

# ---------- 2. 用调试证书补签 ----------
VER=$(python3 -c "
import re,io
s=io.open('$ROOT/AppScope/app.json5',encoding='utf-8').read()
m=re.search(r'\"versionName\"\s*:\s*\"([^\"]+)\"',s)
print(m.group(1) if m else '0.0.0')")
mkdir -p "$OUT_DIR"
TARGET="$OUT_DIR/夜帧影视-$VER-debug-signed.hap"

echo "→ 签名…"
"$JAVA" -jar "$JAR" sign-app \
  -mode localSign \
  -keyAlias "$ALIAS" \
  -keyPwd "$PASS" \
  -keystoreFile "$P12" \
  -keystorePwd "$PASS" \
  -appCertFile "$CER" \
  -profileFile "$P7B" \
  -inFile "$UNSIGNED" \
  -outFile "$TARGET" \
  -signAlg SHA256withECDSA \
  -compatibleVersion 12 > "${TMPDIR:-/tmp}/hmy-tv-sign.log" 2>&1
if ! grep -q "sign-app success" "${TMPDIR:-/tmp}/hmy-tv-sign.log"; then
  echo "✗ 签名失败："
  tail -6 "${TMPDIR:-/tmp}/hmy-tv-sign.log"
  exit 8
fi
echo "  ✓ $TARGET  ($(du -h "$TARGET" | cut -f1))"

# ---------- 3. 可选安装 ----------
if [ -z "$TARGET_DEV" ]; then
  echo
  echo "装到设备："
  echo "  hdc tconn <ip:port> && hdc install -r \"$TARGET\""
  exit 0
fi

# hdc 的 tconn 端口对同一台机器是复用的，重复连也安全
if ! hdc list targets 2>/dev/null | grep -q "$TARGET_DEV"; then
  echo "→ 连接 $TARGET_DEV…"
  hdc tconn "$TARGET_DEV" >/dev/null 2>&1
fi
if ! hdc list targets 2>/dev/null | grep -q "$TARGET_DEV"; then
  echo "✗ 连不上 $TARGET_DEV（设备需开启开发者模式 + USB/无线调试，端口见 hdc 页面）"; exit 9
fi

# 装之前对一下设备 UDID 是否在描述文件白名单里，不然 hdc 只会给个含糊的 9568425
UDID=$(hdc -t "$TARGET_DEV" shell bm get --udid 2>/dev/null | tr -d '\r' | grep -oE '[0-9A-F]{64}')
if [ -n "$UDID" ] && ! echo "$DEVIDS" | grep -q "$UDID"; then
  echo "✗ 设备 UDID $UDID 不在 Profile 白名单里，装上去会报 device is unauthorized"
  echo "  白名单：$DEVIDS"
  echo "  处理：AGC → 我的项目 → 设备管理 添加该设备 → 重新下载调试 Profile 放到 $SIGN_DIR"
  exit 10
fi

echo "→ 安装到 ${TARGET_DEV}…"
if hdc -t "$TARGET_DEV" install -r "$TARGET" 2>&1 | tee "${TMPDIR:-/tmp}/hmy-tv-install.log" | grep -q "install bundle successfully"; then
  echo "✓ 已安装。启动：hdc -t $TARGET_DEV shell aa start -a EntryAbility -b $BUNDLE"
else
  echo "✗ 安装失败："; tail -5 "${TMPDIR:-/tmp}/hmy-tv-install.log"; exit 11
fi
