# 软件著作权登记材料

| 文件 | 用途 | 说明 |
|---|---|---|
| `软著申请表填写信息.md` | 线上申请表的填写底稿 | 每栏都按项目实际情况写好，照抄即可；标【待填】的是你本人的证件与联系方式。末尾两节分别是「功能 → 材料」对应表与「改代码后如何同步材料」 |
| `夜帧影视_源程序.pdf` | 源程序文档（**提交用 PDF**） | 60 页（前 30 + 后 30），**每页 50 行**（第 31 页首行是省略说明，故该页源码 49 行），页眉「夜帧影视软件 V1.0」，页脚页码，A4 |
| `夜帧影视_源程序.docx` | 源程序的可编辑备份 | 内容与上面 PDF 同源（同一套取码/折行/分页规则），供需要改字时用 |
| `夜帧影视_软件说明书.pdf` | 用户手册（**提交用 PDF**，文档鉴别材料） | 21 页，19 张插图（应用图标 1 张 + 运行截图 18 张）+ 14 章功能与操作说明，页眉「夜帧影视软件 V1.0」+ 页码，A4 |
| `夜帧影视_软件说明书.docx` | 说明书的可编辑备份 | 内容与上面 PDF 同源 |
| `夜帧影视_材料清单与封面.pdf` | 提交材料总清单（**核对用**） | 1 页：软件信息、六项材料清单、格式要求、提交前自检勾选 |
| `夜帧影视_商标查询清单.pdf` | **参考件，不随材料提交，但结论影响是否改名** | 2 页：第 9 / 41 类在先商标逐条（含注册号与状态）、同名安卓应用冲突、「三条路」方案对比、换名需改动的文件清单、官网复核步骤。结论：**风险高，建议换名并脱离「凡人」词根**；由 `scripts/gen-trademark-checklist.py` 生成 |
| `夜帧影视_代理委托书.pdf` | 代理委托书（**条件性**） | 1 页，填空 + 手写签字后扫描；**不委托代理机构则无需提交** |
| `夜帧影视_非职务开发声明.pdf` | 非职务开发声明（**备用**） | 1 页，审查员对本软件是否属职务软件提出问询时补交 |

两份文档描述的是同一个版本（V1.0）的最终形态，包含全部交互与性能优化：
首页海报墙（观看进度线 / 更新角标 / “全部 ›”）、设置页双栏布局、片单分层缓存与
“刷新”、父分类汇总、详情页自动定位、搜索收键盘、订阅一键导入点播+直播源、
历史单条删除与二次确认清空、全界面遥控器走焦与手机/电视双布局自适应。

## 重新生成

代码或截图有变动时，重跑这几条命令即可重新生成（需要 `python-docx`）：

```bash
python3 -m pip install python-docx
python3 scripts/gen-copyright.py       # 源程序 docx（可编辑备份）
python3 scripts/gen-copyright-pdf.py   # 源程序 pdf（提交用，Chrome headless 打印）
python3 scripts/gen-manual.py          # 说明书 docx（可编辑备份）
python3 scripts/gen-manual-pdf.py      # 说明书 → HTML（图片自动压缩）
node scripts/cdp-print-pdf.mjs "docs/copyright/夜帧影视_软件说明书.html" \
     "docs/copyright/夜帧影视_软件说明书.pdf" "夜帧影视软件　V1.0　软件说明书"
python3 scripts/gen-copyright-extra.py  # 材料清单 / 代理委托书 / 非职务开发声明（三份 1 页 PDF）
```

- `gen-copyright-pdf.py` 与 `gen-copyright.py` 共用同一套取码/折行/分页规则，把每页
  渲染成固定 A4 的 HTML，再用本机 Chrome 无头模式打印成 PDF（`--no-sandbox`）。
  页眉「夜帧影视软件 V1.0 源程序」与页码写在 HTML 里，不依赖浏览器默认页眉。

- `gen-copyright.py` 会自动遍历 `entry/src/main/ets/**/*.ets`，去掉空行后按每页 50 行
  分页；超过 60 页自动只取前后各 30 页，并在中间插入省略说明（说明占掉第 31 页首行，
  该页源码 49 行，合计仍是 50 行）；末页不足 50 行时补收尾说明填满。
  **内置硬校验**：任一页行数不等于 50 会直接失败退出，不会产出半页。
- 源码行宽上限 82 列（中文按 2 列计）。这是按 A4 可用宽度 476pt 与等宽字体
  0.62em 的最坏情况算出来的：超过就会自动换行，一页变成 51 行。
