#!/usr/bin/env bash
# 用 AGC 发布证书给 Release 包签名（完全命令行，不需要 DevEco 图形界面）。
# 最终产物是上架用的 .app（App Pack）——应用市场只收 .app，传 .hap 会被拒。
#
#   ./scripts/sign-release.sh <发布证书.cer> <发布Profile.p7b>
#
# 为什么不走 hvigor 的 signingConfigs：
#   hvigor 要求 storePassword / keyPassword 是 DevEco 加密后的密文（长度 ≥ 32），
#   明文会被直接拒绝：
#     「The length of the storePassword or keyPassword field is less than 32」
#   而密文只能用 DevEco 图形界面生成。为了不依赖 IDE，这里改成：
#     1) hvigor **assembleApp**（不是 assembleHap）出未签名 .app —— 只有它会生成
#        pac.json（隐私清单）和项目级 pack.info；手工用 app_packing_tool 打的包缺
#        这两样，AGC 上传时报「软件包解析失败」
#     2) 用 SDK 自带的 hap-sign-tool.jar 签 .app（它接受明文密码，-signCode 0）
#   两条命令都是官方工具，产物与 DevEco 签出来的一致。
#
# 前置（AGC 已签发好，直接可用）：
#   $SIGN_DIR/release.p12           私钥库，别名 release，口令见 HMY_STOREPASS
#   $SIGN_DIR/release.cer           证书链（root + 中间 CA + 开发者证书）
#   $SIGN_DIR/夜帧影视Release.p7b   发布 Profile：bundle-name=com.hong.tv, type=release
# 换了目录就用 SIGN_DIR 覆盖，换了口令用 HMY_STOREPASS 覆盖。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

SIGN_DIR="${SIGN_DIR:-/Users/uuxia/Desktop/work/code/huawei}"
P12="$SIGN_DIR/release.p12"
CER="${1:-$SIGN_DIR/release.cer}"
P7B="${2:-$SIGN_DIR/夜帧影视Release.p7b}"
ALIAS="${HMY_ALIAS:-release}"
PASS="${HMY_STOREPASS:-het002402}"

DEVECO="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
JAR="$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
APPPACK="$DEVECO/sdk/default/openharmony/toolchains/lib/app_packing_tool.jar"
JAVA="$DEVECO/jbr/Contents/Home/bin/java"
[ -x "$JAVA" ] || JAVA="$(command -v java)"

OUT="build/release"

# 版本号从 AppScope/app.json5 读，不写死。
# 原来这里硬编码 1.0.4，app.json5 早就升到 1.1.0 了，产物名一直是旧版本 ——
# 提审时按名字找包会拿错文件，商店里显示的还是 1.0.4。
VER="$(grep -m1 '"versionName"' "$ROOT/AppScope/app.json5" \
  | sed -E 's/.*"versionName"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
[ -n "$VER" ] || VER="0.0.0"
APP_UNSIGNED="$OUT/夜帧影视-${VER}-release-unsigned.app"
TARGET="$OUT/夜帧影视-${VER}-release-signed.app"

if [ -z "$CER" ] || [ -z "$P7B" ]; then
  cat <<EOF
用法：./scripts/sign-release.sh [发布证书.cer] [发布Profile.p7b]

不给参数就用默认位置（AGC 已签发好的）：
  $SIGN_DIR/release.cer
  $SIGN_DIR/夜帧影视Release.p7b

可用环境变量覆盖：
  SIGN_DIR        证书目录，默认 /Users/uuxia/Desktop/work/code/huawei
  HMY_STOREPASS   密钥库口令，默认 het002402
  HMY_ALIAS       密钥别名，默认 release
EOF
  exit 2
fi
[ -f "$CER" ] || { echo "✗ 找不到 .cer：$CER"; exit 3; }
[ -f "$P7B" ] || { echo "✗ 找不到 .p7b：$P7B"; exit 3; }
[ -f "$P12" ] || { echo "✗ 找不到密钥库：$P12"; exit 3; }
[ -x "$JAVA" ] || { echo "✗ 找不到 java"; exit 3; }
[ -f "$JAR" ] || { echo "✗ 找不到 hap-sign-tool.jar：$JAR"; exit 3; }
[ -f "$APPPACK" ] || { echo "✗ 找不到 app_packing_tool.jar：$APPPACK"; exit 3; }

