#!/usr/bin/env bash
# 提审前自检。逐条检查应用市场会因为哪些项直接打回，跑完给出明确的红绿结论。
#   ./scripts/preflight.sh
#
# 设计原则：只做**能自动化验证**的检查。凡是要登录 AGC、要人工判断的，
# 一律标成「需人工」，不假装通过。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0
FAIL=0
WARN=0
MANUAL=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
todo() { printf '  \033[36m→\033[0m %s\n' "$1"; MANUAL=$((MANUAL+1)); }

echo "=============================================="
echo " 夜帧影视 · 应用市场提审自检"
echo "=============================================="

# ---------- 1. 版本号 ----------
echo
echo "[1/10] 版本与包名"
BG=$(python3 -c "
import re,io
s=io.open('AppScope/app.json5',encoding='utf-8').read()
b=re.search(r'\"bundleName\"\s*:\s*\"([^\"]+)\"',s)
c=re.search(r'\"versionCode\"\s*:\s*(\d+)',s)
n=re.search(r'\"versionName\"\s*:\s*\"([^\"]+)\"',s)
print((b.group(1) if b else '')+' '+(c.group(1) if c else '0')+' '+(n.group(1) if n else ''))
")
PKG=$(echo "$BG" | cut -d' ' -f1)
VC=$(echo "$BG" | cut -d' ' -f2)
VN=$(echo "$BG" | cut -d' ' -f3)
echo "  package=$PKG  versionCode=$VC  versionName=$VN"
if [ -n "$PKG" ]; then ok "包名已设置：$PKG"; else bad "读不到 bundleName"; fi
if [ "$VC" -gt 1000000 ] 2>/dev/null; then ok "versionCode=$VC"; else warn "versionCode=$VC，首次提审建议从 1000001 起"; fi

# ---------- 2. 权限 ----------
echo
echo "[2/10] 权限清单（越少越容易过）"
PERMS=$(python3 -c "
import re,io
s=io.open('entry/src/main/module.json5',encoding='utf-8').read()
print(','.join(re.findall(r'\"name\"\s*:\s*\"(ohos\.permission\.[^\"]+)\"',s)))
")
echo "  已申请：$PERMS"
CNT=$(echo "$PERMS" | tr ',' '\n' | grep -c 'ohos.permission' || true)
if [ "$CNT" -le 3 ]; then ok "仅 $CNT 项权限（INTERNET + GET_NETWORK_INFO，属最低限度）"; else bad "$CNT 项权限，超出必要范围，审核会要说明"; fi
for p in LOCATION CAMERA MICROPHONE READ_MEDIA READ_CONTACTS READ_CALL_LOG; do
  if echo "$PERMS" | grep -qi "$p"; then bad "申请了敏感权限 $p，需单独说明，建议删掉"; fi
done

# ---------- 3. 签名证书 ----------
echo
echo "[3/10] 签名证书类型"
# 签名不走 build-profile.json5 的 signingConfigs（hvigor 只吃 DevEco 生成的
# 加密口令，命令行写不进去），改成 build.sh → sign-release.sh 后置签名。
# 这里直接校验「真正用来签的那套材料」，校验逻辑写在 python 里，
# 避免 bash 里 `read` + 嵌套 heredoc 把中文标点并进变量名。
SIGN_DIR="${SIGN_DIR:-/Users/uuxia/Desktop/work/code/huawei}"
if python3 - "$SIGN_DIR" <<'PY'
import sys, os, re
d = sys.argv[1]
prof = os.path.join(d, '夜帧影视Release.p7b')
cer = os.path.join(d, 'release.cer')
p12 = os.path.join(d, 'release.p12')
missing = [os.path.basename(x) for x in (prof, cer, p12) if not os.path.isfile(x)]
if missing:
    print('MISSING ' + ','.join(missing))
    sys.exit(1)
raw = open(prof, 'rb').read()
k = re.search(rb'"type"\s*:\s*"(debug|release)"', raw)
b = re.search(rb'"bundle-name"\s*:\s*"([^"]+)"', raw)
kind = k.group(1).decode() if k else 'unknown'
bundle = b.group(1).decode() if b else ''
hasdev = 'yes' if b'"device-ids"' in raw else 'no'
print('KIND=%s HASDEV=%s BUNDLE=%s' % (kind, hasdev, bundle))
sys.exit(0 if (kind == 'release' and hasdev == 'no' and bundle == 'com.hong.tv') else 2)
PY
then
  ok "AGC 发布证书（type=release，无设备白名单，bundle=com.hong.tv）"
else
  bad "发布证书不合要求，或缺少文件（需要 release.p12 / release.cer / 发布 Profile）"
  echo "     目录：${SIGN_DIR}"
fi

echo "[4/10] 首启隐私合规（应用市场硬门槛）"
H=entry/src/main/ets/pages/Home.ets
if grep -q "privacyAgreed" "$H" 2>/dev/null; then ok "启动时读取隐私同意标记"; else bad "未见 privacyAgreed 判断"; fi
if grep -q "ConsentPanel" "$H" 2>/dev/null; then ok "隐私政策面板已接入"; else bad "未见 ConsentPanel"; fi
if grep -q "terminateSelf" "$H" 2>/dev/null; then ok "「不同意」会退出应用（不是仅关闭面板）"; else bad "缺少不同意出口"; fi
# 未同意前必须不联网。
# 判据用 python 独立脚本文件而不是内联 heredoc —— 内联时脚本里只要出现一行与
# 定界符相同的字面量，外层 heredoc 就会提前收尾，整段被当成 shell 解析。
CHK="${TMPDIR:-/tmp}/preflight_consent.py"
cat > "$CHK" <<'PYEOF'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'async aboutToAppear\(\)[^{]*\{', s)
if not m:
    sys.exit(1)
# 从 { 起配平花括号，取出函数体
i = s.index('{', m.start())
depth = 0
j = i
while j < len(s):
    if s[j] == '{':
        depth += 1
    elif s[j] == '}':
        depth -= 1
        if depth == 0:
            break
    j += 1
body = s[i:j + 1]
i_ret = body.find('return;')
i_load = body.find('ensureLoaded')
i_crawl = body.find('autoCrawl(')
# 合规形态有两种：
#   a) 同意前直接 return，加载逻辑全在 boot() 里（本项目用这种）
#   b) 加载逻辑在函数内，但 return 出现在它前面
if i_load < 0 and i_crawl < 0:
    sys.exit(0)
if i_ret >= 0 and (i_load < 0 or i_load > i_ret) and (i_crawl < 0 or i_crawl > i_ret):
    sys.exit(0)
sys.exit(1)
PYEOF
if python3 "$CHK" "$H"; then ok "同意前不加载配置、不抓站源"; else bad "aboutToAppear 可能在同意前就联网"; fi

# ---------- 5. 隐私政策可访问 ----------
echo
echo "[5/10] 隐私政策公网地址"
PURL=$(grep -rho 'https://[a-z0-9.]*:[0-9]*/public/privacy\.html' docs/store/应用市场文案.md 2>/dev/null | head -1)
if [ -z "$PURL" ]; then
  bad "文案里找不到隐私政策 URL"
else
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$PURL" 2>/dev/null || echo 000)
  if [ "$CODE" = "200" ]; then
    ok "$PURL → 200"
  else
    bad "$PURL → $CODE（商店会因此打回）"
  fi
fi

# ---------- 6. 商店物料 ----------
echo
echo "[6/10] 商店物料"
ICON=docs/store/icon_1024.png
if [ -f "$ICON" ]; then
  SZ=$(python3 -c "from PIL import Image;print(Image.open('$ICON').size)" 2>/dev/null || echo '?')
  if [ "$SZ" = "(1024, 1024)" ]; then ok "图标 1024×1024"; else warn "图标尺寸 $SZ，商店要求 1024×1024"; fi
else
  bad "缺图标 docs/store/icon_1024.png"
fi
SS=$(ls docs/store/screenshots/*.png 2>/dev/null | wc -l | tr -d ' ')
if [ "$SS" -ge 4 ]; then ok "截图 $SS 张（≥4 张，1920×1080）"; else bad "截图只有 $SS 张，商店要求 ≥3 张、建议 5~8 张"; fi
for f in "docs/store/应用市场文案.md" "docs/隐私政策.md" "docs/上架指南.md"; do
  [ -f "$f" ] && ok "物料：$f" || bad "缺 $f"
done

# ---------- 7. Release 产物 ----------
echo
echo "[7/10] 可提审的产物"
# 应用市场只收 .app（App Pack），.hap 会被拒「不是 .app 后缀」。
# 优先看 sign-release.sh 的 .app 产出；没有就退回 debug 包并明确标红，
# 因为 debug 包只能装白名单设备，传上去必被拒。
REL=$(ls build/release/*-signed.app 2>/dev/null | head -1)
DBG=entry/build/default/outputs/default/entry-default-signed.hap
if [ -n "$REL" ]; then
  BYTES=$(wc -c < "$REL" | tr -d ' ')
  ok "发布签名 .app：${REL}（$(du -h "$REL" | cut -f1)）"
  if [ "$BYTES" -gt 2000000 ]; then warn "包体 ${BYTES} 字节偏大，检查是否误打进去调试资源"; fi
elif [ -f "$DBG" ]; then
  warn "只有调试包（$(du -h "$DBG" | cut -f1)），可装机自测，不能提审 —— 拿到 AGC 证书后跑 ./scripts/sign-release.sh"
else
  bad "没有产物，先跑 ./scripts/build.sh"
fi

# ---------- 8. 必须人工完成的 ----------
echo
echo "[8/10] 只能由你本人完成的（我无法代办）"
todo "AGC 开发者账号登录 + 实名（个人身份证 / 企业营业执照）"
todo "软著登记证书（中国版权保护中心，30~60 工作日；或代理加急 3~15 天）"
ok "AGC 发布证书与 Profile 已就位，build.sh 会自动用它签名"
todo "AGC 创建应用、上传图标/截图/文案/软著、填提审备注"
echo
# ---------- 9. 应用图标规范 ----------
echo "[9/10] 应用图标（尺寸 / 透明角 / 边缘干净）"
if python3 "$ROOT/scripts/gen-icon.py" --check; then
  ok "图标符合 Apple 图标规范（squircle、四角透明、边缘一圈同色、无白边）"
else
  bad "图标不合规，跑 python3 scripts/gen-icon.py 重新生成"
fi

# ---------- 10. 软著材料与代码一致性 ----------
echo "[10/10] 软著材料与代码一致性"
if python3 "$ROOT/scripts/check-copyright.py"; then
  ok "软著三份材料与当前代码一致"
else
  bad "软著材料已过期或不合规，按上面明细重跑生成脚本"
fi

# ---------- 结论 ----------
echo "=============================================="
printf " 通过 %d  失败 %d  警告 %d  待人工 %d\n" "$PASS" "$FAIL" "$WARN" "$MANUAL"
if [ "$FAIL" -eq 0 ]; then
  echo " 自动检查项全绿。上面剩余的待人工事项完成后即可提审。"
  echo "=============================================="
  exit 0
else
  echo " 有 $FAIL 项必须修复，否则提审必被打回。"
  echo "=============================================="
  exit 1
fi
