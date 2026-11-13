import { Feedback } from '../common/Feedback';
import router from '@ohos.router';
import media from '@ohos.multimedia.media';
import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { Store, HistItem, SkipPref } from '../common/Store';
import { Cms } from '../common/Cms';
import { Http } from '../common/Http';
import { PlayParam, Episode, T, WdHistory } from '../common/Model';
import { Playlist } from '../common/Playlist';
import { Live } from '../common/Live';
import { Resolver, Resolved } from '../common/Resolve';
import { QLevel, QSpeed, Quality } from '../common/Quality';
import { Tip } from '../common/Tip';
import { Device, KEY_IS_PHONE } from '../common/Device';
import { Theme, KEY_THEME, THEME_DARK } from '../common/Theme';
import { PlayGuard } from '../common/PlayGuard';
import { Pointer } from '../common/Pointer';
import { PlayState } from '../common/PlayState';
import { PlayerHud } from '../common/PlayerHud';
import { PlayerFmt } from '../common/PlayerFmt';
import { fixPlayable } from '../common/PlayUrl';
import { friendlyErr, isCapabilityHint } from '../common/PlayerErr';
import window from '@ohos.window';

/** 单击快进快退步长 */
const SEEK_STEP: number = 10000;
/** 长按连发到第 9 次之后的单步 */
const SEEK_STEP_FAST: number = 30000;
/** 长按触发连发前的等待，短于系统长按判定，手感更跟手 */
const HOLD_DELAY: number = 420;
/** 连发间隔 */
const HOLD_GAP: number = 110;
const HOLD_GAP_FAST: number = 70;
/** 连发上限，防止按键 Up 事件丢失导致一直跑 */
const HOLD_MAX: number = 200;
/** 每次调音量步长 */
const VOL_STEP: number = 0.05;
/** 连续 seek 合并提交的延迟：HLS 频繁 seek 会卡顿，合并成一次 */
const SEEK_COMMIT_DELAY: number = 260;
/** 开播前探测单条直播流的超时 */
const LIVE_PROBE_MS: number = 2500;
/** 直播连续跳过几个失效频道就停手（再往下也是浪费时间） */
const LIVE_SKIP_MAX: number = 4;
/** 一次换台最多探几条地址，兜住「全源失效」时无限试下去 */
const LIVE_PROBE_MAX: number = 7;
/** 直播错误去重窗口：同一频道X秒内只计一次错误，避免网络抖动误换台 */
const LIVE_ERR_WINDOW: number = 8000;
/** 画面缩放模式常量（对应 media.VideoScaleType 枚举值） */
const SCALE_STRETCH: number = 0;  // 拉伸铺满（可能变形）
const SCALE_CROP: number = 1;     // 等比裁剪铺满（裁掉溢出部分）
const SCALE_FIT: number = 2;      // 等比适应（留黑边）
/** 卡顿看门狗：位置多久不动就认为在缓冲 */
const FREEZE_MS: number = 5000;
/** 两次自动换档的最小间隔，避免来回抖 */
const ADAPT_GAP: number = 15000;
/** 网速实测的采样上限：够算出来就行，别真去下整集 */
const SPEED_BYTES: number = 384 * 1024;
/** 可选倍速档位。系统枚举只认固定几档，这里只列常用的 */
const SPEEDS: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2];

/** 一条可选字幕轨（从 AVPlayer 的轨道表里挑出来的） */
class SubTrack {
  /** selectTrack 要的轨道号 */
  index: number = 0;
  /** 展示名：优先轨道名，其次语言码 */
  label: string = '';
}

/** 一集预加载好的解析结果 */
class PreloadHit {
  url: string = '';
  header: Record<string, string> = {};
  at: number = 0;
}

@Entry
@Component
struct Player {
  @State title: string = '';
  @State errMsg: string = '';
  @State hint: string = '';
  /**
   * 播放器主状态机（common/PlayState.ets）：负责**转移校验 + 轨迹日志 + 缓冲防抖**。
   *
   * 重要教训：UI 布尔（下面的 playing / prepared / buffering / resolving）**必须保持
   * @State 字段，不能改成派生 getter**。实测在 ArkTS 的 @Component 里，用 `this.prepared`
   * 读取 getter 会拿到 `undefined`（真机日志打出来就是 `prepared=undefined`），
   * 而 `!undefined === true`，于是所有以它为前置条件的操作（seek / 倍速 / 播放暂停 /
   * 选字幕）全部静默失效 —— 表现就是「拖进度没反应、倍速设了不生效」。
   *
   * 现在的关系：
   *   - 状态机推进后调 syncFlags()，把三个可由状态推导的布尔同步好；
   *   - prepared **不与状态机耦合**，只跟播放器生命周期走（prepared/playing 事件置 true，
   *     release 置 false）。它是「播放器能不能接受 seek / setSpeed」的物理事实，
   *     不该被 UI 状态推断带偏。
   */
  @State playState: number = PlayState.IDLE;
  /** 进入缓冲前的状态，缓冲结束后据此恢复 PLAYING / PAUSED */
  private stateBeforeBuffer: number = PlayState.IDLE;
  /** 缓冲进入的防抖定时器（见 applyEv 的说明），-1 表示没有待判定 */
  private bufTimer: number = -1;

  /** 是否在播。缓冲也算 —— 缓冲时按暂停应该真暂停，而不是掉进 play() 分支 */
  @State playing: boolean = false;
  /** 播放器已 prepared：可以 seek / 调倍速 / 选字幕轨 */
  @State prepared: boolean = false;
  /** 解析地址中（加载遮罩） */
  @State resolving: boolean = true;
  /** 缓冲转圈中 */
  @State buffering: boolean = false;

  /** 由主状态推导出三个 UI 布尔（prepared 不参与，它只跟播放器生命周期走） */
  private syncFlags(): void {
    const s: number = this.playState;
    this.playing = s === PlayState.PLAYING || s === PlayState.BUFFERING;
    this.buffering = s === PlayState.BUFFERING;
    this.resolving = s === PlayState.IDLE || s === PlayState.LOADING;
  }
  @State curMs: number = 0;
  @State durMs: number = 0;
  @State showOsd: boolean = true;
  @State via: string = '';
  /** 播放列表进度，如「第 3/24 集」 */
  @State epLabel: string = '';
  /** 快进快退预览目标，-1 表示不在预览 */
  @State seekPreview: number = -1;
  @State seekTip: string = '';
  @State volume: number = 1;
  @State muted: boolean = false;
  @State showVol: boolean = false;
  @State toast: string = '';
  @State showToast: boolean = false;
  /** 控制条按钮的指针高亮。灵犀遥控器是鼠标语义，没有焦点框，只能靠 hover 提示「点得到」 */
  @State hoverKey: string = '';
  /** 指针滑过进度条时预览的时间点，-1 表示没在悬浮 */
  @State hoverMs: number = -1;
  /** 控制条上显示的当前画质，如「自动 720P」 */
  @State qLabel: string = '自动';
  /** 画质选择面板是否展开 */
  @State showQ: boolean = false;
  /** 实测网速文案，如「3.4 MB/s」 */
  @State netTxt: string = '';
  /** 画面显示模式：SCALE_STRETCH=0 / SCALE_CROP=1 / SCALE_FIT=2 */
  @State scaleMode: number = SCALE_STRETCH;
  /** 播放倍速，1 = 正常。全局偏好，起播自动生效 */
  @State speed: number = 1;
  /** 这个源提供的字幕轨；空数组表示没有字幕 */
  @State subs: SubTrack[] = [];
  /** 当前选中的字幕下标（subs 的下标），-1 = 关闭 */
  @State subSel: number = -1;
  /** 设备形态：手机竖屏默认等比适应，避免横屏视频被拉伸变形 */
  @StorageProp(KEY_IS_PHONE) isPhone: boolean = false;
  /**
   * 当前主题。播放页自己不跟着换色（面板恒深色，见 T.PANEL_*），
   * 这里只用于让 build 依赖主题状态、保证从设置页切主题回来后能重建。
   */
  @StorageProp(KEY_THEME) themeMode: string = 'dark';
  /** 长按倍速播放中 */
  @State holdSpeedOn: boolean = false;
  /** 按下前保存的原倍速，用于长按松开时恢复 */
  private holdSpeedVal: number = 1;
  /** 当前屏幕亮度（0-1），仅手机端手势调节使用 */
  @State brightnessVal: number = 0.5;
  /** 亮度 HUD 是否可见 */
  @State showBrightness: boolean = false;
  private brightTimer: number = -1;
  /** 手势起始 X（用于判断左/右半屏） */
  private panStartX: number = 0;
  
  // ===== 下一集预加载缓存 =====
  /**
   * 预加载结果缓存：raw url → 已解析好的最终地址。
   *
   * 原来只有一个槽位（preloadedUrl / preloadedFinalUrl / preloadedStatus），
   * 连续快进两集时第二集必然未命中，又得等 8-12 秒解析。
   * 现在按 URL 存一个小表，并在每次起播/切集后预取「后面 2 集」。
   */
  private preloadMap: Map<string, PreloadHit> = new Map();
  /** 正在预取中的 raw url，避免同一集重复发起 */
  private preloadBusy: Set<string> = new Set();

  private player: media.AVPlayer | null = null;
  private initializing: boolean = false;
  /**
   * 页面已销毁。aboutToAppear 是 async 的：解析地址（直播要逐个探源，可能好几秒）
   * 期间用户按返回，页面先销毁、随后 await 才回来，原来的写法会在这之后照样
   * 创建一个 AVPlayer —— 页面已经没了，没人再释放它，于是就「退出后还在播」。
   * 所有异步链路（resolve → initPlayer → createAVPlayer）回来时都要先看这个标志。
   */
  private closed: boolean = false;
  /** onPageHide 时释放过播放器，回到前台需要重建（直播无法续播） */
  private reopenOnShow: boolean = false;
  /**
   * 注册给 PlayGuard 的停止回调（应用切后台 / 被系统回收时兜底）。
   * 注意这里**不能**置 closed：切后台页面还活着，回来要能重建播放器。
   */
  private stopHook: () => void = (): void => {
    this.reopenOnShow = true;
    this.releasePlayer();
  };
  private xController: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private rawUrl: string = '';
  private finalUrl: string = '';
  private header: Record<string, string> = {};
  /** 页面传参带来的 header（WebDAV Basic Auth 等），direct 播放时用它 */
  private paramHeader: Record<string, string> = {};
  /** 是否以「直连」模式进入（WebDAV/直连页）。切集时保持直连，不重新走影视解析器 */
  private directMode: boolean = false;
  private osdTimer: number = -1;
  private volTimer: number = -1;
  private toastTimer: number = -1;
  private holdTimer: number = -1;
  private holdCode: number = -1;
  private holdCount: number = 0;
  private seekCommitTimer: number = -1;
  /**
   * seek 后短暂抑制 timeUpdate 把进度条往回拉。
   * HLS 一次 seek 要重新拉分片，播放器在真正跳过去之前会先回报一个比目标旧的位置，
   * 那个旧值一旦写进 curMs，进度条就会「先退后进」，看着像卡顿/闪烁。
   * 这里记下目标和窗口期，窗口内只接受不落后于目标的回报。
   */
  private seekGuardUntil: number = 0;
  private seekTarget: number = 0;
  /** 确定键去重：onKeyEvent 和 onClick 可能同时触发，用时间戳挡住重复 */
  private lastCenterAt: number = 0;
  /**
   * 进度条拖动状态。
   *
   * 之前进度条只能点不能拖 —— 「点在 37 分」是一次跳跃，想微调到 37:12 只能反复点。
   * 电视上指针模式（灵犀遥控器）本来就支持按住拖，加上 PanGesture 后手感与手机一致。
   */
  @State dragSeeking: boolean = false;
  /**
   * 播放/暂停的中央图标反馈。
   * 控制条在底部，3 米外看「暂停」那个小字很吃力；点一下画面能在正中给一个大图标，
   * 一眼就知道状态变了。值：'' / 'play' / 'pause'
   */
  @State playFlash: string = '';
  /** 拖动开始时的比例（0~1），拖动中用「起点比例 + 位移/条宽」算目标，避免累积误差 */
  private dragBaseRatio: number = 0;
  /** 播放/暂停图标定时器 */
  private flashTimer: number = -1;
  /** 进度条实际宽度（vp），用于把点击位置换算成播放进度 */
  private barW: number = 0;
  /** 播放页宽度（vp），用于左右半屏手势判定；0 表示还没测到 */
  private winW: number = 0;
  /** 已选中的字幕轨道号（AVPlayer 里的轨道号，不是 subs 下标）；-1 表示没选 */
  private subTrackIdx: number = -1;

  private siteKey: string = '';
  private vodId: string = '';
  private epName: string = '';
  private epIndex: number = 0;
  private from: string = '';
  /** WebDAV 续播：源 id / 源名 / 片名 / 目录 */
  private wdSrcId: string = '';
  private wdSrcName: string = '';
  private wdVod: string = '';
  private wdDir: string = '';
  /** WebDAV 续播：是否剧集（多集）。落盘时据此生成「第 N 集」标签 */
  private wdSeries: boolean = false;
  private leaving: boolean = false;
  /** 直播模式。直播地址是「已经在播的流」，绝不能走影视那套解析 */
  private isLive: boolean = false;
  /** 直播连续失败次数：单台失效是常态，自动顺延，连挂 3 台才停手 */
  private liveFail: number = 0;
  /** 上次直播错误时间戳（毫秒），用于去重避免网络抖动误换台 */
  private lastLiveErrMs: number = 0;
  /** 点播连续失败次数：失败 3 次自动返回详情页，让用户尝试其他线路 */
  private vodFail: number = 0;
  /** 当前频道的备用线路（同名频道的其它地址） */
  private liveAlts: string[] = [];

  // ---- 画质自适应相关 ----
  /** 带多档码率的原始 master 地址；画质切换时始终回到它 */
  private masterUrl: string = '';
  /** 可选档位，空数组表示这个源只有一种清晰度 */
  private levels: QLevel[] = [];
  /** 当前档位下标，-1 表示没档位可切 */
  private levelIdx: number = -1;
  /** 0=自动；>0 高度上限；9999=原画 */
  private qCap: number = 0;
  /** 实测下行速率 kbps，-1 未测 */
  private speedKbps: number = -1;
  /** 最近一次卡顿时间与连续卡顿次数 */
  private stallAt: number = 0;
  private stallN: number = 0;
  /** 上次自动换档时间，用作冷却 */
  private adaptAt: number = 0;
  /** 换档后要恢复到的位置 */
  private pendingSeek: number = 0;
  /** 片头跳过秒数（0=关）。起播后自动 seek 到片头结束点 */
  @State introSkipSec: number = 0;
  /** 片尾跳过秒数（0=关）。播到片尾开始点自动跳下一集/结束 */
  @State outroSkipSec: number = 0;
  /** 自定义跳过秒数编辑态：'' 未编辑 / 'intro' / 'outro' */
  @State skipEditKind: string = '';
  /** 编辑中的秒数值 */
  @State skipEditVal: number = 0;
  /** 播放中浮现的 Apple TV 式跳过按钮：'' / 'intro' / 'outro' */
  @State skipShow: string = '';
  /** 跳过按钮倒计时剩余秒（驱动倒计时环） */
  @State skipLeft: number = 0;
  /** 跳过按钮倒计时总秒（算环比例） */
  @State skipTotal: number = 1;
  /** 跳过按钮倒计时 interval 句柄 */
  private skipTimer: number = -1;
  /** 片头跳过本集只做一次，切集后重置 */
  private introDone: boolean = false;
  /** 片尾跳过本集只做一次，切集后重置 */
  private outroFired: boolean = false;
  /** 80% 进度预加载触发标记，切集时复位 */
  private preloadFired80: boolean = false;
  /** 真实播放位置（毫秒）。curMs 只负责显示，避免每秒刷新整棵树 */
  private posMs: number = 0;
  private watchTimer: number = -1;
  private lastWatchMs: number = 0;
  private lastMoveAt: number = 0;
  private measuring: boolean = false;

  /** 页面显示后把焦点抢到根节点。电视遥控器的按键只送给「焦点组件」，
   *  页面切换/条件渲染都可能把焦点弄丢，丢了就再也收不到按键。 */
  onPageShow(): void {
    // 从「隐藏/切后台」恢复显示时复位离开标志，否则 grabFocus 会一直被 leaving 挡住，
    // 电视遥控器抢不回焦点就再也收不到按键。
    this.leaving = false;
    hilog.info(0x1000, 'BOXN', 'onPageShow');
    // 上次隐藏时为了彻底静音把播放器放掉了，这里重建：
    // 直播直接重连当前台，点播把进度接回去（pendingSeek 通道，起播后 seek）
    this.resumeAfterHide();
    setTimeout(() => {
      this.grabFocus();
    }, 300);
  }

  /**
   * 从「隐藏」状态恢复播放。
   * 切后台再回来时 XComponent 的 surface 可能被系统重建，surfaceId 会短暂为空，
   * 这时 initPlayer 会直接返回；所以这里要等 surface 就绪再建，不能把
   * reopenOnShow 提前清掉（清了就再也没人触发重建，画面永远黑着）。
   */
  private resumeAfterHide(retry: number = 0): void {
    if (!this.reopenOnShow || this.closed || this.player !== null || this.finalUrl.length === 0) {
      return;
    }
    if (this.surfaceId.length === 0) {
      // 最多等 10 秒（25 × 400ms），surface 一直不来就放弃，避免定时器空转
      if (retry < 25) {
        setTimeout(() => {
          this.resumeAfterHide(retry + 1);
        }, 400);
      }
      return;
    }
    this.reopenOnShow = false;
    if (!this.isLive && this.posMs > 0) {
      this.pendingSeek = this.posMs;
    }
    // 状态交给主状态机：initPlayer() 里会发 EV_LOAD，UI 自动进入「加载中」
    this.initPlayer();
  }