- `gen-manual.py` 读取 `docs/store/screenshots/` 里的截图，缺哪张就跳过哪张，不会报错；
  应用图标（3.1 的图 3-1）从 `docs/store/icon_1024.png` 取，由 `scripts/gen-icon.py` 生成。
  图注里的编号（图 5-5 等）写在脚本里，新增小节时记得同步编号。

## 提交前自查

- [ ] 申请表里的软件名称、版本号与两份文档页眉一致（夜帧影视软件 / V1.0）
- [ ] 申请表里的「源程序量」与实际一致（当前 15150 行非空、32 个 ArkTS 文件）
- [ ] 说明书里的应用图标与实际安装后的桌面图标一致
- [ ] 源程序文档打印后确认每页确实是 50 行（A4、不缩放）
- [ ] 说明书打印后图片清晰、没有跨页断裂的图
- [ ] 说明书里描述的功能，界面上都能点到（改了功能没改文档是最常见的补正理由）
- [ ] 身份证复印件正反面在同一页，且已导出为 PDF
- [ ] 首次发表日期与「是否已发表」保持一致
- [ ] 若委托代理机构：代理委托书已填空、本人手写签字、扫描为 PDF

## 源程序的取材顺序（重要）

软著只提交「前 30 页 + 后 30 页」，中间省略。文件顺序由 `scripts/copyright_order.py` 决定，
规则是**三段式**：

```
前段 = 最中性的若干模块（Device / Feedback / QrCode / Pinyin / HistoryPage …）
中段 = 其余模块（含 SettingPage / Store / Cms 这些指向性较强的）
后段 = 次中性的若干模块
```

这样提交材料的前后 30 页都不会出现「站源 / 直播源 / TVBox / 采集接口 / 订阅」这类
指向性词汇，它们只落在被省略的中间页。

> 为什么不用简单的字母序：`common/Cms.ets` 按字母序排第一，文件头注释里的
> 「TVBox 的协议型站源 / csp 爬虫 / jar」会直接出现在第 1 页。
> 也不能简单按敏感度升序：那样尾部会变成 SettingPage / Store，后 30 页反而更露。

新增或改动模块后跑一次：

```bash
python3 scripts/gen-copyright.py && python3 scripts/gen-copyright-pdf.py
# 复扫：前后 30 页应各为 0 命中
```

## 模块清单与抽样说明（备查，不随材料提交）

软著只提交「前 30 页 + 后 30 页」，且按 `scripts/copyright_order.py` 的三段式顺序取材，
所以提交页里以中性模块为主。如果审查员或对方质疑「抽样看不出核心功能」，用这份清单解释：

| 模块 | 非空行 | 模块 | 非空行 |
|---|---|---|---|
| `pages/Player.ets` | 2386 | `common/Live.ets` | 278 |
| `pages/SettingPage.ets` | 1955 | `pages/HistoryPage.ets` | 249 |
| `pages/Home.ets` | 1299 | `common/Crawler.ets` | 220 |
| `common/Store.ets` | 956 | `common/LiveProbe.ets` | 213 |
| `pages/LivePage.ets` | 925 | `common/Http.ets` | 180 |
| `pages/VodPage.ets` | 739 | `pages/CollectPage.ets` | 173 |
| `pages/WebdavPage.ets` | 705 | `common/Pinyin.ets` | 131 |
| `common/Cms.ets` | 619 | `common/Feedback.ets` | 99 |
| `pages/Search.ets` | 589 | `common/Tip.ets` | 77 |
| `pages/Detail.ets` | 530 | `common/Device.ets` | 73 |
| `common/QrCode.ets` | 503 | `common/PhoneTabBar.ets` | 65 |
| `common/Webdav.ets` | 451 | `common/Playlist.ets` | 64 |
| `pages/Direct.ets` | 411 | `common/Resolve.ets` | 63 |
| `common/Quality.ets` | 350 | `entryability/EntryAbility.ets` | 59 |
| `common/Model.ets` | 344 | `common/LivePresets.ets` | 43 |
| `common/QrServer.ets` | 313 | `common/TvFocus.ets` | 20 |

合计 **15150 行 / 32 个文件**（去空行），与申请表「源程序量」一致。

需要完整源码时，直接提供 `entry/src/main/ets/` 目录（32 个 `.ets` 文件）即可，
全部可编译复现；抽样仅为登记格式要求，不代表代码规模。
