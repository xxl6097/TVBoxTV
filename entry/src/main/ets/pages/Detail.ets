import { Feedback } from '../common/Feedback';
import router from '@ohos.router';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';
import { Store, FavItem, HistItem } from '../common/Store';
import { Site, DetailParam, PlayParam, Vod, VodPage, Line, Episode, T } from '../common/Model';
import { Cms } from '../common/Cms';
import { Playlist } from '../common/Playlist';
import { Tip, TIP_MSG, TipLayer } from '../common/Tip';
import { KEY_IS_PHONE } from '../common/Device';
import { Theme, KEY_THEME } from '../common/Theme';
import { Poster } from '../common/Poster';
import { Pointer } from '../common/Pointer';
import { ArraySource } from '../common/DataSource';

/** 剧集网格：整宽 8 列，单项高 46、间距 10。epsHeight() 靠这三个数算总高 */
const EPS_COLS: number = 8;
const EPS_COLS_T: string = '1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr';
const EPS_H: number = 46;
const EPS_GAP: number = 10;
/** 剧集网格最多一次显示几行，超过就让它自己滚（198 集 = 25 行，整页拖着滚太累） */
const EPS_MAX_ROWS: number = 4;

@Entry
@Component
struct Detail {
  @StorageProp(KEY_IS_PHONE) isPhone: boolean = false;
  /** 当前主题。build 里必须用到（见 .id），否则换了色板不会重绘 */
  @StorageProp(KEY_THEME) themeMode: string = 'dark';
  /** 相关推荐：同分类第一页里除去当前这部 */
  @State related: Vod[] = [];
  @State vod: Vod = new Vod();
  @State lines: Line[] = [];
  @State lineIdx: number = 0;
  @State loading: boolean = true;
  @State err: string = '';
  @State fav: boolean = false;
  /** 全局轻提示，绑 AppStorage 上的 TIP_MSG，由 Tip.show() 触发 */
  @StorageLink(TIP_MSG) tipMsg: string = '';
  @State focusKey: string = '';
  /** 简介是否展开。默认只显示 3 行，长简介点「展开全部」看全 */
  @State fullIntro: boolean = false;
  /** 剧集是否从新到旧排序。追更的人通常只想点最新一集 */
  @State epDesc: boolean = false;
  /** 上次看到第几集（-1 表示没看过） */
  @State seen: number = -1;
  /** 上次看到第几毫秒（用于续播提示显示百分比） */
  @State seenPos: number = 0;
  /** 上次那一集的总时长（用于算百分比） */
  @State seenDur: number = 0;
  /** 续播提示弹窗是否显示 */
  @State showResume: boolean = false;
  /** 续播提示自动消失计时器 */
  private resumeTimer: number = -1;
  /**
   * 剧集定位后，已看那集短暂闪亮（高对比度边框），帮助用户在网格里快速找到进度。
   * locateSeen() 完成后置 true，1.5s 后回 false。
   */
  @State seenPulse: boolean = false;

  /** 剧集网格的滚动控制器：进页面要自动滚到「上次看到」那一集 */
  private epScroller: Scroller = new Scroller();
  /**
   * 剧集网格的数据源（LazyForEach）。
   *
   * 原来 Grid 里是 `ForEach(this.epsView())`：200 集的剧一次建 200 个 GridItem，
   * 每个还带边框/动画/两组事件，进详情页会明显顿一下。改成 LazyForEach 后
   * 只建可视区 + cachedCount 范围内的，滚动时边回收边建。
   *
   * 数据是「成片替换」的（加载完成 / 切线路 / 切正倒序），所以统一走 syncEps()，
   * 不需要逐条 notify。
   */
  private epSrc: ArraySource<Episode> = new ArraySource<Episode>();
  /** 集数，驱动空态与「网格要不要自己滚」的判断（数据源本身不是状态变量） */
  @State epCount: number = 0;
  /** 只自动定位一次，用户手动滚走之后不再抢回焦点 */
  private located: boolean = false;

  private siteKey: string = '';
  private siteName: string = '';
  private vodId: string = '';

  async aboutToAppear(): Promise<void> {
    await Store.init(getContext(this) as common.UIAbilityContext);
    const p = router.getParams() as DetailParam;
    if (p !== null && p !== undefined) {
      this.siteKey = p.siteKey;
      this.siteName = p.siteName;
      this.vodId = p.vodId;
    }
    this.fav = await Store.isFavorite(this.siteKey, this.vodId);
    await this.loadSeen();
    await this.load();
  }

  /**
   * 从播放页回来时刷新「上次看到第几集」。
   *
   * 原来只在 aboutToAppear 里读一次历史，于是「看完第 11 集 → 返回」后，
   * 标题还写着上次的集数、高亮也还停在旧的那集，只有杀掉页面重进才对。
   * 这里在每次页面显示时对一下，集数变了就更新高亮并重新定位。
   */
  onPageShow(): void {
    const before: number = this.seen;
    this.loadSeen().then(() => {
      if (this.seen !== before && this.seen >= 0) {
        this.located = false;      // 集数变了，允许再定位一次
        this.locateSeen();
      }
    });
  }

  /** 从播放历史里捞出本片上次看到第几集，同时记录进度用于续播提示 */
  async loadSeen(): Promise<void> {
    const h: HistItem[] = await Store.history();
    for (let i = 0; i < h.length; i++) {
      if (h[i].siteKey === this.siteKey && h[i].vodId === this.vodId) {
        this.seen = h[i].epIndex;
        this.seenPos = h[i].pos;
        this.seenDur = h[i].dur;
        return;
      }
    }
  }

