# 夜帧影视 —— 原生鸿蒙（ArkTS）电视端影视客户端

**夜帧影视** 是面向 **HarmonyOS 大屏**重写的 TVBox 类播放器：纯 ArkTS + ArkUI 实现，不依赖
Android 运行时、不带任何 WebView 套壳，直接跑在鸿蒙原生渲染管线上。

已实测运行环境：**HarmonyOS 7.0.0 / API 26**，设备 **HUAWEI 智慧屏（EDIS-760E）**
与 **Pura X View（VOL-AL00 折叠屏）**，横屏 2232×1320 与 1920×1080 两种分辨率均验证通过。

## 鸿蒙适配要点

| 适配项 | 做法 |
|---|---|
| UI 框架 | ArkUI 声明式开发（`@Entry` / `@Component` / `@Builder`），无 XML 布局、无 Android View |
| 语言 | ArkTS（TypeScript 强约束子集），全量静态类型，`@State` 驱动刷新 |
| 播放 | `@ohos.multimedia.media` AVPlayer + `XComponent` 硬解 Surface，走系统解码器（HLS/H.264/H.265/TS） |
| 切后台停播 | 直播页隐藏即 `release()`（HLS 直播 `pause` 停不干净），并注册 `PlayGuard` 由 `Ability.onBackground` 兜底，避免「退出后还在出声」 |
| 网络 | `@ohos.net.http`，多站源并发分批调度，单站失败隔离 |
| 存储 | `@ohos.data.preferences` 持久化配置、收藏、历史、直播源 |
| 窗口 | `setWindowLayoutFullScreen(true)` + 隐藏系统栏 + `setWindowKeepScreenOn(true)`，全屏沉浸 |
| 屏幕方向 | `module.json5` 声明 `orientation: landscape`，锁定横屏 |
| 遥控器 | 适配华为**灵犀遥控器**的「指针 + 确定」模式：全应用 `onHover` 悬停高亮、`onClick` 接确定键，不依赖方向键焦点链 |
| 分辨率 | 全部尺寸用 vp/百分比 + 自适应网格，同一套代码适配 1080p 电视与 2K 折叠屏 |
| 权限 | 仅 `ohos.permission.INTERNET`，无存储/位置等敏感权限 |

技术栈：**ArkTS · ArkUI · AVPlayer · XComponent · Preferences · Router**，构建工具 hvigor + DevEco Studio 26。

> **它不含任何影片内容。** 应用本身只有界面、协议实现、播放器。看什么完全取决于你导入的 TVBox 配置（JSON）。

---

## 〇、界面按 FongMi/TV 一比一还原

界面不是"参考"，是照着 `FongMi/TV` 的 `app/src/leanback/res` 逐个文件核对出来的。

**主题与配色**（`values/colors.xml` + `leanback/res/values/styles.xml`）：

| 项 | 原版取值 | 本项目 |
|---|---|---|
| 主题基类 | `Theme.Material3.Dark.NoActionBar` | 自定义 `T` 常量类，逐项同值 |
| 主色 `colorPrimary` | **`@color/white`（纯白，不是 M3 默认紫 `#D0BCFF`）** | `T.PRIMARY = #FFFFFF` |
| 选中/勾选文字 | `color/text.xml` → `yellow_500` | `T.SELECTED = #FFEB3B` |
| 窗口背景 | `splash_background` = `#141218` | 同值（含启动页 `start_window_background`） |
| 面板底色 | `colorSurface` = `#1C1B1F` | `T.SURFACE`，用于播放器控制面板 |
| 半透明层级 | `black_20/40/50/70/80/90`、`white_15/30/70/80` | 同值直接用，交给系统混合 |

**控件样式**（`leanback/res/drawable/shape_*.xml`）：

| 控件 | 原版文件 | 原版取值 | 本项目 |
|---|---|---|---|
| 功能块 | `adapter_func` + `selector_item` | 100dp×100dp，图标 36dp + 18sp；常态 `black_20` 底 / 焦点 `black_40` + 1.5dp 白描边，**4dp 圆角** | 同上（图标换成同尺寸 SVG） |
| 分类胶囊 | `adapter_type` + `selector_item_round` | **28dp 胶囊**，8dp/14dp 内边距，选中文字转黄 | 同上 |
| 线路 / 剧集 | `adapter_flag` / `adapter_episode` | `selector_item`，4dp 圆角，16sp | 同上 |
| 通用按钮 | `selector_chip` + `styles.xml#Control` | 4dp 圆角、12dp 横内边距、14sp | 播放器控制按钮 |
| 大按钮 | `selector_button` + `shape_button_normal` | **28dp 胶囊 + 1dp `white_30` 描边** | 搜索等主操作 |
| 卡片描边 | `selector_vod` + `shape_vod_focused` | 1.5dp 白描边 + 8dp 圆角 | 2px 白描边（取整防亚像素虚边） |
| 卡片图片 | `Vod.Grid` | 只上左/上右 8dp 圆角 | 同上 |
| 名称条 | `shape_vod_name` | `black_20` 底 + 只留底部圆角 + 16sp 居中 + 6dp 内边距 | 同上 |
| 角标 | `shape_vod_remark` | `bg_remark`(`#177535` @70%) + 仅右侧 4dp 圆角 + 4dp 内边距 | 同上 |
| 焦点缩放 | `CustomRowPresenter` → `FocusHighlight.ZOOM_FACTOR_SMALL` | **1.1×**（原版是缩放而非不放大） | 同上 |
| 播放器面板 | `shape_controller` + `view_control_vod` | `colorSurface` + 上左/上右 **28dp 圆角**，padding 24/24/16 | 同上（原先的黑色渐变换掉） |
| 行标题 | `adapter_header` | 24sp 白字 | 同上 |
| 行间距 | `setVerticalSpacing` / `CustomRowPresenter(16)` | **16dp**（行内、行间都是） | 同上 |
| 顶栏 | `activity_home` | logo 48dp + 标题 24sp + 时钟 24sp，padding 24/24/8 | 同上 |
| 内容边距 | `fragment_type` / 网格 | padding 24dp（top 8~16dp） | 同上 |

