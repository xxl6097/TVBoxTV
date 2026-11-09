#!/usr/bin/env bash
# setup-github-secrets.sh —— 一键将本地签名材料配置到 GitHub Secrets
#
# 前置条件：
#   1. 安装 GitHub CLI：brew install gh
#   2. 登录：gh auth login
#   3. 本脚本自动读取 docs/ID/ 下的证书文件并上传为 Secrets
#
# 用法：
#   ./scripts/setup-github-secrets.sh
#   GITHUB_REPO=xxl6097/TVBoxTV ./scripts/setup-github-secrets.sh
#
# 上传的 Secrets：
#   HMY_P12_B64   test.p12 的 base64 编码
#   HMY_CER_B64   debug.cer 的 base64 编码（或 release.cer，根据需要）
#   HMY_P7B_B64   debugDebug.p7b 的 base64 编码（包含设备白名单）
#   HMY_STOREPASS 密钥库口令
#   HMY_ALIAS     密钥别名
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID_DIR="$ROOT/docs/ID"

# ── 检查工具 ──────────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
  echo "✗ 未找到 GitHub CLI（gh）"
  echo "  安装：brew install gh"
  echo "  登录：gh auth login"
  exit 1
fi

# ── 确定仓库 ──────────────────────────────────────────────────────────
REPO="${GITHUB_REPO:-xxl6097/TVBoxTV}"
echo "→ 目标仓库：$REPO"

# ── 读取签名材料路径 ──────────────────────────────────────────────────
P12="${HMY_P12:-$ID_DIR/test.p12}"
CER="${HMY_CER:-$ID_DIR/debug.cer}"
P7B="${HMY_P7B:-$ID_DIR/debugDebug.p7b}"
PASS="${HMY_STOREPASS:-het002402}"
ALIAS="${HMY_ALIAS:-hong}"

echo ""
echo "使用的签名材料："
echo "  P12: $P12"
echo "  CER: $CER"
echo "  P7B: $P7B"
echo "  密码: (已隐藏)"
echo "  别名: $ALIAS"
echo ""

# 检查文件存在
for f in "$P12" "$CER" "$P7B"; do
  if [ ! -f "$f" ]; then
    echo "✗ 文件不存在：$f"
    echo "  请确认 docs/ID/ 下有以下文件："
    echo "    test.p12  debug.cer  debugDebug.p7b"
    ls -la "$ID_DIR/" 2>/dev/null || true
    exit 2
  fi
done

# ── 设置 Secrets ──────────────────────────────────────────────────────
echo "→ 上传 Secrets 到 GitHub..."
echo ""

# P12
echo "  [1/5] HMY_P12_B64..."
base64 < "$P12" | gh secret set HMY_P12_B64 --repo "$REPO"
echo "  ✓"

# CER
echo "  [2/5] HMY_CER_B64..."
base64 < "$CER" | gh secret set HMY_CER_B64 --repo "$REPO"
echo "  ✓"

# P7B
echo "  [3/5] HMY_P7B_B64..."
base64 < "$P7B" | gh secret set HMY_P7B_B64 --repo "$REPO"
echo "  ✓"

# STOREPASS
echo "  [4/5] HMY_STOREPASS..."
printf '%s' "$PASS" | gh secret set HMY_STOREPASS --repo "$REPO"
echo "  ✓"

# ALIAS
echo "  [5/5] HMY_ALIAS..."
printf '%s' "$ALIAS" | gh secret set HMY_ALIAS --repo "$REPO"
echo "  ✓"

echo ""
echo "✓ 所有 Secrets 已设置完毕！"
echo ""
echo "下一步："
echo "  1. 构建 CI 镜像（首次）："
echo "     访问：https://github.com/$REPO/actions/workflows/build-image.yml"
echo "     或本地构建后推送到 ghcr.io"
echo ""
echo "  2. 手动触发编译："
echo "     访问：https://github.com/$REPO/actions/workflows/release.yml"
echo "     点击 Run workflow → 选择 sign 模式"
echo ""
echo "  3. 发布 Release（自动触发）："
echo "     git tag v1.1.0 && git push github v1.1.0"