  /**
   * 续播提示：仅在首次进入且有有效历史进度（>5s，且未接近结尾）时显示。
   * 5 秒后自动消失（用户未操作时不打扰）。
   */
  private triggerResumePrompt(): void {
    // 条件：看过 + 进度 > 5s + 未到结尾（距结尾 > 15s）
    if (this.seen < 0) {
      return;
    }
    if (this.seenPos <= 5000) {
      return;
    }
    if (this.seenDur > 0 && this.seenPos >= this.seenDur - 15000) {
      return; // 接近结尾，不提示续播（下次应该看新集）
    }
    this.showResume = true;
    /**
     * 不再自动消失（原来 5 秒后 setTimeout 关掉）。
     *
     * 用户从「继续观看」进来，往往还在看简介/选集，5 秒一到续播入口就没了，
     * 只能自己去选集里找到看过的那一集 —— 等于这个功能白做。
     * 现在一直留着，靠「取消」或直接点某一集关掉。
     */
    if (this.resumeTimer >= 0) {
      clearTimeout(this.resumeTimer);
      this.resumeTimer = -1;
    }
  }

  /**
   * 「继续播放」按钮。
   *
   * 实心白底 + 深色字，是详情页里唯一的强按钮 —— 用户进详情页八成就是想接着看，
   * 这个动作应该一眼可见、一下就能点到，而不是在浮层里找。
   */
  @Builder
  ResumeBtn() {
    Row() {
      Text('▶')
        .fontSize(15)
        .fontColor(T.BG)
        .margin({ right: 8 })
      Text('继续播放')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(T.BG)
    }
    .padding({ left: 22, right: 22, top: 12, bottom: 12 })
    .borderRadius(T.RADIUS_PILL)
    .backgroundColor(this.hi('res_go') ? T.SELECTED : T.TXT)
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
    .focusable(true)
    .onFocus(() => this.hoverTo('res_go', true))
    .onBlur(() => this.hoverTo('res_go', false))
    .onHover((hv: boolean) => this.hoverTo('res_go', hv))
    .onClick(() => Pointer.fire('res_go', () => {
      Feedback.tap();
      this.doResume();
    }))
    .onMouse(Pointer.on('res_go', () => {
      Feedback.tap();
      this.doResume();
    }))
  }

  /** 执行续播：跳到上次那一集，play() 内部会按历史里的位置接着播 */
  private doResume(): void {
    if (this.lines.length === 0) {
      return;
    }
    const eps: Episode[] = this.lines[this.lineIdx].eps;
    if (this.seen < 0 || this.seen >= eps.length) {
      Tip.show('上次那一集已经不在这条线路里了，请手动选集');
      return;
    }
    hilog.info(0x1000, 'BOXN', 'detail resume ep=%{public}d pos=%{public}d',
      this.seen, this.seenPos);
    // 收起浮层，避免和刚刚的操作重复
    this.showResume = false;
    this.play(eps[this.seen], this.seen);
  }

  /** 续播提示的百分比字符串（如「67%」）；进度未知时返回空串 */
  private resumePercent(): string {
    if (this.seenDur <= 0 || this.seenPos <= 0) {
      return '';
    }
    const pct: number = Math.round((this.seenPos / this.seenDur) * 100);
    return pct + '%';
  }

  /**
   * 是否可以续播（决定详情页顶部那条「继续播放」是否出现）。
   *
   * 判据和 triggerResumePrompt 保持一致：看过、进度 > 5 秒、且没到片尾。
   * 到片尾（距结尾 15 秒内）说明这集看完了，再给续播没意义，
   * 应该直接开始下一集。
   */
  private canResume(): boolean {
    if (this.seen < 0 || this.seenPos <= 5000) {
      return false;
    }
    if (this.seenDur > 0 && this.seenPos >= this.seenDur - 15000) {
      return false;
    }
    return true;
  }

  /**
   * 续播按钮右侧的位置信息，如「第 6 集 · 23:45 / 25:10 · 94%」。
   *
   * 用户要的是「一眼知道上次停在哪」，所以三样都给：
   * 哪一集、具体时间点、以及占比。只有百分比的话，25 分钟的片子里
   * 「94%」远不如「23:45」直观。
   */
  private resumeSummary(): string {
    const parts: string[] = [];
    parts.push('第 ' + (this.seen + 1) + ' 集');
    if (this.seenPos > 0) {
      if (this.seenDur > 0) {
        parts.push(this.fmtMs(this.seenPos) + ' / ' + this.fmtMs(this.seenDur));
      } else {
        parts.push(this.fmtMs(this.seenPos));
      }
    }
    const pct: string = this.resumePercent();
    if (pct.length > 0) {
      parts.push(pct);
    }
    return parts.join('  ·  ');
  }

  /** 格式化毫秒为 mm:ss */
  private fmtMs(ms: number): string {
    const sec: number = Math.floor(ms / 1000);
    const m: number = Math.floor(sec / 60);
    const s: number = sec % 60;
    return (m < 10 ? '0' + m : '' + m) + ':' + (s < 10 ? '0' + s : '' + s);
  }

  /** 当前线路的剧集，按用户选的顺序返回 */
  epsView(): Episode[] {
    if (this.lines.length === 0 || this.lineIdx >= this.lines.length) {
      return [];
    }
    const src: Episode[] = this.lines[this.lineIdx].eps;
    if (!this.epDesc) {
      return src;
    }
    const out: Episode[] = [];
    for (let i = src.length - 1; i >= 0; i--) {
      out.push(src[i]);
    }
    return out;
  }

  /** 把当前（线路 + 正/倒序）下的剧集推给 LazyForEach 数据源 */
  private syncEps(): void {
    const list: Episode[] = this.epsView();
    this.epCount = list.length;
    this.epSrc.set(list);
  }

