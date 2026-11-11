/**
 * 直播 EPG（XMLTV 节目单）。
 *
 * 为什么自己解析而不是引 XML 解析器：
 *  1. XMLTV 结构极其固定（`<tv>` 下就 `<channel>` 与 `<programme>` 两类节点），
 *     用两个正则扫一遍就够，省掉一层 DOM/SAX 依赖；
 *  2. `@ohos.xml` 的 XmlPullParser 是流式的，但这里拿到的是整串文本，
 *     走正则反而少一次字符串到流的转换；
 *  3. 节目单是「能显示就行」的数据，某一条解析失败不该影响整份。
 *
 * 体量控制：真实 XMLTV 常有 20~80 MB，直接全文正则会明显卡主线程。
 * 这里硬性截断到 MAX_CHARS，并对 programme 条数设上限——宁可少显示几个台的
 * 节目，也不能让进直播页卡住。截断后按文件顺序解析，通常是「先央视后台名」，
 * 对用户常看的前几十个台足够。
 *
 * 台名匹配：直播源（m3u/txt）里没有 tvg-id，只有台名，所以只能按名字对。
 * 归一化去掉清晰度后缀与标点后先精确匹配，再退到「包含」匹配，
 * 这样 `CCTV5体育` 能对上 `CCTV5+体育赛事`，而 `CCTV1` 不会误配到 `CCTV10`。
 */

import { Http } from './Http';
import { Store } from './Store';
import hilog from '@ohos.hilog';

/** 一条节目 */
export class EpgProg {
  name: string = '';
  /** 开始时间（ms 时间戳） */
  start: number = 0;
  /** 结束时间（ms 时间戳） */
  stop: number = 0;
}

/** XMLTV 里的一个频道 */
class EpgCh {
  id: string = '';
  names: string[] = [];
}

export class Epg {
  /** 缓存有效期：6 小时。节目单本身按天更新，没必要每次进直播页都拉 */
  static readonly TTL: number = 6 * 3600 * 1000;
  /** 最多解析这么多字符（约 6 MB），超出部分直接丢弃 */
  private static readonly MAX_CHARS: number = 6 * 1024 * 1024;
  /** 单份节目单最多收这么多条，防止超大文件把内存吃满 */
  private static readonly MAX_PROGS: number = 30000;

  private static chs: EpgCh[] = [];
  /** channelId → 该台的节目（按开始时间升序） */
  private static progs: Map<string, EpgProg[]> = new Map();
  /** 归一化台名 → channelId */
  private static nameIdx: Map<string, string> = new Map();
  private static loadedAt: number = 0;
  private static busy: boolean = false;
  private static lastErr: string = '';
  /** 台名 → channelId 的解析缓存（空串表示确认对不上，也要缓存，避免反复扫） */
  private static resCache: Map<string, string> = new Map();

  /** 是否已有可用节目单 */
  static loaded(): boolean {
    return Epg.chs.length > 0;
  }

  /**
   * 当前缓存是否还新鲜（未过期且没跨天）。
   * 页面用它判断「要不要重拉」—— 与 ensure() 内部的判断保持一致，
   * 避免出现 ensure 认为要重拉、调用方却以为不用的情况。
   */
  static fresh(): boolean {
    return Epg.chs.length > 0 && Date.now() - Epg.loadedAt < Epg.TTL
      && Epg.sameDay(Epg.loadedAt, Date.now());
  }

  /** 已解析的频道数（设置页用来显示状态） */
  static count(): number {
    return Epg.chs.length;
  }

  /** 上次失败原因，空串表示没失败过 */
  static error(): string {
    return Epg.lastErr;
  }

  /** 节目单是什么时候拉下来的，用来看「数据新不新」 */
  static loadedAtText(): string {
    if (Epg.loadedAt === 0) {
      return '';
    }
    const d: Date = new Date(Epg.loadedAt);
    const now: Date = new Date();
    const sameDay: boolean = d.getFullYear() === now.getFullYear()
      && d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
    return (sameDay ? '今天 ' : '昨天 ') + Epg.hhmm(Epg.loadedAt);
  }

