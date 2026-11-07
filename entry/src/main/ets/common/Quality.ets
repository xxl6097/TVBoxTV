/**
 * 清晰度与网络自适应。
 *
 * 卡顿的根子通常是「码率 > 实际带宽」。能做的三件事：
 *  1. 认出 HLS master playlist 里的多档码率，让用户能选，也能自动选；
 *  2. 用 AVPlayer 的 PlaybackStrategy.preferredHeight 把档位钉在选定值上
 *     （保留 master 地址，系统的 ABR 仍然能工作，比我们自己换流地址稳）；
 *  3. 缓冲水位 preferredBufferDuration 按实测网速抬高，慢网多垫几秒就不容易断。
 */

import http from '@ohos.net.http';

const UA: string = 'Mozilla/5.0 (Linux; HarmonyOS; SmartScreen) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/** 一档清晰度 */
export class QLevel {
  /** 竖向分辨率，0 表示源没标 RESOLUTION */
  height: number = 0;
  width: number = 0;
  /** 声明峰值码率，bps */
  bps: number = 0;
  /** 这一档的媒体播放列表地址 */
  url: string = '';
  /** 源里自带的名字，如 "高清"、"1080p" */
  name: string = '';
}

/** 一次测速结果 */
export class QSpeed {
  /** 实测下行速率 kbps，-1 表示没测出来 */
  kbps: number = -1;
  bytes: number = 0;
  ms: number = 0;
}

export class Quality {
  /** 「自动」档 */
  static readonly AUTO: number = 0;
  /** 「原画」= 不设上限，取源里最高 */
  static readonly TOP: number = 9999;

