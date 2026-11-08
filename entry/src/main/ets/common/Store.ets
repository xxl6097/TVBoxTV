import dataPreferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { RawConfig, RawSite, RawParse, RawLive, Site, ParseRule, Vod, WebdavSource, WebdavVod, WdHistory } from './Model';
import { Http } from './Http';
import { Cms } from './Cms';

const STORE: string = 'boxtv_store_v1';

export class HistItem {
  siteKey: string = '';
  siteName: string = '';
  vodId: string = '';
  name: string = '';
  pic: string = '';
  epName: string = '';
  epIndex: number = 0;
  from: string = '';
  /** 已看到第几毫秒 */
  pos: number = 0;
  /**
   * 这一集的总时长（毫秒），0 表示未知。
   *
   * 首页「继续观看」要画 tvOS 那种观看进度条，必须知道百分比；
   * 只存 pos 画不出来。老记录没有这个字段，读出来是 undefined，
   * 统一按 0 处理，此时卡片不画进度条（而不是画一条 0% 的空条）。
   */
  dur: number = 0;
  time: number = 0;
}

export class FavItem {
  siteKey: string = '';
  siteName: string = '';
  vodId: string = '';
  name: string = '';
  pic: string = '';
}

/** loadSubscription 的返回：订阅名 + 点播站点数 + 直播源数 */
export class SubResult {
  name: string = '';
  sites: number = 0;
  lives: number = 0;
}

/** 配置与本地数据（preferences） */
export class Store {
  private static prefs: dataPreferences.Preferences | null = null;
  private static ctx: common.UIAbilityContext | null = null;
  private static siteList: Site[] = [];
  private static parseList: ParseRule[] = [];
  private static rawSites: number = 0;

  static async init(ctx: common.UIAbilityContext): Promise<void> {
    Store.ctx = ctx;
    if (Store.prefs === null) {
      Store.prefs = await dataPreferences.getPreferences(ctx, STORE);
    }
  }

  /**
   * 用户是否自己填过配置地址（订阅 / 手动导入过就视为已自定义）。
   * 应用包内不再内置任何影视源，站源列表只来自用户主动订阅或导入。
   */
  static async isCustom(): Promise<boolean> {
    if (Store.prefs === null) {
      return false;
    }
    const v: string = await Store.prefs.get('cfgCustom', '0') as string;
    return v === '1';
  }

  // ---------- 配置 ----------

  static async getConfigUrl(): Promise<string> {
    if (Store.prefs === null) {
      return '';
    }
    return await Store.prefs.get('cfgUrl', '') as string;
  }

  /** 订阅源名字（设置页「订阅」右侧展示用），空串 = 未订阅 */
  static async subName(): Promise<string> {
    if (Store.prefs === null) {
      return '';
    }
    return await Store.prefs.get('subName', '') as string;
  }

  /**
   * 载入配置。source 可以是 URL，也可以是直接粘贴的 JSON 文本。
   * 成功后缓存原文，之后离线/源失效也能用上次的站源列表。
   */
  static async loadConfig(source: string): Promise<number> {
    let text: string = '';
    const src: string = source.trim();
    if (src.startsWith('http://') || src.startsWith('https://')) {
      text = await Http.text(src, undefined, 20000);
    } else if (src.length > 0) {
      text = src;
    } else {
      text = await Store.cachedText();
      if (text.length === 0) {
        throw new Error('还没有配置站源');
      }
    }

    const cleaned: string = Cms.cleanJson(text);
    let cfg: RawConfig;
    try {
      cfg = JSON.parse(cleaned) as RawConfig;
    } catch (err) {
      throw new Error('配置不是合法 JSON，请确认地址返回的是 TVBox 配置');
    }
    if (cfg.sites === undefined || cfg.sites.length === 0) {
      throw new Error('配置里没有 sites 列表');
    }

    Store.buildSites(cfg);
    Store.buildParses(cfg);
    // 站源可能整批换过（换订阅），把已启用集合同新列表对齐，
    // 否则旧 key 过滤新站源会得到空集，站源全部静默失效。
    await Store.alignEnabled();

    if (Store.prefs !== null) {
      await Store.prefs.put('cfgText', text);
      if (src.startsWith('http')) {
        await Store.prefs.put('cfgUrl', src);
        // 用户自己填的地址：标记住，之后订阅导入不会覆盖它
        await Store.prefs.put('cfgCustom', '1');
      }
      // 站源列表变了，重置抓取时钟，首页下次进入立刻抓一轮最新。
      await Store.prefs.put('crawlAt', 0);
      await Store.prefs.flush();
    }
    return Store.siteList.length;
  }

