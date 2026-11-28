#!/usr/bin/env bash
# ci-build.sh —— CNB 流水线里的唯一构建入口（本地也能直接跑，用来复现 CI 行为）
#
#   ./scripts/ci-build.sh --toolchain              只打印工具链解析结果
#   ./scripts/ci-build.sh --mode compile           编译未签名 hap
#   ./scripts/ci-build.sh --mode sign              编译 + 调试签名（读环境变量里的签名材料）
#   ./scripts/ci-build.sh --mode sign --build-mode release
#
# 每次构建都会：versionName 的 patch 位 +1、versionCode +1，并把编译时间写进
# entry/src/main/ets/common/BuildInfo.ets（设置页「关于 · 版本」下面那行小字）。
# 想冻结版本号（例如打与 git tag 对应的包）：HMY_NO_BUMP=1 ./scripts/ci-build.sh ...
#
# 模式区别只在于「要不要补签」：编译流程完全一致，避免本地与 CI 各写一套。
#
# 签名材料来源（--mode sign）：
#   1) 环境变量 base64（CI，由 .cnb.yml 的 imports 从密钥仓库注入）
#        HMY_P12_B64 / HMY_CER_B64 / HMY_P7B_B64 / HMY_STOREPASS / HMY_ALIAS
#   2) 目录里已有明文（本地）
#        SIGN_DIR 默认 .ci-sign，其次 $HOME/.ohos/debug-key
#
# 产物：
#   dist/*.hap          可直装的包
#   dist/build-info.txt key=value 扁平清单，供后续阶段或脚本消费
#
# 退出码：
#   0 成功 / 2 工具链不全 / 3 编译失败 / 4 签名材料缺失 / 5 未签名包没找到 / 6 签名失败
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
# shellcheck source=lib/harmony-env.sh
. "$ROOT/scripts/lib/harmony-env.sh"

MODE="compile"
BUILD_MODE="debug"
PRODUCT="default"
ONLY_TOOLCHAIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --toolchain) ONLY_TOOLCHAIN=1; shift ;;
    --mode) MODE="${2:-}"; shift 2 || shift ;;
    --build-mode) BUILD_MODE="${2:-}"; shift 2 || shift ;;
    --product) PRODUCT="${2:-}"; shift 2 || shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) hv_die "未知参数：$1" 1 ;;
  esac
done

case "$MODE" in compile|sign) ;; *) hv_die "--mode 只支持 compile / sign" 1 ;; esac

hv_detect "$ROOT"
hv_log "工具链来源：${HV_TOOLKIT}"
if [ "$ONLY_TOOLCHAIN" = 1 ]; then
  hv_print_toolchain
  exit 0
fi

[ -n "${HV_SDK_HOME:-}" ] || hv_die "没找到鸿蒙 SDK（DEVECO_SDK_HOME / DevEco / 命令行工具都没有）" 2
[ -n "${HV_HVIGOR:-}" ] || hv_die "没找到 hvigorw" 2

# ---------------- 0. 版本号自增 + 编译时间注入 ----------------
#
# 每次打包 versionName 的 patch 位 +1、versionCode +1，并把「现在几点编的」写进
# entry/src/main/ets/common/BuildInfo.ets，设置页「关于 · 版本」那行在版本号下面
# 显示它。
#
# 什么时候不自增（否则会跟发版流程打架）：
#   · REL_VERSION 有值 —— CNB 发版页面已指定版本号，release-notes.sh 要求它与
#     app.json5 严格一致，这里再改就必然对不上；
#   · CNB 云端构建 —— 构建应当可由 git 复现，版本号由仓库决定（想强制自增设 HMY_BUMP=1）；
#   · HMY_NO_BUMP=1 —— 本地手动冻结。
#
# BuildInfo.ets 是编译期生成物：写 → 编译 → 还原，仓库里始终留着默认值，
# 不会因为打包而变脏（打包后 app.json5 会脏，那是版本号真升了，需要提交）。
APP_JSON="$ROOT/AppScope/app.json5"
BUILD_INFO_FILE="$ROOT/entry/src/main/ets/common/BuildInfo.ets"

