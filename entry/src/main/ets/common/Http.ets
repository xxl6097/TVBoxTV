import http from '@ohos.net.http';
import { Net } from './Net';

const UA: string = 'Mozilla/5.0 (Linux; HarmonyOS; SmartScreen) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

class Resp {
  code: number = 0;
  body: string = '';
  location: string = '';
}

/** 精简 HTTP 客户端：GET + 手写重定向跟随 + 中文错误提示 */
export class Http {
  static async text(url: string, extra?: Record<string, string>, timeout?: number): Promise<string> {
    const ms: number = timeout === undefined ? 12000 : timeout;
    // 总预算：timeout 是「这次请求最多花多久」，不是「每一跳各自能花多久」。
    // 原来 3 跳 × ms，用户明显感觉比设定值慢 3 倍。
    const deadline: number = Date.now() + ms;
    let cur: string = url;
    let last: Resp = new Resp();
    let tried: number = 0;
    let moreRedirect: boolean = false;
    for (let hop = 0; hop < 3; hop++) {
      const left: number = Http.leftOf(deadline, ms);
      if (left <= 0) {
        break;
      }
      last = await Http.once(cur, extra, left);
      tried++;
      moreRedirect = false;
      if (last.code >= 300 && last.code < 400 && last.location.length > 0) {
        cur = Http.abs(cur, last.location);
        moreRedirect = true;
        continue;
      }
      break;
    }
    // 一次都没发出去，或重定向还没跟完预算就用完了 —— 都算超时，
    // 不能把 3xx 的空 body 当正文返回（上层会当成「接口返回空数据」）
    if (tried === 0 || moreRedirect) {
      throw new Error('网络超时，请检查网络后重试');
    }
    if (last.code === 0) {
      return last.body;
    }
    if (last.code >= 400) {
      let hint: string = '';
      if (last.code === 403) {
        hint = '，被站点拒绝（可能需要 Referer 或已限制地区）';
      } else if (last.code === 429) {
        hint = '，请求过于频繁被限流';
      } else if (last.code === 404) {
        hint = '，接口不存在（数据源可能已失效）';
      }
      throw new Error('HTTP ' + last.code + hint);
    }
    return last.body;
  }

  /**
   * 只抓首包（前 4KB），用来判断一个流地址「活不活」和「快不快」。
   *
   * 为什么不直接用 text()：直播地址 302 到 mp4 时会整段下载，几秒都回不来。
   * 这里带 Range 头，读超时一到就 destroy，拿多少算多少。
   * 抛异常 = 连不上；返回空串 = 服务端给了 4xx/5xx。
   */
  static async peek(url: string, ms: number): Promise<string> {
    let cur: string = url;
    // 直播源大量用 302 反盗链跳转（源站地址 → 真实 CDN 地址）。
    // 不跟随重定向时，这类流拿到的是 302 空响应，被 probe 误判成失效，
    // 进而自动跳台——用户点 A 台却播 B 台。这里手动跟随（最多 3 跳）。
    //
    // ms 是「整次探测」的预算，不是每跳各算一份。原来是每跳各 ms，
    // 40 个频道探活最坏变成 3 倍时长，连取消都做不到。
    const deadline: number = Date.now() + ms;
    for (let hop = 0; hop < 3; hop++) {
      const left: number = Http.leftOf(deadline, ms);
      if (left <= 0) {
        return '';
      }
      const r: string = await Http.peekOnce(cur, left);
      if (r.startsWith('#REDIRECT:')) {
        cur = Http.abs(cur, r.substring(9));
        continue;
      }
      return r;
    }
    return '';
  }