  onPageHide(): void {
    this.leaving = true;
    hilog.info(0x1000, 'BOXN', 'onPageHide live=%{public}s', this.isLive ? 'y' : 'n');
    // 直播流不能「续播」，而用户返回列表的诉求就是立刻没声音：
    // 直接放掉播放器（pause 对部分 HLS 直播只是停止拉流，已解码的音频仍会播完缓冲）。
    // 回到前台时走 onPageShow 的重建分支重新连当前台。
    if (this.isLive) {
      this.reopenOnShow = true;
      this.releasePlayer();
      return;
    }
    // 点播：暂停即可，回来能原地续播
    this.pausePlayback();
  }

  private grabFocus(): void {
    if (this.leaving) {
      return;
    }
    try {
      this.getUIContext().getFocusController().requestFocus('playerRoot');
      hilog.info(0x1000, 'BOXN', 'requestFocus ok');
    } catch (err) {
      const e = err as BusinessError;
      hilog.info(0x1000, 'BOXN', 'requestFocus fail %{public}s', e.message);
    }
  }

  async aboutToAppear(): Promise<void> {
    // 应用切后台/被回收时由 PlayGuard 兜底停播（页面级 onPageHide 在电视上不可靠）
    PlayGuard.bind(this.stopHook);
    // 手机竖屏默认「等比适应留黑边」：默认的 VIDEO_SCALE_TYPE_FIT 是拉伸铺满，
    // 横屏视频在竖屏手机里会被拉长变形，这里按设备形态切换默认画面比例。
    if (this.isPhone) {
      this.scaleMode = SCALE_FIT;
    }
    await Store.init(getContext(this) as common.UIAbilityContext);
    // 恢复全局偏好：画面比例、清晰度
    await this.restorePreferences();
    if (this.closed) {
      return;
    }
    const p = router.getParams() as PlayParam;
    if (p !== null && p !== undefined) {
      this.title = p.title;
      this.rawUrl = p.url;
      this.siteKey = p.siteKey;
      this.vodId = p.vodId;
      this.epIndex = p.epIndex;
      this.from = p.from;
      this.isLive = p.from === 'live';
      this.directMode = p.from === 'direct';
      this.paramHeader = p.header;
      const cut: number = this.title.lastIndexOf(' ');
      this.epName = cut > 0 ? this.title.substring(cut + 1) : '';
      // 网盘续播：起播后 seek 到上次进度（复用换档的 pendingSeek 通道）
      this.pendingSeek = p.seek > 0 ? p.seek : 0;
      this.wdSrcId = p.wdSrcId.length > 0 ? p.wdSrcId : '';
      this.wdSrcName = p.wdSrcName.length > 0 ? p.wdSrcName : '';
      this.wdVod = p.wdVod.length > 0 ? p.wdVod : '';

      // 片头片尾跳过是**按影片**存的：不同剧/电影的片头长度完全不一样，
      // 用全局值会让 A 剧设的 90 秒套到 B 剧上（表现为「其他视频也被跳过」）。
      // 必须放在这里读 —— restorePreferences() 执行时 siteKey/vodId 还没赋上，
      // 拿到的永远是空串，所有视频会共用一条记录。
      const kh: string[] = this.skipKey();
      const sp: SkipPref = await Store.skipPref(kh[0], kh[1]);
      this.introSkipSec = sp.intro;
      this.outroSkipSec = sp.outro;
      // 倍速也按影片存（用户确认按片保存，与片头跳过一致）：
      // 给某部剧设了 1.5x 不该让纪录片也跟着 1.5x
      this.speed = sp.speed > 0 ? sp.speed : 1;
      this.wdDir = p.wdDir.length > 0 ? p.wdDir : '';
      this.wdSeries = p.wdSeries;
      // 直连（手动填地址）是一个孤立地址，没有剧集概念。
      // 走到这里的调用方未必清过播放列表，这里自愈一次：
      // 否则列表里残留上一部剧，「下一集」和播完自动连播都会串到别的片上。
      // WebDAV 除外——它虽然也走 direct 解析路径，但会正常 set() 整季剧集。
      if (this.directMode && p.siteKey !== 'webdav') {
        Playlist.clear();
      }
    }
    // 画质偏好是全局的：上次选了 720P，这次进来自动还是 720P
    this.qCap = await Store.qualityPref();
    // 倍速同理：整部剧一般都用同一个速度看
    this.speed = await Store.speedPref();
    this.syncEpLabel();

    await this.resolveUrl();
    // 解析地址期间（直播要逐个探源，可能好几秒）用户已经返回：
    // 这里必须收手，否则会在这之后造出一个没人释放的播放器继续出声
    if (this.closed) {
      return;
    }
    if (this.surfaceId.length > 0) {
      this.initPlayer();
    }
  }

  aboutToDisappear(): void {
    this.closed = true;
    PlayGuard.unbind(this.stopHook);
    this.savePos();
    this.releasePlayer();
  }

  onBackPress(): boolean {
    this.leaving = true;
    // 先标记关闭再释放：释放是同步的，但排队中的 initPlayer 回调会看这个标志
    this.closed = true;
    PlayGuard.unbind(this.stopHook);
    this.savePos();
    this.releasePlayer();
    router.back();
    return true;
  }

  syncEpLabel(): void {
    const n: number = Playlist.count();
    if (this.isLive) {
      this.epLabel = n > 1 ? ('第 ' + (Playlist.index() + 1) + '/' + n + ' 台') : '';
      return;
    }
    if (n > 1) {
      this.epLabel = '第 ' + (Playlist.index() + 1) + '/' + n + ' 集';
    } else {
      this.epLabel = '';
    }
  }

  /** 解析出可播放地址。首次进入和切集都会走这里 */
  async resolveUrl(): Promise<void> {
    this.finalUrl = '';
    this.header = {};
    this.hint = '';
    this.levels = [];
    this.levelIdx = -1;
    this.masterUrl = '';
    this.speedKbps = -1;
    this.netTxt = '';
    // 直播单独一条路：地址本身就是流，不需要也无法用影视解析器处理
    if (this.isLive) {
      const url: string = await this.pickPlayableLive();
      if (url.length === 0) {
        this.applyEv(PlayState.EV_ERROR);
        this.errMsg = '这一组频道都打不开。可以在直播页换一个分组，或去设置页换一个直播源。';
        return;
      }
      this.finalUrl = url;
      this.via = '直播直连';
      await this.setupQuality();
      return;
    }
    // 直连播放（本地/局域网文件、单个流地址）：地址就是最终地址，
    // 不能送进影视解析器——那边会把 http://host/a.m3u8?token=x 补成 /index.m3u8，
    // query 一丢就 403，而且 8 个解析器轮询最坏要等 96 秒。
    if (this.directMode) {
      this.finalUrl = this.rawUrl;
      this.header = this.paramHeader;
      this.via = '直连';
      await this.setupQuality();
      return;
    }
    // 先试「补全 m3u8」：采集站第一组线路常给网页地址，真流就是同路径加 /index.m3u8，
    // 命中率远高于走解析接口，而且不用等 8 个解析器轮询到超时。
    let done: boolean = false;
    const guess: string = fixPlayable(this.rawUrl);
    if (guess !== this.rawUrl) {
      try {
        const head: string = await Http.text(guess, undefined, 5000);
        if (head.indexOf('#EXTM3U') >= 0) {
          this.finalUrl = guess;
          this.via = '补全 m3u8';
          done = true;
        }
      } catch (err) {
        // 猜错了就走正常解析
      }
    }

    if (!done) {
      const r: Resolved = await Resolver.resolve(this.rawUrl, Store.parses());
      this.via = r.via;
      this.finalUrl = fixPlayable(r.url);
      this.header = r.header;
      if (this.finalUrl !== r.url) {
        this.via = r.via + ' → m3u8';
      } else if (!r.ok) {
        this.hint = '未能解析出真实播放地址（' + r.via + '），仍尝试直接播放';
      }
    }
    await this.setupQuality();
  }

  /**
   * 后台预加载下一集的播放地址（不初始化播放器，只解析地址）。
   *
   * 在 prepared 回调后触发，用户切集时直接用缓存，省去 8-12s 解析等待。
   * - 不阻塞当前播放（全程后台异步）
   * - 缓存 key 用下一集 rawUrl，切集前先检查 preloadStatus === 1
   * - 切集前 raw url 变了说明缓存失效，仍走正常解析
   */
  private async preloadNextEpisode(): Promise<void> {
    // 直播/直连模式不预加载（它们地址本身就是最终地址，不需要解析）
    if (this.isLive || this.directMode || this.closed) {
      return;
    }
    // 预取后面 2 集：连续快进时第二跳才不会又等 8-12 秒
    await this.preloadAhead(2);
  }

  /**
   * 预取「后面 ahead 集」（默认 2 集）。
   *
   * 连续快进时，只预取下一集的话第二跳必然未命中、又要等 8-12 秒。
   * 串行发起而不是并发：同时解析两条容易把源站打限流，反而更慢。
   */
  private async preloadAhead(ahead: number): Promise<void> {
    if (this.isLive || this.directMode || this.closed) {
      return;
    }
    for (let i = 1; i <= ahead; i++) {
      if (this.closed) {
        return;
      }
      const ep: Episode | null = Playlist.peek(i);
      if (ep === null || ep.url.length === 0) {
        return;
      }
      // 已缓存 / 正在取就跳过
      if (this.preloadMap.has(ep.url) || this.preloadBusy.has(ep.url)) {
        continue;
      }
      this.preloadBusy.add(ep.url);
      await this.preloadOne(ep.url);
    }
  }

  /** 解析并缓存指定 raw url；失败只记日志（预加载失败不该打扰用户） */
  private async preloadOne(rawUrl: string): Promise<void> {
    try {
      let finalUrl: string = '';
      let header: Record<string, string> = {};
      const guess: string = fixPlayable(rawUrl);
      let done: boolean = false;
      if (guess !== rawUrl) {
        try {
          const head: string = await Http.text(guess, undefined, 4000);
          if (head.indexOf('#EXTM3U') >= 0) {
            finalUrl = guess;
            done = true;
          }
        } catch (_e) {
          // 猜错了走正常解析
        }
      }
      if (!done) {
        const r: Resolved = await Resolver.resolve(rawUrl, Store.parses());
        finalUrl = fixPlayable(r.url);
        header = r.header;
      }
      if (this.closed) {
        return;
      }
      this.preloadMap.set(rawUrl, { url: finalUrl, header: header, at: Date.now() });
      hilog.info(0x1000, 'BOXN', 'preload ok: %{public}s', finalUrl.substring(0, 60));
    } catch (e) {
      hilog.info(0x1000, 'BOXN', 'preload fail: %{public}s', (e as Error).message);
    } finally {
      this.preloadBusy.delete(rawUrl);
    }
  }

  /**
   * 切集/切台时尝试使用预加载缓存。
   * 缓存命中时把 finalUrl/header 直接写进去，绕过耗时的 resolveUrl。
   * 缓存未命中或已失效就返回 false，由调用方走正常解析。
   */
  private applyPreload(ep: Episode): boolean {
    if (this.isLive || this.directMode) {
      return false;
    }
    const hit: PreloadHit | undefined = this.preloadMap.get(ep.url);
    if (hit === undefined) {
      return false;
    }
    hilog.info(0x1000, 'BOXN', 'preload hit: %{public}s', ep.url.substring(0, 60));
    this.finalUrl = hit.url;
    this.header = hit.header;
    // 用完即弃：解析结果里可能带临时 token，留久了反而会用到过期地址
    this.preloadMap.delete(ep.url);
    return true;
  }

  // ==================== 画质 ====================

  /**
   * 认一遍这个地址是不是「多档码率的 master playlist」，并把档位选出来。
   *
   * 关键取舍：切档时**不换地址**，仍然把 master 交给播放器，只用
   * PlaybackStrategy.preferredHeight 表达「我要多高的」。这样系统自己的
   * ABR 还在工作，网络瞬断时它能在档位间平滑挪，比我们自己替换流地址稳得多。
   *
   * 性能约束：这个方法在起播的关键路径上（resolveUrl → 这里 → initPlayer），
   * 它多花一秒，用户就多盯一秒黑屏。所以：
   *   - 只抓首包（master playlist 通常 < 2KB，4KB 足够解析完几档）
   *   - 预算 1500ms，源站慢就直接当「单码率」放行，不能让画质探测决定能否起播
   * 原来这里是 peek 4000（还会按跳数翻倍）+ 可能再来一次 6 秒的全量请求，
   * 源站慢时起播前要干等 12 秒以上，屏幕上只有 loading。
   */
  private async setupQuality(): Promise<void> {
    this.masterUrl = this.finalUrl;
    if (this.finalUrl.indexOf('http') !== 0) {
      this.syncQLabel();
      return;
    }
    let head: string = '';
    try {
      head = await Http.peek(this.finalUrl, 1500);
    } catch (e) {
      // 画质探测失败不影响起播（按单码率放行），但要留痕：
      // 排障时要能区分「这源本来单码率」和「探测超时了」
      hilog.info(0x1000, 'BOXN', 'quality probe fail: %{public}s', (e as Error).message);
      this.syncQLabel();
      return;
    }
    if (head.indexOf('#EXT-X-STREAM-INF') < 0) {
      // 单码率：照样有「原画」，只是没得选
      this.syncQLabel();
      return;
    }
    // 首包可能截在某一行的中间，把最后半行去掉，避免解析出残缺的档位行
    if (head.length >= 4096) {
      const nl: number = head.lastIndexOf('\n');
      if (nl > 0) {
        head = head.substring(0, nl + 1);
      }
    }
    const list: QLevel[] = Quality.parseMaster(head, this.finalUrl);
    if (list.length === 0) {
      this.syncQLabel();
      return;
    }
    this.levels = list;
    this.levelIdx = this.pickInitialLevel();
    this.syncQLabel();
  }

  /** 从 Store 恢复播放器全局偏好（画面比例、清晰度、音量）。
   *  倍速**不在这里**：它按影片存，必须在读到 siteKey/vodId 之后才取。 */
  private async restorePreferences(): Promise<void> {
    try {
      this.scaleMode = await Store.scaleModePref();
      this.qCap = await Store.qualityPref();
      // 音量恢复后面，需要播放器准备好
    } catch (e) {
      // 偏好读取失败用默认值，但记一条：否则「为什么每次都是 1.0 倍速」无从查起
      hilog.info(0x1000, 'BOXN', 'pref load fail, use defaults: %{public}s', (e as Error).message);
    }
  }

  /** 初始档位：用户锁了高度就按高度；自动就先用 720P 起步，起来后按实测网速再调 */
  private pickInitialLevel(): number {
    if (this.levels.length === 0) {
      return -1;
    }
    if (this.qCap > 0) {
      return Quality.pickByCap(this.qCap, this.levels);
    }
    if (this.speedKbps > 0) {
      return Quality.pickBySpeed(this.speedKbps, this.levels);
    }
    // 自动模式先挑一个 720P 附近的：起播快，画面也不至于糊
    let best: number = 0;
    for (let i = 0; i < this.levels.length; i++) {
      if (this.levels[i].height > 0 && this.levels[i].height <= 720) {
        best = i;
      }
    }
    return best;
  }

  /** 播放器要的期望高度：0 表示交给系统自己决定 */
  private curHeight(): number {
    if (this.levelIdx >= 0 && this.levelIdx < this.levels.length) {
      return this.levels[this.levelIdx].height;
    }
    return this.qCap > 0 && this.qCap < Quality.TOP ? this.qCap : 0;
  }

  /**
   * 缓冲水位（秒）。慢网多垫一点是治卡顿最有效的一招：
   * 网络抖一下也不至于立刻断流，代价只是起播慢一两秒。
   */
  private bufSec(): number {
    let s: number = 6;
    if (this.speedKbps > 0 && this.speedKbps < 1200) {
      s = 20;
    } else if (this.speedKbps > 0 && this.speedKbps < 2500) {
      s = 14;
    } else if (this.speedKbps > 0 && this.speedKbps < 5000) {
      s = 10;
    }
    if (this.isLive) {
      s += 4;
    }
    return s > 24 ? 24 : s;
  }

  private syncQLabel(): void {
    if (this.levelIdx >= 0 && this.levelIdx < this.levels.length) {
      const name: string = Quality.labelOfLevel(this.levels[this.levelIdx]);
      // 只有一档时不写「自动 1080P」——面板里写着可选档位、点进去却提示
      // 「只有一种清晰度切不了」，用户会以为功能坏了。单档只显示「自动」。
      if (this.levels.length <= 1) {
        this.qLabel = '自动';
        return;
      }
      this.qLabel = this.qCap > 0 ? name : ('自动 ' + name);
      return;
    }
    if (this.qCap >= Quality.TOP) {
      this.qLabel = '原画';
    } else if (this.qCap > 0) {
      this.qLabel = Quality.labelOf(this.qCap, 0);
    } else {
      this.qLabel = '自动';
    }
  }

  /** 用户点某一档 */
  private async chooseLevel(cap: number): Promise<void> {
    const same: boolean = cap === this.qCap;
    this.qCap = cap;
    await Store.setQPref(cap);
    this.showQ = false;
    const next: number = this.levels.length > 0
      ? (cap > 0 ? Quality.pickByCap(cap, this.levels) : this.pickInitialLevel())
      : -1;
    if (next >= 0 && next !== this.levelIdx) {
      await this.applyLevel(next, '已切到 ' + Quality.labelOfLevel(this.levels[next]));
      return;
    }
    this.syncQLabel();
    // 点的是当前这一档：什么都不用做。以前这里会往下走 rebuild，
    // 播放器被销毁重建、进度却没人接，用户看到的是「点了一下画质，从头开始播」。
    if (same) {
      return;
    }
    // 单码率源（绝大多数 m3u8）没有档位可换，但缓冲水位/期望高度还能按新偏好重设一次。
    // 位置必须显式带过去 —— rebuild 自己不设 pendingSeek。
    this.pendingSeek = this.isLive ? 0 : this.posMs;
    await this.rebuild('按新画质偏好重载');
  }

