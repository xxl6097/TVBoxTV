/**
 * WebDAV 网盘 —— 挂载 WebDAV 服务器，浏览目录并识别影视资源。
 *
 * 三种视图：
 *   sources —— 源列表（添加 / 编辑 / 删除 / 进入）
 *   browse  —— 浏览目录（点目录进入、点视频播放），可一键「识别影视」
 *   scan    —— 识别结果（按片名聚合的电影/剧集），点开选集播放
 *
 * 播放走 Player 的「直连」链路，通过 PlayParam.header 把 Basic Auth 带过去，
 * 剧集用 Playlist 共享，遥控器可切上/下一集。
 */

import { Feedback } from '../common/Feedback';
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { Store } from '../common/Store';
import { PlayParam, WebdavSource, WebdavEntry, WebdavVod, WebdavEp, Episode, WdHistory, T } from '../common/Model';
import { Webdav } from '../common/Webdav';
import { Playlist } from '../common/Playlist';
import { Device, KEY_IS_PHONE } from '../common/Device';
import { WdQrPanel } from '../common/WdQr';
import { Tip, TIP_MSG, TipLayer } from '../common/Tip';

@Entry
@Component
struct WebdavPage {
  @State sources: WebdavSource[] = [];
  @State view: string = 'sources';
  @State hoverKey: string = '';
  @State loading: boolean = false;
  @State msg: string = '';
  @State msgColor: string = T.SUB;

  // 当前浏览的源与路径
  @State cur: WebdavSource = new WebdavSource();
  @State curPath: string = '/';
  @State entries: WebdavEntry[] = [];
  // 识别结果
  @State vods: WebdavVod[] = [];
  // 网盘续播记录
  @State wdHist: WdHistory[] = [];

  // 选集弹窗
  @State epOpen: boolean = false;
  @State selVod: WebdavVod = new WebdavVod();

  @StorageProp(KEY_IS_PHONE) isPhone: boolean = false;
  @StorageLink(TIP_MSG) tipMsg: string = '';
  /** 电视端扫码添加网盘面板 */
  @State wdQrOpen: boolean = false;

  async aboutToAppear(): Promise<void> {
    await Store.init(getContext(this) as common.UIAbilityContext);
    await this.refreshData();
  }

  /** 从播放页/设置页返回时刷新源列表与续播记录 */
  onPageShow(): void {
    this.refreshData();
    // 播放页退出时续播记录是异步落盘的（saveWdPos fire-and-forget），
    // 刚回来那一刻 prefs 可能还没 flush 完，读到旧值 → 「继续观看」不显示。
    // 延迟再读一次，等写入落盘后把记录补出来。
    setTimeout(() => {
      this.refreshData();
    }, 350);
  }

  async refreshData(): Promise<void> {
    this.sources = await Store.webdavSources();
    this.wdHist = await Store.wdHistory();
  }

  /** 手机扫码添加成功后：刷新源列表并给一条提示（面板里已经落盘） */
  async afterQrAdd(src: WebdavSource): Promise<void> {
    await this.refreshData();
    Tip.show('已添加网盘「' + src.name + '」');
  }

  // ---------- 焦点 ----------
  hi(key: string): boolean {
    return this.hoverKey === key;
  }

  hover(key: string, on: boolean): void {
    if (on) {
      this.hoverKey = key;
    } else if (this.hoverKey === key) {
      this.hoverKey = '';
    }
  }

  onBackPress(): boolean {
    if (this.wdQrOpen) {
      this.wdQrOpen = false;
      return true;
    }
    if (this.epOpen) {
      this.epOpen = false;
      return true;
    }
    if (this.view !== 'sources') {
      this.backToSources();
      return true;
    }
    router.back();
    return true;
  }

  backToSources(): void {
    this.view = 'sources';
    this.entries = [];
    this.vods = [];
    this.msg = '';
  }

  // ---------- 浏览 ----------
  /**
   * 进入一个源：优先读上次的识别缓存，有就直接展示；没有则自动扫描识别。
   * 目录浏览不再作为默认视图，想看文件树再点「浏览文件」。
   */
  async enterSource(src: WebdavSource): Promise<void> {
    this.cur = src;
    this.curPath = Webdav.mountHref(src);
    this.vods = [];
    this.msg = '';
    const cache: WebdavVod[] = await Store.webdavScanCache(src.id);
    if (cache.length > 0) {
      this.vods = cache;
      this.view = 'scan';
      this.msg = '上次识别到 ' + cache.length + ' 部影视，点「重新扫描」可刷新';
      this.msgColor = '#B7F0BC';
      return;
    }
    // 无缓存 → 切到识别视图再自动扫描（扫描中能看到进度）
    this.view = 'scan';
    await this.scanVods();
  }

