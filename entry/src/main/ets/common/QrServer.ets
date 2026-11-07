/**
 * 扫码录入用的局域网小服务。
 *
 * 电视上敲地址是最痛苦的一步（遥控器指针输入几十个字符的 URL），
 * 所以这里在电视侧起一个极简 HTTP 服务（TCPSocketServer），把地址做成二维码：
 * 手机扫码 → 打开一个手机端表单页 → 粘贴地址/JSON → 提交 → 电视收到并落盘。
 *
 * 没有云、没有账号、不经过第三方：手机和电视在同一局域网就能用，
 * 提交完页面就关了，服务也只在这个设置页存活期间监听。
 */

import socket from '@ohos.net.socket';
import connection from '@ohos.net.connection';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';

/** 提交回调：kind 为 cfg（点播配置）/ live（直播源），返回给手机看的文案 */
export type SaveFn = (kind: string, value: string) => Promise<string>;

export class QrServer {
  static readonly PORT: number = 8788;

  private static server: socket.TCPSocketServer | null = null;
  private static host: string = '';
  private static fn: SaveFn | null = null;
  private static starting: boolean = false;

  static bind(fn: SaveFn): void {
    QrServer.fn = fn;
  }

  static url(): string {
    return QrServer.host.length > 0 ? ('http://' + QrServer.host + ':' + QrServer.PORT) : '';
  }

