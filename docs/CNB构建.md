# CNB 云端构建

本工程除了在本机用 DevEco Studio 出包，也能在 CNB（cnb.cool）上完整跑一遍：
**编译 → 调试签名 → 归档制品**。云端和本地共用同一份脚本，不存在两套逻辑。

| 项 | 本地（Mac + DevEco Studio 26） | 云端（CNB） |
|---|---|---|
| 工具链来源 | `/Applications/DevEco-Studio.app` | 命令行工具镜像（含 `hvigorw` / SDK / `hap-sign-tool.jar`） |
| 入口 | `scripts/build-tv.sh` | 仓库页「执行」→ `compile` / `build` 按钮 |
| 构建实现 | `scripts/ci-build.sh --mode sign` | 同一个 `scripts/ci-build.sh` |
| 签名材料 | `~/.ohos/debug-key/` | 私有密钥仓库 `abber/secrets`（`imports` 注入） |
| 产物 | `dist/*.hap` | 同上 + 推 `oci.cnb.cool` 制品库 |

---

## 一、三个按钮

仓库页顶部「执行」下拉里有两条流水线，配置见 [`.cnb.yml`](../.cnb.yml)：

| 按钮 | 做什么 | 要不要密钥 |
|---|---|---|
| `image` | 构建/重建构建镜像（API 26 命令行工具），升 SDK 时才点，约 14 分钟 | 不要 |
| `compile` | 打印工具链解析结果 → 编译未签名 hap → 输出清单，约 2 分钟 | 不要 |
| `build` | 上面全做，再补调试签名，最后把 hap 推到 OCI 制品库 | 要（密钥仓库） |

**换镜像、升 SDK 之后先用 `compile` 验证**，它不碰任何密钥，失败信息也最干净。

一次 `build` 的产物：

```
dist/夜帧影视-<版本>-debug-signed.hap
dist/hvigor.log
dist/sign.log
dist/build-info.txt      ← 扁平清单，供后续阶段/脚本消费
```

> 产物统一放 `dist/`，**不放 `build/`** —— `build/` 是 hvigor 自己的输出目录，
> 构建开始时会被清理（cloud 上表现为「日志文件刚写完就没了」）。

`dist/build-info.txt` 长这样（`key=value`，一行一个字段）：

```
app=夜帧影视
bundle=com.hong.tv
version=1.1.0
version_code=1000008
build_mode=debug
signed=yes
hap=dist/夜帧影视-1.1.0-debug-signed.hap
size=2.4M
sha256=e557011bf5fd3789d0387c1c5ec69a90de4d1526eec5d744ab4f9fbd50e1c19a
```

---

## 二、签名材料怎么进 CI

**仓库里不放任何证书。** 材料放在同组织的私有仓库 `abber/secrets`：

```
abber/secrets
└── envs/harmony-sign.yml     # 五个变量，p12/cer/p7b 走 base64
```

`.cnb.yml` 里那一行就是入口：

```yaml
imports: https://cnb.cool/abber/secrets/-/blob/main/envs/harmony-sign.yml
```

`imports` 把文件里的键值注入成环境变量，`scripts/ci-build.sh` 在 `--mode sign` 时解码落地到
`.ci-sign/`（权限 600），签完即可用，构建结束后容器销毁。

| 变量 | 内容 |
|---|---|
| `HMY_P12_B64` | 私钥库 `.p12` 的 base64 |
| `HMY_CER_B64` | 叶子证书 `.cer` 的 base64 |
| `HMY_P7B_B64` | 调试描述文件 `.p7b` 的 base64 |
| `HMY_STOREPASS` | 密钥库口令（`storePassword` = `keyPassword`） |
| `HMY_ALIAS` | 密钥别名，默认 `debugkey` |

### 换证书 / 换设备时怎么更新

证书有效期到 **2027-11-03**；设备白名单变了（换电视、换手机）必须回 AGC 重新签发 `.p7b`，
然后更新密钥仓库：

