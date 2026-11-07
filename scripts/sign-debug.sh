#!/usr/bin/env bash
# 用 AGC 调试证书给 Debug 包签名，产出可直接 hdc install 到真机/模拟器的包。
#
#   为什么需要它：真机直装必须用「调试」Profile（type=debug，device-ids 里
#   白名单了这台设备的 UDID）。发布 Profile 是 app_gallery 分发，本地装会报
#   9568322 not trusted app source。
#
#   用法：
#     ./scripts/sign-debug.sh [调试证书.cer] [调试Profile.p7b]
#
#   前置（AGC 已申请好调试证书 + 调试 Profile）：
#     $DBG_DIR/hongmengyingshi-debug.p12   私钥库，别名 debugKey，口令 het002402
#     $DBG_DIR/hongmengyingshi-debug.cer   调试证书链（AGC 下发）
#     $DBG_DIR/hongmengyingshi-debug.p7b   调试 Profile：bundle=com.hong.tv, type=debug
#
#   证书申请流程见 docs/上架指南.md 或本脚本不带参数时的提示。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

DBG_DIR="${DBG_DIR:-$HOME/.ohos/debug-key}"
P12="$DBG_DIR/hongmengyingshi-debug.p12"
CER="${1:-$DBG_DIR/hongmengyingshi-debug.cer}"
P7B="${2:-$DBG_DIR/hongmengyingshi-debug.p7b}"
ALIAS="${HMY_ALIAS:-debugKey}"
PASS="${HMY_STOREPASS:-het002402}"

DEVECO="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
JAR="$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
JAVA="$DEVECO/jbr/Contents/Home/bin/java"
[ -x "$JAVA" ] || JAVA="$(command -v java)"

OUT="build/debug"
UNSIGNED="$ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"
TARGET="$OUT/夜帧影视-1.0.4-debug-signed.hap"

if [ -z "$CER" ] || [ -z "$P7B" ] || [ ! -f "$CER" ] || [ ! -f "$P7B" ]; then
  cat <<EOF
用法：./scripts/sign-debug.sh [调试证书.cer] [调试Profile.p7b]

缺调试证书 / 调试 Profile。到 AGC 走一遍（约 3 分钟）：

  1. https://developer.huawei.com/consumer/cn/service/josp/agc/index.html
  2. 「证书、APP ID 和 Profile」→ 证书 → 新建证书
       - 类型：调试证书（HarmonyOS 应用调试）
       - 上传 CSR：$DBG_DIR/hongmengyingshi-debug.csr
     下载得到 .cer（保存为 $DBG_DIR/hongmengyingshi-debug.cer）
  3. Profile → 新建 → 类型选「调试」
       - 应用：com.hong.tv
       - 证书：上一步的调试证书
       - 设备：勾选这台电视的 UDID
           BE38CEEEE9631D074204DBCF40DADC68146195564CDE799E1B1259617D29A893
     下载得到 .p7b（保存为 $DBG_DIR/hongmengyingshi-debug.p7b）
  4. 回来重跑本脚本，然后：
       ./scripts/install.sh 192.168.1.207:33609 build/debug/夜帧影视-1.0.4-debug-signed.hap

可用环境变量覆盖：DBG_DIR、HMY_STOREPASS、HMY_ALIAS
EOF
  exit 2
fi
[ -f "$P12" ] || { echo "✗ 找不到密钥库：$P12"; exit 3; }
[ -x "$JAVA" ] || { echo "✗ 找不到 java"; exit 3; }
[ -f "$JAR" ] || { echo "✗ 找不到 hap-sign-tool.jar：$JAR"; exit 3; }

# ---------- 0. Profile 必须是调试类型 + 包名匹配 + 含本机 UDID ----------
KIND=$(python3 - "$P7B" <<'PYEOF'
import re, sys
d = open(sys.argv[1], 'rb').read()
m = re.search(rb'"type"\s*:\s*"(debug|release)"', d)
print(m.group(1).decode() if m else 'unknown')
PYEOF
)
BUNDLE=$(python3 - "$P7B" <<'PYEOF'
import re, sys
d = open(sys.argv[1], 'rb').read().decode('utf-8', 'ignore')
m = re.search(r'"bundle-name"\s*:\s*"([^"]+)"', d)
print(m.group(1) if m else '')
PYEOF
)
HASUDID=$(python3 - "$P7B" <<'PYEOF'
import sys
d = open(sys.argv[1], 'rb').read().decode('utf-8', 'ignore')
print('yes' if 'BE38CEEEE9631D074204DBCF40DADC68146195564CDE799E1B1259617D29A893' in d else 'no')
PYEOF
)
echo "→ Profile：type=$KIND  bundle=$BUNDLE  真机UDID白名单=$HASUDID"
if [ "$KIND" != "debug" ]; then
  echo "✗ 这不是调试 Profile（type=$KIND）。真机直装必须用调试 Profile。"; exit 4
