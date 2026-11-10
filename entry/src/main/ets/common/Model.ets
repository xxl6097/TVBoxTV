/**
 * 夜帧影视 —— 数据模型
 *
 * 两套类型：
 *  - Raw*  : 直接对应 TVBox 配置 JSON 里的字段，只用于 JSON.parse 后承接
 *  - 其余  : 应用内部模型，用 class 保证字段有默认值（ArkTS 不允许裸对象字面量）
 */

// ============ TVBox 配置 JSON 原始结构 ============

export interface RawSite {
  key?: string;
  name?: string;
  type?: number;
  api?: string;
  searchable?: number;
  quickSearch?: number;
  filterable?: number;
  ext?: string;
  jar?: string;
}

export interface RawParse {
  name?: string;
  type?: number;
  url?: string;
  ext?: RawParseExt;
}

export interface RawParseExt {
  flag?: string[];
}

/**
 * 订阅文档里的一个直播源条目。
 * 订阅 = 一份 JSON 同时带点播站源（sites）与直播源（lives），
 * 用户只填一个链接，点播和直播一起更新。
 */
export interface RawLive {
  name?: string;
  url?: string;
}

export interface RawConfig {
  sites?: RawSite[];
  parses?: RawParse[];
  lives?: RawLive[];
  /** 订阅源的名字，展示用（设置页「订阅」右侧显示） */
  name?: string;
  /** 订阅源更新时间，展示用 */
  updated?: string;
  spider?: string;
  flags?: string[];
  ads?: string[];
}

// ============ 接口返回 JSON 结构（已把 "class" 预处理成 catList） ============

export interface JVod {
  vod_id?: number;
  vod_name?: string;
  vod_pic?: string;
  vod_remarks?: string;
  vod_year?: string;
  vod_area?: string;
  vod_actor?: string;
  vod_director?: string;
  vod_content?: string;
  vod_blurb?: string;
  vod_play_from?: string;
  vod_play_url?: string;
  vod_time?: string;
  type_name?: string;
  /** 分类 id：苹果 CMS 的 JSON 接口给 type_id，XML/部分站给 tid，两个名字都得认 */
  tid?: number;
  type_id?: number;
}

export interface JClass {
  type_id?: number;
  type_pid?: number;
  type_name?: string;
}

export interface JResp {
  code?: number;
  msg?: string;
  page?: number;
  pagecount?: number;
  total?: number;
  limit?: number;
  list?: JVod[];
  catList?: JClass[];
  data?: JResp;
}

// ============ 应用模型 ============

/** 站源。usable=false 表示该站点需要爬虫运行时（csp_/jar），鸿蒙无法执行 */
export class Site {
  key: string = '';
  name: string = '';
  type: number = 1;
  api: string = '';
  searchable: boolean = true;
  quickSearch: boolean = false;
  /** 站点的 ext 原文。里面的 filters 就是分类页的筛选条件来源 */
  ext: string = '';
  usable: boolean = false;
  reason: string = '';
  enabled: boolean = false;
}

export class Category {
  id: string = '';
  name: string = '';
  /**
   * 父分类 id，空串表示顶级。
   *
   * 采集站普遍是「两级分类」：`电视剧` 下面是 `欧美剧/韩剧/日剧…`，而且
   * **父分类往往没有直属影片**（t=1 返回空列表）。知道父子关系，才能在父分类
   * 为空时自动汇总子分类，而不是甩一句「这个分类下没有内容」。
   */
  pid: string = '';
}

export class Vod {
  id: string = '';
  name: string = '';
  pic: string = '';
  remark: string = '';
  year: string = '';
  area: string = '';
  actor: string = '';
  director: string = '';
  content: string = '';
  typeName: string = '';
  /** 分类 id（详情接口里的 type_id），「相关推荐」按它拉同分类影片 */
  typeId: string = '';
  from: string = '';
  playUrl: string = '';
  siteKey: string = '';
  siteName: string = '';
}

export class Episode {
  name: string = '';
  url: string = '';
  /** 直播专用：同一频道的备用线路 */
  urls: string[] = [];
}

export class Line {
  name: string = '';
  /** 这条线路的地址是否大多能直接喂播放器（.m3u8/.mp4），false 表示是网页需二次解析 */
  direct: boolean = false;
  eps: Episode[] = [];
}

export class VodPage {
  items: Vod[] = [];
  page: number = 1;
  pageCount: number = 1;
  total: number = 0;
}

/** 播放源解析规则（parses 里 type=1 的那些） */
export class ParseRule {
  name: string = '';
  url: string = '';
}

// ============ 页面传参 ============

export class SiteParam {
  key: string = '';
  name: string = '';
}

export class DetailParam {
  siteKey: string = '';
  siteName: string = '';
  vodId: string = '';
}

