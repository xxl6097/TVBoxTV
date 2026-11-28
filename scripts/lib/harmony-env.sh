#!/usr/bin/env bash
# harmony-env.sh —— 鸿蒙工具链定位（本地 DevEco / CNB 命令行工具镜像 共用）
#
# 用法：在脚本里 `source "$(dirname "$0")/lib/harmony-env.sh"`，然后调用 hv_detect。
# 解析完成后可直接使用：
#   HV_TOOLKIT   工具链来源（deveco / clt / custom），仅用于日志
#   HV_SDK_HOME  DEVECO_SDK_HOME 应指向的目录（含 default 子目录）
#   HV_HVIGOR    hvigorw 可执行文件
#   HV_JAVA      java 可执行文件
#   HV_SIGN_JAR  hap-sign-tool.jar
#   HV_DEVECO    DevEco Studio 的 Contents 目录（本地才有，CI 为空）
#   HV_CLT       Command Line Tools 目录（CI 才有，本地为空）
#
# 之所以要抽出来：本地出包脚本原来把 /Applications/DevEco-Studio.app 写死，
# CI 里根本没有这个路径，两边逻辑一旦分叉就会「本地能出包、云端报错」。
set -o pipefail

hv_log() { printf '→ %s\n' "$*" >&2; }
hv_ok()  { printf '  ✓ %s\n' "$*" >&2; }
hv_warn(){ printf '  ! %s\n' "$*" >&2; }
hv_die() { printf '✗ %s\n' "$*" >&2; exit "${2:-1}"; }

# 取第一个存在的路径
hv_first() {
  local f
  for f in "$@"; do
    [ -n "$f" ] && [ -e "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

hv_command() { command -v "$1" 2>/dev/null; }

# 解析鸿蒙工具链，失败时 hv_die
hv_detect() {
  local root="${1:-$PWD}"

  # ---- DevEco Studio（本地）----
  if [ -z "${DEVECO_HOME:-}" ]; then
    DEVECO_HOME="$(hv_first \
      "/Applications/DevEco-Studio.app/Contents" \
      "$HOME/Applications/DevEco-Studio.app/Contents" \
      "/opt/deveco-studio/Contents" \
      "/opt/DevEco-Studio/Contents" \
      "/c/Program Files/Huawei/DevEco Studio" \
      "C:/Program Files/Huawei/DevEco Studio" || true)"
  fi
  HV_DEVECO="${DEVECO_HOME:-}"

  # ---- Command Line Tools（CI 镜像注入 COMMAND_LINE_TOOLS_HOME）----
  HV_CLT="${COMMAND_LINE_TOOLS_HOME:-}"
  if [ -z "$HV_CLT" ] && [ -n "${HVIGOR_HOME:-}" ]; then
    # 有些镜像只给 HVIGOR_HOME（<clt>/hvigor），反推回去
    HV_CLT="$(cd "$HVIGOR_HOME/.." 2>/dev/null && pwd || true)"
  fi

  # ---- SDK ----
  local sdk=""
  if [ -n "${DEVECO_SDK_HOME:-}" ] && [ -d "${DEVECO_SDK_HOME}/default" ]; then
    sdk="$DEVECO_SDK_HOME"
  elif [ -n "$HV_DEVECO" ] && [ -d "$HV_DEVECO/sdk/default" ]; then
    sdk="$HV_DEVECO/sdk"
  elif [ -n "$HV_CLT" ] && [ -d "$HV_CLT/sdk/default" ]; then
    sdk="$HV_CLT/sdk"
  fi
  HV_SDK_HOME="$sdk"

  # ---- hvigorw：工程自带 > DevEco > 命令行工具 > PATH ----
  HV_HVIGOR="$(hv_first \
    "$root/hvigorw" \
    "${HV_DEVECO:+$HV_DEVECO/tools/hvigor/bin/hvigorw}" \
    "${HV_CLT:+$HV_CLT/hvigor/bin/hvigorw}" \
    "${HV_CLT:+$HV_CLT/bin/hvigorw}" || true)"
  if [ -z "$HV_HVIGOR" ]; then
    HV_HVIGOR="$(hv_command hvigorw || true)"
  fi

  # ---- java：DevEco 自带 jbr > CLT 自带 > PATH ----
  HV_JAVA="$(hv_first \
    "${HV_DEVECO:+$HV_DEVECO/jbr/Contents/Home/bin/java}" \
    "${HV_DEVECO:+$HV_DEVECO/jbr/bin/java}" \
    "${HV_CLT:+$HV_CLT/tool/jbr/bin/java}" \
    "${HV_CLT:+$HV_CLT/jbr/bin/java}" \
    "${HV_CLT:+$HV_CLT/tool/node/../jbr/bin/java}" || true)"
  [ -z "$HV_JAVA" ] && HV_JAVA="$(hv_command java || true)"

  # ---- hap-sign-tool.jar：SDK toolchains 里 ----
  HV_SIGN_JAR=""
  if [ -n "$HV_SDK_HOME" ]; then
    HV_SIGN_JAR="$(hv_first \
      "$HV_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar" \
      "$HV_SDK_HOME/default/hms/toolchains/lib/hap-sign-tool.jar" || true)"
    if [ -z "$HV_SIGN_JAR" ]; then
      local cand
      for cand in "$HV_SDK_HOME"/*/openharmony/toolchains/lib/hap-sign-tool.jar \
                  "$HV_SDK_HOME"/*/hms/toolchains/lib/hap-sign-tool.jar; do
        [ -f "$cand" ] && { HV_SIGN_JAR="$cand"; break; }
      done
    fi
  fi

  # ---- Node（hvigorw 内部会用，PATH 里没有就补上）----
  local nodebin=""
  nodebin="$(hv_first "${HV_DEVECO:+$HV_DEVECO/tools/node/bin}" "${HV_CLT:+$HV_CLT/tool/node/bin}" || true)"
  [ -n "$nodebin" ] && case ":$PATH:" in *":$nodebin:"*) ;; *) PATH="$nodebin:$PATH" ;; esac
  export PATH

  if [ -n "$HV_DEVECO" ]; then
    HV_TOOLKIT="deveco"
  elif [ -n "$HV_CLT" ]; then
    HV_TOOLKIT="clt"
  elif [ -n "$HV_HVIGOR" ]; then
    HV_TOOLKIT="custom"
  else
    HV_TOOLKIT="none"
  fi

  # DEVECO_SDK_HOME 必须指到含 default 的那一层；指到 .../sdk/default
  # 会报 00303312「Cannot find the corresponding SDK version」
  [ -n "$HV_SDK_HOME" ] && export DEVECO_SDK_HOME="$HV_SDK_HOME"
  [ -n "$HV_CLT" ] && export COMMAND_LINE_TOOLS_HOME="$HV_CLT"
  return 0
}

