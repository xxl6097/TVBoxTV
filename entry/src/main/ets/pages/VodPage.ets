/**
 * 点播分类页 —— 对照 FongMi 的 fragment_vod.xml + fragment_type.xml + fragment_folder.xml。
 *
 * 原版结构：
 *   toolbar：logo + 站点名（marquee）
 *   分类横滑 RecyclerView（padding 8dp, bottom 12dp，item 是 16sp 圆角胶囊）
 *   ViewPager 里的网格（padding 24dp）
 *   FAB：筛选 / 换站 / 回顶部
 *
 * 卡片样式取自 adapter_vod_rect.xml：图片底 black_20，名称条在图片下方、
 * 背景 black_20、只留底部圆角、16sp 居中、padding 6dp。
 */

import { Feedback } from '../common/Feedback';
import router from '@ohos.router';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';
import { Store } from '../common/Store';
import { Cms } from '../common/Cms';
import { Site, Category, Vod, FilterGroup, FilterValue, VodPage, DetailParam, T } from '../common/Model';
import { Tip, TIP_MSG, TipLayer } from '../common/Tip';
import { KEY_IS_PHONE } from '../common/Device';
import { Poster } from '../common/Poster';
import { Pointer } from '../common/Pointer';
import { PhoneTabBar } from '../common/PhoneTabBar';
import { isBackCode } from '../common/TvFocus';

class Sel {
  key: string = '';
  v: string = '';
}

/** 站源格子的尺寸，siteGridH() 靠这几个数算总高 */
const SITE_COLS: number = 4;
const SITE_COLS_T: string = '1fr 1fr 1fr 1fr';
const SITE_ITEM_H: number = 56;
const SITE_GAP: number = 12;

@Entry
@Component
struct VodList {
  /** 设备形态：手机网格列数更少、触控目标更大 */
  @StorageProp(KEY_IS_PHONE) isPhone: boolean = false;
  @State site: Site = new Site();
  /** 全局轻提示（AppStorage 上的 TIP_MSG），Tip.show() 触发 */
  @StorageLink(TIP_MSG) tipMsg: string = '';
  @State sites: Site[] = [];
  @State cats: Category[] = [];
  @State curCat: Category = new Category();
  @State fGroups: FilterGroup[] = [];
  @State sel: Sel[] = [];
  @State items: Vod[] = [];
  @State page: number = 1;
  @State lastPage: number = 1;
  @State loading: boolean = true;
  @State more: boolean = false;
  @State err: string = '';
  /**
   * 翻页（追加）失败的错误，和 err 分开存。
   *
   * 以前翻页失败也写进 err，而 err 只在「重新拉第一页」时清空、且 onEnd 见到
   * err 非空就直接 return —— 结果是：列表已经有一屏内容时，第 2 页失败既看不到
   * 报错（err 分支要求 items 为空才渲染），也再也不能翻页，必须换分类才好。
   */
  @State moreErr: string = '';
  /** 分类表拉取失败。重试按钮据此决定是「重拉分类」还是「重拉列表」 */
  @State catFailed: boolean = false;
  @State hoverKey: string = '';
  /** 下拉刷新的转圈状态（Refresh 组件要求双向绑定） */
  @State refreshing: boolean = false;
  @State showSites: boolean = false;
  @State showFilter: boolean = false;
  /** 换站弹窗搜索框内容，实时过滤站源列表 */
  @State siteSearchKw: string = '';
  /** 当前分类是不是「父分类汇总」模式（此时不能翻页，列表是各子分类最新内容的混排） */
  @State merged: boolean = false;

  private cms: Cms | null = null;
  private reqId: number = 0;

  aboutToAppear(): void {
    this.boot();
  }

  onBackPress(): boolean {
    // 遥控器返回键：弹窗打开时先关弹窗，否则退出页面
    if (this.showSites) {
      this.showSites = false;
      return true;
    }
    if (this.showFilter) {
      this.showFilter = false;
      return true;
    }
    router.back();
    return true;
  }

  // ==================== 数据 ====================

  async boot(): Promise<void> {
    await Store.init(getContext(this) as common.UIAbilityContext);
    await Store.ensureLoaded();
    const list: Site[] = await Store.activeSites();
    this.sites = list;
    if (list.length === 0) {
      this.loading = false;
      this.err = '还没有启用站源，去「设置」里勾几个';
      return;
    }
    await this.useSite(list[0]);
  }