  async loadDir(): Promise<void> {
    this.loading = true;
    this.entries = [];
    try {
      this.entries = await Webdav.list(this.cur, this.curPath);
    } catch (e) {
      const err = e as Error;
      this.msg = err.message;
      this.msgColor = T.WARN;
    }
    this.loading = false;
  }

  /** 从识别结果视图切回目录浏览 */
  async openBrowse(): Promise<void> {
    this.view = 'browse';
    this.msg = '';
    await this.loadDir();
  }

  async enterDir(entry: WebdavEntry): Promise<void> {
    this.curPath = Webdav.stripSlash(entry.href);
    await this.loadDir();
  }

  async goUp(): Promise<void> {
    const p: string = Webdav.stripSlash(this.curPath);
    const i: number = p.lastIndexOf('/');
    this.curPath = i <= 0 ? '/' : p.substring(0, i);
    await this.loadDir();
  }

  pathLabel(): string {
    let p: string = this.curPath;
    try {
      p = decodeURIComponent(p);
    } catch (e) {
      // 保持原文
    }
    return p;
  }

  // ---------- 播放 ----------
  playFile(entry: WebdavEntry): void {
    const v = new WebdavVod();
    v.name = Webdav.stripExt(entry.name);
    v.kind = 'movie';
    v.dir = Webdav.stripSlash(this.curPath);
    const ep = new WebdavEp();
    ep.name = entry.name;
    ep.url = Webdav.absUrl(this.cur, entry.href);
    ep.href = entry.href;
    v.eps.push(ep);
    this.playEp(v, 0);
  }

  openEp(vod: WebdavVod): void {
    if (vod.eps.length === 1) {
      this.playEp(vod, 0);
      return;
    }
    this.selVod = vod;
    this.epOpen = true;
  }

  epNameOf(vod: WebdavVod, ep: WebdavEp, i: number): string {
    if (vod.kind === 'series') {
      if (ep.season > 0 && ep.episode > 0) {
        return 'S' + WebdavPage.pad2(ep.season) + 'E' + WebdavPage.pad2(ep.episode);
      }
      if (ep.episode > 0) {
        return '第 ' + ep.episode + ' 集';
      }
    }
    return Webdav.stripExt(ep.name);
  }

  playEp(vod: WebdavVod, idx: number): void {
    if (idx < 0 || idx >= vod.eps.length) {
      return;
    }
    // 交给播放列表，剧集可切上/下一集
    const eps: Episode[] = [];
    for (let i = 0; i < vod.eps.length; i++) {
      const e = new Episode();
      e.name = this.epNameOf(vod, vod.eps[i], i);
      e.url = vod.eps[i].url;
      eps.push(e);
    }
    Playlist.set(eps, idx, vod.name);
    this.epOpen = false;

    const p = new PlayParam();
    p.url = vod.eps[idx].url;
    p.title = vod.name + (vod.eps.length > 1 ? (' ' + eps[idx].name) : '');
    p.siteKey = 'webdav';
    p.vodId = 'webdav:' + this.cur.id + ':' + vod.name;
    p.from = 'direct';
    p.epIndex = idx;
    p.header = Webdav.authHeader(this.cur);
    // 网盘续播落盘所需字段
    p.wdSrcId = this.cur.id;
    p.wdSrcName = this.cur.name;
    p.wdVod = vod.name;
    p.wdDir = vod.dir;
    p.wdSeries = vod.eps.length > 1;
    router.pushUrl({ url: 'pages/Player', params: p });
  }