> 两处必须记住的坑：① `colorPrimary` 是**白色**，凡是"白底按钮"文字必须用深色（`T.BG`），否则白底白字；② 选中态是**黄字**，不是换底色。

页面结构也照原版拆：

```
Home          activity_home        顶栏 + 功能行（6 块）+ 继续观看行 + 最近更新行
VodPage       fragment_vod/type    返回 + 站点名 + 分类胶囊行 + 6 列海报网格 + 换站/筛选
Detail        activity_vod         海报 + 元信息 + 简介展开 + 线路 + 剧集 6 列
LivePage      activity_live        左分组 + 右频道网格
CollectPage   activity_collect     6 列网格 + 卡片角标删除
HistoryPage   activity_history     adpater_vod_list 横条卡
SettingPage   activity_setting     配置 / 定时更新 / 直播源 / 站源管理
```

> 原版 TV 版**没有左侧导航栏**——它是「顶栏 + Leanback 行」结构，功能入口是首页第一行的 6 个方块。本项目照此实现，不要按手机版的底部 3 tab 理解。

---

## 一、先说清楚两个上游仓库是什么

你给的两个地址性质完全不同，这决定了技术路线：

| 仓库 | 实质 | 能不能直接用 |
|---|---|---|
| `zqc11608/box` | **不是应用源码**，是 TVBox 的「站源规则」数据包：`m.json`（280 个站点）、`dm.txt`、`sub/`、`vod/` | 是**数据**，本项目直接消费它 |
| `FongMi/TV` | 影视 TV 的**安卓应用源码**（Java + Kotlin + Gradle） | 是**安卓 APK**，鸿蒙装不了 |

FongMi/TV 里最关键的三个模块，在鸿蒙上都不存在：

| 模块 | 作用 | 鸿蒙现状 |
|---|---|---|
| `catvod` 的 `DexClassLoader` | 加载 `2212.jar`，跑 218 个 `csp_xxx` Java 爬虫 | 无 JVM / 无 DEX 类加载器 |
| `quickjs` | 跑 JS 爬虫 | 系统不提供应用内 JS 引擎 |
| `chaquo` | 跑 Python 爬虫 | 无 CPython 运行时 |

所以 **"把 FongMi 转译成鸿蒙" 这条路在原理上不存在**，只能按鸿蒙的能力重写一个客户端——也就是本项目做的事。

## 二、协议支持矩阵（重要，决定了 280 个站点里能用几个）

`m.json` 里 280 个站点按 TVBox 的 `type` 字段分：

```
type 3  csp_/jar 爬虫      220 个   ← 需要 Java/JS 运行时，鸿蒙无法执行
type 1  JSON 采集接口       45 个   ← 纯 HTTP，已完整实现
type 4  多层 data 的 JSON   10 个   ← 同上，实现里做了 data 拆包
type 0  XML 采集接口         5 个   ← 已完整实现（含 CDATA）
                          ─────
                          280
```

**本机实际可运行 60 个站源（约 21%）**，其中 `parses` 解析接口可用 34 个。

这不是"没做完"，是能力边界：那 220 个站点背后是 Java 字节码，换任何非安卓系统都一样跑不了。应用里对这些站点会明确标注 **「需爬虫运行时」** 并默认不启用，不会给你一个假装能用的空壳。

## 三、功能

