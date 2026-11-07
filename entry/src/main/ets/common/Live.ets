/**
 * 直播源解析 + 频道目录。
 *
 * 支持两种最常见的格式：
 *  - M3U：  #EXTINF:-1 tvg-logo="..." group-title="央视",CCTV-1  + 下一行地址
 *  - TXT：  「央视,#genre#」做分组行，之后每行「频道名,地址」
 *
 * 解析出来的分组顺序保持文件里的原始顺序——直播源作者通常把央视/卫视排在前面，
 * 重排反而更难找。目录层级在 buildTree 里整理；画质不进目录，播放中按网速自动选。
 */

import { Http } from './Http';
import { Channel, ChannelGroup, LiveDir } from './Model';

export class Live {
  /**
   * 单条流探活 + 测响应速度。
   *
   * 为什么不交给播放器：AVPlayer 对死链要 20 秒上下才回调 error，
   * 用户盯着黑屏等 20 秒才知道这台挂了。这里抓首包，几秒内给结论。
   * 返回 true 表示「能连上且吐的像是流」，不代表一定能解码出画面。
   */
  static async probe(url: string, ms: number): Promise<boolean> {
    if (url.length === 0) {
      return false;
    }
    try {
      const head: string = await Http.peek(url, ms);
      if (head.length === 0) {
        return false;
      }
      if (head === '#BIN' || head.indexOf('#EXTM3U') >= 0 || head.indexOf('#EXTINF') >= 0) {
        return true;
      }
      const t: string = head.trim().toLowerCase();
      // 源站失效最常见的手法：302 到一张错误页 / 一段「版权已下架」的视频
      if (t.startsWith('<!doctype') || t.startsWith('<html') || t.indexOf('<body') >= 0) {
        return false;
      }
      if (t.indexOf('error_account') >= 0 || t.indexOf('pirated') >= 0) {
        return false;
      }
      // 剩下的是 TS 分片之类的二进制/纯文本，交给播放器判定
      return true;
    } catch (err) {
      return false;
    }
  }

  /** 拉取并解析。失败抛异常，由调用方展示文案。timeout 可调，测活时用短超时快筛 */
  static async load(url: string, timeout: number = 25000): Promise<ChannelGroup[]> {
    const txt: string = await Http.text(url, undefined, timeout);
    if (txt.trim().length === 0) {
      throw new Error('直播源返回空内容');
    }
    const gs: ChannelGroup[] = Live.parse(txt);
    if (gs.length === 0) {
      throw new Error('没解析出频道，检查源格式是否为 m3u/txt');
    }
    return gs;
  }

  static parse(text: string): ChannelGroup[] {
    const t: string = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    if (t.indexOf('#EXTINF') >= 0) {
      return Live.parseM3u(t);
    }
    return Live.parseTxt(t);
  }

  // ---------- 目录 ----------

  /**
   * 按源里原始的分组名建目录，返回根节点（根节点本身不显示，只用它的 children）。
   *
   * 不做任何归类改写：源写「央视频道」就显示「央视频道」，写「地方台/北京」
   * 就拆成两级——和电视盒子里的分组列表是同一套东西。认不出来的（多数是源
   * 根本没写 group-title）统一叫「未分组」，原样留着，不猜、不合并。
   */
  static buildTree(groups: ChannelGroup[]): LiveDir {
    const root = new LiveDir();
    root.name = '全部';

    for (let i = 0; i < groups.length; i++) {
      const g: ChannelGroup = groups[i];
      if (g.channels.length === 0) {
        continue;
      }
      const parts: string[] = Live.splitName(g.name);
      if (parts.length >= 2) {
        const p: LiveDir = Live.child(root, parts[0]);
        const sub: LiveDir = Live.child(p, Live.tail(parts, 1));
        for (let k = 0; k < g.channels.length; k++) {
          sub.channels.push(g.channels[k]);
        }
      } else {
        const d: LiveDir = Live.child(root, g.name);
        for (let k = 0; k < g.channels.length; k++) {
          d.channels.push(g.channels[k]);
        }
      }
    }

    Live.countOf(root);
    return root;
  }

  /** 取节点下的全部频道（含所有子目录），按树序展开 */
  static collect(n: LiveDir, out: Channel[]): void {
    for (let i = 0; i < n.channels.length; i++) {
      out.push(n.channels[i]);
    }
    for (let i = 0; i < n.children.length; i++) {
      Live.collect(n.children[i], out);
    }
  }

  private static countOf(n: LiveDir): number {
    let c: number = n.channels.length;
    for (let i = 0; i < n.children.length; i++) {
      c += Live.countOf(n.children[i]);
    }
    n.count = c;
    return c;
  }

