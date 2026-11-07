#!/usr/bin/env node
/**
 * 协议自检 —— 与 entry/src/main/ets/common/Cms.ets 同一套解析逻辑的 Node 版。
 * 用来在装机前确认「某个站源现在还能不能读」，不用等电视上试。
 *
 * 用法：
 *   node tools/parse-check.mjs                                  # 用内置默认配置
 *   node tools/parse-check.mjs <配置地址>                        # 检查前 5 个可用站源
 *   node tools/parse-check.mjs <配置地址> 关键词                  # 只检查名字含关键词的站源
 *   node tools/parse-check.mjs <配置地址> 关键词 --detail         # 深挖到剧集直链
 */

import { execFile } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';

const UA = 'Mozilla/5.0 (Linux; HarmonyOS; SmartScreen) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
const DEFAULT_CFG = 'https://raw.githubusercontent.com/zqc11608/box/main/m.json';

// ---------- 与 Cms.ets 一一对应 ----------
const s = (v) => (v === undefined || v === null ? '' : String(v).trim());

const plain = (t) => {
  let r = t.replace(/<br\s*\/?>/gi, '\n').replace(/<\/p>/gi, '\n').replace(/<[^>]+>/g, '');
  r = r.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
       .replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&');
  return r.replace(/\n{3,}/g, '\n\n').trim();
};

/** 先取 CDATA 再清标签——顺序反了会把 <![CDATA[片名]]> 整段删掉 */
const text = (t) => {
  let r = t;
  const c = r.indexOf('<![CDATA[');
  if (c >= 0) {
    const e = r.indexOf(']]>', c);
    if (e > 0) r = r.substring(c + 9, e);
  }
  return plain(r);
};

const node = (block, tag) => {
  const m = block.match(new RegExp('<' + tag + '>([\\s\\S]*?)</' + tag + '>', 'i'));
  return m === null ? '' : text(m[1]);
};

const cleanJson = (t) => {
  if (t.charCodeAt(0) === 0xFEFF) t = t.substring(1);
  return t.split('\n').map((l) => l.replace('\r', ''))
    .filter((l) => !l.trimStart().startsWith('//'))
    .join('\n').replace(/"class"\s*:/g, '"catList":');
};

const catFromXml = (xml) => {
  const out = []; const re = /<ty\b[^>]*\bid="(\d+)"[^>]*>([\s\S]*?)<\/ty>/gi; let m = re.exec(xml);
  while (m !== null) { const n = plain(m[2]); if (n) out.push({ id: m[1], name: n }); m = re.exec(xml); }
  return out;
};

const catsFromVideos = (xml) => {
  const out = []; const seen = [];
  for (const b of xml.match(/<video>[\s\S]*?<\/video>/gi) ?? []) {
    const tid = node(b, 'tid'); const tn = node(b, 'type');
    if (tid && tn && !seen.includes(tid)) { seen.push(tid); out.push({ id: tid, name: tn }); }
  }
  return out;
};

const listFromXml = (xml, page) => {
  const pg = { items: [], page, pageCount: 1, total: 0 };
  const head = xml.match(/<list\b[^>]*>/i);
  if (head) {
    const p = head[0].match(/\bpage="(\d+)"/i);
    const pc = head[0].match(/\bpagecount="(\d+)"/i);
    const rc = head[0].match(/\brecordcount="(\d+)"/i);
    if (p) pg.page = +p[1];
    if (pc) pg.pageCount = +pc[1];
    if (rc) pg.total = +rc[1];
  }
  for (const b of xml.match(/<video>[\s\S]*?<\/video>/gi) ?? []) {
    pg.items.push({
      id: node(b, 'id'), name: node(b, 'name'), pic: node(b, 'pic'),
      remark: node(b, 'note') || node(b, 'dt'), typeName: node(b, 'type')
    });
  }
  return pg;
};

const detailFromXml = (xml) => {
  const blocks = xml.match(/<video>[\s\S]*?<\/video>/gi) ?? [];
  if (!blocks.length) throw new Error('返回里没有 <video>');
  const b = blocks[0];
  const flags = []; const urls = [];
  let m; const re = /<dd\b[^>]*\bflag="([^"]*)"[^>]*>([\s\S]*?)<\/dd>/gi;
  while ((m = re.exec(b)) !== null) { flags.push(m[1]); urls.push(text(m[2])); }
  return {
    id: node(b, 'id'), name: node(b, 'name'), pic: node(b, 'pic'),
    typeName: node(b, 'type'), year: node(b, 'year'), area: node(b, 'area'),
    content: node(b, 'des'), from: flags.join('$$$'), playUrl: urls.join('$$$')
  };
};