  /** 一批台名里有多少能对上节目单（设置页/节目单标题用来给匹配率） */
  static matched(names: string[]): number {
    let n: number = 0;
    for (let i = 0; i < names.length; i++) {
      if (Epg.resolve(names[i]).length > 0) {
        n++;
      }
    }
    return n;
  }

  /**
   * 归一化台名。
   *
   * 直播源里同一台有多种写法：`CCTV-1`、`CCTV1 高清`、`CCTV1综合`、`cctv1`。
   * XMLTV 的 display-name 又是另一套写法。两边都过一遍这个函数再比。
   */
  static norm(s: string): string {
    let t: string = s.toLowerCase();
    t = t.replace(/\s+/g, '');
    // 括号里的补充说明（「（港澳）」「(4K)」）对不上就别参与比较
    t = t.replace(/[（(][^）)]*[）)]/g, '');
    t = t.replace(/(高清|超清|标清|蓝光|原画|测试|备用|主源|副源|4k|8k|uhd|fhd|hd)/g, '');
    t = t.replace(/[\-_·.,，、:：|/+]/g, '');
    return t;
  }

  /** 清空缓存（设置页换 EPG 地址后调用） */
  static reset(): void {
    Epg.chs = [];
    Epg.progs = new Map();
    Epg.nameIdx = new Map();
    Epg.resCache = new Map();
    Epg.loadedAt = 0;
    Epg.lastErr = '';
  }

  /**
   * 确保有节目单可用：有缓存且未过期就直接返回，否则拉一次。
   * 返回解析到的频道数（0 表示没配置或拉取失败）。
   */
  static async ensure(force: boolean): Promise<number> {
    if (!force && Epg.fresh()) {
      return Epg.chs.length;
    }
    if (Epg.busy) {
      return Epg.chs.length;
    }
    const url: string = await Store.epgUrl();
    if (url.length === 0) {
      return 0;
    }
    Epg.busy = true;
    try {
      const raw: string = await Http.text(url, undefined, 30000);
      if (raw.length === 0) {
        Epg.lastErr = '节目单地址返回了空内容';
        return Epg.chs.length;
      }
      const xml: string = raw.length > Epg.MAX_CHARS ? raw.substring(0, Epg.MAX_CHARS) : raw;
      Epg.parse(xml);
      Epg.loadedAt = Date.now();
      Epg.lastErr = '';
      hilog.info(0x1000, 'BOXN', 'epg parsed ch=%{public}d truncated=%{public}s',
        Epg.chs.length, '' + (raw.length > Epg.MAX_CHARS));
      return Epg.chs.length;
    } catch (err) {
      const e = err as Error;
      Epg.lastErr = e.message;
      hilog.error(0x1000, 'BOXN', 'epg load fail: %{public}s', e.message);
      return Epg.chs.length;
    } finally {
      Epg.busy = false;
    }
  }

  /** 某台当前正在播的节目；没有就返回 null */
  static now(chName: string): EpgProg | null {
    const id: string = Epg.resolve(chName);
    if (id.length === 0) {
      return null;
    }
    const list: EpgProg[] | undefined = Epg.progs.get(id);
    if (list === undefined || list.length === 0) {
      return null;
    }
    const t: number = Date.now();
    for (let i = 0; i < list.length; i++) {
      if (t >= list[i].start && t < list[i].stop) {
        return list[i];
      }
    }
    return null;
  }

  /** 某台今天的节目单（从当前时间起算，最多 12 条） */
  static today(chName: string): EpgProg[] {
    const id: string = Epg.resolve(chName);
    if (id.length === 0) {
      return [];
    }
    const list: EpgProg[] | undefined = Epg.progs.get(id);
    if (list === undefined) {
      return [];
    }
    const t: number = Date.now();
    const out: EpgProg[] = [];
    for (let i = 0; i < list.length && out.length < 12; i++) {
      // 正在播的和还没播的都算「接下来」
      if (list[i].stop > t) {
        out.push(list[i]);
      }
    }
    return out;
  }

  /** 当前节目的文案：`新闻30分 12:00-12:30`；没节目返回空串 */
  static nowText(chName: string): string {
    const p: EpgProg | null = Epg.now(chName);
    if (p === null) {
      return '';
    }
    return p.name + ' ' + Epg.hhmm(p.start) + '-' + Epg.hhmm(p.stop);
  }

  /** 时间戳 → HH:MM */
  static hhmm(ms: number): string {
    const d: Date = new Date(ms);
    const h: number = d.getHours();
    const m: number = d.getMinutes();
    return (h < 10 ? '0' + h : '' + h) + ':' + (m < 10 ? '0' + m : '' + m);
  }

  /**
   * 两个时间戳是否同一天（本地时区）。
   *
   * 为什么单靠 TTL 不够：节目单是按「天」组织的数据。晚上 22:00 拉一份，
   * 到凌晨 2:00 只过了 4 小时、TTL 还没到，但缓存里全是昨天的节目 ——
   * 结果是频道格子第二行集体消失（now() 找不到正在播的）、
   * 节目单面板把昨天剩下的节目当成「接下来」。所以跨天必须作废。
   */
  private static sameDay(a: number, b: number): boolean {
    const x: Date = new Date(a);
    const y: Date = new Date(b);
    return x.getFullYear() === y.getFullYear() && x.getMonth() === y.getMonth()
      && x.getDate() === y.getDate();
  }

  // ==================== 匹配 ====================

  /** 台名 → channelId。先精确，再「包含」兜底 */
  private static resolve(chName: string): string {
    // 结果缓存：直播页每个频道格子每次重绘都会问一次，没命中时那次「包含匹配」
    // 要把整个 nameIdx 走一遍（XMLTV 常有几千个台），499 台的列表滚动时会明显吃帧。
    const cached: string | undefined = Epg.resCache.get(chName);
    if (cached !== undefined) {
      return cached;
    }
    const got: string = Epg.resolveRaw(chName);
    Epg.resCache.set(chName, got);
    return got;
  }

  private static resolveRaw(chName: string): string {
    const n: string = Epg.norm(chName);
    if (n.length === 0) {
      return '';
    }
    const hit: string | undefined = Epg.nameIdx.get(n);
    if (hit !== undefined) {
      return hit;
    }
    // 包含匹配取「最长命中」：CCTV1 不会因为 cctv10 先被遍历到就配错
    let bestId: string = '';
    let bestLen: number = 0;
    Epg.nameIdx.forEach((id: string, k: string) => {
      if (k.length < 3 || k.length <= bestLen) {
        return;
      }
      if (n.indexOf(k) >= 0 || k.indexOf(n) >= 0) {
        bestId = id;
        bestLen = k.length;
      }
    });
    return bestId;
  }

  // ==================== 解析 ====================

  private static parse(xml: string): void {
    const chs: EpgCh[] = [];
    const nameIdx: Map<string, string> = new Map();

    const chRe: RegExp = new RegExp('<channel\\b[^>]*\\bid="([^"]*)"[^>]*>([\\s\\S]*?)<\\/channel>', 'g');
    let m: RegExpExecArray | null = chRe.exec(xml);
    while (m !== null) {
      const ch: EpgCh = new EpgCh();
      ch.id = m[1];
      const body: string = m[2];
      const nRe: RegExp = new RegExp('<display-name[^>]*>([\\s\\S]*?)<\\/display-name>', 'g');
      let nm: RegExpExecArray | null = nRe.exec(body);
      while (nm !== null) {
        const v: string = Epg.unescape(nm[1]).trim();
        if (v.length > 0) {
          ch.names.push(v);
          const k: string = Epg.norm(v);
          // 先注册的优先，避免后面的台覆盖前面同名的台
          if (k.length > 0 && nameIdx.get(k) === undefined) {
            nameIdx.set(k, ch.id);
          }
        }
        nm = nRe.exec(body);
      }
      if (ch.id.length > 0 && ch.names.length > 0) {
        chs.push(ch);
      }
      m = chRe.exec(xml);
    }

    const progs: Map<string, EpgProg[]> = new Map();
    let total: number = 0;
    const pgRe: RegExp = new RegExp('<programme\\b([^>]*)>([\\s\\S]*?)<\\/programme>', 'g');
    let p: RegExpExecArray | null = pgRe.exec(xml);
    while (p !== null && total < Epg.MAX_PROGS) {
      const attrs: string = p[1];
      const chId: string = Epg.attr(attrs, 'channel');
      const start: number = Epg.tsOf(Epg.attr(attrs, 'start'));
      const stop: number = Epg.tsOf(Epg.attr(attrs, 'stop'));
      const tm: RegExpExecArray | null =
        new RegExp('<title[^>]*>([\\s\\S]*?)<\\/title>').exec(p[2]);
      const title: string = tm === null ? '' : Epg.unescape(tm[1]).trim();
      if (chId.length > 0 && start > 0 && title.length > 0) {
        let arr: EpgProg[] | undefined = progs.get(chId);
        if (arr === undefined) {
          arr = [];
          progs.set(chId, arr);
        }
        const it: EpgProg = new EpgProg();
        it.name = title;
        it.start = start;
        // 缺 stop 时按半小时算，否则这条永远查不到「正在播」
        it.stop = stop > start ? stop : start + 30 * 60000;
        arr.push(it);
        total++;
      }
      p = pgRe.exec(xml);
    }

    progs.forEach((arr: EpgProg[]) => {
      arr.sort((a: EpgProg, b: EpgProg) => a.start - b.start);
    });

    Epg.chs = chs;
    Epg.nameIdx = nameIdx;
    Epg.progs = progs;
  }

  /** 从属性串里取某个属性的值 */
  private static attr(attrs: string, key: string): string {
    const re: RegExp = new RegExp(key + '="([^"]*)"');
    const m: RegExpExecArray | null = re.exec(attrs);
    return m === null ? '' : m[1];
  }

  /**
   * XMLTV 时间 → 时间戳。
   * 格式：`20261111120000 +0800`（末尾时区可省略，省略时按本地时间理解）
   */
  private static tsOf(s: string): number {
    const v: string = s.trim();
    if (v.length < 14) {
      return 0;
    }
    const y: number = parseInt(v.substring(0, 4), 10);
    const mo: number = parseInt(v.substring(4, 6), 10) - 1;
    const d: number = parseInt(v.substring(6, 8), 10);
    const h: number = parseInt(v.substring(8, 10), 10);
    const mi: number = parseInt(v.substring(10, 12), 10);
    const se: number = parseInt(v.substring(12, 14), 10);
    if (isNaN(y) || isNaN(mo) || isNaN(d) || isNaN(h) || isNaN(mi)) {
      return 0;
    }
    let base: number = Date.UTC(y, mo, d, h, mi, isNaN(se) ? 0 : se);
    const rest: string = v.substring(14).trim();
    // `+0800` 表示「这个时刻是东八区」，换成 UTC 要减掉 8 小时
    if (rest.length >= 5) {
      const sign: number = rest.charAt(0) === '-' ? -1 : 1;
      const oh: number = parseInt(rest.substring(1, 3), 10);
      const om: number = parseInt(rest.substring(3, 5), 10);
      if (!isNaN(oh) && !isNaN(om)) {
        base = base - sign * (oh * 60 + om) * 60000;
      }
    }
    return base;
  }

  /** XML 实体反转义（节目名里常见 `&amp;` `&apos;`） */
  private static unescape(s: string): string {
    return s.replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, '\'')
      .replace(/&#(\d+);/g, (all: string, code: string) => String.fromCharCode(parseInt(code, 10)))
      .replace(/&amp;/g, '&');
  }
}