  async useSite(s: Site): Promise<void> {
    this.site = s;
    this.cms = new Cms(s);
    this.loading = true;
    this.err = '';
    this.moreErr = '';
    this.catFailed = false;
    this.items = [];
    this.cats = [];
    this.sel = [];
    this.fGroups = [];
    this.merged = false;
    this.showSites = false;
    this.showFilter = false;
    const my: number = ++this.reqId;
    try {
      const cs: Category[] = await this.cms.categories();
      if (my !== this.reqId) {
        return;
      }
      this.cats = cs;
      const first: Category = cs.length > 0 ? cs[0] : new Category();
      this.curCat = first;
      this.fGroups = Cms.filtersOf(s.ext, first.id);
      await this.restoreSel(first);
      await this.loadPage(1, true);
    } catch (e) {
      if (my !== this.reqId) {
        return;
      }
      this.loading = false;
      // 标记失败来源：重试要重拉分类，只重拉列表救不回分类栏
      // （curCat 会是空 id，TypeRow 高度 0 永久消失，用户再也切不了分类）
      this.catFailed = true;
      this.err = '拉取分类失败：' + (e as Error).message;
    }
  }

  /** 重试按钮统一入口：按失败来源分发，别用同一条路径糊过去 */
  retryLoad(): void {
    if (this.catFailed) {
      this.useSite(this.site);
    } else {
      this.loadPage(1, true);
    }
  }

  /** 当前分类的子分类 id 列表（父分类才有，叶子分类返回空） */
  childrenOf(c: Category): string[] {
    const out: string[] = [];
    // 「全部」的 id 是空串，而顶级分类的 pid 也是空串 —— 不排除的话
    // 全部会被当成「所有顶级分类的父级」，一进页面就并发 20 个请求。
    // t='' 本身就返回全集，根本不需要聚合。
    if (c.id.length === 0) {
      return out;
    }
    for (let i = 0; i < this.cats.length; i++) {
      if (this.cats[i].pid === c.id && this.cats[i].id !== c.id) {
        out.push(this.cats[i].id);
      }
    }
    return out;
  }

  /** 丢掉接口缓存并按当前分类重拉，用于「我就是想看最新的」 */
  async reloadNow(): Promise<void> {
    Cms.clearCache();
    this.items = [];
    this.page = 1;
    await this.loadPage(1, true);
    Tip.show('已刷新「' + this.curCat.name + '」');
  }

  async pickCat(c: Category): Promise<void> {
    if (this.curCat.id === c.id && this.items.length > 0) {
      return;
    }
    this.curCat = c;
    this.fGroups = Cms.filtersOf(this.site.ext, c.id);
    this.items = [];
    this.page = 1;
    // 恢复该分类的筛选条件
    await this.restoreSel(c);
    await this.loadPage(1, true);
  }

  /** 从 Store 恢复当前站源+分类的筛选条件 */
  async restoreSel(c: Category): Promise<void> {
    const json: string = await Store.filterSel(this.site.key, c.id);
    if (json.length === 0) {
      this.sel = [];
      return;
    }
    try {
      const arr: Sel[] = JSON.parse(json) as Sel[];
      this.sel = arr;
    } catch (_e) {
      this.sel = [];
    }
  }

  /** 持久化当前筛选条件 */
  async saveSel(): Promise<void> {
    await Store.setFilterSel(this.site.key, this.curCat.id, JSON.stringify(this.sel));
  }

  /**
   * 合并分页结果并按 id 去重。
   *
   * 采集站按更新时间倒序，翻页期间有新片插入时第 N 页会和第 N-1 页重叠；
   * 部分站还会把越界的页码「夹」回最后一页，直接 concat 就是整页重复。
   * 重复 key 会让 ForEach 报 Duplicate key 并丢节点，用户看到的是「翻到第 2 页少了几部」。
   */
  mergeItems(old: Vod[], add: Vod[]): Vod[] {
    const seen: Set<string> = new Set<string>();
    const out: Vod[] = [];
    for (let i = 0; i < old.length; i++) {
      const v: Vod = old[i];
      const k: string = v.siteKey + '|' + v.id;
      if (v.id.length > 0 && !seen.has(k)) {
        seen.add(k);
        out.push(v);
      }
    }
    for (let i = 0; i < add.length; i++) {
      const v: Vod = add[i];
      const k: string = v.siteKey + '|' + v.id;
      if (v.id.length > 0 && !seen.has(k)) {
        seen.add(k);
        out.push(v);
      }
    }
    return out;
  }