| 模块 | 实现 |
|---|---|
| 配置导入 | URL 下载 / 直接粘贴 JSON；容错 `//` 注释行、BOM、CRLF、保留字 `"class"` |
| 订阅 | 一个订阅链接同时下发点播站源（sites）+ 直播源（lives）：填一次链接，点播和直播一起更新；订阅里的直播源可在设置页逐个测速切换，未配直播源时自动选用第一个 |
| 站源管理 | 逐个开关；不可用站点标注原因；默认只启用协议型；**换订阅后已启用集合同新列表自动对齐**（保留交集，交集为空则回到默认全开），不会出现「订阅成功了但一个站都没有」；「全部启用」常驻，不需要先测速 |
| 分类浏览 | 分类栏 + 海报网格 + 翻页；站点不给分类时自动从条目反推并补「全部」；翻页结果按 `siteKey+id` 去重（采集站翻页重叠 / 越界页夹回时不会重复丢项）；翻页失败在列表底部给一条可点的重试，不占用首屏错误态 |
| 详情 | 海报/年份/地区/主演/简介；多线路切换；剧集网格 |
| 全局搜索 | 最多 18 个站源分批并发（每批 6），单站失败不影响整体 |
| 播放 | AVPlayer + XComponent 硬解；底部控制条（上/下一集、±10 秒、播放暂停、音量、静音）全部可点；进度条可点击定位（指针设备也可点）。**支持 0.5–2.0 倍速**（全局偏好，追完整剧不用每集重设）与**内嵌字幕轨切换**（HLS 的 WEBVTT/TTML，面板里列出可选项，没有字幕轨时明确提示）；起播前画质探测有 1.5 秒预算，源站慢也不会卡在 loading 上十几秒。切画质会**带着当前进度重建**（点同一档不重载）；播放出错或 `play/pause` 状态异常时释放播放器并停在错误页，点「重试」从干净状态重建；surface 被系统重建（切后台回来）时自动放掉旧播放器重连，不会「有声无图」 |
| 播放地址解析 | `parses` 里 type=1 的 JSON 解析接口，前 8 个**并发**试（编码优先，命中即返回），最坏耗时从 96 秒降到约 9 秒 |
| 历史 / 收藏 | 本地持久化，记录看到第几集与进度；历史按最后观看时间倒序（重看老片会浮到最前）；收藏取消要二次确认，且用「只删不加」语义（列表过期时不会反而把条目加回来） |
| 灵犀遥控器 | 光标 + 点击模式：**全应用所有可点热区同时挂 `onClick` + `onMouse`**（按 key 做 400ms 去重，指针与触屏谁先到都只执行一次；按下到抬起位移 >12vp 视为拖动不触发点击，滑动列表不会误进详情）。覆盖首页卡片、点播网格与筛选、详情剧集、设置所有行、搜索、历史、收藏、直连、直播频道、播放页 17 个热区与进度条 |
| 定时抓取 | 每 6 小时自动跑一轮：刷新远程配置 + 抓各站最新影片 + 探测站源存活；首页「最近更新」展示，设置页可手动触发。**一轮全空（断网/站源集体失效）时保留上一轮数据**，只把下次尝试提前到 10 分钟后，不会把首页清空还锁住 6 小时 |
| 交互细节 | 封面统一走 `Poster` 组件：加载中显示骨架占位、加载失败退到骨架而不是留一块纯黑；卡片悬停微放大 + 140ms 缓动（高亮边框常驻 2px、只换颜色，避免 hover 时卡片抖动）；站源列表骨架屏；简介展开/收起；剧集正序/倒序切换 + 已看剧集标记；搜索历史一键重搜；播放出错就地重试；指针滑过进度条预览时间点；站源列表底部翻页 |


### 交互与反馈

