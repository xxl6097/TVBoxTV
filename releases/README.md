# 安装包

夜帧影视 HarmonyOS 安装包（HAP），debug 签名，手机 / 平板 / 电视通用。

> 当前只保留最新一版在仓库里，旧版本从下面的「历史版本」表格点链接下载；
> 链接地址里的 tag 换成对应版本号即可（早期版本仅在 Release 里）。

## 最新版

| 版本 | 文件 | 大小 | 编译时间 |
|---|---|---|---|
| v1.1.8 | [TVBoxTV-1.1.8-debug.hap](TVBoxTV-1.1.8-debug.hap) | 3.2 MB | 2026-11-28 13:48:29 |

sha256：`2eb79393cf70e90a8e33016b8739e6e216e1f609edd07bf906ba35516709ba16`

下载地址（直链）：

```
https://github.com/xxl6097/TVBoxTV/raw/main/releases/TVBoxTV-1.1.8-debug.hap
```

## 安装

手机 / 平板：

```bash
hdc install -r TVBoxTV-1.1.8-debug.hap
```

电视（局域网调试）：

```bash
hdc tconn 192.168.100.176:5555
hdc install -r TVBoxTV-1.1.8-debug.hap
```

如果设备上装过 versionCode 更高的老包，会报 `install version downgrade`，
加 `-d` 允许降级覆盖即可（不卸载、保留订阅源和播放记录）：

```bash
hdc install -r -d TVBoxTV-1.1.8-debug.hap
```

## 这一版改了什么

### 直播解码不匹配时自动换线
设备没有 H.265/HEVC 解码能力时（模拟器、部分机型），AVPlayer 报
`5400106 VID_DEC_ERR-video/hevc-unsupport`。过去这条错误被当成「频道失效」
直接跳到下一台，整组 H.265 的央视会连跳几台后停在错误页。现在先在同频道的
备用线路里找能解的编码，线路耗尽才换台；失败过的线路记进进程内黑名单，
下次进这个台直接从能解的线路起播。

### 直播优先选不带第三方水印的上游
咪咕转发会在画面右上角烧「CCTV. 咪咕视频」水印，那是编进画面的像素，
应用层去不掉，只能换上游。现在优先选央视频（ysp）的干净源，央视各台右上角
不再出现咪咕水印，分辨率同时从 720p 提到 1080p。干净源失败一次进入 5 分钟
冷却，期间退回原顺序。

### 版本号与编译时间
每次打包自动自增 versionName / versionCode；设置页「关于」在版本号下面显示
编译时间（如 `编译于 2026-11-28 13:48:29`），排查问题能直接确认构建批次。

### 修复
- 直播源地址里连续斜杠（`//uuxia/xxx`）被服务端 403，导致整组频道标灰
- 播放设置面板打开时，遮罩吃到同一次点击抬起导致面板立刻关闭（点击穿透）
- 安装早期高 versionCode 老包时报 `install version downgrade`

## 历史版本

| 版本 | 位置 |
|---|---|
| v1.1.0 | [Release v1.1.0](https://github.com/xxl6097/TVBoxTV/releases/tag/v1.1.0) |
| v0.x | 早期构建，未归档 |