  async loadPage(p: number, fresh: boolean): Promise<void> {
    if (this.cms === null) {
      return;
    }
    const my: number = ++this.reqId;
    if (fresh) {
      this.loading = true;
      this.err = '';
      this.moreErr = '';
      this.catFailed = false;
    } else {
      this.more = true;
      this.moreErr = '';
    }
    this.cms.setExtra(this.extra());
    // 父分类（如「电视剧」）在采集站里往往没有直属影片，直接请求会拿到空列表。
    // 这种情况把子分类一起拉下来混排，比甩一句「这个分类下没有内容」有用得多。
    //
    // 用两段式而不是无条件聚合：多数父分类其实有少量直属影片（比如「电影」只有
    // 一两条），无条件聚合会一次并发十几个请求，容易被采集站限流。所以先单独请求
    // 一次，内容够多就直接用；不够才回头拉子分类补齐。
    // 只在第 1 页、且没加筛选时做：筛选条件是按具体分类生效的，混着查容易出空。
    const kids: string[] = (p === 1 && this.extra().length === 0)
      ? this.childrenOf(this.curCat) : [];
    try {
      let r: VodPage = await this.cms.list(this.curCat.id, p);
      if (my !== this.reqId) {
        return;
      }
      this.merged = false;
      if (kids.length > 0 && r.items.length < 8) {
        // 稀疏分类：把子分类补齐（最多 10 个子分类，再多就太吵了）
        const use: string[] = [this.curCat.id].concat(kids.slice(0, 10));
        r = await this.cms.listMerged(use, 1);
        this.merged = true;
      }
      if (my !== this.reqId) {
        return;
      }
      this.lastPage = r.pageCount <= 0 ? p : r.pageCount;
      this.page = p;
      this.items = fresh ? this.mergeItems([], r.items) : this.mergeItems(this.items, r.items);
      if (this.items.length === 0) {
        this.err = '这个分类下没有内容';
      }
    } catch (e) {
      if (my !== this.reqId) {
        return;
      }
      // 翻页失败写 moreErr、不动 err：列表已有内容时 err 分支根本不会渲染，
      // 写在 err 里等于把「还能不能继续翻」的状态也一并弄坏了。
      if (fresh) {
        this.err = '加载失败：' + (e as Error).message;
      } else {
        this.moreErr = '加载更多失败：' + (e as Error).message;
      }
    } finally {
      if (my === this.reqId) {
        this.loading = false;
        this.more = false;
      }
    }
  }

  onEnd(): void {
    if (this.loading || this.more || this.err.length > 0 || this.moreErr.length > 0 || this.merged) {
      return;          // 聚合模式没有「下一页」——它是各子分类第 1 页的混排
    }
    if (this.page < this.lastPage) {
      this.loadPage(this.page + 1, false);
    }
  }

  extra(): string {
    let q: string = '';
    for (let i = 0; i < this.sel.length; i++) {
      const s: Sel = this.sel[i];
      if (s.v.length > 0) {
        q += '&' + encodeURIComponent(s.key) + '=' + encodeURIComponent(s.v);
      }
    }
    return q;
  }

  selOf(key: string): string {
    for (let i = 0; i < this.sel.length; i++) {
      if (this.sel[i].key === key) {
        return this.sel[i].v;
      }
    }
    return '';
  }

  setSel(key: string, v: string): void {
    const out: Sel[] = [];
    let done: boolean = false;
    for (let i = 0; i < this.sel.length; i++) {
      if (this.sel[i].key === key) {
        if (!done) {
          const s = new Sel();
          s.key = key;
          s.v = v;
          out.push(s);
          done = true;
        }
      } else {
        out.push(this.sel[i]);
      }
    }
    if (!done) {
      const s = new Sel();
      s.key = key;
      s.v = v;
      out.push(s);
    }
    this.sel = out;
  }