```bash
# 1. 把新证书放回 ~/.ohos/debug-key/，然后重新生成密钥仓库文件
cd /tmp && rm -rf secrets && git clone https://cnb.cool/abber/secrets.git && cd secrets
D=~/.ohos/debug-key
cat > envs/harmony-sign.yml <<EOF
HMY_P12_B64: "$(base64 -i $D/hongmengyingshi-debug.p12 | tr -d '\n')"
HMY_CER_B64: "$(base64 -i $D/hongmengyingshi-debug.cer | tr -d '\n')"
HMY_P7B_B64: "$(base64 -i $D/hongmengyingshi-debug.p7b | tr -d '\n')"
HMY_STOREPASS: "你的口令"
HMY_ALIAS: "debugkey"
EOF

# 2. 提交
git commit -am "更新调试签名材料" && git push
```

> `base64 -w0` 是 Linux 写法，macOS 用 `base64 -i 文件 | tr -d '\n'`。
> 单个变量上限 100KB，当前 p7b 只占 5.8KB，够用很久。

### 为什么签名不在 `build-profile.json5` 里

hvigor 的 `signingConfigs` 只认 DevEco 图形界面加密过的口令密文（长度 ≥ 32），写明文直接被拒：

```
The length of the storePassword or keyPassword field is less than 32
```

所以两边都是「hvigor 出未签名 hap → `hap-sign-tool.jar` 用明文口令补签」。
这条链路唯一依赖 `hap-sign-tool.jar` 在 SDK 的 `toolchains/lib/` 下，DevEco 与命令行工具镜像里都有。

---

## 三、构建镜像（自建，API 26）

流水线用的镜像是本仓库自己构建的：

```
docker.cnb.cool/abber/harmonytv:harmony-26
```

### 为什么不用现成的社区镜像

社区有个现成的鸿蒙命令行镜像，但它的 SDK 是 **API 21（HarmonyOS 6.0.1）**，
本工程目标 **API 26（DevEco Studio 26 / HarmonyOS 26.0.0）**，差一代工具链，实测两个报错：

| 报错 | 真实原因 |
|---|---|
| `10705000 Syntax Error: ',' expected [LivePage.ts:1418:29]` + `Failed to execute es2abc` | 旧版 es2abc 解析不了新编译器产出的中间代码 |
| `"@ohos.multimedia.soundPool" is imported by "Feedback.ets", but could not be resolved` | 旧 SDK 的 API 面里没有该模块 |

**源码没错，是工具链版本不够。** 所以镜像必须自建，且与本机 DevEco 同一代。

### 镜像怎么来的

见 [`.cnb/Dockerfile.harmony`](../.cnb/Dockerfile.harmony)，两步：

1. ubuntu:22.04 + `openjdk-17`（`hap-sign-tool.jar` 要用）+ `libgl1` 等系统库
2. 下载 Huawei **Command Line Tools 26（Linux）** 并解压到 `/opt/harmony/command-line-tools`