  // ---------- 续播 ----------
  /** 从续播记录继续观看：seek 到上次进度，能重建选集时仍可切上/下一集 */
  async continueWatch(h: WdHistory): Promise<void> {
    const srcs: WebdavSource[] = await Store.webdavSources();
    let src: WebdavSource | null = null;
    for (let i = 0; i < srcs.length; i++) {
      if (srcs[i].id === h.srcId) {
        src = srcs[i];
        break;
      }
    }
    if (src === null) {
      // 源都删了，这条续播记录必然失效，直接清掉
      await Store.removeWdHistory(h);
      this.wdHist = await Store.wdHistory();
      return;
    }

    // 尝试从识别缓存重建整部剧的选集，续播时也能切上/下一集
    let eps: Episode[] = [];
    let startIdx: number = 0;
    let playUrl: string = h.url;
    let title: string = h.vodName;
    const cache: WebdavVod[] = await Store.webdavScanCache(src.id);
    let vod: WebdavVod | null = null;
    for (let i = 0; i < cache.length; i++) {
      if (cache[i].name === h.vodName) {
        vod = cache[i];
        break;
      }
    }
    if (vod !== null && vod.eps.length > 0) {
      for (let i = 0; i < vod.eps.length; i++) {
        const e = new Episode();
        e.name = this.epNameOf(vod, vod.eps[i], i);
        e.url = vod.eps[i].url;
        eps.push(e);
      }
      startIdx = (h.epIndex >= 0 && h.epIndex < vod.eps.length) ? h.epIndex : 0;
      playUrl = vod.eps[startIdx].url;
      title = vod.name + (vod.eps.length > 1 ? (' ' + eps[startIdx].name) : '');
      Playlist.set(eps, startIdx, vod.name);
    } else if (h.epName.length > 0) {
      title = h.vodName + ' ' + h.epName;
    }

    const p = new PlayParam();
    p.url = playUrl;
    p.title = title;
    p.siteKey = 'webdav';
    p.vodId = 'webdav:' + src.id + ':' + h.vodName;
    p.from = 'direct';
    p.epIndex = startIdx;
    p.header = Webdav.authHeader(src);
    p.seek = h.pos;
    p.wdSrcId = src.id;
    p.wdSrcName = src.name;
    p.wdVod = h.vodName;
    p.wdDir = h.dir;
    // 是否剧集：能重建选集按集数判断；否则按历史记录粗略判断（epIndex>0 或曾有集名）
    if (vod !== null && vod.eps.length > 0) {
      p.wdSeries = vod.eps.length > 1;
    } else {
      p.wdSeries = h.epIndex > 0 || h.epName.length > 0;
    }
    router.pushUrl({ url: 'pages/Player', params: p });
  }

  async removeWd(h: WdHistory): Promise<void> {
    await Store.removeWdHistory(h);
    this.wdHist = await Store.wdHistory();
  }

  static pad2(n: number): string {
    return n < 10 ? '0' + n : String(n);
  }

  // ---------- 识别影视 ----------
  async scanVods(): Promise<void> {
    this.loading = true;
    this.msg = '正在扫描目录识别影视资源…';
    this.msgColor = T.SUB;
    try {
      const result: WebdavVod[] = await Webdav.scan(this.cur, 6,
        (dirs: number, files: number): void => {
          this.msg = '正在扫描… 已扫 ' + dirs + ' 个目录，发现 ' + files + ' 个视频';
        });
      this.vods = result;
      // 识别结果落盘，下次进入直接读缓存
      await Store.saveWebdavScan(this.cur.id, result);
      this.view = 'scan';
      this.msg = '识别到 ' + result.length + ' 部影视';
      this.msgColor = '#B7F0BC';
    } catch (e) {
      const err = e as Error;
      this.msg = err.message;
      this.msgColor = T.WARN;
      // 扫描失败保留在 browse 视图（如果本来就在 browse），否则停在 sources
      if (this.view !== 'browse') {
        this.view = 'browse';
        await this.loadDir();
      }
    }
    this.loading = false;
  }

  // ---------- UI ----------
  @Builder
  Btn(label: string, key: string, primary: boolean, act: () => void) {
    Text(label)
      .fontSize(15)
      .height(44)
      .padding({ left: 22, right: 22 })
      .borderRadius(T.RADIUS_PILL)
      .backgroundColor(primary ? T.ACCENT : (this.hi(key) ? T.CARD_HI : T.CARD))
      .fontColor(primary ? T.BG : (this.hi(key) ? T.SELECTED : T.TXT))
      .border({ width: T.BORDER, color: this.hi(key) ? (primary ? T.SELECTED : T.TXT) : '#00000000' })
      .textAlign(TextAlign.Center)
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .focusable(true)
      .onFocus(() => this.hover(key, true))
      .onBlur(() => this.hover(key, false))
      .onHover((hv: boolean) => this.hover(key, hv))
      .onClick(() => {
        Feedback.tap();
        act();
      })
  }