  async applyFilter(): Promise<void> {
    this.showFilter = false;
    await this.saveSel();
    this.items = [];
    await this.loadPage(1, true);
  }

  selText(): string {
    const parts: string[] = [];
    for (let i = 0; i < this.fGroups.length; i++) {
      const g: FilterGroup = this.fGroups[i];
      const v: string = this.selOf(g.key);
      if (v.length > 0) {
        let label: string = v;
        for (let k = 0; k < g.values.length; k++) {
          if (g.values[k].v === v) {
            label = g.values[k].n;
            break;
          }
        }
        parts.push(label);
      }
    }
    return parts.join(' · ');
  }

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

  // ==================== 界面 ====================

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        this.Toolbar()
        this.TypeRow()
        this.Body()
        if (this.isPhone) {
          PhoneTabBar('pages/VodPage')
        }
      }
      .width('100%')
      .height('100%')

      if (this.showSites) {
        this.SiteSheet()
      }
      if (this.showFilter) {
        this.FilterSheet()
      }

      if (this.tipMsg.length > 0) {
        TipLayer(this.tipMsg)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(T.BG)
  }

  @Builder
  Toolbar() {
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
        .onClick(() => Pointer.fire('vp_back', () => {
            Feedback.tap();
            router.back();
        }))
        .onMouse(Pointer.on('vp_back', () => {
            Feedback.tap();
            router.back();
        }))
      Text(this.site.name.length > 0 ? this.site.name : '点播')
        .fontSize(24)
        .fontColor(T.TXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 8 })
        .layoutWeight(1)
      Text(this.selText().length > 0 ? this.selText() : '')
        .fontSize(14)
        .fontColor(T.SUB)
        .maxLines(1)
        .margin({ right: 12 })
      // 有缓存之后必须留一个「强制拉最新」的入口，否则用户想看看有没有更新，
      // 只能等 90 秒的列表缓存过期。清缓存后按当前分类重载。
      this.ToolBtn('刷新', 'reload', () => {
        this.reloadNow();
      })
      this.ToolBtn('换站', 'site', () => {
        this.showSites = true;
      })
      if (this.fGroups.length > 0) {
        this.ToolBtn('筛选', 'filter', () => {
          this.showFilter = true;
        })
      }
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 8 })
  }

  @Builder
  ToolBtn(label: string, key: string, act: () => void) {
    // selector_chip：4dp 圆角 + 12dp 横向内边距，常态无底、焦点 black_40 + 1.5dp 白描边
    Text(label)
      .fontSize(16)
      .fontColor(T.TXT)
      .height(40)
      .padding({ left: 12, right: 12 })
      .borderRadius(T.RADIUS_SM)
      .margin({ left: 8 })
      .textAlign(TextAlign.Center)
      .backgroundColor(this.hi('t_' + key) ? T.CARD_HI : T.CARD)
      .border({ width: T.BORDER, color: this.hi('t_' + key) ? T.TXT : '#00000000' })
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .focusable(true)
      .onFocus(() => this.hover('t_' + key, true))
      .onBlur(() => this.hover('t_' + key, false))
      .onHover((hv: boolean) => this.hover('t_' + key, hv))
      .onClick(() => Pointer.fire('vp_tab' + key, () => { Feedback.tap(); act(); }))
      .onMouse(Pointer.on('vp_tab' + key, () => { Feedback.tap(); act(); }))
  }

  @Builder
  TypeRow() {
    Scroll() {
      Row() {
        ForEach(this.cats, (c: Category) => {
          // adapter_type.xml + selector_item_round：28dp 胶囊，black_20 常态 / black_40 焦点 + 1.5dp 白描边
          // 文字色走 color/text.xml：仅 selected 变 yellow_500，focused 不变
          Text(c.name)
            .fontSize(16)
            .fontColor(this.curCat.id === c.id ? T.SELECTED : T.TXT)
            .height(38)
            .padding({ left: 14, right: 14 })
            .borderRadius(T.RADIUS_PILL)
            .margin({ right: 8 })
            .textAlign(TextAlign.Center)
            .backgroundColor(this.curCat.id === c.id || this.hi('c_' + c.id) ? T.CARD_HI : T.CARD)
            .border({
              width: T.BORDER,
              color: this.hi('c_' + c.id) ? T.TXT : '#00000000'
            })
            .animation({ duration: T.ANIM, curve: Curve.EaseOut })
            .focusable(true)
            .onFocus(() => this.hover('c_' + c.id, true))
            .onBlur(() => this.hover('c_' + c.id, false))
            .onHover((hv: boolean) => this.hover('c_' + c.id, hv))
            .onClick(() => Pointer.fire('vp_cat' + c.id, () => {
                Feedback.tap();
                this.pickCat(c);
            }))
            .onMouse(Pointer.on('vp_cat' + c.id, () => {
                Feedback.tap();
                this.pickCat(c);
            }))
        }, (c: Category) => 'cat' + c.id + c.name)
      }
      .padding({ left: 24, right: 24 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(this.cats.length > 0 ? 52 : 0)
  }

  @Builder
  Body() {
    if (this.loading && this.items.length === 0) {
      Column() {
        LoadingProgress().width(44).height(44).color(T.TXT)
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    } else if (this.err.length > 0 && this.items.length === 0) {
      Column() {
        Text(this.err).fontSize(16).fontColor(T.SUB).textAlign(TextAlign.Center).width('70%')
        Text('重试')
          .fontSize(16)
          .fontColor(T.TXT)
          .height(42)
          .padding({ left: 28, right: 28 })
          .borderRadius(T.RADIUS)
          .margin({ top: 16 })
          .border({ width: T.BORDER, color: T.TXT })
          .focusable(true)
          .onFocus(() => this.hover('retry', true))
          .onBlur(() => this.hover('retry', false))
          .onHover((hv: boolean) => this.hover('retry', hv))
          .backgroundColor(this.hi('retry') ? T.CARD_HI : '#00000000')
          .onClick(() => Pointer.fire('vp_retry', () => {
              Feedback.tap();
              this.retryLoad();
          }))
          .onMouse(Pointer.on('vp_retry', () => {
              Feedback.tap();
              this.retryLoad();
          }))
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    } else {
      if (this.merged) {
        Row() {
          Text('「' + this.curCat.name + '」自身内容较少，已连带汇总它 ' +
            this.childrenOf(this.curCat).length + ' 个子分类的最新内容')
            .fontSize(14).fontColor(T.DIM)
        }
        .width('100%')
        .padding({ left: 24, right: 24, bottom: 6 })
      }
      // 下拉刷新：重新拉当前分类的第一页。顶栏那个「刷新」在电视上更顺手，
      // 但手机用户的下意识动作是往下拉，两条路都留着成本很低。
      // Refresh 必须**直接**套在可滚动组件上——中间夹一层容器时它拿不到滚动位置，
      // 手势根本不会被识别（直播页踩过同一个坑）
      Refresh({ refreshing: $$this.refreshing }) {
      Grid() {
        ForEach(this.items, (v: Vod) => {
          GridItem() {
            this.Card(v)
          }
          .focusable(true)
          .onFocus(() => this.hover('p_' + v.id, true))
          .onBlur(() => this.hover('p_' + v.id, false))
          .onClick(() => Pointer.fire('vp_card' + v.id, () => {
              Feedback.tap();
              const p = new DetailParam();
              p.siteKey = v.siteKey.length > 0 ? v.siteKey : this.site.key;
              p.siteName = v.siteName.length > 0 ? v.siteName : this.site.name;
              p.vodId = v.id;
              router.pushUrl({ url: 'pages/Detail', params: p });
          }))
          .onMouse(Pointer.on('vp_card' + v.id, () => {
              Feedback.tap();
              const p = new DetailParam();
              p.siteKey = v.siteKey.length > 0 ? v.siteKey : this.site.key;
              p.siteName = v.siteName.length > 0 ? v.siteName : this.site.name;
              p.vodId = v.id;
              router.pushUrl({ url: 'pages/Detail', params: p });
          }))
        }, (v: Vod) => 'v' + v.id + v.name)
      }
      .columnsTemplate(this.isPhone ? '1fr 1fr 1fr' : '1fr 1fr 1fr 1fr 1fr 1fr')
      .columnsGap(12)
      .rowsGap(20)
      .width('100%')
      // 在 Refresh 里只能给 height('100%')：拿到父容器完整高度它才会自己滚，
      // 给 layoutWeight 时高度由 Refresh 的测量结果决定，行数一多就撑到屏幕外
      .height('100%')
      .padding({ left: 24, right: 24, top: 8, bottom: 24 })
      .scrollBar(BarState.Off)
      .cachedCount(12)
      // Spring 的回弹会把「已到顶后的那段下拉」吃掉，手势传不到 Refresh
      .edgeEffect(EdgeEffect.None)
      .onReachEnd(() => {
        this.onEnd();
      })
      }
      .width('100%')
      .layoutWeight(1)
      .onRefreshing(() => {
        this.refreshing = true;
        hilog.info(0x1000, 'BOXN', 'vod pull-refresh cat=%{public}s', this.curCat.name);
        // 走 reloadNow：它会清接口缓存。不清缓存的话下拉拿到的还是 90 秒内的
        // 旧响应，用户拉一把看不到任何变化，会当成「没反应」
        this.reloadNow().then(() => {
          this.refreshing = false;
        });
      })
      // 翻页失败时在底部给一条可点的重试行。以前这里什么都没有，
      // onEnd 又被 err 永久挡住 —— 用户只能换分类才能继续看。
      if (this.moreErr.length > 0) {
        Row() {
          Text(this.moreErr)
            .fontSize(14).fontColor(T.WARN)
            .layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('重试')
            .fontSize(14).fontColor(T.TXT)
            .height(34).padding({ left: 18, right: 18 })
            .border({ width: T.BORDER, color: T.TXT })
            .borderRadius(T.RADIUS)
            .focusable(true)
            .backgroundColor(this.hi('more') ? T.CARD_HI : '#00000000')
            .onFocus(() => this.hover('more', true))
            .onBlur(() => this.hover('more', false))
            .onHover((hv: boolean) => this.hover('more', hv))
            .onClick(() => Pointer.fire('vp_more', () => {
                Feedback.tap();
                this.loadPage(this.page + 1, false);
            }))
            .onMouse(Pointer.on('vp_more', () => {
                Feedback.tap();
                this.loadPage(this.page + 1, false);
            }))
        }
        .width('100%')
        .padding({ left: 24, right: 24, bottom: 14 })
        .justifyContent(FlexAlign.Center)
      }
    }
  }

  /** adapter_vod_rect.xml：图 + 名称条（black_20 背景、只留底部圆角、16sp 居中） */
  @Builder
  Card(v: Vod) {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        Poster({ url: v.pic, bot: 0 })
          .width('100%')
          .height('100%')
        if (v.remark.length > 0) {
          // shape_vod_remark：bg_remark(#177535 @70%)，仅右侧 4dp 圆角，4dp 内边距
          Text(v.remark)
            .fontSize(14)
            .fontColor(T.TXT)
            .backgroundColor('#B3177535')
            .padding(4)
            .borderRadius({ topRight: T.RADIUS_SM, bottomRight: T.RADIUS_SM })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '90%' })
        }
      }
      .width('100%')
      .aspectRatio(16 / 9)

      Text(v.name)
        .fontSize(16)
        .fontColor(T.TXT)
        .backgroundColor(T.CARD)
        .width('100%')
        .padding(6)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .borderRadius({ bottomLeft: T.RADIUS, bottomRight: T.RADIUS })
    }
    .width('100%')
    .borderRadius(T.RADIUS)
    .border({ width: T.BORDER, color: this.hi('p_' + v.id) ? T.TXT : '#00000000' })
    .scale({
      x: this.hi('p_' + v.id) ? T.HOVER_SCALE : 1,
      y: this.hi('p_' + v.id) ? T.HOVER_SCALE : 1
    })
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
    .onHover((hv: boolean) => this.hover('p_' + v.id, hv))
  }

  // ---------- 换站 ----------

  /** 站源网格列数：手机 2 列（名字长），电视 4 列 */
  siteCols(): number {
    return this.isPhone ? 2 : SITE_COLS;
  }

  /** 站源网格的完整高度：不按可用空间裁剪，多出来的交给外层 Scroll */
  siteGridH(): number {
    const filtered = this.filteredSites();
    const n: number = filtered.length;
    if (n === 0) {
      return 0;
    }
    const rows: number = Math.ceil(n / this.siteCols());
    return rows * SITE_ITEM_H + (rows - 1) * SITE_GAP;
  }

  /** 按搜索关键词过滤站源列表（空关键词返回全部） */
  filteredSites(): Site[] {
    if (this.siteSearchKw.trim().length === 0) {
      return this.sites;
    }
    const kw = this.siteSearchKw.trim().toLowerCase();
    return this.sites.filter((s: Site) => s.name.toLowerCase().indexOf(kw) >= 0);
  }

  @Builder
  SiteSheet() {
    Column() {
      Row() {
        Text('选择站源').fontSize(22).fontColor(T.TXT).layoutWeight(1)
        Text('关闭')
          .fontSize(16)
          .fontColor(this.hi('ss_close') ? T.TXT : T.SUB)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(T.RADIUS_SM)
          .backgroundColor(this.hi('ss_close') ? T.CARD_HI : '#00000000')
          .focusable(true)
          .defaultFocus(true)
          .onFocus(() => this.hover('ss_close', true))
          .onBlur(() => this.hover('ss_close', false))
          .onHover((hv: boolean) => this.hover('ss_close', hv))
          .onClick(() => Pointer.fire('vp_sclose', () => {
              Feedback.tap();
              this.showSites = false;
              this.siteSearchKw = '';
          }))
          .onMouse(Pointer.on('vp_sclose', () => {
              Feedback.tap();
              this.showSites = false;
              this.siteSearchKw = '';
          }))
      }
      .width('100%')
      .margin({ bottom: 16 })

      // 搜索框：站源超过 8 个时显示，实时过滤
      if (this.sites.length > 8) {
        Row() {
          Text('🔍').fontSize(16)
          TextInput({ text: this.siteSearchKw, placeholder: '搜索站源…' })
            .fontSize(16)
            .layoutWeight(1)
            .margin({ left: 8 })
            .backgroundColor(T.CARD)
            .borderRadius(T.RADIUS_SM)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onChange((v: string) => {
              this.siteSearchKw = v;
            })
        }
        .width('100%')
        .margin({ bottom: 12 })
      }

      /**
       * 站源网格。
       *
       * 直接给 Grid 加 layoutWeight(1) 时，行数超过可用高度会**压缩最后一行**：
       * 实测 12 个站源（3 行）时，前 8 个是 56vp，最后一行的 4 个被压成 28vp，
       * 文字挤在半个格子里，而且没有滚动条 —— 多出来的站源等于点不到。
       * 改成「外层 Scroll + Grid 高度按行数算准」，行高不再被压缩，多了就滚。
       */
      Scroll() {
        Grid() {
          ForEach(this.filteredSites(), (s: Site) => {
            GridItem() {
              Text(s.name)
                .fontSize(16)
                .fontColor(T.TXT)
                .width('100%')
                .height(SITE_ITEM_H)
                .borderRadius(T.RADIUS)
                .textAlign(TextAlign.Center)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .padding({ left: 10, right: 10 })
                .backgroundColor(this.site.key === s.key ? T.CARD_HI : T.CARD)
                .border({
                  width: T.BORDER,
                  color: this.site.key === s.key ? T.TXT :
                    (this.hi('ss_' + s.key) ? T.SUB : '#00000000')
                })
                .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                .focusable(true)
                .onFocus(() => this.hover('ss_' + s.key, true))
                .onBlur(() => this.hover('ss_' + s.key, false))
                .onHover((hv: boolean) => this.hover('ss_' + s.key, hv))
                .onClick(() => Pointer.fire('vp_site' + s.key, () => {
                    Feedback.tap();
                    this.useSite(s);
                }))
                .onMouse(Pointer.on('vp_site' + s.key, () => {
                    Feedback.tap();
                    this.useSite(s);
                }))
            }
          }, (s: Site) => 'st' + s.key)
        }
        .columnsTemplate(this.isPhone ? '1fr 1fr' : SITE_COLS_T)
        .columnsGap(SITE_GAP)
        .rowsGap(SITE_GAP)
        .width('100%')
        .height(this.siteGridH())
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('72%')
    .height('72%')
    .padding(24)
    .borderRadius(16)
    .backgroundColor(T.SURFACE)
    .shadow({ radius: 40, color: T.BLACK_80 })
    // 焦点锁在弹窗内
    .focusScopeId('sites_panel', true)
  }

  // ---------- 筛选 ----------

  @Builder
  FilterSheet() {
    Column() {
      Row() {
        Text('筛选').fontSize(22).fontColor(T.TXT).layoutWeight(1)
        Text('重置')
          .fontSize(16)
          .fontColor(this.hi('fl_reset') ? T.TXT : T.SUB)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(T.RADIUS_SM)
          .backgroundColor(this.hi('fl_reset') ? T.CARD_HI : '#00000000')
          .focusable(true)
          .onFocus(() => this.hover('fl_reset', true))
          .onBlur(() => this.hover('fl_reset', false))
          .onHover((hv: boolean) => this.hover('fl_reset', hv))
          .onClick(() => Pointer.fire('vp_fclr', () => {
              Feedback.tap();
              this.sel = [];
          }))
          .onMouse(Pointer.on('vp_fclr', () => {
              Feedback.tap();
              this.sel = [];
          }))
      }
      .width('100%')
      .margin({ bottom: 12 })

      Scroll() {
        Column() {
          ForEach(this.fGroups, (g: FilterGroup) => {
            Column() {
              Text(g.name).fontSize(14).fontColor(T.SUB).width('100%').margin({ bottom: 8 })
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(g.values, (v: FilterValue) => {
                  Text(v.n)
                    .fontSize(15)
                    .fontColor(T.TXT)
                    .height(36)
                    .padding({ left: 16, right: 16 })
                    .borderRadius(18)
                    .margin({ right: 10, bottom: 10 })
                    .textAlign(TextAlign.Center)
                    .backgroundColor(this.selOf(g.key) === v.v ? T.CARD_HI : '#00000000')
                    .border({
                      width: T.BORDER,
                      color: this.selOf(g.key) === v.v ? T.TXT :
                        (this.hi('fv_' + g.key + v.v) ? T.SUB : '#00000000')
                    })
                    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                    .focusable(true)
                    .onFocus(() => this.hover('fv_' + g.key + v.v, true))
                    .onBlur(() => this.hover('fv_' + g.key + v.v, false))
                    .onHover((hv: boolean) => this.hover('fv_' + g.key + v.v, hv))
                    .onClick(() => Pointer.fire('vp_f' + g.key + v.v, () => {
                        Feedback.tap();
                        this.setSel(g.key, v.v);
                    }))
                    .onMouse(Pointer.on('vp_f' + g.key + v.v, () => {
                        Feedback.tap();
                        this.setSel(g.key, v.v);
                    }))
                }, (v: FilterValue) => 'fv' + g.key + v.v + v.n)
              }
              .width('100%')
            }
            .width('100%')
            .margin({ bottom: 12 })
            .alignItems(HorizontalAlign.Start)
          }, (g: FilterGroup) => 'fg' + g.key)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Row() {
        Blank()
        Text('确定')
          .fontSize(16)
          .fontColor('#141218')
          .backgroundColor(T.ACCENT)
          .height(44)
          .padding({ left: 40, right: 40 })
          .borderRadius(T.RADIUS)
          .textAlign(TextAlign.Center)
          .border({ width: 3, color: this.hi('fl_ok') ? T.SELECTED : '#00000000' })
          .scale({ x: this.hi('fl_ok') ? 1.05 : 1, y: this.hi('fl_ok') ? 1.05 : 1 })
          .animation({ duration: T.ANIM, curve: Curve.EaseOut })
          .focusable(true)
          .defaultFocus(true)
          .onFocus(() => this.hover('fl_ok', true))
          .onBlur(() => this.hover('fl_ok', false))
          .onHover((hv: boolean) => this.hover('fl_ok', hv))
          .onClick(() => Pointer.fire('vp_fapply', () => {
              Feedback.tap();
              this.applyFilter();
          }))
          .onMouse(Pointer.on('vp_fapply', () => {
              Feedback.tap();
              this.applyFilter();
          }))
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('64%')
    .height('72%')
    .padding(24)
    .borderRadius(16)
    .backgroundColor(T.SURFACE)
    .shadow({ radius: 40, color: T.BLACK_80 })
    // 焦点锁在弹窗内
    .focusScopeId('filter_panel', true)
  }
}