const splitLines = (from, playUrl) => {
  const out = []; if (!playUrl) return out;
  const f = from ? from.split('$$$') : []; const u = playUrl.split('$$$');
  for (let i = 0; i < u.length; i++) {
    const ln = { name: i < f.length && f[i] ? f[i] : '线路 ' + (i + 1), eps: [] };
    const segs = u[i].split('#');
    for (let k = 0; k < segs.length; k++) {
      const seg = segs[k].trim(); if (!seg) continue;
      const p = seg.indexOf('$');
      const name = p > 0 ? seg.substring(0, p).trim() : '第 ' + (k + 1) + ' 集';
      const url = p > 0 ? seg.substring(p + 1).trim() : seg;
      if (url && url.indexOf('://') > 0) ln.eps.push({ name, url });
    }
    if (ln.eps.length) out.push(ln);
  }
  return out;
};

const isDirect = (u) => ['.m3u8', '.mp4', '.flv', '.mkv', '.ts', '.m4v'].some((e) => u.toLowerCase().includes(e));

// ---------- 网络 ----------
// 开发机常常挂着本地代理，而 Node 的 fetch 不读 HTTP_PROXY 环境变量，
// 所以 fetch 失败时回落到 curl（curl 会读代理配置）。
const fetchGet = async (u, ms) => {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), ms);
  try {
    const r = await fetch(u, { headers: { 'User-Agent': UA }, signal: ac.signal, redirect: 'follow' });
    return { code: r.status, body: await r.text() };
  } finally {
    clearTimeout(t);
  }
};

const curlGet = (u, ms) => new Promise((res, rej) => {
  execFile('curl', ['-sS', '-L', '-m', String(Math.max(1, Math.round(ms / 1000))),
    '-A', UA, '-w', '\n__HTTP_CODE__%{http_code}', u],
    { maxBuffer: 64 * 1024 * 1024 },
    (err, stdout) => {
      if (err) { return rej(err); }
      const i = stdout.lastIndexOf('\n__HTTP_CODE__');
      const code = i >= 0 ? parseInt(stdout.slice(i + 14), 10) : 200;
      res({ code: Number.isFinite(code) ? code : 200, body: i >= 0 ? stdout.slice(0, i) : stdout });
    });
});

const get = async (u, ms = 15000) => {
  if (u.startsWith('file://') || (existsSync(u) && !/^https?:/.test(u))) {
    const path = u.startsWith('file://') ? new URL(u).pathname : u;
    return { code: 200, body: readFileSync(path, 'utf8') };
  }
  try {
    return await fetchGet(u, ms);
  } catch (e) {
    return await curlGet(u, ms);
  }
};

// ---------- 主流程 ----------
const args = process.argv.slice(2);
const cfgUrl = args[0] && !args[0].startsWith('--') ? args[0] : DEFAULT_CFG;
const keyword = args[1] && !args[1].startsWith('--') ? args[1] : '';
const deep = args.includes('--detail');

console.log('配置地址 :', cfgUrl);
const cfgRes = await get(cfgUrl, 25000);
if (cfgRes.code !== 200) {
  console.error('✗ 配置下载失败 HTTP', cfgRes.code);
  process.exit(1);
}
const cfg = JSON.parse(cleanJson(cfgRes.body));
const all = cfg.sites ?? [];
const usable = all.filter((x) => (x.type === 0 || x.type === 1 || x.type === 4) && /^https?:/.test(x.api ?? ''));
const spider = all.filter((x) => x.type === 3);
const parses = (cfg.parses ?? []).filter((p) => p.type === 1 && /^http/.test(p.url ?? ''));

console.log('站源总数 :', all.length, '| 可用', usable.length, '| 需爬虫(不支持)', spider.length);
console.log('解析接口 :', parses.length, '个');
console.log('');

let targets = usable;
if (keyword) {
  targets = usable.filter((x) => (x.name ?? '').includes(keyword));
  if (!targets.length) {
    console.error('✗ 没有名字含「' + keyword + '」的可用站源');
    process.exit(1);
  }
} else {
  targets = usable.slice(0, 5);
}