  /** 通用行底板：标题 + 说明 + 右侧操作文字，焦点高亮 */
  @Builder
  RowItem(key: string, title: string, sub: string, right: string, act: () => void) {
    Row() {
      Column() {
        Text(title).fontSize(15).fontColor(T.TXT).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (sub.length > 0) {
          Text(sub).fontSize(12).fontColor(T.DIM).margin({ top: 3 }).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (right.length > 0) {
        Text(right).fontSize(13).fontColor(T.SELECTED).margin({ left: 10 })
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 14, right: 14 })
    .borderRadius(T.RADIUS_SM)
    .backgroundColor(this.hi(key) ? T.CARD_HI : T.CARD)
    .border({ width: T.BORDER, color: this.hi(key) ? T.TXT : '#00000000' })
    .margin({ bottom: 8 })
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
    .focusable(true)
    .onFocus(() => this.hover(key, true))
    .onBlur(() => this.hover(key, false))
    .onHover((hv: boolean) => this.hover(key, hv))
    .onClick(() => {
      Feedback.tap();
      act();
    })
  }

  @Builder
  TopBar(title: string) {
    Row() {
      Text('‹')
        .fontSize(34)
        .fontColor(this.hi('back') ? T.TXT : T.SUB)
        .width(40)
        .textAlign(TextAlign.Center)
        .focusable(true)
        .defaultFocus(true)
        .onFocus(() => this.hover('back', true))
        .onBlur(() => this.hover('back', false))
        .onHover((hv: boolean) => this.hover('back', hv))
        .onClick(() => {
          Feedback.tap();
          if (this.view === 'sources') {
            router.back();
          } else {
            this.backToSources();
          }
        })
      Text(title).fontSize(24).fontColor(T.TXT).margin({ left: 8 })
      if (this.view === 'browse') {
        Text(this.cur.name + '  ·  ' + this.pathLabel())
          .fontSize(14).fontColor(T.DIM).margin({ left: 16 }).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      } else if (this.view === 'scan') {
        Text(this.cur.name)
          .fontSize(14).fontColor(T.DIM).margin({ left: 16 }).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 8 })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        this.TopBar(this.view === 'sources' ? 'WebDAV 网盘' : (this.view === 'browse' ? '浏览文件' : '识别影视'))

        Scroll() {
          Column() {
            if (this.view === 'sources') {
              this.sourcesView()
            } else if (this.view === 'browse') {
              this.browseView()
            } else {
              this.scanView()
            }
          }
          .width('100%')
          .padding({ left: 24, right: 24, bottom: 30 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(T.BG)

      if (this.epOpen) {
        this.epPanel()
      }
      if (this.wdQrOpen) {
        WdQrPanel({
          onClose: () => {
            this.wdQrOpen = false;
          },
          onSaved: (src: WebdavSource) => {
            this.wdQrOpen = false;
            this.afterQrAdd(src);
          }
        })
      }
      if (this.tipMsg.length > 0) {
        TipLayer(this.tipMsg)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  sourcesView() {
    Column() {
      // 继续观看：网盘播放记录，点击从上次进度续播
      if (this.wdHist.length > 0) {
        Row() {
          Text('继续观看').fontSize(17).fontColor(T.TXT)
          Blank()
          Text('清空').fontSize(13).fontColor(T.DIM)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(T.RADIUS_PILL)
            .backgroundColor(this.hi('clearWd') ? T.CARD_HI : T.CARD)
            .border({ width: T.BORDER, color: this.hi('clearWd') ? T.TXT : '#00000000' })
            .focusable(true)
            .onFocus(() => this.hover('clearWd', true))
            .onBlur(() => this.hover('clearWd', false))
            .onHover((hv: boolean) => this.hover('clearWd', hv))
            .onClick(() => {
              Feedback.tap();
              this.clearWd();
            })
        }
        .width('100%')
        .margin({ top: 6, bottom: 8 })

        ForEach(this.wdHist, (h: WdHistory) => {
          this.wdHistItem(h)
        }, (h: WdHistory) => h.srcId + '_' + h.vodName)

        Text('挂载的网盘在这里浏览目录、识别并播放影视资源；新增 / 编辑 / 删除网盘请到「设置 → 网盘」。')
          .fontSize(14).fontColor(T.SUB).width('100%').lineHeight(22).margin({ top: 18 })
      } else {
        Text('挂载的网盘在这里浏览目录、识别并播放影视资源；新增 / 编辑 / 删除网盘请到「设置 → 网盘」。')
          .fontSize(14).fontColor(T.SUB).width('100%').lineHeight(22)
      }

      Row() {
        // 电视端首选：扫码在手机上填，遥控器只负责点这一下
        if (!this.isPhone) {
          this.Btn('扫码添加网盘', 'qr_add', true, () => {
            this.wdQrOpen = true;
          })
        }
        this.Btn('去设置页添加', 'go_setting', this.isPhone, () => {
          router.pushUrl({ url: 'pages/SettingPage' });
        })
        Blank()
      }
      .width('100%')
      .margin({ top: 16, bottom: 6 })

      if (this.sources.length === 0) {
        Text(this.isPhone ? '还没有挂载任何网盘。点「去设置页添加」，填服务器地址、账号密码即可。'
          : '还没有挂载任何网盘。点「扫码添加网盘」，用手机扫码填服务器地址和账号密码，电视这台不用敲字。')
          .fontSize(14).fontColor(T.DIM).width('100%').margin({ top: 20 }).lineHeight(22)
      } else {
        ForEach(this.sources, (s: WebdavSource) => {
          this.RowItem('s_' + s.id, s.name, s.url, '进入 ›', () => {
            this.enterSource(s);
          })
        }, (s: WebdavSource) => s.id)
      }
    }
  }

  /** 单条续播记录 */
  @Builder
  wdHistItem(h: WdHistory) {
    Row() {
      Column() {
        Text(h.vodName).fontSize(15).fontColor(T.TXT).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Text(h.epName.length > 0 ? ('看到 ' + h.epName) : '电影')
            .fontSize(12).fontColor(T.DIM)
          if (h.pos > 0) {
            Text(' · 已看 ' + WebdavPage.fmtPos(h.pos) + (h.dur > 0 ? (' / ' + WebdavPage.fmtPos(h.dur)) : ''))
              .fontSize(12).fontColor(T.SELECTED)
          }
        }
        .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        Feedback.tap();
        this.continueWatch(h);
      })

      Text('继续播放 ›')
        .fontSize(13).fontColor(T.SELECTED).margin({ left: 10 })
        .onClick(() => {
          Feedback.tap();
          this.continueWatch(h);
        })

      Text('✕')
        .fontSize(15).fontColor(T.DIM)
        .width(36).height(36).textAlign(TextAlign.Center).borderRadius(18)
        .margin({ left: 8 })
        .onClick(() => {
          Feedback.tap();
          this.removeWd(h);
        })
    }
    .width('100%')
    .height(56)
    .padding({ left: 14, right: 14 })
    .borderRadius(T.RADIUS_SM)
    .backgroundColor(this.hi('w_' + h.srcId + '_' + h.vodName) ? T.CARD_HI : T.CARD)
    .border({ width: T.BORDER, color: this.hi('w_' + h.srcId + '_' + h.vodName) ? T.TXT : '#00000000' })
    .margin({ bottom: 8 })
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
    .focusable(true)
    .onFocus(() => this.hover('w_' + h.srcId + '_' + h.vodName, true))
    .onBlur(() => this.hover('w_' + h.srcId + '_' + h.vodName, false))
    .onHover((hv: boolean) => this.hover('w_' + h.srcId + '_' + h.vodName, hv))
  }

  async clearWd(): Promise<void> {
    await Store.clearWdHistory();
    this.wdHist = [];
  }

  @Builder
  browseView() {
    Column() {
      Row() {
        this.Btn('识别影视', 'scan', true, () => {
          this.scanVods();
        })
        this.Btn('上级目录', 'up', false, () => {
          this.goUp();
        })
        this.Btn('刷新', 'refresh', false, () => {
          this.loadDir();
        })
        Blank()
      }
      .width('100%')
      .margin({ top: 8, bottom: 12 })

      if (this.loading) {
        Row() {
          LoadingProgress().width(24).height(24).color(T.SUB)
          Text('加载中…').fontSize(14).fontColor(T.DIM).margin({ left: 10 })
        }
        .width('100%').margin({ top: 20 })
      } else if (this.entries.length === 0) {
        Text(this.msg.length > 0 ? this.msg : '这个目录是空的。')
          .fontSize(14).fontColor(this.msgColor).width('100%').margin({ top: 16 }).lineHeight(22)
      } else {
        ForEach(this.entries, (e: WebdavEntry, i: number) => {
          this.RowItem(
            'f_' + i,
            (e.isDir ? '📁 ' : '🎬 ') + e.name,
            e.isDir ? '目录' : (WebdavPage.sizeLabel(e.size) + (e.mtime.length > 0 ? ' · ' + e.mtime : '')),
            e.isDir ? '进入' : '播放',
            () => {
              if (e.isDir) {
                this.enterDir(e);
              } else if (Webdav.isVideo(e.name)) {
                this.playFile(e);
              }
            })
        }, (e: WebdavEntry, i: number) => e.href + i)
      }
    }
  }

  @Builder
  scanView() {
    Column() {
      Row() {
        this.Btn('浏览文件', 'browse', false, () => {
          this.openBrowse();
        })
        this.Btn('重新扫描', 'rescan', true, () => {
          this.scanVods();
        })
        Blank()
      }
      .width('100%')
      .margin({ top: 8, bottom: 12 })

      if (this.loading) {
        Column() {
          Row() {
            LoadingProgress().width(24).height(24).color(T.SUB)
            Text('扫描中…').fontSize(14).fontColor(T.DIM).margin({ left: 10 })
          }
          if (this.msg.length > 0) {
            Text(this.msg).fontSize(13).fontColor(T.DIM).width('100%').margin({ top: 10 }).lineHeight(20)
          }
        }
        .width('100%').margin({ top: 20 })
      } else if (this.vods.length === 0) {
        Text(this.msg.length > 0 ? this.msg : '没有识别到视频资源。')
          .fontSize(14).fontColor(this.msgColor).width('100%').margin({ top: 16 }).lineHeight(22)
      } else {
        ForEach(this.vods, (v: WebdavVod, i: number) => {
          this.RowItem('v_' + i, v.name, this.vodMeta(v), '播放', () => {
            this.openEp(v);
          })
        }, (v: WebdavVod, i: number) => v.name + i)
      }
    }
  }

  @Builder
  epPanel() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor(T.BLACK_70)
        .onClick(() => {
          Feedback.tap();
          this.epOpen = false;
        })

      Column() {
        Row() {
          Text(this.selVod.name).fontSize(19).fontColor(T.TXT).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Blank()
          Text('✕').fontSize(19).fontColor(this.hi('ex') ? T.TXT : T.SUB)
            .width(42).height(42).textAlign(TextAlign.Center).borderRadius(T.RADIUS_SM)
            .backgroundColor(this.hi('ex') ? T.CARD_HI : '#00000000')
            .focusable(true).defaultFocus(true)
            .onFocus(() => this.hover('ex', true))
            .onBlur(() => this.hover('ex', false))
            .onHover((hv: boolean) => this.hover('ex', hv))
            .onClick(() => {
              Feedback.tap();
              this.epOpen = false;
            })
        }
        .width('100%')

        Scroll() {
          Column() {
            ForEach(this.selVod.eps, (ep: WebdavEp, i: number) => {
              this.RowItem('ep_' + i, this.epNameOf(this.selVod, ep, i), '', '播放', () => {
                this.playEp(this.selVod, i);
              })
            }, (ep: WebdavEp, i: number) => ep.href + i)
          }
          .width('100%')
        }
        .width('100%')
        .height(this.isPhone ? 320 : 360)
        .margin({ top: 14 })
        .scrollBar(BarState.Off)
      }
      .width(Device.panelW(520))
      .padding(24)
      .backgroundColor(T.SURFACE)
      .borderRadius(28)
      .alignItems(HorizontalAlign.Start)
      .focusScopeId('ep_panel', true)
    }
    .width('100%')
    .height('100%')
  }

  vodMeta(v: WebdavVod): string {
    return (v.kind === 'series' ? '剧集 · ' : '电影 · ') +
      (v.year.length > 0 ? v.year + ' · ' : '') + v.eps.length + ' 集';
  }

  static sizeLabel(size: number): string {
    if (size <= 0) {
      return '';
    }
    if (size >= 1024 * 1024 * 1024) {
      return (size / 1024 / 1024 / 1024).toFixed(2) + ' GB';
    }
    if (size >= 1024 * 1024) {
      return (size / 1024 / 1024).toFixed(1) + ' MB';
    }
    if (size >= 1024) {
      return (size / 1024).toFixed(0) + ' KB';
    }
    return size + ' B';
  }

  static fmtPos(ms: number): string {
    if (ms <= 0) {
      return '0:00';
    }
    const t: number = Math.floor(ms / 1000);
    const h: number = Math.floor(t / 3600);
    const m: number = Math.floor((t % 3600) / 60);
    const s: number = t % 60;
    const mm: string = (m < 10 ? '0' : '') + m;
    const ss: string = (s < 10 ? '0' : '') + s;
    return h > 0 ? (h + ':' + mm + ':' + ss) : (mm + ':' + ss);
  }
}