  /**
   * 换档。做法是销毁播放器、用同一个 master 地址重建，只改 preferredHeight。
   * 位置会带过去，用户感知是「顿一下继续」，不是「重新开始」。
   */
  private async applyLevel(i: number, tip: string): Promise<void> {
    if (i < 0 || i >= this.levels.length) {
      return;
    }
    // 直播是实时流，posMs 是「已经缓冲到的旧位置」，带过去 seek 反而会卡住/黑屏，
    // 所以直播一律从直播点重连，不做续播。
    const keep: number = this.isLive ? 0 : this.posMs;
    this.levelIdx = i;
    this.adaptAt = Date.now();
    this.stallN = 0;
    this.syncQLabel();
    this.finalUrl = this.masterUrl;
    this.pendingSeek = keep;
    await this.rebuild(tip);
  }

  /** 重建播放器，保留进度 */
  private async rebuild(tip: string): Promise<void> {
    this.releasePlayer();
    this.errMsg = '';
    if (tip.length > 0) {
      this.showTip(tip);
    }
    await this.initPlayer();
  }

  /** 卡顿计数：60 秒内累计两次就降一档 */
  private onStall(): void {
    const now: number = Date.now();
    if (now - this.stallAt > 60000) {
      this.stallN = 0;
    }
    this.stallAt = now;
    this.stallN++;
    if (this.qCap > 0 || this.levels.length < 2) {
      return;
    }
    if (this.stallN >= 2 && this.levelIdx > 0 && now - this.adaptAt > ADAPT_GAP) {
      const lower: number = this.levelIdx - 1;
      this.applyLevel(lower, '网络偏慢，已自动降到 ' + Quality.labelOfLevel(this.levels[lower]));
    }
  }

  /** 起播后偷偷测一次网速：既用来显示，也用来决定要不要升档 */
  private async measureNet(): Promise<void> {
    if (this.measuring || this.masterUrl.length === 0) {
      return;
    }
    this.measuring = true;
    try {
      let seg: string = '';
      const listUrl: string = (this.levelIdx >= 0 && this.levelIdx < this.levels.length)
        ? this.levels[this.levelIdx].url
        : this.masterUrl;
      try {
        const pl: string = await Http.text(listUrl, undefined, 5000);
        seg = Quality.firstSegment(pl, listUrl);
      } catch (e) {
        // 拿不到分片列表就退回整条播放列表地址估速，但要记下来：
        // 否则测速结果异常时没法判断是源的问题还是这里降级了
        hilog.info(0x1000, 'BOXN', 'quality segment fail, fallback to list url: %{public}s',
          (e as Error).message);
        seg = '';
      }
      if (seg.length === 0) {
        seg = listUrl;
      }
      const sp: QSpeed = await Quality.measure(seg, 4000, SPEED_BYTES);
      if (sp.kbps <= 0) {
        return;
      }
      this.speedKbps = sp.kbps;
      this.netTxt = Quality.fmtKbps(sp.kbps);
      // 网速够、又没在卡，就往上升一档；只升一档，升上去卡了会自己降回来
      if (this.qCap === 0 && this.levels.length > 1 && this.stallN === 0 &&
        this.levelIdx < this.levels.length - 1 && Date.now() - this.adaptAt > ADAPT_GAP) {
        const best: number = Quality.pickBySpeed(sp.kbps, this.levels);
        if (best > this.levelIdx) {
          this.applyLevel(best, '网速良好，已升到 ' + Quality.labelOfLevel(this.levels[best]));
        }
      }
    } finally {
      this.measuring = false;
    }
  }

  /** 卡顿看门狗：播放中位置长时间不动，就是卡了 */
  private startWatch(): void {
    if (this.watchTimer >= 0) {
      return;
    }
    this.lastWatchMs = this.posMs;
    this.lastMoveAt = Date.now();
    this.watchTimer = setInterval(() => {
      if (this.leaving) {
        return;
      }
      // 只盯「正在播」和「已经卡在缓冲」两种状态。
      // 注意不能用 playing getter 判：进了 BUFFERING 之后 playing 已经是 false，
      // 那样看门狗第一分支就 return，卡住以后永远没人把它救回来。
      const active: boolean = this.playState === PlayState.PLAYING ||
        this.playState === PlayState.BUFFERING;
      if (!active) {
        this.lastWatchMs = this.posMs;
        this.lastMoveAt = Date.now();
        return;
      }
      if (this.posMs !== this.lastWatchMs) {
        this.lastWatchMs = this.posMs;
        this.lastMoveAt = Date.now();
        // 位置又动了：如果之前被看门狗判成缓冲，这里收回
        if (this.playState === PlayState.BUFFERING) {
          this.applyEv(PlayState.EV_BUFFER_END);
        }
        return;
      }
      if (Date.now() - this.lastMoveAt > FREEZE_MS) {
        this.applyEv(PlayState.EV_BUFFER_START);
        this.lastMoveAt = Date.now();
        this.onStall();
      }
    }, 1000);
  }

  private stopWatch(): void {
    if (this.watchTimer >= 0) {
      clearInterval(this.watchTimer);
      this.watchTimer = -1;
    }
  }

  /**
   * 单条直播流探活。判据和实现都在 Live.probe 里，
   * 设置页给源打分用的是同一套，避免两处判得不一样。
   */
  private async probeLiveStream(u: string): Promise<boolean> {
    return Live.probe(u, LIVE_PROBE_MS);
  }

  /**
   * 从当前频道往下找第一个能连上的。
   * 顺序是：主线路 → 同台的备用线路 → 下一个台。
   * 直播源里一个 CCTV1 常有三四条地址，换线比换台命中率高得多。
   */
  private async pickPlayableLive(): Promise<string> {
    let skip: number = 0;
    let tries: number = 0;
    while (skip <= LIVE_SKIP_MAX && tries < LIVE_PROBE_MAX) {
      this.syncLiveAlts();
      tries++;
      if (await this.probeLiveStream(this.rawUrl)) {
        this.liveFail = 0;
        return this.rawUrl;
      }
      while (this.liveAlts.length > 0 && tries < LIVE_PROBE_MAX) {
        const alt: string = this.liveAlts[0];
        this.liveAlts = this.liveAlts.slice(1);
        tries++;
        if (await this.probeLiveStream(alt)) {
          this.rawUrl = alt;
          this.liveFail = 0;
          this.showTip('已切到该频道的备用线路');
          return alt;
        }
      }
      if (skip >= LIVE_SKIP_MAX || !Playlist.hasNext()) {
        return '';
      }
      const ep: Episode | null = Playlist.step(1);
      if (ep === null) {
        return '';
      }
      skip++;
      this.liveFail = skip;
      this.rawUrl = ep.url;
      this.epName = ep.name;
      this.epIndex = Playlist.index();
      this.title = ep.name;
      this.syncEpLabel();
      this.showTip('跳过失效频道 → ' + ep.name);
    }
    return '';
  }

  /** 把当前频道除主线路外的其它地址装进 liveAlts */
  private syncLiveAlts(): void {
    this.liveAlts = [];
    const ep: Episode | null = Playlist.current();
    if (ep === null) {
      return;
    }
    for (let i = 0; i < ep.urls.length; i++) {
      const u: string = ep.urls[i];
      if (u !== this.rawUrl && this.liveAlts.indexOf(u) < 0) {
        this.liveAlts.push(u);
      }
    }
  }

  savePos(): void {
    // 直播没有「看到第几分钟」这回事，别往历史里塞
    if (this.isLive) {
      return;
    }
    // WebDAV 播放：走网盘专用续播记录（自包含 url + 进度，下次直接续播）
    if (this.siteKey === 'webdav') {
      this.saveWdPos();
      return;
    }
    if (this.siteKey.length === 0 || this.vodId.length === 0 || this.posMs <= 0) {
      return;
    }
    const h = new HistItem();
    h.siteKey = this.siteKey;
    h.siteName = '';
    h.vodId = this.vodId;
    h.name = '';
    h.pic = '';
    h.epName = this.epName;
    h.epIndex = this.epIndex;
    h.from = this.from;
    h.pos = this.posMs;
    h.dur = this.durMs > 0 ? this.durMs : 0;
    h.time = Date.now();
    Store.updateHistoryPos(h);
  }

  /** WebDAV 播放：把当前进度写进网盘续播记录 */
  saveWdPos(): void {
    if (this.posMs <= 0 || this.wdVod.length === 0) {
      return;
    }
    const h = new WdHistory();
    h.srcId = this.wdSrcId;
    h.srcName = this.wdSrcName;
    h.vodName = this.wdVod;
    h.dir = this.wdDir;
    h.epIndex = this.epIndex;
    // 集标签按「是否剧集」动态生成：剧集记「第 N 集」，电影留空（显示为「电影」）。
    // 不能复用 this.epName —— 那是从标题空格切割出来的，电影名带空格（如「异星战境 Atlas」）
    // 会被误切成集名，剧集名则被切集逻辑覆盖成脏值。
    h.epName = this.wdSeries ? ('第 ' + (this.epIndex + 1) + ' 集') : '';
    h.url = this.rawUrl;
    h.pos = this.posMs;
    h.dur = this.durMs > 0 ? this.durMs : 0;
    h.time = Date.now();
    Store.updateWdHistory(h);
  }

  /**
   * 状态机唯一入口（优化 #133）。
   *
   * 原来 playing/prepared/buffering/resolving/errMsg 在二十多处直接赋值，
   * 组合出来的中间态无法追溯；现在所有生命周期事件都先经 PlayState.reduce
   * 校验，非法/重复事件直接丢弃，每次真实转换留一条轨迹日志。
   *
   * **缓冲事件做了防抖**：真机日志显示起播那一刻 AVPlayer 会把 BUFFER_START /
   * PLAY 连续交替派发，47ms 内抖出 6 次状态转移（BUFFERING↔PLAYING）。后果是
   * 控制条图标和「缓冲中」提示闪烁、stateBeforeBuffer 被反复覆盖。
   * 真正的卡顿会持续几百毫秒以上，所以把「进入缓冲」延后 300ms 生效，
   * 期间收到 BUFFER_END 就当这次抖动没发生过。
   */
  private applyEv(ev: number): void {
    if (ev === PlayState.EV_BUFFER_START) {
      if (this.playState === PlayState.BUFFERING || this.bufTimer >= 0) {
        return;                 // 已在缓冲，或已在等待判定
      }
      this.bufTimer = setTimeout(() => {
        this.bufTimer = -1;
        if (this.playState === PlayState.BUFFERING) {
          return;
        }
        // 真正进入缓冲时再记「缓冲前状态」，此时它才是稳定的
        this.stateBeforeBuffer = this.playState;
        this.moveState(PlayState.EV_BUFFER_START);
      }, 300);
      return;
    }
    if (ev === PlayState.EV_BUFFER_END) {
      if (this.bufTimer >= 0) {
        clearTimeout(this.bufTimer);
        this.bufTimer = -1;
        return;                 // 假缓冲：还没进 BUFFERING 就结束了
      }
      if (this.playState !== PlayState.BUFFERING) {
        return;                 // 迟到的缓冲结束事件，忽略
      }
      // 缓冲结束按「缓冲前的状态」翻译，否则暂停中缓冲完会自己播起来
      const real: number = this.stateBeforeBuffer === PlayState.PAUSED
        ? PlayState.EV_PAUSE : PlayState.EV_PLAY;
      this.moveState(real);
      return;
    }
    this.moveState(ev);
  }

  /** 实际推进状态机并记轨迹（applyEv 被防抖拦住时不走这里） */
  private moveState(ev: number): void {
    const next: number = PlayState.reduce(this.playState, ev);
    if (next === this.playState) {
      return;
    }
    hilog.info(0x1000, 'BOXN', 'playState %{public}s -> %{public}s (ev=%{public}s)',
      PlayState.label(this.playState), PlayState.label(next), PlayState.eventLabel(ev));
    this.playState = next;
    // 状态变了就把三个 UI 布尔同步过去（prepared 不在这里，见字段注释）
    this.syncFlags();
  }

  releasePlayer(): void {
    this.applyEv(PlayState.EV_RESET);
    // prepared 跟着播放器实例走：实例没了就不能再 seek / 调倍速
    this.prepared = false;
    if (this.bufTimer >= 0) {
      clearTimeout(this.bufTimer);
      this.bufTimer = -1;
    }
    if (this.flashTimer >= 0) {
      clearTimeout(this.flashTimer);
      this.flashTimer = -1;
    }
    this.playFlash = '';
    this.clearHold();
    this.stopWatch();
    if (this.osdTimer >= 0) {
      clearTimeout(this.osdTimer);
      this.osdTimer = -1;
    }
    if (this.volTimer >= 0) {
      clearTimeout(this.volTimer);
      this.volTimer = -1;
    }
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
    if (this.seekCommitTimer >= 0) {
      clearTimeout(this.seekCommitTimer);
      this.seekCommitTimer = -1;
    }
    // 停掉「跳过片头片尾」倒计时，防止页面销毁后定时器还在跑
    this.stopSkipTimer();
    this.skipShow = '';
    if (this.player !== null) {
      try {
        this.player.release();
      } catch (e) {
        // ignore
      }
      this.player = null;
    }
    // 播放器没了，状态由 releasePlayer 里的 EV_RESET 统一复位（→ IDLE）。
    // 这里不再单独改 prepared / playing：它们是主状态的派生值，直接改会编译不过
    // （只读 getter），也正是这次改造要堵住的「两套事实打架」。
  }

