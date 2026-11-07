/**
 * 播放源测速排行 + 可用性检测。
 *
 * 为什么抽成公共模块：这套逻辑原先只写在设置页里，直播页拿不到，于是用户在
 * 直播页看到某个源「一堆台但全点不开」，只能自己退回设置页去猜哪个源好用。
 * 现在两处共用同一份实现，结论也一致（同一套超时、抽样数、评分权重）。
 *
 * 两类检测，回答的是两个不同问题：
 *   1. 源级 rankOne —— 这个源好不好？拉列表快不快、有多少台、抽样能不能播。
 *      用于「测速排行」，用来在多个源之间挑一个。
 *   2. 频道级 channels —— 这个源里哪些台是死的？逐个抓首包，
 *      用于把失效台标灰，避免用户点一次等 20 秒。
 *
 * 一个必须记住的教训：只看「列表拉得快」完全没用。实测有源 74 ms 就拉完
 * 500 多个台，抽样一测全连不上。所以可播率必须实测，不能靠速度推断。
 */

import { Live } from './Live';
import { Channel, ChannelGroup } from './Model';

/** 一次源级测速的结论 */
export class LiveScore {
  name: string = '';
  url: string = '';
  /** 列表是否拉得下来（不代表频道能播） */
  ok: boolean = false;
  /** 拉完整份列表的耗时（ms），-1 = 没测出来 */
  ms: number = -1;
  /** 频道总数 */
  count: number = 0;
  /** 抽样里能连上的数量 */
  alive: number = 0;
  /** 实际抽样数量（源里台太少时可能小于计划值） */
  sampled: number = 0;
  /** 综合评分 0~100，越大越好 */
  score: number = 0;
  /** 给界面直接用的一句话，避免每处各拼一遍 */
  state: string = '';
}

export class LiveProbe {
  /** 每个源抽样几个台实测。3 个够看出「全军覆没」，再多会明显拖慢排行 */
  static readonly SAMPLE: number = 3;
  /** 单条流等首包的超时。死链常常直接挂住不返回，超过这个时间就当失效 */
  static readonly STREAM_MS: number = 3000;
  /** 拉列表的超时。8 秒拉不下来说明这个源本身有问题 */
  static readonly LIST_MS: number = 8000;
  /** 外层兜底超时：Http 的 abort 不是所有情况都能打断，外层再压一道 */
  static readonly GUARD_MS: number = 10000;

  /**
   * 测一个源。不会抛异常，失败也会返回一个 ok=false 的结果。
   *
   * 顺序是刻意的：先把列表拉下来（拿到频道数），再抽样测流。
   * 反过来做的话，列表都拉不下来的源还要白等 3 次流超时。
   */
  static async rankOne(name: string, url: string): Promise<LiveScore> {
    const r = new LiveScore();
    r.name = name;
    r.url = url;
    const t0: number = Date.now();

    let gs: ChannelGroup[] = [];
    try {
      gs = await Promise.race([Live.load(url, LiveProbe.LIST_MS), LiveProbe.guard(LiveProbe.GUARD_MS)]);
    } catch (e) {
      r.state = '拉取失败';
      return r;
    }

    r.ms = Date.now() - t0;
    let n: number = 0;
    for (let i = 0; i < gs.length; i++) {
      n += gs[i].channels.length;
    }
    if (n === 0) {
      r.state = '列表为空';
      return r;
    }

    r.ok = true;
    r.count = n;

    // 抽样：先从不同分组里各取第一个（避免全落在同一个台的多条线路上），
    // 分组数不够再回头补该组里的第 2、3 个 —— 有的源只有一个分组装着四百个台，
    // 只从这里取一个样本，「可播 1/1」的说服力太弱，一个台抽风就会把整个源判死。
    const samples: string[] = [];
    for (let i = 0; i < gs.length && samples.length < LiveProbe.SAMPLE; i++) {
      const chs: Channel[] = gs[i].channels;
      if (chs.length > 0) {
        samples.push(chs[0].urls.length > 0 ? chs[0].urls[0] : chs[0].url);
      }
    }
    for (let k = 1; samples.length < LiveProbe.SAMPLE; k++) {
      let added: boolean = false;
      for (let i = 0; i < gs.length && samples.length < LiveProbe.SAMPLE; i++) {
        const chs: Channel[] = gs[i].channels;
        if (k < chs.length) {
          const u: string = chs[k].urls.length > 0 ? chs[k].urls[0] : chs[k].url;
          if (samples.indexOf(u) < 0) {
            samples.push(u);
            added = true;
          }
        }
      }
      if (!added) {
        break;      // 全源就那么几个台，补不出来
      }
    }
    r.sampled = samples.length;

    const jobs: Promise<boolean>[] = [];
    for (let i = 0; i < samples.length; i++) {
      jobs.push(Live.probe(samples[i], LiveProbe.STREAM_MS));
    }
    const rs: boolean[] = await Promise.all(jobs);
    for (let i = 0; i < rs.length; i++) {
      if (rs[i]) {
        r.alive++;
      }
    }

    r.score = LiveProbe.score(r);
    r.state = r.ms + ' ms · ' + r.count + ' 台 · 可播 ' + r.alive + '/' + r.sampled;
    return r;
  }

