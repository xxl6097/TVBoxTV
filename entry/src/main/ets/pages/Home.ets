/**
 * 首页 —— 对照 FongMi TV 版（leanback）的 activity_home.xml + HomeActivity。
 *
 * 原版结构（自上而下）：
 *   toolbar：logo 48dp + 标题 24sp + 时钟 24sp，padding 24dp
 *   VerticalGridView（多行）：
 *     ① 功能行：点播 / 直播 / 搜索 / 收藏 / 设置，每块 100dp × 100dp
 *     ② 继续观看行（历史）
 *     ③ 推荐行（分类海报横滑）
 *
 * 视觉规范全部照 res 取值：
 *   背景 #141218，行标题 24sp，卡片 8dp 圆角，选中 1.5dp 白描边（取整 2）
 */

import { Feedback } from '../common/Feedback';
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import display from '@ohos.display';
import { Store, HistItem } from '../common/Store';
import { Vod, DetailParam, T } from '../common/Model';
import { Crawler, CrawlResult } from '../common/Crawler';
import { Tip, TIP_MSG, TipLayer } from '../common/Tip';
import { KEY_IS_PHONE } from '../common/Device';
import { PhoneTabBar } from '../common/PhoneTabBar';
import { isBackCode } from '../common/TvFocus';

/** 功能块列模板：必须是 1fr × N，用固定宽度会让最后一格溢出屏幕 */
const FUNC_COLS: string = '1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr';

class Func {
  label: string = '';
  page: string = '';
}

function funcs(): Func[] {
  const out: Func[] = [];
  const labels: string[] = ['点播', '直播', '直连', '网盘', '搜索', '收藏', '历史', '设置'];
  const pages: string[] = ['pages/VodPage', 'pages/LivePage', 'pages/Direct', 'pages/WebdavPage',
    'pages/Search', 'pages/CollectPage', 'pages/HistoryPage', 'pages/SettingPage'];
  for (let i = 0; i < labels.length; i++) {
    const f = new Func();
    f.label = labels[i];
    f.page = pages[i];
    out.push(f);
  }
  return out;
}

/**
 * 首页轨道卡片的尺寸与视觉参数 —— 参照 tvOS 的「海报墙 + 悬浮抬起」。
 *
 * 之前是「200×100 图 + 下方一条灰色标题栏」，看起来像表格单元格：
 * 标题被框在一个色块里、和海报是两块分离的方块，整体没有「一叠卡片」的质感。
 * tvOS 的做法是海报自己就是卡片（圆角、投影、悬停抬起），文字浮在海报下方，
 * 不另加底色；继续观看还会在海报底部压一条观看进度。
 */
class R {
  /** 海报宽高：16:9。208 宽在这块 809vp 的屏上正好露出 3 张半，暗示可横滑 */
  static readonly W: number = 208;
  static readonly H: number = 117;
  static readonly GAP: number = 16;
  static readonly RADIUS: number = 10;
  /** 悬停抬起倍率：比列表页的 1.1 克制，横向轨道上抬太多会互相压住 */
  static readonly SCALE: number = 1.06;
  /** 进度条高度 */
  static readonly BAR_H: number = 3;
}

/** 首页轨道卡片共用的「抬起」效果：缩放 + 投影 + 白色描边 */
@Extend(Column)
function railLift(focused: boolean) {
  .scale({ x: focused ? R.SCALE : 1, y: focused ? R.SCALE : 1 })
  .shadow({
    radius: focused ? 22 : 0,
    color: focused ? '#B3000000' : '#00000000',
    offsetX: 0,
    offsetY: focused ? 8 : 0
  })
  .animation({ duration: 180, curve: Curve.FastOutSlowIn })
}

/**
 * 「继续观看」卡片：海报 + 底部观看进度条 + 标题 + 集数/时间。
 *
 * 为什么单独做一个组件而不是在 build 里内联：这条轨道每张卡片都要读
 * 自己的进度百分比和悬停态，内联会让 build 变成一大段重复代码；
 * 用 @Component + @Prop 还能保证 hover 状态变化时只有对应那张卡重建。
 */
@Component
struct ContinueCard {
  @Prop pic: string = '';
  @Prop name: string = '';
  @Prop epName: string = '';
  @Prop meta: string = '';
  /** 观看进度 0~1；<=0 表示时长未知，不画进度条 */
  @Prop ratio: number = 0;
  @Prop focused: boolean = false;
  onTap: () => void = () => {
  };
  onHoverIn: (on: boolean) => void = () => {
  };
  /** 单条删除（右上角「✕」） */
  onDelete: () => void = () => {
  };
  /** 删除按钮自身的悬停高亮 */
  @State delHover: boolean = false;