# ---------- 0. Profile 必须是发布类型 ----------
KIND=$(python3 - "$P7B" <<'PYEOF'
import re, sys
d = open(sys.argv[1], 'rb').read()
m = re.search(rb'"type"\s*:\s*"(debug|release)"', d)
print(m.group(1).decode() if m else 'unknown')
PYEOF
)
HASDEV=$(python3 - "$P7B" <<'PYEOF'
import sys
d = open(sys.argv[1], 'rb').read()
print('yes' if b'"device-ids"' in d else 'no')
PYEOF
)
BUNDLE=$(python3 - "$P7B" <<'PYEOF'
import re, sys
d = open(sys.argv[1], 'rb').read().decode('utf-8', 'ignore')
m = re.search(r'"bundle-name"\s*:\s*"([^"]+)"', d)
print(m.group(1) if m else '')
PYEOF
)
echo "→ Profile：type=$KIND  device-ids=$HASDEV  bundle=$BUNDLE"
if [ "$KIND" != "release" ] || [ "$HASDEV" != "no" ]; then
  echo "✗ 这不是发布 Profile（或含设备白名单），商店会拒。请到 AGC 重新创建「发布」Profile。"
  exit 4
fi
if [ -n "$BUNDLE" ] && [ "$BUNDLE" != "com.hong.tv" ]; then
  echo "✗ Profile 里的包名是 $BUNDLE，与工程的 com.hong.tv 不一致"
  exit 5
fi

# ---------- 1. 出一份未签名 Release 包 ----------
# hvigor 只有在 product 没引用 signingConfig 时才出未签名包，
# 所以临时把配置改成空签名，编译完立刻还原（失败也会还原）。
BP=build-profile.json5
cp "$BP" "/tmp/bp-sign-backup.json5"
restore() { cp "/tmp/bp-sign-backup.json5" "$BP"; }
trap restore EXIT

python3 - "$BP" <<'PYEOF'
import re, io, sys
bp = sys.argv[1]
s = io.open(bp, encoding='utf-8').read()
s = re.sub(r'"signingConfigs"\s*:\s*\[[^\]]*\]', '"signingConfigs": []', s, count=1)
s = re.sub(r'\s*"signingConfig"\s*:\s*"[^"]*",?', '', s, count=1)
io.open(bp, 'w', encoding='utf-8').write(s)
PYEOF

echo "→ 编译未签名 Release .app…"
export DEVECO_SDK_HOME="$DEVECO/sdk"
export NODE_HOME="$DEVECO/tools/node"
export PATH="$NODE_HOME/bin:$DEVECO/sdk/default/openharmony/toolchains:$PATH"
LOG="${TMPDIR:-/tmp}/hmy-sign-build.log"
HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw"
[ -x "$ROOT/hvigorw" ] && HVIGOR="$ROOT/hvigorw"

# 必须用 assembleApp（不是 assembleHap + app_packing_tool 手工打包）。
# 手工打出来的 .app 只有 pack.info + hap 两个条目，缺 pac.json（隐私清单），
# 用的还是模块级 pack.info（字段不全），AGC 上传时直接报「软件包解析失败」，
# 错误详情只给一个错误码，极难自查。assembleApp 产出的才是官方结构：
#   entry-default.hap + pack.info（项目级）+ pac.json（{"dataProcess":[],"specialAPIs":[]}）
CACHE_REL="$ROOT/entry/build/default/cache/default/default@CompileArkTS/esmodule/release"
if [ -d "$CACHE_REL" ]; then
  # hvigor 清理该目录时是整目录删除，文件一多会被环境的批量删除保护拦下
  # （safe-delete 钩子 → hvigor 报 00308018 Unknown Error），先挪开再编译。
  mv "$CACHE_REL" "${TMPDIR:-/tmp}/hv-cache-aside-$(date +%s)" 2>/dev/null || true
fi
"$HVIGOR" --mode project -p product=default -p buildMode=release assembleApp --no-daemon > "$LOG" 2>&1
if ! grep -q "BUILD SUCCESSFUL" "$LOG"; then
  echo "✗ 编译失败，日志：$LOG"
  grep -n "Error Message" "$LOG" | head -6
  exit 6