| 场景 | 行为 |
|---|---|
| 进度条 | 可**点击定位**，也可**按住拖动**（PanGesture）；拖动时中央显示目标时间，松手提示「已定位到 xx:xx」 |
| 播放 / 暂停 | 点画面切换，屏幕正中闪一个大 ▶ / ❚❚（3 米外也看得清） |
| 音量 / 静音 | 右上角音量条 + 状态自动收起 |
| 收藏 | 详情页点收藏，底部弹「已加入收藏 / 已取消收藏」；收藏页取消要再点一次确认 |
| 倍速 | 播放设置面板里 0.5x–2.0x 六档，选完整部剧都按这个速度播 |
| 字幕 | 源里带字幕轨时，播放设置面板列出可选轨（按轨道名/语言码），可一键关闭 |
| 清空历史 | **二次确认**：第一次提示「再点一次确认（共 N 条）」，按钮同时变红写「确认清空？」，6 秒内再点才真清 |
| 设置页保存 / 导入 / 更新 | 底部胶囊提示（页面内文字滚动后会看不见，所以补了全局提示） |
| 点画面 | 控制条收着时**第一下只唤出控制条**（不暂停），再点才播放/暂停；指针停在控制条上不自动收起（超时 12 秒） |
| 接口缓存 | 分类表 5 分钟 / 列表 90 秒 / 详情 10 分钟，切回看过的分类**瞬间**返回；点播页有「刷新」按钮强制拉最新 |
| 网络状态 | 系统层监听出网能力（`NET_CAPABILITY_VALIDATED` 优先）：断网/恢复各提示一次，避免首页、直播、搜索同时报错；请求失败时错误文案直接说「当前没有网络连接」，而不是让人以为对方站点挂了 |
| 父分类 | 「电视剧」「电影」这类父分类在采集站里往往没有直属影片，程序自动汇总子分类内容并注明，不再显示空列表 |
| 观看定位 | 详情页自动滚到「上次看到」那一集；从播放页返回时集数与高亮会立刻更新 |
| 列表滚动 | 直播频道网格、点播网格、搜索结果横滑、搜索历史、设置页、换站抽屉均可拖动滚动 |
| 搜索 | 发起搜索时自动收起软键盘并让输入框失焦，避免键盘与「粘贴/全选」菜单盖住结果 |
| 直播源 | 通过「订阅」一键导入（一份订阅同时带点播站源+直播源）；首次进直播页自动选用订阅下发的第一个源并提示可更换 |
| 直播源测速 | 直播页「测速」批量检测订阅下发的直播源：拉列表计时 + 抽样抓流首包算可播率，按「可播率 70% + 速度 30%」评分排行，可直接切换；面板逐条回填，测速中不误关 |
| 频道可用性 | 直播页「检测」对当前分组逐个探活（上限 40 台），失效台标灰加删除线；换源或刷新后自动清除标记 |
| 频道收藏 | 目录树置顶「★ 我的收藏」（带台数）。**长按**任意频道卡片收藏/取消（遥控按住确定键同样有效），已收藏的台右上角带 ★；收藏按时间倒序，存的是台名+地址+分组，换源后同名台仍在。点「我的收藏」只看收藏台，可在其中再搜索 |
| 频道搜索 | 顶栏「搜索」展开输入框（手机端默认常驻），按台名实时过滤，命中数显示在面包屑「· 搜到 N 台」；与「我的收藏」可叠加过滤；清除按钮一键复位 |
| 下拉刷新 | 直播频道网格 / 点播影片网格 / 搜索结果三处下拉即刷新。直播顺带清掉上一轮的失效标记；点播会先清接口缓存再重拉（否则下拉拿到的是 90 秒内的旧响应，看着像没反应）。电视端仍用顶栏「刷新」（遥控器没有这个手势） |
| 详情页 | 整页一个纵向滚动：简介展开后照样能滚；剧集整宽 8 列，超过 4 行时网格自己滚、到边界再把手势交给整页 |
| 画质 | 控制条点「画质」弹出**居中浮层**（不挤压控制条），档位按真实高度命名（184P/288P/480P…），单档源不显示档位 |
| 测速 | 点了立刻提示「开始测速 N 个源，约 30 秒」并自动展开列表，能看见每行的「测试中…」 |
| 设置页 | 参照 tvOS：分组卡片 + 一行一项，右侧固定「当前值 + ›」；焦点整行变亮并出现左侧白竖条；操作行统一带箭头、纯展示行不带，能点与不能点一眼分开 |
| 首页轨道 | 参照 tvOS 海报墙：海报即卡片（圆角+投影），悬停放大 1.06 并浮起；文字浮在海报下方不加底色块；区块标题带条目数 + 「全部 ›」；继续观看在海报底部压一条真实观看进度；最近更新的更新状态改成右上角角标 |

### 关于遥控器

夜帧影视 的灵犀遥控器在系统里是**指针设备**：方向键是移动光标，确定键是鼠标左键点击，
`onKeyEvent` 收不到任何按键。所以整个应用的交互都按「光标 + 点击」设计——
每个可点元素都有 `onHover` 悬停高亮，播放页所有操作都是可点的按钮。

两条硬性约束（都踩过，详见 `docs/安装与排错.md` 第三节）：

- **`ForEach` 的 key 里绝不能放悬停态**。悬停 → key 变 → 项重建 → 新节点又触发悬停，
  静置时每秒重建 6 次，按下去的那一下永远落在已销毁的节点上，表现为「指着某个台点下去毫无反应」。
- **热区要盖满整格**。`onClick` 挂在小号 `Text` 上时，卡片的空白区点了没反应；
  指针遥控对不准文字就是这个效果。

自定义组件 `common/Pointer.ets` 提供指针遥控的点击识别（按下+抬起都在本元素才算一次，
400ms 时间窗去重，避免 `onClick` 与 `onMouse` 双触发叠出两层页面）。

细节见 `docs/安装与排错.md` 第三节。

## 四、编译与安装

> 包名已改为 `com.hong.tv`。本地构建也走 AGC 发布证书（`./scripts/build.sh` →
> `scripts/sign-release.sh`），产物与提审用的是同一份，实测可直接 `hdc install`。
>
> 缓存的命中情况可以看日志（便于判断「慢」是网络还是程序）：
> `hdc shell hilog -x -T BOXN | grep cache` → `cache HIT` / `cache MISS ... 480 ms`。

```bash
./scripts/ci-build.sh --toolchain       # 只打印工具链解析结果（排环境问题先看这个）
./scripts/ci-build.sh --mode compile    # 只编译，与 CNB 的 compile 按钮同一条命令
./scripts/ci-build.sh --mode sign       # 编译 + 补签，与 CNB 的 build 按钮同一条命令
./scripts/build.sh                      # 编译（DevEco 26 内置 hvigor + API 26 SDK）
./scripts/build-tv.sh                   # 编译 + 用调试证书补签（电视真机联调用）
./scripts/build-tv.sh --install 192.168.100.176:5555   # 编译 → 签名 → 装机，一条命令
./scripts/install.sh                    # 安装到默认设备并启动
./scripts/install.sh 192.168.1.207:33609  # 指定设备（IP:端口）
./scripts/hdcx.sh shell "bm get -u"     # 单条命令里完成重连+执行，读设备信息
```

