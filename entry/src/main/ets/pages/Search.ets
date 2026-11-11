import { Feedback } from '../common/Feedback';
import { abbrsOf, abbrToT9 } from '../common/Pinyin';
import router from '@ohos.router';
import inputMethod from '@ohos.inputMethod';
import common from '@ohos.app.ability.common';
import { Store } from '../common/Store';
import { Site, PlayParam, DetailParam, Vod, T } from '../common/Model';
import { Cms } from '../common/Cms';
import { Tip, TIP_MSG, TipLayer } from '../common/Tip';
import { Device, KEY_IS_PHONE } from '../common/Device';
import { Theme, KEY_THEME } from '../common/Theme';
import { PhoneTabBar } from '../common/PhoneTabBar';
import { Pointer } from '../common/Pointer';
import { Poster } from '../common/Poster';

class Group {
  key: string = '';
  site: string = '';
  items: Vod[] = [];
}

/** 右侧联想建议项：来源分「搜过」（历史）与「热播」（首页片名） */
class Sug {
  text: string = '';
  from: string = '';
}

@Entry
@Component
struct SearchPage {
  @State kw: string = '';
  /** 设备形态：手机竖屏显示底部 Tab */
  @StorageProp(KEY_IS_PHONE) isPhone: boolean = false;
  /** 当前主题。build 里必须用到（见 .id），否则换了色板不会重绘 */
  @StorageProp(KEY_THEME) themeMode: string = 'dark';
  /** 全局轻提示（AppStorage 上的 TIP_MSG），Tip.show() 触发 */
  @StorageLink(TIP_MSG) tipMsg: string = '';
  @State groups: Group[] = [];
  @State loading: boolean = false;
  @State progress: string = '';
  @State err: string = '';
  @State focusKey: string = '';
  @State kws: string[] = [];
  /** 右侧联想建议词（根据输入内容实时猜测） */
  @State sugg: Sug[] = [];
  /** 热门推荐：来自首页 feed，最多 12 张，空态时展示 */
  @State hotVods: Vod[] = [];
  /** 下拉重搜的转圈状态（Refresh 组件要求双向绑定） */
  @State refreshing: boolean = false;
  /** 长按删除搜索记录的时刻：用来跳过紧随其后的点击 */
  private lastKwDelMs: number = 0;
  /** 联想候选池：搜索历史 + 首页最近更新片名，进页面收集一次 */
  private pool: Sug[] = [];
  /** 搜索序号：连续搜索时用来丢弃上一轮的延迟结果 */
  private gen: number = 0;
  /** 联想建议防抖计时器（300ms）：快速打字时不每个字都触发 */
  private suggTimer: number = -1;
  /** 搜不到结果时刷新热门推荐的轮次（交替两种取法） */
  private hotRound: number = 0;

  async aboutToAppear(): Promise<void> {
    await Store.init(getContext(this) as common.UIAbilityContext);
    this.kws = await Store.keywords();
    await this.buildPool();
    // 热门推荐：从首页 feed 取最多 12 条
    const feed: Vod[] = await Store.feed();
    this.hotVods = feed.length > 12 ? feed.slice(0, 12) : feed;
    // 从详情页点演员名跳过来时，带 keyword + autoSearch 直接触发搜索
    const p: Object | undefined = router.getParams();
    if (p !== null && p !== undefined && p instanceof Object) {
      const rec: Record<string, Object> = p as Record<string, Object>;
      const kwObj: Object | undefined = rec['keyword'];
      if (kwObj !== undefined && typeof kwObj === 'string') {
        const kw: string = kwObj as string;
        this.kw = kw;
        const autoObj: Object | undefined = rec['autoSearch'];
        if (autoObj === true) {
          await this.doSearch();
        }
      }
    }
  }

  /** 收集联想候选词：搜索历史 + 首页「最近更新」片名，进页面收集一次 */
  private async buildPool(): Promise<void> {
    const out: Sug[] = [];
    const push = (s: string, from: string): void => {
      const t: string = s.trim();
      if (t.length === 0) {
        return;
      }
      for (let i = 0; i < out.length; i++) {
        if (out[i].text === t) {
          return;
        }
      }
      const g = new Sug();
      g.text = t;
      g.from = from;
      out.push(g);
    };
    for (let i = 0; i < this.kws.length; i++) {
      push(this.kws[i], 'hist');
    }
    const feed: Vod[] = await Store.feed();
    for (let i = 0; i < feed.length; i++) {
      push(feed[i].name, 'feed');
    }
    this.pool = out;
    this.refreshSugg();
  }

