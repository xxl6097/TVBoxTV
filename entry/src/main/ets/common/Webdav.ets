import { WebdavSource, WebdavEntry, WebdavVod, WebdavEp } from './Model';
import { Http } from './Http';
import { Cms } from './Cms';

/**
 * WebDAV 客户端 + 影视资源识别。
 *
 * 列目录用 PROPFIND（返回 multistatus XML），读文件/播放走普通 GET（带 Basic Auth）。
 * 识别：递归扫描目录树，把视频文件按命名规范聚合成「电影 / 剧集」。
 */

/** 常见视频扩展名（小写） */
const VIDEO_EXT: string[] = ['mp4', 'mkv', 'avi', 'ts', 'm2ts', 'mts', 'mov', 'wmv', 'flv',
  'rmvb', 'rm', 'm4v', 'webm', '3gp', 'mpg', 'mpeg', 'vob', 'm2t', 'f4v'];

/** 一个文件名解析出的影视元信息 */
class Parsed {
  title: string = '';
  season: number = 0;
  episode: number = 0;
  year: string = '';
  isSeries: boolean = false;
}

export class Webdav {
  private static readonly B64: string =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  // ==================== 认证与 URL ====================

  /** 纯实现 base64（UTF-8），用于 Basic Auth，不依赖额外 API */
  static base64(s: string): string {
    const bytes: number[] = [];
    for (let i = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      if (c < 0x80) {
        bytes.push(c);
      } else if (c < 0x800) {
        bytes.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
      } else {
        bytes.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
      }
    }
    let out: string = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const b0: number = bytes[i];
      const b1: number = i + 1 < bytes.length ? bytes[i + 1] : -1;
      const b2: number = i + 2 < bytes.length ? bytes[i + 2] : -1;
      out += Webdav.B64.charAt(b0 >> 2);
      out += Webdav.B64.charAt(((b0 & 3) << 4) | (b1 >= 0 ? (b1 >> 4) : 0));
      out += b1 >= 0 ? Webdav.B64.charAt(((b1 & 15) << 2) | (b2 >= 0 ? (b2 >> 6) : 0)) : '=';
      out += b2 >= 0 ? Webdav.B64.charAt(b2 & 63) : '=';
    }
    return out;
  }

  /** Basic Auth header；用户名空则不给（匿名访问） */
  static authHeader(src: WebdavSource): Record<string, string> {
    if (src.user.length === 0) {
      return {};
    }
    const h: Record<string, string> = {};
    h['Authorization'] = 'Basic ' + Webdav.base64(src.user + ':' + src.pass);
    return h;
  }

  /** 逐段 URL 编码路径，保留 '/' */
  static encodePath(p: string): string {
    if (p.length === 0) {
      return '/';
    }
    const parts: string[] = p.split('/');
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].length > 0) {
        out.push(encodeURIComponent(parts[i]));
      }
    }
    return '/' + out.join('/');
  }

  /** 服务器返回的 href 可能已编码（含 %），用户输入的根路径未编码，这里统一处理 */
  private static safePath(p: string): string {
    if (p.indexOf('%') >= 0) {
      return p;
    }
    return Webdav.encodePath(p);
  }

  /**
   * 提取 origin：scheme://host:port（去路径部分）。
   *
   * 为什么所有绝对 href 都用 origin 拼而不是用 src.url 拼：WebDAV 服务器
   * （极空间 / Alist / 群晖等）返回的 href 是「服务器根开始的完整绝对路径」，
   * 如 `/dav/迅雷下载/电影/`。而用户填的 url 可能已经带了路径前缀
   * （`https://host/dav/迅雷下载/`），拿 url 去拼绝对 href 会把 `/dav/迅雷下载`
   * 重复一遍，得到 `/dav/迅雷下载/dav/迅雷下载/…`，必然 404。
   */
  static originOf(url: string): string {
    const i: number = url.indexOf('://');
    if (i < 0) {
      return url;
    }
    const rest: string = url.substring(i + 3);
    const slash: number = rest.indexOf('/');
    return slash < 0 ? url : url.substring(0, i + 3 + slash);
  }

  /** url 的路径部分（保留原样，可能带尾斜杠；无路径时返回 '/'） */
  static urlPath(url: string): string {
    const i: number = url.indexOf('://');
    if (i < 0) {
      return '/';
    }
    const rest: string = url.substring(i + 3);
    const slash: number = rest.indexOf('/');
    return slash < 0 ? '/' : rest.substring(slash);
  }

  /** 去掉尾部斜杠（根 '/' 保持不动） */
  static stripSlash(p: string): string {
    if (p === '/' || p.length === 0) {
      return '/';
    }
    return p.endsWith('/') ? p.substring(0, p.length - 1) : p;
  }

  /**
   * 挂载根对应的「服务器绝对路径」（percent-encoded，不带尾斜杠）。
   *
   * 把用户填的 url（可能带路径前缀）与 root 合并成一个从 origin 开始的完整路径，
   * 之后所有内部路径（curPath、entry.href）都用这个语义，避免前缀重复。
   */
  static mountHref(src: WebdavSource): string {
    let base: string = Webdav.stripSlash(Webdav.safePath(Webdav.urlPath(src.url)));
    const root: string = src.root === undefined ? '' : src.root.trim();
    if (root.length === 0 || root === '/') {
      return base;
    }
    let r: string = root;
    if (!r.startsWith('/')) {
      r = '/' + r;
    }
    const rootEnc: string = Webdav.safePath(r);
    // 用户把完整路径（含 url 前缀）填进了 root，直接用它，避免二次拼接
    const baseSlash: string = base === '/' ? '/' : base + '/';
    if (rootEnc === base || rootEnc.startsWith(baseSlash)) {
      return Webdav.stripSlash(rootEnc);
    }
    if (base === '/') {
      return Webdav.stripSlash(rootEnc);
    }
    return base + rootEnc;
  }

  /** href → 完整 URL。href 是服务器绝对路径（已编码），用 origin 拼接。 */
  static absUrl(src: WebdavSource, href: string): string {
    if (href.startsWith('http://') || href.startsWith('https://')) {
      return href;
    }
    const origin: string = Webdav.originOf(src.url);
    if (href.startsWith('/')) {
      return origin + href;
    }
    return origin + '/' + href;
  }

  // ==================== 目录 ====================

  /** PROPFIND 列目录，返回直接子项（已排除当前目录自身） */
  static async list(src: WebdavSource, path: string): Promise<WebdavEntry[]> {
    // path 是服务器绝对路径（已编码），用 origin 拼请求 URL，不再用 src.url 拼
    const origin: string = Webdav.originOf(src.url);
    const url: string = origin + (path.startsWith('/') ? path : '/' + path);
    const xml: string = await Http.propfind(url, Webdav.authHeader(src), 15000);
    const all: WebdavEntry[] = Webdav.xmlList(xml);
    const out: WebdavEntry[] = [];
    // 排除「当前目录自己」那条（统一去尾斜杠后比较）
    const self: string = Webdav.stripSlash(path);
    for (let i = 0; i < all.length; i++) {
      const e: WebdavEntry = all[i];
      if (Webdav.stripSlash(e.href) === self) {
        continue;
      }
      out.push(e);
    }
    return out;
  }

  /** 测试连接：列挂载根，成功返回条目数，失败抛异常 */
  static async probe(src: WebdavSource): Promise<number> {
    const root: string = Webdav.mountHref(src);
    const list: WebdavEntry[] = await Webdav.list(src, root);
    return list.length;
  }

  // ==================== 影视识别 ====================

  static isVideo(name: string): boolean {
    const dot: number = name.lastIndexOf('.');
    if (dot < 0) {
      // 无扩展名：极空间等 NAS 会把无扩展名视频（如「异星战境 Atlas」）
      // 暴露成普通文件（resourcetype 非 collection），按视频处理，否则会漏。
      return true;
    }
    const ext: string = name.substring(dot + 1).toLowerCase();
    return VIDEO_EXT.indexOf(ext) >= 0;
  }

  /** 从绝对 href 取最后一段目录名（URL 解码后） */
  static dirName(href: string): string {
    const h: string = Webdav.stripSlash(href);
    const i: number = h.lastIndexOf('/');
    let name: string = i >= 0 ? h.substring(i + 1) : h;
    try {
      name = decodeURIComponent(name);
    } catch (err) {
      // 解码失败保留原文
    }
    return name;
  }

  /** 清理目录名里的季/卷序号前缀，如「01 风起天南」→「风起天南」 */
  static cleanDirName(name: string): string {
    return name.replace(/^\d{1,3}\s*[-_ ]?\s*/, '').trim();
  }

  /** 从 href 取所在目录（去掉最后一段） */
  private static dirOf(href: string): string {
    const i: number = href.lastIndexOf('/');
    return i > 0 ? href.substring(0, i) : '/';
  }

  /** 解析文件名 → 影视元信息 */
  static parse(name: string): Parsed {
    const p = new Parsed();
    let base: string = name;
    const dot: number = base.lastIndexOf('.');
    if (dot > 0) {
      const ext: string = base.substring(dot + 1).toLowerCase();
      if (VIDEO_EXT.indexOf(ext) >= 0) {
        base = base.substring(0, dot);
      }
    }

    // 纯数字文件名（1.mp4 / 01.mp4 / 001.mp4）：集号 = 数字，
    // 片名留空，由扫描时用父目录名补（如「凡人修仙传/01 风起天南/1.mp4」）。
    const pure: RegExpMatchArray | null = base.match(/^\s*(\d{1,4})\s*$/);
    if (pure !== null) {
      p.episode = parseInt(pure[1], 10);
      p.isSeries = true;
      p.title = '';
      return p;
    }

    // 年份
    const ym: RegExpMatchArray | null = base.match(/((?:19|20)\d{2})/);
    if (ym !== null) {
      p.year = ym[1];
      base = base.replace(ym[1], ' ');
    }

    // 剧集：SxxExx 优先，其次 第xx集，再 E/EPxx，最后末尾纯数字
    const sm: RegExpMatchArray | null = base.match(/[Ss](\d{1,2})\s*[Ee](\d{1,3})/);
    if (sm !== null) {
      p.season = parseInt(sm[1], 10);
      p.episode = parseInt(sm[2], 10);
      p.isSeries = true;
      base = base.replace(sm[0], ' ');
    } else {
      const cm: RegExpMatchArray | null = base.match(/第\s*(\d{1,3})\s*[集話话]/);
      if (cm !== null) {
        p.episode = parseInt(cm[1], 10);
        p.isSeries = true;
        base = base.replace(cm[0], ' ');
      } else {
        const em: RegExpMatchArray | null = base.match(/[Ee][Pp]?\s*(\d{1,3})\b/);
        if (em !== null) {
          p.episode = parseInt(em[1], 10);
          p.isSeries = true;
          base = base.replace(em[0], ' ');
        } else {
          const tail: RegExpMatchArray | null = base.match(/(?:[._\-\s])(\d{1,3})\s*$/);
          if (tail !== null) {
            const n: number = parseInt(tail[1], 10);
            if (n > 0 && n <= 999) {
              p.episode = n;
              p.isSeries = true;
              base = base.substring(0, base.length - tail[0].length);
            }
          }
        }
      }
    }

    p.title = Webdav.cleanTitle(base);
    return p;
  }

  /** 清理分辨率/编码标签，分隔符换空格，得到干净片名 */
  static cleanTitle(s: string): string {
    let t: string = s;
    t = t.replace(/1080[pi]|720[pi]|2160[pi]|480[pi]|576[pi]|4[Kk]|8[Kk]/g, ' ');
    t = t.replace(/x26[45]|h26[45]|hevc|hdr10?|10bit|8bit|aac|dts|dd5\.1|truehd|atmos|bluray|blu-ray|web-?dl|webrip|remux|proper|repack/g, ' ');
    t = t.replace(/[._\[\]()（）\-]+/g, ' ');
    t = t.replace(/\s{2,}/g, ' ').trim();
    return t;
  }

  /**
   * 递归扫描目录树，识别影视并聚合。
   *
   * maxDepth 限制递归层数；dirBudget 限制最多扫描的目录总数（防止超大目录
   * 把扫描拖到几分钟）；每批并发 BATCH 个 PROPFIND，既提速又不压垮服务器。
   * onProgress 可选，回调 (已扫目录数, 已发现视频数)，用于界面进度反馈。
   */
  static async scan(src: WebdavSource, maxDepth: number,
    onProgress?: (dirs: number, files: number) => void): Promise<WebdavVod[]> {
    const root: string = Webdav.mountHref(src);
    const files: WebdavEntry[] = [];
    const DIR_BUDGET: number = 200;
    const BATCH: number = 6;
    let current: string[] = [root];
    let depth: number = 0;
    let scanned: number = 0;

    while (current.length > 0 && depth <= maxDepth && scanned < DIR_BUDGET) {
      const next: string[] = [];
      // 分批并发列目录：每批最多 BATCH 个，避免同时打爆服务器
      for (let b = 0; b < current.length; b += BATCH) {
        const slice: string[] = [];
        for (let k = b; k < current.length && k < b + BATCH; k++) {
          slice.push(current[k]);
        }
        const results: WebdavEntry[][] = await Promise.all(slice.map(async (dir: string): Promise<WebdavEntry[]> => {
          try {
            return await Webdav.list(src, dir);
          } catch (e) {
            return [];   // 单个目录失败不中断整体扫描
          }
        }));
        for (let i = 0; i < results.length; i++) {
          const entries: WebdavEntry[] = results[i];
          for (let k = 0; k < entries.length; k++) {
            const e: WebdavEntry = entries[k];
            if (e.isDir) {
              next.push(e.href);
            } else if (Webdav.isVideo(e.name)) {
              files.push(e);
            }
          }
        }
      }
      scanned += current.length;
      if (onProgress !== undefined) {
        onProgress(scanned, files.length);
      }
      current = next;
      depth++;
    }

    // 聚合：剧集按 (目录+片名) 归组；电影/单集每条独立
    const vods: WebdavVod[] = [];
    const idx: Record<string, number> = {};
    for (let i = 0; i < files.length; i++) {
      const f: WebdavEntry = files[i];
      const p: Parsed = Webdav.parse(f.name);
      const dir: string = Webdav.dirOf(f.href);
      // 纯数字文件名（1.mp4…）parse 出来的片名是空的，用父目录名补片名
      let title: string = p.title;
      if (title.length === 0 && p.isSeries) {
        title = Webdav.cleanDirName(Webdav.dirName(dir));
      }
      const key: string = p.isSeries ? (dir + '|' + title) : ('#' + i);
      let pos: number = -1;
      const has: number | undefined = idx[key];
      if (has === undefined) {
        const v = new WebdavVod();
        v.name = title.length > 0 ? title : Webdav.stripExt(f.name);
        v.kind = p.isSeries ? 'series' : 'movie';
        v.year = p.year;
        v.dir = dir;
        vods.push(v);
        pos = vods.length - 1;
        idx[key] = pos;
      } else {
        pos = has;
      }
      const vod: WebdavVod = vods[pos];
      const ep = new WebdavEp();
      ep.name = f.name;
      ep.url = Webdav.absUrl(src, f.href);
      ep.href = f.href;
      ep.season = p.season;
      ep.episode = p.episode;
      vod.eps.push(ep);
    }

    // 剧集内部按 季 + 集 排序
    for (let i = 0; i < vods.length; i++) {
      if (vods[i].kind === 'series') {
        vods[i].eps.sort((a: WebdavEp, b: WebdavEp): number => {
          if (a.season !== b.season) {
            return a.season - b.season;
          }
          return a.episode - b.episode;
        });
      }
    }
    return vods;
  }

  static stripExt(name: string): string {
    const dot: number = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /** 从 URL 取主机名，作为源的默认名称 */
  static hostOf(url: string): string {
    let s: string = url;
    const p: number = s.indexOf('://');
    if (p >= 0) {
      s = s.substring(p + 3);
    }
    const slash: number = s.indexOf('/');
    if (slash >= 0) {
      s = s.substring(0, slash);
    }
    return s;
  }

  // ==================== XML 解析 ====================

  private static nodeVal(block: string, tag: string): string {
    const re = new RegExp('<' + tag + '>([\\s\\S]*?)</' + tag + '>', 'i');
    const m: RegExpMatchArray | null = block.match(re);
    if (m === null) {
      return '';
    }
    // 返回原始内容，不做 HTML 标签剥离：resourcetype 的值就是 `<collection/>` 这种
    // 自闭合标签，若用 Cms.text 会把标签剥成空串，导致目录判断失效。
    return m[1];
  }

  /** 把 PROPFIND 返回的 multistatus XML 解析成条目列表 */
  private static xmlList(xml: string): WebdavEntry[] {
    const out: WebdavEntry[] = [];
    // 去掉命名空间前缀（D:href → href 等），再用统一的无前缀正则解析
    const t: string = xml.replace(/(<\/?)([A-Za-z]+):/g, '$1');
    const blocks: RegExpMatchArray | null = t.match(/<response>[\s\S]*?<\/response>/gi);
    if (blocks === null) {
      return out;
    }
    for (let i = 0; i < blocks.length; i++) {
      const b: string = blocks[i];
      // href 值做 HTML 实体解码（&amp; → & 等），但 resourcetype 保持原始内容判断 collection
      const href: string = Cms.text(Webdav.nodeVal(b, 'href')).trim();
      if (href.length === 0) {
        continue;
      }
      const rt: string = Webdav.nodeVal(b, 'resourcetype');
      const e = new WebdavEntry();
      e.href = href;
      e.isDir = rt.indexOf('collection') >= 0;
      const sizeStr: string = Webdav.nodeVal(b, 'getcontentlength');
      e.size = sizeStr.length > 0 ? parseInt(sizeStr, 10) : 0;
      e.mtime = Webdav.nodeVal(b, 'getlastmodified');
      // 显示名：href 最后一段，URL 解码（未编码的中文解码会抛错，回退原文）
      let disp: string = href;
      try {
        disp = decodeURIComponent(href);
      } catch (err) {
        disp = href;
      }
      let name: string = disp;
      if (name.endsWith('/')) {
        name = name.substring(0, name.length - 1);
      }
      const slash: number = name.lastIndexOf('/');
      if (slash >= 0) {
        name = name.substring(slash + 1);
      }
      e.name = name.length > 0 ? name : href;
      out.push(e);
    }
    return out;
  }
}