  /**
   * 订阅 = 一份 JSON 同时带点播站源（sites）与直播源（lives）。
   * 用户只填一个链接，点播和直播一起更新，替代原来「配置地址 + 直播源」两处分开填。
   */
  static async loadSubscription(source: string): Promise<SubResult> {
    let text: string = '';
    const src: string = source.trim();
    if (src.startsWith('http://') || src.startsWith('https://')) {
      text = await Http.text(src, undefined, 20000);
    } else if (src.length > 0) {
      text = src;
    } else {
      text = await Store.cachedText();
      if (text.length === 0) {
        throw new Error('还没有订阅地址');
      }
    }

    const cleaned: string = Cms.cleanJson(text);
    let cfg: RawConfig;
    try {
      cfg = JSON.parse(cleaned) as RawConfig;
    } catch (err) {
      throw new Error('订阅不是合法 JSON');
    }
    // 内容是字面量 null / 空对象时，下面任何一次 .length / .trim() 都会抛
    // "Cannot read properties of null"，用户看到的就是这行半英文报错
    if (cfg === null || cfg === undefined) {
      throw new Error('订阅内容为空（不是合法的 TVBox 配置）');
    }

    const r: SubResult = new SubResult();
    r.name = cfg.name !== undefined && cfg.name !== null ? cfg.name : '';

    // 点播站源
    if (cfg.sites !== undefined && cfg.sites !== null && cfg.sites.length > 0) {
      Store.buildSites(cfg);
      Store.buildParses(cfg);
      // 换订阅后站源 key 整批变化，先把已启用集合同新列表对齐，
      // 否则旧 key 命中不了新站源，等于订阅完一个站都没有。
      await Store.alignEnabled();
      r.sites = Store.siteList.length;
      if (Store.prefs !== null) {
        await Store.prefs.put('cfgText', text);
        if (src.startsWith('http')) {
          await Store.prefs.put('cfgUrl', src);
          await Store.prefs.put('cfgCustom', '1');
        }
        if (r.name.length > 0) {
          await Store.prefs.put('subName', r.name);
        }
        // 站源列表变了，重置抓取时钟：首页下次进入立刻抓一轮最新，
        // 而不是沿用旧的「上次更新时间」再等 6 小时。
        await Store.prefs.put('crawlAt', 0);
      }
    }

    // 直播源
    if (cfg.lives !== undefined && cfg.lives !== null && cfg.lives.length > 0) {
      const lives: RawLive[] = [];
      for (let i = 0; i < cfg.lives.length; i++) {
        const l: RawLive = cfg.lives[i];
        if (l === null || l === undefined) {
          continue;
        }
        const u: string = l.url !== undefined && l.url !== null ? l.url.trim() : '';
        if (u.startsWith('http://') || u.startsWith('https://')) {
          const nm: string = l.name !== undefined && l.name !== null ? l.name : ('直播源' + (i + 1));
          const n: RawLive = { name: nm, url: u };
          lives.push(n);
        }
      }
      await Store.setSubLives(lives);
      r.lives = lives.length;
      // 自动选一个默认直播源：当前没配源、或当前源已不在新订阅的列表里，
      // 就用订阅里的第一个，点「直播」就有画面。当前源还在列表里就保留不打断。
      if (lives.length > 0) {
        const cur: string = await Store.liveUrl();
        const firstUrl: string = lives[0].url !== undefined ? lives[0].url : '';
        let inList: boolean = false;
        for (let i = 0; i < lives.length; i++) {
          if (lives[i].url === cur) {
            inList = true;
            break;
          }
        }
        if (firstUrl.length > 0 && !inList) {
          await Store.setLiveUrl(firstUrl);
        }
      }
    }

    if (Store.prefs !== null) {
      await Store.prefs.flush();
    }
    if (r.sites === 0 && r.lives === 0) {
      throw new Error('订阅里既没有站点也没有直播源');
    }
    return r;
  }

  static async cachedText(): Promise<string> {
    if (Store.prefs === null) {
      return '';
    }
    return await Store.prefs.get('cfgText', '') as string;
  }

