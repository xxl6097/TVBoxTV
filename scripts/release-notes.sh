#!/usr/bin/env bash
# release-notes.sh —— 出包后、建 Release 前的最后一步（只在发版按钮里跑）
#
# 做三件事：
#   1. 校验 —— 按钮填的版本号必须和 app.json5 编译出来的 version 一致，
#      否则会出现「v1.2.0 的 Release 挂了个 1.1.0 的包」这种不可挽回的脏数据
#   2. 改文件名 —— hap 原名带中文（夜帧影视-1.1.0-debug-signed.hap），
#      Release 附件名走 URL，中文会被转义成一长串 %E5%A4%9C…，改成 ASCII
#   3. 写正文 —— 生成 dist/release-notes.md（git:release 用 descriptionFromFile 读它）
#
# 环境变量（由 .cnb/web_trigger.yml 的 inputs 注入）：
#   REL_VERSION  版本号，必填，形如 1.1.0（不带 v，带 v 会自动去掉）
#   REL_NOTE     更新说明，可选
#
# 产物：
#   dist/release/yezhen-tv-<版本>-<debug|release>.hap   实际发出去的附件
#   dist/release-notes.md                               Release 正文
#   dist/release-info.txt                               tag / 附件名 / 下载地址（扁平清单）
#
# 退出码：0 成功 / 7 版本号缺失或与包不一致 / 8 找不到待发布的 hap
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
# shellcheck source=lib/harmony-env.sh
. "$ROOT/scripts/lib/harmony-env.sh"

INFO="$ROOT/dist/build-info.txt"
[ -f "$INFO" ] || hv_die "没有 $INFO —— 发布前必须先跑 ./scripts/ci-build.sh --mode sign" 8

# 读扁平清单（key=value，一行一个字段）
info() { sed -n "s/^$1=//p" "$INFO" | head -1; }

VER="$(info version)"
MODE="$(info build_mode)"
HAP_REL="$(info hap)"
SHA="$(info sha256)"
SIZE="$(info size)"
COMMIT="$(info commit)"
BRANCH="$(info branch)"
BUILT_AT="$(info built_at)"
BUNDLE="$(info bundle)"
VCODE="$(info version_code)"
APP="$(info app)"

# ---------------- 1. 版本校验 ----------------
WANT="${REL_VERSION:-}"
WANT="${WANT#v}"          # 允许用户手填 v1.1.0
WANT="${WANT#V}"
if [ -z "$WANT" ]; then
  hv_die "没有传版本号（环境变量 REL_VERSION）——请用页面上的发版按钮，或手动 REL_VERSION=1.1.0 ./scripts/release-notes.sh" 7
fi
if [ "$WANT" != "$VER" ]; then
  echo "✗ 版本号对不上：按钮填的是 ${WANT}，实际编出来的是 $VER"
  echo "  要么把 AppScope/app.json5 的 versionName 改成 $WANT 重新出包，"
  echo "  要么把按钮里的版本号改成 ${VER}。发版不做自动改写，避免 tag 与包体不一致。"
  exit 7
fi

# ---------------- 2. 附件改名（ASCII） ----------------
HAP_ABS="$ROOT/$HAP_REL"
[ -f "$HAP_ABS" ] || hv_die "清单里写的包不存在：$HAP_REL" 8

ASSET="yezhen-tv-${VER}-${MODE}.hap"
OUT_DIR="$ROOT/dist/release"
mkdir -p "$OUT_DIR"
cp -f "$HAP_ABS" "$OUT_DIR/$ASSET"
hv_ok "发布附件：dist/release/${ASSET}（$(hv_size "$OUT_DIR/$ASSET")）"

TAG="v${VER}"
REPO="${CNB_REPO_SLUG:-abber/HarmonyTv}"
URL="https://cnb.cool/${REPO}/-/releases/download/${TAG}/${ASSET}"

# ---------------- 3. 写 Release 正文 ----------------
NOTES="$ROOT/dist/release-notes.md"
{
  if [ -n "${REL_NOTE:-}" ]; then
    printf '%s\n\n' "$REL_NOTE"
  fi
  printf '## 安装包\n\n'
  printf '| 项 | 值 |\n|---|---|\n'
  printf '| 文件 | `%s` |\n' "$ASSET"
  printf '| 大小 | %s |\n' "$SIZE"
  printf '| SHA-256 | `%s` |\n' "$SHA"
  printf '| 包名 | `%s` |\n' "$BUNDLE"
  printf '| 版本 | %s（versionCode %s） |\n' "$VER" "$VCODE"
  printf '| 构建模式 | %s |\n' "$MODE"
  printf '| 签名 | 调试证书（仅限白名单设备直装，不能上架） |\n'
  printf '\n## 安装\n\n'
  printf '```bash\n'
  # -L 必须加：CNB 的下载地址会 302 跳到 CDN
  printf 'curl -fL -O %s\n' "$URL"
  printf 'hdc install -r %s\n' "$ASSET"
  printf '```\n'
  printf '\n## 构建信息\n\n'
  printf '| 项 | 值 |\n|---|---|\n'
  printf '| 应用 | %s |\n' "$APP"
  printf '| 分支 | %s |\n' "$BRANCH"
  printf '| 提交 | `%s` |\n' "$COMMIT"
  printf '| 构建时间 | %s |\n' "$BUILT_AT"
  printf '| 工具链 | %s |\n' "$(info toolkit)"
} > "$NOTES"
hv_ok "Release 正文：dist/release-notes.md"

# 给后续阶段/人工排查用的扁平清单
cat > "$ROOT/dist/release-info.txt" <<EOF
tag=$TAG
asset=dist/release/$ASSET
asset_name=$ASSET
sha256=$SHA
size=$SIZE
url=$URL
notes=dist/release-notes.md
EOF

echo
echo "================ 发布信息 ================"
sed 's/^/  /' "$ROOT/dist/release-info.txt"
echo "=========================================="
