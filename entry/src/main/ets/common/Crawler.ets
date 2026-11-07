import { Site, Vod, VodPage } from './Model';
import { Cms } from './Cms';
import { Store } from './Store';

/** 定时周期：6 小时 */
export const CRAWL_INTERVAL: number = 6 * 60 * 60 * 1000;
/** 每个站取多少条最新 */
const PER_SITE: number = 10;
/** 首页最多保留多少条 */
const FEED_MAX: number = 60;
/** 并发数。电视性能有限，太高会互相拖慢，实测 4 最稳 */
const CONC: number = 4;

export class CrawlResult {
  at: number = 0;
  /** 本轮尝试的站数 */
  sites: number = 0;
  /** 有数据返回的站数 */
  alive: number = 0;
  /** 没数据 / 超时的站数 */
  dead: number = 0;
  /** 抓到的条目数 */
  items: number = 0;
  /** 是否顺带更新了远程配置 */
  cfgUpdated: boolean = false;
  ok: boolean = true;
  msg: string = '';
}

/**
 * 定时抓取。
 *
 * 鸿蒙 TV 应用没有可靠的常驻后台，所以不用后台定时器，改成
 * 「启动 / 回前台 / 前台定时器」触发 + 记录上次时间，超过 6 小时才真跑。
 * 这样既不耗电，也不依赖后台权限，用户感知上就是「每次打开都是新的」。
 */
export class Crawler {
  private static running: boolean = false;
  /**
   * 正在跑的这轮抓取的 Promise。
   *
   * 订阅成功后 SettingPage 会 fire-and-forget 起一轮抓取；用户随即返回首页，
   * 首页 onPageShow 也会调 maybeRun。若两处各跑一轮，既重复又互相抢并发，
   * 所以这里让并发调用方「等同一轮结果」——await 同一个 Promise，谁先起谁干，
   * 后到的等它跑完再各自刷新自己的 feed，做到「订阅后立即更新 + 回首页立即可见」。
   */
  private static current: Promise<CrawlResult> | null = null;

  static isRunning(): boolean {
    return Crawler.running;
  }

  /** 到期才跑；没到期返回 null。若已有一轮在跑，则等它跑完返回同一结果 */
  static async maybeRun(): Promise<CrawlResult | null> {
    if (Crawler.running) {
      if (Crawler.current !== null) {
        return await Crawler.current;
      }
      return null;
    }
    const last: number = await Store.lastCrawlAt();
    if (last > 0 && Date.now() - last < CRAWL_INTERVAL) {
      return null;
    }
    return await Crawler.run(false);
  }

  /** 立即跑一轮。force=false 时同样受 6 小时间隔限制；已有一轮在跑时复用其结果 */
  static async run(force: boolean): Promise<CrawlResult> {
    const res = new CrawlResult();
    if (Crawler.running) {
      if (Crawler.current !== null) {
        return await Crawler.current;
      }
      res.ok = false;
      res.msg = '正在更新中，请稍候';
      return res;
    }
    if (!force) {
      const last: number = await Store.lastCrawlAt();
      if (last > 0 && Date.now() - last < CRAWL_INTERVAL) {
        res.ok = false;
        res.msg = '还没到更新时间';
        return res;
      }
    }

    Crawler.running = true;
    Crawler.current = Crawler.doRun();
    try {
      return await Crawler.current;
    } finally {
      Crawler.running = false;
      Crawler.current = null;
    }
  }