  /** 启动时用缓存恢复站点列表；没有缓存则返回 false */
  static async restore(): Promise<boolean> {
    const text: string = await Store.cachedText();
    if (text.length === 0) {
      return false;
    }
    try {
      const cfg: RawConfig = JSON.parse(Cms.cleanJson(text)) as RawConfig;
      if (cfg === null || cfg === undefined) {
        return false;
      }
      if (cfg.sites === undefined || cfg.sites === null || cfg.sites.length === 0) {
        return false;
      }
      Store.buildSites(cfg);
      Store.buildParses(cfg);
      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * 从外部订阅 JSON 里取字符串字段。
   *
   * 这是外部数据，字段可能是 null / 数字 / 对象。原来的写法
   * `r.key !== undefined && r.key.length > 0` 遇到 null 时前半句成立、
   * 后半句直接抛 "Cannot read properties of null (reading 'length')"，
   * 用户在设置页看到的就是这行半英文报错。
   */
  private static strOf(v: string | null | undefined, fallback: string): string {
    if (v === undefined || v === null) {
      return fallback;
    }
    const s: string = v;
    return s.length > 0 ? s : fallback;
  }

  /** 取数字字段；null / 非数字一律给兜底值 */
  private static numOf(v: number | null | undefined, fallback: number): number {
    if (v === undefined || v === null) {
      return fallback;
    }
    const n: number = v;
    return isNaN(n) ? fallback : n;
  }

  private static buildSites(cfg: RawConfig): void {
    const out: Site[] = [];
    const raw: RawSite[] = cfg.sites as RawSite[];
    for (let i = 0; i < raw.length; i++) {
      const r = raw[i];
      // 配置里偶尔会出现 null 占位的空项，整个跳过
      if (r === undefined || r === null) {
        continue;
      }
      const s = new Site();
      s.key = Store.strOf(r.key, 'site_' + i);
      s.name = Store.strOf(r.name, '站源 ' + (i + 1));
      s.type = Store.numOf(r.type, 1);
      s.api = Store.strOf(r.api, '');
      s.searchable = Store.numOf(r.searchable, 1) === 1;
      s.quickSearch = Store.numOf(r.quickSearch, 0) === 1;
      // 订阅源的 ext 可能是 JSON 对象（如 hongtv.json v5 的 note/library/verified），
      // 而 TVBox 标准里 ext 是字符串。这里规范成字符串，否则 filtersOf 里的
      // ext.trim() 会因 ext 实际是 object 而抛 "undefined is not callable"。
      if (r.ext === undefined || r.ext === null) {
        s.ext = '';
      } else if (typeof r.ext === 'string') {
        s.ext = r.ext;
      } else {
        s.ext = JSON.stringify(r.ext as Object);
      }

      if (s.type === 3) {
        s.usable = false;
        s.reason = '需爬虫运行时（Java/JS），鸿蒙无法执行';
      } else if (s.type === 0 || s.type === 1 || s.type === 4) {
        if (s.api.startsWith('http://') || s.api.startsWith('https://')) {
          s.usable = true;
          s.reason = '';
        } else {
          s.usable = false;
          s.reason = '接口地址不是 HTTP';
        }
      } else {
        s.usable = false;
        s.reason = '暂不支持的类型 type=' + s.type;
      }
      out.push(s);
    }
    Store.rawSites = out.length;
    Store.siteList = out;
  }

  private static buildParses(cfg: RawConfig): void {
    const out: ParseRule[] = [];
      if (cfg.parses !== undefined && cfg.parses !== null) {
        const ps: RawParse[] = cfg.parses;
        for (let i = 0; i < ps.length; i++) {
          const p = ps[i];
          if (p === undefined || p === null) {
            continue;
          }
          const url: string = Store.strOf(p.url, '');
          // type 2 是「并发/轮询」占位符，真正的解析器是那些 type 1 的
          if (Store.numOf(p.type, 0) === 1 && url.startsWith('http')) {
            const r = new ParseRule();
            r.name = Store.strOf(p.name, '解析' + i);
            r.url = url;
            out.push(r);
          }
        }
      }
    Store.parseList = out;
  }

  static sites(): Site[] {
    return Store.siteList;
  }

  static usableSites(): Site[] {
    const out: Site[] = [];
    for (let i = 0; i < Store.siteList.length; i++) {
      if (Store.siteList[i].usable) {
        out.push(Store.siteList[i]);
      }
    }
    return out;
  }

  static site(key: string): Site | null {
    for (let i = 0; i < Store.siteList.length; i++) {
      if (Store.siteList[i].key === key) {
        return Store.siteList[i];
      }
    }
    return null;
  }

  static parses(): ParseRule[] {
    return Store.parseList;
  }

  static totalSites(): number {
    return Store.rawSites;
  }

  // ---------- 站点启用开关 ----------

  static async enabledKeys(): Promise<string[]> {
    if (Store.prefs === null) {
      return [];
    }
    const s: string = await Store.prefs.get('enabled', '') as string;
    if (s.length === 0) {
      return [];
    }
    try {
      return JSON.parse(s) as string[];
    } catch (err) {
      return [];
    }
  }

  static async setEnabledKeys(keys: string[]): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('enabled', JSON.stringify(keys));
    await Store.prefs.flush();
  }

  /**
   * 站源列表重建后，把「已启用」集合和新列表对齐。
   *
   * 为什么必须做：`enabled` 里存的是**旧配置**的站源 key。换了订阅之后 key 全变，
   * `activeSites()` 拿旧 key 去过滤新站源会命中 0 个 —— 表现为「订阅成功，但首页
   * 一直显示正在拉取、搜索永远 0 结果」，而恢复入口「全部启用」还藏在测速之后。
   *
   * 策略用**保留交集**而不是直接清空：同源订阅日常更新时（站源 key 不变）用户的
   * 开关选择不会丢；换了一整套配置时交集为空，写成空数组，`activeSites()` 会把
   * 空数组理解为「默认全部可用」，自动回到可用状态。
   */
  private static async alignEnabled(): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    const old: string[] = await Store.enabledKeys();
    if (old.length === 0) {
      return;      // 本来就是默认全开，不用动
    }
    const next: string[] = [];
    for (let i = 0; i < Store.siteList.length; i++) {
      const s: Site = Store.siteList[i];
      if (s.usable && old.indexOf(s.key) >= 0) {
        next.push(s.key);
      }
    }
    await Store.prefs.put('enabled', JSON.stringify(next));
  }