# 打印工具链解析结果（CI 里第一件事就该看这个）
hv_print_toolchain() {
  printf '工具链来源 : %s\n' "${HV_TOOLKIT:-unknown}"
  printf 'DevEco     : %s\n' "${HV_DEVECO:-<无，CI 正常>}"
  printf '命令行工具 : %s\n' "${HV_CLT:-<无，本地正常>}"
  printf 'SDK        : %s\n' "${HV_SDK_HOME:-<未找到>}"
  printf 'hvigorw    : %s\n' "${HV_HVIGOR:-<未找到>}"
  printf 'java       : %s\n' "${HV_JAVA:-<未找到>}"
  printf '签名工具   : %s\n' "${HV_SIGN_JAR:-<未找到>}"
  if [ -n "${HV_HVIGOR:-}" ]; then
    printf 'node       : %s\n' "$(command -v node 2>/dev/null || echo '<未找到>')"
    printf 'hvigor 版本 : %s\n' "$("$HV_HVIGOR" -v 2>/dev/null | tr -d '\r' | head -1 || echo '<未知>')"
  fi
  printf 'ohpm       : %s\n' "$(command -v ohpm 2>/dev/null || echo '<未找到，无依赖工程可忽略>')"
}

# AppScope/app.json5 里的 versionName
hv_app_version() {
  local f="${1:-AppScope/app.json5}"
  sed -n 's/.*"versionName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1
}

# AppScope/app.json5 里的 versionCode
hv_app_version_code() {
  local f="${1:-AppScope/app.json5}"
  sed -n 's/.*"versionCode"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1
}

# AppScope/app.json5 里的 bundleName
hv_app_bundle() {
  local f="${1:-AppScope/app.json5}"
  sed -n 's/.*"bundleName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1
}

