/**
 * 设置页 —— 对照 FongMi 的 activity_setting.xml + SettingFragment。
 *
 * 分五块：扫码录入 / 配置地址（站源）/ 定时更新 / 直播源 / 站源管理。
 */

import { Feedback } from '../common/Feedback';
import router from '@ohos.router';
import bundleManager from '@ohos.bundle.bundleManager';
import common from '@ohos.app.ability.common';
import { Store, SubResult } from '../common/Store';
import { Cms } from '../common/Cms';
import { Site, T, ChannelGroup, WebdavSource, WebdavVod } from '../common/Model';
import { Webdav } from '../common/Webdav';
import { Crawler, CrawlResult } from '../common/Crawler';
import { Live } from '../common/Live';
import { Http } from '../common/Http';
import { QrCode } from '../common/QrCode';
import { QrServer } from '../common/QrServer';
import { WdQrPanel } from '../common/WdQr';
import { Tip, TIP_MSG, TipLayer } from '../common/Tip';
import { LivePreset, fromLives } from '../common/LivePresets';
import { Device, KEY_IS_PHONE } from '../common/Device';
import { PhoneTabBar } from '../common/PhoneTabBar';
import { Pointer } from '../common/Pointer';

/** 一个站源的测速结果，按 key 与 Site 对应 */
class SiteSpeed {
  key: string = '';
  ms: number = -1;
  ok: boolean = false;

  constructor(key: string) {
    this.key = key;
  }
}

/**
 * 设置页视觉参数 —— 参照 tvOS「设置」的分组卡片 + 行式条目。
 *
 * 为什么用这套结构：原先把每个设置项都做成独立小卡片、按钮散落在各行右侧，
 * 一屏里同时出现 6 种卡片高度和 5 种按钮样式，用户扫一眼分不清「哪些是设置项、
 * 哪些是操作」。tvOS 的做法是把同一类的项收进一张卡，每项只占一行、
 * 右侧固定两列（当前值 + 箭头），要操作就整行进二级——层次一眼可见。
 *
 * 尺寸按横屏电视收紧了：tvOS 的行高约 76pt，这屏只有 366vp 高，
 * 用 52 才能在一屏里放下 5 行，同时保持「一行一项」的节奏。
 */
class S {
  /** 分组卡片圆角 */
  static readonly CARD_R: number = 14;
  /** 行高 */
  static readonly ROW_H: number = 52;
  /** 行的左右内边距（右边比左边大一点，给箭头留呼吸） */
  static readonly PAD_L: number = 15;
  static readonly PAD_R: number = 18;
  /** 行间分割线：从文字起始位置缩进，和 tvOS 的内缩分隔线一致 */
  static readonly DIV_INSET: number = 18;
  static readonly DIV_COLOR: string = '#1FFFFFFF';
  /** 分组标题颜色（white 55%） */
  static readonly GROUP_TXT: string = '#8CFFFFFF';
  /** 焦点行底色：20% 白。比纯白反色柔和，也兼容 Toggle（不会出现白底白开关） */
  static readonly ROW_HI: string = '#33FFFFFF';
  /** 焦点竖条宽度 */
  static readonly BAR_W: number = 3;
}

/**
 * 设置行 —— tvOS 风格的「标题 + 当前值 + 箭头」。
 *
 * 为什么是 @Component 而不是 @Builder：@Builder 按值传参，传进来的字符串
 * 不会跟着页面状态更新（本项目已经踩过一次：播放按钮一直显示「播放」）。
 * 设置页的每一行右侧恰恰都是随状态变的「当前值」——配置地址有没有配、
 * 直播源选了哪个、站源启用了几个。用 @Builder 的结果就是首帧拿到什么就
 * 永远显示什么（实测「未配置 / 0 个」一直不刷新）。@Prop 是单向同步，
 * 父组件的状态一变这里就重建，才对得上。
 */
@Component
struct SRowView {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop arrow: boolean = false;
  @Prop focused: boolean = false;
  /** 破坏性操作：标题用警示色 */
  @Prop warn: boolean = false;
  onTap: () => void = () => {
  };
  onHoverIn: (on: boolean) => void = () => {
  };

  build() {
    Row() {
      // 焦点竖条：常态透明但占位，出现时文字不会左右跳
      Row()
        .width(S.BAR_W)
        .height(20)
        .borderRadius(S.BAR_W / 2)
        .backgroundColor(this.focused ? (this.warn ? T.WARN : T.TXT) : '#00000000')
      // 标签绝不收缩：之前这里给了 layoutWeight(1)，轮到「上次更新」这种
      // 「短标签 + 一长串值」的组合时，Row 会优先满足值想要的宽度，把标签压到
      // 只剩 ~37vp，屏幕上直接显示成「上…」——四个字被砍掉三个。
      Text(this.label)
        .fontSize(16)
        .fontColor(this.warn ? T.WARN : T.TXT)
        // 没有值时才由标签撑开剩余空间（把箭头顶到最右）；
        // 有值时标签按自身宽度定住，不跟值抢空间。
        .layoutWeight(this.value.length > 0 ? 0 : 1)
        .flexShrink(0)
        .margin({ left: 12 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.value.length > 0) {
        // 值改成占剩余空间并靠右省略，短值时位置和原来一致，
        // 长值时由它自己缩，而不是去抢标签的宽度。
        Text(this.value)
          .fontSize(14)
          .fontColor(this.focused ? T.TXT : (this.warn ? T.DIM : T.SUB))
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 12 })
      }
      if (this.arrow) {
        Text('›')
          .fontSize(20)
          .fontColor(this.focused ? T.TXT : T.DIM)
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .height(S.ROW_H)
    .padding({ left: S.PAD_L, right: S.PAD_R })
    .backgroundColor(this.focused ? S.ROW_HI : '#00000000')
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
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
    .onClick(() => Pointer.fire('st_row_' + this.label, () => {
        Feedback.tap();
        this.onTap();
    }))
    .onMouse(Pointer.on('st_row_' + this.label, () => {
        Feedback.tap();
        this.onTap();
    }))
  }
}

/** 展开出来的子列表项：缩进 + 小一号字，体现「这是上一级的明细」 */
@Component
struct SChildView {
  @Prop label: string = '';
  @Prop meta: string = '';
  @Prop value: string = '';
  @Prop focused: boolean = false;
  /** 当前正在使用的项：黄色高亮 */
  @Prop hot: boolean = false;
  onTap: () => void = () => {
  };
  onHoverIn: (on: boolean) => void = () => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(15)
        .fontColor(this.hot ? T.SELECTED : T.TXT)
        .width(160)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.meta)
        .fontSize(13)
        .fontColor(T.DIM)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 12 })
      Text(this.value)
        .fontSize(13)
        .fontColor(this.hot ? T.SELECTED : T.SUB)
        .margin({ left: 12 })
    }
    .width('100%')
    .height(42)
    .padding({ left: 30, right: S.PAD_R })
    .backgroundColor(this.focused ? S.ROW_HI : '#00000000')
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
    .onHover((hv: boolean) => {
      this.onHoverIn(hv);
    })
    .onClick(() => Pointer.fire('st_child_' + this.label, () => {
        Feedback.tap();
        this.onTap();
    }))
    .onMouse(Pointer.on('st_child_' + this.label, () => {
        Feedback.tap();
        this.onTap();
    }))
  }
}

/** 站源行：名称 + 类型/原因 + 测速结果 + 开关。开关行不做整行点击 */
@Component
struct SSiteView {
  @Prop name: string = '';
  @Prop detail: string = '';
  @Prop usable: boolean = true;
  /** 开关状态。不能叫 enabled —— 那是 CustomComponent 基类的属性（禁用组件），会冲突 */
  @Prop sw: boolean = true;
  @Prop speed: string = '';
  @Prop speedColor: string = '';
  @Prop focused: boolean = false;
  onToggle: (on: boolean) => void = () => {
  };
  onHoverIn: (on: boolean) => void = () => {
  };