  /** 本机局域网 IP。优先取默认网络里的 IPv4，回环地址跳过 */
  static async localIp(): Promise<string> {
    try {
      const net: connection.NetHandle = connection.getDefaultNetSync();
      const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
      const list: connection.LinkAddress[] = props.linkAddresses;
      for (let i = 0; i < list.length; i++) {
        const addr: string = list[i].address.address;
        if (addr.indexOf('.') > 0 && addr.indexOf('127.') !== 0 && addr.indexOf('169.254') !== 0) {
          return addr;
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.info(0x1000, 'BOXN', 'localIp fail %{public}s', e.message);
    }
    return '';
  }

  /** 启动服务，返回可访问地址；失败返回空串 */
  static async start(fn: SaveFn): Promise<string> {
    QrServer.fn = fn;
    if (QrServer.server !== null) {
      // 服务已经在跑：只把写入能力接回来
      return QrServer.url();
    }
    if (QrServer.starting) {
      return '';
    }
    QrServer.starting = true;
    try {
      const ip: string = await QrServer.localIp();
      if (ip.length === 0) {
        return '';
      }
      QrServer.host = ip;
      const srv: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      const addr: socket.NetAddress = { address: '0.0.0.0', port: QrServer.PORT, family: 1 };
      await srv.listen(addr);
      srv.on('connect', (client: socket.TCPSocketConnection) => {
        QrServer.serve(client);
      });
      QrServer.server = srv;
      hilog.info(0x1000, 'BOXN', 'qr server on %{public}s', QrServer.url());
      return QrServer.url();
    } catch (err) {
      const e = err as BusinessError;
      hilog.info(0x1000, 'BOXN', 'qr server start fail code=%{public}d %{public}s', e.code, e.message);
      QrServer.host = '';
      return '';
    } finally {
      QrServer.starting = false;
    }
  }

  /**
   * 页面离开时调用：只断掉「写入」能力，不关闭监听。
   * 端口一旦 listen 就没法在 API 12 上主动释放（close 是 API 20 才有），
   * 关掉连接回调反而会留下无人处理的连接；所以留着监听、让 /save 直接拒绝,
   * 下次再进设置页直接复用同一个服务，也不会撞上「端口已占用」。
   */
  static stop(): void {
    QrServer.fn = null;
  }

  // ==================== 请求处理 ====================

  private static serve(client: socket.TCPSocketConnection): void {
    let acc: string = '';
    let responded: boolean = false;

    const reply = (body: string, type: string): void => {
      if (responded) {
        return;
      }
      responded = true;
      const head: string = 'HTTP/1.1 200 OK\r\n' +
        'Content-Type: ' + type + '; charset=utf-8\r\n' +
        'Content-Length: ' + QrServer.byteLen(body) + '\r\n' +
        'Cache-Control: no-store\r\n' +
        'Connection: close\r\n\r\n';
      client.send({ data: head + body }).then(() => {
        setTimeout(() => {
          QrServer.shut(client);
        }, 150);
      }).catch(() => {
        QrServer.shut(client);
      });
    };

    client.on('message', (info: socket.SocketMessageInfo) => {
      acc += QrServer.decode(info.message);
      const split: number = acc.indexOf('\r\n\r\n');
      if (split < 0) {
        return;
      }
      const head: string = acc.substring(0, split);
      const body: string = acc.substring(split + 4);
      const lines: string[] = head.split('\r\n');
      const first: string = lines.length > 0 ? lines[0] : '';
      const parts: string[] = first.split(' ');
      const method: string = parts.length > 0 ? parts[0] : 'GET';
      const target: string = parts.length > 1 ? parts[1] : '/';

      // 表单体是 x-www-form-urlencoded（纯 ASCII），所以字符数即字节数
      let need: number = 0;
      for (let i = 1; i < lines.length; i++) {
        const ln: string = lines[i].toLowerCase();
        if (ln.indexOf('content-length:') === 0) {
          const n: number = parseInt(ln.substring(15).trim(), 10);
          need = isNaN(n) ? 0 : n;
        }
      }
      if (body.length < need) {
        return;
      }

      const path: string = target.split('?')[0];
      if (path === '/save') {
        QrServer.handleSave(body, reply);
        return;
      }
      if (path === '/cur') {
        QrServer.handleCur(reply);
        return;
      }
      if (path === '/favicon.ico') {
        reply('', 'text/plain');
        return;
      }
      // 二维码里带了 ?t=cfg / ?t=live，手机打开时直接把对应的输入框顶到最前并聚焦，
      // 省得用户在两个框之间找「我刚才点的是哪一个」
      const qi: number = target.indexOf('?');
      const kind: string = qi >= 0 ? QrServer.field(target.substring(qi + 1), 't') : '';
      reply(QrServer.page(kind), 'text/html');
      hilog.info(0x1000, 'BOXN', 'qr req %{public}s %{public}s', method, path);
    });
  }

  private static shut(client: socket.TCPSocketConnection): void {
    try {
      client.off('message');
    } catch (e) {
      // 忽略
    }
    try {
      client.close();
    } catch (e) {
      // 忽略
    }
  }

  private static async handleSave(body: string, reply: (b: string, t: string) => void): Promise<void> {
    const kind: string = QrServer.field(body, 't');
    const value: string = QrServer.field(body, 'v');
    if (kind.length === 0 || value.length === 0) {
      reply('{"ok":false,"msg":"参数不全，请重新填写"}', 'application/json');
      return;
    }
    const fn: SaveFn | null = QrServer.fn;
    if (fn === null) {
      reply('{"ok":false,"msg":"电视端界面已关闭，请重新打开设置页"}', 'application/json');
      return;
    }
    try {
      const msg: string = await fn(kind, value);
      reply('{"ok":true,"msg":' + JSON.stringify(msg) + '}', 'application/json');
    } catch (err) {
      const e = err as Error;
      reply('{"ok":false,"msg":' + JSON.stringify('保存失败：' + e.message) + '}', 'application/json');
    }
  }

  private static async handleCur(reply: (b: string, t: string) => void): Promise<void> {
    reply('{"url":"' + QrServer.url() + '"}', 'application/json');
  }

  /** 从 form-urlencoded 体里取字段 */
  private static field(body: string, key: string): string {
    const parts: string[] = body.split('&');
    for (let i = 0; i < parts.length; i++) {
      const eq: number = parts[i].indexOf('=');
      if (eq < 0) {
        continue;
      }
      if (parts[i].substring(0, eq) === key) {
        const raw: string = parts[i].substring(eq + 1);
        try {
          return decodeURIComponent(raw.replace(/\+/g, ' '));
        } catch (e) {
          return raw;
        }
      }
    }
    return '';
  }

  private static decode(buf: ArrayBuffer): string {
    try {
      const dec: util.TextDecoder = util.TextDecoder.create('utf-8');
      return dec.decodeToString(new Uint8Array(buf));
    } catch (e) {
      return '';
    }
  }

  private static byteLen(s: string): number {
    try {
      const enc: util.TextEncoder = new util.TextEncoder();
      return enc.encodeInto(s).length;
    } catch (e) {
      return s.length;
    }
  }

  /**
   * 手机端表单页。
   * kind = cfg / live 时，把对应那块排到最前并自动聚焦，其余那块折叠到下面。
   */
  private static page(kind: string): string {
    const css: string =
      'body{margin:0;padding:20px 16px 40px;background:#141218;color:#fff;' +
      'font-family:-apple-system,BlinkMacSystemFont,"HarmonyOS Sans",sans-serif;font-size:16px}' +
      'h1{font-size:19px;margin:0 0 4px}' +
      '.sub{color:#B3FFFFFF;font-size:13px;margin-bottom:18px;line-height:1.5}' +
      '.card{background:#1C1B1F;border-radius:14px;padding:16px;margin-bottom:16px}' +
      '.card h2{font-size:15px;margin:0 0 8px;color:#FFEB3B}' +
      '.card.dim{opacity:.55}' +
      'textarea{width:100%;box-sizing:border-box;min-height:92px;background:#26242B;color:#fff;' +
      'border:1px solid #3A3841;border-radius:10px;padding:10px;font-size:14px;line-height:1.5}' +
      'button{width:100%;margin-top:12px;height:46px;border:0;border-radius:23px;' +
      'background:#FFFFFF;color:#141218;font-size:16px;font-weight:600}' +
      '.st{font-size:13px;margin-top:10px;color:#B3FFFFFF;word-break:break-all;line-height:1.5}';
    const js: string =
      '<script>' +
      'function sub(k){var el=document.getElementById(k);var v=el.value.trim();' +
      'var st=document.getElementById(k+"-st");' +
      'if(!v){st.textContent="先填入地址再提交";return;}' +
      'st.textContent="提交中…";st.style.color="#B3FFFFFF";' +
      'fetch("/save",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},' +
      'body:"t="+k+"&v="+encodeURIComponent(v)}).then(function(r){return r.json();})' +
      '.then(function(d){st.textContent=d.msg;st.style.color=d.ok?"#7ee787":"#ff7b72";' +
      'if(d.ok){el.value="";}}).catch(function(e){st.textContent="提交失败："+e;st.style.color="#ff7b72";});}' +
      '</script>';

    // 直连播放：只给一张「视频地址」卡片，提交后电视直接开播
    if (kind === 'play') {
      const playCard: string =
        '<div class="card"><h2>视频地址</h2>' +
        '<textarea id="play" placeholder="http(s) 的 m3u8 / mp4 地址"></textarea>' +
        '<button onclick="sub(\'play\')">提交并播放</button>' +
        '<div class="st" id="play-st"></div></div>';
      const html: string =
        '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">' +
        '<meta name="viewport" content="width=device-width,initial-scale=1">' +
        '<title>夜帧影视 · 直连播放</title><style>' + css + '</style></head><body>' +
        '<h1>夜帧影视 · 直连播放</h1>' +
        '<div class="sub">粘一个视频地址，提交后电视立刻开始播放。</div>' +
        playCard + js +
        '<script>setTimeout(function(){var e=document.getElementById("play");if(e){e.focus();}},120);</script>' +
        '</body></html>';
      return html;
    }

    const subCard: string =
      '<div class="card' + (kind === 'sub' ? '' : ' dim') + '"><h2>订阅链接</h2>' +
      '<textarea id="sub" placeholder="订阅链接（https://…，一份同时含点播站源和直播源的 JSON）"></textarea>' +
      '<button onclick="sub(\'sub\')">订阅</button>' +
      '<div class="st" id="sub-st"></div></div>';
    const cfgCard: string =
      '<div class="card' + (kind === 'live' ? ' dim' : '') + '"><h2>点播配置地址</h2>' +
      '<textarea id="cfg" placeholder="TVBox 配置地址（http/https 的 JSON），也可以直接粘贴整段 JSON"></textarea>' +
      '<button onclick="sub(\'cfg\')">提交点播配置</button>' +
      '<div class="st" id="cfg-st"></div></div>';
    const liveCard: string =
      '<div class="card' + (kind === 'cfg' ? ' dim' : '') + '"><h2>直播源地址</h2>' +
      '<textarea id="live" placeholder="m3u / txt 直播源地址"></textarea>' +
      '<button onclick="sub(\'live\')">提交直播源</button>' +
      '<div class="st" id="live-st"></div></div>';

    const live: boolean = kind === 'live';
    const isSub: boolean = kind === 'sub';
    // 订阅：订阅卡在最前，点播/直播两张折叠到下面；点播/直播各自顶到最前。
    const first: string = isSub ? subCard : (live ? liveCard : cfgCard);
    const second: string = isSub ? (cfgCard + liveCard) : (live ? cfgCard : liveCard);
    const head: string = kind.length === 0
      ? '在这里填好点「提交」，电视上会立刻生效，不用再用遥控器敲字。'
      : (isSub ? '你在电视上点的是「订阅」，粘一个订阅链接提交，点播站源和直播源一起更新。'
        : (live ? '你在电视上点的是「直播源」，把 m3u / txt 地址粘到下面提交即可。'
          : '你在电视上点的是「点播配置」，把配置地址或整段 JSON 粘到下面提交即可。'));
    const focus: string = '<script>setTimeout(function(){var e=document.getElementById("' +
      (isSub ? 'sub' : (live ? 'live' : 'cfg')) + '");if(e){e.focus();}},120);</script>';

    const html: string =
      '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<title>夜帧影视 · 扫码录入</title><style>' + css + '</style></head><body>' +
      '<h1>夜帧影视 · 手机录入</h1>' +
      '<div class="sub">' + head + '</div>' +
      first + second + js + focus + '</body></html>';
    return html;
  }
}
