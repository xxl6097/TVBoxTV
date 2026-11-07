#!/usr/bin/env bash
# 【已废弃】旧的「编译 Release hap」脚本。
#
# 原因：它只调用 hvigor assembleHap，产物 entry-default-signed.hap 用的是
# build-profile.json5 里的调试证书（type=debug、带 device-ids），不能上架；
# 而且应用市场只收 .app（App Pack），不收 .hap。
#
# 现在统一走 build.sh → sign-release.sh，产物是发布证书签名的 .app 包。
# 保留本文件仅为了让旧习惯 / 旧文档调用不报错，两者等价：
#   ./scripts/build-release.sh   ==   ./scripts/build.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/build.sh" "$@"