  async initPlayer(): Promise<void> {
    if (this.closed || this.initializing || this.player !== null || this.surfaceId.length === 0 ||
      this.finalUrl.length === 0) {
      return;
    }
    this.initializing = true;
    this.applyEv(PlayState.EV_LOAD);
    try {
      const sid: string = this.surfaceId;
      const p: media.AVPlayer = await media.createAVPlayer();
      // createAVPlayer 是异步的：等待期间用户可能已经返回，页面销毁后没人再管这个实例。
      // 这里必须自己收掉，否则它会在后台把流一直播下去（「退出后还在播」的另一个来源）。
      if (this.closed) {
        try {
          p.release();
        } catch (e) {
          // ignore
        }
        return;
      }
      this.player = p;

      p.on('error', (err: BusinessError) => {
        hilog.error(0x1000, 'BOXN', 'player error code=%{public}d msg=%{public}s isLive=%{public}s',
          err.code, err.message, this.isLive ? 'YES' : 'NO');
        // 801 / not support 是系统播放器在 prepared 阶段发的**能力提示**，
        // 不是播放失败——紧接着就是 state=playing，画面正常出。
        // 之前把它当失败处理，导致「画面在播却提示无法播放、自动换台」。
        // 判据统一放在 common/PlayerErr.ets，别在页面里再长一套散落判断。
        if (isCapabilityHint(err.code, err.message, this.isLive)) {
          hilog.info(0x1000, 'BOXN', 'capability hint (code=%{public}d), ignore', err.code);
          return;
        }
        this.applyEv(PlayState.EV_ERROR);
        this.errMsg = friendlyErr(err.code, err.message);
        // 直播单台失效太常见（源站限流/换地址），自动顺到下个频道，
        // 连挂 3 台说明整源有问题，停下来给用户看错误和重试
        if (this.isLive && this.liveFail < 3 && Playlist.hasNext()) {
          const now: number = Date.now();
          // 8秒内的重复错误不换台：网络抖动、缓冲超时等临时问题，不代表频道失效
          // 若频繁报错，放行后 liveFail 计数也有上限（<3），不会无限换
          if (now - this.lastLiveErrMs < LIVE_ERR_WINDOW) {
            hilog.info(0x1000, 'BOXN', 'live error suppressed (within %{public}dms window, lastErr=%{public}d now=%{public}d)', 
              LIVE_ERR_WINDOW, this.lastLiveErrMs, now);
            return;
          }
          this.lastLiveErrMs = now;
          this.liveFail++;
          hilog.warn(0x1000, 'BOXN', 'live auto-switch: liveFail=%{public}d/3', this.liveFail);
          this.showTip('该频道无法播放，自动换下一个');
          this.switchEpisode(1);
          return;
        }
        // 点播连续失败 3 次自动返回详情页，让用户尝试其他线路
        if (!this.isLive) {
          this.vodFail++;
          if (this.vodFail < 3) {
            this.showTip('播放失败，正在重试(' + this.vodFail + '/3)');
            this.releasePlayer();
            setTimeout(() => {
              if (!this.closed) {
                this.initPlayer();
              }
            }, 1000);
            return;
          }
          this.showTip('多次播放失败，请尝试其他线路');
          setTimeout(() => {
            if (!this.closed) {
              router.back();
            }
          }, 2000);
          return;
        }
        // 走到这里说明这一台/这一集彻底播不了。错误态的 AVPlayer 只会一直报错，
        // 不会再自己恢复，而 UI 焦点还停在根节点上——用户按「确定」就会进
        // togglePlay 对 error 态调 play()，抛 5400102 且没人捕获。
        // 直接放掉，让「重试」按钮从干净状态重建。
        this.releasePlayer();
        this.showOsd = true;
      });

      p.on('stateChange', (state: media.AVPlayerState) => {
        hilog.info(0x1000, 'BOXN', 'state=%{public}s live=%{public}s', state, this.isLive ? 'y' : 'n');
        if (state === 'initialized') {
          // surfaceId 只能在 initialized 状态下赋值。放在 idle 设会报
          // 5400102 Operate Not Permit: the attribute(SurfaceID) can only be set
          // in the initialized state —— 结果就是有声音没画面。
          try {
            p.surfaceId = sid;
          } catch (e) {
            // 赋值失败也不阻断音频
          }
          p.prepare();
        } else if (state === 'prepared') {
          this.applyEv(PlayState.EV_PREPARED);
          // prepared 是播放器的物理事实，直接置位（不经状态机推导）：
          // seek / 倍速 / 选轨都以它为前提，任何「推导不到」都会让这些功能静默失效
          this.prepared = true;
          // 直播流没有总时长（duration 为 -1），置 0 让 UI 走「直播」分支
          this.durMs = this.isLive ? 0 : p.duration;
          // 成功 prepared 说明这一次播放正常，重置失败计数
          this.vodFail = 0;
          this.liveFail = 0;
          // prepared 时恢复音量偏好（异步，不挡起播）
          Store.volumePref().then((volPref: number) => {
            this.volume = volPref / 15; // 从 0-15 映射回 0-1
            this.applyVolume();
          }).catch(() => {
            // 偏好读取失败用默认值
          });
          // 画面显示模式只能在 prepared/playing/paused/completed 状态设置，
          // initialized 状态设会报 5400102（unsupport video scale operation）
          try {
            p.videoScaleType = this.scaleMode as media.VideoScaleType;
          } catch (e) {
            // 个别机型不支持，忽略
          }
          p.play();
          // 倍速要在起播后设：prepared 之前调 setSpeed 会被忽略
          this.applySpeed(p);
          // 字幕轨只在 prepared 之后才读得到，异步取，不挡起播
          this.loadSubs(p);
          // 后台预加载下一集，不挡当前播放（异步启动，不 await）
          this.preloadNextEpisode().catch(() => {});
          // 部分机型 / 部分流不会补发 playing 状态，这里先乐观置上，
          // 否则控制条会一直以为在暂停（暂停态不自动收起，挡住半屏画面）。
          // 走 applyEv 而不是直接改 playing：READY → PLAYING 是合法转移，
          // 若此时已被判成 ERROR，这一步会被转移表挡掉，不会把错误态覆盖成播放中。
          this.applyEv(PlayState.EV_PLAY);
          this.popOsd();
          // 换档/重载后把位置接回去，用户看到的是「顿一下继续」
          if (this.pendingSeek > 0) {
            const back: number = this.pendingSeek;
            this.pendingSeek = 0;
            setTimeout(() => {
              try {
                if (this.player !== null && this.prepared && back > 0) {
                  this.player.seek(back);
                  this.posMs = back;
                  this.curMs = back;
                  this.markSeek(back);
                }
              } catch (e) {
                // 状态不允许就放弃这次续播
              }
            }, 120);
          } else if (this.introSkipSec > 0 && !this.introDone && !this.isLive) {
            // 跳过片头：起播浮现 Apple TV 式「跳过片头」按钮，点一下或倒计时结束即跳过
            const skipMs: number = this.introSkipSec * 1000;
            if (this.durMs <= 0 || skipMs < this.durMs - 30000) {
              this.showSkipBtn('intro', 5);
            }
          }
          this.startWatch();
          // 起播两秒后再测网速，别和首帧缓冲抢带宽
          setTimeout(() => {
            this.measureNet();
          }, 2000);
        } else if (state === 'playing') {
          this.applyEv(PlayState.EV_PLAY);
          // 双保险：个别机型/源从 initialized 直接到 playing，不补发 prepared
          this.prepared = true;
          this.liveFail = 0;
        } else if (state === 'paused') {
          this.applyEv(PlayState.EV_PAUSE);
        } else if (state === 'completed') {
          this.applyEv(PlayState.EV_COMPLETE);
          hilog.info(0x1000, 'BOXN', 'state=completed, isLive=%{public}s, hasNext=%{public}s', 
            this.isLive ? 'YES' : 'NO', Playlist.hasNext() ? 'yes' : 'no');
          // 直播不走 completed 自动换台：直播流的 completed 通常是短暂断流
          // 或 HLS 分片结束，不代表频道播完，自动换台会造成正常收看时乱跳
          if (this.isLive) {
            hilog.info(0x1000, 'BOXN', 'live completed, ignore auto-switch');
          } else if (Playlist.hasNext()) {
            // 点播追剧：一集播完自动接下一集
            hilog.info(0x1000, 'BOXN', 'vod completed, auto next episode');
            this.switchEpisode(1);
          } else {
            this.showOsd = true;
          }
        }
      });

      // 缓冲状态直接反映到界面上：以前卡住就是黑屏干等，看着像死机
      p.on('bufferingUpdate', (info: media.BufferingInfoType, value: number) => {
        if (info === media.BufferingInfoType.BUFFERING_START) {
          this.applyEv(PlayState.EV_BUFFER_START);
          this.onStall();
        } else if (info === media.BufferingInfoType.BUFFERING_END) {
          this.applyEv(PlayState.EV_BUFFER_END);
        }
      });

      /**
       * 时长补正。
       *
       * 原来只在 prepared 回调里读一次 p.duration，但部分 HLS 源那时还是 -1，
       * 之后系统算出了时长也不会再通知我们 —— 结果是 durMs 恒为 0，
       * 片尾跳过、进度条拖动、片尾倒计时全部失效（而且只在部分源上复现，
       * 看起来像「有些视频片尾不跳」）。
       * 这里监听 durationUpdate，拿到有效值就补上。
       */
      p.on('durationUpdate', (d: number) => {
        if (this.isLive || d <= 0) {
          return;
        }
        if (Math.abs(d - this.durMs) < 1000) {
          return;
        }
        this.durMs = d;
        hilog.info(0x1000, 'BOXN', 'duration corrected to %{public}d', d);
      });

      /**
       * 进度只在显示时同步到 UI。
       * 以前每秒都写 @State curMs，控制条收起时也在刷新整棵组件树，
       * 大屏上一卡一卡的观感有一部分就是这么来的。
       */
      p.on('timeUpdate', (t: number) => {
        this.posMs = t;
        // 片尾跳过：播到片尾起点，浮现 Apple TV 式「下一集/跳过片尾」按钮，点一下或倒计时结束即跳
        //
        // 两道保护（原来都没有）：
        //  1. 片尾秒数必须明显小于总时长（至少留 30 秒正常内容）。
        //     片头那侧一直有这个判断，片尾漏了 —— 一集 60 秒、片尾设 90 秒时，
        //     起播瞬间就满足 t >= dur - 90s，直接弹「跳下一集」。
        //  2. 当前不能已经处在片尾区间之前太久：t 从 0 起算时，上面的式子会退化成
        //     「负数也成立」，靠第 1 条兜住。
        if (!this.isLive && this.outroSkipSec > 0 && this.durMs > 0 && !this.outroFired &&
          this.outroSkipSec * 1000 < this.durMs - 30000 &&
          t >= this.durMs - this.outroSkipSec * 1000) {
          this.outroFired = true;
          this.showSkipBtn('outro', 8);
          return;
        }
        // 80% 进度时再次预加载下一集：prepared 时拿到的解析结果可能因临时 token 失效，
        // 80% 时重新预解析保证切集时命中率更高（约5~10分钟更新一次地址）
        if (!this.isLive && !this.directMode && this.durMs > 60000 &&
          t > 0 && this.durMs > 0 && !this.preloadFired80 &&
          t >= this.durMs * 0.8) {
          this.preloadFired80 = true;
          this.preloadNextEpisode().catch(() => {});
        }
        if (this.seekPreview >= 0) {
          // 拖动/快进预览中：进度条走 seekPreview，这里不碰 curMs，避免预览被实时位置覆盖
          return;
        }
        if (this.showOsd) {
          // seek 后 800ms 内，播放器常先回报一个比目标旧的位置（HLS 重新拉分片），
          // 直接写 curMs 会让进度条先回跳再前进，看着像卡顿。只接受不落后于目标的回报。
          if (this.seekGuardUntil > Date.now() && t < this.seekTarget - 300) {
            return;
          }
          if (Math.abs(t - this.curMs) >= 200) {
            this.curMs = t;
          }
        }
      });

      // 先给数据源，等它进 initialized，再在回调里挂 surface
      try {
        const src: media.MediaSource = media.createMediaSourceWithUrl(this.finalUrl, this.header);
        // 期望清晰度 + 缓冲水位：慢网多垫几秒，是治卡顿最直接的一招
        const strategy: media.PlaybackStrategy = {
          preferredHeight: this.curHeight(),
          preferredBufferDuration: this.bufSec()
        };
        try {
          await p.setMediaSource(src, strategy);
        } catch (e0) {
          // 机型不支持这个策略字段时退回普通设置，不能因为画质策略播不了
          await p.setMediaSource(src);
        }
      } catch (e) {
        p.url = this.finalUrl;
      }
    } catch (err) {
      const e = err as Error;
      this.applyEv(PlayState.EV_ERROR);
      this.errMsg = '初始化播放器失败：' + e.message;
      this.showOsd = true;
    } finally {
      this.initializing = false;
    }
  }

  // ==================== 播放控制 ====================

  /**
   * 暂停播放（页面被遮挡 / 切后台时用）。pause 会触发 stateChange 同步 playing 状态。
   * 这里**不能用 this.playing 做前置判断**：缓冲/换档过程中 playing 可能是 false，
   * 但解码器仍在出声音，判断一挡就变成「明明退出了还在响」。
   */
  private pausePlayback(): void {
    if (this.player !== null && this.prepared) {
      try {
        this.player.pause();
      } catch (e) {
        // ignore
      }
      // 不在这里改 playing：pause() 会触发 stateChange('paused') → EV_PAUSE
    }
  }

  togglePlay(): void {
    if (this.player === null || !this.prepared) {
      hilog.info(0x1000, 'BOXN', 'toggle skipped player=%{public}s prepared=%{public}s state=%{public}s',
        '' + (this.player !== null), '' + this.prepared, PlayState.label(this.playState));
      return;
    }
    hilog.info(0x1000, 'BOXN', 'toggle before playing=%{public}s', this.playing ? 'y' : 'n');
    // play()/pause() 在状态不允许时抛 BusinessError（5400102 等），
    // 这里是 UI 事件回调，没人 catch 就是一条未捕获异常 + 界面完全没反应。
    try {
      if (this.playing) {
        this.player.pause();
        this.flashPlay('pause');
        this.showOsd = true;
        if (this.osdTimer >= 0) {
          clearTimeout(this.osdTimer);
          this.osdTimer = -1;
        }
      } else {
        this.player.play();
        this.flashPlay('play');
        this.popOsd();
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x1000, 'BOXN', 'toggle fail code=%{public}d msg=%{public}s', e.code, e.message);
      // 5400102 = Operate Not Permit：只是「此刻这个状态下不允许 play/pause」，
      // 不是播放失败。以前一律当错误处理 —— 直接释放播放器 + 弹「播放器状态异常」，
      // 在起播那一瞬点一下就能把整部片打掉。prepare/缓冲切换期间这种拒绝很常见，
      // 给个轻提示就够了，等状态就绪再点即可。
      if (e.code === 5400102) {
        this.showTip('画面还没准备好，稍后再试');
        return;
      }
      this.applyEv(PlayState.EV_ERROR);
      this.errMsg = '播放器状态异常，已停止。点「重试」重新加载。';
      this.releasePlayer();
    }
  }

  /**
   * 确定键统一走这里。
   * 鸿蒙电视上「确定」既可能以 KEYCODE_DPAD_CENTER 进 onKeyEvent，
   * 也可能以 click 派发给焦点组件，两条路都接住，用时间戳去重防止一次按键切两下。
   */
  private onCenter(): void {
    const now: number = Date.now();
    if (now - this.lastCenterAt < 220) {
      return;
    }
    this.lastCenterAt = now;
    hilog.info(0x1000, 'BOXN', 'center hit');
    this.clearHold();
    // 控制条收着时，第一下点击只负责把它唤出来。
    // 以前是直接切播放/暂停：控制条 8 秒自动收起，用户想点个按钮，结果画面先停了，
    // 还得再点一下恢复 —— 电视盒子的通行做法也是「先出条、再操作」。
    if (!this.showOsd) {
      this.popOsd();
      return;
    }
    this.togglePlay();
  }

  /** 音量 0~1，muted 时实际下发 0 */
  applyVolume(): void {
    if (this.player === null) {
      return;
    }
    try {
      this.player.setVolume(this.muted ? 0 : this.volume);
    } catch (e) {
      // 状态不允许时忽略，prepared 后会再调一次
    }
  }

  changeVolume(delta: number): void {
    let v: number = this.volume + delta;
    if (v < 0) {
      v = 0;
    }
    if (v > 1) {
      v = 1;
    }
    this.volume = v;
    if (v > 0) {
      this.muted = false;
    }
    // 保存音量偏好（映射到 0-15 范围）
    Store.setVolumePref(Math.round(v * 15)).catch(() => {});
    this.applyVolume();
    this.showVol = true;
    if (this.volTimer >= 0) {
      clearTimeout(this.volTimer);
    }
    this.volTimer = setTimeout(() => {
      this.showVol = false;
      this.volTimer = -1;
    }, 1600);
    this.popOsd();
  }

  toggleMute(): void {
    this.muted = !this.muted;
    this.applyVolume();
    this.showVol = true;
    if (this.volTimer >= 0) {
      clearTimeout(this.volTimer);
    }
    this.volTimer = setTimeout(() => {
      this.showVol = false;
      this.volTimer = -1;
    }, 1600);
    this.popOsd();
  }

  /**
   * 连续快进/快退。
   * 不每次直接 seek：HLS 每个 seek 都要重新拉分片，连按会卡死。
   * 这里先把目标累计到 seekPreview 上做即时反馈，停顿 260ms 再一次性提交。
   */
  seekBy(dir: number, repeat: boolean): void {
    if (this.player === null || !this.prepared) {
      return;
    }
    // 直播是实时流，快进快退没有意义
    if (this.isLive) {
      this.showTip('直播不支持快进，按左右键可换台');
      return;
    }
    const step: number = repeat && this.holdCount > 8 ? SEEK_STEP_FAST : SEEK_STEP;
    const base: number = this.seekPreview >= 0 ? this.seekPreview : this.posMs;
    let target: number = base + dir * step;
    if (target < 0) {
      target = 0;
    }
    if (this.durMs > 0 && target > this.durMs - 1000) {
      target = this.durMs - 1000;
    }
    this.seekPreview = target;
    const diff: number = Math.floor(Math.abs(target - this.posMs) / 1000);
    this.seekTip = (dir > 0 ? '快进 +' : '快退 -') + diff + ' 秒';
    hilog.info(0x1000, 'BOXN', 'seek dir=%{public}d step=%{public}d target=%{public}d', dir, step, target);

    if (this.seekCommitTimer >= 0) {
      clearTimeout(this.seekCommitTimer);
    }
    this.seekCommitTimer = setTimeout(() => {
      this.seekCommitTimer = -1;
      this.commitSeek();
    }, SEEK_COMMIT_DELAY);
    this.popOsd();
  }

  commitSeek(): void {
    const t: number = this.seekPreview;
    this.seekPreview = -1;
    if (t < 0) {
      return;
    }
    this.applySeek(t);
  }

  /** 记一次已提交的 seek，抑制随后 800ms 内播放器回报的旧位置（防回跳闪烁） */
  private markSeek(t: number): void {
    this.seekTarget = t;
    this.seekGuardUntil = Date.now() + 800;
    // seek 后位置瞬间不动是正常的（重新拉分片），别让卡顿看门狗误判成卡死
    this.lastWatchMs = t;
    this.lastMoveAt = Date.now();
  }

  /**
   * 统一的定位入口：点击进度条、键盘快进、拖动松手都走这里。
   *
   * 三件事以前都没有，导致「点了没反应 / 位置显示对但画面没动」：
   *   1. 上限钳制到 dur-800ms：正好 seek 到 duration 会直接进 completed，
   *      画面上就是「一拖到底就黑屏/自动跳集」；
   *   2. 播放器还没 prepared 时不丢弃，记进 pendingSeek，prepared 后自动补上；
   *   3. seek 抛错时把进度回滚到播放器真实位置，不留在假位置上。
   */
  private applySeek(target: number): void {
    if (this.durMs <= 0) {
      return;
    }
    let t: number = target;
    const max: number = this.durMs - 800 > 0 ? this.durMs - 800 : 0;
    if (t > max) {
      t = max;
    }
    if (t < 0) {
      t = 0;
    }
    if (this.player === null || !this.prepared) {
      // 还没准备好（刚切集、刚换档）：排队，等 prepared 回调里再执行
      this.pendingSeek = t > 0 ? t : 0;
      this.showTip('正在准备，稍后跳转');
      return;
    }
    // 用户手动定位时，撤掉正在倒计时的跳过按钮，别和手势打架
    this.cancelSkipBtn();
    try {
      this.player.seek(t);
      this.posMs = t;
      this.curMs = t;
      this.markSeek(t);
      this.updateOutroAfterSeek(t);
      hilog.info(0x1000, 'BOXN', 'seek apply %{public}d', t);
    } catch (e) {
      // 状态不允许：把 UI 拉回播放器真实位置，避免「时间跳了、画面没动」。
      // 同时把目标记进 pendingSeek —— prepared 回调里会自动补跳，
      // 用户不必再拖一次（原来只提示「定位失败」，等于让他重来）。
      this.pendingSeek = t > 0 ? t : 0;
      try {
        const real: number = this.player.currentTime;
        this.posMs = real;
        this.curMs = real;
      } catch (e2) {
        // 连 currentTime 都读不到就保持原样
      }
      this.showTip('正在准备，稍后自动跳转');
    }
  }