  /**
   * 保证站点列表已就绪。
   *
   * 应用包内不内置任何影视源，站源只来自用户订阅 / 手动导入后的本地缓存。
   * 无缓存时返回 false，页面据此显示「还没有站源，去订阅」的空态。
   * 子组件（VodView 等）的 aboutToAppear 可能比父页面异步初始化更早跑完，
   * 那时候 siteList 还是空的，会误报「没有站源」——这里做一次幂等兜底。
   */
  static async ensureLoaded(): Promise<boolean> {
    if (Store.siteList.length > 0) {
      return true;
    }
    return await Store.restore();
  }

  /** 默认只启用协议型站点，避免一屏全是不可用站源 */
  static async activeSites(): Promise<Site[]> {    const keys: string[] = await Store.enabledKeys();
    if (keys.length === 0) {
      const out: Site[] = [];
      for (let i = 0; i < Store.siteList.length; i++) {
        if (Store.siteList[i].usable) {
          out.push(Store.siteList[i]);
        }
      }
      return out;
    }
    const out: Site[] = [];
    for (let i = 0; i < Store.siteList.length; i++) {
      const s: Site = Store.siteList[i];
      if (s.usable && keys.indexOf(s.key) >= 0) {
        out.push(s);
      }
    }
    return out;
  }

  // ---------- 历史 ----------

  static async history(): Promise<HistItem[]> {
    if (Store.prefs === null) {
      return [];
    }
    const s: string = await Store.prefs.get('hist', '') as string;
    if (s.length === 0) {
      return [];
    }
    try {
      const arr: HistItem[] = JSON.parse(s) as HistItem[];
      // 按「最后观看时间」倒序。
      // updateHistoryPos 只改 time、不动数组位置，于是重看老片时会出现
      // 「刚刚」排在「12 小时前」下面，列表看起来是乱的。
      arr.sort((a: HistItem, b: HistItem): number => {
        const ta: number = a.time === undefined || a.time === null ? 0 : a.time;
        const tb: number = b.time === undefined || b.time === null ? 0 : b.time;
        return tb - ta;
      });
      return arr;
    } catch (err) {
      return [];
    }
  }

