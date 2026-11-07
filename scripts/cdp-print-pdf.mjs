#!/usr/bin/env node
// 用 Chrome DevTools Protocol 把 HTML 打印成 PDF，支持自定义页眉 / 页脚页码。
//
// 为什么不用 `chrome --print-to-pdf`：那个只能输出默认页眉（左侧日期 + 右侧标题）
// 和默认页脚（左侧 file:// URL + 右侧页码），URL 印在每页页脚很难看，也不符合
// 软著「页眉写软件名称与版本、页脚连续页码」的要求。
// CDP 的 Page.printToPDF 支持 headerTemplate / footerTemplate，可以精确排版。
//
// 用法：node scripts/cdp-print-pdf.mjs <input.html> <output.pdf> [页眉文字]
//
// 依赖：Node 18+（内置 fetch 与 WebSocket，本机 Node 22 满足）。

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const [, , htmlPath, outPath, headerText] = process.argv;

if (!htmlPath || !outPath) {
  console.error('用法: node scripts/cdp-print-pdf.mjs <input.html> <output.pdf> [页眉文字]');
  process.exit(2);
}

// 随机端口 + 独立 profile，避免与残留的 Chrome 实例抢端口 / 抢锁
const PORT = 9300 + Math.floor(Math.random() * 500);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'hmy-cdp-'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const LOG = path.join(os.tmpdir(), 'hmy-cdp-print.log');
fs.writeFileSync(LOG, '');
const log = (s) => {
  try { fs.appendFileSync(LOG, s + '\n'); } catch {}
  console.log(s);
};

const chrome = spawn(
  CHROME,
  [
    '--headless=new',
    '--no-sandbox',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    '--hide-scrollbars',
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${profile}`,
    'about:blank',
  ],
  { stdio: 'ignore' }
);

let cleaned = false;
function cleanup() {
  if (cleaned) return;
  cleaned = true;
  try { chrome.kill('SIGKILL'); } catch {}
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch {}
}
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(130); });

async function pageWsUrl() {
  for (let i = 0; i < 80; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json`);
      if (r.ok) {
        const list = await r.json();
        const page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
        if (page) return page.webSocketDebuggerUrl;
      }
    } catch {}
    await sleep(200);
  }
  throw new Error('Chrome DevTools 未就绪');
}

function client(ws) {
  let seq = 0;
  const pending = new Map();
  const events = new Map();
  ws.addEventListener('message', (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(msg.error.message));
      else resolve(msg.result);
    } else if (msg.method) {
      for (const cb of events.get(msg.method) || []) cb(msg.params);
    }
  });
  return {
    send(method, params = {}) {
      const id = ++seq;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        ws.send(JSON.stringify({ id, method, params }));
      });
    },
    on(method, cb) {
      if (!events.has(method)) events.set(method, []);
      events.get(method).push(cb);
    },
  };
}

const FONT = `font-family:'Songti SC','SimSun',serif;`;

const headerTemplate = `
<div style="width:100%;${FONT}font-size:9px;color:#000;text-align:center;padding:0 10mm;">
  ${headerText || ''}
</div>`;

const footerTemplate = `
<div style="width:100%;${FONT}font-size:9px;color:#000;text-align:center;">
  <span class="pageNumber"></span>
</div>`;

(async () => {
  log('[cdp] chrome pid=' + chrome.pid + ' port=' + PORT);
  const wsUrl = await pageWsUrl();
  const ws = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', reject, { once: true });
  });
  log('[cdp] ws connected');
  const cdp = client(ws);

  await cdp.send('Page.enable');
  const loaded = new Promise((resolve) => {
    cdp.on('Page.loadEventFired', resolve);
  });
  const absHtml = path.isAbsolute(htmlPath) ? htmlPath : path.resolve(process.cwd(), htmlPath);
  if (!fs.existsSync(absHtml)) {
    throw new Error('HTML 不存在：' + absHtml);
  }
  const fileUrl = 'file://' + encodeURI(absHtml);
  log('[cdp] navigate ' + fileUrl);
  await cdp.send('Page.navigate', { url: fileUrl });
  await Promise.race([loaded, sleep(15000)]);
  await sleep(800); // 等图片解码
  log('[cdp] page loaded, printing');

  const res = await cdp.send('Page.printToPDF', {
    printBackground: true,
    displayHeaderFooter: true,
    headerTemplate,
    footerTemplate,
    paperWidth: 8.27,   // A4: 210mm
    paperHeight: 11.69, // A4: 297mm
    marginTop: 0.87,    // 22mm
    marginBottom: 0.79, // 20mm
    marginLeft: 1.02,   // 26mm
    marginRight: 0.94,  // 24mm
    preferCSSPageSize: false,
  });

  const absOut = path.isAbsolute(outPath) ? outPath : path.resolve(process.cwd(), outPath);
  fs.writeFileSync(absOut, Buffer.from(res.data, 'base64'));
  log('✓ ' + absOut + '  (' + (fs.statSync(absOut).size / 1024).toFixed(0) + ' KB)');

  ws.close();
  cleanup();
  process.exit(0);
})().catch((e) => {
  console.error('✗ 打印失败：' + (e && e.message ? e.message : e));
  cleanup();
  process.exit(1);
});