> `build-tv.sh` 解决的是命令行构建的两个坑：
> **① `DEVECO_SDK_HOME` 要指到 `.../DevEco-Studio.app/Contents/sdk`**（含 `default`
> 子目录的父级）；指到 `sdk/default` 会报 `00303312 SDK component missing`，不设又会报
> `00303217 Configuration Error`。
> **② hvigor 的 `signingConfigs` 只吃 DevEco 加密后的口令（长度 ≥ 32）**，明文口令写进去
> 直接构建失败，所以签名这步由脚本用 `hap-sign-tool.jar` 补做。
> 调试凭证在 `~/.ohos/debug-key/hongmengyingshi-debug.{p12,cer,p7b}`，描述文件里白名单
> 了手机与电视两台设备（有效期 2026-11-03 → 2027-11-03）。

> **无线调试会话很短**：`hdc tconn` 建好后隔一次 shell 调用就可能失效，报
> `Not match target founded, check connect-key`。所有设备操作都走 `scripts/hdcx.sh`，
> 它在一条命令里完成 `kill → start → tconn → 执行`。

**换设备后必须重新签名**：调试描述文件（`.p7b`）里白名单了具体设备的 UDID，换一台机器安装会报
`9568423 the device is unauthorized`。处理办法：DevEco 里连上新设备 →
**File → Project Structure → Signing Configs** → 勾选 *Automatically generate signature*，
它会生成含新 UDID 的 `.p7b`。旧凭证在 `~/.ohos/config/` 下有备份。

> **注意**：`build-profile.json5` 里已有 `signingConfigs` 时，DevEco 会直接用旧凭证打包、
> 不弹自动签名窗口，点 Run 就是 `9568423`。换设备时要先把 `"signingConfigs": []` 清空，
> 签完再补回 `products[].signingConfig: "default"`。细节见 `docs/安装与排错.md` 第六节。

一步到位（自动检测凭证 → 引导签名 → 签完自动编译装机）：

```bash
./scripts/sign-auto.sh
```

首次编译前需要在 DevEco 里做**一次**签名（新包名 `com.fanren.boxtv` 需要自己的调试描述文件）：

1. DevEco Studio 打开本目录，等右下角 Sync 走完
2. 确认右上角设备是 `10.140.253.182:5555`
3. 点 **▶ Run**（⇧F10）→ 弹「Automatically generate signature」→ OK + 登录

之后 `.p7b` 就位，全部可以走命令行。

> `build-profile.json5` 里 `products[].signingConfig` 已预置为 `"default"`，
> 这是上次做 ZspaceTV 时踩过的坑：DevEco 只会写 `signingConfigs`，不写引用，导致
> `WARN No signingConfig found for product default`、只出未签名包。这次提前补上了。

### 云端出包（CNB）

不用开 DevEco 也能出包：CNB 仓库页「执行」下拉有两个按钮，配置在 `.cnb.yml`。

| 按钮 | 做什么 | 要密钥 |
|---|---|---|
| **出包并发布 Release** | 编译 + 调试签名 + 建 Release `v<版本号>` + 把**可直装的 hap** 挂成附件（页面填版本号/更新说明） | 要 |
| `出包（不发布）` | 编译 + 调试签名 + 推 `oci.cnb.cool` 制品库（版本号 + latest 双标签） | 要 |
| `编译校验` | 镜像里编译未签名 hap，输出 `dist/build-info.txt`，约 2 分钟 | 不要 |
| `重建构建镜像` | 构建命令行工具 26 / API 26 镜像，升 SDK 才点，约 14 分钟 | 不要 |

按钮定义在 `.cnb/web_trigger.yml`，实际跑的流水线在 `.cnb.yml`。发版产物直链形如
`https://cnb.cool/abber/HarmonyTv/-/releases/download/v1.1.0/yezhen-tv-1.1.0-debug.hap`。

> 镜像必须自建：社区现成镜像的 SDK 是 API 21，本工程要 API 26，会报
> `es2abc` 语法错和 `soundPool` 解析失败——源码没问题，是工具链差一代。
> 上架用的 release `.app` 需要 AGC 发布证书，仍走本机 `scripts/sign-release.sh`。

云端与本地**共用同一份构建实现** `scripts/ci-build.sh`，差别只有工具链来源
（本地 DevEco / 云端 `COMMAND_LINE_TOOLS_HOME`），由 `scripts/lib/harmony-env.sh` 统一推断。
签名材料不放仓库，走私有密钥仓库 `abber/secrets`，通过 `imports` 注入成环境变量。

CI 报错先在本地跑同一条命令复现，再看 `docs/CNB构建.md`（含镜像自建、制品取回、报错对照表）。

## 五、已知限制

- **爬虫型站源（220 个）不支持**，这是平台能力边界，不是疏漏。
- **筛选条件**未做：`m.json` 的 type 0/1 站点都没有 `ext`（分类/筛选 API），无从获取。
- **只有 http/https 协议**：`proxy://`、`tvbox://` 这类伪协议未实现。直播走标准 m3u/txt 源，已支持。
- 站源本身极不稳定：写测试时 `bajiezy.xyz` 返回 429、`ikaola.tv` 被 Cloudflare 403。
  应用对单站失败做了隔离，不会整页崩。