export class PlayParam {
  url: string = '';
  title: string = '';
  siteKey: string = '';
  vodId: string = '';
  from: string = '';
  epIndex: number = 0;
  /** 播放请求要带的额外 header（如 WebDAV 的 Basic Auth） */
  header: Record<string, string> = {};
  /** 初始续播位置（毫秒），>0 时起播后自动 seek 到该处 */
  seek: number = 0;
  /** WebDAV 续播：源 id（落盘 + 取认证 header 用） */
  wdSrcId: string = '';
  /** WebDAV 续播：源名（展示用） */
  wdSrcName: string = '';
  /** WebDAV 续播：片名（去重键 + 展示用） */
  wdVod: string = '';
  /** WebDAV 续播：所在目录 */
  wdDir: string = '';
  /** WebDAV 续播：是否剧集（多集）。true 时续播记录按「第 N 集」落盘 */
  wdSeries: boolean = false;
}

// ============ 筛选（对应 TVBox ext 里的 filters） ============

export class FilterValue {
  n: string = '';
  v: string = '';
}

export class FilterGroup {
  key: string = '';
  name: string = '';
  values: FilterValue[] = [];
}

// ============ 直播 ============

export class Channel {
  name: string = '';
  url: string = '';
  logo: string = '';
  group: string = '';
  /** 同一个台的全部线路（含 url 本身）。直播源里 CCTV1 常出现三四条，播挂了要能换线 */
  urls: string[] = [];
}

export class ChannelGroup {
  name: string = '';
  channels: Channel[] = [];
}

/**
 * 直播目录节点。
 *
 * 直播源本身只有一层分组（m3u 的 group-title / txt 的 #genre#），
 * 几百个台平铺在一条列表里很难找，这里把它扩成三级：
 *   一级 —— 大类（央视 / 卫视 / 体育 …）
 *   二级 —— 源里的分组名
 *   三级 —— 源自带的子分组（「地方台/北京」），没有就按清晰度拆（4K / 高清 / 标准）
 *
 * 每个节点既可以有直属频道，也可以有子节点；UI 取频道时往下递归全收。
 */
export class LiveDir {
  name: string = '';
  /** 含子节点在内的频道总数，buildTree 结束时算好，列表上直接显示 */
  count: number = 0;
  children: LiveDir[] = [];
  channels: Channel[] = [];
}

// ============ WebDAV 网盘挂载 ============

/** 一个 WebDAV 挂载源（存本机 preferences） */
export class WebdavSource {
  id: string = '';
  name: string = '';
  /** 服务器地址，如 http://192.168.1.10:5244/dav 或 https://dav.example.com/dav */
  url: string = '';
  user: string = '';
  pass: string = '';
  /** 挂载根路径，如 /影视；空串 = 从根开始浏览 */
  root: string = '';
}

/** WebDAV 目录项（PROPFIND 解析出的一个 response） */
export class WebdavEntry {
  /** 相对 href（已 URL 解码），如 /影视/电影/xx.mkv */
  href: string = '';
  name: string = '';
  isDir: boolean = false;
  size: number = 0;
  mtime: string = '';
}

/** 识别出的一部影视 */
export class WebdavVod {
  name: string = '';
  /** movie = 电影 / series = 剧集 */
  kind: string = 'movie';
  year: string = '';
  /** 所在目录（展示用） */
  dir: string = '';
  /** 剧集列表（电影只有 1 条） */
  eps: WebdavEp[] = [];
}

export class WebdavEp {
  name: string = '';
  /** 完整可播放 URL（不带认证，认证 header 由播放层加） */
  url: string = '';
  /** 相对 href */
  href: string = '';
  /** 季号，0 表示无 */
  season: number = 0;
  /** 集号 */
  episode: number = 0;
}

/**
 * WebDAV 播放续播记录（存本机 preferences）。
 *
 * 自包含：存了该集的完整播放 URL + 进度，下次无需重新扫描识别，
 * 直接拿 url + 源 id（取认证 header）就能续播。
 */
export class WdHistory {
  /** 源 id，用于找回 WebdavSource 取认证 header */
  srcId: string = '';
  srcName: string = '';
  vodName: string = '';
  dir: string = '';
  epIndex: number = 0;
  epName: string = '';
  /** 该集完整播放 URL（认证 header 播放时另加） */
  url: string = '';
  /** 已看到第几毫秒 */
  pos: number = 0;
  /** 该集总时长（毫秒），0 表示未知 */
  dur: number = 0;
  time: number = 0;
}

// ============ 界面常量 ============