  static async pushHistory(h: HistItem): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    const list: HistItem[] = await Store.history();
    const out: HistItem[] = [];
    out.push(h);
    for (let i = 0; i < list.length; i++) {
      const k: string = list[i].siteKey + '|' + list[i].vodId;
      if (k !== h.siteKey + '|' + h.vodId) {
        out.push(list[i]);
      }
      if (out.length >= 40) {
        break;
      }
    }
    await Store.prefs.put('hist', JSON.stringify(out));
    await Store.prefs.flush();
  }

  /** 更新某条记录的播放进度（同一个 siteKey+vodId 只保留一条） */
  static async updateHistoryPos(h: HistItem): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    const list: HistItem[] = await Store.history();
    let found: boolean = false;
    const out: HistItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const it: HistItem = list[i];
      if (it.siteKey === h.siteKey && it.vodId === h.vodId) {
        it.pos = h.pos;
        it.dur = h.dur;
        it.epName = h.epName;
        it.epIndex = h.epIndex;
        it.from = h.from;
        it.time = Date.now();
        out.push(it);
        found = true;
      } else {
        out.push(it);
      }
    }
    if (!found) {
      out.unshift(h);
    }
    await Store.prefs.put('hist', JSON.stringify(out));
    await Store.prefs.flush();
  }

  /** 删除单条历史记录（按 siteKey+vodId 匹配，同一部只留一条，因此唯一） */
  static async removeHistory(h: HistItem): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    const list: HistItem[] = await Store.history();
    const out: HistItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const it: HistItem = list[i];
      if (!(it.siteKey === h.siteKey && it.vodId === h.vodId)) {
        out.push(it);
      }
    }
    await Store.prefs.put('hist', JSON.stringify(out));
    await Store.prefs.flush();
  }

  static async clearHistory(): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('hist', '[]');
    await Store.prefs.flush();
  }

  // ---------- 收藏 ----------

  static async favorites(): Promise<FavItem[]> {
    if (Store.prefs === null) {
      return [];
    }
    const s: string = await Store.prefs.get('fav', '') as string;
    if (s.length === 0) {
      return [];
    }
    try {
      return JSON.parse(s) as FavItem[];
    } catch (err) {
      return [];
    }
  }

  static async isFavorite(siteKey: string, vodId: string): Promise<boolean> {
    const list: FavItem[] = await Store.favorites();
    for (let i = 0; i < list.length; i++) {
      if (list[i].siteKey === siteKey && list[i].vodId === vodId) {
        return true;
      }
    }
    return false;
  }

  static async toggleFavorite(f: FavItem): Promise<boolean> {
    if (Store.prefs === null) {
      return false;
    }
    const list: FavItem[] = await Store.favorites();
    const out: FavItem[] = [];
    let removed: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].siteKey === f.siteKey && list[i].vodId === f.vodId) {
        removed = true;
      } else {
        out.push(list[i]);
      }
    }
    if (!removed) {
      out.unshift(f);
    }
    await Store.prefs.put('fav', JSON.stringify(out));
    await Store.prefs.flush();
    return !removed;
  }

  /**
   * 只删不加。
   *
   * 收藏页的「删除」不能复用 toggleFavorite：那边是翻转语义，
   * 一旦列表已经过期（比如在别的设备/别的页面刚取消过），
   * 翻转会把这条**加回去**，界面却提示「已取消收藏」。
   * 返回是否真的删掉了，调用方据此给正确提示。
   */
  static async removeFavorite(f: FavItem): Promise<boolean> {
    if (Store.prefs === null) {
      return false;
    }
    const list: FavItem[] = await Store.favorites();
    const out: FavItem[] = [];
    let hit: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].siteKey === f.siteKey && list[i].vodId === f.vodId) {
        hit = true;
      } else {
        out.push(list[i]);
      }
    }
    if (!hit) {
      return false;
    }
    await Store.prefs.put('fav', JSON.stringify(out));
    await Store.prefs.flush();
    return true;
  }

  // ---------- 搜索历史 ----------

  /** 最多留几条。电视上用指针输入关键词很费劲，历史点一下就能重搜 */
  private static KW_MAX: number = 8;

  static async keywords(): Promise<string[]> {
    if (Store.prefs === null) {
      return [];
    }
    const raw: string = await Store.prefs.get('kwHist', '') as string;
    if (raw.length === 0) {
      return [];
    }
    const out: string[] = [];
    const parts: string[] = raw.split('\n');
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i].trim();
      if (p.length > 0) {
        out.push(p);
      }
    }
    return out;
  }

  /** 记一条关键词：去重、最近用的排最前 */
  static async pushKeyword(kw: string): Promise<string[]> {
    const k: string = kw.trim();
    if (Store.prefs === null || k.length === 0) {
      return Store.keywords();
    }
    const old: string[] = await Store.keywords();
    const out: string[] = [k];
    for (let i = 0; i < old.length; i++) {
      if (old[i] !== k && out.length < Store.KW_MAX) {
        out.push(old[i]);
      }
    }
    await Store.prefs.put('kwHist', out.join('\n'));
    await Store.prefs.flush();
    return out;
  }

  static async clearKeywords(): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('kwHist', '');
    await Store.prefs.flush();
  }

  // ---------- 直播源 ----------

  static async liveUrl(): Promise<string> {
    if (Store.prefs === null) {
      return '';
    }
    return await Store.prefs.get('liveUrl', '') as string;
  }

  static async setLiveUrl(u: string): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('liveUrl', u);
    await Store.prefs.flush();
  }

  /** 订阅文档下发的直播源列表（多个候选，设置页可逐个测速切换） */
  static async subLives(): Promise<RawLive[]> {
    if (Store.prefs === null) {
      return [];
    }
    const s: string = await Store.prefs.get('subLives', '') as string;
    if (s.length === 0) {
      return [];
    }
    try {
      return JSON.parse(s) as RawLive[];
    } catch (err) {
      return [];
    }
  }

  static async setSubLives(list: RawLive[]): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('subLives', JSON.stringify(list));
    await Store.prefs.flush();
  }

  // ---------- 画质偏好 ----------

  /**
   * 上一次看片选过的清晰度。
   * 0 = 自动（按网速），>0 = 高度上限（1080/720/480），9999 = 原画（不设限）。
   * 记成全局而不是逐片，是因为用户对画质的偏好通常跟片无关，只跟网络有关。
   */
  static async qPref(): Promise<number> {
    if (Store.prefs === null) {
      return 0;
    }
    return await Store.prefs.get('qPref', 0) as number;
  }

  static async setQPref(v: number): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('qPref', v);
    await Store.prefs.flush();
  }

  /**
   * 播放倍速。1 = 正常速度。
   *
   * 做成全局偏好而不是每集记一次：追剧的人一般整部都看 1.25/1.5 倍，
   * 每集都要重设一次很烦。数值直接存倍率（0.5/0.75/1.25/1.5/2），
   * 不用枚举下标 —— 以后加档位不会把老配置错位。
   */
  static async speedPref(): Promise<number> {
    if (Store.prefs === null) {
      return 1;
    }
    const v: number = await Store.prefs.get('speed', 1) as number;
    return v > 0 ? v : 1;
  }

  static async setSpeedPref(v: number): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('speed', v);
    await Store.prefs.flush();
  }

  /** 片头跳过秒数，0 = 不跳过 */
  static async introSkipSec(): Promise<number> {
    if (Store.prefs === null) {
      return 0;
    }
    return await Store.prefs.get('introSkip', 0) as number;
  }

  static async setIntroSkipSec(v: number): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('introSkip', v);
    await Store.prefs.flush();
  }

  /** 片尾跳过秒数，0 = 不跳过 */
  static async outroSkipSec(): Promise<number> {
    if (Store.prefs === null) {
      return 0;
    }
    return await Store.prefs.get('outroSkip', 0) as number;
  }

  static async setOutroSkipSec(v: number): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('outroSkip', v);
    await Store.prefs.flush();
  }

  /** 点击反馈：声音开关，1 = 开（默认），0 = 关 */
  static async tapSound(): Promise<number> {
    if (Store.prefs === null) {
      return 1;
    }
    return await Store.prefs.get('tapSound', 1) as number;
  }

  static async setTapSound(v: number): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('tapSound', v);
    await Store.prefs.flush();
  }

  /** 点击反馈：震动开关，1 = 开（默认），0 = 关 */
  static async tapVibrate(): Promise<number> {
    if (Store.prefs === null) {
      return 1;
    }
    return await Store.prefs.get('tapVibrate', 1) as number;
  }

  static async setTapVibrate(v: number): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('tapVibrate', v);
    await Store.prefs.flush();
  }

  // ---------- 定时抓取 ----------

  /** 首页「最近更新」的数据（上一轮抓取结果） */
  static async feed(): Promise<Vod[]> {
    if (Store.prefs === null) {
      return [];
    }
    const s: string = await Store.prefs.get('feed', '') as string;
    if (s.length === 0) {
      return [];
    }
    try {
      return JSON.parse(s) as Vod[];
    } catch (err) {
      return [];
    }
  }

  static async saveFeed(list: Vod[]): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('feed', JSON.stringify(list));
    await Store.prefs.flush();
  }

  static async lastCrawlAt(): Promise<number> {
    if (Store.prefs === null) {
      return 0;
    }
    return await Store.prefs.get('crawlAt', 0) as number;
  }

  static async setLastCrawlAt(t: number): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('crawlAt', t);
    await Store.prefs.flush();
  }

  /** 上一轮结果摘要，设置页展示用 */
  static async crawlSummary(): Promise<string> {
    if (Store.prefs === null) {
      return '';
    }
    return await Store.prefs.get('crawlSummary', '') as string;
  }

  static async saveCrawlSummary(s: string): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('crawlSummary', s);
    await Store.prefs.flush();
  }

  /** 上一轮探测失败的站源 key，首页可以据此提示 */
  static async deadKeys(): Promise<string[]> {
    if (Store.prefs === null) {
      return [];
    }
    const s: string = await Store.prefs.get('deadKeys', '') as string;
    if (s.length === 0) {
      return [];
    }
    try {
      return JSON.parse(s) as string[];
    } catch (err) {
      return [];
    }
  }

  static async saveDeadKeys(keys: string[]): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('deadKeys', JSON.stringify(keys));
    await Store.prefs.flush();
  }

  // ---------- 首启同意与引导 ----------

  /**
   * 隐私政策是否已同意。
   *
   * 应用市场（含华为）要求首次启动必须先展示隐私政策、用户点「同意」后才允许
   * 联网与收集任何信息。所以这个标记必须在做任何网络请求之前读到，读不到就当作
   * 未同意——宁可多弹一次，也不能在未同意状态下先联网。
   */
  static async privacyAgreed(): Promise<boolean> {
    if (Store.prefs === null) {
      return false;
    }
    return await Store.prefs.get('privacyAgreed', false) as boolean;
  }

  static async setPrivacyAgreed(): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('privacyAgreed', true);
    await Store.prefs.flush();
  }

  /** 首启引导是否已看过。和隐私同意分开记：同意是必须的，引导只是提示 */
  static async guideDone(): Promise<boolean> {
    if (Store.prefs === null) {
      return false;
    }
    return await Store.prefs.get('guideDone', false) as boolean;
  }

  static async setGuideDone(): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('guideDone', true);
    await Store.prefs.flush();
  }

  /** 直连播放用过的地址，方便回看（只存本机） */
  static async directList(): Promise<string[]> {
    if (Store.prefs === null) {
      return [];
    }
    const s: string = await Store.prefs.get('directList', '') as string;
    if (s.length === 0) {
      return [];
    }
    try {
      return JSON.parse(s) as string[];
    } catch (err) {
      return [];
    }
  }

  static async pushDirect(url: string): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    const old: string[] = await Store.directList();
    const out: string[] = [url];
    for (let i = 0; i < old.length && out.length < 12; i++) {
      if (old[i] !== url) {
        out.push(old[i]);
      }
    }
    await Store.prefs.put('directList', JSON.stringify(out));
    await Store.prefs.flush();
  }

  // ---------- WebDAV 网盘 ----------

  static async webdavSources(): Promise<WebdavSource[]> {
    if (Store.prefs === null) {
      return [];
    }
    const s: string = await Store.prefs.get('webdavList', '') as string;
    if (s.length === 0) {
      return [];
    }
    try {
      return JSON.parse(s) as WebdavSource[];
    } catch (err) {
      return [];
    }
  }

  /** 新增或按 id 覆盖保存一个 WebDAV 源 */
  static async saveWebdavSource(src: WebdavSource): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    if (src.id.length === 0) {
      src.id = 'wd_' + Date.now();
    }
    const list: WebdavSource[] = await Store.webdavSources();
    const out: WebdavSource[] = [];
    let replaced: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === src.id) {
        out.push(src);
        replaced = true;
      } else {
        out.push(list[i]);
      }
    }
    if (!replaced) {
      out.unshift(src);
    }
    await Store.prefs.put('webdavList', JSON.stringify(out));
    await Store.prefs.flush();
  }

  static async removeWebdavSource(id: string): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    const list: WebdavSource[] = await Store.webdavSources();
    const out: WebdavSource[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].id !== id) {
        out.push(list[i]);
      }
    }
    await Store.prefs.put('webdavList', JSON.stringify(out));
    // 源删了，识别缓存一并清掉，避免残留
    await Store.removeWebdavScan(id);
    await Store.prefs.flush();
  }

  // ---------- WebDAV 识别结果缓存 ----------

  /**
   * 某个源最近一次识别出的影视列表（缓存）。
   * key 按源 id 区分：`webdavScan_<srcId>`。
   */
  static async webdavScanCache(srcId: string): Promise<WebdavVod[]> {
    if (Store.prefs === null) {
      return [];
    }
    const s: string = await Store.prefs.get('webdavScan_' + srcId, '') as string;
    if (s.length === 0) {
      return [];
    }
    try {
      return JSON.parse(s) as WebdavVod[];
    } catch (err) {
      return [];
    }
  }

  static async saveWebdavScan(srcId: string, vods: WebdavVod[]): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('webdavScan_' + srcId, JSON.stringify(vods));
    await Store.prefs.flush();
  }

  static async removeWebdavScan(srcId: string): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('webdavScan_' + srcId, '');
    await Store.prefs.flush();
  }

  // ---------- WebDAV 播放续播记录 ----------

  /** 网盘播放记录。读取时按 time 倒序（最近看的在前） */
  static async wdHistory(): Promise<WdHistory[]> {
    if (Store.prefs === null) {
      return [];
    }
    const s: string = await Store.prefs.get('wdHist', '') as string;
    if (s.length === 0) {
      return [];
    }
    try {
      const list: WdHistory[] = JSON.parse(s) as WdHistory[];
      list.sort((a: WdHistory, b: WdHistory) => b.time - a.time);
      return list;
    } catch (err) {
      return [];
    }
  }

  /**
   * 更新一条网盘播放记录。按 srcId+vodName 去重（同一部只留一条），
   * 播到哪集、看到第几分钟都覆盖最新值。
   */
  static async updateWdHistory(h: WdHistory): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    const list: WdHistory[] = await Store.wdHistory();
    const out: WdHistory[] = [];
    let found: boolean = false;
    for (let i = 0; i < list.length; i++) {
      const it: WdHistory = list[i];
      if (it.srcId === h.srcId && it.vodName === h.vodName) {
        it.srcName = h.srcName;
        it.dir = h.dir;
        it.epIndex = h.epIndex;
        it.epName = h.epName;
        it.url = h.url;
        it.pos = h.pos;
        it.dur = h.dur;
        it.time = h.time;
        out.push(it);
        found = true;
      } else {
        out.push(it);
      }
    }
    if (!found) {
      out.unshift(h);
    }
    await Store.prefs.put('wdHist', JSON.stringify(out));
    await Store.prefs.flush();
  }

  static async removeWdHistory(h: WdHistory): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    const list: WdHistory[] = await Store.wdHistory();
    const out: WdHistory[] = [];
    for (let i = 0; i < list.length; i++) {
      const it: WdHistory = list[i];
      if (!(it.srcId === h.srcId && it.vodName === h.vodName)) {
        out.push(it);
      }
    }
    await Store.prefs.put('wdHist', JSON.stringify(out));
    await Store.prefs.flush();
  }

  static async clearWdHistory(): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('wdHist', '[]');
    await Store.prefs.flush();
  }

  // ---------- 播放器全局偏好 ----------

  /** 画面显示模式偏好：0=拉伸 / 1=裁剪 / 2=等比适应 */
  static async scaleModePref(): Promise<number> {
    if (Store.prefs === null) {
      return 0;
    }
    const v: string = await Store.prefs.get('playerScaleMode', '0') as string;
    return parseInt(v);
  }

  static async setScaleModePref(mode: number): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('playerScaleMode', mode.toString());
    await Store.prefs.flush();
  }

  /** 画质档位偏好：0=自动 / >0=指定档位 / 9999=原画 */
  static async qualityPref(): Promise<number> {
    if (Store.prefs === null) {
      return 0;
    }
    const v: string = await Store.prefs.get('playerQuality', '0') as string;
    return parseInt(v);
  }

  static async setQualityPref(qLvl: number): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('playerQuality', qLvl.toString());
    await Store.prefs.flush();
  }

  /** 倍速偏好：0.5 / 1.0 / 1.5 / 2.0 等 */
  static async speedPref(): Promise<number> {
    if (Store.prefs === null) {
      return 1.0;
    }
    const v: string = await Store.prefs.get('playerSpeed', '1.0') as string;
    return parseFloat(v);
  }

  static async setSpeedPref(speed: number): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('playerSpeed', speed.toString());
    await Store.prefs.flush();
  }

  /** 音量偏好：0-15（AVPlayer 的标准范围） */
  static async volumePref(): Promise<number> {
    if (Store.prefs === null) {
      return 10; // 默认中等音量
    }
    const v: string = await Store.prefs.get('playerVolume', '10') as string;
    return parseInt(v);
  }

  static async setVolumePref(vol: number): Promise<void> {
    if (Store.prefs === null) {
      return;
    }
    await Store.prefs.put('playerVolume', vol.toString());
    await Store.prefs.flush();
  }
}