CLT 官方下载要登录华为开发者账号，所以这里用 GitHub 上的镜像仓库
[`ErBWs/ohos-sdk`](https://github.com/ErBWs/ohos-sdk)（原样搬运官方包，含 `.sha256` 校验）。
包是分卷的，`Dockerfile` 里 `.aa` + `.ab` 拼回完整 tar.gz 再校验解压，共约 2.2GB。

> **构建一次约 14 分钟**（下载 2.2GB + 解压 + 推镜像）。只有升 SDK / 换工具链才需要重建。

### 构建 / 重建镜像

仓库页「执行」→ **image**（`.cnb.yml` 里的 `web_trigger_image`）：

```bash
# 它做的事，等价的本地命令：
docker build -f .cnb/Dockerfile.harmony \
  -t docker.cnb.cool/abber/harmonytv:harmony-26 .
docker push docker.cnb.cool/abber/harmonytv:harmony-26
```

### 升 SDK 怎么办

`Dockerfile.harmony` 里 `ARG OHOS_SDK_TAG` 默认 `latest`（跟随最新的 API 26 版）。
要钉死某个版本：

```dockerfile
ARG OHOS_SDK_TAG=26.0.0.821
```

改完重新点一次 **image** 按钮，再点 **compile** 验证，最后 **build** 出包。

### 换镜像

`.cnb.yml` 里两处 `docker.image`（`web_trigger_compile` 的锚点）改一处即可，
`web_trigger_build` 引用同一锚点。工具链路径由 `scripts/lib/harmony-env.sh` 从
`COMMAND_LINE_TOOLS_HOME` 自动推断，**脚本一行都不用改**。

## 四、取回制品

`build` 按钮跑完后，hap 会以通用 OCI 制品形式归档（`allowFailure` 打开，归档失败不影响出包）：

```bash
# 版本号标签（1.1.0-<commit 短哈希>）与 latest 双标签
oras pull oci.cnb.cool/abber/harmonytv/yezhen-tv:latest

# 装到设备
hdc install -r 夜帧影视-1.1.0-debug-signed.hap
```

> 制品路径取自 `${CNB_OCI_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}/yezhen-tv`，仓库名会被转小写。

制品也能在仓库页「制品」→ OCI 里直接下载。

---

## 五、本地复现 CI 行为

CI 出问题时的标准动作：**在本地跑同一条命令**，两边结果应该一致。

```bash
./scripts/ci-build.sh --toolchain              # 工具链解析结果（排查环境问题先看这个）
./scripts/ci-build.sh --mode compile           # 只编译
./scripts/ci-build.sh --mode sign              # 编译 + 签名（读 $HMY_* 或 ~/.ohos/debug-key）

./scripts/build-tv.sh                          # = --mode sign + 提示装包命令
./scripts/build-tv.sh --install 192.168.1.207:33609   # 构建 + 装到手机
```

`scripts/ci-build.sh` 的退出码是稳定的，脚本里可以直接判断：

| 退出码 | 含义 |
|---|---|
| 0 | 成功 |
| 2 | 工具链不全（SDK / hvigorw 没找到） |
| 3 | 编译失败 |
| 4 | 签名材料缺失（口令或证书不全） |
| 5 | 编译成功但没找到未签名 hap |
| 6 | 签名失败 / Profile 校验不过（类型、包名、有效期） |

---

## 六、常见报错

| 现象 | 原因 | 处理 |
|---|---|---|
| `00303312 Cannot find the corresponding SDK version` | 镜像 SDK 版本与工程要求不符 | 重建镜像 / 换 `OHOS_SDK_TAG`（第三节） |
| `11201001 Dependency Error` + `libGL.so.1: cannot open shared object file` | 镜像缺系统库（资源编译的 image_transcoder 依赖 libGL） | 镜像里已补 `libgl1 libglu1-mesa libfreetype6 libgbm1` |
| `Failed to execute es2abc` / `10705000 Syntax Error` | 工具链版本低于源码要求（社区镜像 API 21 vs 工程 API 26） | 用自建 harmony-26 镜像 |
| `"@ohos.multimedia.soundPool" could not be resolved` | 同上，旧 SDK 没有该模块 | 同上 |
| `The length of the storePassword or keyPassword field is less than 32` | 把明文口令写进了 `signingConfigs` | 别写 `signingConfigs`，走 `ci-build.sh` 补签 |
| `sign-app success` 没有、签名阶段失败 | `.ci-sign/` 没落地或口令错 | 看 `dist/sign.log`；本地 `--toolchain` 确认 `hap-sign-tool.jar` 找到 |
| `device is unauthorized` / `9568425` | 设备 UDID 不在 `.p7b` 白名单 | AGC 添加设备 → 重签 `.p7b` → 更新密钥仓库 |
| `9568322 not trusted app source` | 装的是上架用 `.app`（release 签名） | 真机自测要用 debug 签名的 `.hap` |
| 按钮点了没反应 / 没有 `build` 按钮 | `.cnb.yml` 里 `web_trigger_*` 没挂在 `$` 下 | 参考本仓库的 `.cnb.yml` 结构 |
| `pipeline` 起不来：镜像拉取失败 | 镜像仓库不可达 | 换镜像，或 `compile` 按钮先验证 |