  /** 按 url 反查真实集数下标（倒序显示时不能直接用显示位置） */
  realIdx(ep: Episode): number {
    if (this.lines.length === 0 || this.lineIdx >= this.lines.length) {
      return 0;
    }
    const src: Episode[] = this.lines[this.lineIdx].eps;
    for (let i = 0; i < src.length; i++) {
      if (src[i].url === ep.url) {
        return i;
      }
    }
    return 0;
  }

  /**
   * 拉同分类的其它片子做「相关推荐」。
   *
   * 只取第 1 页并在前端去掉自己：采集站的详情接口不返回「同类」，
   * 用详情里的 type_id 反查列表是唯一稳妥的办法（不用猜标签、也不用额外接口）。
   * 失败静默——推荐位空着不影响主内容。
   */
  /** 点推荐位：push 一个新的详情页（返回能逐层退，比 replace 符合直觉） */
  openRelated(v: Vod): void {
    const p = new DetailParam();
    p.siteKey = v.siteKey.length > 0 ? v.siteKey : this.siteKey;
    p.siteName = v.siteName.length > 0 ? v.siteName : this.vod.siteName;
    p.vodId = v.id;
    router.pushUrl({ url: 'pages/Detail', params: p });
  }

  async loadRelated(s: Site, typeId: string): Promise<void> {
    if (typeId.length === 0) {
      return;
    }
    try {
      const cms = new Cms(s);
      const pg: VodPage = await cms.list(typeId, 1);
      const out: Vod[] = [];
      for (let i = 0; i < pg.items.length && out.length < 12; i++) {
        const v: Vod = pg.items[i];
        if (v.id === this.vodId) {
          continue;
        }
        out.push(v);
      }
      this.related = out;
    } catch (e) {
      hilog.info(0x1000, 'BOXN', 'related load failed: %{public}s', (e as Error).message);
    }
  }

  async load(): Promise<void> {
    const s: Site | null = Store.site(this.siteKey);
    if (s === null) {
      this.err = '数据源不存在';
      this.loading = false;
      return;
    }
    this.loading = true;
    this.err = '';
    try {
      const cms = new Cms(s);
      const v: Vod = await cms.detail(this.vodId);
      if (v.siteName.length === 0) {
        v.siteName = s.name;
      }
      this.vod = v;
      this.lines = Cms.splitLines(v.from, v.playUrl);
      // 推荐是锦上添花，不 await：主内容先渲染，推荐晚一两秒出来没关系
      this.loadRelated(s, v.typeId);
      // 默认落在「能直接播」的那条线路上：很多采集站第一组是网页地址，
      // 播放器拿到会播不出来，真流在后面的 /index.m3u8 那组
      this.lineIdx = 0;
      for (let i = 0; i < this.lines.length; i++) {
        if (this.lines[i].direct) {
          this.lineIdx = i;
          break;
        }
      }
      // 用户在这部片子上手动选过线路就沿用他选的，别再退回收视最差的默认线
      const savedLine: number = await Store.linePref(this.siteKey, this.vodId);
      if (savedLine >= 0 && savedLine < this.lines.length) {
        this.lineIdx = savedLine;
      }
      if (this.lines.length === 0) {
        this.err = '该片没有可播放的剧集地址';
      }
      this.syncEps();
    } catch (err) {
      const e = err as Error;
      this.err = e.message;
    } finally {
      this.loading = false;
      // 剧集节点这一刻才真正生成，等一帧再滚，否则 scroller 还没有可滚内容
      this.locateSeen();
      // 有历史进度时弹出续播提示
      this.triggerResumePrompt();
    }
  }

  async toggleFav(): Promise<void> {
    const f = new FavItem();
    f.siteKey = this.siteKey;
    f.siteName = this.vod.siteName.length > 0 ? this.vod.siteName : this.siteName;
    f.vodId = this.vodId;
    f.name = this.vod.name;
    f.pic = this.vod.pic;
    this.fav = await Store.toggleFavorite(f);
    Tip.show(this.fav ? '已加入收藏' : '已取消收藏');
  }

  async play(ep: Episode, idx: number): Promise<void> {
    if (this.lines.length === 0) {
      return;
    }
    const line: Line = this.lines[this.lineIdx];
    const p = new PlayParam();
    p.url = ep.url;
    p.title = this.vod.name + ' ' + ep.name;
    p.siteKey = this.siteKey;
    p.vodId = this.vodId;
    p.from = line.name;
    p.epIndex = idx;

    // 续播：同一集上次看到哪就接着播；换集则从头开始。
    // 以前这里无条件写 pos = 0，于是「拖到 20 分钟 → 返回详情 → 再点同一集」会从 0 开始，
    // 并且把历史里的进度一并清零（首页「继续观看」也跟着退回 00:00）。
    let resume: number = 0;
    let resumeDur: number = 0;
    const hist: HistItem[] = await Store.history();
    for (let i = 0; i < hist.length; i++) {
      const it: HistItem = hist[i];
      if (it.siteKey === this.siteKey && it.vodId === this.vodId && it.epIndex === idx) {
        // 太靠前（<5 秒）没意义；太靠后（离结尾 <15 秒）续播等于一进去就结束，都不续
        if (it.pos > 5000 && (it.dur <= 0 || it.pos < it.dur - 15000)) {
          resume = it.pos;
          resumeDur = it.dur;
        }
        break;
      }
    }

    const h = new HistItem();
    h.siteKey = this.siteKey;
    h.siteName = this.vod.siteName.length > 0 ? this.vod.siteName : this.siteName;
    h.vodId = this.vodId;
    h.name = this.vod.name;
    h.pic = this.vod.pic;
    h.epName = ep.name;
    h.epIndex = idx;
    h.from = line.name;
    h.pos = resume;
    h.dur = resumeDur;      // 时长要等播放器 prepared 之后才知道
    h.time = Date.now();
    await Store.pushHistory(h);
    p.seek = resume;

    // 把整条线路的剧集交给播放页，遥控器上才能直接切上/下一集
    Playlist.set(line.eps, idx, this.vod.name);

    router.pushUrl({ url: 'pages/Player', params: p });
  }