  private static child(parent: LiveDir, name: string): LiveDir {
    for (let i = 0; i < parent.children.length; i++) {
      if (parent.children[i].name === name) {
        return parent.children[i];
      }
    }
    const d = new LiveDir();
    d.name = name;
    parent.children.push(d);
    return d;
  }

  /** 部分源用 / | \ > 写层级，拆出来直接用，比猜关键词准 */
  private static splitName(n: string): string[] {
    const out: string[] = [];
    let cur: string = '';
    for (let i = 0; i < n.length; i++) {
      const c: string = n.charAt(i);
      if (c === '/' || c === '\\' || c === '|' || c === '｜' || c === '>' || c === '＞') {
        if (cur.trim().length > 0) {
          out.push(cur.trim());
        }
        cur = '';
      } else {
        cur = cur + c;
      }
    }
    if (cur.trim().length > 0) {
      out.push(cur.trim());
    }
    return out.length === 0 ? [n] : out;
  }

  private static tail(parts: string[], from: number): string {
    let s: string = '';
    for (let i = from; i < parts.length; i++) {
      s = s.length === 0 ? parts[i] : s + '/' + parts[i];
    }
    return s;
  }

  // ---------- M3U ----------

  private static parseM3u(t: string): ChannelGroup[] {
    const lines: string[] = t.split('\n');
    const groups: ChannelGroup[] = [];
    let curName: string = '';
    let curLogo: string = '';
    let curGroup: string = '';

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        curGroup = Live.attr(line, 'group-title');
        if (curGroup.length === 0) {
          curGroup = '未分组';
        }
        curLogo = Live.attr(line, 'tvg-logo');
        const c: number = line.lastIndexOf(',');
        curName = c >= 0 ? line.substring(c + 1).trim() : '';
        if (curName.length === 0) {
          curName = Live.attr(line, 'tvg-name');
        }
        continue;
      }
      if (line.startsWith('#')) {
        // #EXTGRP:分组 这类补充信息
        if (line.startsWith('#EXTGRP:')) {
          const g: string = line.substring(8).trim();
          if (g.length > 0) {
            curGroup = g;
          }
        }
        continue;
      }
      if (curName.length === 0) {
        continue;
      }
      Live.push(groups, curGroup, curName, line, curLogo);
      curName = '';
      curLogo = '';
    }
    return groups;
  }

  private static attr(line: string, key: string): string {
    const i: number = line.indexOf(key + '="');
    if (i < 0) {
      return '';
    }
    const s: number = i + key.length + 2;
    const e: number = line.indexOf('"', s);
    return e < 0 ? '' : line.substring(s, e);
  }

  // ---------- TXT ----------

  private static parseTxt(t: string): ChannelGroup[] {
    const lines: string[] = t.split('\n');
    const groups: ChannelGroup[] = [];
    let curGroup: string = '未分组';

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0 || line.startsWith('#')) {
        continue;
      }
      if (line.indexOf(',#genre#') >= 0) {
        const g: string = line.substring(0, line.indexOf(',#genre#')).trim();
        if (g.length > 0) {
          curGroup = g;
        }
        continue;
      }
      const c: number = line.indexOf(',');
      if (c <= 0) {
        continue;
      }
      const name: string = line.substring(0, c).trim();
      const url: string = line.substring(c + 1).trim();
      if (name.length === 0 || !Live.isUrl(url)) {
        continue;
      }
      Live.push(groups, curGroup, name, url, '');
    }
    return groups;
  }

  // ---------- 公共 ----------

  /**
   * 只收 http/https。
   * 源里混着 rtmp://、rtsp://、udp:// 这类地址，系统 AVPlayer 播不了，
   * 留在列表里点一次失败一次，不如直接滤掉。
   */
  private static isUrl(u: string): boolean {
    return u.startsWith('http://') || u.startsWith('https://');
  }

  private static push(groups: ChannelGroup[], groupName: string, name: string, url: string,
    logo: string): void {
    let g: ChannelGroup | null = null;
    for (let i = 0; i < groups.length; i++) {
      if (groups[i].name === groupName) {
        g = groups[i];
        break;
      }
    }
    if (g === null) {
      g = new ChannelGroup();
      g.name = groupName;
      groups.push(g);
    }
    // 同名同组视为同一个台的多条线路：合并成一条，地址按顺序备着
    for (let i = 0; i < g.channels.length; i++) {
      const exist: Channel = g.channels[i];
      if (exist.name === name) {
        if (exist.urls.indexOf(url) < 0) {
          exist.urls.push(url);
        }
        return;
      }
    }
    const ch = new Channel();
    ch.name = name;
    ch.url = url;
    ch.logo = logo;
    ch.group = groupName;
    ch.urls.push(url);
    g.channels.push(ch);
  }
}
