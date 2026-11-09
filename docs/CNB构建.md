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

## 一、两个按钮

仓库页顶部「执行」下拉里有两条流水线，配置见 [`.cnb.yml`](../.cnb.yml)：

| 按钮 | 做什么 | 要不要密钥 |
|---|---|---|
| `compile` | 打印工具链解析结果 → 编译未签名 hap → 输出清单 | 不要 |
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

## 三、构建镜像

当前用的镜像是社区维护的鸿蒙命令行工具镜像：

```
docker.cnb.cool/mayflyee/examples/harmony-command-line-tools:latest
```

它由华为 **Command Line Tools**（Linux 版）打包而成，已包含 `hvigorw`、`ohpm`、SDK 与
`hap-sign-tool.jar`，开箱即用。`.cnb.yml` 里改这一处就能换镜像。

### 什么时候需要自建

镜像里的 SDK 版本比本机 DevEco 低时，编译会报：

```
00303312 Cannot find the corresponding SDK version
```

这时要么把镜像换新版，要么自建一个和本机对齐的：

```dockerfile
# .cnb/Dockerfile.harmony
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive TZ=Asia/Shanghai

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl wget unzip git ca-certificates openjdk-17-jdk \
    && rm -rf /var/lib/apt/lists/*

# 华为 Command Line Tools（Linux 版）需登录开发者账号下载，
# 下载后与本 Dockerfile 放同一目录，或用 ARG 传直链
ARG CLT_ZIP=command-line-tools-linux.zip
COPY ${CLT_ZIP} /tmp/clt.zip
RUN mkdir -p /opt/harmony && cd /opt/harmony \
    && unzip -q /tmp/clt.zip && rm /tmp/clt.zip

ENV COMMAND_LINE_TOOLS_HOME=/opt/harmony/command-line-tools
ENV PATH=${COMMAND_LINE_TOOLS_HOME}/bin:${COMMAND_LINE_TOOLS_HOME}/hvigor/bin:${PATH}
WORKDIR /workspace
```

推成自己的镜像（很轻，只跑一次）：

```bash
docker build -f .cnb/Dockerfile.harmony -t docker.cnb.cool/abber/harmony-tools:latest .
docker login -u cnb -p "<CNB_TOKEN>" docker.cnb.cool
docker push docker.cnb.cool/abber/harmony-tools:latest
```

然后把 `.cnb.yml` 的 `docker.image` 换成新地址即可 —— **脚本不用改**，工具链路径由
`scripts/lib/harmony-env.sh` 从 `COMMAND_LINE_TOOLS_HOME` / `HVIGOR_HOME` 自动推断。

---

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
| `00303312 Cannot find the corresponding SDK version` | 镜像 SDK 版本与工程要求不符 | 换镜像 / 自建镜像（第三节） |
| `The length of the storePassword or keyPassword field is less than 32` | 把明文口令写进了 `signingConfigs` | 别写 `signingConfigs`，走 `ci-build.sh` 补签 |
| `sign-app success` 没有、签名阶段失败 | `.ci-sign/` 没落地或口令错 | 看 `dist/sign.log`；本地 `--toolchain` 确认 `hap-sign-tool.jar` 找到 |
| `device is unauthorized` / `9568425` | 设备 UDID 不在 `.p7b` 白名单 | AGC 添加设备 → 重签 `.p7b` → 更新密钥仓库 |
| `9568322 not trusted app source` | 装的是上架用 `.app`（release 签名） | 真机自测要用 debug 签名的 `.hap` |
| 按钮点了没反应 / 没有 `build` 按钮 | `.cnb.yml` 里 `web_trigger_*` 没挂在 `$` 下 | 参考本仓库的 `.cnb.yml` 结构 |
| `pipeline` 起不来：镜像拉取失败 | 镜像仓库不可达 | 换镜像，或 `compile` 按钮先验证 |
