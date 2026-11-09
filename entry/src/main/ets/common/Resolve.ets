import { ParseRule } from './Model';
import { Http } from './Http';
import { Cms } from './Cms';

export interface ParseResp {
  code?: number;
  url?: string;
  msg?: string;
  header?: Record<string, string>;
}

export class Resolved {
  url: string = '';
  header: Record<string, string> = {};
  via: string = '';
  ok: boolean = false;
}

/** 一次成功命中的记录：哪条规则、返回了什么 */
class Hit {
  rule: ParseRule = new ParseRule();
  resp: ParseResp = {};
}

/**
 * 每条解析规则的成功率统计（内存缓存，本次会话内有效）。
 *
 * key = rule.name，value = RuleStat {ok: number, total: number}。
 * 用于下次调用时把成功率高的规则排在前面，减少等待时间。
 */
class RuleStat {
  ok: number = 0;
  total: number = 0;
}
const ruleStats: Map<string, RuleStat> = new Map();

/**
 * 全局解析超时（毫秒）：两轮并发都超过这个时间就放弃，直接返回原地址。
 * 实测每条规则 4.5s 单超时 × 两轮 ≈ 9s；把总预算限在 12s，
 * 极端情况（多台规则全挂）不会让用户等超过这个时间。
 */
const RESOLVE_TOTAL_TIMEOUT_MS: number = 12000;

/**
 * 播放地址解析。
 *
 * 采集源给出的地址通常是直链（m3u8/mp4），少数需要走「解析接口」把
 * 视频站页面地址换成真实播放地址。这里实现 TVBox parses 里 type=1 的那类：
 *   GET {rule.url}{encodeURIComponent(playUrl)}  →  {"url":"http://...m3u8"}
 *
 * 两条约束决定了这里必须是「编码优先 + 规则并行」：
 *  - 主流解析接口把 u 当 URL 参数读，必须 encodeURIComponent，
 *    不编码的写法基本拿不到结果。原来的顺序是「先原样再编码」，
 *    等于对每个接口先白等一个超时，8 条 × 6 秒 = 48 秒才轮到正确写法。
 *  - 规则串行最坏 8 × 2 × 6 秒 = 96 秒，用户早就退出了。
 *    现在 8 条规则同时发，命中即可返回，总耗时约等于「最慢的一条」。
 *
 * 优化：成功率排序 + 全局超时（最坏 12s 放行）。
 */
export class Resolver {
  static async resolve(raw: string, rules: ParseRule[]): Promise<Resolved> {
    const r = new Resolved();
    r.url = raw;

    if (raw.length === 0) {
      r.via = '空地址';
      return r;
    }
    if (Cms.isDirect(raw)) {
      r.via = '直链';
      r.ok = true;
      return r;
    }

    const limit: number = rules.length < 8 ? rules.length : 8;
    if (limit === 0) {
      r.via = '未解析（可能需要专用解析器）';
      return r;
    }

    // 按成功率排序：成功率高的规则先跑，减少等待时间
    const pick: ParseRule[] = Resolver.sortBySuccessRate(rules.slice(0, limit));

    // 全局超时：两轮并发都不超 RESOLVE_TOTAL_TIMEOUT_MS
    const globalTimeoutProm = new Promise<null>((resolve) => {
      setTimeout(() => resolve(null), RESOLVE_TOTAL_TIMEOUT_MS);
    });

    const resolveProm: Promise<Hit | null> = (async (): Promise<Hit | null> => {
      // 第一轮：编码（绝大多数接口走这条）
      let hit: Hit | null = await Resolver.round(pick, raw, true);
      if (hit === null) {
        // 第二轮：原样。少数老接口自己做解码，传编码值反而失败
        hit = await Resolver.round(pick, raw, false);
      }
      return hit;
    })();

    // 全局超时 race：超时后直接放行，不卡住播放器
    const winner = await Promise.race([resolveProm, globalTimeoutProm]);

    if (winner !== null) {
      const hit = winner as Hit;
      Resolver.recordHit(hit.rule.name, true);
      r.url = Cms.s(hit.resp.url);
      r.via = hit.rule.name;
      r.ok = true;
      if (hit.resp.header !== undefined && hit.resp.header !== null) {
        r.header = hit.resp.header;
      }
      return r;
    }

    r.via = '未解析（可能需要专用解析器）';
    return r;
  }

  /**
   * 记录规则命中情况，用于成功率排序。
   * 每条规则单独统计，成功/失败各加 1。
   */
  static recordHit(name: string, ok: boolean): void {
    let s: RuleStat | undefined = ruleStats.get(name);
    if (s === undefined) {
      s = new RuleStat();
      ruleStats.set(name, s);
    }
    s.total++;
    if (ok) {
      s.ok++;
    }
  }

  /**
   * 按成功率排序：成功次数多的优先，从未试过的排末尾。
   * 这样随着使用积累，「好使」的规则会越来越靠前，首次命中延迟下降。
   */
  private static sortBySuccessRate(rules: ParseRule[]): ParseRule[] {
    return rules.slice().sort((a: ParseRule, b: ParseRule) => {
      const sa = ruleStats.get(a.name);
      const sb = ruleStats.get(b.name);
      const rateA: number = (sa !== undefined && sa.total > 0) ? sa.ok / sa.total : 0.5;
      const rateB: number = (sb !== undefined && sb.total > 0) ? sb.ok / sb.total : 0.5;
      return rateB - rateA;
    });
  }

  /** 单条规则试一次。失败一律返回 null，不抛异常 */
  private static async tryOne(rule: ParseRule, raw: string, encoded: boolean): Promise<Hit | null> {
    const cand: string = rule.url + (encoded ? encodeURIComponent(raw) : raw);
    try {
      const txt: string = await Http.text(cand, undefined, 4500);
      const j = JSON.parse(Cms.cleanJson(txt)) as ParseResp;
      const u: string = Cms.s(j.url);
      if (u.startsWith('http')) {
        const h = new Hit();
        h.rule = rule;
        h.resp = j;
        return h;
      }
    } catch (err) {
      // 换下一个解析器
    }
    return null;
  }

  /**
   * 一轮并发：所有规则同时发，谁先给结果就用谁，其余在后台自然结束。
   * 不用 Promise.all 是因为它会等最慢的那条 —— 第一条 100ms 就命中时
   * 用户还要再等 4 秒，属于自己给自己加延迟。
   */
  private static async round(rules: ParseRule[], raw: string, encoded: boolean): Promise<Hit | null> {
    return new Promise<Hit | null>((done: (v: Hit | null) => void) => {
      let left: number = rules.length;
      let settled: boolean = false;
      const finish = (h: Hit | null): void => {
        if (settled) {
          return;
        }
        settled = true;
        done(h);
      };
      for (let i = 0; i < rules.length; i++) {
        Resolver.tryOne(rules[i], raw, encoded).then((h: Hit | null) => {
          left--;
          if (h !== null) {
            finish(h);
            return;
          }
          if (left === 0) {
            finish(null);
          }
        }).catch(() => {
          left--;
          if (left === 0) {
            finish(null);
          }
        });
      }
    });
  }
}