  build() {
    Row() {
      Row()
        .width(S.BAR_W)
        .height(18)
        .borderRadius(S.BAR_W / 2)
        .backgroundColor(this.focused ? T.TXT : '#00000000')
      Column() {
        Text(this.name)
          .fontSize(15)
          .fontColor(this.usable ? T.TXT : T.DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.detail)
          .fontSize(12)
          .fontColor(this.usable ? T.DIM : T.WARN)
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      if (this.speed.length > 0) {
        Text(this.speed)
          .fontSize(12)
          .fontColor(this.speedColor)
          .margin({ right: 14 })
      }
      if (this.usable) {
        Toggle({ type: ToggleType.Switch, isOn: this.sw })
          .selectedColor(T.ACCENT)
          .onChange((on: boolean) => {
            this.onToggle(on);
          })
      } else {
        Text('不支持')
          .fontSize(12)
          .fontColor(T.WARN)
          .border({ width: 1, color: T.WARN })
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(4)
      }
    }
    .width('100%')
    .height(58)
    .padding({ left: 30, right: S.PAD_R })
    .backgroundColor(this.focused ? S.ROW_HI : '#00000000')
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
    .onHover((hv: boolean) => {
      this.onHoverIn(hv);
    })
  }
}

@Entry
@Component
struct SettingPage {
  @State url: string = '';
  /** 设备形态：手机竖屏显示底部 Tab */
  @StorageProp(KEY_IS_PHONE) isPhone: boolean = false;
  /** 全局轻提示（AppStorage 上的 TIP_MSG），Tip.show() 触发 */
  @StorageLink(TIP_MSG) tipMsg: string = '';
  @State liveUrl: string = '';
  @State sites: Site[] = [];
  @State msg: string = '';
  @State msgColor: string = T.SUB;
  /** 提示条自动消失的计时器。常驻会把下面的卡片整体往下挤，看着像版面在跳 */
  private msgTimer: number = -1;
  @State busy: boolean = false;
  @State total: number = 0;
  @State usable: number = 0;
  @State showAll: boolean = false;
  @State focusKey: string = '';
  @State crawlInfo: string = '';
  @State crawlBusy: boolean = false;
  @State presets: LivePreset[] = [];
  /** 订阅源名字，空串表示还没订阅 */
  @State subName: string = '';
  /**
   * 两处源列表默认折叠。
   * 设置页原本一进来就把 10 个直播源 + 20 个站源全铺开，折叠掉之后首屏只剩
   * 地址栏和几个按钮，滚一屏就能看完所有设置项。
   */
  @State showPresets: boolean = false;
  @State showSites: boolean = false;
  @State probing: boolean = false;
  /** 站源测速结果，和 Site 用 key 对应 */
  @State speeds: SiteSpeed[] = [];
  @State speedBusy: boolean = false;
  @State ranked: boolean = false;
  /** 扫码录入弹窗：点输入框才弹，不占常驻版面 */
  @State qrOpen: boolean = false;
  /** 弹的是哪一个：cfg = 点播配置地址，live = 直播源地址 */
  @State qrKind: string = 'cfg';
  /** 手机可访问的地址，空串表示服务没起来 */
  @State qrUrl: string = '';
  @State qrTip: string = '';
  /** 关于区块展开隐私政策摘要 */
  @State showPrivacy: boolean = false;
  /** 点击反馈：声音开关 */
  @State soundOn: boolean = true;
  /** 点击反馈：震动开关 */
  @State vibrateOn: boolean = true;
  /** 播放历史 WebDAV 云同步开关 */
  @State histSyncOn: boolean = false;
  /** TV 端左侧导航当前选中分组：source/update/webdav/sites/data/about */
  @State tvNav: string = 'source';
  /** WebDAV 网盘源列表 */
  @State wdSources: WebdavSource[] = [];
  /** 网盘添加/编辑弹窗 */
  @State wdEditOpen: boolean = false;
  /** 网盘扫码录入面板（电视端，盖在添加弹窗之上） */
  @State wdQrOpen: boolean = false;
  @State wdId: string = '';
  @State wdName: string = '';
  @State wdUrl: string = '';
  @State wdUser: string = '';
  @State wdPass: string = '';
  @State wdRoot: string = '';
  @State wdTesting: boolean = false;
  @State wdMsg: string = '';
  @State wdMsgColor: string = T.SUB;
  /** 每个源最近一次识别出的影视数量（与 wdSources 下标对齐） */
  @State wdScanCounts: number[] = [];
  /** 正在识别中的源下标，-1 表示没有 */
  @State wdScanBusy: number = -1;
  /** 展示用版本号，不引 bundleManager 也能从 AppStorage 拿到 */
  @State verName: string = '1.0.2';
  /** 弹窗里切到「手动输入」模式（没 Wi-Fi / 扫不了码时的退路） */
  @State qrManualMode: boolean = false;
  @State qrManual: string = '';

  private qrMatrix: boolean[][] = [];
  /**
   * 矩阵本身放普通字段，这里只留一个「有没有画好」的标记给 UI。
   * 原因：openQr 里 await 完才拿到矩阵，而 @State qrMatrix 是二维数组，
   * 直接当 @State 每帧比数组引用代价大；UI 只需要知道「该显示画布还是转圈」。
   */
  @State qrHas: boolean = false;
  private qrSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private qrCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.qrSettings);
  private qrReady: boolean = false;
  /** 二维码画布边长（vp） */
  private readonly QR_BOX: number = 220;

  async aboutToAppear(): Promise<void> {
    await Store.init(getContext(this) as common.UIAbilityContext);
    await Store.ensureLoaded();
    this.url = await Store.getConfigUrl();
    this.liveUrl = await Store.liveUrl();
    this.crawlInfo = await Store.crawlSummary();
    this.presets = fromLives(await Store.subLives());
    this.subName = await Store.subName();
    this.wdSources = await Store.webdavSources();
    await this.reloadWdScanCounts();
    this.readVersion();
    this.soundOn = (await Store.tapSound()) !== 0;
    this.vibrateOn = (await Store.tapVibrate()) !== 0;
    this.histSyncOn = await Store.histSyncEnabled();
    // 进入设置页时静默拉取一次云历史（不阻塞 UI）
    Store.pullHistFromWebDAV().catch(() => {});
    await this.refresh();
  }

  /**
   * 顶部提示条。
   *
   * 统一走这里：设完 4 秒自动清掉。原先各处直接给 this.msg 赋值，
   * 提示一旦出现就一直挂着，把下面所有卡片往下顶一截，用户以为版面错位。
   */
  toast(t: string, color: string): void {
    this.msg = t;
    this.msgColor = color;
    if (this.msgTimer >= 0) {
      clearTimeout(this.msgTimer);
    }
    this.msgTimer = setTimeout(() => {
      this.msg = '';
      this.msgTimer = -1;
    }, 4000);
  }

  /**
   * 「点播配置」右侧的状态。
   *
   * 应用包内不再内置站源，站源只来自用户订阅 / 手动导入。
   * 三态：填了配置地址 →「已配置」；导入了站源但没填地址 →「已导入」；
   * 都没有 →「未配置」。
   */
  /** 点击反馈：声音开关切换 */
  async toggleTapSound(): Promise<void> {
    this.soundOn = !this.soundOn;
    await Store.setTapSound(this.soundOn ? 1 : 0);
    Feedback.refresh();
  }

  /** 点击反馈：震动开关切换 */
  async toggleTapVibrate(): Promise<void> {
    this.vibrateOn = !this.vibrateOn;
    await Store.setTapVibrate(this.vibrateOn ? 1 : 0);
    Feedback.refresh();
  }

  /** 历史云同步开关切换 */
  async toggleHistSync(): Promise<void> {
    this.histSyncOn = !this.histSyncOn;
    await Store.setHistSyncEnabled(this.histSyncOn);
    if (this.histSyncOn) {
      // 开启后立即触发一次上传
      Store.syncHistToWebDAV().catch(() => {});
      this.toast('历史同步已开启，将同步到第一个网盘', '#4CAF50');
    } else {
      this.toast('历史同步已关闭', '#FF9800');
    }
  }

  cfgState(): string {
    if (this.url.length > 0) {
      return '已配置';
    }
    return this.sites.length > 0 ? '已导入' : '未配置';
  }

  /**
   * 把抓取摘要压短。
   *
   * Store 里存的是「11-03 13:23 更新完成 · 18/20 个站源有响应 · 收到 60 条 ·
   * 2 个无响应」这种给人看的长句，塞进设置行右侧会把整行吃掉一半，
   * 还会被 ellipsis 截成半句话。行里只留「时间 · 站源 · 条数 · 失效数」。
   */
  crawlShort(): string {
    if (this.crawlInfo.length === 0) {
      return '还没有抓取过';
    }
    return this.crawlInfo
      .replace(' 更新完成', '')
      .replace('个站源有响应', '站源')
      .replace('收到 ', '')
      .replace('个无响应', '失效');
  }