  /** 点进度条定位。ratio 为 0~1 */
  seekToRatio(ratio: number): void {
    if (this.player === null || !this.prepared || this.durMs <= 0) {
      // 这条以前是静默 return，真机上表现为「拖了有预览、松手没反应」。
      // 记一条日志，至少能从 hilog 看出是哪一项没满足。
      hilog.info(0x1000, 'BOXN', 'seek skip player=%{public}s prepared=%{public}s dur=%{public}d',
        '' + (this.player !== null), '' + this.prepared, this.durMs);
      return;
    }
    // 点进度条定位同样撤掉跳过按钮
    this.cancelSkipBtn();
    let r: number = ratio;
    if (r < 0) {
      r = 0;
    }
    if (r > 1) {
      r = 1;
    }
    if (this.seekCommitTimer >= 0) {
      clearTimeout(this.seekCommitTimer);
      this.seekCommitTimer = -1;
    }
    this.seekPreview = -1;
    this.applySeek(Math.floor(this.durMs * r));
    this.popOsd();
  }

  /** 切集 / 换台。delta 为 +1 / -1 */
  async switchEpisode(delta: number): Promise<void> {
    // 留一行调用记录：直播自动换台这类问题全靠它回溯「谁触发的」。
    // 不打印调用栈——每次切集都抓 Error().stack 开销明显，而且日志一屏就刷过去了
    hilog.info(0x1000, 'BOXN', 'switchEpisode delta=%{public}d isLive=%{public}s',
      delta, this.isLive ? 'YES' : 'NO');
    // 页面已销毁（用户已返回）时不要再换台/换集——那会重新拉起一个播放器
    if (this.closed) {
      return;
    }
    if (Playlist.count() === 0) {
      this.showTip(this.isLive ? '当前分组没有其他频道'
        : (this.directMode ? '直连播放没有上一集/下一集' : '当前没有可切换的剧集，返回详情页选集'));
      return;
    }
    const ep: Episode | null = Playlist.step(delta);
    if (ep === null) {
      if (this.isLive) {
        this.showTip(delta > 0 ? '已经是最后一个频道' : '已经是第一个频道');
      } else {
        this.showTip(delta > 0 ? '已经是最后一集' : '已经是第一集');
      }
      return;
    }
    this.savePos();
    this.releasePlayer();
    this.curMs = 0;
    this.posMs = 0;
    this.durMs = 0;
    this.seekPreview = -1;
    this.errMsg = '';
    this.stallN = 0;
    this.pendingSeek = 0;
    this.introDone = false;
    this.outroFired = false;
    this.preloadFired80 = false;
    this.epName = ep.name;
    this.epIndex = Playlist.index();
    if (this.isLive) {
      // 直播标题就是频道名，别拼成「直播 CCTV5」
      this.title = ep.name;
      this.showTip('换台：' + ep.name);
    } else {
      this.title = Playlist.title().length > 0 ? (Playlist.title() + ' ' + ep.name) : ep.name;
      this.showTip('第 ' + (this.epIndex + 1) + ' 集  ' + ep.name);
    }
    this.from = this.isLive ? 'live' : (this.directMode ? 'direct' : Playlist.title());
    this.syncEpLabel();

    // 尝试使用下一集预加载缓存，命中时直接使用，省去 8-12s 解析等待
    const hitPreload: boolean = this.applyPreload(ep);

    if (hitPreload) {
      // 命中预加载缓存，已经把 finalUrl/header 写进去，只需 setupQuality
      try {
        await this.setupQuality();
      } catch (e) {
        // 预加载结果过期了或出错，降级走正常解析
        await this.resolveUrl();
      }
    } else {
      // 缓存未命中，走正常解析流程
      await this.resolveUrl();
    }
    this.initPlayer();
  }

  /** 出错后重来一遍：销毁播放器、重新解析当前地址。播不出来时不用退回详情页 */
  async retry(): Promise<void> {
    hilog.info(0x1000, 'BOXN', 'retry');
    this.savePos();
    this.releasePlayer();
    this.liveFail = 0;
    this.curMs = 0;
    this.posMs = 0;
    this.durMs = 0;
    this.errMsg = '';
    this.seekPreview = -1;
    this.stallN = 0;
    this.pendingSeek = 0;
    this.introDone = false;
    this.outroFired = false;
    this.preloadFired80 = false;
    this.skipShow = '';
    this.stopSkipTimer();
    this.showOsd = false;
    await this.resolveUrl();
    this.initPlayer();
  }

  /** 指针悬停高亮（和首页同一套语义） */
  hoverTo(key: string, isHover: boolean): void {
    if (isHover) {
      this.hoverKey = key;
    } else if (this.hoverKey === key) {
      this.hoverKey = '';
    }
  }

  hi(key: string): boolean {
    return this.hoverKey === key;
  }

  /**
   * 这个页面上所有「点一下」的统一入口。
   *
   * 灵犀指向遥控器在智慧屏上发的是鼠标事件（onMouse），而焦点系统会在指针
   * 悬停时把焦点抢走，导致 onClick 不一定触发；触屏/传统遥控走的又是 onClick。
   * 两边都可能到，所以每个热区同时挂 onClick + onMouse，并用 key 做时间窗去重，
   * 保证同一个动作只执行一次。
   *
   * 播放页原来 15 个 onMouse 里一个都没有（只有直播页做过适配），
   * 也就是说这台电视上「播放/暂停、±10 秒、上一集/下一集、音量、播放设置、
   * 画质档位、跳过片头」全都点不动 —— 只能靠遥控器方向键去 Focus 链上摸。
   */
  private tap(key: string, act: () => void): void {
    if (!Pointer.once(key)) {
      return;
    }
    Feedback.tap();
    act();
  }

  /** onMouse 版的同一个热区，内部仍然走 tap() 去重 */
  private ptr(key: string, act: () => void): (e: MouseEvent) => void {
    return Pointer.pressRelease(key, (): void => {
      this.tap(key, act);
    });
  }

  // ==================== 按键 ====================
  private doAction(code: number, repeat: boolean): void {
    if (code === KeyCode.KEYCODE_DPAD_LEFT) {
      // 直播里左右键＝换台，比快退有用得多
      if (this.isLive) {
        this.switchEpisode(-1);
      } else {
        this.seekBy(-1, repeat);
      }
    } else if (code === KeyCode.KEYCODE_DPAD_RIGHT) {
      if (this.isLive) {
        this.switchEpisode(1);
      } else {
        this.seekBy(1, repeat);
      }
    } else if (code === KeyCode.KEYCODE_DPAD_UP) {
      this.changeVolume(VOL_STEP);
    } else if (code === KeyCode.KEYCODE_DPAD_DOWN) {
      this.changeVolume(-VOL_STEP);
    }
  }

  private beginHold(code: number): void {
    this.clearHold();
    this.holdCode = code;
    this.holdCount = 0;
    this.holdTimer = setTimeout(() => {
      this.tickHold();
    }, HOLD_DELAY);
  }

  private tickHold(): void {
    const code: number = this.holdCode;
    if (code < 0) {
      return;
    }
    this.holdCount++;
    if (this.holdCount > HOLD_MAX) {
      this.clearHold();
      return;
    }
    this.doAction(code, true);
    const gap: number = this.holdCount > 8 ? HOLD_GAP_FAST : HOLD_GAP;
    this.holdTimer = setTimeout(() => {
      this.tickHold();
    }, gap);
  }

  private clearHold(): void {
    if (this.holdTimer >= 0) {
      clearTimeout(this.holdTimer);
      this.holdTimer = -1;
    }
    this.holdCode = -1;
    this.holdCount = 0;
  }

  private onKey(e: KeyEvent): void {
    const code: number = e.keyCode;
    if (e.type === KeyType.Up) {
      if (code === this.holdCode) {
        // 松手时把还没提交的 seek 立刻落地，手感才跟得上
        if (this.seekCommitTimer >= 0) {
          clearTimeout(this.seekCommitTimer);
          this.seekCommitTimer = -1;
        }
        this.clearHold();
        this.commitSeek();
      }
      return;
    }
    if (e.type !== KeyType.Down) {
      return;
    }
    e.stopPropagation();
    hilog.info(0x1000, 'BOXN', 'key=%{public}d', code);

    // 播放 / 暂停
    if (code === KeyCode.KEYCODE_DPAD_CENTER || code === KeyCode.KEYCODE_ENTER ||
      code === KeyCode.KEYCODE_SPACE || code === KeyCode.KEYCODE_MEDIA_PLAY_PAUSE ||
      code === KeyCode.KEYCODE_MEDIA_PLAY || code === KeyCode.KEYCODE_MEDIA_PAUSE) {
      this.onCenter();
      return;
    }

    // 音量（遥控器音量键若被系统放行到应用也能接住）
    if (code === KeyCode.KEYCODE_VOLUME_UP) {
      this.clearHold();
      this.changeVolume(VOL_STEP);
      return;
    }
    if (code === KeyCode.KEYCODE_VOLUME_DOWN) {
      this.clearHold();
      this.changeVolume(-VOL_STEP);
      return;
    }
    if (code === KeyCode.KEYCODE_MUTE) {
      this.clearHold();
      this.toggleMute();
      return;
    }

    // 上/下一集
    if (code === KeyCode.KEYCODE_MEDIA_NEXT || code === KeyCode.KEYCODE_PAGE_DOWN) {
      this.clearHold();
      this.switchEpisode(1);
      return;
    }
    if (code === KeyCode.KEYCODE_MEDIA_PREVIOUS || code === KeyCode.KEYCODE_PAGE_UP) {
      this.clearHold();
      this.switchEpisode(-1);
      return;
    }

    // 快进快退：短按一步，长按连续（连发由自己的定时器驱动，
    // 系统补发的重复 Down 在这里被 holdCode 挡掉，不会双倍加速）
    if (code === KeyCode.KEYCODE_DPAD_LEFT || code === KeyCode.KEYCODE_DPAD_RIGHT ||
      code === KeyCode.KEYCODE_DPAD_UP || code === KeyCode.KEYCODE_DPAD_DOWN) {
      if (this.holdCode === code) {
        return;
      }
      this.doAction(code, false);
      // 直播的左右是换台，按住连发会一路冲到最后一个频道，所以不挂连发
      if (!this.isLive || code === KeyCode.KEYCODE_DPAD_UP || code === KeyCode.KEYCODE_DPAD_DOWN) {
        this.beginHold(code);
      }
      return;
    }

    // 快退 / 快进专用键
    if (code === KeyCode.KEYCODE_MEDIA_REWIND) {
      this.seekBy(-1, false);
      return;
    }
    if (code === KeyCode.KEYCODE_MEDIA_FAST_FORWARD) {
      this.seekBy(1, false);
      return;
    }
  }

  // ==================== 提示 ====================

  popOsd(): void {
    // 控制条出现时把「显示位置」对齐到真实位置（没显示时为了省刷新没同步）
    this.curMs = this.posMs;
    this.showOsd = true;
    if (this.osdTimer >= 0) {
      clearTimeout(this.osdTimer);
    }
    this.osdTimer = setTimeout(() => {
      // 暂停时不自动收起，方便看清进度再操作
      if (this.playing) {
        this.showOsd = false;
      }
      this.osdTimer = -1;
    }, 12000);
  }

  /** 中央大图标闪一下 */
  flashPlay(kind: string): void {
    this.playFlash = kind;
    if (this.flashTimer >= 0) {
      clearTimeout(this.flashTimer);
    }
    this.flashTimer = setTimeout(() => {
      this.playFlash = '';
      this.flashTimer = -1;
    }, 700);
  }