  /**
   * 解析 master playlist。
   * 形如：
   *   #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1920x1080,NAME="高清"
   *   1080p/index.m3u8
   * 只有带 EXT-X-STREAM-INF 的才算多档；普通媒体列表返回空数组。
   */
  static parseMaster(text: string, base: string): QLevel[] {
    const out: QLevel[] = [];
    if (text.indexOf('#EXT-X-STREAM-INF') < 0) {
      return out;
    }
    const lines: string[] = text.replace(/\r\n/g, '\n').split('\n');
    let pending: QLevel | null = null;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        const lv = new QLevel();
        lv.bps = Quality.numAttr(line, 'AVERAGE-BANDWIDTH');
        const peak: number = Quality.numAttr(line, 'BANDWIDTH');
        if (peak > 0) {
          lv.bps = peak;
        }
        const res: string = Quality.strAttr(line, 'RESOLUTION');
        if (res.length > 0) {
          const x: number = res.toLowerCase().indexOf('x');
          if (x > 0) {
            lv.width = Quality.toNum(res.substring(0, x));
            lv.height = Quality.toNum(res.substring(x + 1));
          }
        }
        lv.name = Quality.strAttr(line, 'NAME');
        if (lv.name.length === 0) {
          lv.name = Quality.strAttr(line, 'VIDEO-RANGE');
        }
        pending = lv;
        continue;
      }
      if (line.startsWith('#')) {
        continue;
      }
      if (pending !== null) {
        pending.url = Quality.abs(base, line);
        out.push(pending);
        pending = null;
      }
    }
    // 按清晰度升序，没有 RESOLUTION 的按码率排
    out.sort((a: QLevel, b: QLevel): number => {
      const ha: number = a.height > 0 ? a.height : Math.floor(a.bps / 20000);
      const hb: number = b.height > 0 ? b.height : Math.floor(b.bps / 20000);
      if (ha !== hb) {
        return ha - hb;
      }
      return a.bps - b.bps;
    });
    return out;
  }

  /** 显示名。优先用分辨率，没标就用码率折算 */
  static labelOf(h: number, bps: number): string {
    if (h >= 2160) {
      return '4K';
    }
    if (h >= 1440) {
      return '2K';
    }
    if (h >= 1080) {
      return '1080P';
    }
    if (h >= 720) {
      return '720P';
    }
    if (h >= 540) {
      return '540P';
    }
    if (h >= 480) {
      return '480P';
    }
    if (h >= 360) {
      return '360P';
    }
    if (bps >= 4000000) {
      return '高清';
    }
    if (bps >= 1500000) {
      return '标清';
    }
    return bps > 0 ? '流畅' : '原画';
  }

  static labelOfLevel(l: QLevel): string {
    const s: string = Quality.labelOf(l.height, l.bps);
    if (s === '原画' && l.name.length > 0) {
      return l.name;
    }
    // labelOf 只认 360/480/540/720/1080 这些标准高度，其余一律落到
    // 「流畅/标清/高清」三档，于是 240P 和 180P 会显示成两个一模一样的「流畅」，
    // 面板上根本分不清。这类档位直接显示真实高度。
    const vague: boolean = s === '流畅' || s === '标清' || s === '高清';
    if (vague && l.height > 0) {
      return l.height + 'P';
    }
    // 连高度都没写的 master 只能靠码率区分
    if (vague && l.bps > 0) {
      return s + ' ' + Math.round(l.bps / 1000) + 'K';
    }
    return s;
  }

  /**
   * 按实测速率挑档：留 30% 余量，取「码率不超过 0.7×速率」的最高一档。
   * 一档都不满足（网太差）就退到最低档，至少别整个卡死。
   */
  static pickBySpeed(kbps: number, levels: QLevel[]): number {
    if (levels.length === 0) {
      return -1;
    }
    if (kbps <= 0) {
      return 0;
    }
    const budget: number = kbps * 0.7 * 1000;
    let best: number = -1;
    for (let i = 0; i < levels.length; i++) {
      const need: number = levels[i].bps > 0 ? levels[i].bps : (levels[i].height > 0 ? levels[i].height * 4000 : 0);
      if (need <= budget) {
        best = i;
      }
    }
    return best < 0 ? 0 : best;
  }

  /** 选「不高于 cap 的最高档」；cap 为 TOP 时直接取最高档 */
  static pickByCap(cap: number, levels: QLevel[]): number {
    if (levels.length === 0) {
      return -1;
    }
    if (cap >= Quality.TOP) {
      return levels.length - 1;
    }
    let best: number = -1;
    for (let i = 0; i < levels.length; i++) {
      if (levels[i].height <= 0 || levels[i].height <= cap) {
        best = i;
      }
    }
    return best < 0 ? 0 : best;
  }

  /** 从媒体列表里找第一个分片，用来实测网速 */
  static firstSegment(playlist: string, base: string): string {
    const lines: string[] = playlist.replace(/\r\n/g, '\n').split('\n');
    let nextIsSeg: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        nextIsSeg = true;
        continue;
      }
      if (line.startsWith('#')) {
        continue;
      }
      if (nextIsSeg || line.indexOf('.ts') > 0 || line.indexOf('.m4s') > 0 ||
        line.indexOf('.mp4') > 0 || line.indexOf('.flv') > 0) {
        return Quality.abs(base, line);
      }
    }
    return '';
  }

  /**
   * 实测下行速率。
   *
   * 用 dataReceive 边收边计数，收到 limit 就主动 destroy——
   * 不这样做的话，遇到不支持 Range 的 CDN 会把整个 mp4 拉下来，几百兆。
   */
  static measure(url: string, ms: number, limit: number): Promise<QSpeed> {
    return new Promise<QSpeed>((resolve) => {
      const st = new QSpeed();
      if (url.length === 0) {
        resolve(st);
        return;
      }
      const req = http.createHttp();
      let bytes: number = 0;
      let settled: boolean = false;
      let timer: number = -1;
      const t0: number = Date.now();
      const finish = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
        try {
          req.off('dataReceive');
        } catch (e) {
          // 忽略
        }
        try {
          req.destroy();
        } catch (e) {
          // 忽略
        }
        st.bytes = bytes;
        st.ms = Date.now() - t0;
        // bits/ms 就是 kbps：1 字节/毫秒 = 8 kbps
        if (st.ms > 150 && bytes > 16384) {
          st.kbps = Math.floor(bytes * 8 / st.ms);
        }
        resolve(st);
      };
      try {
        req.on('dataReceive', (buf: ArrayBuffer) => {
          bytes += buf.byteLength;
          if (bytes >= limit) {
            finish();
          }
        });
      } catch (e) {
        // 老版本没有 dataReceive，退化成「只测得没测速」
      }
      timer = setTimeout(finish, ms);
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': UA, 'Accept': '*/*', 'Range': 'bytes=0-' + (limit - 1) },
        connectTimeout: ms,
        readTimeout: ms,
        usingCache: false
      };
      req.request(url, opt).then(() => {
        finish();
      }).catch(() => {
        // 连接失败/被 destroy：有多少算多少，够 16KB 就给结果
        finish();
      });
    });
  }

  static fmtKbps(kbps: number): string {
    if (kbps <= 0) {
      return '';
    }
    if (kbps >= 1000) {
      return (Math.round(kbps / 100) / 10) + ' MB/s';
    }
    return kbps + ' KB/s';
  }

  // ---------- 内部 ----------

  private static toNum(s: string): number {
    const n: number = parseInt(s.trim(), 10);
    return isNaN(n) ? 0 : n;
  }

  private static numAttr(line: string, key: string): number {
    return Quality.toNum(Quality.strAttr(line, key));
  }

  private static strAttr(line: string, key: string): string {
    const i: number = line.indexOf(key + '=');
    if (i < 0) {
      return '';
    }
    let s: number = i + key.length + 1;
    let e: number = line.length;
    if (line.charAt(s) === '"') {
      s = s + 1;
      const q: number = line.indexOf('"', s);
      return q < 0 ? line.substring(s) : line.substring(s, q);
    }
    const comma: number = line.indexOf(',', s);
    if (comma >= 0) {
      e = comma;
    }
    return line.substring(s, e).trim();
  }

  /** 相对地址转绝对（HLS 里分片地址常见 "../xxx/seg.ts"） */
  static abs(base: string, ref: string): string {
    const r: string = ref.trim();
    if (r.startsWith('http://') || r.startsWith('https://')) {
      return r;
    }
    const scheme: number = base.indexOf('://');
    if (scheme < 0) {
      return r;
    }
    const hostEnd: number = base.indexOf('/', scheme + 3);
    const origin: string = hostEnd < 0 ? base : base.substring(0, hostEnd);
    if (r.startsWith('//')) {
      return base.substring(0, scheme) + ':' + r;
    }
    if (r.startsWith('/')) {
      return origin + r;
    }
    const cut: number = base.indexOf('?');
    const clean: string = cut >= 0 ? base.substring(0, cut) : base;
    const dir: string = clean.substring(0, clean.lastIndexOf('/') + 1);
    const path: string = dir + r;
    // 只对 origin 之后的路径段做 ../ 归一，否则会把 http:// 里的斜杠吃掉
    const rest: string = path.length > origin.length ? path.substring(origin.length) : path;
    const parts: string[] = rest.split('/');
    const stack: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i];
      if (p === '..') {
        if (stack.length > 0) {
          stack.pop();
        }
      } else if (p !== '.' && p.length > 0) {
        stack.push(p);
      }
    }
    return origin + '/' + stack.join('/');
  }
}