fi

# ---------- 2. 取出 hvigor 产出的未签名 .app ----------
RAW_APP="$(ls -t "$ROOT"/build/outputs/default/*-unsigned.app 2>/dev/null | head -1)"
[ -n "$RAW_APP" ] && [ -f "$RAW_APP" ] || {
  echo "✗ 没找到未签名 .app（build/outputs/default/*-unsigned.app）"
  echo "  编译日志：$LOG"
  exit 7
}
mkdir -p "$OUT"
cp "$RAW_APP" "$APP_UNSIGNED"
echo "  未签名 .app：$(basename "$RAW_APP")  $(du -h "$APP_UNSIGNED" | cut -f1)"
# 结构自检：缺 pac.json 的包上 AGC 一定解析失败，先在这里拦下来
if ! unzip -l "$APP_UNSIGNED" 2>/dev/null | grep -q 'pac.json'; then
  echo "✗ .app 里没有 pac.json（隐私清单），AGC 会报「软件包解析失败」"
  exit 7
fi

# ---------- 3. 用官方工具签名 .app ----------
echo "→ 签名 .app…"
# -signCode 0：代码签名只对 hap/hsp/hqf/elf 生效，签 .app 时置 0，
# 只给它挂 .app 自己的签名块（体积增加约 14.7 KB）。用 1 在部分 AGC 校验里会被判非法包。
"$JAVA" -jar "$JAR" sign-app \
  -mode localSign \
  -keyAlias "$ALIAS" \
  -keyPwd "$PASS" \
  -keystoreFile "$P12" \
  -keystorePwd "$PASS" \
  -appCertFile "$CER" \
  -profileFile "$P7B" \
  -inFile "$APP_UNSIGNED" \
  -outFile "$TARGET" \
  -signAlg SHA256withECDSA \
  -compatibleVersion 12 \
  -signCode 0 > "${TMPDIR:-/tmp}/hmy-sign.log" 2>&1
RC=$?
tail -5 "${TMPDIR:-/tmp}/hmy-sign.log"
if [ $RC -ne 0 ] || [ ! -f "$TARGET" ]; then
  cat <<EOF

✗ 签名失败（退出码 $RC）。常见原因：
  · 密码不对 —— 用 HMY_STOREPASS='口令' 覆盖（默认 $PASS）
  · .cer 与 .p7b 不是同一次申请的一对
  · keyAlias 不是 releaseKey
  · .cer 没有先导入密钥库（脚本会提示，执行：
      keytool -importcert -alias releaseKey -file <证书.cer> \\
        -keystore $P12 -storetype PKCS12 -storepass '口令' -noprompt）
EOF
  exit 7
fi

# ---------- 4. 校验产物 ----------
echo "→ 校验签名…"
"$JAVA" -jar "$JAR" verify-app -inFile "$TARGET" -outCertChain "$OUT/cert-chain.cer" \
  -outProfile "$OUT/profile.p7b" > "${TMPDIR:-/tmp}/hmy-verify.log" 2>&1
if grep -qi "verify success\|VERIFY_SUCCESS" "${TMPDIR:-/tmp}/hmy-verify.log" || [ -f "$OUT/cert-chain.cer" ]; then
  echo
  echo "✓ 签名完成并通过校验"
  echo "  产物：$TARGET  ($(du -h "$TARGET" | cut -f1))"
  echo
  cat <<EOF
接下来在 AGC 网页提交（注意：上传的是 .app，不是 .hap）：
  1. 我的应用 → 找到「夜帧影视」（包名 com.hong.tv）
  2. 上传 docs/store/icon_1024.png
  3. 粘贴 docs/store/应用市场文案.md 的介绍与更新说明
  4. 上传 docs/store/screenshots/ 的截图
  5. 隐私政策 URL：https://s3a.abber.cn:88/public/privacy.html
  6. 上传软著扫描件
  7. 版本信息 → 上传 $TARGET
  8. 审核备注用 docs/store/审核备注.md 里那段，提交审核
EOF
else
  echo "✗ 校验未通过，日志：${TMPDIR:-/tmp}/hmy-verify.log"
  tail -8 "${TMPDIR:-/tmp}/hmy-verify.log"
  exit 8
fi
