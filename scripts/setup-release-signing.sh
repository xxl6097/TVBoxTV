#!/usr/bin/env bash
# 把 AGC 下发的发布证书接进工程。
#
# 用法：
#   ./scripts/setup-release-signing.sh <发布证书.cer> <发布Profile.p7b>
#
# 它会做四件事：
#   1. 把 AGC 签发的 .cer 导入到本机密钥库（keytool -importcert，替换自签名链）
#   2. 备份 build-profile.json5，写入 release 签名配置
#   3. 用 release 配置编译一次，验证证书链与 Profile 是否匹配
#   4. 打印结论与后续步骤
#
# 前置：先用本机密钥库生成 CSR 并到 AGC 申请证书。
#   密钥库与 CSR 已生成在 ~/.ohos/release-key/
#     hongmengyingshi-release.p12   （私钥，务必备份，丢了就无法再更新应用）
#     hongmengyingshi-release.csr   （上传给 AGC）
#   密钥库口令见 docs/上架指南.md，或环境变量 HMY_STOREPASS
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

CER="${1:-}"
P7B="${2:-}"
KEYDIR="$HOME/.ohos/release-key"
P12="$KEYDIR/hongmengyingshi-release.p12"
ALIAS="releaseKey"
PASS="${HMY_STOREPASS:-Het002402@HMYS}"

if [ -z "$CER" ] || [ -z "$P7B" ]; then
  cat <<EOF
用法：./scripts/setup-release-signing.sh <发布证书.cer> <发布Profile.p7b>

还没有这两个文件的话，按下面走一遍（约 10 分钟）：

  1. 打开 https://developer.huawei.com/consumer/cn/service/josp/agc/index.html
  2. 证书、APP ID 和 Profile → 证书 → 新建证书
       - 类型：发布证书
       - 上传 CSR：$KEYDIR/hongmengyingshi-release.csr
     下载得到 .cer
  3. APP ID → 新建 → 包名填 com.hong.tv，设备类型勾 TV / 平板 / 手机
  4. Profile → 新建 → 类型选「发布」
       - 关联上一步的证书与 APP ID（发布 Profile 不用勾设备）
     下载得到 .p7b
  5. 回到这里重跑本脚本，把两个文件路径传进来
EOF
  exit 2
fi

[ -f "$CER" ] || { echo "✗ 找不到 .cer：$CER"; exit 3; }
[ -f "$P7B" ] || { echo "✗ 找不到 .p7b：$P7B"; exit 3; }
[ -f "$P12" ] || { echo "✗ 找不到密钥库：$P12"; exit 3; }

KT="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/keytool"
[ -x "$KT" ] || KT="$(command -v keytool)"
[ -n "$KT" ] || { echo "✗ 找不到 keytool"; exit 3; }

# ---------- 1. 把签发证书导入密钥库 ----------
echo "→ 导入证书链到 $P12"
cp "$P12" "$P12.bak-$(date +%m%d-%H%M%S)"
"$KT" -importcert -alias "$ALIAS" -file "$CER" -keystore "$P12" \
  -storetype PKCS12 -storepass "$PASS" -noprompt 2>&1 | tail -3

# ---------- 2. 确认是发布证书 ----------
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
echo "→ Profile 类型：$KIND，设备白名单：$HASDEV"
if [ "$KIND" != "release" ] || [ "$HASDEV" != "no" ]; then
  echo "✗ 这个 Profile 不是发布类型（或是带设备白名单的调试 Profile），商店会拒。"
  echo "  请到 AGC 重新创建「发布」Profile 再试。"
  exit 4
fi

# ---------- 3. 写 build-profile.json5 ----------
BP=build-profile.json5
cp "$BP" "$BP.bak-release-$(date +%m%d-%H%M%S)"
python3 - "$BP" "$P12" "$CER" "$P7B" "$PASS" "$ALIAS" <<'PYEOF'
import re, sys, io
bp, p12, cer, p7b, pw, alias = sys.argv[1:7]
s = io.open(bp, encoding='utf-8').read()

block = '''"signingConfigs": [
      {
        // 发布证书。密码在此为明文，hvigor 直接可用；
        // 若 DevEco 打开工程时提示重填，让它加密写回即可（不影响命令行构建）。
        "name": "release",
        "type": "HarmonyOS",
        "material": {
          "storeFile": "%s",
          "storePassword": "%s",
          "keyAlias": "%s",
          "keyPassword": "%s",
          "signAlg": "SHA256withECDSA",
          "certpath": "%s",
          "profile": "%s"
        }
      }
    ]''' % (p12, pw, alias, pw, cer, p7b)

s2 = re.sub(r'"signingConfigs"\s*:\s*\[.*?\n    \]', block, s, count=1, flags=re.S)
if s2 == s:
    # 空数组形态
    s2 = re.sub(r'"signingConfigs"\s*:\s*\[\s*\]', block, s, count=1)
s2 = re.sub(r'"signingConfig"\s*:\s*"[^"]*"', '"signingConfig": "release"', s2, count=1)
io.open(bp, 'w', encoding='utf-8').write(s2)
print('   build-profile.json5 已切到 release 签名')
PYEOF

# ---------- 4. 编译验证 ----------
echo "→ 编译 Release 验证…"
./scripts/build.sh
RC=$?

echo
if [ $RC -eq 0 ]; then
  cat <<'EOF'
✓ 发布签名已接好，包可以提审了。

  下一步（AGC 网页操作）：
    1. 我的应用 → 新建应用 → 名称「夜帧影视」、包名 com.hong.tv
    2. 上传 docs/store/icon_1024.png
    3. 粘贴 docs/store/应用市场文案.md 里的介绍与更新说明
    4. 上传 docs/store/screenshots/ 的 8 张截图
    5. 隐私政策 URL：https://s3a.abber.cn:88/public/privacy.html
    6. 上传软著扫描件
    7. 版本信息 → 上传 build/release/夜帧影视-1.0.4-release-signed.app
    8. 审核备注用文案里那段（含首启路径），提交审核

  提审前再跑一次自检：./scripts/preflight.sh
EOF
else
  cat <<EOF
✗ 编译或签名失败（退出码 $RC）。

  常见原因：
    · 密码不对：脚本用的是 \$HMY_STOREPASS，当前值不对就
      HMY_STOREPASS='你的口令' ./scripts/setup-release-signing.sh <cer> <p7b>
    · .cer 与 .p7b 不配套（证书和 Profile 必须是同一次申请里的一对）
    · 包名不一致：Profile 里 bundle-name 必须是 com.hong.tv

  已备份原配置：ls build-profile.json5.bak-release-*
  要回退：cp build-profile.json5.bak-release-* build-profile.json5
EOF
fi
exit $RC