const urlOf = (api, params) => {
  if (api.endsWith('?')) return api + params;
  if (api.indexOf('?') >= 0) return api + '&' + params;
  return api + '?' + params;
};

let okCount = 0;
for (const site of targets) {
  const tag = (site.name ?? site.key ?? '').slice(0, 24);
  console.log('──', tag, '(' + site.api + ')');
  try {
    const t0 = Date.now();
    const c = await get(urlOf(site.api, 'ac=list'));
    if (c.code >= 400) throw new Error('分类接口 HTTP ' + c.code);

    const isXml = c.body.trimStart().startsWith('<');
    let cats;
    if (isXml) {
      cats = catFromXml(c.body);
      if (!cats.length) {
        const d = catsFromVideos(c.body);
        if (d.length) { d.unshift({ id: '', name: '全部' }); }
        cats = d;
      }
    } else {
      const root = JSON.parse(cleanJson(c.body)).data ?? JSON.parse(cleanJson(c.body));
      cats = (root.catList ?? []).map((x) => ({ id: String(x.type_id ?? ''), name: s(x.type_name) }));
    }
    // 与 App 一致：补「全部」（t 传空串，多数 CMS 返回全集）
    if (cats.length) { cats.unshift({ id: '', name: '全部' }); }
    console.log('   分类 :', cats.length, '个', cats.slice(0, 6).map((x) => x.name).join('/'));

    const tid = cats[0]?.id ?? '';
    const l = await get(urlOf(site.api, 'ac=videolist&t=' + encodeURIComponent(tid) + '&pg=1'));
    if (l.code >= 400) throw new Error('列表接口 HTTP ' + l.code);

    let page;
    if (isXml || l.body.trimStart().startsWith('<')) {
      page = listFromXml(l.body, 1);
    } else {
      const root = JSON.parse(cleanJson(l.body)).data ?? JSON.parse(cleanJson(l.body));
      page = {
        items: (root.list ?? []).map((v) => ({
          id: String(v.vod_id ?? ''), name: s(v.vod_name), pic: s(v.vod_pic),
          remark: s(v.vod_remarks), typeName: s(v.type_name)
        })),
        page: root.page ?? 1, pageCount: root.pagecount ?? 1, total: root.total ?? 0
      };
    }
    console.log('   列表 :', page.items.length, '条 / 共', page.pageCount, '页 /', page.total, '部');
    if (!page.items.length) throw new Error('列表为空');

    const first = page.items[0];
    console.log('   首条 :', first.name, first.remark ? '[' + first.remark + ']' : '');
    if (first.pic) console.log('   海报 :', first.pic.slice(0, 70));

    if (deep) {
      const d = await get(urlOf(site.api, 'ac=detail&ids=' + encodeURIComponent(first.id)));
      if (d.code >= 400) throw new Error('详情接口 HTTP ' + d.code);
      let vod;
      if (isXml || d.body.trimStart().startsWith('<')) {
        vod = detailFromXml(d.body);
      } else {
        const root = JSON.parse(cleanJson(d.body)).data ?? JSON.parse(cleanJson(d.body));
        const v = (root.list ?? [])[0];
        if (!v) throw new Error('详情里没有 list');
        vod = {
          id: String(v.vod_id ?? ''), name: s(v.vod_name), from: s(v.vod_play_from),
          playUrl: s(v.vod_play_url), content: plain(s(v.vod_content))
        };
      }
      const lines = splitLines(vod.from, vod.playUrl);
      console.log('   详情 :', vod.name, '| 线路', lines.length);
      for (const ln of lines.slice(0, 3)) {
        const ep = ln.eps[0];
        console.log('     ' + ln.name.padEnd(10), ln.eps.length + ' 集', ep ? '首集:' + ep.name : '');
        if (ep) console.log('       ' + ep.url.slice(0, 90), isDirect(ep.url) ? '→ 直链 ✓' : '→ 需解析');
      }
      if (!lines.length) throw new Error('详情里拆不出剧集');
    }

    console.log('   ✓ 可用（' + (Date.now() - t0) + ' ms）\n');
    okCount++;
  } catch (e) {
    console.log('   ✗ ' + (e instanceof Error ? e.message : String(e)) + '\n');
  }
}

console.log('结果：' + okCount + ' / ' + targets.length + ' 个站源通过');
process.exit(okCount > 0 ? 0 : 1);