  showTip(t: string): void {
    this.toast = t;
    this.showToast = true;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.showToast = false;
      this.toastTimer = -1;
    }, 2000);
    this.popOsd();
  }

  // 错误码翻译与能力提示判定已拆到 common/PlayerErr.ets
  // （friendlyErr / isCapabilityHint），播放地址规整化见 common/PlayUrl.ets。

  // ==================== 格式化 ====================

  /** 进度条读的位置：快进预览时用预览值，松手后才回到真实播放位置 */
  displayMs(): number {
    return this.seekPreview >= 0 ? this.seekPreview : this.curMs;
  }

  /** 毫秒 → mm:ss（超过一小时 h:mm:ss）。实现在 common/PlayerFmt.ets，纯函数 */
  fmt(ms: number): string {
    return PlayerFmt.time(ms);
  }

  volPct(): string {
    return this.muted ? '静音' : (Math.round(this.volume * 100) + '%');
  }

  /**
   * 控制条上的按钮。华为智慧屏灵犀遥控器在指针模式下只产生点击事件，
   * 所以所有操作都必须有一个「能用指针点到」的入口。
   *
   * 注意：文字不能当参数传进来。@Builder 是值传递，传进来的字符串不会跟着
   * this.playing / this.muted 变（踩过：一直显示「播放」）。只能让 builder
   * 内部直接读状态，ArkUI 才会建立依赖。
   */
  @Builder
  CtlBtn(act: number) {
    // styles.xml 的 <style name="Control">：selector_chip(4dp) + textColor=@color/text + 14sp
    Text(this.ctlText(act))
      .fontSize(14)
      .fontColor(this.hi('ctl' + act) ? T.SELECTED : T.PANEL_TXT)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(this.hi('ctl' + act) ? T.PANEL_BTN_HI : '#00000000')
      .borderRadius(T.RADIUS_SM)
      .border({ width: T.BORDER, color: this.hi('ctl' + act) ? T.PANEL_TXT : '#00000000' })
      .margin({ right: 8, bottom: 8 })
      .textAlign(TextAlign.Center)
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .onHover((hv: boolean) => this.hoverTo('ctl' + act, hv))
      .onClick(() => this.tap('ctl' + act, () => this.doCtrl(act)))
      .onMouse(this.ptr('ctl' + act, () => this.doCtrl(act)))
  }

  /** 控制条文案。放在方法里读状态，@Builder 才能跟到变化（传值不会更新） */
  ctlText(act: number): string {
    if (act === 0) {
      return this.isLive ? '上一台' : '上一集';
    }
    if (act === 1) {
      return '−  10 秒';
    }
    if (act === 2) {
      return this.playing ? '暂停' : '播放';
    }
    if (act === 3) {
      return '+  10 秒';
    }
    if (act === 4) {
      return '音量 −';
    }
    if (act === 5) {
      return '音量 +';
    }
    if (act === 6) {
      return this.isLive ? '下一台' : '下一集';
    }
    if (act === 7) {
      return this.muted ? '取消静音' : '静音';
    }
    // act === 8：面板已升级为「播放设置」（画质 + 画面比例 + 跳过片头片尾），入口名跟着改
    return '播放设置';
  }

  doCtrl(act: number): void {
    hilog.info(0x1000, 'BOXN', 'ctl=%{public}d', act);
    if (act === 0) {
      this.switchEpisode(-1);
    } else if (act === 1) {
      this.seekBy(-1, false);
    } else if (act === 2) {
      this.onCenter();
    } else if (act === 3) {
      this.seekBy(1, false);
    } else if (act === 4) {
      this.changeVolume(-VOL_STEP);
    } else if (act === 5) {
      this.changeVolume(VOL_STEP);
    } else if (act === 6) {
      this.switchEpisode(1);
    } else if (act === 7) {
      this.toggleMute();
    } else if (act === 8) {
      this.showQ = !this.showQ;
      hilog.info(0x1000, 'BOXN', 'showQ=%{public}s lv=%{public}d osd=%{public}s',
        '' + this.showQ, this.levels.length, '' + this.showOsd);
      this.popOsd();
    }
  }

  // ---- 画质面板 ----

  /** 「自动」/「原画」这类整体档位 */
  capOn(cap: number): boolean {
    if (cap === 0) {
      return this.qCap === 0;
    }
    if (cap >= Quality.TOP) {
      return this.qCap >= Quality.TOP;
    }
    return this.qCap > 0 && this.qCap < Quality.TOP && this.curHeight() === cap;
  }

  @Builder
  QChip(cap: number, label: string) {
    Text(label)
      .fontSize(15)
      .fontColor(this.capOn(cap) ? T.SELECTED : T.PANEL_TXT)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.capOn(cap) ? T.PANEL_BTN_HI : T.WHITE_15)
      .borderRadius(T.RADIUS_PILL)
      .border({ width: T.BORDER, color: this.capOn(cap) ? T.SELECTED : '#00000000' })
      .margin({ right: 10, bottom: 8 })
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .onHover((hv: boolean) => this.hoverTo('qc' + cap, hv))
      .onClick(() => this.tap('qc' + cap, () => {
        this.chooseLevel(cap);
      }))
      .onMouse(this.ptr('qc' + cap, () => {
        this.chooseLevel(cap);
      }))
  }

  /** 具体某一档（点它 = 锁定这个清晰度） */
  @Builder
  QLvChip(i: number) {
    Text(Quality.labelOfLevel(this.levels[i]))
      .fontSize(15)
      .fontColor(this.lvOn(i) ? T.SELECTED : T.PANEL_TXT)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.lvOn(i) ? T.PANEL_BTN_HI : T.WHITE_15)
      .borderRadius(T.RADIUS_PILL)
      .border({ width: T.BORDER, color: this.lvOn(i) ? T.SELECTED : '#00000000' })
      .margin({ right: 10, bottom: 8 })
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .onHover((hv: boolean) => this.hoverTo('ql' + i, hv))
      .onClick(() => this.tap('ql' + i, () => this.pickLevel(i)))
      .onMouse(this.ptr('ql' + i, () => this.pickLevel(i)))
  }

  lvOn(i: number): boolean {
    return this.qCap > 0 && this.qCap < Quality.TOP && this.levelIdx === i;
  }

  /** 用户点了具体某一档：把这个档位的高度记成偏好，然后立即切 */
  async pickLevel(i: number): Promise<void> {
    if (i < 0 || i >= this.levels.length) {
      return;
    }
    const lv: QLevel = this.levels[i];
    this.qCap = lv.height > 0 ? lv.height : Quality.TOP;
    await Store.setQualityPref(this.qCap);
    this.showQ = false;
    await this.applyLevel(i, '已切到 ' + Quality.labelOfLevel(lv));
  }

  /** 切换画面显示模式（视频缩放）。改 videoScaleType 即时生效，无需重建播放器 */
  private async setScale(mode: number): Promise<void> {
    this.scaleMode = mode;
    await Store.setScaleModePref(mode);
    const name: string = mode === SCALE_CROP ? '裁剪铺满（等比不变形）'
      : (mode === SCALE_FIT ? '等比适应（留黑边）' : '拉伸铺满');
    if (this.player !== null) {
      try {
        this.player.videoScaleType = mode as media.VideoScaleType;
      } catch (e) {
        // 个别流/机型不支持改缩放。以前这里静默忽略、照样提示「画面比例：X」，
        // 用户会以为设置成功但画面没变 —— 现在如实说是这个源不支持。
        hilog.info(0x1000, 'BOXN', 'setScale fail: %{public}s', (e as Error).message);
        this.showTip('这个源不支持调整画面比例');
        return;
      }
    }
    this.showTip('画面比例：' + name);
  }

  /**
   * 设置项的作用范围标签。
   *
   * 播放设置里混着两种范围：画面比例是全局的（换片也沿用），
   * 倍速/片头/片尾是按影片存的。界面不标出来，用户根本分不清
   * 「这个改动会影响谁」—— 之前片头跳过串到别的视频，一半原因就是这里没交代。
   */
  @Builder
  ScopeTag(text: string) {
    Text(text)
      .fontSize(10)
      .fontColor(T.PANEL_DIM)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .margin({ left: 8 })
      .borderRadius(4)
      .border({ width: 1, color: '#33FFFFFF' })
  }

  /** 点画面唤出控制条等隐藏手势的说明文案 */
  private handTipText(): string {
    const lines: string[] = [
      '· 点画面唤出控制条，拖进度条或左右滑可快进/快退',
      '· 上下滑：左半屏调亮度、右半屏调音量'
    ];
    if (!this.isLive) {
      lines.push('· 长按左右两侧可连续快进/快退，松手即定位');
      lines.push('· 播完自动接下一集；片头片尾可在这里设置跳过（仅对当前这部片生效）');
    } else {
      lines.push('· 直播实时流不支持快进，压左右键可切上一个/下一个频道');
      lines.push('· 部分直播源不支持倍速，切了没变化时会给出提示');
    }
    return lines.join('\n');
  }

  /**
   * 画质选择浮层。
   *
   * 原来这块是塞在底部控制条里的，跟着 OSD 一起向上长。多档位的源（比如 5 档）
   * 面板一展开就把 OSD 顶出屏幕顶部 —— 实测 dumpLayout 直接抓不到面板节点，
   * 等于「点了画质什么也没出现」。改成独立居中浮层后，档位再多也放得下。
   */

  /** 画面显示模式选项（拉伸/裁剪），放进画质面板 */
  @Builder
  ScaleChip(mode: number, label: string) {
    Text(label)
      .fontSize(15)
      .fontColor(this.scaleMode === mode ? T.SELECTED : T.PANEL_TXT)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.scaleMode === mode ? T.PANEL_BTN_HI : T.WHITE_15)
      .borderRadius(T.RADIUS_PILL)
      .border({ width: T.BORDER, color: this.scaleMode === mode ? T.SELECTED : '#00000000' })
      .margin({ right: 10, bottom: 8 })
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .onClick(() => this.tap('sc' + mode, () => this.setScale(mode)))
      .onMouse(this.ptr('sc' + mode, () => this.setScale(mode)))
  }

  /** 跳过片头/片尾的档位 chip。kind = 'intro' | 'outro'，sec 单位秒，0 表示关 */
  @Builder
  SkipChip(kind: string, sec: number) {
    Text(this.skipLabel(sec))
      .fontSize(15)
      .fontColor(this.skipOn(kind, sec) ? T.SELECTED : T.PANEL_TXT)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.skipOn(kind, sec) ? T.PANEL_BTN_HI : T.WHITE_15)
      .borderRadius(T.RADIUS_PILL)
      .border({ width: T.BORDER, color: this.skipOn(kind, sec) ? T.SELECTED : '#00000000' })
      .margin({ right: 10, bottom: 8 })
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .onHover((hv: boolean) => this.hoverTo('sk_' + kind + '_' + sec, hv))
      .onClick(() => this.tap('skc_' + kind + '_' + sec, () => {
        this.pickSkip(kind, sec);
      }))
      .onMouse(this.ptr('skc_' + kind + '_' + sec, () => {
        this.pickSkip(kind, sec);
      }))
  }

  // ==================== 倍速 / 字幕 ====================

  /** 倍率 → 系统枚举。系统只认固定几档，别的值一律按 1.0 处理 */
  private static speedOf(v: number): media.PlaybackSpeed {
    if (v === 0.5) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    }
    if (v === 0.75) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    }
    if (v === 1.25) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    }
    if (v === 1.5) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    }
    if (v === 2) {
      return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    }
    return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
  }

  /**
   * 设一次倍速。prepared 之后才能设，idle/initialized 调会被忽略；
   * 个别流（直播切片、DRM）不支持变速，抛错就静默跳过——
   * 否则一个「能不能变速」的问题会把整条起播链路打断。
   */
  private applySpeed(p: media.AVPlayer): void {
    // 注意不能「speed === 1 就 return」：从 1.5x 调回 1.0x 时正是要靠这句
    // setSpeed(1.0) 把速度改回来，return 掉的话声音还是快的。
    try {
      p.setSpeed(Player.speedOf(this.speed));
    } catch (e) {
      // 不支持变速的源（HLS 直播、部分点播封装）会抛 BusinessError。
      // 以前这里空 catch，用户只看到「已切到 1.5 倍速」而声音没变 ——
      // 现在明说，至少不会以为是软件坏了。
      const err = e as Error;
      hilog.error(0x1000, 'BOXN', 'setSpeed fail %{public}s: %{public}s', '' + this.speed, err.message);
      // 别只说「不支持」就完事：直播源不支持变速是常态，用户真正想知道的是「那我还能怎么办」。
      // 点播换线路/换画质后可能就支持了；直播只能回 1.0 倍速。
      if (this.isLive) {
        this.showTip('直播流不支持 ' + this.speed + ' 倍速，已保持原速');
      } else {
        this.showTip('这个源不支持 ' + this.speed + ' 倍速，可换条线路再试');
      }
    }
  }

  private async pickSpeed(v: number): Promise<void> {
    this.speed = v;
    // 按影片保存（不再写全局 playerSpeed，否则又会串到其他视频）
    const k: string[] = this.skipKey();
    await Store.setSkipPrefSpeed(k[0], k[1], v);
    if (this.player !== null && this.prepared) {
      this.applySpeed(this.player);
      hilog.info(0x1000, 'BOXN', 'speed apply %{public}s state=%{public}s',
        '' + v, PlayState.label(this.playState));
      this.showTip(v === 1 ? '已恢复 1.0 倍速（仅本片）' : ('已切到 ' + v + ' 倍速（仅本片）'));
    } else {
      // 以前无论有没有真正生效都弹「已切到 1.5 倍速」，用户看到提示却听不出变化。
      hilog.info(0x1000, 'BOXN', 'speed skip player=%{public}s prepared=%{public}s state=%{public}s',
        '' + (this.player !== null), '' + this.prepared, PlayState.label(this.playState));
      this.showTip('播放器还没准备好，倍速稍后生效');
    }
  }

  /**
   * 读一遍轨道表，把字幕轨挑出来。
   *
   * 以前干脆没做字幕：HLS 里带 WEBVTT/TTML 字幕轨的片子，用户只能在
   * 「有字幕的播放器」里看。这里走系统能力——AVPlayer 的轨道表里字幕轨
   * 的 track_type 是 MEDIA_TYPE_SUBTITLE，选中即显示，不需要自己渲染。
   * 没有字幕轨时保持空数组，面板显示「这个源没有字幕轨」，
   * 而不是留一个点了没反应的开关。
   */
  private async loadSubs(p: media.AVPlayer): Promise<void> {
    try {
      const list = await p.getTrackDescription();
      const out: SubTrack[] = [];
      for (let i = 0; i < list.length; i++) {
        const d = list[i];
        const tt: number = d['track_type'] as number;
        if (tt !== media.MediaType.MEDIA_TYPE_SUBTITLE) {
          continue;
        }
        const st = new SubTrack();
        st.index = d['track_index'] as number;
        const nm: string = d['track_name'] !== undefined && d['track_name'] !== null
          ? String(d['track_name']) : '';
        const lang: string = d['language'] !== undefined && d['language'] !== null
          ? String(d['language']) : '';
        st.label = nm.length > 0 ? nm : (lang.length > 0 ? lang : ('字幕 ' + (out.length + 1)));
        out.push(st);
      }
      this.subs = out;
      this.subSel = -1;
      this.subTrackIdx = -1;
    } catch (e) {
      this.subs = [];
    }
  }

  private async pickSub(i: number): Promise<void> {
    if (this.player === null || !this.prepared) {
      this.showTip('还没起播，等画面出来再切字幕');
      return;
    }
    const p = this.player;
    try {
      if (i < 0) {
        if (this.subTrackIdx >= 0) {
          await p.deselectTrack(this.subTrackIdx);
        }
        this.subTrackIdx = -1;
        this.subSel = -1;
        this.showTip('已关闭字幕');
        return;
      }
      if (i >= this.subs.length) {
        return;
      }
      const t: SubTrack = this.subs[i];
      await p.selectTrack(t.index);
      this.subTrackIdx = t.index;
      this.subSel = i;
      this.showTip('字幕：' + t.label);
    } catch (e) {
      this.showTip('这个源不支持切换字幕');
    }
  }

  @Builder
  SpeedChip(v: number) {
    Text(v === 1 ? '1.0x' : (v + 'x'))
      .fontSize(15)
      .fontColor(this.speed === v ? T.SELECTED : T.PANEL_TXT)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.speed === v ? T.PANEL_BTN_HI : T.WHITE_15)
      .borderRadius(T.RADIUS_PILL)
      .border({ width: T.BORDER, color: this.speed === v ? T.SELECTED : '#00000000' })
      .margin({ right: 10, bottom: 8 })
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .onHover((hv: boolean) => this.hoverTo('spd' + v, hv))
      .onClick(() => this.tap('spd' + v, () => {
        this.pickSpeed(v);
      }))
      .onMouse(this.ptr('spd' + v, () => {
        this.pickSpeed(v);
      }))
      // 长按倍速播放：按下时改为 2.0x，松开恢复原倍速
      .gesture(
        LongPressGesture({ duration: 300 })
          .onAction(() => {
            if (!this.holdSpeedOn && this.player !== null) {
              this.holdSpeedVal = this.speed;
              this.holdSpeedOn = true;
              this.pickSpeed(2);
              Tip.show('长按倍速播放：2.0x');
            }
          })
          .onActionEnd(() => {
            if (this.holdSpeedOn) {
              this.holdSpeedOn = false;
              this.pickSpeed(this.holdSpeedVal);
              Tip.show('恢复倍速：' + (this.holdSpeedVal + 'x'));
            }
          })
      )
  }

  @Builder
  SubChip(i: number, label: string) {
    Text(label)
      .fontSize(15)
      .fontColor(this.subSel === i ? T.SELECTED : T.PANEL_TXT)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.subSel === i ? T.PANEL_BTN_HI : T.WHITE_15)
      .borderRadius(T.RADIUS_PILL)
      .border({ width: T.BORDER, color: this.subSel === i ? T.SELECTED : '#00000000' })
      .margin({ right: 10, bottom: 8 })
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .onHover((hv: boolean) => this.hoverTo('sub' + i, hv))
      .onClick(() => this.tap('sub' + i, () => {
        this.pickSub(i);
      }))
      .onMouse(this.ptr('sub' + i, () => {
        this.pickSub(i);
      }))
  }

  private skipOn(kind: string, sec: number): boolean {
    const cur: number = kind === 'intro' ? this.introSkipSec : this.outroSkipSec;
    return cur === sec;
  }

  private skipLabel(sec: number): string {
    return sec <= 0 ? '关' : (sec + ' 秒');
  }

  private async pickSkip(kind: string, sec: number): Promise<void> {
    if (kind === 'intro') {
      this.introSkipSec = sec;
    } else {
      this.outroSkipSec = sec;
    }
    // 只写当前这部片，不影响其他视频（键的合成规则见 skipKey()）
    const k1: string[] = this.skipKey();
    await Store.setSkipPref(k1[0], k1[1], this.introSkipSec, this.outroSkipSec);
    if (kind === 'intro') {
      this.showTip(sec > 0 ? ('已设片头跳过 ' + sec + ' 秒，本片起播自动生效') : '已关闭片头跳过');
    } else {
      this.showTip(sec > 0 ? ('已设片尾跳过 ' + sec + ' 秒，本片播到片尾自动切') : '已关闭片尾跳过');
    }
  }

  /**
   * 跳过设置的主键 [siteKey, vodId]。
   *
   * 点播有 siteKey/vodId；网盘和直连这两类在这两个字段上是空的，
   * 如果直接用会把所有网盘/直连视频挤到同一条记录里（等于又变成全局）。
   * 这里按来源合成：
   *   - 网盘：用 wdSrcId + wdVod（网盘源 + 条目路径，唯一）
   *   - 直连：用 rawUrl（地址本身唯一）
   */
  private skipKey(): string[] {
    if (this.siteKey.length > 0 || this.vodId.length > 0) {
      return [this.siteKey, this.vodId];
    }
    if (this.wdSrcId.length > 0 || this.wdVod.length > 0) {
      return ['wd:' + this.wdSrcId, this.wdVod];
    }
    // 直连：地址可能带临时签名，取「问号前」的部分当主键，避免每次进都变
    const u: string = this.rawUrl;
    const q: number = u.indexOf('?');
    return ['direct', q > 0 ? u.substring(0, q) : u];
  }

  /** 秒数格式化：90 → 1分30秒；45 → 45秒；60 → 1分钟（实现在 common/PlayerFmt.ets） */
  private fmtSec(sec: number): string {
    return PlayerFmt.sec(sec);
  }

  /** 浮现 Apple TV 式跳过按钮并启动倒计时。kind = 'intro' | 'outro' */
  private showSkipBtn(kind: string, totalSec: number): void {
    this.skipShow = kind;
    this.skipTotal = totalSec > 0 ? totalSec : 1;
    this.skipLeft = this.skipTotal;
    // 按钮浮现时收起控制条，画面干净、只剩跳过按钮，贴合 Apple TV 的沉浸式体验
    this.showOsd = false;
    this.stopSkipTimer();
    this.skipTimer = setInterval(() => {
      this.skipLeft -= 0.1;
      if (this.skipLeft <= 0) {
        this.stopSkipTimer();
        this.doSkip(kind);
      }
    }, 100);
  }

  /** 停止倒计时（不执行跳过） */
  private stopSkipTimer(): void {
    if (this.skipTimer >= 0) {
      clearInterval(this.skipTimer);
      this.skipTimer = -1;
    }
  }

  /** 取消跳过按钮（用户手动 seek / 切集时）。片尾跳过状态由 updateOutroAfterSeek 按目标位置重置 */
  private cancelSkipBtn(): void {
    this.skipShow = '';
    this.stopSkipTimer();
  }

  /**
   * 手动 seek 后更新片尾跳过状态。
   * 用户拖动/点击进度条定位到片尾区域 = 主动想看片尾，本集不再自动跳下一集；
   * 定位到片尾区域之外 = 恢复自动跳，之后自然播到片尾仍会提示。
   * 修复「一拉进度条就倒计时切下一集」的问题。
   */
  private updateOutroAfterSeek(t: number): void {
    // 与 timeUpdate 里的判断保持一致：片尾秒数不小于总时长时视为「不启用」，
    // 否则拖动进度条会立刻被判成「已进入片尾」而触发跳集
    if (this.outroSkipSec > 0 && this.durMs > 0 &&
      this.outroSkipSec * 1000 < this.durMs - 30000) {
      this.outroFired = t >= this.durMs - this.outroSkipSec * 1000;
    }
  }

  /** 执行跳过动作（点击或倒计时结束） */
  private doSkip(kind: string): void {
    if (this.skipShow !== kind) {
      return;
    }
    this.skipShow = '';
    this.stopSkipTimer();
    if (kind === 'intro') {
      this.introDone = true;
      const skipMs: number = this.introSkipSec * 1000;
      try {
        if (this.player !== null && this.prepared && skipMs > 0) {
          this.player.seek(skipMs);
          this.posMs = skipMs;
          this.curMs = skipMs;
          this.markSeek(skipMs);
        }
      } catch (e) {
        // 状态不允许就放弃这次跳过
      }
      this.showTip('已跳过片头 ' + this.fmtSec(this.introSkipSec));
    } else {
      this.outroFired = true;
      if (Playlist.hasNext()) {
        this.showTip('片尾，跳下一集');
        this.switchEpisode(1);
      } else {
        this.showTip('已跳过片尾');
        try {
          if (this.player !== null) {
            this.player.seek(this.durMs);
          }
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /** 倒计时环剩余比例（0~1），驱动圆形进度环 */
  private skipRingProgress(): number {
    if (this.skipTotal <= 0) {
      return 0;
    }
    const p: number = this.skipLeft / this.skipTotal;
    return p < 0 ? 0 : (p > 1 ? 1 : p);
  }

  /** 标记当前位置：片头 = 当前播放位置（秒）；片尾 = 距结尾距离（秒） */
  private async markSkip(kind: string): Promise<void> {
    if (kind === 'intro') {
      const posSec: number = Math.max(0, Math.round(this.posMs / 1000));
      this.introSkipSec = posSec;
      await Store.setIntroSkipSec(posSec);
      this.showTip(posSec > 0
        ? ('已标记片头结束点 ' + this.fmtSec(posSec) + '，下次起播跳到这里')
        : '当前位置是片头起点，无法标记');
    } else {
      const leftSec: number = Math.max(0, Math.round((this.durMs - this.posMs) / 1000));
      this.outroSkipSec = leftSec;
      await Store.setOutroSkipSec(leftSec);
      this.showTip(leftSec > 0
        ? ('已标记片尾起点（距结尾 ' + this.fmtSec(leftSec) + '），播到这里自动切')
        : '已到片尾，无法标记');
    }
  }

  /** 编辑值拆出的分钟数（0~10） */
  private skipEditMin(): number {
    return Math.floor(this.skipEditVal / 60);
  }

  /** 编辑值拆出的秒数（0~59） */
  private skipEditSecOnly(): number {
    return this.skipEditVal % 60;
  }

  /** 打开自定义秒数编辑 */
  private openSkipEdit(kind: string): void {
    this.skipEditKind = kind;
    const cur: number = kind === 'intro' ? this.introSkipSec : this.outroSkipSec;
    this.skipEditVal = cur > 0 ? cur : 30;
  }

  /** 步进调整编辑值，范围 0~600 秒 */
  private adjSkipEdit(delta: number): void {
    this.skipEditVal = Math.max(0, Math.min(600, this.skipEditVal + delta));
  }

  /** 应用自定义秒数 */
  private async applySkipEdit(): Promise<void> {
    if (this.skipEditKind === 'intro') {
      this.introSkipSec = this.skipEditVal;
    } else if (this.skipEditKind === 'outro') {
      this.outroSkipSec = this.skipEditVal;
    }
    // 同样只写当前这部片
    const k2: string[] = this.skipKey();
    await Store.setSkipPref(k2[0], k2[1], this.introSkipSec, this.outroSkipSec);
    if (this.skipEditKind === 'intro') {
      this.showTip(this.skipEditVal > 0
        ? ('已设片头跳过 ' + this.fmtSec(this.skipEditVal) + '（仅本片）')
        : '已关闭片头跳过');
    } else if (this.skipEditKind === 'outro') {
      this.showTip(this.skipEditVal > 0
        ? ('已设片尾跳过 ' + this.fmtSec(this.skipEditVal) + '（仅本片）')
        : '已关闭片尾跳过');
    }
    this.skipEditKind = '';
  }

  /** 动作 chip 点击分发 */
  private onSkipAction(kind: string, mode: string): void {
    if (mode === 'custom') {
      this.openSkipEdit(kind);
    } else {
      this.markSkip(kind);
    }
  }

  /** 跳过设置的动作 chip（自定义 / 标当前） */
  @Builder
  SkipActionChip(kind: string, mode: string, label: string) {
    Text(label)
      .fontSize(15)
      .fontColor(this.hi('sk_' + kind + '_' + mode) ? T.SELECTED : T.PANEL_SUB)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.hi('sk_' + kind + '_' + mode) ? T.PANEL_BTN_HI : T.WHITE_15)
      .borderRadius(T.RADIUS_PILL)
      .border({ width: T.BORDER, color: this.hi('sk_' + kind + '_' + mode) ? T.SELECTED : '#00000000' })
      .margin({ right: 10, bottom: 8 })
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .onHover((hv: boolean) => this.hoverTo('sk_' + kind + '_' + mode, hv))
      .onClick(() => this.tap('ska_' + kind + '_' + mode, () => {
        this.onSkipAction(kind, mode);
      }))
      .onMouse(this.ptr('ska_' + kind + '_' + mode, () => {
        this.onSkipAction(kind, mode);
      }))
  }

  /** 步进按钮 */
  @Builder
  StepBtn(delta: number, label: string) {
    Text(label)
      .fontSize(15)
      .fontColor(this.hi('skstep_' + delta) ? T.SELECTED : T.PANEL_TXT)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .backgroundColor(this.hi('skstep_' + delta) ? T.PANEL_BTN_HI : T.WHITE_15)
      .borderRadius(T.RADIUS_PILL)
      .border({ width: T.BORDER, color: this.hi('skstep_' + delta) ? T.SELECTED : '#00000000' })
      .margin({ right: 8 })
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .onHover((hv: boolean) => this.hoverTo('skstep_' + delta, hv))
      .onClick(() => this.tap('skstep_' + delta, () => this.adjSkipEdit(delta)))
      .onMouse(this.ptr('skstep_' + delta, () => this.adjSkipEdit(delta)))
  }

  /** 自定义位置编辑条：分、秒两个维度各自加减，实时显示当前位置 */
  @Builder
  SkipEditBar(kind: string) {
    Column() {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, justifyContent: FlexAlign.Start }) {
        Text(kind === 'intro' ? '片头结束点' : '片尾起点')
          .fontSize(14).fontColor(T.PANEL_DIM)
          .margin({ right: 14 })

        Text('分')
          .fontSize(14).fontColor(T.PANEL_SUB)
          .margin({ right: 4 })
        this.StepBtn(-60, '-1')
        Text(this.skipEditMin().toString())
          .fontSize(18).fontColor(T.SELECTED)
          .margin({ left: 8, right: 8 })
        this.StepBtn(60, '+1')

        Text('秒')
          .fontSize(14).fontColor(T.PANEL_SUB)
          .margin({ left: 14, right: 4 })
        this.StepBtn(-5, '-5')
        Text(this.skipEditSecOnly().toString())
          .fontSize(18).fontColor(T.SELECTED)
          .margin({ left: 8, right: 8 })
        this.StepBtn(5, '+5')
      }
      .width('100%')

      Row() {
        Blank()
        Text('取消')
          .fontSize(14)
          .fontColor(this.hi('skcancel') ? T.SELECTED : T.PANEL_SUB)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .borderRadius(T.RADIUS_PILL)
          .backgroundColor(this.hi('skcancel') ? T.PANEL_BTN_HI : '#00000000')
          .onHover((hv: boolean) => this.hoverTo('skcancel', hv))
          .onClick(() => this.tap('skcancel', () => {
            this.skipEditKind = '';
          }))
          .onMouse(this.ptr('skcancel', () => {
            this.skipEditKind = '';
          }))
        Text('确定')
          .fontSize(14)
          .fontColor(this.hi('skok') ? T.SELECTED : T.PANEL_TXT)
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .borderRadius(T.RADIUS_PILL)
          .backgroundColor(this.hi('skok') ? T.PANEL_BTN_HI : T.WHITE_15)
          .border({ width: T.BORDER, color: this.hi('skok') ? T.SELECTED : '#00000000' })
          .margin({ left: 8 })
          .onHover((hv: boolean) => this.hoverTo('skok', hv))
          .onClick(() => this.tap('skok', () => this.applySkipEdit()))
          .onMouse(this.ptr('skok', () => this.applySkipEdit()))
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .margin({ top: 8 })
  }

  /** Apple TV 式播放中浮现的「跳过片头 / 下一集」胶囊按钮：右下角 + 倒计时环 */
  @Builder
  SkipFloatBtn() {
    Column() {
      Row() {
        Blank()
        Row() {
          // 倒计时环：底环半透明 + 进度环白色，随倒计时逐渐消失
          Stack() {
            Circle({ width: 26, height: 26 })
              .fill('#00000000')
              .stroke('#55FFFFFF')
              .strokeWidth(2.5)
            Circle({ width: 26, height: 26 })
              .fill('#00000000')
              .stroke('#FFFFFF')
              .strokeWidth(2.5)
              .strokeLineCap(LineCapStyle.Round)
              .strokeDashArray([2 * Math.PI * 13])
              .strokeDashOffset(2 * Math.PI * 13 * (1 - this.skipRingProgress()))
              .rotate({ angle: -90 })
          }
          .width(26)
          .height(26)
          .margin({ right: 14 })

          Text(this.skipShow === 'intro' ? '跳过片头' : (Playlist.hasNext() ? '下一集' : '跳过片尾'))
            .fontSize(18)
            .fontColor('#FFFFFF')
        }
        .padding({ left: 20, right: 26, top: 12, bottom: 12 })
        .backgroundColor('#CC181818')
        .borderRadius(40)
        .border({ width: 1.5, color: this.hi('skipfloat') ? '#FFFFFFFF' : '#88FFFFFF' })
        .shadow({ radius: 18, color: '#80000000' })
        .animation({ duration: T.ANIM, curve: Curve.EaseOut })
        .onHover((hv: boolean) => this.hoverTo('skipfloat', hv))
        .onClick(() => this.tap('skipfloat', () => this.doSkip(this.skipShow)))
        .onMouse(this.ptr('skipfloat', () => this.doSkip(this.skipShow)))
        .margin({ right: 48, bottom: 96 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  QPanel() {
    Stack() {
      // 点空白处关闭
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(T.BLACK_50)
        .onClick(() => this.tap('qmask', () => {
          this.showQ = false;
        }))
        .onMouse(this.ptr('qmask', () => {
          this.showQ = false;
        }))

      Column() {
        Row() {
          Text('播放设置').fontSize(21).fontColor(T.PANEL_TXT)
          Text(this.qLabel.length > 0 ? ('  当前 ' + this.qLabel) : '')
            .fontSize(15).fontColor(T.PANEL_DIM)
          Blank()
          Text('关闭')
            .fontSize(15)
            .fontColor(this.hi('qclose') ? T.SELECTED : T.PANEL_SUB)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(T.RADIUS_SM)
            .backgroundColor(this.hi('qclose') ? T.PANEL_BTN_HI : '#00000000')
            .border({ width: T.BORDER, color: this.hi('qclose') ? T.PANEL_TXT : '#00000000' })
            .animation({ duration: T.ANIM, curve: Curve.EaseOut })
            .onHover((hv: boolean) => this.hoverTo('qclose', hv))
            .onClick(() => this.tap('qclose', () => {
              this.showQ = false;
            }))
            .onMouse(this.ptr('qclose', () => {
              this.showQ = false;
            }))
        }
        .width('100%')
        .margin({ bottom: 14 })

        // 面板内容要能滚：档位 + 画面比例 + 倍速 + 字幕 + 跳片头片尾叠起来
        // 会超出手机竖屏高度，不滚的话最下面的「跳过片尾」直接被裁掉
        Scroll() {
          Column() {
        if (this.levels.length > 1) {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            this.QChip(0, '自动（按网速）')
            ForEach(this.levels, (lv: QLevel, i: number) => {
              this.QLvChip(i)
            }, (lv: QLevel, i: number) => 'lv_' + i + '_' + lv.url)
            this.QChip(Quality.TOP, '原画')
          }
          .width('100%')

          Text(this.netTxt.length > 0
            ? ('实测网速 ' + this.netTxt + '，共 ' + this.levels.length + ' 档可切。选「自动」后播放器会按网速升降档。')
            : ('源提供 ' + this.levels.length + ' 档清晰度。选「自动」后先起播再按网速调整。'))
            .fontSize(14).fontColor(T.PANEL_DIM).width('100%').margin({ top: 12 }).lineHeight(22)
        } else {
          Text(this.levels.length === 1
            ? ('当前 ' + Quality.labelOfLevel(this.levels[0]) +
              '，源只提供了这一档清晰度，切不了。\n网络差时播放器会自动加大缓冲，卡住会自动重连。')
            : '这个片源没有提供多档清晰度，切不了。\n网络差时播放器会自动加大缓冲，卡住会自动重连。')
            .fontSize(15).fontColor(T.PANEL_SUB).width('100%').lineHeight(24)
        }

        // 画面显示模式：不依赖源是否多码率，直播/点播都可用，
        // 解决直播常见的「4:3 画面被拉宽变形」或「四周黑边」问题。
        // 手机竖屏默认「等比适应」；电视端默认「拉伸铺满」。
        Row() {
          Text('画面比例')
            .fontSize(14).fontColor(T.PANEL_DIM)
          this.ScopeTag('全局')
        }
        .width('100%')
        .margin({ top: 16 })
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          this.ScaleChip(2, '等比适应（留黑边）')
          this.ScaleChip(1, '裁剪铺满')
          this.ScaleChip(0, '拉伸铺满')
        }
        .width('100%')
        .margin({ top: 6 })

        // 倍速：按**当前这部片**保存（点播改了不影响其他剧/电影）
        Row() {
          Text('倍速')
            .fontSize(14).fontColor(T.PANEL_DIM)
          this.ScopeTag('仅本片')
          Text(this.speed === 1 ? '正常' : (this.speed + ' 倍'))
            .fontSize(13).fontColor(this.speed === 1 ? T.PANEL_DIM : T.SELECTED)
            .margin({ left: 10 })
        }
        .width('100%')
        .margin({ top: 16 })
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(SPEEDS, (s: number) => {
            this.SpeedChip(s)
          }, (s: number) => 'spd_' + s)
        }
        .width('100%')
        .margin({ top: 6 })

        // 字幕：只有源里确实带字幕轨时才列出可选项
        Row() {
          Text('字幕')
            .fontSize(14).fontColor(T.PANEL_DIM)
          Text(this.subs.length === 0
            ? '这个源没有字幕轨'
            : (this.subSel < 0 ? '已关闭' : this.subs[this.subSel].label))
            .fontSize(13)
            .fontColor(this.subs.length > 0 && this.subSel >= 0 ? T.SELECTED : T.PANEL_DIM)
            .margin({ left: 10 })
        }
        .width('100%')
        .margin({ top: 16 })
        if (this.subs.length > 0) {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            this.SubChip(-1, '关闭')
            ForEach(this.subs, (t: SubTrack, i: number) => {
              this.SubChip(i, t.label)
            }, (t: SubTrack, i: number) => 'sub_' + i + '_' + t.index)
          }
          .width('100%')
          .margin({ top: 6 })
        }

        // 跳过片头片尾：起播自动跳片头，播到片尾自动切下一集（或结束）
        Row() {
          Text('跳过片头')
            .fontSize(14).fontColor(T.PANEL_DIM)
          this.ScopeTag('仅本片')
          if (this.introSkipSec > 0) {
            Text('当前 ' + this.fmtSec(this.introSkipSec))
              .fontSize(13).fontColor(T.SELECTED)
              .margin({ left: 10 })
          }
        }
        .width('100%')
        .margin({ top: 16 })
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          this.SkipChip('intro', 0)
          this.SkipChip('intro', 15)
          this.SkipChip('intro', 30)
          this.SkipChip('intro', 60)
          this.SkipChip('intro', 90)
          this.SkipActionChip('intro', 'custom', '自定义')
          this.SkipActionChip('intro', 'mark', '标当前')
        }
        .width('100%')
        .margin({ top: 6 })

        if (this.skipEditKind === 'intro') {
          this.SkipEditBar('intro')
        }

        Row() {
          Text('跳过片尾')
            .fontSize(14).fontColor(T.PANEL_DIM)
          this.ScopeTag('仅本片')
          if (this.outroSkipSec > 0) {
            Text('当前 ' + this.fmtSec(this.outroSkipSec))
              .fontSize(13).fontColor(T.SELECTED)
              .margin({ left: 10 })
          }
        }
        .width('100%')
        .margin({ top: 14 })
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          this.SkipChip('outro', 0)
          this.SkipChip('outro', 15)
          this.SkipChip('outro', 30)
          this.SkipChip('outro', 60)
          this.SkipChip('outro', 90)
          this.SkipActionChip('outro', 'custom', '自定义')
          this.SkipActionChip('outro', 'mark', '标当前')
        }
        .width('100%')
        .margin({ top: 6 })

        if (this.skipEditKind === 'outro') {
          this.SkipEditBar('outro')
        }

        // 操作说明：手势是隐藏功能，不写出来用户只能靠试。
        // 放在面板最底部（要滚一下才看到），不占常用项的位置。
        Divider()
          .color('#1FFFFFFF')
          .margin({ top: 18, bottom: 12 })
        Text(this.isLive ? '操作提示（直播）' : '操作提示')
          .fontSize(13).fontColor(T.PANEL_DIM)
          .width('100%')
        Text(this.handTipText())
          .fontSize(12)
          .fontColor(T.PANEL_DIM)
          .lineHeight(19)
          .width('100%')
          .margin({ top: 6 })
      }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .scrollBar(BarState.Off)
        .constraintSize({ maxHeight: Device.isPhone() ? 470 : 580 })
      }
      .width(Device.panelW(700))
      .padding(24)
      .backgroundColor(T.PANEL_SURFACE)
      .borderRadius(20)
      .alignItems(HorizontalAlign.Start)
      .shadow({ radius: 40, color: T.BLACK_80 })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      XComponent({
        id: 'videoSurface',
        type: XComponentType.SURFACE,
        controller: this.xController
      })
        .width('100%')
        .height('100%')
        .focusable(false)
        .onLoad(() => {
          this.surfaceId = this.xController.getXComponentSurfaceId();
          if (this.player !== null) {
            // 已有播放器却又收到 onLoad：说明 surface 被系统重建过（切后台回来、
            // 窗口尺寸变化）。旧 AVPlayer 还绑着那个已销毁的 surface，症状是
            // 「有声音、没画面、点哪都没用」。必须放掉重建。
            hilog.info(0x1000, 'BOXN', 'surface rebuilt, reopen player');
            if (!this.isLive && this.posMs > 0) {
              this.pendingSeek = this.posMs;
            }
            this.releasePlayer();
            // releasePlayer 已发 EV_RESET，UI 回到「加载中」，这里不必再手动置 buffering
          }
          this.initPlayer();
        })
        .onDestroy(() => {
          // surface 销毁后旧 id 不可用。不在这里清掉的话，下一次 onLoad 拿到的
          // 新 id 和缓存里的旧值只差在「有没有被清过」，判断会失真；
          // 而且 initPlayer 有 surfaceId 非空的前置检查，留着旧值等于允许它
          // 去绑一个已经不存在的 surface。
          this.surfaceId = '';
        })

      // 加载 / 缓冲 / 错误三种浮层交给 common/PlayerHud（#140 拆分的第一个模块）。
      // 约定「状态进、回调出」：组件只管画，不碰 AVPlayer，也不再耦合页面里的十几个字段。
      PlayerHud({
        isLive: this.isLive,
        errMsg: this.errMsg,
        netTxt: this.netTxt,
        multiLevel: this.levels.length > 1,
        autoQuality: this.qCap === 0,
        resolving: this.resolving,
        buffering: this.buffering,
        prepared: this.prepared,
        retryHi: this.hi('rt'),
        backHi: this.hi('bk'),
        onRetry: () => {
          this.retry();
        },
        onBack: () => {
          this.onBackPress();
        },
        onHoverRetry: (on: boolean) => this.hoverTo('rt', on),
        onHoverBack: (on: boolean) => this.hoverTo('bk', on)
      })

      // 播放/暂停中央图标：全屏居中，不拦截点击
      if (this.playFlash.length > 0 && this.seekPreview < 0) {
        Column() {
          Column() {
            Text(this.playFlash === 'play' ? '▶' : '❚❚')
              .fontSize(56)
              .fontColor('#FFFFFF')
          }
          .width(140)
          .height(140)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(T.BLACK_70)
          .borderRadius(70)
          .border({ width: T.BORDER, color: T.WHITE_30 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 快进快退浮层：全屏容器居中，且不拦截点击
      if (this.seekPreview >= 0) {
        Column() {
          Column() {
            Text(this.seekTip).fontSize(24).fontColor('#FFFFFF')
            Text(this.fmt(this.seekPreview) + '  /  ' + this.fmt(this.durMs))
              .fontSize(36).fontWeight(FontWeight.Bold).fontColor(T.SELECTED)
              .margin({ top: 8 })
          }
          .padding({ left: 48, right: 48, top: 22, bottom: 22 })
          .backgroundColor(T.BLACK_70)
          .borderRadius(16)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 音量条：全屏容器贴右上
      if (this.showVol) {
        Column() {
          Column() {
            Row() {
              Text(this.muted ? '静音' : '音量').fontSize(18).fontColor(T.PANEL_SUB).width(48).margin({ right: 8 })
              Text(this.volPct()).fontSize(20).fontColor('#FFFFFF').width(64)
            }
            Stack({ alignContent: Alignment.Start }) {
              Row() {}
              .width('100%').height(8).backgroundColor(T.WHITE_30).borderRadius(4)
              Row() {}
              .width(((this.muted ? 0 : this.volume) * 100) + '%')
              .height(8).backgroundColor(this.muted ? T.PANEL_DIM : T.PANEL_TXT).borderRadius(4)
            }
            .width(210).height(8).margin({ top: 10 })
          }
          .padding({ left: 22, right: 22, top: 16, bottom: 18 })
          .backgroundColor(T.BLACK_70)
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.End)
        .padding({ top: 44, right: 48 })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 换集/到头提示：全屏容器贴顶部居中
      if (this.showToast) {
        Column() {
          Text(this.toast)
            .fontSize(22).fontColor('#FFFFFF')
            .padding({ left: 30, right: 30, top: 14, bottom: 14 })
            .backgroundColor(T.BLACK_70)
            .borderRadius(12)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 60 })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 底部控制面板：FongMi 的 shape_controller —— colorSurface + 上左/上右 28dp 圆角，padding 24/24/16
      if (this.showOsd && !this.resolving) {
        Column() {
          Column() {
            Row() {
              Text(this.title)
                .fontSize(20).fontColor(T.PANEL_TXT)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (this.epLabel.length > 0) {
                Text(this.epLabel).fontSize(16).fontColor(T.PANEL_SUB)
              }
            }
            .width('100%')

            if (this.hint.length > 0) {
              Text(this.hint).fontSize(15).fontColor(T.SELECTED).margin({ top: 6 }).width('100%')
            }

            // 直播没有「总进度」，位置换成 LIVE 标记 + 换台提示
            if (this.isLive) {
              Row() {
                Row() {
                  Row() {}
                  .width(8).height(8).backgroundColor(T.LIVE).borderRadius(4)
                  Text('直播').fontSize(15).fontColor(T.PANEL_TXT).margin({ left: 8 })
                }
                Blank()
                Text('左右键换台 · 上下键音量').fontSize(14).fontColor(T.PANEL_DIM)
              }
              .width('100%')
              .height(28)
              .margin({ top: 10 })
            } else {
            // 进度（进度条本身可点击定位，指针模式下很有用）
            Row() {
              Text(this.fmt(this.displayMs())).fontSize(16).fontColor(T.PANEL_SUB).width(96)
              Row() {
                Stack({ alignContent: Alignment.Start }) {
                  Row() {}
                  .width('100%').height(6).backgroundColor(T.WHITE_30).borderRadius(3)
                  Row() {}
                  .width((this.durMs > 0 ? (this.displayMs() / this.durMs * 100) : 0) + '%')
                  .height(6)
                  // FongMi 的 seek 进度就是 colorPrimary（白），拖动预览时用 yellow_500
                  .backgroundColor(this.seekPreview >= 0 ? T.SELECTED : T.PANEL_TXT)
                  .borderRadius(3)
                }
                .width('100%')
                .height(6)
              }
              .layoutWeight(1)
              .height(28)
              .alignItems(VerticalAlign.Center)
              .onAreaChange((oldV: Area, newV: Area) => {
                const w = newV.width;
                this.barW = typeof w === 'number' ? w : parseFloat(w.toString());
              })
              .onMouse((e: MouseEvent) => {
                if (this.durMs <= 0 || this.barW <= 0) {
                  return;
                }
                let r: number = e.x / this.barW;
                r = r < 0 ? 0 : (r > 1 ? 1 : r);
                // 指针滑过进度条时把右侧总时长换成对应时间点，先看准了再点
                if (e.action === MouseAction.Move) {
                  this.hoverMs = r * this.durMs;
                  return;
                }
                // 灵犀遥控器在指针模式下点进度条不一定派发 onClick
                // （焦点先被悬停抢走），这里补一条 Release → seek
                if (e.action === MouseAction.Release) {
                  this.hoverMs = -1;
                  this.seekToRatio(r);
                }
              })
              .onHover((hv: boolean) => {
                if (!hv) {
                  this.hoverMs = -1;
                }
              })
              .onClick((ev: ClickEvent) => {
                Feedback.tap();
                if (this.barW > 0) {
                  this.seekToRatio(ev.x / this.barW);
                }
              })
              // 按住拖动定位：位移按条宽换算，预览走 seekPreview（黄色高亮 + 中央大字浮层）
              .gesture(
                PanGesture({ direction: PanDirection.Horizontal, distance: 3 })
                  .onActionStart((e: GestureEvent) => {
                    if (this.durMs <= 0 || this.barW <= 0) {
                      return;
                    }
                    this.dragSeeking = true;
                    // 起点取「手指按下的位置」，不是「当前播放位置」。
                    // 以前用 displayMs()/durMs 当基准，于是「在 80% 处按下、拖到 85%」
                    // 实际只从当前位置往前走了 5%，手指和进度完全对不上。
                    let base: number = this.displayMs() / this.durMs;
                    const fingers = e.fingerList;
                    if (fingers !== undefined && fingers.length > 0) {
                      let fr: number = fingers[0].localX / this.barW;
                      fr = fr < 0 ? 0 : (fr > 1 ? 1 : fr);
                      base = fr;
                    }
                    this.dragBaseRatio = base;
                    // 按下即预览到按点，拖动时位置跟手
                    this.seekPreview = Math.floor(base * this.durMs);
                    this.seekTip = '拖动定位';
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    if (!this.dragSeeking || this.durMs <= 0 || this.barW <= 0) {
                      return;
                    }
                    let r: number = this.dragBaseRatio + e.offsetX / this.barW;
                    r = r < 0 ? 0 : (r > 1 ? 1 : r);
                    this.seekPreview = Math.floor(r * this.durMs);
                    this.popOsd();
                  })
                  .onActionEnd((e: GestureEvent) => {
                    if (!this.dragSeeking) {
                      return;
                    }
                    this.dragSeeking = false;
                    // 落点用「起点比例 + 总位移」算，和拖动过程中预览用的是同一套公式，
                    // 所以松手后定位与预览严格一致，不会出现「拖到 85% 却落回 30%」。
                    // 只有当拿不到位移（offsetX 异常）时，才退回 seekPreview。
                    let endMs: number = this.seekPreview;
                    if (this.barW > 0 && this.durMs > 0) {
                      let r: number = this.dragBaseRatio + e.offsetX / this.barW;
                      r = r < 0 ? 0 : (r > 1 ? 1 : r);
                      endMs = Math.floor(r * this.durMs);
                    }
                    if (endMs >= 0 && this.durMs > 0) {
                      const shown: string = this.fmt(endMs);
                      // 复用点击定位的同一条路径，保证拖动与点击落到同一时刻
                      this.seekToRatio(endMs / this.durMs);
                      Tip.show('已定位到 ' + shown);
                    }
                    this.seekPreview = -1;
                  })
                  .onActionCancel(() => {
                    // 手势被上层容器抢走时，别把预览留在屏幕上
                    this.dragSeeking = false;
                    this.seekPreview = -1;
                  })
              )
              Text(this.hoverMs >= 0 ? this.fmt(this.hoverMs) : this.fmt(this.durMs))
                .fontSize(16)
                .fontColor(this.hoverMs >= 0 ? T.SELECTED : T.PANEL_SUB)
                .width(96)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .margin({ top: 10 })
            }

            // 控制按钮：遥控器是「指针 + 确定」模式时全靠这里操作
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              if (this.isLive) {
                this.CtlBtn(0)
                this.CtlBtn(2)
                this.CtlBtn(4)
                this.CtlBtn(5)
                this.CtlBtn(6)
                this.CtlBtn(7)
                this.CtlBtn(8)
              } else {
                this.CtlBtn(0)
                this.CtlBtn(1)
                this.CtlBtn(2)
                this.CtlBtn(3)
                this.CtlBtn(4)
                this.CtlBtn(5)
                this.CtlBtn(6)
                this.CtlBtn(7)
                this.CtlBtn(8)
              }
            }
            .width('100%')
            .margin({ top: 12 })

            Row() {
              Text(this.isLive ? '频道地址直连播放，不经过解析' : ('解析：' + this.via))
                .fontSize(14).fontColor(T.PANEL_DIM)
              if (this.netTxt.length > 0) {
                Text('· 网速 ' + this.netTxt).fontSize(14).fontColor(T.PANEL_DIM).margin({ left: 10 })
              }
              Text(this.isLive ? '点画面唤出控制条 · 左右键或按钮换台' : '点画面唤出控制条 · 再点画面播放/暂停 · 进度条可点可拖')
                .fontSize(14).fontColor(T.PANEL_DIM).margin({ left: 24 })
            }
            .width('100%')
            .margin({ top: 8 })
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 24, bottom: 16 })
          .backgroundColor(T.PANEL_SURFACE)
          .borderRadius({ topLeft: T.RADIUS_PILL, topRight: T.RADIUS_PILL })
          // 指针停在控制条上就别自动收：遥控器要把指针从画面中间挪到
          // 底部按钮上，8 秒经常不够，条子一走用户得重新点一次
          .onHover((hv: boolean) => {
            if (hv) {
              if (this.osdTimer >= 0) {
                clearTimeout(this.osdTimer);
                this.osdTimer = -1;
              }
            } else {
              this.popOsd();
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseInOut }))
      }

      // 画质浮层必须在 OSD 之外：跟着 OSD 一起长会把面板顶出屏幕
      if (this.showQ) {
        this.QPanel()
      }

      // Apple TV 式跳过按钮：独立于 OSD，播放中浮现（OSD 收起时最上层）
      if (this.skipShow !== '') {
        this.SkipFloatBtn()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .id('playerRoot')
    // 记下实际宽度，给「左半屏调亮度 / 右半屏调音量」用（见纵向手势处）
    .onAreaChange((oldV: Area, newV: Area) => {
      const w = newV.width;
      this.winW = typeof w === 'number' ? w : parseFloat(w.toString());
    })
    .focusable(true)
    .defaultFocus(true)
    .onFocus(() => {
      hilog.info(0x1000, 'BOXN', 'root FOCUS');
    })
    .onBlur(() => {
      hilog.info(0x1000, 'BOXN', 'root BLUR');
      // 焦点丢了就把按键通道也丢了，200ms 后抢回来
      setTimeout(() => {
        this.grabFocus();
      }, 200);
    })
    .onClick(() => {
      Feedback.tap();
      // 遥控器「确定」在电视上常常以 click 派发给焦点组件，这里接住
      this.onCenter();
    })
    .onMouse((e: MouseEvent) => {
      // 灵犀遥控器指针一动就把控制条唤出来，否则用户不知道该点哪。
      // Press 也要唤：只点不移动时不产生 Move。
      if ((e.action === MouseAction.Move || e.action === MouseAction.Press) && !this.showOsd) {
        hilog.info(0x1000, 'BOXN', 'pointer wake');
        this.popOsd();
      }
    })
    // 手势交互：左右滑快进快退、上下滑调音量/亮度
    .gesture(
      PanGesture({ direction: PanDirection.All, distance: 10 })
        .onActionStart((e: GestureEvent) => {
          // 进度条正在被拖动时，禁止其它手势
          if (this.dragSeeking) {
            return;
          }
          // 记录手势起始 X，用于后续判断左/右半屏
          this.panStartX = e.fingerList.length > 0 ? e.fingerList[0].localX : 0;
        })
        .onActionUpdate((e: GestureEvent) => {
          if (this.dragSeeking || this.durMs <= 0) {
            return;
          }
          const absX = Math.abs(e.offsetX);
          const absY = Math.abs(e.offsetY);
          
          // 横向手势：快进快退
          if (absX > absY && absX > 20) {
            const deltaMs = (e.offsetX > 0 ? 1 : -1) * SEEK_STEP;
            let target = this.displayMs() + deltaMs;
            target = target < 0 ? 0 : (target > this.durMs ? this.durMs : target);
            this.seekPreview = target;
            this.seekTip = (deltaMs > 0 ? '+' : '') + (deltaMs / 1000) + 's';
            this.popOsd();
            return;
          }
          
          // 纵向手势：左半屏调亮度，右半屏调音量（仅手机）
          if (absY > absX && absY > 20 && this.isPhone) {
            // 以前这里写死 `panStartX < 200`，注释却说「左半屏」——
            // 手机横屏宽 1320vp，200 只占最左 15%，于是中间到右边缘 85%
            // 的区域全在调音量，用户几乎调不了亮度。
            // 现在按实际窗口宽度取中点；拿不到宽度时退回 200 保守处理。
            const halfW: number = this.winW > 0 ? this.winW / 2 : 200;
            const isLeftHalf: boolean = this.panStartX < halfW;
            if (isLeftHalf) {
              // 左半屏：调亮度
              const bDelta: number = e.offsetY > 0 ? -0.05 : 0.05;
              let bri: number = this.brightnessVal + bDelta;
              bri = bri < 0.05 ? 0.05 : (bri > 1.0 ? 1.0 : bri);
              this.brightnessVal = bri;
              this.showBrightness = true;
              this.popOsd();
              // 调节系统窗口亮度（不支持时静默忽略）
              try {
                window.getLastWindow(getContext(this), (_err: Object, win: window.Window) => {
                  win.setWindowBrightness(bri).catch(() => {});
                });
              } catch (_e) {
                // 不支持时忽略
              }
              if (this.brightTimer >= 0) {
                clearTimeout(this.brightTimer);
              }
              this.brightTimer = setTimeout(() => {
                this.showBrightness = false;
                this.brightTimer = -1;
              }, 2000) as number;
            } else {
              // 右半屏：调音量
              const deltaVol: number = e.offsetY > 0 ? -VOL_STEP : VOL_STEP;
              let vol: number = this.volume + deltaVol;
              vol = vol < 0 ? 0 : (vol > 1 ? 1 : vol);
              this.volume = vol;
              this.showVol = true;
              this.popOsd();
              if (this.volTimer >= 0) {
                clearTimeout(this.volTimer);
              }
              this.volTimer = setTimeout(() => {
                this.showVol = false;
              }, 2000) as number;
            }
          }
        })
        .onActionEnd(() => {
          // 松手时确认 seek（如果在预览中）
          if (this.seekPreview >= 0 && this.durMs > 0) {
            this.seekToRatio(this.seekPreview / this.durMs);
            Tip.show(this.fmt(this.seekPreview));
            this.seekPreview = -1;
          }
        })
        .onActionCancel(() => {
          this.seekPreview = -1;
        })
    )
    .onKeyEvent((e: KeyEvent) => {
      this.onKey(e);
    })
    // 播放页不加 backgroundColor(T.BG)：底色必须是黑的（视频画面 + 控制面板叠在上面），
    // 这里只把主题名挂到 id 上，保证切主题后 OSD 文案会重绘
    .id('player_' + this.themeMode)
  }
}