fi
if [ -n "$BUNDLE" ] && [ "$BUNDLE" != "com.hong.tv" ]; then
  echo "✗ Profile 包名是 $BUNDLE，与工程的 com.hong.tv 不一致"; exit 5
fi
if [ "$HASUDID" != "yes" ]; then
  echo "⚠ 警告：Profile 的设备白名单里没找到这台电视的 UDID，装上可能报 device unauthorized。"
  echo "  确认 AGC 申请 Profile 时勾选了：BE38CEEEE9631D074204DBCF40DADC68146195564CDE799E1B1259617D29A893"
fi

# ---------- 1. 出未签名 Debug 包 ----------
BP=build-profile.json5
cp "$BP" "/tmp/bp-dbg-backup.json5"
restore() { cp "/tmp/bp-dbg-backup.json5" "$BP"; }
trap restore EXIT

python3 - "$BP" <<'PYEOF'
import re, io, sys
bp = sys.argv[1]
s = io.open(bp, encoding='utf-8').read()
# 只清空 signingConfigs 数组本身，不跨行（跨行会把 products 误删）
s = re.sub(r'"signingConfigs"\s*:\s*\[[^\]]*\]', '"signingConfigs": []', s, count=1)
s = re.sub(r'\s*"signingConfig"\s*:\s*"[^"]*",?', '', s, count=1)
io.open(bp, 'w', encoding='utf-8').write(s)
PYEOF

echo "→ 编译未签名 Debug…"
export DEVECO_SDK_HOME="$DEVECO/sdk"
export NODE_HOME="$DEVECO/tools/node"
export PATH="$NODE_HOME/bin:$DEVECO/sdk/default/openharmony/toolchains:$PATH"
LOG="${TMPDIR:-/tmp}/hmy-dbg-build.log"
HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw"
[ -x "$ROOT/hvigorw" ] && HVIGOR="$ROOT/hvigorw"
"$HVIGOR" --mode module -p product=default -p buildMode=debug assembleHap --no-daemon > "$LOG" 2>&1
if ! grep -q "BUILD SUCCESSFUL" "$LOG"; then
  echo "✗ 编译失败，日志：$LOG"
  grep -n "Error Message" "$LOG" | head -6
  exit 6
fi
[ -f "$UNSIGNED" ] || { echo "✗ 没找到未签名包：$UNSIGNED"; exit 6; }
echo "  未签名包：$(du -h "$UNSIGNED" | cut -f1)"

# ---------- 2. 签名 ----------
mkdir -p "$OUT"
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
  -compatibleVersion 12 \
  -signCode 1 > "${TMPDIR:-/tmp}/hmy-dbg-sign.log" 2>&1
RC=$?
tail -4 "${TMPDIR:-/tmp}/hmy-dbg-sign.log"
if [ $RC -ne 0 ] || [ ! -f "$TARGET" ]; then
  echo "✗ 签名失败（退出码 $RC）。常见：密码不对、.cer/.p7b 不是同一对、alias 不是 debugKey。"
  exit 7
fi

# ---------- 3. 校验 ----------
echo "→ 校验签名…"
"$JAVA" -jar "$JAR" verify-app -inFile "$TARGET" -outCertChain "$OUT/cert-chain.cer" \
  -outProfile "$OUT/profile.p7b" > "${TMPDIR:-/tmp}/hmy-dbg-verify.log" 2>&1
if grep -qi "verify success" "${TMPDIR:-/tmp}/hmy-dbg-verify.log" || [ -f "$OUT/cert-chain.cer" ]; then
  echo
  echo "✓ Debug 签名完成并通过校验"
  echo "  产物：$TARGET  ($(du -h "$TARGET" | cut -f1))"
  echo
  echo "装到真机："
  echo "  ./scripts/install.sh 192.168.1.207:33609 $TARGET"
else
  echo "✗ 校验未通过，日志：${TMPDIR:-/tmp}/hmy-dbg-verify.log"
  tail -8 "${TMPDIR:-/tmp}/hmy-dbg-verify.log"
  exit 8
fi