# 从 p7b（PKCS#7 DER，内部嵌了一段明文 JSON）里取字段
#   hv_profile_field <p7b> '"type"'
# 用 tr 把不可打印字节换成换行再 grep —— 不依赖 python / strings（CI 镜像里没有）
hv_profile_field() {
  LC_ALL=C tr -c '[:print:]' '\n' < "$1" 2>/dev/null \
    | grep -a -o "$2:[^,}]*" | head -1 | sed "s/^$2://" | tr -d '"'
}

hv_profile_devids() {
  LC_ALL=C tr -c '[:print:]' '\n' < "$1" 2>/dev/null \
    | grep -a -o '"device-ids":\[[^]]*\]' | head -1 | grep -o '[0-9A-F]\{64\}' | tr '\n' ' '
}

# 跨平台 sha256
hv_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# 人类可读大小
# 用文件字节数算，不用 du —— du 读的是磁盘占用，APFS 上刚 cp 出来的副本会
# 因为 clone/块对齐报得比原文件大（实测同一个 hap 一处 2.4M、一处 3.1M）。
hv_size() {
  [ -f "$1" ] || { echo "-"; return; }
  local bytes
  bytes="$(wc -c < "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$bytes" ] || { echo "-"; return; }
  awk -v b="$bytes" 'BEGIN {
    split("B K M G T", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%d%s\n", b, u[i]
    else printf "%.1f%s\n", b, u[i]
  }'
}

# ---------------------------------------------------------------------------
# 版本号自增 + 编译时间注入
#
# 需求：每次打包版本号都要往上走一格，并且包里能显示「这一版是什么时候编的」。
# 两者都在编译前一刻生成，避免出现「版本号是手改的、时间是上次的」这种对不上。
#
# 版本号规则：versionName 的最后一段 +1（1.1.0 → 1.1.1），versionCode 同步 +1。
# 想冻结版本（比如打与 tag 一致的包）设 HMY_NO_BUMP=1。
# ---------------------------------------------------------------------------

# 自增 AppScope/app.json5 里的 versionName(patch) 与 versionCode
#   hv_bump_version [app.json5]
hv_bump_version() {
  local f="${1:-AppScope/app.json5}"
  [ -f "$f" ] || return 1
  local ver code major rest minor patch newver newcode
  ver="$(hv_app_version "$f")"
  code="$(hv_app_version_code "$f")"
  [ -n "$ver" ] || return 1

  major="${ver%%.*}"
  rest="${ver#*.}"
  if [ "$rest" = "$ver" ]; then
    minor=0; patch=0
  else
    minor="${rest%%.*}"
    if [ "$minor" = "$rest" ]; then patch=0; else patch="${rest#*.}"; fi
  fi
  # 非数字（如 1.1.0-beta）就归零重来，别把版本号写成 NaN
  case "$patch" in ''|*[!0-9]*) patch=0 ;; esac
  case "$major" in ''|*[!0-9]*) major=1 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  newver="$major.$minor.$((patch + 1))"

  case "$code" in ''|*[!0-9]*) newcode=1 ;; *) newcode=$((code + 1)) ;; esac

  # 用临时文件改写：GNU 的 sed -i 与 BSD 的 sed -i '' 不兼容，走重定向最省事
  sed -e "s/\(\"versionName\"[[:space:]]*:[[:space:]]*\)\"[^\"]*\"/\1\"$newver\"/" \
      -e "s/\(\"versionCode\"[[:space:]]*:[[:space:]]*\)[0-9][0-9]*/\1$newcode/" \
      "$f" > "$f.hvbump" && mv "$f.hvbump" "$f" || return 1

  hv_log "版本号 $ver ($code) → $newver ($newcode)"
  return 0
}

# 写 BuildInfo.ets（编译前注入，编译后由调用方还原）
#   hv_write_build_info <目标文件> <versionName> <versionCode> <编译时间> <buildMode>
hv_write_build_info() {
  local f="$1" ver="${2:-0.0.0}" code="${3:-0}" at="${4:-}" mode="${5:-debug}"
  [ -n "$f" ] || return 1
  mkdir -p "$(dirname "$f")" || return 1
  cat > "$f" <<EOF
/**
 * 构建信息 —— 由 scripts/lib/harmony-env.sh 的 hv_write_build_info() 在编译前写入，
 * 编译结束后自动还原成仓库里的默认值。本文件是生成物，不要手改。
 */
export class BuildInfo {
  static readonly VERSION: string = '$ver';
  static readonly VERSION_CODE: number = $code;
  static readonly BUILT_AT: string = '$at';
  static readonly BUILD_MODE: string = '$mode';
}
EOF
}