_restore_build_info() {
  if [ -n "${BUILD_INFO_BAK:-}" ] && [ -f "${BUILD_INFO_BAK:-}" ]; then
    cp "$BUILD_INFO_BAK" "$BUILD_INFO_FILE" 2>/dev/null
    rm -f "$BUILD_INFO_BAK"
  fi
}
if [ -f "$BUILD_INFO_FILE" ]; then
  BUILD_INFO_BAK="$(mktemp "${TMPDIR:-/tmp}/buildinfo.XXXXXX" 2>/dev/null || true)"
  [ -n "${BUILD_INFO_BAK:-}" ] && cp "$BUILD_INFO_FILE" "$BUILD_INFO_BAK"
  trap _restore_build_info EXIT
fi

if [ "${HMY_NO_BUMP:-0}" = "1" ]; then
  hv_log "跳过版本号自增（HMY_NO_BUMP=1）"
elif [ -n "${REL_VERSION:-}" ]; then
  hv_log "跳过版本号自增（发版指定 REL_VERSION=$REL_VERSION）"
elif [ -n "${CNB_BUILD_WORKSPACE:-}" ] && [ "${HMY_BUMP:-0}" != "1" ]; then
  hv_log "跳过版本号自增（云端构建按 git 版本出包，要自增设 HMY_BUMP=1）"
else
  hv_bump_version "$APP_JSON" || hv_warn "版本号自增失败，沿用当前值"
fi

VER="$(hv_app_version "$APP_JSON")"; [ -n "$VER" ] || VER="0.0.0"
VCODE="$(hv_app_version_code "$APP_JSON")"; [ -n "$VCODE" ] || VCODE="0"
BUNDLE="$(hv_app_bundle "$APP_JSON")"; [ -n "$BUNDLE" ] || BUNDLE="unknown"
BUILT_AT="$(date '+%Y-%m-%d %H:%M:%S')"
if hv_write_build_info "$BUILD_INFO_FILE" "$VER" "$VCODE" "$BUILT_AT" "$BUILD_MODE"; then
  hv_ok "编译时间 $BUILT_AT → ${BUILD_INFO_FILE#$ROOT/}"
else
  hv_warn "写 BuildInfo.ets 失败，设置页将不显示编译时间"
fi

# ---------------- 1. 编译 ----------------
OUT_DIR="$ROOT/dist"
LOG_DIR="$OUT_DIR"
mkdir -p "$LOG_DIR"
BUILD_LOG="$LOG_DIR/hvigor.log"

hv_log "编译（product=$PRODUCT, buildMode=${BUILD_MODE}, version=${VER}/${VCODE}）…"
set +e
if [ -n "${CNB_BUILD_WORKSPACE:-}" ]; then
  # 云端把全量 hvigor 日志打到构建日志里，排障不用再翻文件
  "$HV_HVIGOR" --mode module -p "product=$PRODUCT" -p "buildMode=$BUILD_MODE" \
    assembleHap --no-daemon 2>&1 | tee "$BUILD_LOG"
  rc=${PIPESTATUS[0]}
else
  "$HV_HVIGOR" --mode module -p "product=$PRODUCT" -p "buildMode=$BUILD_MODE" \
    assembleHap --no-daemon > "$BUILD_LOG" 2>&1
  rc=$?
  [ -f "$BUILD_LOG" ] && tail -5 "$BUILD_LOG" | sed 's/^/    /'
fi
set -e
if [ $rc -ne 0 ] || [ ! -f "$BUILD_LOG" ] || ! grep -q "BUILD SUCCESSFUL" "$BUILD_LOG"; then
  echo
  echo "✗ 编译失败（日志：${BUILD_LOG#$ROOT/}）"
  [ -f "$BUILD_LOG" ] && grep -nE "ERROR|Error Message|error:|00303[0-9]{3}" "$BUILD_LOG" | head -20
  exit 3
