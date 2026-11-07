/**
 * 直播源列表。
 *
 * 应用包内**不内置**任何直播源——配合应用市场上架合规：影视 / 直播源
 * 只能由用户主动订阅或手动填写导入，不能随安装包下发。候选直播源只来自：
 *   1. 订阅文档下发的 lives（Store.subLives）
 *   2. 用户手动填写的直播源地址
 *
 * 设置页拿它做「测速排行 / 选用」，直播页也拿它做「首次进入还没配源时」的引导。
 */

import { RawLive } from './Model';

export class LivePreset {
  name: string = '';
  url: string = '';
  /** 空串 = 未测；「测试中…」；「时长 · 频道数」；「不可用」 */
  state: string = '';
  ok: boolean = false;
  /** 测出的频道总数，用来挑最优源 */
  count: number = 0;
  /** 拉完整份列表的耗时（ms），-1 表示没测出来 */
  ms: number = -1;
  /** 抽样测活的命中数：频道多不等于能播，这一项才决定好不好用 */
  alive: number = 0;
  /** 抽样总数 */
  sampled: number = 0;

  constructor(name: string, url: string) {
    this.name = name;
    this.url = url;
  }
}

/** 把订阅文档下发的直播源列表（RawLive）转成 LivePreset 候选 */
export function fromLives(lives: RawLive[]): LivePreset[] {
  const out: LivePreset[] = [];
  for (let i = 0; i < lives.length; i++) {
    const l: RawLive = lives[i];
    const url: string = l.url !== undefined ? l.url.trim() : '';
    if (url.length > 0) {
      const name: string = l.name !== undefined && l.name.length > 0 ? l.name : ('直播源' + (i + 1));
      out.push(new LivePreset(name, url));
    }
  }
  return out;
}