  build() {
    Column() {
      Stack() {
        Image(this.pic.length > 0 ? this.pic : $r('app.media.app_icon'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .borderRadius(R.RADIUS)

        // 观看进度：tvOS 在缩略图底部压一条细线，一眼看出看到哪了。
        // 时长未知（老记录）就不画，避免出现一条永远不动的空槽。
        if (this.ratio > 0) {
          Column() {
            Row()
              .width((this.ratio * 100) + '%')
              .height(R.BAR_H)
              .backgroundColor(T.TXT)
          }
          .width('100%')
          .height(R.BAR_H)
          .backgroundColor('#73000000')
          .alignItems(HorizontalAlign.Start)
          .borderRadius({ bottomLeft: R.RADIUS, bottomRight: R.RADIUS })
          .align(Alignment.Bottom)
        }

        // 单条删除：右上角小圆「✕」。触屏直接点；电视端悬停变亮后点。
        // 子组件有自己的 onClick，点击时不会冒泡触发整张卡的 onTap（不会误进详情）。
        // 用 position 绝对定位到海报右上角（align 在此 SDK 上对 Text 定位不稳）。
        Text('✕')
          .width(22)
          .height(22)
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor(this.delHover ? T.ERR : '#B3000000')
          .borderRadius(11)
          .textAlign(TextAlign.Center)
          .position({ x: R.W - 22 - 5, y: 5 })
          .onHover((hv: boolean) => {
            this.delHover = hv;
          })
          .onClick(() => {
            Feedback.tap();
            this.onDelete();
          })
      }
      .width(R.W)
      .height(R.H)
      .borderRadius(R.RADIUS)
      .border({ width: 2, color: this.focused ? T.TXT : '#00000000' })

      Text(this.name)
        .fontSize(14.5)
        .fontWeight(this.focused ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.focused ? T.TXT : T.SUB)
        .width(R.W)
        .margin({ top: 7 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.meta.length > 0) {
        Text(this.meta)
          .fontSize(12)
          .fontColor(this.focused ? T.DIM : '#66FFFFFF')
          .width(R.W)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width(R.W)
    .alignItems(HorizontalAlign.Start)
    .railLift(this.focused)
    // 遥控器：可聚焦，焦点进入/离开复用悬停高亮（鼠标 onHover 与焦点 onFocus 并存）
    .focusable(true)
    .onFocus(() => {
      this.onHoverIn(true);
    })
    .onBlur(() => {
      this.onHoverIn(false);
    })
    .onHover((hv: boolean) => {
      this.onHoverIn(hv);
    })
    .onClick(() => {
      Feedback.tap();
      this.onTap();
    })
  }
}

/** 「最近更新」卡片：海报 + 右上角更新状态角标 + 标题 + 类型/年份 */
@Component
struct FeedCard {
  @Prop pic: string = '';
  @Prop name: string = '';
  @Prop remark: string = '';
  @Prop meta: string = '';
  @Prop focused: boolean = false;
  onTap: () => void = () => {
  };
  onHoverIn: (on: boolean) => void = () => {
  };

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Image(this.pic.length > 0 ? this.pic : $r('app.media.app_icon'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .borderRadius(R.RADIUS)

        // 更新状态改成右上角小药丸：原来是一条横贯整图的深绿条，
        // 压在画面上既挡内容又像「字幕条」，tvOS 一律用角标。
        if (this.remark.length > 0) {
          Text(this.remark)
            .fontSize(11)
            .fontColor(T.TXT)
            .backgroundColor('#B3121218')
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .borderRadius(6)
            .margin({ top: 7, right: 7 })
            .maxLines(1)
        }
      }
      .width(R.W)
      .height(R.H)
      .borderRadius(R.RADIUS)
      .border({ width: 2, color: this.focused ? T.TXT : '#00000000' })

      Text(this.name)
        .fontSize(14.5)
        .fontWeight(this.focused ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.focused ? T.TXT : T.SUB)
        .width(R.W)
        .margin({ top: 7 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.meta.length > 0) {
        Text(this.meta)
          .fontSize(12)
          .fontColor(this.focused ? T.DIM : '#66FFFFFF')
          .width(R.W)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width(R.W)
    .alignItems(HorizontalAlign.Start)
    .railLift(this.focused)
    .focusable(true)
    .onFocus(() => {
      this.onHoverIn(true);
    })
    .onBlur(() => {
      this.onHoverIn(false);
    })
    .onHover((hv: boolean) => {
      this.onHoverIn(hv);
    })
    .onClick(() => {
      Feedback.tap();
      this.onTap();
    })
  }
}

@Entry
@Component
struct Home {
  /** 设备形态：true=手机（底部 Tab + 网格 + 触摸），false=电视（顶部功能行 + 横向轨道 + 焦点） */
  @StorageProp(KEY_IS_PHONE) isPhone: boolean = false;
  @State hist: HistItem[] = [];
  /** 「清空全部」的二次确认窗口：6 秒内再点一次才真清 */
  @State confirmClearHist: boolean = false;
  /** 全局轻提示（AppStorage 上的 TIP_MSG），Tip.show() 触发 */
  @StorageLink(TIP_MSG) tipMsg: string = '';
  @State feed: Vod[] = [];
  @State hoverKey: string = '';
  @State clock: string = '';
  @State title: string = '夜帧影视';
  @State ready: boolean = false;
  @State items: Func[] = [];
  /**
   * 隐私同意门禁。
   *
   * 应用市场要求：首次启动必须先弹隐私政策、用户同意后才能联网。
   * 所以 consentReady 为 false 时，aboutToAppear 里**什么都不做**——
   * 不读配置、不抓站源、不连任何地址，等用户点了同意再说。
   */
  @State consentReady: boolean = false;
  @State agreed: boolean = false;
  @State showGuide: boolean = false;
  @State guideStep: number = 0;
  /** 是否已经导入站源（订阅/手动导入过）。空态文案据此区分「去订阅」还是「正在更新」 */
  @State hasSites: boolean = false;
  /** 是否正在抓最新。改成 @State 才能驱动空态里的「正在更新…」加载提示 */
  @State crawling: boolean = false;

  private tick: number = -1;
  private clockTick: number = -1;

  async aboutToAppear(): Promise<void> {
    this.items = funcs();
    await Store.init(getContext(this) as common.UIAbilityContext);
    const ok: boolean = await Store.privacyAgreed();
    this.consentReady = true;
    this.agreed = ok;
    if (!ok) {
      // 未同意前不联网、不读缓存内容，界面只留一个隐私政策面板
      return;
    }
    await this.boot();
  }

  /** 同意之后才跑的正常启动流程 */
  async boot(): Promise<void> {
    await Store.ensureLoaded();
    this.title = '夜帧影视';
    await this.reload();
    this.ready = true;
    this.autoCrawl();

    this.setClock();
    this.clockTick = setInterval(() => {
      this.setClock();
    }, 1000);
    this.tick = setInterval(() => {
      this.autoCrawl();
    }, 30 * 60 * 1000);

    const g: boolean = await Store.guideDone();
    if (!g) {
      this.showGuide = true;
    }
  }

  /** 同意隐私政策 */
  async agree(): Promise<void> {
    await Store.setPrivacyAgreed();
    this.agreed = true;
    await this.boot();
  }

  /** 不同意就退出。不能只是关掉面板——那等于替用户同意了 */
  disagree(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    ctx.terminateSelf();
  }

  async closeGuide(): Promise<void> {
    await Store.setGuideDone();
    this.showGuide = false;
  }

  aboutToDisappear(): void {
    if (this.tick >= 0) {
      clearInterval(this.tick);
      this.tick = -1;
    }
    if (this.clockTick >= 0) {
      clearInterval(this.clockTick);
      this.clockTick = -1;
    }
  }

  async onPageShow(): Promise<void> {
    if (this.ready) {
      await this.reload();
      this.autoCrawl();
    }
  }

  setClock(): void {
    const d = new Date();
    const h: string = d.getHours() < 10 ? ('0' + d.getHours()) : String(d.getHours());
    const m: string = d.getMinutes() < 10 ? ('0' + d.getMinutes()) : String(d.getMinutes());
    const s: string = d.getSeconds() < 10 ? ('0' + d.getSeconds()) : String(d.getSeconds());
    this.clock = h + ':' + m + ':' + s;
  }

  async reload(): Promise<void> {
    this.hist = await Store.history();
    this.feed = await Store.feed();
    this.hasSites = Store.sites().length > 0;
  }

  /** 单条删除继续观看记录 */
  async removeHist(h: HistItem): Promise<void> {
    await Store.removeHistory(h);
    this.hist = await Store.history();
    Tip.show('已删除「' + h.name + '」');
  }

  /** 全部清空（带二次确认，误触不可恢复） */
  async clearHist(): Promise<void> {
    const n: number = this.hist.length;
    if (n === 0) {
      return;
    }
    if (!this.confirmClearHist) {
      this.confirmClearHist = true;
      Tip.show('再点一次确认清空（共 ' + n + ' 条），6 秒内有效');
      setTimeout(() => {
        this.confirmClearHist = false;
      }, 6000);
      return;
    }
    this.confirmClearHist = false;
    await Store.clearHistory();
    this.hist = [];
    Tip.show('已清空 ' + n + ' 条记录');
  }

  async autoCrawl(): Promise<void> {
    if (this.crawling) {
      return;
    }
    this.crawling = true;
    try {
      const r: CrawlResult | null = await Crawler.maybeRun();
      if (r !== null) {
        this.feed = await Store.feed();
      }
    } catch (err) {
      // 定时任务失败不打扰
    } finally {
      this.crawling = false;
    }
  }

  /**
   * 轨道标题行 —— tvOS 的「标题 + 右侧「全部 ›」」。
   *
   * 比原来只有一行 24vp 大字多了三件事：左侧标题下方的小字给出规模，
   * 右侧给一个明确的「全部」入口（不用先点进某个片子才知道还有更多），
   * 悬停时「全部」整块变亮，指针用户知道这里能点。
   */
  @Builder
  RailHeader(title: string, sub: string, key: string, act: () => void) {
    Row() {
      Text(title)
        .fontSize(21)
        .fontWeight(FontWeight.Medium)
        .fontColor(T.TXT)
      Text(sub)
        .fontSize(13)
        .fontColor(T.DIM)
        .margin({ left: 10 })
      Blank()
      Row() {
        Text('全部')
          .fontSize(13)
          .fontColor(this.hi(key) ? T.TXT : T.SUB)
        Text('›')
          .fontSize(17)
          .fontColor(this.hi(key) ? T.TXT : T.DIM)
          .margin({ left: 3 })
      }
      .height(30)
      .padding({ left: 12, right: 12 })
      .borderRadius(15)
      .backgroundColor(this.hi(key) ? '#26FFFFFF' : '#00000000')
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .focusable(true)
      .onFocus(() => this.hover(key, true))
      .onBlur(() => this.hover(key, false))
      .onHover((hv: boolean) => this.hover(key, hv))
      .onClick(() => { Feedback.tap(); act(); })
    }
    .width('100%')
    .padding({ top: 12, bottom: 6 })
  }

  /**
   * 「继续观看」专用标题行：比通用 RailHeader 多一个「清空」按钮。
   *
   * 清空带二次确认（confirmClearHist），按钮文案从「清空」变成「确认清空？」，
   * 遥控器用户看完底部提示再移动焦点过去，6 秒窗口内点即生效。
   */
  @Builder
  HistHeader() {
    Row() {
      Text('继续观看')
        .fontSize(21)
        .fontWeight(FontWeight.Medium)
        .fontColor(T.TXT)
      Text(this.hist.length + ' 部')
        .fontSize(13)
        .fontColor(T.DIM)
        .margin({ left: 10 })
      Blank()
      Row() {
        Text(this.confirmClearHist ? '确认清空？' : '清空')
          .fontSize(13)
          .fontColor(this.confirmClearHist ? T.ERR : (this.hi('clear_h') ? T.TXT : T.SUB))
      }
      .height(30)
      .padding({ left: 12, right: 12 })
      .borderRadius(15)
      .backgroundColor(this.hi('clear_h') ? '#26FFFFFF' : '#00000000')
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .focusable(true)
      .onFocus(() => this.hover('clear_h', true))
      .onBlur(() => this.hover('clear_h', false))
      .onHover((hv: boolean) => this.hover('clear_h', hv))
      .onClick(() => {
        Feedback.tap();
        this.clearHist();
      })
      Row() {
        Text('全部')
          .fontSize(13)
          .fontColor(this.hi('all_h') ? T.TXT : T.SUB)
        Text('›')
          .fontSize(17)
          .fontColor(this.hi('all_h') ? T.TXT : T.DIM)
          .margin({ left: 3 })
      }
      .height(30)
      .padding({ left: 12, right: 12 })
      .borderRadius(15)
      .backgroundColor(this.hi('all_h') ? '#26FFFFFF' : '#00000000')
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .focusable(true)
      .onFocus(() => this.hover('all_h', true))
      .onBlur(() => this.hover('all_h', false))
      .onHover((hv: boolean) => this.hover('all_h', hv))
      .onClick(() => {
        Feedback.tap();
        this.open('pages/HistoryPage');
      })
      .margin({ left: 6 })
    }
    .width('100%')
    .padding({ top: 12, bottom: 6 })
  }

  /**
   * 继续观看的观看进度（0~1）。
   *
   * 时长未知时返回 0，卡片就不画进度条 —— 而不是画一条 0% 的槽，
   * 那会让人以为「一点没看」。看到最后 1 分钟时按 99% 显示，
   * 避免整条填满却还在「继续观看」里出现。
   */
  histRatio(h: HistItem): number {
    const dur: number = h.dur === undefined ? 0 : h.dur;
    if (dur <= 0 || h.pos <= 0) {
      return 0;
    }
    let r: number = h.pos / dur;
    if (r > 0.99) {
      r = 0.99;
    }
    if (r < 0.02) {
      r = 0.02;      // 给个最小可见宽度，否则「刚开始看」和「没看过」看起来一样
    }
    return r;
  }

  /** 继续观看的第二行：第几集 · 看到多少 / 多久以前看的 */
  histMeta(h: HistItem): string {
    const parts: string[] = [];
    if (h.epName.length > 0) {
      parts.push(h.epName);
    }
    const r: number = this.histRatio(h);
    if (r > 0) {
      parts.push('已看 ' + Math.round(r * 100) + '%');
    }
    const ago: string = this.ago(h.time);
    if (ago.length > 0) {
      parts.push(ago);
    }
    return parts.join(' · ');
  }

  /** 最近更新的第二行：类型 / 年份，都没有就退到站源名 */
  feedMeta(v: Vod): string {
    const parts: string[] = [];
    if (v.typeName.length > 0) {
      parts.push(v.typeName);
    }
    if (v.year.length > 0) {
      parts.push(v.year);
    }
    if (parts.length === 0 && v.siteName.length > 0) {
      parts.push(v.siteName);
    }
    return parts.join(' · ');
  }

  /** 相对时间：刚刚 / N 分钟前 / N 小时前 / 昨天 / N 天前 */
  ago(t: number): string {
    if (t <= 0) {
      return '';
    }
    const d: number = Date.now() - t;
    if (d < 60000) {
      return '刚刚';
    }
    if (d < 3600000) {
      return Math.floor(d / 60000) + ' 分钟前';
    }
    if (d < 86400000) {
      return Math.floor(d / 3600000) + ' 小时前';
    }
    if (d < 172800000) {
      return '昨天';
    }
    return Math.floor(d / 86400000) + ' 天前';
  }

  open(page: string): void {
    router.pushUrl({ url: page });
  }

  openDetail(siteKey: string, siteName: string, vodId: string): void {
    const p = new DetailParam();
    p.siteKey = siteKey;
    p.siteName = siteName;
    p.vodId = vodId;
    router.pushUrl({ url: 'pages/Detail', params: p });
  }

  /** 功能块的 36dp 图标（FongMi 用 VectorDrawable，这里换成同尺寸 SVG） */
  iconOf(label: string): Resource {
    if (label === '直播') {
      return $r('app.media.ic_live');
    }
    if (label === '搜索') {
      return $r('app.media.ic_search');
    }
    if (label === '收藏') {
      return $r('app.media.ic_collect');
    }
    if (label === '历史') {
      return $r('app.media.ic_history');
    }
    if (label === '设置') {
      return $r('app.media.ic_setting');
    }
    return $r('app.media.ic_vod');
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

  @Builder
  TvHome() {
    Column() {
      // ---------- toolbar：logo 48dp + marginEnd 12dp，标题 24sp，时钟 24sp，padding 24/24/8 ----------
      Row() {
        Image($r('app.media.app_icon'))
          .width(48)
          .height(48)
          .objectFit(ImageFit.Contain)
          .borderRadius(T.RADIUS)
          .margin({ right: 12 })
        Text(this.title)
          .fontSize(24)
          .fontColor(T.TXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.clock)
          .fontSize(24)
          .fontColor(T.TXT)
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 12, bottom: 4 })

      // ---------- 行式内容 ----------
      Scroll() {
        Column() {
          // ① 功能行
          //
          // 这里**必须**用 Grid 等分，不能用固定 100dp 的 Row：
          // 功能块是 7 个（点播/直播/直连/搜索/收藏/历史/设置），
          // 7×100 + 6×16 = 796vp，而 744vp 宽的屏幕上可用只有 696vp，
          // 最后一格「设置」会被挤出屏幕外——遥控器够不到，等于功能消失。
          // 改成 1fr × 7 后每格约 89vp，7 个都能完整显示，换屏幕宽度也不再溢出。
          Grid() {
            ForEach(this.items, (f: Func) => {
              GridItem() {
                Column() {
                  Image(this.iconOf(f.label))
                    .width(34)
                    .height(34)
                    .objectFit(ImageFit.Contain)
                  Text(f.label)
                    .fontSize(17)
                    .fontColor(T.TXT)
                    .margin({ top: 4 })
                    .maxLines(1)
                }
                .width('100%')
                .height(74)
                .justifyContent(FlexAlign.Center)
                // shape_item_normal：black_20 底 + 4dp 圆角；焦点 shape_item_focused：black_40 + 1.5dp 白描边
                .backgroundColor(this.hi('f_' + f.label) ? T.CARD_HI : T.CARD)
                .borderRadius(T.RADIUS_SM)
                .border({
                  width: T.BORDER,
                  color: this.hi('f_' + f.label) ? T.TXT : '#00000000'
                })
                .scale({
                  x: this.hi('f_' + f.label) ? T.HOVER_SCALE : 1,
                  y: this.hi('f_' + f.label) ? T.HOVER_SCALE : 1
                })
                .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                // 遥控器焦点：聚焦高亮与鼠标悬停共用同一套 hi() 状态。
                // defaultFocus 只落在「点播」这一格（且仅在同意隐私、非引导期），
                // 弹窗出现时由其 focusScope 锁定焦点，不会落到这里。
                .focusable(true)
                .defaultFocus(this.agreed && !this.showGuide && f.label === '点播')
                .onFocus(() => this.hover('f_' + f.label, true))
                .onBlur(() => this.hover('f_' + f.label, false))
                .onHover((hv: boolean) => this.hover('f_' + f.label, hv))
                .onClick(() => {
                  Feedback.tap();
                  this.open(f.page);
                })
              }
            }, (f: Func) => 'func' + f.label)
          }
          .columnsTemplate(FUNC_COLS)
          .columnsGap(12)
          .height(74)
          .width('100%')

          // ② 继续观看（tvOS 轨道：标题行 + 海报墙）
          if (this.hist.length > 0) {
            this.HistHeader()
            Scroll() {
              Row() {
                ForEach(this.hist, (h: HistItem, i: number) => {
                  ContinueCard({
                    pic: h.pic,
                    name: h.name,
                    epName: h.epName,
                    meta: this.histMeta(h),
                    ratio: this.histRatio(h),
                    focused: this.hi('h_' + h.vodId),
                    onTap: () => {
                      this.openDetail(h.siteKey, h.siteName, h.vodId);
                    },
                    onHoverIn: (on: boolean) => this.hover('h_' + h.vodId, on),
                    onDelete: () => {
                      this.removeHist(h);
                    }
                  })
                  .margin({ right: i === this.hist.length - 1 ? 0 : R.GAP })
                },
                // key 必须带上会变的数据。ForEach 只看 key 判断「这一项变了没」：
                // key 不变就不重建 item，@Prop 拿到的还是上一帧的 meta/ratio。
                // 实测只按 siteKey+vodId 做 key，看完第 33 集回到首页，
                // 进度和时间仍停在「4 小时前」——数据早就写进 prefs 了，是 UI 没刷新。
                (h: HistItem) => 'hist' + h.siteKey + h.vodId + '_' + h.time + '_' + h.pos + '_' +
                  (h.dur === undefined ? 0 : h.dur))
              }
              // 横向 Scroll 里这一行**不能**写 width('100%')：
              // 写了以后 Row 宽度被撑成容器宽，内容不再溢出，整行就滚不动了。
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
            // 内容比视口窄时（比如只有 2 张卡）Scroll 默认把子节点居中，
            // 轨道就变成「中间一小撮、两边大片空白」。tvOS 的轨道一律从左边起排，
            // 所以这里显式靠左；内容超出时对齐方式不影响滚动。
            .align(Alignment.Start)
            // 卡片悬停时会放大并投影，轨道上下留出空间，否则投影被裁掉一半
            .padding({ top: 4, bottom: 6 })
          }

          // ③ 最近更新
          if (this.feed.length > 0) {
            this.RailHeader('最近更新', this.feed.length + ' 部', 'all_f', () => {
              this.open('pages/VodPage');
            })
            Scroll() {
              Row() {
                ForEach(this.feed, (v: Vod, i: number) => {
                  FeedCard({
                    pic: v.pic,
                    name: v.name,
                    remark: v.remark,
                    meta: this.feedMeta(v),
                    focused: this.hi('v_' + v.id),
                    onTap: () => {
                      this.openDetail(v.siteKey, v.siteName, v.id);
                    },
                    onHoverIn: (on: boolean) => this.hover('v_' + v.id, on)
                  })
                  .margin({ right: i === this.feed.length - 1 ? 0 : R.GAP })
                }, (v: Vod) => 'feed' + v.siteKey + v.id)
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
            .align(Alignment.Start)
            .padding({ top: 4, bottom: 6 })
          }

          if (this.hist.length === 0 && this.feed.length === 0) {
            if (this.hasSites) {
              // 已订阅但「最近更新」还没抓出来：要么正在抓，要么这轮没抓到数据。
              // 别再让人以为没订阅，给一个明确的「正在更新」状态 + 点播兜底入口。
              Column() {
                Row() {
                  if (this.crawling) {
                    LoadingProgress().width(18).height(18).color(T.SUB)
                  }
                  Text(this.crawling ? '正在更新「最近更新」…' : '已订阅，正在拉取最新影片…')
                    .fontSize(16)
                    .fontColor(T.SUB)
                    .margin({ left: this.crawling ? 10 : 0 })
                }
                Text(this.isPhone ? '也可以直接点底部「点播」按分类浏览，或到「设置 → 内容更新 → 立即更新」。' : '也可以直接点上方「点播」按分类浏览，或到「设置 → 内容更新 → 立即更新」。')
                  .fontSize(13)
                  .fontColor(T.DIM)
                  .margin({ top: 8 })
              }
              .width('100%')
              .margin({ top: 40 })
              .alignItems(HorizontalAlign.Start)
            } else {
              Column() {
                Text('还没有内容。进「设置」点「订阅」，一个链接同时导入点播 + 直播源。')
                  .fontSize(16)
                  .fontColor(T.SUB)
                Text('去订阅')
                  .fontSize(16)
                  .fontColor(T.TXT)
                  .height(44)
                  .padding({ left: 34, right: 34 })
                  .borderRadius(T.RADIUS)
                  .margin({ top: 20 })
                  .border({ width: T.BORDER, color: T.TXT })
                  .focusable(true)
                  .onFocus(() => this.hover('gosub', true))
                  .onBlur(() => this.hover('gosub', false))
                  .onHover((hv: boolean) => this.hover('gosub', hv))
                  .backgroundColor(this.hi('gosub') ? T.CARD_HI : '#00000000')
                  .onClick(() => {
                    Feedback.tap();
                    router.pushUrl({ url: 'pages/SettingPage' });
                  })
              }
              .width('100%')
              .margin({ top: 40 })
              .alignItems(HorizontalAlign.Start)
            }
          }
        }
        .width('100%')
        // 底部留白：最后一行卡片不贴屏幕下沿，滚到底时看着才像「结束了」
        .padding({ left: 24, right: 24, top: 8, bottom: 28 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      // 内容从顶部开始排。Scroll 默认 align=Center，内容比视口矮时会把
      // 功能行（点播/直播/…）垂直居中，导致它们和顶部工具栏之间空一大段。
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(T.BG)
  }

  /** 手机首页：顶部标题栏 + 内容区（横滑继续观看 / 网格最近更新）+ 底部 Tab 导航 */
  @Builder
  PhoneHome() {
    Column() {
      // 顶部标题栏：触屏手机不需要「回首页」按钮，这里只做品牌 + 快捷入口
      Row() {
        Image($r('app.media.app_icon'))
          .width(30)
          .height(30)
          .objectFit(ImageFit.Contain)
          .borderRadius(6)
          .margin({ right: 10 })
        Text(this.title)
          .fontSize(19)
          .fontWeight(FontWeight.Medium)
          .fontColor(T.TXT)
          .maxLines(1)
          .layoutWeight(1)
        Text('直连')
          .fontSize(14)
          .fontColor(T.SUB)
          .padding({ left: 13, right: 13, top: 7, bottom: 7 })
          .borderRadius(T.RADIUS_PILL)
          .backgroundColor(T.CARD)
          .onClick(() => {
            Feedback.tap();
            this.open('pages/Direct');
          })
        Text('网盘')
          .fontSize(14)
          .fontColor(T.SUB)
          .padding({ left: 13, right: 13, top: 7, bottom: 7 })
          .borderRadius(T.RADIUS_PILL)
          .backgroundColor(T.CARD)
          .margin({ left: 8 })
          .onClick(() => {
            Feedback.tap();
            this.open('pages/WebdavPage');
          })
        Text('历史')
          .fontSize(14)
          .fontColor(T.SUB)
          .padding({ left: 13, right: 13, top: 7, bottom: 7 })
          .borderRadius(T.RADIUS_PILL)
          .backgroundColor(T.CARD)
          .margin({ left: 8 })
          .onClick(() => {
            Feedback.tap();
            this.open('pages/HistoryPage');
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 6 })

      // 内容区
      Scroll() {
        Column() {
          // 继续观看：手机保留横滑轨道，触屏左右滑
          if (this.hist.length > 0) {
            this.HistHeader()
            Scroll() {
              Row() {
                ForEach(this.hist, (h: HistItem, i: number) => {
                  ContinueCard({
                    pic: h.pic,
                    name: h.name,
                    epName: h.epName,
                    meta: this.histMeta(h),
                    ratio: this.histRatio(h),
                    focused: this.hi('h_' + h.vodId),
                    onTap: () => {
                      this.openDetail(h.siteKey, h.siteName, h.vodId);
                    },
                    onHoverIn: (on: boolean) => this.hover('h_' + h.vodId, on),
                    onDelete: () => {
                      this.removeHist(h);
                    }
                  })
                  .margin({ right: i === this.hist.length - 1 ? 0 : R.GAP })
                }, (h: HistItem) => 'phist' + h.siteKey + h.vodId + '_' + h.time + '_' + h.pos + '_' +
                  (h.dur === undefined ? 0 : h.dur))
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
            .align(Alignment.Start)
            .padding({ top: 4, bottom: 6 })
          }

          // 最近更新：手机用网格（竖屏 3 列 / 横屏 5 列），触摸点击
          if (this.feed.length > 0) {
            this.RailHeader('最近更新', this.feed.length + ' 部', 'all_f', () => {
              this.open('pages/VodPage');
            })
            Grid() {
              ForEach(this.feed, (v: Vod) => {
                GridItem() {
                  this.PhoneFeedCard(v)
                }
                .onClick(() => {
                  Feedback.tap();
                  this.openDetail(v.siteKey, v.siteName, v.id);
                })
              }, (v: Vod) => 'pfeed' + v.siteKey + v.id)
            }
            .columnsTemplate(this.phoneFeedCols())
            .columnsGap(10)
            .rowsGap(14)
            .width('100%')
            .scrollBar(BarState.Off)
          }

          // 空态
          if (this.hist.length === 0 && this.feed.length === 0) {
            if (this.hasSites) {
              Column() {
                Row() {
                  if (this.crawling) {
                    LoadingProgress().width(18).height(18).color(T.SUB)
                  }
                  Text(this.crawling ? '正在更新「最近更新」…' : '已订阅，正在拉取最新影片…')
                    .fontSize(15)
                    .fontColor(T.SUB)
                    .margin({ left: this.crawling ? 10 : 0 })
                }
                Text('也可以点底部「点播」按分类浏览，或到「设置 → 内容更新 → 立即更新」。')
                  .fontSize(12)
                  .fontColor(T.DIM)
                  .margin({ top: 8 })
              }
              .width('100%')
              .margin({ top: 30 })
              .alignItems(HorizontalAlign.Start)
            } else {
              Column() {
                Text('还没有内容。点右下角「设置」→「订阅」，一个链接同时导入点播 + 直播源。')
                  .fontSize(15)
                  .fontColor(T.SUB)
                Text('去订阅')
                  .fontSize(15)
                  .fontColor(T.TXT)
                  .height(42)
                  .padding({ left: 30, right: 30 })
                  .borderRadius(T.RADIUS)
                  .margin({ top: 16 })
                  .border({ width: T.BORDER, color: T.TXT })
                  .backgroundColor(T.CARD)
                  .onClick(() => {
                    Feedback.tap();
                    router.pushUrl({ url: 'pages/SettingPage' });
                  })
              }
              .width('100%')
              .margin({ top: 30 })
              .alignItems(HorizontalAlign.Start)
            }
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      // 底部 Tab 导航（触屏拇指热区）
      PhoneTabBar('')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(T.BG)
  }

  /** 底部 Tab 项：图标 + 文字，整块可点 */
  @Builder
  PhoneTab(label: string, page: string) {
    Column() {
      Image(this.iconOf(label))
        .width(20)
        .height(20)
        .objectFit(ImageFit.Contain)
      Text(label)
        .fontSize(11)
        .fontColor(T.SUB)
        .margin({ top: 3 })
        .maxLines(1)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      Feedback.tap();
      this.open(page);
    })
  }

  /** 手机「最近更新」海报卡：16:9 图 + 角标 + 标题 + 类型/年份，触摸点击无焦点放大 */
  @Builder
  PhoneFeedCard(v: Vod) {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Image(v.pic.length > 0 ? v.pic : $r('app.media.app_icon'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .borderRadius(R.RADIUS)
        if (v.remark.length > 0) {
          Text(v.remark)
            .fontSize(10)
            .fontColor(T.TXT)
            .backgroundColor('#B3121218')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(5)
            .margin({ top: 5, right: 5 })
            .maxLines(1)
        }
      }
      .width('100%')
      .aspectRatio(16 / 9)

      Text(v.name)
        .fontSize(13)
        .fontColor(T.SUB)
        .width('100%')
        .margin({ top: 5 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.feedMeta(v).length > 0) {
        Text(this.feedMeta(v))
          .fontSize(11)
          .fontColor(T.DIM)
          .width('100%')
          .margin({ top: 1 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 手机「最近更新」网格列数：竖屏 3 列、横屏（折叠屏展开）5 列 */
  phoneFeedCols(): string {
    try {
      const d = display.getDefaultDisplaySync();
      if (d.width > d.height) {
        return '1fr 1fr 1fr 1fr 1fr';
      }
    } catch (e) {
      // 读不到屏幕就按竖屏 3 列
    }
    return '1fr 1fr 1fr';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.isPhone) {
        this.PhoneHome()
      } else {
        this.TvHome()
      }

      // 未同意前盖住整页：既是合规要求，也顺便挡住底下的空列表
      if (this.consentReady && !this.agreed) {
        this.ConsentPanel()
      }

      if (this.agreed && this.showGuide) {
        this.GuidePanel()
      }

      if (this.tipMsg.length > 0) {
        TipLayer(this.tipMsg)
      }
    }
    .width('100%')
    .height('100%')
    // 遥控器返回键：根页面返回 = 退出；引导面板打开时先关引导。
    // 方向键焦点导航、OK 确认由 ArkUI 焦点系统自动处理，无需在此逐键写。
    .onKeyEvent((event: KeyEvent) => {
      if (event.type !== KeyType.Down) {
        return;
      }
      if (isBackCode(event.keyCode)) {
        if (this.showGuide) {
          this.closeGuide();
          return;
        }
        const ctx = getContext(this) as common.UIAbilityContext;
        ctx.terminateSelf();
      }
    })
  }

  /** 弹窗宽度：手机竖屏用相对宽度留边（固定 660/640 会超出屏宽被裁切），电视端保持固定宽度 */
  dialogW(base: number): string | number {
    return this.isPhone ? '92%' : base;
  }

  /**
   * 隐私政策同意面板。
   *
   * 三个要点，缺一个审核都会打回：
   *  1. 首次启动**必须**出现，且在同意前不联网（已由 aboutToAppear 保证）
   *  2. 必须给出全文入口，不能只有一句「我们重视隐私」
   *  3. 必须有「不同意」并且真的不能用（这里直接退出应用）
   */
  @Builder
  ConsentPanel() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor(T.BG)

      Column() {
        Text('夜帧影视 隐私政策').fontSize(22).fontColor(T.TXT)
        Text('开始使用前，请阅读并同意以下条款').fontSize(13).fontColor(T.DIM).margin({ top: 6 })

        Scroll() {
          Column() {
            Text(POLICY_TEXT)
              .fontSize(14).fontColor(T.SUB).width('100%').lineHeight(24)
          }
          .width('100%')
        }
        .height(176)
        .width('100%')
        .margin({ top: 14 })
        .padding(14)
        .backgroundColor(T.CARD)
        .borderRadius(T.RADIUS)
        .scrollBar(BarState.Auto)

        Text('完整条款：https://s3a.abber.cn:88/public/privacy.html')
          .fontSize(12).fontColor(T.DIM).margin({ top: 8 }).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row() {
          Text('不同意并退出')
            .fontSize(16).height(48)
            .padding({ left: 26, right: 26 })
            .borderRadius(T.RADIUS_PILL)
            .fontColor(T.SUB)
            .backgroundColor(this.hi('no') ? T.CARD_HI : T.CARD)
            .border({ width: T.BORDER, color: this.hi('no') ? T.TXT : '#00000000' })
            .textAlign(TextAlign.Center)
            .animation({ duration: T.ANIM, curve: Curve.EaseOut })
            .focusable(true)
            .onFocus(() => this.hover('no', true))
            .onBlur(() => this.hover('no', false))
            .onHover((hv: boolean) => this.hover('no', hv))
            .onClick(() => {
              Feedback.tap();
              this.disagree();
            })

          Text('同意并继续')
            .fontSize(16).height(48)
            .padding({ left: 30, right: 30 })
            .borderRadius(T.RADIUS_PILL)
            .fontColor(T.BG)
            .backgroundColor(T.ACCENT)
            .margin({ left: 16 })
            .textAlign(TextAlign.Center)
            .border({ width: 3, color: this.hi('yes') ? T.SELECTED : '#00000000' })
            .scale({ x: this.hi('yes') ? 1.05 : 1, y: this.hi('yes') ? 1.05 : 1 })
            .animation({ duration: T.ANIM, curve: Curve.EaseOut })
            .focusable(true)
            .defaultFocus(true)
            .onFocus(() => this.hover('yes', true))
            .onBlur(() => this.hover('yes', false))
            .onHover((hv: boolean) => this.hover('yes', hv))
            .onClick(() => {
              Feedback.tap();
              this.agree();
            })
        }
        .width('100%')
        .margin({ top: 16 })
        .justifyContent(FlexAlign.Center)
      }
      .width(this.dialogW(660))
      .padding(22)
      .backgroundColor(T.SURFACE)
      .borderRadius(24)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%')
    // 焦点锁在本面板内：方向键只在「不同意 / 同意」两个按钮间移动，不会跑到底层
    .focusScopeId('consent', true)
  }

  /** 首启引导：三句话讲清怎么用，审核员第一次打开也能找到核心功能 */
  @Builder
  GuidePanel() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor(T.BLACK_80)

      Column() {
        Text('三步开始用').fontSize(22).fontColor(T.TXT)

        Row() {
          Text('1').fontSize(18).fontColor(T.SELECTED).width(30)
          Column() {
            Text('导入片源').fontSize(16).fontColor(T.TXT)
            Text(this.isPhone ? '设置 → 点播配置，直接粘贴配置地址；直播源同理。' : '设置 → 点播配置，手机扫码把配置地址粘进来；直播源同理。')
              .fontSize(13).fontColor(T.SUB).margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
        }
        .width('100%').margin({ top: 18 })

        Row() {
          Text('2').fontSize(18).fontColor(T.SELECTED).width(30)
          Column() {
            Text('看直播 / 点播').fontSize(16).fontColor(T.TXT)
            Text('直播按源里的分组列在左侧，点分组只看该类；点播可按分类浏览与搜索。')
              .fontSize(13).fontColor(T.SUB).margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
        }
        .width('100%').margin({ top: 14 })

        Row() {
          Text('3').fontSize(18).fontColor(T.SELECTED).width(30)
          Column() {
            Text('直连播放').fontSize(16).fontColor(T.TXT)
            Text('不想配源也能用：首页「直连」，填一个 m3u8 / mp4 地址就能播。')
              .fontSize(13).fontColor(T.SUB).margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
        }
        .width('100%').margin({ top: 14 })

        Text('本应用不含任何影视内容，也不收集个人信息；无广告、无账号。')
          .fontSize(12).fontColor(T.DIM).margin({ top: 20 })

        Text('开始使用')
          .fontSize(16).height(48)
          .padding({ left: 30, right: 30 })
          .borderRadius(T.RADIUS_PILL)
          .fontColor(T.BG)
          .backgroundColor(T.ACCENT)
          .margin({ top: 18 })
          .textAlign(TextAlign.Center)
          .border({ width: 3, color: this.hi('yes') ? T.SELECTED : '#00000000' })
          .scale({ x: this.hi('yes') ? 1.05 : 1, y: this.hi('yes') ? 1.05 : 1 })
          .animation({ duration: T.ANIM, curve: Curve.EaseOut })
          .focusable(true)
          .defaultFocus(true)
          .onFocus(() => this.hover('yes', true))
          .onBlur(() => this.hover('yes', false))
          .onHover((hv: boolean) => this.hover('yes', hv))
          .onClick(() => {
            Feedback.tap();
            this.closeGuide();
          })
      }
      .width(this.dialogW(640))
      .padding(28)
      .backgroundColor(T.SURFACE)
      .borderRadius(28)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%')
    // 焦点锁在本引导面板内
    .focusScopeId('guide', true)
  }
}

/** 隐私政策正文摘要：内联在包里，断网也能读，不依赖外部页面 */
const POLICY_TEXT: string =
  '一、我们不收集任何个人信息\n' +
  '本应用没有注册、登录、手机号、邮箱等账号体系，也没有自己的服务器。' +
  '你的源地址、收藏、观看历史、播放进度、画质偏好全部只保存在本机，卸载即清除。\n\n' +
  '二、联网只做这些事\n' +
  '请求你自己填写的点播配置地址与直播源地址，读取其中列出的站点接口，' +
  '并按地址播放视频流；点「测速排行」时向这些地址发一次探测请求。' +
  '这些请求由你的设备直接发往第三方，不经过开发者。\n\n' +
  '三、权限只用两项\n' +
  '联网（获取并播放你配置的内容）、读取网络状态（取本机局域网 IP，供手机扫码录入使用）。' +
  '不申请位置、通讯录、短信、相机、麦克风、相册、设备标识符（IMEI/OAID）、剪贴板等任何权限。\n\n' +
  '四、扫码录入\n' +
  '仅电视端点源地址时会临时开一个局域网页面（端口 8788），只接收同一 Wi-Fi 下手机提交的地址，' +
  '手机端直接输入、不开该页面；不连任何外部服务器、无统计脚本；离开页面即停止接受写入。\n\n' +
  '五、不包含广告与统计 SDK\n' +
  '无第三方广告、无埋点统计、无推送、无社交分享、无崩溃上报。纯 ArkTS 实现。\n\n' +
  '六、内容来源\n' +
  '本应用不提供、不存储、不分发任何影视内容，仅为播放器与源管理工具。' +
  '内容全部来自你自行填写的第三方接口，请确保来源合法。';
