#!/usr/bin/env bash
# 编译出可安装、可提审的 HAP。用法：./scripts/build.sh
#
# 包名已改为 com.hong.tv，DevEco 里那份**调试**证书的 Profile 绑的是旧包名
# （com.fanren.zspacetv），拿它签会被 hvigor 直接拒掉，所以本地构建统一走
# AGC 的**发布**证书。注意 release 包**不能** hdc install（实测报
# 9568322 not trusted app source，因为 profile 的 app-distribution-type
# 是 app_gallery），自测请用 debug 包；release 包的校验方式是 verify-app。
#
# 具体流程（未签名编译 → hap-sign-tool 签名 → 校验）在 sign-release.sh 里，
# 这里只是入口，保持 `./scripts/build.sh` 这个老习惯不变。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/sign-release.sh" "$@"
