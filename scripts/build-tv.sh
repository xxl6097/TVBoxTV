#!/usr/bin/env bash
# 一条命令出「可直接装到真机/电视」的调试包，并可选安装。
#
#   ./scripts/build-tv.sh                                  # 只构建，产出 build/ci/*-signed.hap
#   ./scripts/build-tv.sh --install 192.168.100.176:5555   # 构建 + 装到电视
#   ./scripts/build-tv.sh --install 192.168.10.168:37713   # 构建 + 装到手机
#   ./scripts/build-tv.sh --build-mode release             # 换构建模式（默认 debug）
#
# 它现在只是「本地封装」，不再自己实现编译/签名：
#   编译 + 签名 → 交给 scripts/ci-build.sh --mode sign（与 CNB 流水线同一份代码）
#   装到设备    → hdc tconn + hdc install -r
#
# 为什么签名不写进 build-profile.json5 的 signingConfigs：
#   hvigor 要求 storePassword / keyPassword 是 DevEco 加密后的密文（长度 ≥ 32），
#   写明文直接被拒「The length of the storePassword or keyPassword field is
#   less than 32」，而密文只能由 DevEco 图形界面生成。所以：
#     hvigor 出未签名 hap → SDK 自带 hap-sign-tool.jar 补签（接受明文口令）
#
# 签名材料（AGC 下发的调试描述文件 + 自签密钥库），按顺序找：
#   ${SIGN_DIR}（默认 .ci-sign） → ~/.ohos/debug-key
#   hongmengyingshi-debug.p12   私钥库，别名 debugkey，口令见 HMY_STOREPASS
#   hongmengyingshi-debug.cer   叶子证书
#   hongmengyingshi-debug.p7b   debug Profile：bundle-name=com.hong.tv
#                               设备白名单含手机 + 电视，有效期至 2027-11-03
# 与 scripts/sign-release.sh 的区别：那个出上架用 .app（release，装了会报
# 9568322 not trusted app source）；这个出真机自测用 .hap（debug）。
# 云端构建见 .cnb.yml 与 docs/CNB构建.md。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
# shellcheck source=lib/harmony-env.sh
. "$ROOT/scripts/lib/harmony-env.sh"

TARGET_DEV=""
BUILD_MODE="debug"

while [ $# -gt 0 ]; do
  case "$1" in
    --install) TARGET_DEV="${2:-}"; shift 2 || shift ;;
    --build-mode) BUILD_MODE="${2:-}"; shift 2 || shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

# 本地默认口令（与历史行为一致）；CI 由密钥仓库注入 HMY_STOREPASS
export HMY_STOREPASS="${HMY_STOREPASS:-het002402}"
export HMY_ALIAS="${HMY_ALIAS:-debugkey}"

# ---------- 1. 编译 + 签名（与 CNB 流水线同一实现）----------
"$ROOT/scripts/ci-build.sh" --mode sign --build-mode "$BUILD_MODE" || exit $?

INFO="$ROOT/build/ci/build-info.txt"
HAP="$ROOT/$(sed -n 's/^hap=//p' "$INFO" | head -1)"
BUNDLE="$(sed -n 's/^bundle=//p' "$INFO" | head -1)"
[ -f "$HAP" ] || { echo "✗ 没找到签名包：$HAP"; exit 8; }

# ---------- 2. 可选安装 ----------
if [ -z "$TARGET_DEV" ]; then
  echo
  echo "装到设备："
  echo "  hdc tconn <ip:port> && hdc install -r \"$HAP\""
  echo "  或：./scripts/build-tv.sh --install <ip:port>"
  exit 0
fi

SIGN_DIR="${SIGN_DIR:-$ROOT/.ci-sign}"
[ -f "$SIGN_DIR/hongmengyingshi-debug.p7b" ] || SIGN_DIR="$HOME/.ohos/debug-key"
DEVIDS="$(hv_profile_devids "$SIGN_DIR/hongmengyingshi-debug.p7b")"

# hdc 的 tconn 端口对同一台机器是复用的，重复连也安全
if ! hdc list targets 2>/dev/null | grep -q "$TARGET_DEV"; then
  echo "→ 连接 ${TARGET_DEV}…"
  hdc tconn "$TARGET_DEV" >/dev/null 2>&1
fi
if ! hdc list targets 2>/dev/null | grep -q "$TARGET_DEV"; then
  echo "✗ 连不上 ${TARGET_DEV}（设备需开启开发者模式 + USB/无线调试，端口见 hdc 页面）"; exit 9
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
if hdc -t "$TARGET_DEV" install -r "$HAP" 2>&1 | tee "${TMPDIR:-/tmp}/hmy-tv-install.log" | grep -q "install bundle successfully"; then
  echo "✓ 已安装。启动：hdc -t $TARGET_DEV shell aa start -a EntryAbility -b $BUNDLE"
else
  echo "✗ 安装失败："; tail -5 "${TMPDIR:-/tmp}/hmy-tv-install.log"; exit 11
fi