  /** 抓取主体：远程配置刷新 → 逐站抓最新 → 去重落盘 */
  private static async doRun(): Promise<CrawlResult> {
    const res = new CrawlResult();

    // 1) 远程配置刷新：只有用户自己填过地址才做。
    //    站源列表只来自订阅 / 手动导入，这里按用户填的地址联网刷新。
    if (await Store.isCustom()) {
      const url: string = await Store.getConfigUrl();
      if (url.length > 0) {
        try {
          await Store.loadConfig(url);
          res.cfgUpdated = true;
        } catch (err) {
          res.cfgUpdated = false;
        }
      }
    }

    // 2) 逐站抓最新（并发池）
    const sites: Site[] = await Store.activeSites();
    res.sites = sites.length;
    if (sites.length === 0) {
      // 还没有任何站源（未订阅 / 刚清空）。这一轮是空跑：
      // **不能**记 setLastCrawlAt，否则用户随后订阅完，回首页的 maybeRun 会
      // 因为「刚刚更新过」而被 6 小时间隔挡住，首页就一直空空如也。
      // 也不覆盖已有 feed / 抓取摘要。
      res.ok = false;
      res.msg = '还没有站源，请先在「设置 → 播放源 → 订阅」导入';
      return res;
    }
    const bag: Vod[] = [];
    const dead: string[] = [];
    let aliveCount: number = 0;
    let cursor: number = 0;

    const worker = async (): Promise<void> => {
      while (cursor < sites.length) {
        const i: number = cursor;
        cursor++;
        const s: Site = sites[i];
        let got: number = 0;
        try {
          const cms = new Cms(s);
          // 空分类 = 全部，取第一页即最新
          const page: VodPage = await cms.list('', 1);
          const arr: Vod[] = page.items;
          for (let k = 0; k < arr.length && k < PER_SITE; k++) {
            const v: Vod = arr[k];
            if (v.id.length === 0 || v.name.length === 0) {
              continue;
            }
            const item = new Vod();
            item.id = v.id;
            item.name = v.name;
            item.pic = v.pic;
            item.remark = v.remark;
            item.year = v.year;
            item.area = v.area;
            item.typeName = v.typeName;
            item.siteKey = s.key;
            item.siteName = s.name;
            bag.push(item);
            got++;
          }
        } catch (err) {
          got = 0;
        }
        if (got > 0) {
          aliveCount++;
        } else {
          dead.push(s.key);
        }
      }
    };

    const tasks: Promise<void>[] = [];
    for (let i = 0; i < CONC; i++) {
      tasks.push(worker());
    }
    await Promise.all(tasks);

    // 3) 按片名去重（同一部片常被多个站收录），保留先到的
    const seen: Set<string> = new Set<string>();
    const feed: Vod[] = [];
    for (let i = 0; i < bag.length; i++) {
      const v: Vod = bag[i];
      const k: string = v.name + '|' + v.year;
      if (seen.has(k)) {
        continue;
      }
      seen.add(k);
      feed.push(v);
      if (feed.length >= FEED_MAX) {
        break;
      }
    }

    res.alive = aliveCount;
    res.dead = dead.length;
    res.items = feed.length;
    res.at = Date.now();
    res.ok = feed.length > 0;
    if (!res.ok) {
      res.msg = '这一轮没有抓到数据，可能是网络不通或站源集体失效';
    }

    await Store.saveFeed(feed);
    await Store.saveDeadKeys(dead);
    await Store.setLastCrawlAt(res.at);
    await Store.saveCrawlSummary(Crawler.summaryOf(res));
    return res;
  }

  static summaryOf(r: CrawlResult): string {
    const t: string = Crawler.fmtTime(r.at);
    if (!r.ok) {
      return t + ' 更新失败：' + r.msg;
    }
    let s: string = t + ' 更新完成 · ' + r.alive + '/' + r.sites + ' 个站源有响应 · 收到 ' + r.items + ' 条';
    if (r.dead > 0) {
      s += ' · ' + r.dead + ' 个无响应';
    }
    if (r.cfgUpdated) {
      s += ' · 配置已刷新';
    }
    return s;
  }

  static fmtTime(ms: number): string {
    if (ms <= 0) {
      return '还没更新过';
    }
    const d = new Date(ms);
    const mo: string = (d.getMonth() + 1) < 10 ? '0' + (d.getMonth() + 1) : '' + (d.getMonth() + 1);
    const da: string = d.getDate() < 10 ? '0' + d.getDate() : '' + d.getDate();
    const h: string = d.getHours() < 10 ? '0' + d.getHours() : '' + d.getHours();
    const mi: string = d.getMinutes() < 10 ? '0' + d.getMinutes() : '' + d.getMinutes();
    return mo + '-' + da + ' ' + h + ':' + mi;
  }
}