export class T {
  /**
   * 取值全部来自 FongMi/TV 的 leanback 变体资源，不做主观调整：
   *   app/src/main/res/values/colors.xml        —— 基础色板 + splash_background
   *   app/src/leanback/res/values/styles.xml    —— Theme.Base（colorPrimary = white）
   *   app/src/leanback/res/color/text.xml       —— 选中/聚焦文字 = yellow_500
   *   app/src/leanback/res/drawable/shape_*.xml —— 圆角、描边、底色
   */
  static BG: string = '#141218';

  /**
   * 按主题取页面底色。
   *
   * 为什么不直接写 `T.BG`：`T` 是普通静态对象，`Theme` 改它的字段**不会**
   * 触发任何刷新；ArkUI 只在 build 读到状态变量时才重绘。把主题名当参数传进来，
   * 调用处就自然读到了 `@StorageProp themeMode`，换主题时整页才会重建。
   * 参数本身不参与计算（真值在 T.BG 上，Theme 已经改好了）。
   */
  static pageBg(mode: string): string {
    return T.BG;
  }
  /** Theme.Material3.Dark 的 colorSurface（播放器控制面板 shape_controller 用的就是它） */
  static SURFACE: string = '#1C1B1F';

  // ---- 基础色板（values/colors.xml 原值，半透明直接交给系统混合）----
  static BLACK_20: string = '#33000000';
  static BLACK_40: string = '#66000000';
  static BLACK_50: string = '#80000000';
  static BLACK_70: string = '#B3000000';
  static BLACK_80: string = '#CC000000';
  static BLACK_90: string = '#E6000000';
  static WHITE_15: string = '#26FFFFFF';
  static WHITE_30: string = '#4DFFFFFF';
  static WHITE_70: string = '#B3FFFFFF';
  static WHITE_80: string = '#CCFFFFFF';

  /** Theme.Base 的 colorPrimary 就是纯白，不是 M3 默认紫 */
  static PRIMARY: string = '#FFFFFF';
  /** color/text.xml：state_selected / state_checked 一律 yellow_500 */
  static SELECTED: string = '#FFEB3B';

  /** 卡片/功能块常态底 = black_20（shape_item_normal / shape_chip 系列） */
  static CARD: string = '#33000000';
  /** 焦点态底 = black_40（shape_item_focused） */
  static CARD_HI: string = '#66000000';
  /** 主强调色 = colorPrimary = white */
  static ACCENT: string = '#FFFFFF';
  /** 选中态补充底色，用于需要压暗的已选按钮 */
  static ACCENT_DIM: string = '#4DFFFFFF';
  static TXT: string = '#FFFFFF';
  /** white_70 / white_50，对应 FongMi 的次级文字 */
  static SUB: string = '#B3FFFFFF';
  static DIM: string = '#80FFFFFF';
  /**
   * 「这个台连不上」的频道文字色。深色底上是白 35%，
   * 浅色主题下必须反过来（由 Theme 覆盖），所以单独给个字段，别在页面里写死。
   */
  static DEAD: string = '#5AFFFFFF';
  static WARN: string = '#FFB4AB';
  static ERR: string = '#FFB4AB';
  /** 直播标记点。取 FongMi values/colors.xml 的 red_500 */
  static LIVE: string = '#F44336';

  // ---- 播放器面板专用色（**不随主题变化**）----
  /**
   * 控制条、按钮、进度条都叠在视频画面上，只能按「恒深色」设计：
   * 浅色主题里那套深灰字 + 近透明黑底压到画面上，会随画面亮度忽隐忽现。
   * 所以这几个值写死在这里，Theme 不会覆盖它们。
   */
  static PANEL_TXT: string = '#FFFFFF';
  static PANEL_SUB: string = '#B3FFFFFF';
  static PANEL_DIM: string = '#80FFFFFF';
  static PANEL_BTN: string = '#26FFFFFF';
  static PANEL_BTN_HI: string = '#4DFFFFFF';
  /** 控制条/设置面板的底：恒为深灰，不跟主题 */
  static PANEL_SURFACE: string = '#1C1B1F';

  // ---- 交互动效 ----
  /** hover / 选中态过渡时长（ms） */
  static ANIM: number = 140;
  /** FongMi 的 shape_vod_focused：1.5dp 白色描边。取整到 2 避免亚像素虚边 */
  static BORDER: number = 2;
  /** 卡片圆角：Vod.Grid / Vod.Grid.Large 都是 8dp */
  static RADIUS: number = 8;
  /** 功能块圆角：shape_item_* 是 4dp */
  static RADIUS_SM: number = 4;
  /** 胶囊圆角：shape_chip_round_* = 28dp */
  static RADIUS_PILL: number = 28;
  /** Leanback FocusHighlight.ZOOM_FACTOR_SMALL = 1.1f（ListRow 默认缩放） */
  static HOVER_SCALE: number = 1.1;
}