  /**
   * 评分：可播率占 70%，速度占 30%。
   *
   * 权重不对称是有意的 —— 直播首要的是「点开能看」。一个 200 ms 但半数是死台的源，
   * 实际体验远不如一个 800 ms 但全部能播的源。速度按 50 ms 折 1 分递减：
   * 100 ms → 98 分，1000 ms → 80 分，5000 ms → 0 分。
   */
  static score(r: LiveScore): number {
    if (!r.ok) {
      return 0;
    }
    const availability: number = r.sampled > 0 ? (r.alive / r.sampled) * 100 : 0;
    const speed: number = Math.max(0, 100 - r.ms / 50);
    return Math.round(availability * 0.7 + speed * 0.3);
  }

  /**
   * 批量测速，按批推进（每批 3 个）。
   *
   * 并发全部拉满的话，同时开十几个 HTTP 连接，弱网下会互相拖慢，
   * 测出来的耗时反而不准（本来 300 ms 的源测成 2 秒）。
   */
  static async rankAll(items: LiveScore[], onEach: (i: number, r: LiveScore) => void): Promise<LiveScore[]> {
    const out: LiveScore[] = [];
    for (let i = 0; i < items.length; i++) {
      const r = new LiveScore();
      r.name = items[i].name;
      r.url = items[i].url;
      out.push(r);
    }
    for (let s = 0; s < out.length; s += 3) {
      const batch: Promise<void>[] = [];
      for (let i = s; i < Math.min(s + 3, out.length); i++) {
        const idx: number = i;
        batch.push((async (): Promise<void> => {
          const r = await LiveProbe.rankOne(out[idx].name, out[idx].url);
          out[idx] = r;
          onEach(idx, r);
        })());
      }
      await Promise.all(batch);
    }
    return out;
  }

  /** 按评分排序；同分时台多的排前面，再同则按耗时 */
  static sort(list: LiveScore[]): LiveScore[] {
    const out: LiveScore[] = list.slice();
    out.sort((a: LiveScore, b: LiveScore): number => {
      if (a.score !== b.score) {
        return b.score - a.score;
      }
      if (a.ok !== b.ok) {
        return a.ok ? -1 : 1;
      }
      if (a.count !== b.count) {
        return b.count - a.count;
      }
      return a.ms - b.ms;
    });
    return out;
  }

  /**
   * 逐个检测频道能不能连上，返回失效数量。
   *
   * 并发控制在 4：再高容易把源站当攻击，几十个台同时探活会被限流，
   * 结果是一堆「假失效」——明明能播的台被标灰，比不标更糟。
   *
   * onTick 每检测完一条调一次，界面可以边测边标灰，不用等全部结束。
   */
  static async channels(chs: Channel[], onTick: (ch: Channel, alive: boolean) => void,
    parallel: number = 4): Promise<number> {
    let dead: number = 0;
    for (let s = 0; s < chs.length; s += parallel) {
      const jobs: Promise<void>[] = [];
      for (let i = s; i < Math.min(s + parallel, chs.length); i++) {
        const ch: Channel = chs[i];
        const u: string = ch.urls.length > 0 ? ch.urls[0] : ch.url;
        jobs.push((async (): Promise<void> => {
          const ok: boolean = await Live.probe(u, LiveProbe.STREAM_MS);
          if (!ok) {
            dead++;
          }
          onTick(ch, ok);
        })());
      }
      await Promise.all(jobs);
    }
    return dead;
  }

  /** 外层兜底超时：到点就抛，让 rankOne 走到「拉取失败」分支 */
  private static guard(ms: number): Promise<ChannelGroup[]> {
    return new Promise<ChannelGroup[]>((_, reject: (e: Error) => void) => {
      setTimeout(() => {
        reject(new Error('探测超时'));
      }, ms);
    });
  }
}