  /** 灵犀遥控器是指针模式，高亮靠 hover 驱动 */
  hoverTo(key: string, isHover: boolean): void {
    if (isHover) {
      this.focusKey = key;
    } else if (this.focusKey === key) {
      this.focusKey = '';
    }
  }

  hi(key: string): boolean {
    return this.focusKey === key;
  }

  onBackPress(): boolean {
    router.back();
    return true;
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('‹').fontSize(40).fontColor(this.hi('back') ? T.TXT : T.SUB).width(40)
            .focusable(true)
            .defaultFocus(true)
            .onFocus(() => this.hoverTo('back', true))
            .onBlur(() => this.hoverTo('back', false))
            .onHover((hv: boolean) => this.hoverTo('back', hv))
            .onClick(() => Pointer.fire('d_back', () => { Feedback.tap(); router.back(); }))
            .onMouse(Pointer.on('d_back', () => { Feedback.tap(); router.back(); }))
          Text(this.vod.name.length > 0 ? this.vod.name : '详情')
            .fontSize(24).fontColor(T.TXT)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Text(this.fav ? '★ 已收藏' : '☆ 收藏')
            .fontSize(16).height(40).padding({ left: 12, right: 12 })
            .textAlign(TextAlign.Center)
            .borderRadius(T.RADIUS_SM)
            .backgroundColor(this.hi('fav') ? T.CARD_HI : T.CARD)
            // color/text.xml：selected 才变 yellow_500
            .fontColor(this.fav ? T.SELECTED : T.TXT)
            .border({ width: T.BORDER, color: this.hi('fav') ? T.TXT : '#00000000' })
            .animation({ duration: T.ANIM, curve: Curve.EaseOut })
            .focusable(true)
            .onFocus(() => this.hoverTo('fav', true))
            .onBlur(() => this.hoverTo('fav', false))
            .onHover((hv: boolean) => this.hoverTo('fav', hv))
            .onClick(() => Pointer.fire('d_fav', () => { Feedback.tap(); this.toggleFav(); }))
            .onMouse(Pointer.on('d_fav', () => { Feedback.tap(); this.toggleFav(); }))
        }
        .width('100%')
        .padding({ left: 24, right: 24, top: 24, bottom: 12 })