- 播放格式取决于鸿蒙系统解码器：HLS/H.264/H.265/TS 正常，DTS/TrueHD 音轨大概率无声。

### 直播源怎么配

应用包内**不内置**任何直播源（配合上架合规：直播源只能由用户主动订阅导入）。两种方式：

1. **订阅**（推荐）：设置页 → 订阅 → 填一个订阅链接，一份订阅同时带点播站源和直播源。
2. **手动填**：设置页 → 直播源 → 手动填一个 m3u / txt 地址。

默认订阅源（`https://s3a.abber.cn:88/public/subscribe.json`）下发的直播源如下：

| 名称 | 源（经 gh-proxy 镜像） | 实测频道 |
|---|---|---|
| 央视·IPv4 | `vbskycn/iptv` `tv/iptv4.m3u` | 463 |
| 中国频道 | `iptv-org/iptv` `streams/cn.m3u` | 517 |
| 国内电视 | `YueChan/Live` `GNTV.m3u` | 140 |
| 国内·aptv | `Kimentanm/aptv` `m3u/iptv.m3u` | 120 |
| 国内综合 | `YueChan/Live` `IPTV.m3u` | 96 |
| 测速优选 | `ssili126/tv` `itvlist.txt` | ~100 |
| 央视频道 | `YueChan/Live` `CUTV.txt` | ~85 |
| 央视·IPv6 | `fanmingming/live` `tv/m3u/ipv6.m3u` | 82（需 IPv6） |
| 聚合索引 | `fanmingming/live` `tv/m3u/index.m3u` | 94 |
| 镜像备用 | `ghproxy.net` 版 iptv4 | 463 |

#### 点「测速排行」——按实测结果排，而不是按频道数猜

一次测完订阅下发的所有直播源，每行给出 **延迟 · 频道数 · 可播抽样**，例如
`353 ms · 131 频道 · 可播 2/3`，并**按「可播数 → 延迟」自动重排、把第一名设为当前源**。

「可播 n/m」是关键一项：只看列表拉得快会选错——实测有源 74 ms 就拉完了 104 个频道，
但抽 3 个台去连，**一个都不通**；而 353 ms 的源 3 个台里能连上 2 个。所以排序规则是
**先看抽样台能不能连上，连上数量相同再比谁快**，而不是单纯比拉列表的速度。

#### 一个台挂了会自动往下找

播放页对直播单独走一条路（不经过影视解析），开播前先抓一下流地址的首包：

1. 主线路不通 → 换**同名的备用线路**（源里 CCTV1 常有 3~4 条地址，换线比换台命中率高）
2. 备用线路也不通 → **自动跳下一个台**，并提示「跳过失效频道 → CCTV2」
3. 连跳 4 个台都失败 → 停下来给错误页和重试按钮

这样做的原因：AVPlayer 对死链要 20 秒上下才回调 error，用户盯着黑屏等 20 秒才知道台挂了。
自己探活是 2.5 秒一次，体验差一个数量级。

#### 频道分组：用源里写的原名字，摆成电视盒子的样子

直播页是电视盒子的经典布局——**左边一列分组，右边频道网格**，点哪个分组就只看哪个分组。

分组**不改写、不归类**：源里写 `group-title="央视频道"` 就显示「央视频道」，写
`group-title="地方台/北京"` 就自动拆成「地方台 › 北京」两级。顶部「全部频道」回到全集，
标题栏显示「462 台 · 12 组」和当前路径「央视频道 › 全部」。

> 为什么不做「央视 / 卫视 / 地方」这类二次归类：源自己的分组名已经是最贴近内容的划分，
> 再套一层大类，每看一次都要多点一次；而且大类是靠关键词猜的，源一改名就对不上，
> 反而把频道分错堆。源完全没写 `group-title` 的（纯 txt 源常见）统一落到「未分组」，
> 原样保留，不猜。

#### 台多了怎么找：收藏 + 搜索

几百台靠翻分组找太慢，所以给了两条互补的路：

- **收藏**：目录树最上面的「★ 我的收藏」，**长按**频道卡片即可收藏/取消（遥控器按住确定键
  也是长按）。收藏存的是「台名 + 地址 + 分组 + 时间」，按时间倒序，换源后同名台还在。
  为什么用长按而不是卡片角上的星标：这块网格的点击挂在 `GridItem` 上（格子比文字大一圈，
  只挂文字会点不到空白区），角上再放小按钮会和整格点击抢事件，指针遥控对不准还容易误进播放页。
- **搜索**：顶栏「搜索」展开输入框（手机端默认常驻，电视端收起——遥控打字慢），
  按台名实时过滤，面包屑补一个「· 搜到 N 台」，否则「列表变短」和「源挂了」看起来一样。
  两套过滤互不覆盖：在「我的收藏」里仍可再搜某个台。

> 长按抬起后系统还会补一次 `click`，所以长按收藏后用 900ms 时间窗吞掉紧随其后的点击，
> 否则「想收藏」会变成「收藏 + 进播放页」。