  /**
   * 根据输入内容实时刷新右侧建议（带 300ms 防抖）。
   * 中文：前缀命中优先、包含命中其次；
   * 纯字母/数字：按「拼音首字母缩写」猜测（输 sgyy / sg 都能命中「三国演义」）。
   */
  private refreshSugg(): void {
    if (this.suggTimer >= 0) {
      clearTimeout(this.suggTimer);
    }
    this.suggTimer = setTimeout(() => {
      this.doRefreshSugg();
      this.suggTimer = -1;
    }, 300);
  }

  /** 实际执行联想刷新的逻辑（由防抖定时器调用） */
  private doRefreshSugg(): void {
    const kw: string = this.kw.trim().toLowerCase();
    if (kw.length === 0) {
      this.sugg = this.pool.slice(0, 12);
      return;
    }
    // 区分三种输入：纯字母（拼音首字母缩写）、纯数字（T9 九宫格）、中文
    const isLetter: boolean = /^[a-z]+$/.test(kw);
    const isNum: boolean = /^[0-9]+$/.test(kw);
    const prefix: Sug[] = [];
    const contain: Sug[] = [];
    for (let i = 0; i < this.pool.length; i++) {
      const s: Sug = this.pool[i];
      const t: string = s.text.toLowerCase();
      if (t === kw) {
        continue;
      }
      let hitPrefix: boolean = false;
      let hitContain: boolean = false;
      if (isLetter) {
        // 拼音首字母缩写：sgyy 命中「三国演义」
        const abbrs: string[] = abbrsOf(s.text);
        for (let k = 0; k < abbrs.length; k++) {
          if (abbrs[k].startsWith(kw)) {
            hitPrefix = true;
            break;
          }
          if (!hitContain && abbrs[k].indexOf(kw) >= 0) {
            hitContain = true;
          }
        }
      } else if (isNum) {
        // T9 九宫格数字：2292 命中「璀璨之城」（cczc）
        const abbrs: string[] = abbrsOf(s.text);
        for (let k = 0; k < abbrs.length; k++) {
          const t9: string = abbrToT9(abbrs[k]);
          if (t9.startsWith(kw)) {
            hitPrefix = true;
            break;
          }
          if (!hitContain && t9.indexOf(kw) >= 0) {
            hitContain = true;
          }
        }
      } else {
        if (t.startsWith(kw)) {
          hitPrefix = true;
        } else if (t.indexOf(kw) >= 0) {
          hitContain = true;
        }
      }
      if (hitPrefix) {
        prefix.push(s);
      } else if (hitContain) {
        contain.push(s);
      }
    }
    this.sugg = prefix.concat(contain).slice(0, 12);
  }

  /** 点右侧建议词：填入输入框并直接搜索（建议词点击无需防抖，立即刷新） */
  private pickSugg(s: Sug): void {
    Feedback.tap();
    this.kw = s.text;
    this.doRefreshSugg();
    this.doSearch();
  }

  async clearKws(): Promise<void> {
    const n: number = this.kws.length;
    await Store.clearKeywords();
    this.kws = [];
    // 清空后联想池里还有旧关键词，一并重建，否则右侧建议仍显示已清掉的词
    await this.buildPool();
    this.doRefreshSugg();
    Tip.show(n > 0 ? ('已清空 ' + n + ' 条搜索记录') : '没有搜索记录');
  }

  /**
   * 长按删掉一条搜索记录。
   *
   * 只摘这一个词，其余记录连点击次数都保留（次数决定「猜你想搜」的排序，
   * 整体清空会把这些偏好一起丢掉）。
   */
  async removeKw(kw: string): Promise<void> {
    // 记下时间，onClick 里据此跳过「长按抬起后紧跟的那次点击」
    this.lastKwDelMs = Date.now();
    this.kws = await Store.removeKeyword(kw);
    // 联想池里也存着这个关键词，不重建的话右侧「猜你想搜」还挂着刚删掉的那条
    await this.buildPool();
    this.doRefreshSugg();
    Tip.show('已删除「' + kw + '」');
  }