fi
hv_ok "编译通过"
mkdir -p "$OUT_DIR"

# ---------------- 2. 找未签名包 ----------------
UNSIGNED="$ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"
if [ ! -f "$UNSIGNED" ]; then
  # 目录结构随 hvigor 版本有差异，兜底扫一遍
  UNSIGNED="$(find "$ROOT/entry/build" -name "*-unsigned.hap" -type f 2>/dev/null | head -1)"
fi
[ -n "$UNSIGNED" ] && [ -f "$UNSIGNED" ] || hv_die "编译成功但没找到未签名 hap（预期 entry/build/default/outputs/default/）" 5
hv_ok "未签名包：${UNSIGNED#$ROOT/}"

# VER / VCODE / BUNDLE 已在第 0 步读好（编译前），这里不再重复读——
# 重复读虽然值一样，但一旦哪天有人在编译过程里改了 app.json5，
# 就会出现「包内版本」与「文件名版本」不一致的诡异问题。

HAP_NAME="夜帧影视-$VER-$BUILD_MODE"
FINAL_HAP=""

# ---------------- 3. 签名（可选）----------------
if [ "$MODE" = "sign" ]; then
  SIGN_DIR="${SIGN_DIR:-$ROOT/.ci-sign}"
  mkdir -p "$SIGN_DIR"

  if [ -n "${HMY_P12_B64:-}" ] && [ -n "${HMY_CER_B64:-}" ] && [ -n "${HMY_P7B_B64:-}" ]; then
    hv_log "从环境变量解码签名材料 → ${SIGN_DIR#$ROOT/}"
    printf '%s' "$HMY_P12_B64" | base64 -d > "$SIGN_DIR/hongmengyingshi-debug.p12" 2>/dev/null
    printf '%s' "$HMY_CER_B64" | base64 -d > "$SIGN_DIR/hongmengyingshi-debug.cer" 2>/dev/null
    printf '%s' "$HMY_P7B_B64" | base64 -d > "$SIGN_DIR/hongmengyingshi-debug.p7b" 2>/dev/null
    chmod 600 "$SIGN_DIR"/*.p12 "$SIGN_DIR"/*.p7b 2>/dev/null
  elif [ ! -f "$SIGN_DIR/hongmengyingshi-debug.p7b" ] && [ ! -f "$SIGN_DIR"/*.p7b ] 2>/dev/null && [ -d "$HOME/.ohos/debug-key" ]; then
    SIGN_DIR="$HOME/.ohos/debug-key"
  fi

  # 自动寻找签名文件（支持多种命名约定）
  # 优先找标准命名 hongmengyingshi-debug.*，其次扫目录中任意 .p12/.cer/.p7b
  _find_sign_file() {
    local dir="$1" std="$2" ext="$3"
    if [ -f "$dir/$std" ]; then echo "$dir/$std"; return; fi
    find "$dir" -maxdepth 1 -name "*$ext" -type f 2>/dev/null | head -1
  }

  P12="$(_find_sign_file "$SIGN_DIR" "hongmengyingshi-debug.p12" ".p12")"
  CER="$(_find_sign_file "$SIGN_DIR" "hongmengyingshi-debug.cer" ".cer")"
  # .p7b 优先选调试类型（包含 debug 的文件名）
  P7B="$(_find_sign_file "$SIGN_DIR" "hongmengyingshi-debug.p7b" ".p7b")"
  if [ -z "$P7B" ] || [ ! -f "$P7B" ]; then
    P7B="$(find "$SIGN_DIR" -maxdepth 1 -name "*[Dd]ebug*.p7b" -type f 2>/dev/null | head -1)"
  fi
  ALIAS="${HMY_ALIAS:-debugkey}"
  PASS="${HMY_STOREPASS:-}"

  miss=""
  [ -f "$P12" ] || miss="$miss p12"
  [ -f "$CER" ] || miss="$miss cer"
  [ -f "$P7B" ] || miss="$miss p7b"
  [ -n "$PASS" ] || miss="$miss HMY_STOREPASS"
  [ -n "${HV_SIGN_JAR:-}" ] && [ -f "$HV_SIGN_JAR" ] || miss="$miss hap-sign-tool.jar"
  [ -n "${HV_JAVA:-}" ] || miss="$miss java"
  [ -z "$miss" ] || hv_die "签名材料不全：${miss}（CI 上检查 imports 是否生效，本地跑 scripts/build-tv.sh）" 4

  # Profile 自检：类型必须是 debug，包名必须对得上，否则白编一遍
  KIND="$(hv_profile_field "$P7B" '"type"')"
  PBUNDLE="$(hv_profile_field "$P7B" '"bundle-name"')"
  NOTAFTER="$(hv_profile_field "$P7B" '"not-after"')"
  [ "$KIND" = "debug" ] || hv_die "描述文件不是调试类型（type=${KIND}），装真机会报 9568322" 6
  [ "$PBUNDLE" = "$BUNDLE" ] || hv_die "描述文件包名 $PBUNDLE ≠ 工程 $BUNDLE" 6
  if [ -n "$NOTAFTER" ] && [ "$(date +%s)" -gt "$NOTAFTER" ]; then
    hv_die "描述文件已过期（截止 ${NOTAFTER}），回 AGC 重新签发" 6
  fi
  hv_ok "Profile 校验通过（bundle=$PBUNDLE, 设备白名单 $(hv_profile_devids "$P7B" | wc -w | tr -d ' ') 台）"

  FINAL_HAP="$OUT_DIR/$HAP_NAME-signed.hap"
  SIGN_LOG="$LOG_DIR/sign.log"
  hv_log "签名…"
  set +e
  "$HV_JAVA" -jar "$HV_SIGN_JAR" sign-app \
    -mode localSign \
    -keyAlias "$ALIAS" \
    -keyPwd "$PASS" \
    -keystoreFile "$P12" \
    -keystorePwd "$PASS" \
    -appCertFile "$CER" \
    -profileFile "$P7B" \
    -inFile "$UNSIGNED" \
    -outFile "$FINAL_HAP" \
    -signAlg SHA256withECDSA \
    -compatibleVersion 12 > "$SIGN_LOG" 2>&1
  rc=$?
  set -e
  if [ $rc -ne 0 ] || ! grep -q "sign-app success" "$SIGN_LOG" || [ ! -f "$FINAL_HAP" ]; then
    echo "✗ 签名失败："; tail -8 "$SIGN_LOG"
    exit 6
  fi
  hv_ok "已签名：${FINAL_HAP#$ROOT/}（$(hv_size "$FINAL_HAP")）"
else
  FINAL_HAP="$OUT_DIR/$HAP_NAME-unsigned.hap"
  cp "$UNSIGNED" "$FINAL_HAP"
fi

# ---------------- 4. 清单 ----------------
SHA="$(hv_sha256 "$FINAL_HAP")"
SIZE="$(hv_size "$FINAL_HAP")"
cat > "$OUT_DIR/build-info.txt" <<EOF
app=夜帧影视
bundle=$BUNDLE
version=$VER
version_code=$VCODE
build_mode=$BUILD_MODE
signed=$([ "$MODE" = sign ] && echo yes || echo no)
hap=${FINAL_HAP#$ROOT/}
size=$SIZE
sha256=$SHA
branch=${CNB_BRANCH:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')}
commit=${CNB_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo '-')}
built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
built_at_local=$BUILT_AT
toolkit=${HV_TOOLKIT}
EOF

echo
echo "================ 构建结果 ================"
sed 's/^/  /' "$OUT_DIR/build-info.txt"
echo "=========================================="