#### 画质在播放中自动选，不弹框为难人

| 情况 | 行为 |
|---|---|
| 多码率 master（有 `#EXT-X-STREAM-INF`） | 起播取 720P 附近，播起来后 `Quality.measure` 实测网速再升/降档 |
| 播放中途卡顿 | 卡顿看门狗自动降一档，提示「网络偏慢，已自动降到 720P」 |
| 单码流（多数直播就是这种） | 没档可切，改调缓冲水位 `preferredBufferDuration` 抗抖动 |
| 用户手动锁档 | 记录到 `qPref`，之后不再自动升降，直到改回「自动」 |

切档不换地址：始终把 master 交给播放器，只用 `PlaybackStrategy.preferredHeight` 表达期望高度，
系统自己的 ABR 才能继续在档位间平滑挪，比我们自己替换流地址稳。

#### 手机扫码录入片源

电视上用遥控器敲几十个字符的 URL 是最难受的一步，所以：

**点「订阅」「点播配置」或「直播源」的输入框 → 直接弹出二维码**（不占常驻版面）。

- 面板左边是二维码，右边是可直接点的「手动输入 ›」（没连 Wi-Fi / 相机扫不了时的退路）
- 手机与电视连同一个 Wi-Fi，扫码打开 `http://<电视IP>:8788?t=sub|cfg|live`
- 二维码里带了 `?t=`，手机页面会把对应那块排到最前并自动聚焦：点的是直播源，打开就是直播源输入框；点的是订阅，打开就是订阅链接输入框
- 粘地址提交后电视端立即落盘并刷新，弹窗收起；离开设置页就不再接受写入
- 点面板外的空白处或右上「✕」关闭

#### 订阅链接（点播 + 直播一起更新）

设置页「订阅」填一个链接，就能同时更新点播站源和直播源。订阅文档是 TVBox 配置 JSON 的扩展：

```json
{
  "name": "夜帧影视·订阅源",
  "sites":  [ /* 点播站源，同 TVBox 格式 */ ],
  "parses": [ /* 播放地址解析接口 */ ],
  "lives":  [ { "name": "央视·IPv4", "url": "https://…/iptv4.m3u" } ]
}
```

默认订阅源已生成并托管在 `https://s3a.abber.cn:88/public/subscribe.json`（重跑
`python3 scripts/gen-subscription.py` 后重新上传即可更新），扫码图见
`docs/store/subscribe_qr.png`。订阅成功后未配直播源会自动选用第一个。

> **为什么订阅源都带 `gh-proxy.com` 前缀**
>
> 这台设备 `ping raw.githubusercontent.com` 是通的（66 ms），但 `@ohos.net.http` 抓它的 https
> 会直接抛 `Internal error`（TLS 层被拦），直播页表现为「直播源加载失败」。
> 换 `gh-proxy.com`（国内有节点，18 ms）后同一文件能完整取到 463 个频道。
> 旧版本存过的 raw 直连地址，进直播页时会**自动改写成镜像地址**，不用手动重配。

### 站源（点播）怎么选最快的

设置页 → 站源管理 → **测速排行**：对每个可用站源发一次 `?ac=list`，只读首包，
记录响应时间与有没有吐数据，测完按快→慢重排，每行显示 `399 ms` / `不通`。

测完出现两个按钮：

- **启用最快 5 个**：只开最快的 5 个，其余关掉——搜索和点播不会在慢站上干等
- **全部启用**：恢复全开

排序结果会一直保留（切开关、重新刷新都不会丢），直到下次重新测速。

## 五之二、上架应用市场

物料与流程见 **`docs/上架指南.md`**，速览：

```bash
./scripts/build.sh          # 编译 + 用 AGC 发布证书签名，产物在 build/release/
./scripts/preflight.sh      # 提审前自检（8 组，红绿结论）
./scripts/install.sh        # 装到设备（默认取 build/release 下最新包）
```

| 项 | 状态 |
|---|---|
| 包名 | `com.hong.tv`（APP ID `6917620734707118812`） |
| 应用图标 | **单张 `$media:app_icon`**（由 `docs/store/icon_1024.png` 缩出的 512 版）：外层 squircle（指数 5）+ 内层正圆（占 90%）+ 边圈统一 #76D79A；主图形为「播放三角 + 三声道声波」+ 下方「夜帧影视」，4× 超采样、整体光学居中。分层资源（background/foreground/layered_image.json）保留在工程内备用。生成脚本 `scripts/gen-icon.py`、`scripts/redesign-emblem.py` |
| AGC 发布证书 | ✅ `release.p12` / `release.cer` / `发布Profile.p7b`，`SIGN_DIR` 默认指向 `~/Desktop/work/code/huawei` |
| 签名方式 | `hap-sign-tool.jar` 后置签名（hvigor 只吃 DevEco 加密口令，命令行写不进去） |
| Release 产物 | ✅ `build/release/夜帧影视-1.0.4-release-signed.app`（App Pack，`verify-app` 校验通过。注意 `app_gallery` 分发的包**不能**本地 `hdc install`，会报 9568322，属正常） |
| 提审自检 | ✅ 16 项通过 / 0 失败 |
| 软著材料 | ✅ `docs/copyright/`（源程序 60 页 × 50 行、前后 30 页零指向性词汇 + 说明书 21 页 / 19 图 + 申请表底稿；`check-copyright.py` 含内容风险自检） |
| 隐私政策公网地址 | ✅ `https://s3a.abber.cn:88/public/privacy.html` |
| 截图 / 图标 / 文案 | ✅ 见 `docs/store/`（18 张横屏 1920×1080 + 5 张竖版 1080×1920，均已按「夜帧影视」重拍） |
| 首启隐私政策 + 不同意退出 | ✅ 已实现，清数据实测通过 |
| 首启三步引导 / 直连播放 | ✅ 已实现，实测出画面 |