  /**
   * 搜一个站源。
   *
   * gen 是「第几次搜索」的编号：每次点搜索都会 +1，返回时对不上就丢掉。
   * 不加这个的话，用户改了关键词再搜，上一轮还在飞的请求陆续回来，
   * 会把旧关键词的结果混进新列表里 —— 表现为「明明搜的是 A，列表里全是 B」。
   */
  async one(s: Site, kw: string, gen: number): Promise<void> {
    try {
      const cms = new Cms(s);
      const list: Vod[] = await cms.search(kw);
      if (gen !== this.gen) {
        return;
      }
      if (list.length > 0) {
        const g = new Group();
        g.key = s.key;
        g.site = s.name;
        g.items = list;
        this.groups = this.groups.concat([g]);
      }
    } catch (err) {
      // 单个站源失败不影响整体
    }
  }

  async doSearch(): Promise<void> {
    const kw: string = this.kw.trim();
    if (kw.length === 0) {
      this.err = '请输入关键词';
      return;
    }
    const my: number = ++this.gen;
    this.loading = true;
    this.err = '';
    this.groups = [];
    // 收起输入法 + 让输入框失焦。
    // 不收起的话（平板/手机上尤其明显）软键盘和「粘贴/全选」浮动菜单会盖住
    // 下半屏，搜索结果明明出来了却看不见，用户以为没搜到。
    this.blurInput();
    // 记进历史，下次在空态里点一下就能重搜
    this.kws = await Store.pushKeyword(kw);

    const all: Site[] = await Store.activeSites();
    const targets: Site[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].searchable) {
        targets.push(all[i]);
      }
      if (targets.length >= 18) {
        break;
      }
    }
    if (targets.length === 0) {
      this.loading = false;
      this.err = '没有启用任何可搜索的站源';
      return;
    }

    const BATCH: number = 6;
    for (let i = 0; i < targets.length; i += BATCH) {
      const batch: Site[] = targets.slice(i, i + BATCH);
      const ps: Promise<void>[] = [];
      for (let k = 0; k < batch.length; k++) {
        ps.push(this.one(batch[k], kw, my));
      }
      if (my !== this.gen) {
        return;              // 期间用户又搜了别的，这一轮的结果全部作废
      }
      this.progress = '已搜索 ' + Math.min(i + BATCH, targets.length) + ' / ' + targets.length + ' 个站源';
      await Promise.all(ps);
      this.loading = this.groups.length === 0;
    }
    if (my !== this.gen) {
      return;
    }
    this.progress = '';
    this.loading = false;
    if (this.groups.length === 0) {
      this.err = '没有搜到「' + this.kw.trim() + '」';
      // 搜不到时换一批热门推荐（偶数轮按搜索历史加权，奇数轮随机取一页）
      await this.loadHotVods();
    }
  }

  /** 收起软键盘并把焦点从输入框挪走（焦点一走，文本选择菜单也会消失） */
  blurInput(): void {
    try {
      inputMethod.getController().stopInputSession();
    } catch (err) {
      // 没有输入法/已收起时忽略
    }
    focusControl.requestFocus('search_btn');
  }

  openDetail(g: Group, v: Vod): void {
    const p = new DetailParam();
    p.siteKey = g.key;
    p.siteName = g.site;
    p.vodId = v.id;
    router.pushUrl({ url: 'pages/Detail', params: p });
  }

  /** 点击热门推荐:直接用片名搜索 */
  openHotVod(v: Vod): void {
    this.kw = v.name;
    this.doSearch();
  }

  /**
   * 搜不到结果时换一批热门推荐，别让空态永远挂着同一批片名。
   * 偶数轮：按搜索历史词加权（kws 已按「次数×时间衰减」排序，靠前更贴合偏好）；
   * 奇数轮：从 feed 的随机位置起环绕取一页。
   * feed 为空时保留原推荐，不把已有内容清空。
   */
  private async loadHotVods(): Promise<void> {
    this.hotRound += 1;
    const feed: Vod[] = await Store.feed();
    if (feed.length === 0) {
      return;
    }
    const picked: Vod[] = [];
    if (this.hotRound % 2 === 0) {
      for (let i = 0; i < this.kws.length && picked.length < 12; i++) {
        const kw: string = this.kws[i].trim();
        if (kw.length === 0) {
          continue;
        }
        for (let j = 0; j < feed.length && picked.length < 12; j++) {
          if (feed[j].name.indexOf(kw) >= 0 && picked.indexOf(feed[j]) < 0) {
            picked.push(feed[j]);
          }
        }
      }
      for (let j = 0; j < feed.length && picked.length < 12; j++) {
        if (picked.indexOf(feed[j]) < 0) {
          picked.push(feed[j]);
        }
      }
    } else {
      const start: number = Math.floor(Math.random() * feed.length);
      for (let k = 0; k < feed.length && picked.length < 12; k++) {
        const v: Vod = feed[(start + k) % feed.length];
        if (picked.indexOf(v) < 0) {
          picked.push(v);
        }
      }
    }
    this.hotVods = picked;
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

  /** 当前输入是否纯字母（拼音首字母缩写输入） */
  private letterInput(): boolean {
    const kw: string = this.kw.trim().toLowerCase();
    return kw.length > 0 && /^[a-z]+$/.test(kw);
  }

  /** 当前输入是否纯数字（T9 九宫格输入） */
  private numInput(): boolean {
    const kw: string = this.kw.trim();
    return kw.length > 0 && /^[0-9]+$/.test(kw);
  }

  /**
   * 建议项提示：字母输入显示拼音缩写（cczc），数字输入显示 T9 数字串（2292）。
   * 名称始终作为主信息完整显示，这里只是右侧灰色小字补充。
   */
  private hintLabel(text: string): string {
    const abbrs: string[] = abbrsOf(text);
    if (abbrs.length === 0) {
      return '';
    }
    if (this.numInput()) {
      const t9s: string[] = [];
      for (let i = 0; i < abbrs.length; i++) {
        const t9: string = abbrToT9(abbrs[i]);
        if (t9s.indexOf(t9) < 0) {
          t9s.push(t9);
        }
        if (t9s.length >= 2) {
          break;
        }
      }
      return t9s.join('/');
    }
    if (abbrs.length === 1) {
      return abbrs[0];
    }
    return abbrs[0] + '/' + abbrs[1];
  }

  /** 右侧「猜你想搜」建议面板（仅 TV 端）。内容随输入实时变化 */
  @Builder
  SuggestionPanel() {
    Column() {
      Row() {
        Text('猜你想搜').fontSize(20).fontColor(T.TXT).fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .margin({ bottom: 14 })

      if (this.sugg.length === 0) {
        Column() {
          Text('输入片名或拼音首字母').fontSize(17).fontColor(T.SUB)
          Text('如 sgyy → 三国演义').fontSize(14).fontColor(T.DIM).margin({ top: 8 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.sugg, (s: Sug, i: number) => {
            ListItem() {
              Row() {
                Text(s.text)
                  .fontSize(17)
                  .fontColor(this.hi('sug' + i) ? T.SELECTED : T.TXT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                if (this.letterInput() || this.numInput()) {
                  Text(this.hintLabel(s.text))
                    .fontSize(12)
                    .fontColor(this.hi('sug' + i) ? T.SUB : T.DIM)
                    .margin({ left: 8 })
                }
                Text(s.from === 'hist' ? '搜过' : '热播')
                  .fontSize(11)
                  .fontColor(s.from === 'hist' ? T.SUB : T.DIM)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  .borderRadius(8)
                  .backgroundColor(T.WHITE_15)
                  .margin({ left: 8 })
                Text('›').fontSize(20).fontColor(T.DIM).margin({ left: 8 })
              }
              .width('100%')
              .padding({ left: 18, right: 16, top: 13, bottom: 13 })
              .borderRadius(10)
              .backgroundColor(this.hi('sug' + i) ? T.CARD_HI : T.CARD)
              .border({ width: T.BORDER, color: this.hi('sug' + i) ? T.ACCENT : '#00000000' })
              .focusable(true)
              .onFocus(() => this.hoverTo('sug' + i, true))
              .onBlur(() => this.hoverTo('sug' + i, false))
              .onHover((hv: boolean) => this.hoverTo('sug' + i, hv))
              .onClick(() => Pointer.fire('sr_sug' + i, () => { this.pickSugg(s); }))
              .onMouse(Pointer.on('sr_sug' + i, () => { this.pickSugg(s); }))
            }
          }, (s: Sug, i: number) => 'sug' + i + s.text)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 搜索状态行：loading / 错误 / 命中数 */
  @Builder
  StatusRow() {
    Row() {
      if (this.loading) {
        LoadingProgress().width(26).height(26).color(T.ACCENT)
        Text('搜索中… ' + this.progress).fontSize(16).fontColor(T.SUB).margin({ left: 10 })
      } else if (this.err.length > 0) {
        Text(this.err).fontSize(17).fontColor(T.WARN)
      } else if (this.groups.length > 0) {
        Text('共命中 ' + this.groups.length + ' 个站源').fontSize(16).fontColor(T.DIM)
      }
    }
    .width('100%')
    .padding({ left: 56, right: 56 })
    .height(34)
  }

  /** 主体:空态(最近搜过 / 热门推荐 / 提示)或搜索结果列表 */
  @Builder
  ResultBody() {
    if (this.groups.length === 0 && !this.loading) {
      Scroll() {
        Column() {
          if (this.kws.length > 0) {
            Row() {
              Text('最近搜过').fontSize(19).fontColor(T.SUB)
              Text('· 长按可删除').fontSize(13).fontColor(T.DIM).margin({ left: 8 })
              Blank()
              Text('清空记录')
                .fontSize(15)
                .fontColor(this.hi('clear') ? T.ERR : T.DIM)
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .focusable(true)
                .onFocus(() => this.hoverTo('clear', true))
                .onBlur(() => this.hoverTo('clear', false))
                .onHover((hv: boolean) => this.hoverTo('clear', hv))
                .onClick(() => Pointer.fire('sr_kwclr', () => { Feedback.tap(); this.clearKws(); }))
                .onMouse(Pointer.on('sr_kwclr', () => { Feedback.tap(); this.clearKws(); }))
            }
            .width('100%')
            .margin({ bottom: 14 })

            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.kws, (k: string, i: number) => {
                Text(k)
                  .fontSize(16)
                  .fontColor(this.hi('kw' + i) ? T.SELECTED : T.TXT)
                  .backgroundColor(this.hi('kw' + i) ? T.CARD_HI : T.CARD)
                  .height(40)
                  .padding({ left: 14, right: 14 })
                  .borderRadius(T.RADIUS_PILL)
                  .border({ width: T.BORDER, color: this.hi('kw' + i) ? T.TXT : '#00000000' })
                  .margin({ right: 8, bottom: 8 })
                  .textAlign(TextAlign.Center)
                  .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                  .focusable(true)
                  .onFocus(() => this.hoverTo('kw' + i, true))
                  .onBlur(() => this.hoverTo('kw' + i, false))
                  .onHover((hv: boolean) => this.hoverTo('kw' + i, hv))
                  .onClick(() => Pointer.fire('sr_kw' + k, () => {
                      // 长按删除后的抬手会再补一次 click，吞掉，否则「删一条」变成「删完又搜一次」
                      if (Date.now() - this.lastKwDelMs < 900) {
                        return;
                      }
                      Feedback.tap();
                      this.kw = k;
                      this.doSearch();
                  }))
                  .onMouse(Pointer.on('sr_kw' + k, () => {
                      if (Date.now() - this.lastKwDelMs < 900) {
                        return;
                      }
                      Feedback.tap();
                      this.kw = k;
                      this.doSearch();
                  }))
                  // 长按删除这一条（触屏长按、遥控按住确定键都走这里）
                  .gesture(
                    LongPressGesture({ repeat: false, duration: 600 })
                      .onAction(() => {
                        this.removeKw(k);
                      })
                  )
              }, (k: string, i: number) => 'kw' + i + k)
            }
            .width('100%')
            .margin({ bottom: this.hotVods.length > 0 ? 32 : 0 })
          }

          if (this.hotVods.length > 0) {
            Column() {
              Text('热门推荐').fontSize(19).fontColor(T.SUB).width('100%').margin({ bottom: 14 })
              List({ space: 14 }) {
                ForEach(this.hotVods, (v: Vod) => {
                  ListItem() {
                    Column() {
                      Poster({ url: v.pic, w: 104, h: 146 })
                      Text(v.name).fontSize(14).fontColor(T.TXT)
                        .width(104).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 5 })
                    }
                    .padding(6)
                    .borderRadius(10)
                    .backgroundColor(this.hi('hot_' + v.id) ? T.CARD_HI : '#00000000')
                    .border({ width: T.BORDER, color: this.hi('hot_' + v.id) ? T.ACCENT : '#00000000' })
                    .scale({
                      x: this.hi('hot_' + v.id) ? T.HOVER_SCALE : 1,
                      y: this.hi('hot_' + v.id) ? T.HOVER_SCALE : 1
                    })
                    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                    .onHover((hv: boolean) => this.hoverTo('hot_' + v.id, hv))
                    .focusable(true)
                    .onFocus(() => { this.focusKey = 'hot_' + v.id; })
                    .onBlur(() => { if (this.focusKey === ('hot_' + v.id)) { this.focusKey = ''; } })
                    .onClick(() => Pointer.fire('sr_hot' + v.id, () => { Feedback.tap(); this.openHotVod(v); }))
                    .onMouse(Pointer.on('sr_hot' + v.id, () => { Feedback.tap(); this.openHotVod(v); }))
                  }
                }, (v: Vod) => 'hot' + v.id)
              }
              .listDirection(Axis.Horizontal)
              .width('100%')
              .height(178)
              .scrollBar(BarState.Off)
            }
            .width('100%')
          }

          if (this.kws.length === 0 && this.hotVods.length === 0) {
            Column() {
              Text('搜索影片').fontSize(26).fontColor(T.SUB)
              Text('会在已启用的协议型站源里并发检索(最多 18 个)').fontSize(16).fontColor(T.DIM).margin({ top: 10 })
              Text(this.isPhone ? '点上方输入框,输片名后点「搜索」' : '用遥控器指针点一下输入框,输片名后点「搜索」').fontSize(15).fontColor(T.DIM).margin({ top: 18 })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
        }
        .width('100%')
        .padding({ left: 24, right: 24, top: 24 })
      }
      .width('100%').layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    } else {
      // 下拉重搜：换个站源顺序或站源刚恢复时，用户的第一反应都是往下拉一把。
      // Refresh 必须**直接**套在 List 上，中间夹容器就识别不到滚动位置
      Refresh({ refreshing: $$this.refreshing }) {
      List({ space: 6 }) {
        ForEach(this.groups, (g: Group) => {
          ListItem() {
            Column() {
              Row() {
                Text(g.site).fontSize(19).fontColor(T.TXT).fontWeight(FontWeight.Medium)
                Text(g.items.length + ' 个结果').fontSize(14).fontColor(T.DIM).margin({ left: 12 })
              }
              .width('100%')
              .margin({ top: 6, bottom: 6 })

              List({ space: 14 }) {
                ForEach(g.items, (v: Vod) => {
                  ListItem() {
                    Column() {
                      Poster({ url: v.pic, w: 104, h: 146 })
                      Text(v.name).fontSize(14).fontColor(T.TXT)
                        .width(104).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 5 })
                    }
                    .padding(6)
                    .borderRadius(10)
                    .backgroundColor(this.hi('r_' + g.key + v.id) ? T.CARD_HI : '#00000000')
                    .border({ width: T.BORDER, color: this.hi('r_' + g.key + v.id) ? T.ACCENT : '#00000000' })
                    .scale({
                      x: this.hi('r_' + g.key + v.id) ? T.HOVER_SCALE : 1,
                      y: this.hi('r_' + g.key + v.id) ? T.HOVER_SCALE : 1
                    })
                    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                    .onHover((hv: boolean) => this.hoverTo('r_' + g.key + v.id, hv))
                    .focusable(true)
                    .onFocus(() => { this.focusKey = 'r_' + g.key + v.id; })
                    .onBlur(() => { if (this.focusKey === ('r_' + g.key + v.id)) { this.focusKey = ''; } })
                    .onClick(() => Pointer.fire('sr_r' + g.key + v.id, () => { Feedback.tap(); this.openDetail(g, v); }))
                    .onMouse(Pointer.on('sr_r' + g.key + v.id, () => { Feedback.tap(); this.openDetail(g, v); }))
                  }
                }, (v: Vod) => 'r' + g.key + v.id)
              }
              .listDirection(Axis.Horizontal)
              .width('100%')
              .height(178)
              .scrollBar(BarState.Off)
            }
            .width('100%')
          }
        }, (g: Group) => 'g' + g.key)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 24, right: 24, bottom: 24 })
      .scrollBar(BarState.Auto)
      }
      .width('100%')
      .layoutWeight(1)
      .onRefreshing(() => {
        this.refreshing = true;
        // 搜索本身不缓存，重跑一遍就是最新结果
        this.doSearch().then(() => {
          this.refreshing = false;
        });
      })
    }
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
          .onClick(() => Pointer.fire('sr_back', () => { Feedback.tap(); router.back(); }))
          .onMouse(Pointer.on('sr_back', () => { Feedback.tap(); router.back(); }))
        Stack({ alignContent: Alignment.End }) {
          TextInput({ text: this.kw, placeholder: '输入片名，回车搜索' })
            .height(52)
            .width('100%')
            .fontSize(20)
            .fontColor(T.TXT)
            .placeholderColor(T.DIM)
            .backgroundColor(T.CARD)
            .borderRadius(26)
            .padding({ left: 22, right: 52 })
            .onChange((v: string) => { this.kw = v; this.refreshSugg(); })
            .onSubmit(() => { this.doSearch(); })
          // 电视上指针定位光标改字很别扭，给一个一键清空的入口
          if (this.kw.length > 0) {
            Text('×')
              .fontSize(28).fontColor(this.hi('clr') ? T.TXT : T.DIM)
              .width(44).height(44).textAlign(TextAlign.Center)
              .borderRadius(22).margin({ right: 6 })
              .focusable(true)
              .onFocus(() => this.hoverTo('clr', true))
              .onBlur(() => this.hoverTo('clr', false))
              .onHover((hv: boolean) => this.hoverTo('clr', hv))
              .onClick(() => Pointer.fire('sr_clr', () => { Feedback.tap(); this.kw = ''; }))
              .onMouse(Pointer.on('sr_clr', () => { Feedback.tap(); this.kw = ''; }))
          }
        }
        .layoutWeight(this.isPhone ? 1 : 0)
        .width(this.isPhone ? '100%' : 560)
        .height(52)
        Button('搜索')
          .id('search_btn')
          .focusable(true)
          .hoverEffect(HoverEffect.Scale)
          .fontSize(19).height(52).borderRadius(26)
          // colorPrimary 是白，所以 onPrimary 必须用深色字，否则白底白字
          .backgroundColor(T.ACCENT).fontColor(T.BG)
          .padding({ left: 30, right: 30 })
          .margin({ left: 14 })
          .onClick(() => Pointer.fire('sr_go', () => { Feedback.tap(); this.doSearch(); }))
          .onMouse(Pointer.on('sr_go', () => { Feedback.tap(); this.doSearch(); }))
        // TV 端：输入框收窄靠左，右侧空间留给下面的建议栏
        if (!this.isPhone) {
          Blank()
        }
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 24, bottom: 8 })

      if (this.isPhone) {
        // 手机端：单栏（状态行 + 主体）
        this.StatusRow()
        this.ResultBody()
      } else {
        // TV 端：左右两栏——左栏输入+结果，右栏联想建议
        Row() {
          Column() {
            this.StatusRow()
            this.ResultBody()
          }
          .layoutWeight(1)
          .height('100%')

          Column() {
            this.SuggestionPanel()
          }
          .width(400)
          .height('100%')
          .padding({ left: 20, top: 4 })
        }
        .width('100%')
        .layoutWeight(1)
      }
      if (this.isPhone) {
        PhoneTabBar('pages/Search')
      }
    }
    .width('100%')
    .height('100%')

    // 轻提示是 Stack 的第二层，浮在页面之上。位置必须在这里：
    // 上一条 .width/.height 是 Column 的修饰符，写到 if 之后就会被解析到
    // Stack 上，改成 Column 的修饰符链就断了。
    if (this.tipMsg.length > 0) {
      TipLayer({ msg: this.tipMsg })
    }
  }
  .width('100%')
  .height('100%')
  .alignContent(Alignment.Center)
    .backgroundColor(T.pageBg(this.themeMode))
    // id 带主题名：让 build 真正依赖 themeMode（否则换色板不重绘）
    .id('search_' + this.themeMode)
  }
}