  private static async peekOnce(url: string, ms: number): Promise<string> {
    const req = http.createHttp();
    try {
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': UA,
          'Accept': '*/*',
          'Range': 'bytes=0-4095'
        },
        connectTimeout: ms,
        readTimeout: ms,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false
      };
      const res = await req.request(url, opt);
      if (res.responseCode >= 400) {
        return '';
      }
      if (res.responseCode >= 300 && res.responseCode < 400) {
        const h = res.header as Record<string, string>;
        const keys: string[] = Object.keys(h);
        for (let i = 0; i < keys.length; i++) {
          if (keys[i].toLowerCase() === 'location') {
            return '#REDIRECT:' + String(h[keys[i]]);
          }
        }
        return '';
      }
      if (typeof res.result !== 'string') {
        return '#BIN';
      }
      const s: string = res.result as string;
      return s.length > 4096 ? s.substring(0, 4096) : s;
    } catch (err) {
      const e = err as Error;
      throw new Error('连接失败：' + Http.humanize(e.message));
    } finally {
      req.destroy();
    }
  }

  /**
   * WebDAV PROPFIND：列目录 / 探测连接。
   *
   * http.RequestMethod 枚举只有 OPTIONS/GET/HEAD/POST/PUT/DELETE/TRACE/CONNECT
   * 八个，没有 PROPFIND；但底层网络栈走的是 libcurl 语义（CURLOPT_CUSTOMREQUEST），
   * 接受任意 method 字符串。这里用双重断言把 'PROPFIND' 塞进去。
   * Depth: 1 表示列当前目录的直接子项（不递归）。
   */
  static async propfind(url: string, extra: Record<string, string> | undefined, timeout?: number): Promise<string> {
    const ms: number = timeout === undefined ? 15000 : timeout;
    const req = http.createHttp();
    try {
      const header: Record<string, string> = { 'User-Agent': UA, 'Depth': '1' };
      if (extra !== undefined) {
        const keys: string[] = Object.keys(extra);
        for (let i = 0; i < keys.length; i++) {
          header[keys[i]] = extra[keys[i]];
        }
      }
      const opt: http.HttpRequestOptions = {
        method: 'PROPFIND' as http.RequestMethod,
        header: header,
        connectTimeout: ms,
        readTimeout: ms,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false
      };
      const res = await req.request(url, opt);
      if (res.responseCode >= 400) {
        let hint: string = '';
        if (res.responseCode === 401) {
          hint = '，用户名或密码错误';
        } else if (res.responseCode === 403) {
          hint = '，无权限访问该路径';
        } else if (res.responseCode === 404) {
          hint = '，路径不存在';
        }
        throw new Error('WebDAV HTTP ' + res.responseCode + hint);
      }
      if (typeof res.result === 'string') {
        return res.result as string;
      }
      return '';
    } catch (err) {
      const e = err as Error;
      if (e.message.indexOf('WebDAV HTTP') === 0) {
        throw e;
      }
      throw new Error('WebDAV 请求失败：' + e.message);
    } finally {
      req.destroy();
    }
  }

  /**
   * WebDAV PUT 上传文件。用于历史记录云同步。
   * 成功返回 true，失败返回 false（不抛异常，调用方用于后台静默同步）。
   */
  static async put(url: string, body: string, extra?: Record<string, string>, timeout?: number): Promise<boolean> {
    const ms: number = timeout === undefined ? 10000 : timeout;
    const req = http.createHttp();
    try {
      const header: Record<string, string> = { 'User-Agent': UA, 'Content-Type': 'application/json; charset=utf-8' };
      if (extra !== undefined) {
        const keys: string[] = Object.keys(extra);
        for (let i = 0; i < keys.length; i++) {
          header[keys[i]] = extra[keys[i]];
        }
      }
      const res = await req.request(url, {
        method: 'PUT' as http.RequestMethod,
        header: header,
        connectTimeout: ms,
        readTimeout: ms,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        extraData: body
      } as http.HttpRequestOptions);
      return res.responseCode >= 200 && res.responseCode < 300;
    } catch (err) {
      return false;
    } finally {
      req.destroy();
    }
  }

  private static async once(url: string, extra: Record<string, string> | undefined, ms: number): Promise<Resp> {    const req = http.createHttp();
    const r = new Resp();
    try {
      const header: Record<string, string> = { 'User-Agent': UA, 'Accept': '*/*' };
      if (extra !== undefined) {
        for (const k of Object.keys(extra)) {
          header[k] = extra[k];
        }
      }
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: ms,
        readTimeout: ms,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false
      };
      const res = await req.request(url, opt);
      r.code = res.responseCode;
      if (typeof res.result === 'string') {
        r.body = res.result as string;
      }
      const h = res.header as Record<string, string>;
      const keys: string[] = Object.keys(h);
      for (let i = 0; i < keys.length; i++) {
        if (keys[i].toLowerCase() === 'location') {
          r.location = String(h[keys[i]]);
        }
      }
    } catch (err) {
      const e = err as Error;
      throw new Error('网络请求失败：' + Http.humanize(e.message));
    } finally {
      req.destroy();
    }
    return r;
  }

  /**
   * 算出这一跳还能用多少毫秒。0 表示预算已耗尽，调用方应收手。
   * 剩得太少时给一个最小可用值——刚发出去就必然超时的请求毫无意义；
   * 但不会无限续期：下一跳重新算又会归零，所以最多多花一跳的余量。
   */
  private static leftOf(deadline: number, totalMs: number): number {
    const left: number = deadline - Date.now();
    if (left <= 0) {
      return 0;
    }
    if (left >= 600) {
      return left;
    }
    return totalMs < 600 ? totalMs : 600;
  }

  private static abs(base: string, loc: string): string {
    if (loc.startsWith('http://') || loc.startsWith('https://')) {
      return loc;
    }
    const i: number = base.indexOf('://');
    if (i < 0) {
      return loc;
    }
    const slash: number = base.indexOf('/', i + 3);
    if (loc.startsWith('/')) {
      return slash < 0 ? base.substring(0, base.length) + loc : base.substring(0, slash) + loc;
    }
    return slash < 0 ? base + '/' + loc : base.substring(0, slash + 1) + loc;
  }

  /** 把底层网络库的英文错误翻译成用户能看懂的中文 */
  private static humanize(msg: string): string {
    // 先看系统层面到底有没有网：断网时底层报的是「connect fail / unreachable」
    // 之类的笼统错误，照翻成「无法连接服务器」会让人以为是对方站点挂了，
    // 跑去换源、清缓存，其实只是没连上 WiFi。
    if (!Net.online()) {
      return '当前没有网络连接，请检查 WiFi 或网线';
    }
    const m: string = msg.toLowerCase();
    // 超时类
    if (m.indexOf('timeout') >= 0 || m.indexOf('timed out') >= 0) {
      return '网络超时，请检查网络后重试';
    }
    // 连接失败类
    if (m.indexOf('connect') >= 0 && m.indexOf('fail') >= 0) {
      return '无法连接服务器，请检查网络或稍后再试';
    }
    if (m.indexOf('refused') >= 0 || m.indexOf('reject') >= 0) {
      return '连接被拒绝，服务器可能未启动或不可用';
    }
    if (m.indexOf('unreachable') >= 0 || m.indexOf('network is') >= 0) {
      return '网络不可达，请检查网络连接';
    }
    // DNS类
    if (m.indexOf('resolve') >= 0 || m.indexOf('getaddrinfo') >= 0 || m.indexOf('enotfound') >= 0) {
      return '域名解析失败，请检查网络或域名是否正确';
    }
    // SSL/TLS类
    if (m.indexOf('ssl') >= 0 || m.indexOf('certificate') >= 0 || m.indexOf('handshake') >= 0) {
      return 'SSL/TLS证书验证失败，可能网络劫持或服务器配置问题';
    }
    // 其他类
    if (m.indexOf('reset') >= 0 || m.indexOf('broken pipe') >= 0) {
      return '连接中断，请重试';
    }
    if (m.indexOf('abort') >= 0 || m.indexOf('cancel') >= 0) {
      return '请求已取消';
    }
    // 兜底：返回简化后的原始错误（去掉冗长的堆栈信息）
    const firstLine = msg.split('\n')[0];
    return firstLine.length > 100 ? firstLine.substring(0, 100) + '...' : firstLine;
  }
}