> **务必认清的一点**：影视聚合 / 可自填源这一类应用在国内应用市场属高风险品类，
> 常见拒审理由是「无法提供内容授权」。这不是材料齐不齐的问题，是产品形态与
> 「内容可追溯」要求本身冲突。`docs/上架指南.md` 第四节给了三条现实路径，
> 建议先投一次拿到明确意见，再决定是改产品定位还是换分发渠道。

### 凭据放在哪

- `docs/store/agc-应用信息.md`：APP ID、证书主体、文件位置（可公开的部分）
- `.agc-secret`：Client Secret，权限 600，已写进 `.gitignore`，**不要入库、不要写进
  HAP**（客户端里的字符串能被解包看到；真要用应放后端换 token）

## 六、目录

```
TVBoxTV/
├── entry/src/main/ets/
│   ├── common/
│   │   ├── Model.ets      数据模型 + 界面常量
│   │   ├── Http.ets       GET 客户端（手写重定向跟随、中文错误提示）
│   │   ├── Cms.ets        采集协议实现（JSON/XML/CDATA/线路拆分）
│   │   ├── Resolve.ets    播放地址解析（parses type=1）
│   │   ├── Pointer.ets    灵犀指向遥控的指针点击识别（按下+抬起 / 400ms 去重）
│   │   ├── PlayGuard.ets  切后台停播兜底（Ability.onBackground 统一停掉播放器）
│   │   ├── WdQr.ets       网盘扫码录入面板（电视端扫码，手机填表）
│   │   └── Store.ets      配置缓存、站点开关、历史、收藏
│   ├── pages/
│   │   ├── Index.ets      首页（继续观看 / 收藏 / 站源）
│   │   ├── SiteList.ets   分类浏览 + 翻页
│   │   ├── Detail.ets     详情 + 线路 + 剧集
│   │   ├── Search.ets     多站并发搜索
│   │   ├── Player.ets     播放器
│   │   └── Settings.ets   配置导入 + 站源管理
│   └── entryability/EntryAbility.ets
├── .cnb.yml                  CNB 流水线：compile / build 两个手动按钮
├── scripts/build.sh          一键编译
├── scripts/ci-build.sh       编译 + 补签的唯一实现（本地与 CNB 共用，含 build-info 清单）
├── scripts/lib/harmony-env.sh 工具链定位（DevEco / 命令行工具 / SDK / 签名工具，跨平台）
├── scripts/build-tv.sh       编译 + 调试证书补签 + 装机（电视真机联调，一条命令）
├── scripts/build-release.sh  Release 编译 + 证书类型自检（上架用）
├── scripts/preflight.sh      提审前自检（8 组检查，红绿结论）
├── scripts/emuctl.sh         模拟器操作（真机不在线时用）
├── scripts/sign-release.sh   用 AGC 证书签 Release 包（纯命令行，不依赖 IDE）
├── scripts/install.sh        一键装机
├── scripts/sign-auto.sh      换设备后重新签名并装机
├── tools/parse-check.mjs     协议解析自检（Node，与 Cms.ets 同一套逻辑）
└── docs/
    ├── 可行性分析.md
    ├── CNB构建.md            云端出包、密钥仓库、镜像自建、报错对照
    ├── 安装与排错.md
    ├── 上架指南.md
    ├── 隐私政策.md
    └── store/                上架物料
        ├── 应用市场文案.md
        ├── privacy.html
        ├── icon_1024.png
        └── screenshots/      1920×1080 ×17
```

## 七、排错

| 现象 | 原因 | 处理 |
|---|---|---|
| 退出直播后还在出声 | 直播 `pause` 停不干净；解析/建播放器期间返回会遗留 AVPlayer | 已修：直播 hide 即 `release()` + `PlayGuard` 切后台兜底，详见 `docs/安装与排错.md` 三节 |
| `code:9568320 no signature file` | 没签名 | DevEco 点一次 ▶ Run 生成描述文件 |
| 分类加载失败 | 站源换了域名/被墙 | 换站源，或在设置里关掉它 |
| 所有站源都没内容 | 配置过期 | 重新导入配置地址 |
| 播放黑屏但有声 | 视频编码不被支持 | 换线路 |
| 播放提示「未解析」 | 该地址需要专用解析器 | 换线路；解析器生态在 `parses` 里，可换配置 |
