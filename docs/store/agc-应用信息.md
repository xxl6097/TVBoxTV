# AGC 应用信息（夜帧影视）

| 项 | 值 |
|---|---|
| 应用名称 | 夜帧影视 |
| 包名（Bundle Name） | `com.hong.tv` |
| APP ID / Client ID | `6917620734707118812` |
| Client Secret | 见项目根 `.agc-secret`（权限 600，不入库、不写进应用代码） |
| 开发者 | 夏小力（2074029209214267713） |
| 发布证书主体 | `CN=夏小力(2074029209214267713),Release` |
| Profile 类型 | release / app_gallery（无设备白名单） |

## 关于 Client Secret 的处理

`Client Secret` 是**服务端凭证**，用于换 access_token。它不能出现在客户端
（HAP 里的任何字符串都能被解包看到），也不能提交进代码仓库。本项目目前没有用到
账号登录、推送、支付等需要它的能力，所以只记录在本地文件里备用。

真要用到（比如接入华为账号登录），正确做法是：

```
手机/电视 App  →  你自己的后端  →  Huawei OAuth（带 client_secret）→ 返回用户 token
```

即让后端持有 secret，客户端只拿短期的临时凭证。

## 证书文件位置

```
/Users/uuxia/Desktop/work/code/huawei/
├── release.p12            私钥库（别名 release，口令 het002402）
├── release.cer            证书链：root + 中间 CA + 开发者证书
├── release.csr            当初申请证书用的 CSR
└── 夜帧影视Release.p7b     发布 Profile
```

> `release.p12` **必须备份**。它一旦丢失，这个包名就再也无法发布更新，
> 只能在 AGC 重新申请证书并重装（用户会丢数据）。