  /** 版本号从包信息读，别在代码里写死——改了 app.json5 忘了同步会误导审核 */
  readVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName.length > 0) {
        this.verName = info.versionName;
      }
    } catch (e) {
      // 读不到就保留默认值，不影响主流程
    }
  }

  aboutToDisappear(): void {
    // 离开设置页就不再接受手机写入，避免后台被人往配置里塞东西
    QrServer.stop();
    if (this.msgTimer >= 0) {
      clearTimeout(this.msgTimer);
      this.msgTimer = -1;
    }
  }

  // ==================== WebDAV 网盘源管理 ====================

  openWdAdd(): void {
    this.wdId = '';
    this.wdName = '';
    this.wdUrl = '';
    this.wdUser = '';
    this.wdPass = '';
    this.wdRoot = '';
    this.wdMsg = '';
    this.wdEditOpen = true;
  }

  openWdEdit(src: WebdavSource): void {
    this.wdId = src.id;
    this.wdName = src.name;
    this.wdUrl = src.url;
    this.wdUser = src.user;
    this.wdPass = src.pass;
    this.wdRoot = src.root;
    this.wdMsg = '';
    this.wdEditOpen = true;
  }

  async testWd(): Promise<void> {
    if (this.wdUrl.trim().length === 0) {
      this.wdMsg = '先填服务器地址';
      this.wdMsgColor = T.WARN;
      return;
    }
    this.wdTesting = true;
    const t = new WebdavSource();
    t.url = this.wdUrl.trim();
    t.user = this.wdUser.trim();
    t.pass = this.wdPass;
    t.root = this.wdRoot.trim();
    try {
      const n: number = await Webdav.probe(t);
      this.wdMsg = '连接成功，根目录有 ' + n + ' 项';
      this.wdMsgColor = '#B7F0BC';
    } catch (e) {
      const err = e as Error;
      this.wdMsg = err.message;
      this.wdMsgColor = T.WARN;
    }
    this.wdTesting = false;
  }

  async saveWd(): Promise<void> {
    const url: string = this.wdUrl.trim();
    if (url.length === 0) {
      this.wdMsg = '请填服务器地址';
      this.wdMsgColor = T.WARN;
      return;
    }
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      this.wdMsg = '地址要以 http:// 或 https:// 开头';
      this.wdMsgColor = T.WARN;
      return;
    }
    const s = new WebdavSource();
    s.id = this.wdId;
    s.name = this.wdName.trim().length > 0 ? this.wdName.trim() : Webdav.hostOf(url);
    s.url = url;
    s.user = this.wdUser.trim();
    s.pass = this.wdPass;
    s.root = this.wdRoot.trim();
    // 编辑时若挂载点 / 认证变化，旧的识别缓存已失效（路径/账号对不上），清掉让下次重新识别
    if (this.wdId.length > 0) {
      const olds: WebdavSource[] = await Store.webdavSources();
      for (let i = 0; i < olds.length; i++) {
        if (olds[i].id === this.wdId &&
          (olds[i].url !== s.url || olds[i].root !== s.root || olds[i].user !== s.user)) {
          await Store.removeWebdavScan(this.wdId);
          break;
        }
      }
    }
    await Store.saveWebdavSource(s);
    this.wdSources = await Store.webdavSources();
    await this.reloadWdScanCounts();
    this.wdEditOpen = false;
    this.toast('已保存「' + s.name + '」', '#B7F0BC');
  }

  /**
   * 手机扫码提交成功后的收尾。
   * 面板自己已经落盘过了，这里只负责刷新列表 + 给电视端一条反馈。
   */
  async afterWdQrSaved(src: WebdavSource): Promise<void> {
    this.wdSources = await Store.webdavSources();
    await this.reloadWdScanCounts();
    this.toast('手机已添加网盘「' + src.name + '」', '#B7F0BC');
  }

  async removeWd(src: WebdavSource): Promise<void> {
    await Store.removeWebdavSource(src.id);
    this.wdSources = await Store.webdavSources();
    await this.reloadWdScanCounts();
    this.wdEditOpen = false;
    this.toast('已删除「' + src.name + '」', T.SUB);
  }

  /** 重新读取每个源识别出的影视数量（供设置页展示） */
  async reloadWdScanCounts(): Promise<void> {
    const counts: number[] = [];
    for (let i = 0; i < this.wdSources.length; i++) {
      const vods: WebdavVod[] = await Store.webdavScanCache(this.wdSources[i].id);
      counts.push(vods.length);
    }
    this.wdScanCounts = counts;
  }

  /**
   * 识别某个 WebDAV 源的影视资源并落盘缓存。
   * 供设置页「网盘」分组里的「识别影视」按钮调用。
   */
  async scanWd(src: WebdavSource, idx: number): Promise<void> {
    if (this.wdScanBusy >= 0) {
      return;
    }
    this.wdScanBusy = idx;
    this.toast('正在识别「' + src.name + '」…', T.SUB);
    try {
      const vods: WebdavVod[] = await Webdav.scan(src, 6);
      await Store.saveWebdavScan(src.id, vods);
      if (idx >= 0 && idx < this.wdScanCounts.length) {
        this.wdScanCounts[idx] = vods.length;
      }
      this.toast('「' + src.name + '」识别到 ' + vods.length + ' 部影视', '#B7F0BC');
    } catch (e) {
      const err = e as Error;
      this.toast('识别失败：' + err.message, T.WARN);
    }
    this.wdScanBusy = -1;
  }

  /**
   * 弹出扫码面板。
   *
   * 电视上用遥控器敲几十个字符的 URL 是最难受的一步，所以点输入框就直接给二维码：
   * 手机扫开、粘地址、提交，电视这边收到就落盘。kind 决定手机页面把哪个框排在最前。
   */
  async openQr(kind: string): Promise<void> {
    this.qrKind = kind;
    this.qrOpen = true;
    this.qrHas = false;
    // 手机端自己就是手机，不需要「手机扫码」——直接进手动输入，不启动二维码服务
    this.qrManualMode = Device.isPhone();
    this.qrManual = kind === 'live' ? this.liveUrl : this.url;
    this.qrUrl = '';
    if (Device.isPhone()) {
      this.qrTip = '';
      return;
    }
    this.qrTip = '正在启动手机录入服务…';
    const base: string = await QrServer.start((k: string, value: string): Promise<string> => {
      return this.onPhoneSave(k, value);
    });
    if (base.length === 0) {
      this.qrTip = '没拿到本机 IP（电视可能没连 Wi-Fi）。点「手动输入」用遥控器填。';
      return;
    }
    const full: string = base + '?t=' + kind;
    this.qrUrl = full;
    this.qrMatrix = QrCode.make(full);
    this.qrHas = this.qrMatrix.length > 0;
    if (this.qrMatrix.length === 0) {
      this.qrTip = '二维码生成失败，可在手机浏览器打开：' + full;
      return;
    }
    this.qrTip = kind === 'live'
      ? '手机扫码 → 粘 m3u / txt 直播源地址 → 提交，电视立刻生效'
      : (kind === 'sub'
        ? '手机扫码 → 粘订阅链接（点播站源 + 直播源一起更新）→ 提交'
        : '手机扫码 → 粘配置地址或整段 JSON → 提交，电视立刻生效');
    this.drawQr();
  }

  /** 折叠条上显示当前选中的订阅源名字；不是订阅源就显示「自定义」 */
  currentPresetName(): string {
    for (let i = 0; i < this.presets.length; i++) {
      if (this.presets[i].url === this.liveUrl) {
        return this.presets[i].name;
      }
    }
    return this.liveUrl.length > 0 ? '自定义地址' : '未选择';
  }

  /** 已启用的站源数，折叠时也能一眼看到规模 */
  enabledCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.sites.length; i++) {
      if (this.sites[i].usable && this.sites[i].enabled) {
        n++;
      }
    }
    return n;
  }

  closeQr(): void {
    this.qrOpen = false;
    this.qrManualMode = false;
  }

  /** 弹窗里手动填完提交，走和手机提交同一条保存路径 */
  async applyQrManual(): Promise<void> {
    const v: string = this.qrManual.trim();
    if (v.length === 0) {
      this.qrTip = '为空，什么也不会保存';
      return;
    }
    try {
      if (this.qrKind === 'live') {
        await Store.setLiveUrl(v);
        this.liveUrl = v;
        this.msg = '直播源已保存';
      } else if (this.qrKind === 'sub') {
        const r: SubResult = await Store.loadSubscription(v);
        if (v.indexOf('http') === 0) {
          this.url = v;
        }
        this.subName = r.name;
        Cms.clearCache();
        await this.refresh();
        await this.reloadSubState();
        this.msg = '订阅成功：' + r.sites + ' 个站源 · ' + r.lives + ' 个直播源';
        // 订阅成功后立即后台抓一轮最新，不等回首页、不受 6 小时间隔限制
        this.kickCrawl();
      } else {
        this.url = v.indexOf('http') === 0 ? v : this.url;
        const n: number = await Store.loadConfig(v);
        Cms.clearCache();
        await this.refresh();
        this.msg = '配置已导入：共 ' + n + ' 个站源，其中 ' + this.usable + ' 个可用';
      }
      this.msgColor = '#B7F0BC';
      await this.refresh();
      this.closeQr();
    } catch (err) {
      const e = err as Error;
      this.qrTip = '保存失败：' + e.message;
    }
  }

  /**
   * 扫码录入弹窗。
   *
   * 只在点了「点播配置」或「直播源」输入框时出现：左边二维码给手机扫，
   * 右边是这台电视上的退路（手动填）。点空白处或「✕」收起。
   */
  @Builder
  QrPanel() {
    Stack() {
      // 遮罩：点一下即关，避免 TV 上没有明显的关闭入口
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(T.BLACK_70)
        .onClick(() => Pointer.fire('st_qrx', () => {
            Feedback.tap();
            this.closeQr();
        }))
        .onMouse(Pointer.on('st_qrx', () => {
            Feedback.tap();
            this.closeQr();
        }))

      Column() {
        Row() {
          Column() {
            Text(this.qrKind === 'live'
              ? (Device.isPhone() ? '录入直播源' : '手机扫码录入直播源')
              : (this.qrKind === 'sub'
                ? (Device.isPhone() ? '订阅' : '手机扫码订阅')
                : (Device.isPhone() ? '录入点播配置' : '手机扫码录入点播配置')))
              .fontSize(20).fontColor(T.TXT)
            Text(Device.isPhone()
              ? '输入地址后点「保存」，立即生效'
              : (this.qrKind === 'live'
                ? '手机与电视连同一个 Wi-Fi，扫码后粘 m3u / txt 地址提交'
                : (this.qrKind === 'sub'
                  ? '扫码后粘订阅链接，点播站源和直播源一次更新'
                  : '手机与电视连同一个 Wi-Fi，扫码后粘配置地址或整段 JSON 提交')))
              .fontSize(13).fontColor(T.DIM).margin({ top: 6 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('✕')
            .fontSize(20)
            .fontColor(this.hi('qrx') ? T.SELECTED : T.SUB)
            .width(44).height(44)
            .textAlign(TextAlign.Center)
            .borderRadius(T.RADIUS_PILL)
            .backgroundColor(this.hi('qrx') ? T.CARD_HI : '#00000000')
            .onHover((hv: boolean) => this.hoverTo('qrx', hv))
            .onClick(() => Pointer.fire('st_qrx2', () => {
                Feedback.tap();
                this.closeQr();
            }))
            .onMouse(Pointer.on('st_qrx2', () => {
                Feedback.tap();
                this.closeQr();
            }))
        }
        .width('100%')

        Row() {
          // 二维码：白底留白，保证在深色面板上也能被相机扫到（仅电视端展示）
          if (!Device.isPhone()) {
            Column() {
              if (this.qrHas) {
                Canvas(this.qrCtx)
                  .width(this.QR_BOX)
                  .height(this.QR_BOX)
                  .onReady(() => {
                    this.qrReady = true;
                    this.drawQr();
                  })
              } else {
                Column() {
                  LoadingProgress().width(36).height(36).color(T.SUB)
                  Text('生成中…').fontSize(13).fontColor(T.DIM).margin({ top: 8 })
                }
                .width(this.QR_BOX).height(this.QR_BOX)
                .justifyContent(FlexAlign.Center)
              }
            }
            .width(this.QR_BOX + 24)
            .height(this.QR_BOX + 24)
            .backgroundColor('#FFFFFF')
            .borderRadius(T.RADIUS)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }

          Column() {
            if (this.qrTip.length > 0) {
              Text(this.qrTip)
                .fontSize(14)
                .fontColor(this.qrUrl.length > 0 ? T.SUB : T.WARN)
                .width('100%')
                .lineHeight(22)
            }

            if (this.qrUrl.length > 0) {
              Text(this.qrUrl)
                .fontSize(20).fontColor(T.SELECTED).margin({ top: 10 })
            }

            if (!Device.isPhone()) {
              Text('手机扫不了？也可以在下面直接填。')
                .fontSize(12).fontColor(T.DIM).margin({ top: 14 })
            }

            if (this.qrManualMode) {
              TextInput({
                text: this.qrManual,
                placeholder: this.qrKind === 'live' ? 'm3u / txt 直播源地址'
                  : (this.qrKind === 'sub' ? '订阅链接（https://…）' : '配置地址或整段 JSON')
              })
                .height(46)
                .width('100%')
                .fontSize(14)
                .fontColor(T.TXT)
                .placeholderColor(T.DIM)
                .backgroundColor(T.SURFACE)
                .borderRadius(T.RADIUS)
                .padding({ left: 14, right: 14 })
                .margin({ top: 8 })
                .onChange((v: string) => {
                  this.qrManual = v;
                })
                .onSubmit(() => {
                  this.applyQrManual();
                })

              Text(Device.isPhone() ? '保存' : '保存到电视')
                .fontSize(15)
                .fontColor(T.BG)
                .height(40)
                .padding({ left: 22, right: 22 })
                .borderRadius(T.RADIUS_PILL)
                .backgroundColor(T.ACCENT)
                .margin({ top: 10 })
                .textAlign(TextAlign.Center)
                .onClick(() => Pointer.fire('st_qrok', () => {
                    Feedback.tap();
                    this.applyQrManual();
                }))
                .onMouse(Pointer.on('st_qrok', () => {
                    Feedback.tap();
                    this.applyQrManual();
                }))
            } else {
              Text('手动输入 ›')
                .fontSize(15)
                .fontColor(T.TXT)
                .height(40)
                .padding({ left: 22, right: 22 })
                .borderRadius(T.RADIUS_PILL)
                .border({ width: T.BORDER, color: this.hi('qrm') ? T.TXT : T.WHITE_30 })
                .backgroundColor(this.hi('qrm') ? T.CARD_HI : '#00000000')
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
                .onHover((hv: boolean) => this.hoverTo('qrm', hv))
                .onClick(() => Pointer.fire('st_qrman', () => {
                    Feedback.tap();
                    this.qrManualMode = true;
                }))
                .onMouse(Pointer.on('st_qrman', () => {
                    Feedback.tap();
                    this.qrManualMode = true;
                }))
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: Device.isPhone() ? 0 : 24 })
        }
        .width('100%')
        .margin({ top: 20 })
        .alignItems(VerticalAlign.Center)
      }
      .width(Device.panelW(680))
      .padding(24)
      .backgroundColor(T.SURFACE)
      .borderRadius(28)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }

  /** 手机提交过来的内容 */
  async onPhoneSave(kind: string, value: string): Promise<string> {
    const v: string = value.trim();
    if (kind === 'live') {
      await Store.setLiveUrl(v);
      this.liveUrl = v;
      this.toast('手机已提交直播源，已保存', '#B7F0BC');
      await this.refresh();
      return '已保存：电视上的直播源已更新';
    }
    if (kind === 'sub') {
      const r: SubResult = await Store.loadSubscription(v);
      if (v.indexOf('http') === 0) {
        this.url = v;
      }
      this.subName = r.name;
      Cms.clearCache();
      await this.refresh();
      await this.reloadSubState();
      this.toast('订阅成功：' + r.sites + ' 个站源 · ' + r.lives + ' 个直播源', '#B7F0BC');
      // 订阅成功后立即后台抓一轮最新
      this.kickCrawl();
      return '已订阅 ' + r.sites + ' 个站源、' + r.lives + ' 个直播源，电视端已刷新';
    }
    const n: number = await Store.loadConfig(v);
    if (v.indexOf('http') === 0) {
      this.url = v;
    }
    await this.refresh();
    this.toast('手机已提交点播配置：共 ' + n + ' 个站源，其中 ' + this.usable + ' 个可用', '#B7F0BC');
    return '已导入 ' + n + ' 个站源，电视端已刷新';
  }

  /** 把二维码画到画布上：整数倍模块 + 居中留白，保证边缘锐利好扫 */
  drawQr(): void {
    if (!this.qrReady || this.qrMatrix.length === 0) {
      return;
    }
    const n: number = this.qrMatrix.length;
    const quiet: number = 4;
    const total: number = n + quiet * 2;
    let unit: number = Math.floor(this.QR_BOX / total);
    if (unit < 1) {
      unit = 1;
    }
    const drawn: number = unit * total;
    const offX: number = Math.floor((this.QR_BOX - drawn) / 2) + unit * quiet;
    const offY: number = Math.floor((this.QR_BOX - drawn) / 2) + unit * quiet;
    this.qrCtx.fillStyle = '#FFFFFF';
    this.qrCtx.fillRect(0, 0, this.QR_BOX, this.QR_BOX);
    this.qrCtx.fillStyle = '#000000';
    for (let r = 0; r < n; r++) {
      for (let c = 0; c < n; c++) {
        if (this.qrMatrix[r][c]) {
          this.qrCtx.fillRect(offX + c * unit, offY + r * unit, unit, unit);
        }
      }
    }
  }

  onBackPress(): boolean {
    // 遥控器返回键：扫码面板打开时先关面板，否则退出页面
    if (this.qrOpen) {
      this.closeQr();
      return true;
    }
    // 网盘扫码面板也压在弹窗上面，先收它
    if (this.wdQrOpen) {
      this.wdQrOpen = false;
      return true;
    }
    if (this.wdEditOpen) {
      this.wdEditOpen = false;
      return true;
    }
    router.back();
    return true;
  }

  async refresh(): Promise<void> {
    this.total = Store.totalSites();
    this.usable = Store.usableSites().length;
    const keys: string[] = await Store.enabledKeys();
    const base: string[] = keys.length > 0 ? keys : this.keysOf(Store.usableSites());
    const out: Site[] = [];
    const all: Site[] = Store.sites();
    for (let i = 0; i < all.length; i++) {
      const s: Site = all[i];
      s.enabled = base.indexOf(s.key) >= 0;
      if (s.usable || this.showAll) {
        out.push(s);
      }
    }
    this.sites = out;
    // 测过速的，列表要一直保持「快→慢」的顺序；refresh 会按配置原序重建，这里补一次
    if (this.ranked) {
      this.sortSitesBySpeed();
    }
  }

  /**
   * 订阅成功后刷新直播源相关状态：候选列表 presets + 当前选中的 liveUrl。
   *
   * refresh() 只重建站源 sites，不碰 presets——订阅是在页面打开之后才发生的，
   * aboutToAppear 里读过一次 presets 就固定了，不在这里补一次，订阅完「订阅直播源」
   * 列表会一直显示「未订阅」、展开也是空。liveUrl 同理：Store.loadSubscription
   * 会自动选第一个默认源，但页面上的 currentPresetName() 还指着旧值。
   */
  async reloadSubState(): Promise<void> {
    this.presets = fromLives(await Store.subLives());
    this.liveUrl = await Store.liveUrl();
  }

  keysOf(list: Site[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(list[i].key);
    }
    return out;
  }

  async doImport(): Promise<void> {
    const src: string = this.url.trim();
    if (src.length === 0) {
      this.toast('请填配置地址', T.WARN);
      return;
    }
    this.busy = true;
    this.toast('正在下载并解析配置…', T.SUB);
    try {
      const n: number = await Store.loadConfig(src);
      Cms.clearCache();
      await this.refresh();
      this.toast('导入成功：共 ' + n + ' 个站源，其中 ' + this.usable + ' 个可在本机运行', '#B7F0BC');
    } catch (err) {
      const e = err as Error;
      this.toast('导入失败：' + e.message, T.ERR);
    } finally {
      this.busy = false;
    }
    Tip.show(this.msg.length > 0 ? this.msg : '已导入');
  }

  async saveLive(): Promise<void> {
    await Store.setLiveUrl(this.liveUrl.trim());
    this.toast(this.liveUrl.trim().length > 0 ? '直播源已保存' : '已清空直播源', '#B7F0BC');
    Tip.show(this.msg.length > 0 ? this.msg : '已保存');
  }

  /**
   * 直播源测速排行。系统 http 并发有上限，10 个一起发会互相排队（实测一直停在「测试中」），
   * 所以分 3 批、每批 3 个，并且给每个请求加 Promise.race 硬超时兜底。
   * 测完按「能用 → 耗时升序」重排，并把最快那个设为当前源。
   */
  async probeAll(): Promise<void> {
    if (this.probing) {
      Tip.show('正在测速，请稍等');
      return;
    }
    const list: LivePreset[] = fromLives(await Store.subLives());
    if (list.length === 0) {
      this.toast('还没有直播源，先去「订阅」导入一个', T.WARN);
      return;
    }
    this.probing = true;
    // 折叠状态下测速，用户看不到「测试中…」的进度，会以为没反应。
    // 这里顺手展开，测完不自动收起（结果就摆在列表里）。
    this.showPresets = true;
    Tip.show('开始测速 ' + list.length + ' 个直播源，约 30 秒');
    for (let i = 0; i < list.length; i++) {
      list[i].state = '测试中…';
    }
    this.presets = list;
    for (let s = 0; s < list.length; s += 3) {
      const batch: Promise<void>[] = [];
      const end: number = Math.min(s + 3, list.length);
      for (let i = s; i < end; i++) {
        batch.push(this.probeInto(i));
      }
      await Promise.all(batch);
    }
    this.probing = false;
    await this.rankPresets();
  }

  /** 排名规则：能拉列表优先 → 抽样的台能连上的多的优先 → 拉得更快的优先 */
  async rankPresets(): Promise<void> {
    const sorted: LivePreset[] = this.presets.slice();
    sorted.sort((a: LivePreset, b: LivePreset): number => {
      if (a.ok !== b.ok) {
        return a.ok ? -1 : 1;
      }
      if (!a.ok) {
        return 0;
      }
      if (a.alive !== b.alive) {
        return b.alive - a.alive;
      }
      return a.ms - b.ms;
    });
    this.presets = sorted;

    let best: LivePreset | null = null;
    for (let i = 0; i < sorted.length; i++) {
      if (sorted[i].ok) {
        best = sorted[i];
        break;
      }
    }
    if (best === null) {
      this.toast('所有订阅直播源都没测通，检查网络后重试，或手动填一个源地址', T.WARN);
      return;
    }
    const cur: string = this.liveUrl.trim();
    const why: string = best.alive > 0
      ? ('可播 ' + best.alive + '/' + best.sampled + ' · ' + best.ms + ' ms · ' + best.count + ' 频道')
      : ('抽样频道都没连通，仅按列表速度选 · ' + best.ms + ' ms');
    if (cur !== best.url) {
      this.liveUrl = best.url;
      await this.saveLive();
      this.msg = '已选用最优「' + best.name + '」（' + why + '）';
    } else {
      this.msg = '当前已是最优「' + best.name + '」（' + why + '）';
    }
    this.msgColor = best.alive > 0 ? '#B7F0BC' : T.WARN;
  }

  /** 硬超时：http 的 connectTimeout 在 TLS 握手挂住时不生效，这里再兜一层 */
  private guard(ms: number): Promise<ChannelGroup[]> {
    return new Promise<ChannelGroup[]>((resolve, reject) => {
      setTimeout(() => {
        reject(new Error('timeout'));
      }, ms);
    });
  }

  async probeInto(i: number): Promise<void> {
    const target: LivePreset = this.presets[i];
    const name: string = target.name;
    const url: string = target.url;
    let state: string = '不可用';
    let ok: boolean = false;
    let count: number = 0;
    let ms: number = -1;
    let alive: number = 0;
    let sampled: number = 0;
    const t0: number = Date.now();
    try {
      const gs: ChannelGroup[] = await Promise.race([Live.load(url, 8000), this.guard(10000)]);
      ms = Date.now() - t0;
      let n: number = 0;
      for (let k = 0; k < gs.length; k++) {
        n += gs[k].channels.length;
      }
      if (n > 0) {
        ok = true;
        count = n;
        // 抽 3 个台（前三个分组各取第一个）实测能不能连上。
        // 只看列表拉得快没用——实测有源 74ms 拉完，频道却全军覆没。
        const samples: string[] = [];
        for (let g = 0; g < gs.length && samples.length < 3; g++) {
          const chs = gs[g].channels;
          if (chs.length > 0) {
            samples.push(chs[0].urls.length > 0 ? chs[0].urls[0] : chs[0].url);
          }
        }
        sampled = samples.length;
        const checks: Promise<boolean>[] = [];
        for (let s = 0; s < samples.length; s++) {
          checks.push(Live.probe(samples[s], 3000));
        }
        const rs: boolean[] = await Promise.all(checks);
        for (let s = 0; s < rs.length; s++) {
          if (rs[s]) {
            alive++;
          }
        }
        state = ms + ' ms · ' + n + ' 频道 · 可播 ' + alive + '/' + sampled;
      }
    } catch (e) {
      state = '不可用';
      ms = -1;
    }
    // ArkTS：改数组元素属性不会触发刷新，必须换新数组 + 新元素
    const np = new LivePreset(name, url);
    np.state = state;
    np.ok = ok;
    np.count = count;
    np.ms = ms;
    np.alive = alive;
    np.sampled = sampled;
    const next: LivePreset[] = [];
    for (let k = 0; k < this.presets.length; k++) {
      next.push(this.presets[k].url === url ? np : this.presets[k]);
    }
    this.presets = next;
  }

  // ==================== 站源测速 ====================

  /** 复刻 Cms 内部的 URL 拼法：api 自带 ? 时用 & 接 */
  private probeUrlOf(api: string): string {
    if (api.endsWith('?')) {
      return api + 'ac=list';
    }
    if (api.indexOf('?') >= 0) {
      return api + '&ac=list';
    }
    return api + '?ac=list';
  }

  /**
   * 站源测速排行。
   * 判据是「首包响应时间 + 有没有吐数据」：采集接口的 ?ac=list 一定会回内容，
   * 回空、回 4xx、或干脆连不上都算不可用。同样分 3 批跑，避免并发被排队。
   */
  async probeSites(): Promise<void> {
    if (this.speedBusy) {
      Tip.show('正在测速，请稍等');
      return;
    }
    this.speedBusy = true;
    this.showSites = true;
    Tip.show('开始测速 ' + this.sites.length + ' 个站源，约 40 秒');
    this.ranked = false;
    const list: Site[] = Store.usableSites();
    const init: SiteSpeed[] = [];
    for (let i = 0; i < list.length; i++) {
      const sp = new SiteSpeed(list[i].key);
      sp.ms = -2;
      init.push(sp);
    }
    this.speeds = init;
    this.sites = this.sites.slice();

    for (let s = 0; s < list.length; s += 3) {
      const batch: Promise<void>[] = [];
      const end: number = Math.min(s + 3, list.length);
      for (let i = s; i < end; i++) {
        batch.push(this.probeSiteOne(list[i]));
      }
      await Promise.all(batch);
    }
    this.speedBusy = false;
    this.ranked = true;
    this.sortSitesBySpeed();
    let okCount: number = 0;
    for (let i = 0; i < this.speeds.length; i++) {
      if (this.speeds[i].ok) {
        okCount++;
      }
    }
    this.toast('站源测速完成：' + okCount + '/' + list.length + ' 个能通，已按响应速度排序', okCount > 0 ? '#B7F0BC' : T.WARN);
  }

  async probeSiteOne(s: Site): Promise<void> {
    const url: string = this.probeUrlOf(s.api);
    let ms: number = -1;
    let ok: boolean = false;
    const t0: number = Date.now();
    try {
      const head: string = await Http.peek(url, 6000);
      ms = Date.now() - t0;
      const t: string = head.trim();
      // 采集接口正常时至少会回 XML/JSON 片段，空体或明显是错误页的都算不可用
      ok = t.length > 0 && (t.indexOf('<') >= 0 || t.indexOf('{') >= 0);
      if (t.toLowerCase().startsWith('<!doctype') || t.toLowerCase().indexOf('<title>404') >= 0) {
        ok = false;
      }
    } catch (e) {
      ok = false;
      ms = -1;
    }
    const np = new SiteSpeed(s.key);
    np.ms = ms;
    np.ok = ok;
    const next: SiteSpeed[] = [];
    for (let i = 0; i < this.speeds.length; i++) {
      next.push(this.speeds[i].key === s.key ? np : this.speeds[i]);
    }
    this.speeds = next;
  }

  /** 按测速结果重排站源列表：能通的按耗时升序在前，其余保持原序在后 */
  sortSitesBySpeed(): void {
    const sorted: SiteSpeed[] = this.speeds.slice();
    sorted.sort((a: SiteSpeed, b: SiteSpeed): number => {
      if (a.ok !== b.ok) {
        return a.ok ? -1 : 1;
      }
      if (a.ok && b.ok) {
        return a.ms - b.ms;
      }
      return 0;
    });
    this.speeds = sorted;

    const next: Site[] = this.sites.slice();
    next.sort((a: Site, b: Site): number => this.rankOf(a.key) - this.rankOf(b.key));
    this.sites = next;
  }

  /** 排名数字，越小越快；没测到的排到最后 */
  rankOf(key: string): number {
    for (let i = 0; i < this.speeds.length; i++) {
      if (this.speeds[i].key === key) {
        return i;
      }
    }
    return 900 + 1;
  }

  speedText(key: string): string {
    for (let i = 0; i < this.speeds.length; i++) {
      const sp: SiteSpeed = this.speeds[i];
      if (sp.key === key) {
        if (sp.ms === -2) {
          return '测速中…';
        }
        return sp.ok ? (sp.ms + ' ms') : '不通';
      }
    }
    return '';
  }

  speedColor(key: string): string {
    for (let i = 0; i < this.speeds.length; i++) {
      const sp: SiteSpeed = this.speeds[i];
      if (sp.key === key) {
        return sp.ok ? '#B7F0BC' : T.WARN;
      }
    }
    return T.DIM;
  }

  /** 只启用测速前 N 的站源，剩下的关掉——搜索/点播就不会在慢站上干等 */
  async enableTop(n: number): Promise<void> {
    const keys: string[] = [];
    for (let i = 0; i < this.speeds.length && keys.length < n; i++) {
      if (this.speeds[i].ok) {
        keys.push(this.speeds[i].key);
      }
    }
    if (keys.length === 0) {
      this.toast('没有测通的站源，先点「测速排行」', T.WARN);
      return;
    }
    await Store.setEnabledKeys(keys);
    await this.refresh();
    this.toast('已启用最快的 ' + keys.length + ' 个站源，其余已关闭', '#B7F0BC');
  }

  async enableAllSites(): Promise<void> {
    await Store.setEnabledKeys(this.keysOf(Store.usableSites()));
    await this.refresh();
    this.toast('已启用全部可用站源', '#B7F0BC');
  }

  async toggle(s: Site, on: boolean): Promise<void> {
    const all: Site[] = Store.sites();
    const keys: string[] = [];
    for (let i = 0; i < all.length; i++) {
      if (!all[i].usable) {
        continue;
      }
      if (all[i].key === s.key) {
        if (on) {
          keys.push(all[i].key);
        }
      } else if (all[i].enabled) {
        keys.push(all[i].key);
      }
    }
    await Store.setEnabledKeys(keys);
    await this.refresh();
  }

  async clearHist(): Promise<void> {
    await Store.clearHistory();
    this.toast('已清除播放记录', '#B7F0BC');
    // 页面内的 msg 在「配置地址」下面，用户滚到别处就看不见了，再补一条全局提示
    Tip.show('已清除播放记录');
  }

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

  /**
   * 订阅/导入成功后立即后台抓一轮最新。
   *
   * fire-and-forget（不 await）：20 个站源要抓约 1 分钟，await 会把设置页卡死。
   * Crawler.run 有并发锁，若回首页的 autoCrawl 也在等，两边会复用同一轮结果。
   */
  kickCrawl(): void {
    Crawler.run(true).then((r: CrawlResult) => {
      this.toast(Crawler.summaryOf(r).slice(0, 40), r.ok ? '#B7F0BC' : T.WARN);
    }).catch((err: Error) => {
      this.toast('更新失败：' + err.message, T.ERR);
    });
  }

  async doCrawl(): Promise<void> {
    if (this.crawlBusy) {
      return;
    }
    this.crawlBusy = true;
    this.crawlInfo = '正在逐个站源抓取最新影片，大约需要 1 分钟…';
    try {
      const r: CrawlResult = await Crawler.run(true);
      this.crawlInfo = Crawler.summaryOf(r);
    } catch (err) {
      const e = err as Error;
      this.crawlInfo = '更新失败：' + e.message;
    } finally {
      this.crawlBusy = false;
    }
    Tip.show(this.crawlInfo.length > 0 ? this.crawlInfo.slice(0, 40) : '更新完成');
  }

  // ==================== 分组标题与分割线 ====================

  /**
   * 分组标题：小字、半透明，贴在卡片上方。
   * top 控制标题上方留白：TV 端右侧内容要贴顶，传 0；手机端分组之间保留间距，传 16。
   */
  @Builder
  GroupLabel(t: string, top: number = 16) {
    Text(t)
      .fontSize(12.5)
      .fontWeight(FontWeight.Medium)
      .fontColor(S.GROUP_TXT)
      .letterSpacing(0.8)
      .width('100%')
      .padding({ left: 18, top: top, bottom: 7 })
  }

  /** 卡片内分割线：左右内缩，不顶到卡片圆角上（tvOS 的内缩分隔线） */
  @Builder
  SDiv() {
    Row() {
      Row()
        .width('100%')
        .height(1)
        .backgroundColor(S.DIV_COLOR)
    }
    .width('100%')
    .padding({ left: S.DIV_INSET, right: S.DIV_INSET })
  }

  /**
   * 标题栏：返回 + 大标题 + 右侧站源统计。
   * 手机 / 电视两端共用。
   */
  @Builder
  TitleBar() {
    Row() {
      Text('‹')
        .fontSize(32)
        .fontColor(this.hi('back') ? T.TXT : T.SUB)
        .width(36)
        .height(40)
        .textAlign(TextAlign.Center)
        .borderRadius(18)
        .backgroundColor(this.hi('back') ? S.ROW_HI : '#00000000')
        .animation({ duration: T.ANIM, curve: Curve.EaseOut })
        .onHover((hv: boolean) => this.hoverTo('back', hv))
        .onClick(() => Pointer.fire('st_back', () => {
            Feedback.tap();
            router.back();
        }))
        .onMouse(Pointer.on('st_back', () => {
            Feedback.tap();
            router.back();
        }))
      Text('设置')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(T.TXT)
        .margin({ left: 10 })
        .layoutWeight(1)
      Text(this.total > 0 ? ('站源 ' + this.usable + ' / ' + this.total) : '')
        .fontSize(14)
        .fontColor(T.DIM)
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 18, bottom: 4 })
  }

  /** 操作结果就地反馈条（手机/电视共用） */
  @Builder
  MsgBar() {
    if (this.msg.length > 0) {
      Row() {
        Text(this.msg)
          .fontSize(13)
          .fontColor(this.msgColor)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 42, right: 24, top: 6 })
    }
  }

  // ==================== 五个分组（手机 / 电视共用内容体） ====================

  /** 播放源 */
  @Builder
  SectionSource() {
    this.GroupLabel('播放源', 0)
    Column() {
      SRowView({ label: '订阅', value: this.subName.length > 0 ? this.subName : '未订阅', arrow: true, focused: this.hi('r_sub'),
        onTap: () => {
          this.openQr('sub');
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_sub', on) })
      this.SDiv()
      SRowView({ label: '点播配置', value: this.cfgState(), arrow: true, focused: this.hi('r_cfg'),
        onTap: () => {
          this.openQr('cfg');
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_cfg', on) })
      this.SDiv()
      SRowView({ label: '直播源', value: this.currentPresetName(), arrow: true, focused: this.hi('r_live'),
        onTap: () => {
          this.openQr('live');
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_live', on) })

      // 点播配置有地址时，给一个「重新拉取」的入口
      if (this.url.length > 0) {
        this.SDiv()
        SRowView({ label: this.busy ? '正在导入…' : '重新导入配置', arrow: true, focused: this.hi('r_imp'),
          onTap: () => {
            this.doImport();
          },
          onHoverIn: (on: boolean) => this.hoverTo('r_imp', on) })
      }

      this.SDiv()
      SRowView({ label: '订阅直播源', value: this.presets.length > 0 ? (this.presets.length + ' 个 · ' + (this.showPresets ? '收起' : '展开')) : '未订阅', arrow: true, focused: this.hi('r_pv'),
        onTap: () => {
          this.showPresets = !this.showPresets;
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_pv', on) })
      if (this.showPresets) {
        this.SDiv()
        if (this.presets.length === 0) {
          Text(this.isPhone ? '还没有直播源。先用「订阅」导入一个（一份订阅同时带点播站源和直播源），或手动填一个直播源地址' : '还没有直播源。先用上方「订阅」导入一个（一份订阅同时带点播站源和直播源），或手动填一个直播源地址')
            .fontSize(13)
            .fontColor(T.DIM)
            .width('100%')
            .padding({ left: 4, bottom: 8 })
        } else {
          Column() {
            ForEach(this.presets, (p: LivePreset, i: number) => {
              SChildView({
                label: p.name,
                meta: p.state.length > 0 ? p.state : '未测速',
                value: this.liveUrl === p.url ? '✓ 使用中' : '使用',
                hot: this.liveUrl === p.url,
                focused: this.hi('lp_' + i),
                onTap: () => {
                  this.liveUrl = p.url;
                  this.saveLive();
                },
                onHoverIn: (on: boolean) => this.hoverTo('lp_' + i, on)
              })
            }, (p: LivePreset, i: number) => 'lp' + i + p.url)
          }
          .width('100%')
          .padding({ bottom: 8 })
        }
      }
    }
    .width('100%')
    .backgroundColor(T.SURFACE)
    .borderRadius(S.CARD_R)
  }

  /** 内容更新 */
  @Builder
  SectionUpdate() {
    this.GroupLabel('内容更新', this.isPhone ? 16 : 0)
    Column() {
      SRowView({ label: '上次更新', value: this.crawlShort(), arrow: false, focused: this.hi('r_info'),
        onTap: () => {
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_info', on) })
      this.SDiv()
      SRowView({ label: this.crawlBusy ? '正在抓取最新影片…' : '立即更新', arrow: true, focused: this.hi('r_crawl'),
        onTap: () => {
          this.doCrawl();
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_crawl', on) })
    }
    .width('100%')
    .backgroundColor(T.SURFACE)
    .borderRadius(S.CARD_R)
  }

  /** 站源 */
  @Builder
  SectionSites() {
    this.GroupLabel('站源', this.isPhone ? 16 : 0)
    Column() {
      SRowView({ label: '站源列表', value: this.sites.length + ' 个 · 已启用 ' + this.enabledCount(), arrow: true, focused: this.hi('r_sv2'),
        onTap: () => {
          this.showSites = !this.showSites;
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_sv2', on) })
      this.SDiv()
      SRowView({ label: this.speedBusy ? '正在测速…' : '测速排行', arrow: true, focused: this.hi('r_spd'),
        onTap: () => {
          this.probeSites();
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_spd', on) })
      if (this.ranked) {
        this.SDiv()
        SRowView({ label: '启用最快的 5 个', arrow: true, focused: this.hi('r_top5'),
          onTap: () => {
            this.enableTop(5);
          },
          onHoverIn: (on: boolean) => this.hoverTo('r_top5', on) })
      }
      // 「全部启用」必须常驻：它是站源全部失效后唯一的自救入口。
      // 以前跟着 ranked（测速结果）一起显示，用户得先跑 40 秒测速才能看到，
      // 换订阅后站源静默全关时就等于没有出路。
      this.SDiv()
      SRowView({ label: '全部启用', arrow: true, focused: this.hi('r_all'),
        onTap: () => {
          this.enableAllSites();
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_all', on) })
      this.SDiv()
      SRowView({ label: '站源筛选', value: this.showAll ? '全部' : '仅可用', arrow: true, focused: this.hi('r_show'),
        onTap: () => {
          this.showAll = !this.showAll;
          this.refresh();
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_show', on) })

      if (this.showSites) {
        this.SDiv()
        if (this.sites.length === 0) {
          Text(this.isPhone ? '还没有导入配置。点「点播配置」直接粘贴地址录入。' : '还没有导入配置。点上方的「点播配置」用手机扫码录入。')
            .fontSize(13)
            .fontColor(T.DIM)
            .width('100%')
            .padding({ left: 30, right: S.PAD_R, top: 14, bottom: 18 })
            .lineHeight(21)
        } else {
          Column() {
            ForEach(this.sites, (s: Site) => {
              SSiteView({
                name: s.name,
                detail: s.usable ? (s.type === 0 ? 'XML 采集接口' : 'JSON 采集接口') : s.reason,
                usable: s.usable,
                sw: s.enabled,
                speed: this.speedText(s.key),
                speedColor: this.speedColor(s.key),
                focused: this.hi('m_' + s.key),
                onToggle: (on: boolean) => {
                  this.toggle(s, on);
                },
                onHoverIn: (on: boolean) => this.hoverTo('m_' + s.key, on)
              })
            }, (s: Site) => 'm' + s.key)
          }
          .width('100%')
          .padding({ top: 4, bottom: 8 })
        }
      }
    }
    .width('100%')
    .backgroundColor(T.SURFACE)
    .borderRadius(S.CARD_R)
  }

  /** 数据 */
  @Builder
  SectionData() {
    this.GroupLabel('数据', this.isPhone ? 16 : 0)
    Column() {
      SRowView({ label: '清除播放记录', warn: true, focused: this.hi('r_clr'),
        onTap: () => {
          this.clearHist();
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_clr', on) })
    }
    .width('100%')
    .backgroundColor(T.SURFACE)
    .borderRadius(S.CARD_R)
  }

  /** 关于 */
  @Builder
  SectionAbout() {
    this.GroupLabel('关于', this.isPhone ? 16 : 0)
    Column() {
      SRowView({ label: '点击声音', value: this.soundOn ? '开' : '关', arrow: false, focused: this.hi('r_snd'),
        onTap: () => {
          this.toggleTapSound();
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_snd', on) })
      this.SDiv()
      SRowView({ label: '点击震动', value: this.vibrateOn ? '开' : '关', arrow: false, focused: this.hi('r_vib'),
        onTap: () => {
          this.toggleTapVibrate();
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_vib', on) })
      this.SDiv()
      SRowView({ label: '历史同步', value: this.histSyncOn ? '开' : '关', arrow: false, focused: this.hi('r_hsy'),
        onTap: () => {
          this.toggleHistSync();
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_hsy', on) })
      this.SDiv()
      SRowView({ label: '版本', value: 'v' + this.verName, arrow: false, focused: this.hi('r_ver'),
        onTap: () => {
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_ver', on) })
      this.SDiv()
      SRowView({ label: '隐私政策', value: this.showPrivacy ? '收起' : '查看', arrow: true, focused: this.hi('r_pp'),
        onTap: () => {
          this.showPrivacy = !this.showPrivacy;
        },
        onHoverIn: (on: boolean) => this.hoverTo('r_pp', on) })
      if (this.showPrivacy) {
        this.SDiv()
        Column() {
          Text('夜帧影视不收集任何个人信息，也没有自己的服务器。\n' +
            '· 本机保存：源地址、收藏、历史、播放进度、画质偏好——均不上传。\n' +
            '· 网络请求只发往你填写的第三方地址，不经过开发者。\n' +
            '· 权限仅三项：联网、读网络状态、震动（用于按钮点击反馈）；不申请位置、相册、通讯录、设备标识等。\n' +
            '· 无广告、无统计 SDK、无推送 SDK、无账号。\n' +
            '· 扫码录入仅在局域网内起临时页面，离开本页即停止接受写入。')
            .fontSize(13)
            .fontColor(T.SUB)
            .lineHeight(22)
            .width('100%')
          Text('完整条款：https://s3a.abber.cn:88/public/privacy.html')
            .fontSize(12)
            .fontColor(T.DIM)
            .margin({ top: 8 })
            .width('100%')
          Text('本应用为本地播放器，不提供、不存储、不分发任何影视内容；' +
            '内容全部来自你自行填写的第三方接口。')
            .fontSize(12)
            .fontColor(T.DIM)
            .margin({ top: 10 })
            .width('100%')
            .lineHeight(20)
        }
        .width('100%')
        .padding({ left: 30, right: S.PAD_R, top: 12, bottom: 16 })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .backgroundColor(T.SURFACE)
    .borderRadius(S.CARD_R)
  }

  /** 网盘（WebDAV）源管理 */
  @Builder
  SectionWebdav() {
    this.GroupLabel('网盘', this.isPhone ? 16 : 0)
    Column() {
      SRowView({ label: '添加挂载', value: this.wdSources.length + ' 个已挂载', arrow: true, focused: this.hi('wd_add'),
        onTap: () => {
          this.openWdAdd();
        },
        onHoverIn: (on: boolean) => this.hoverTo('wd_add', on) })

      if (this.wdSources.length === 0) {
        this.SDiv()
        Text('挂载 WebDAV 网盘（Alist / 群晖 / Nextcloud 等）后，可在首页「网盘」里浏览目录、识别并播放影视资源。')
          .fontSize(13)
          .fontColor(T.DIM)
          .width('100%')
          .padding({ left: 30, right: S.PAD_R, top: 14, bottom: 18 })
          .lineHeight(21)
      } else {
        ForEach(this.wdSources, (s: WebdavSource, i: number) => {
          this.SDiv()
          SRowView({ label: s.name, value: s.url, arrow: true, focused: this.hi('wd_' + i),
            onTap: () => {
              this.openWdEdit(s);
            },
            onHoverIn: (on: boolean) => this.hoverTo('wd_' + i, on) })
          Row() {
            Text(this.wdScanBusy === i ? '正在识别影视资源…'
              : (this.wdScanCounts[i] > 0 ? '已识别 ' + this.wdScanCounts[i] + ' 部影视' : '尚未识别'))
              .fontSize(13)
              .fontColor(this.wdScanCounts[i] > 0 ? T.SUB : T.DIM)
              .layoutWeight(1)
              .margin({ left: 26 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            this.WdBtn(this.wdScanBusy === i ? '识别中…' : '识别影视', 'wdscan_' + i, false, () => {
              this.scanWd(s, i);
            })
          }
          .width('100%')
          .padding({ left: S.PAD_L, right: S.PAD_R, top: 6, bottom: 12 })
        }, (s: WebdavSource, i: number) => 'wd' + i + s.id)
      }
    }
    .width('100%')
    .backgroundColor(T.SURFACE)
    .borderRadius(S.CARD_R)
  }

  /** 网盘添加/编辑弹窗 */
  @Builder
  WebdavEditPanel() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor(T.BLACK_70)
        .onClick(() => Pointer.fire('st_wdx', () => {
            Feedback.tap();
            this.wdEditOpen = false;
        }))
        .onMouse(Pointer.on('st_wdx', () => {
            Feedback.tap();
            this.wdEditOpen = false;
        }))

      Column() {
        Row() {
          Text(this.wdId.length === 0 ? '添加挂载' : '编辑挂载').fontSize(19).fontColor(T.TXT)
          Blank()
          Text('✕').fontSize(19).fontColor(this.hi('wdx') ? T.TXT : T.SUB)
            .width(42).height(42).textAlign(TextAlign.Center).borderRadius(T.RADIUS_SM)
            .backgroundColor(this.hi('wdx') ? S.ROW_HI : '#00000000')
            .focusable(true)
            // 新增时焦点默认落在「手机扫码录入」上，编辑时才落在关闭按钮
            .defaultFocus(this.wdId.length > 0)
            .onFocus(() => this.hoverTo('wdx', true))
            .onBlur(() => this.hoverTo('wdx', false))
            .onHover((hv: boolean) => this.hoverTo('wdx', hv))
            .onClick(() => Pointer.fire('st_wdx2', () => {
                Feedback.tap();
                this.wdEditOpen = false;
            }))
            .onMouse(Pointer.on('st_wdx2', () => {
                Feedback.tap();
                this.wdEditOpen = false;
            }))
        }
        .width('100%')

        // 电视端的首选入口：遥控器敲 5 个字段（还含大小写敏感的密码）太痛苦，
        // 直接给二维码让手机填。手机端不显示这块，本机键盘就够快。
        if (!this.isPhone) {
          Row() {
            Text('📱').fontSize(20)
            Column() {
              Text('手机扫码录入').fontSize(15).fontColor(T.TXT)
              Text('电视上敲地址太费劲：扫码在手机上填完，电视这边自动保存')
                .fontSize(12).fontColor(T.DIM).margin({ top: 3 }).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 12 })
            .layoutWeight(1)

            Text('打开 ›').fontSize(13).fontColor(T.SELECTED)
          }
          .width('100%')
          .height(64)
          .padding({ left: 14, right: 14 })
          .borderRadius(T.RADIUS)
          .backgroundColor(this.hi('wdqr') ? T.CARD_HI : T.CARD)
          .border({ width: T.BORDER, color: this.hi('wdqr') ? T.TXT : '#00000000' })
          .margin({ top: 14 })
          .animation({ duration: T.ANIM, curve: Curve.EaseOut })
          .focusable(true)
          .defaultFocus(this.wdId.length === 0)
          .onFocus(() => this.hoverTo('wdqr', true))
          .onBlur(() => this.hoverTo('wdqr', false))
          .onHover((hv: boolean) => this.hoverTo('wdqr', hv))
          .onClick(() => Pointer.fire('st_wdqr', () => {
              Feedback.tap();
              this.wdQrOpen = true;
          }))
          .onMouse(Pointer.on('st_wdqr', () => {
              Feedback.tap();
              this.wdQrOpen = true;
          }))
        }

        Column() {
          TextInput({ text: this.wdName, placeholder: '名称（可留空，默认取域名）' })
            .height(46).width('100%').fontSize(15).fontColor(T.TXT).placeholderColor(T.DIM)
            .backgroundColor(T.CARD).borderRadius(T.RADIUS).padding({ left: 14, right: 14 })
            .margin({ top: 14 })
            .onChange((v: string) => {
              this.wdName = v;
            })
          TextInput({ text: this.wdUrl, placeholder: '服务器地址，如 https://dav.example.com/dav' })
            .height(46).width('100%').fontSize(15).fontColor(T.TXT).placeholderColor(T.DIM)
            .backgroundColor(T.CARD).borderRadius(T.RADIUS).padding({ left: 14, right: 14 })
            .margin({ top: 10 })
            .onChange((v: string) => {
              this.wdUrl = v;
            })
          TextInput({ text: this.wdUser, placeholder: '用户名（匿名可留空）' })
            .height(46).width('100%').fontSize(15).fontColor(T.TXT).placeholderColor(T.DIM)
            .backgroundColor(T.CARD).borderRadius(T.RADIUS).padding({ left: 14, right: 14 })
            .margin({ top: 10 })
            .onChange((v: string) => {
              this.wdUser = v;
            })
          TextInput({ text: this.wdPass, placeholder: '密码' })
            .type(InputType.Password)
            .height(46).width('100%').fontSize(15).fontColor(T.TXT).placeholderColor(T.DIM)
            .backgroundColor(T.CARD).borderRadius(T.RADIUS).padding({ left: 14, right: 14 })
            .margin({ top: 10 })
            .onChange((v: string) => {
              this.wdPass = v;
            })
          TextInput({ text: this.wdRoot, placeholder: '挂载根路径，如 /影视（可留空 = 根目录）' })
            .height(46).width('100%').fontSize(15).fontColor(T.TXT).placeholderColor(T.DIM)
            .backgroundColor(T.CARD).borderRadius(T.RADIUS).padding({ left: 14, right: 14 })
            .margin({ top: 10 })
            .onChange((v: string) => {
              this.wdRoot = v;
            })
        }
        .width('100%')

        if (this.wdMsg.length > 0) {
          Text(this.wdMsg).fontSize(13).fontColor(this.wdMsgColor).width('100%').margin({ top: 12 }).lineHeight(20)
        }

        Row() {
          if (this.wdId.length > 0) {
            this.WdBtn('删除', 'wddel', false, () => {
              for (let i = 0; i < this.wdSources.length; i++) {
                if (this.wdSources[i].id === this.wdId) {
                  this.removeWd(this.wdSources[i]);
                  break;
                }
              }
            })
          }
          this.WdBtn(this.wdTesting ? '测试中…' : '测试连接', 'wdtest', false, () => {
            this.testWd();
          })
          Blank()
          this.WdBtn('保存', 'wdsave', true, () => {
            this.saveWd();
          })
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width(Device.panelW(560))
      .padding(24)
      .backgroundColor(T.SURFACE)
      .borderRadius(28)
      .alignItems(HorizontalAlign.Start)
      .focusScopeId('wd_panel', true)
    }
    .width('100%')
    .height('100%')
  }

  /** 网盘弹窗内的胶囊按钮 */
  @Builder
  WdBtn(label: string, key: string, primary: boolean, act: () => void) {
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
      .onFocus(() => this.hoverTo(key, true))
      .onBlur(() => this.hoverTo(key, false))
      .onHover((hv: boolean) => this.hoverTo(key, hv))
      .onClick(() => Pointer.fire('st_btn' + key, () => {
          Feedback.tap();
          act();
      }))
      .onMouse(Pointer.on('st_btn' + key, () => {
          Feedback.tap();
          act();
      }))
  }

  /**
   * 手机端布局：单列纵向滚动，全部 6 个分组依次排布，底部 Tab 导航。
   * 保持不变（原布局）。
   */
  @Builder
  PhoneLayout() {
    Column() {
      this.TitleBar()
      this.MsgBar()
      Scroll() {
        Column() {
          this.SectionSource()
          this.SectionUpdate()
          this.SectionWebdav()
          this.SectionSites()
          this.SectionData()
          this.SectionAbout()
          Row().height(this.isPhone ? 62 : 24)
        }
        .width('100%')
        .padding({ left: 24, right: 24, bottom: 8 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      PhoneTabBar('pages/SettingPage')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(T.BG)
  }

  /** TV 端左侧导航项：高亮竖条 + 文字，hover / 点击即切换右侧内容 */
  @Builder
  NavItem(t: string, key: string, first: boolean = false) {
    Row() {
      Row()
        .width(S.BAR_W)
        .height(22)
        .borderRadius(S.BAR_W / 2)
        .backgroundColor(this.tvNav === key ? T.TXT : '#00000000')
      Text(t)
        .fontSize(17)
        .fontColor(this.tvNav === key ? T.TXT : T.SUB)
        .fontWeight(this.tvNav === key ? FontWeight.Medium : FontWeight.Normal)
        .margin({ left: 14 })
    }
    .width('100%')
    .height(52)
    .padding({ left: 14, right: 14 })
    .borderRadius(12)
    .backgroundColor(this.tvNav === key ? S.ROW_HI : '#00000000')
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
    .focusable(true)
    .defaultFocus(first)
    .onFocus(() => {
      this.tvNav = key;
    })
    .onHover((hv: boolean) => {
      if (hv) {
        this.tvNav = key;
      }
    })
    .onClick(() => Pointer.fire('st_nav' + key, () => {
        Feedback.tap();
        this.tvNav = key;
    }))
    .onMouse(Pointer.on('st_nav' + key, () => {
        Feedback.tap();
        this.tvNav = key;
    }))
  }

  /** TV 端左侧导航栏 */
  @Builder
  TvNav() {
    Column() {
      this.NavItem('播放源', 'source', true)
      this.NavItem('内容更新', 'update')
      this.NavItem('网盘', 'webdav')
      this.NavItem('站源', 'sites')
      this.NavItem('数据', 'data')
      this.NavItem('关于', 'about')
    }
    .width(224)
    .height('100%')
    .padding({ top: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * TV 端布局：左侧导航栏 + 右侧内容区（对照电视系统设置的经典双栏）。
   * 遥控器/鼠标在左侧上下移动即切换右侧分组，内容在右侧独立滚动。
   */
  @Builder
  TvLayout() {
    Column() {
      this.TitleBar()
      this.MsgBar()
      Row() {
        this.TvNav()
        // 导航与内容区之间的细分隔线
        Row()
          .width(1)
          .height('100%')
          .backgroundColor('#14FFFFFF')
        Scroll() {
          Column() {
            if (this.tvNav === 'source') {
              this.SectionSource()
            } else if (this.tvNav === 'update') {
              this.SectionUpdate()
            } else if (this.tvNav === 'webdav') {
              this.SectionWebdav()
            } else if (this.tvNav === 'sites') {
              this.SectionSites()
            } else if (this.tvNav === 'data') {
              this.SectionData()
            } else {
              this.SectionAbout()
            }
            Row().height(24)
          }
          .width('100%')
          .padding({ left: 28, right: 36, bottom: 8 })
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Start)
        }
        .layoutWeight(1)
        .height('100%')
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(T.BG)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.isPhone) {
        this.PhoneLayout()
      } else {
        this.TvLayout()
      }
      if (this.qrOpen) {
        this.QrPanel()
      }
      if (this.wdEditOpen) {
        this.WebdavEditPanel()
      }
      // 网盘扫码录入：盖在「添加挂载」弹窗之上，手机提交完自动收起并刷新列表
      if (this.wdQrOpen) {
        WdQrPanel({
          onClose: () => {
            this.wdQrOpen = false;
          },
          onSaved: (src: WebdavSource) => {
            this.wdQrOpen = false;
            this.wdEditOpen = false;
            this.afterWdQrSaved(src);
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
}