        if (this.loading) {
          Column() {
            LoadingProgress().width(50).height(50).color(T.ACCENT)
            Text('读取详情…').fontSize(17).fontColor(T.SUB).margin({ top: 12 })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          /**
           * 整页统一纵向滚动。
           *
           * 改之前是「右侧 Column 里放简介 + 一个 layoutWeight(1) 的剧集 Grid」：
           * Column 高度被父 Row 钉死，简介一长（展开全部时 14 行）就把空间吃光，
           * Grid 分到 0 高度 —— 实测简介的 bounds 一直延伸到 [2748,1280]，
           * 剧集整块看不见也够不到，滑也滑不动（它压根没有可用高度）。
           *
           * 现在只有一层滚动容器：简介、线路、剧集都在里面排，内容多就整体往下滚。
           * 剧集网格改到整宽 8 列，并按行数把高度算准（见 epsHeight），
           * 它自己不滚，交给外层 Scroll，避免同方向嵌套滚动互相抢手势。
           */
          Scroll() {
            Column() {
              Row() {
                // 左：海报。屏幕只有 366vp 高，海报不能按 240×340 摆，否则一屏装不下
                Column() {
                  Poster({ url: this.vod.pic, w: this.isPhone ? 120 : 200, h: this.isPhone ? 169 : 282, radius: 12 })
                  Text(this.vod.siteName).fontSize(13).fontColor(T.DIM).margin({ top: 10 })
                }
                .width(this.isPhone ? 140 : 232)
                .alignItems(HorizontalAlign.Start)

                // 右：元信息 + 简介 + 线路
                Column() {
                  Text(this.metaLine()).fontSize(16).fontColor(T.SUB)
                    .width('100%').maxLines(this.isPhone ? 4 : 2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  // 演员可点击标签（点击搜索该演员）
                  if (this.vod.actor.length > 0) {
                    Row() {
                      Text('主演').fontSize(14).fontColor(T.DIM).margin({ right: 8 })
                        .flexShrink(0)
                      Flex({ wrap: FlexWrap.Wrap }) {
                        ForEach(this.actors(), (a: string) => {
                          Text(a)
                            .fontSize(14)
                            .fontColor(this.hi('act_' + a) ? T.SELECTED : T.ACCENT)
                            .backgroundColor(this.hi('act_' + a) ? T.CARD_HI : T.CARD)
                            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                            .borderRadius(T.RADIUS_SM)
                            .margin({ right: 8, bottom: 6 })
                            .onHover((hv: boolean) => this.hoverTo('act_' + a, hv))
                            .onClick(() => Pointer.fire('act_' + a, () => {
                              Feedback.tap();
                              this.searchActor(a);
                            }))
                            .onMouse(Pointer.on('act_' + a, () => {
                              Feedback.tap();
                              this.searchActor(a);
                            }))
                        }, (a: string) => a)
                      }
                      .layoutWeight(1)
                    }
                    .width('100%').margin({ top: 6 }).alignItems(VerticalAlign.Top)
                  }
                  Text(this.vod.content.length > 0 ? this.vod.content : '暂无简介')
                    .fontSize(16).fontColor(T.SUB).lineHeight(25)
                    .width('100%')
                    // 展开后不再靠 maxLines 截断，交给外层 Scroll 滚动
                    .maxLines(this.fullIntro ? 200 : 3)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 10 })
                  if (this.vod.content.length > 60) {
                    Text(this.fullIntro ? '收起' : '展开全部')
                      .fontSize(15).fontColor(this.hi('intro') ? T.TXT : T.ACCENT)
                      .padding({ top: 4, bottom: 4 })
                      .focusable(true)
                      .onFocus(() => this.hoverTo('intro', true))
                      .onBlur(() => this.hoverTo('intro', false))
                      .onHover((hv: boolean) => this.hoverTo('intro', hv))
                      .onClick(() => Pointer.fire('d_intro', () => {
                          Feedback.tap();
                          this.fullIntro = !this.fullIntro;
                          Tip.show(this.fullIntro ? '简介已展开，可上下滚动查看' : '简介已收起');
                      }))
                      .onMouse(Pointer.on('d_intro', () => {
                          Feedback.tap();
                          this.fullIntro = !this.fullIntro;
                          Tip.show(this.fullIntro ? '简介已展开，可上下滚动查看' : '简介已收起');
                      }))
                  }

                  if (this.err.length > 0) {
                    Text(this.err).fontSize(17).fontColor(T.WARN).margin({ top: 14 })
                  }

                  /**
                   * 续播行：一颗「继续播放」按钮 + 上次看到的位置。
                   *
                   * 放在简介下面、线路上面 —— 这是进入详情页后视线自然落到的位置，
                   * 比原来那个左下角的浮层显眼得多（浮层还常被简介/选集挤到看不见）。
                   *
                   * 手机上按钮和信息分两行：竖屏宽度只有 360vp 左右，
                   * 「继续播放」+「第 6 集 · 23:45 / 25:10 · 94%」并排会挤成一团。
                   * 电视横屏空间够，按钮和信息左右并排更紧凑。
                   */
                  if (this.canResume()) {
                    if (this.isPhone) {
                      Column() {
                        this.ResumeBtn()
                        Text(this.resumeSummary())
                          .fontSize(13).fontColor(T.DIM)
                          .width('100%')
                          .margin({ top: 8 })
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .width('100%')
                      .alignItems(HorizontalAlign.Start)
                      .margin({ top: 16 })
                    } else {
                      Row() {
                        this.ResumeBtn()
                        Text(this.resumeSummary())
                          .fontSize(14).fontColor(T.DIM)
                          .layoutWeight(1)
                          .margin({ left: 14 })
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)
                      .margin({ top: 16 })
                    }
                  }

                  // 线路
                  if (this.lines.length > 1) {
                    Row() {
                      Text('线路').fontSize(16).fontColor(T.DIM).margin({ right: 12 })
                      List({ space: 10 }) {
                        ForEach(this.lines, (l: Line, i: number) => {
                          ListItem() {
                            Text(l.name + (l.direct ? '' : ' ·需解析'))
                              .fontSize(16)
                              // adapter_flag.xml：selector_item + color/text
                              .fontColor(this.lineIdx === i ? T.SELECTED : (l.direct ? T.TXT : T.WARN))
                              .backgroundColor(this.lineIdx === i || this.hi('ln' + i) ? T.CARD_HI : T.CARD)
                              .height(40).padding({ left: 12, right: 12 }).borderRadius(T.RADIUS_SM)
                              .border({
                                width: T.BORDER,
                                color: this.hi('ln' + i) ? T.TXT : '#00000000'
                              })
                              .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                              .onHover((hv: boolean) => this.hoverTo('ln' + i, hv))
                              .focusable(true)
                              .onFocus(() => this.hoverTo('ln' + i, true))
                              .onBlur(() => this.hoverTo('ln' + i, false))
                              .onClick(() => Pointer.fire('d_line' + i, () => {
                                  Feedback.tap();
                                  this.lineIdx = i;
                                  this.syncEps();
                                  Store.setLinePref(this.siteKey, this.vodId, i).catch(() => {});
                                  Tip.show('已切到线路：' + l.name);
                              }))
                              .onMouse(Pointer.on('d_line' + i, () => {
                                  Feedback.tap();
                                  this.lineIdx = i;
                                  this.syncEps();
                                  Store.setLinePref(this.siteKey, this.vodId, i).catch(() => {});
                                  Tip.show('已切到线路：' + l.name);
                              }))
                          }
                        }, (l: Line, i: number) => 'l' + i + l.name)
                      }
                      .listDirection(Axis.Horizontal)
                      .height(48).layoutWeight(1).scrollBar(BarState.Off)
                    }
                    .width('100%').margin({ top: 14 })
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 24 })
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)

              // 剧集：整宽 8 列，纵向空间比塞在右半边时省一半
              if (this.lines.length > 0) {
                Row() {
                  Text('剧集').fontSize(18).fontColor(T.TXT)
                  Text('共 ' + this.lines[this.lineIdx].eps.length + ' 集')
                    .fontSize(15).fontColor(T.DIM).margin({ left: 12 })
                  if (this.epsScrollable()) {
                    Text('· 可上下滚动查看更多')
                      .fontSize(14).fontColor(T.DIM).margin({ left: 8 })
                  }
                  if (this.seen >= 0) {
                    Text('上次看到第 ' + (this.seen + 1) + ' 集')
                      .fontSize(15).fontColor(T.ACCENT).margin({ left: 12 })
                  }
                  Blank()
                  Text(this.epDesc ? '倒序' : '正序')
                    .fontSize(15).fontColor(this.hi('ord') ? T.SELECTED : T.SUB)
                    .backgroundColor(this.hi('ord') ? T.CARD_HI : T.CARD)
                    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                    .borderRadius(T.RADIUS_SM)
                    .border({ width: T.BORDER, color: this.hi('ord') ? T.TXT : '#00000000' })
                    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                    .focusable(true)
                    .onFocus(() => this.hoverTo('ord', true))
                    .onBlur(() => this.hoverTo('ord', false))
                    .onHover((hv: boolean) => this.hoverTo('ord', hv))
                    .onClick(() => Pointer.fire('d_epdesc', () => { Feedback.tap(); this.epDesc = !this.epDesc; this.syncEps(); }))
                    .onMouse(Pointer.on('d_epdesc', () => { Feedback.tap(); this.epDesc = !this.epDesc; this.syncEps(); }))
                }
                .width('100%').margin({ top: 20, bottom: 10 })

                Grid(this.epScroller) {
                  LazyForEach(this.epSrc, (ep: Episode) => {
                    GridItem() {
                      Text(ep.name)
                        .fontSize(16)
                        // adapter_episode.xml：selector_item(4dp 圆角) + color/text
                        .fontColor(this.realIdx(ep) === this.seen ? T.SELECTED : T.TXT)
                        .backgroundColor(this.realIdx(ep) === this.seen || this.hi('e' + this.realIdx(ep)) ?
                          T.CARD_HI : T.CARD)
                        .height(EPS_H).width('100%')
                        .textAlign(TextAlign.Center)
                        .borderRadius(T.RADIUS_SM)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .border({
                          width: this.realIdx(ep) === this.seen && this.seenPulse ? 2 : T.BORDER,
                          color: this.realIdx(ep) === this.seen && this.seenPulse ? T.ACCENT
                            : (this.hi('e' + this.realIdx(ep)) ? T.TXT : '#00000000')
                        })
                        .animation({ duration: 400, curve: Curve.EaseInOut })
                        .onHover((hv: boolean) => this.hoverTo('e' + this.realIdx(ep), hv))
                        .focusable(true)
                        .onFocus(() => this.hoverTo('e' + this.realIdx(ep), true))
                        .onBlur(() => this.hoverTo('e' + this.realIdx(ep), false))
                        .onClick(() => Pointer.fire('d_ep' + this.realIdx(ep), () => { Feedback.tap(); this.play(ep, this.realIdx(ep)); }))
                        .onMouse(Pointer.on('d_ep' + this.realIdx(ep), () => { Feedback.tap(); this.play(ep, this.realIdx(ep)); }))
                    }
                  }, (ep: Episode) => 'e' + ep.url + (this.epDesc ? 'd' : 'a'))
                }
                .columnsTemplate(this.epsColsT())
                .columnsGap(EPS_GAP)
                .rowsGap(EPS_GAP)
                // 预建可视区上下各 20 个：滚动时不会出现「白块等着建」的顿感，
                // 又不至于像 ForEach 那样一次把 200 集全建出来
                .cachedCount(20)
                .width('100%')
                // 行数少时高度按内容算准（不留空白），行数多时封顶 4 行自己滚
                .height(this.epsBoxHeight())
                // 内层先滚、到顶/到底再把手势交给外层 Scroll，两级都顺
                .nestedScroll({
                  scrollForward: NestedScrollMode.SELF_FIRST,
                  scrollBackward: NestedScrollMode.SELF_FIRST
                })
                .scrollBar(this.epsScrollable() ? BarState.Auto : BarState.Off)
              }

              // 相关推荐：同分类里除去自己的片子，横向一排。
              // 放在剧集下面——「这部看完看什么」是看完剧集列表才会想到的问题
              if (this.related.length > 0) {
                Row() {
                  Text('相关推荐').fontSize(18).fontColor(T.TXT)
                  Text('· 同分类').fontSize(13).fontColor(T.DIM).margin({ left: 8 })
                }
                .width('100%')
                .margin({ top: 18, bottom: 10 })

                List({ space: 14 }) {
                  ForEach(this.related, (v: Vod) => {
                    ListItem() {
                      Column() {
                        Poster({ url: v.pic, w: 104, h: 146 })
                        Text(v.name)
                          .fontSize(14).fontColor(T.TXT)
                          .width(104).maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .margin({ top: 5 })
                      }
                      .padding(6)
                      .borderRadius(10)
                      .backgroundColor(this.hi('rel' + v.id) ? T.CARD_HI : '#00000000')
                      .border({ width: T.BORDER, color: this.hi('rel' + v.id) ? T.ACCENT : '#00000000' })
                      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                      .focusable(true)
                      .onFocus(() => this.hoverTo('rel' + v.id, true))
                      .onBlur(() => this.hoverTo('rel' + v.id, false))
                      .onHover((hv: boolean) => this.hoverTo('rel' + v.id, hv))
                      .onClick(() => Pointer.fire('d_rel' + v.id, () => {
                          Feedback.tap();
                          this.openRelated(v);
                      }))
                      .onMouse(Pointer.on('d_rel' + v.id, () => {
                          Feedback.tap();
                          this.openRelated(v);
                      }))
                    }
                  }, (v: Vod) => 'rel' + v.id)
                }
                .listDirection(Axis.Horizontal)
                .width('100%')
                .height(196)
                .scrollBar(BarState.Off)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 24, right: 24, bottom: 24 })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(T.pageBg(this.themeMode))

      if (this.tipMsg.length > 0) {
        TipLayer({ msg: this.tipMsg })
      }

      // 续播提示浮层：有进度记录时短暂显示，自动 5s 消失
      if (this.showResume) {
        Column() {
          Column() {
            Text('继续观看')
              .fontSize(16).fontColor(T.TXT).fontWeight(FontWeight.Medium)
            Text('第 ' + (this.seen + 1) + ' 集' +
              (this.resumePercent().length > 0 ? '  ·  看到 ' + this.resumePercent() : '') +
              (this.seenPos > 0 ? '  ·  ' + this.fmtMs(this.seenPos) : ''))
              .fontSize(14).fontColor(T.DIM).margin({ top: 4 })
            Row() {
              Text('从头看')
                .fontSize(14).fontColor(T.SUB)
                .height(36).padding({ left: 16, right: 16 })
                .borderRadius(T.RADIUS_SM)
                .backgroundColor(this.hi('rp_head') ? T.CARD_HI : T.CARD)
                .border({ width: T.BORDER, color: this.hi('rp_head') ? T.TXT : '#00000000' })
                .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                .onHover((hv: boolean) => this.hoverTo('rp_head', hv))
                .focusable(true)
                .onFocus(() => this.hoverTo('rp_head', true))
                .onBlur(() => this.hoverTo('rp_head', false))
                .onClick(() => Pointer.fire('rp_head', () => {
                    Feedback.tap();
                    this.showResume = false;
                    if (this.resumeTimer >= 0) {
                      clearTimeout(this.resumeTimer);
                      this.resumeTimer = -1;
                    }
                    // 从头播：覆盖续播进度
                    const ep: Episode = this.lines[this.lineIdx].eps[this.seen];
                    if (ep !== null && ep !== undefined) {
                      const line: Line = this.lines[this.lineIdx];
                      const p = new PlayParam();
                      p.url = ep.url;
                      p.title = this.vod.name + ' ' + ep.name;
                      p.siteKey = this.siteKey;
                      p.vodId = this.vodId;
                      p.from = line.name;
                      p.epIndex = this.seen;
                      p.seek = 0;
                      Playlist.set(line.eps, this.seen, this.vod.name);
                      router.pushUrl({ url: 'pages/Player', params: p });
                    }
                }))
                .onMouse(Pointer.on('rp_head', () => {
                    Feedback.tap();
                    this.showResume = false;
                    if (this.resumeTimer >= 0) {
                      clearTimeout(this.resumeTimer);
                      this.resumeTimer = -1;
                    }
                    const ep: Episode = this.lines[this.lineIdx].eps[this.seen];
                    if (ep !== null && ep !== undefined) {
                      const line: Line = this.lines[this.lineIdx];
                      const p = new PlayParam();
                      p.url = ep.url;
                      p.title = this.vod.name + ' ' + ep.name;
                      p.siteKey = this.siteKey;
                      p.vodId = this.vodId;
                      p.from = line.name;
                      p.epIndex = this.seen;
                      p.seek = 0;
                      Playlist.set(line.eps, this.seen, this.vod.name);
                      router.pushUrl({ url: 'pages/Player', params: p });
                    }
                }))
              Text('继续播放')
                .fontSize(14).fontColor(T.BG)
                .height(36).padding({ left: 16, right: 16 })
                .borderRadius(T.RADIUS_SM)
                .backgroundColor(this.hi('rp_cont') ? T.ACCENT : T.TXT)
                .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                .margin({ left: 12 })
                .onHover((hv: boolean) => this.hoverTo('rp_cont', hv))
                .focusable(true)
                .defaultFocus(true)
                .onFocus(() => this.hoverTo('rp_cont', true))
                .onBlur(() => this.hoverTo('rp_cont', false))
                .onClick(() => Pointer.fire('rp_cont', () => {
                    Feedback.tap();
                    this.showResume = false;
                    if (this.resumeTimer >= 0) {
                      clearTimeout(this.resumeTimer);
                      this.resumeTimer = -1;
                    }
                    // 直接续播对应集
                    if (this.lines.length > 0) {
                      const ep: Episode = this.lines[this.lineIdx].eps[this.seen];
                      if (ep !== null && ep !== undefined) {
                        this.play(ep, this.seen);
                      }
                    }
                }))
                .onMouse(Pointer.on('rp_cont', () => {
                    Feedback.tap();
                    this.showResume = false;
                    if (this.resumeTimer >= 0) {
                      clearTimeout(this.resumeTimer);
                      this.resumeTimer = -1;
                    }
                    if (this.lines.length > 0) {
                      const ep: Episode = this.lines[this.lineIdx].eps[this.seen];
                      if (ep !== null && ep !== undefined) {
                        this.play(ep, this.seen);
                      }
                    }
                }))
              Text('取消')
                .fontSize(14).fontColor(T.DIM)
                .height(36).padding({ left: 16, right: 16 })
                .borderRadius(T.RADIUS_SM)
                .backgroundColor(this.hi('rp_cancel') ? T.CARD_HI : '#00000000')
                .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                .margin({ left: 8 })
                .onHover((hv: boolean) => this.hoverTo('rp_cancel', hv))
                .focusable(true)
                .onFocus(() => this.hoverTo('rp_cancel', true))
                .onBlur(() => this.hoverTo('rp_cancel', false))
                .onClick(() => Pointer.fire('rp_cancel', () => {
                    Feedback.tap();
                    this.showResume = false;
                    if (this.resumeTimer >= 0) {
                      clearTimeout(this.resumeTimer);
                      this.resumeTimer = -1;
                    }
                }))
                .onMouse(Pointer.on('rp_cancel', () => {
                    Feedback.tap();
                    this.showResume = false;
                    if (this.resumeTimer >= 0) {
                      clearTimeout(this.resumeTimer);
                      this.resumeTimer = -1;
                    }
                }))
            }
            .margin({ top: 14 })
          }
          .padding({ left: 24, right: 24, top: 20, bottom: 20 })
          .backgroundColor(T.SURFACE)
          .borderRadius(16)
          .shadow({ radius: 30, color: T.BLACK_80 })
          .alignItems(HorizontalAlign.Start)
          .border({ width: T.BORDER, color: T.WHITE_15 })
        }
        .width('100%')
        .height('100%')
        /**
         * 续播卡片钉在右下角，而不是底部居中。
         *
         * 底部居中的浮层会压住选集/简介；既然它现在不再自动消失，
         * 就得放到不挡内容的位置。右下角在详情页通常是空白区。
         */
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .padding({ bottom: 40, right: 40 })
        .animation({ duration: 280, curve: Curve.FastOutSlowIn })
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    .backgroundColor(T.pageBg(this.themeMode))
    // id 带主题名：让 build 真正依赖 themeMode（否则换色板不重绘）
    .id('detail_' + this.themeMode)
  }

  /**
   * 剧集网格的精确高度。
   *
   * Grid 放在 Scroll 里必须给定高度，否则它会撑成「无限高」把所有剧集平铺出来；
   * 而给定高度后它自己又能滚，和外层 Scroll 抢同一个方向的手势。
   * 折中办法：按行数把高度算到刚好包住内容（行数×46 + 行间距×10），
   * 这样内层永不溢出、不会抢手势，整页只有一个滚动轴。
   */
  /**
   * 把「上次看到」的那一集滚进可视区。
   *
   * 198 集的片子上次看到第 77 集，网格只露 4 行（32 集），用户得一路往下滑
   * 才能找到自己看到哪了 —— 而标题栏明明写着「上次看到第 77 集」。
   * 这里在剧集渲染后滚过去，让它跟标题对上。
   * 只做一次：用户自己滚开之后再调用会把人拽回去。
   */
  locateSeen(): void {
    if (this.located || this.seen < 0) {
      return;
    }
    const list: Episode[] = this.epsView();
    if (list.length === 0) {
      // 数据还没到（onPageShow 比 load() 更早触发）。**不能**在这里置 located，
      // 否则等剧集真正渲染出来时已经被标记成「定位过了」，永远不滚。
      return;
    }
    if (list.length <= this.epsCols() * EPS_MAX_ROWS) {
      this.located = true;      // 一屏放得下，不用滚
      return;
    }
    // 显示位置（倒序时 seen 的下标要换算） = 原下标在列表里的位置
    let pos: number = -1;
    for (let i = 0; i < list.length; i++) {
      if (this.realIdx(list[i]) === this.seen) {
        pos = i;
        break;
      }
    }
    if (pos < 0) {
      this.located = true;
      return;
    }
    this.located = true;
    // 滚到「上一行」开头，让当前集不是贴着顶部，能看出上下文
    const target: number = pos - this.epsCols() >= 0 ? pos - this.epsCols() : 0;
    // 只调一次往往滚不动：从播放页返回时页面刚重建，Grid 还没完成 measure，
    // scrollToIndex 会被丢掉（实测调用后 currentOffset().y 仍是 0）。
    // 所以隔一帧重试，滚成功（y>0）就停。
    let tries: number = 0;
    const tick = (): void => {
      tries++;
      this.epScroller.scrollToIndex(target, false, ScrollAlign.START);
      const y: number = this.epScroller.currentOffset().yOffset;
      hilog.info(0x1000, 'BOXN', 'ep locate try=%{public}d target=%{public}d y=%{public}d',
        tries, target, y);
      if (y <= 0 && tries < 6) {
        setTimeout(tick, 120);
      } else {
        // 滚到位后触发已看那集的高亮脉冲（1.5s 后消退）
        this.seenPulse = true;
        setTimeout(() => { this.seenPulse = false; }, 1500);
      }
    };
    setTimeout(tick, 80);
  }

  /** 剧集是否需要网格内部滚动（行数超过显示上限） */
  epsScrollable(): boolean {
    return this.epsView().length > this.epsCols() * EPS_MAX_ROWS;
  }

  /** 网格实际占用的高度：内容不足 4 行就按内容走，避免下方留一大片空白 */
  epsBoxHeight(): number {
    const full: number = this.epsHeight();
    const cap: number = EPS_MAX_ROWS * EPS_H + (EPS_MAX_ROWS - 1) * EPS_GAP;
    return full > cap ? cap : full;
  }

  epsHeight(): number {
    const n: number = this.epsView().length;
    if (n === 0) {
      return 0;
    }
    const rows: number = Math.ceil(n / this.epsCols());
    return rows * EPS_H + (rows - 1) * EPS_GAP;
  }

  /** 剧集网格列数：手机 4 列（触控目标更大），电视 8 列 */
  epsCols(): number {
    return this.isPhone ? 4 : EPS_COLS;
  }

  epsColsT(): string {
    return this.isPhone ? '1fr 1fr 1fr 1fr' : EPS_COLS_T;
  }

  metaLine(): string {
    const parts: string[] = [];
    if (this.vod.typeName.length > 0) {
      parts.push(this.vod.typeName);
    }
    if (this.vod.year.length > 0) {
      parts.push(this.vod.year);
    }
    if (this.vod.area.length > 0) {
      parts.push(this.vod.area);
    }
    if (this.vod.remark.length > 0) {
      parts.push(this.vod.remark);
    }
    return parts.length > 0 ? parts.join('  ·  ') : '暂无资料';
  }

  /** 把 actor 字符串按 ,/$$$/、 分隔成数组 */
  actors(): string[] {
    if (this.vod.actor.length === 0) {
      return [];
    }
    const out: string[] = [];
    const names: string[] = this.vod.actor.split(/[,，/$$$$\u3001]/);
    for (let i = 0; i < names.length; i++) {
      const n: string = names[i].trim();
      if (n.length > 0 && out.indexOf(n) < 0) {
        out.push(n);
      }
    }
    return out.length > 8 ? out.slice(0, 8) : out;
  }

  /** 点击演员名 → 搜索该演员 */
  searchActor(name: string): void {
    const params: Record<string, Object> = { 'keyword': name, 'autoSearch': true };
    router.pushUrl({ url: 'pages/Search', params: params });
    Tip.show('搜索演员：' + name);
  }
}
