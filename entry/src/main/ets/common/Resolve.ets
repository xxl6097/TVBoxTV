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

/**
 * 播放地址解析。
 *
 * 采集源给出的地址通常是直链（m3u8/mp4），少数需要走「解析接口」把
 * 视频站页面地址换成真实播放地址。这里实现 TVBox parses 里 type=1 的那类：
 *   GET {rule.url}{encodeURIComponent(playUrl)}  →  {"url":"http://...m3u8"}
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
    for (let i = 0; i < limit; i++) {
      const rule: ParseRule = rules[i];
      // 解析接口对参数编码的接受度不一致，先原样再编码
      const cands: string[] = [rule.url + raw, rule.url + encodeURIComponent(raw)];
      for (let k = 0; k < cands.length; k++) {
        try {
          const txt: string = await Http.text(cands[k], undefined, 6000);
          const j = JSON.parse(Cms.cleanJson(txt)) as ParseResp;
          const u: string = Cms.s(j.url);
          if (u.startsWith('http')) {
            r.url = u;
            r.via = rule.name;
            r.ok = true;
            if (j.header !== undefined) {
              r.header = j.header;
            }
            return r;
          }
        } catch (err) {
          // 换下一个解析器
        }
      }
    }

    r.via = '未解析（可能需要专用解析器）';
    return r;
  }
}
