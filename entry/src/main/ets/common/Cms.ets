import hilog from '@ohos.hilog';
import { Http } from './Http';
import { Site, Category, Vod, VodPage, Line, Episode, JResp, JVod, JClass,
  FilterGroup, FilterValue } from './Model';

/**
 * 内容接口客户端：面向标准 CMS 开放数据接口。
 *
 * 支持三类数据源协议：
 *   type 0 —— XML 数据接口
 *   type 1 —— JSON 数据接口
 *   type 4 —— 返回体多包一层 data 的 JSON 接口（同一套参数）
 * 脚本型实现依赖 JVM 与字节码加载器，本平台不支持，由上层标记为不可用。
 */
/** 一条接口响应缓存。key 即完整 URL（含接口地址与查询串），天然按来源隔离 */
class CmHit {
  key: string = '';
  body: string = '';
  at: number = 0;
}

export class Cms {
  /**
   * 接口响应缓存。
   *
   * 一次列表请求往往 1~3 秒，而用户在分类标签上来回点的概率很高
   * （看看「电影」有没有新片、再回「电视剧」继续）。之前每次切换都重新请求，
   * 回来一次就白等一次。这里加一层按 URL 的短 TTL 缓存：
   *   分类表 5 分钟（基本不变）
   *   列表   90 秒（够「来回切」，又不会把刚更新的片单压太久）
   *   详情   10 分钟（详情几乎不变，但剧集会更新，所以不给太长）
   * 搜索不缓存：关键词千变万化，缓存命中率低，还容易把「刚试过的搜索」结果留旧。
   */
  private static hits: CmHit[] = [];
  private static readonly HIT_MAX: number = 30;
  private static readonly HIT_CHARS: number = 3000000;
  private static readonly TTL_CAT: number = 300000;
  private static readonly TTL_LIST: number = 90000;
  private static readonly TTL_DETAIL: number = 600000;

  /** 读缓存；过期或没有都返回空串 */
  private static hit(url: string, ttl: number): string {
    const now: number = Date.now();
    for (let i = 0; i < Cms.hits.length; i++) {
      if (Cms.hits[i].key === url) {
        if (now - Cms.hits[i].at <= ttl) {
          return Cms.hits[i].body;
        }
        Cms.hits.splice(i, 1);   // 过期就地清掉，避免数组越攒越长
        return '';
      }
    }
    return '';
  }

  /** 写缓存：同 URL 覆盖、超条数按最旧淘汰、超总字数从最旧开始丢 */
  private static keep(url: string, body: string): void {
    if (body.length === 0) {
      return;                  // 空响应不缓存，否则一次失败会「粘」住 90 秒
    }
    const e = new CmHit();
    e.key = url;
    e.body = body;
    e.at = Date.now();
    for (let i = 0; i < Cms.hits.length; i++) {
      if (Cms.hits[i].key === url) {
        Cms.hits[i] = e;
        return;
      }
    }
    Cms.hits.push(e);
    while (Cms.hits.length > Cms.HIT_MAX) {
      Cms.hits.shift();
    }
    let total: number = 0;
    for (let i = 0; i < Cms.hits.length; i++) {
      total += Cms.hits[i].body.length;
    }
    while (total > Cms.HIT_CHARS && Cms.hits.length > 1) {
      total -= Cms.hits[0].body.length;
      Cms.hits.shift();
    }
  }

  /**
   * 缓存透明的一层：命中直接返回，未命中请求后落缓存。
   * 注意不能叫 text —— 类里已有一个 `Cms.text(s)` 负责剥 HTML 标签。
   */
  private static async fetch(url: string, ttl: number, ms: number): Promise<string> {
    const has: string = Cms.hit(url, ttl);
    if (has.length > 0) {
      hilog.info(0x1000, 'BOXN', 'cache HIT  %{public}s', Cms.short(url));
      return has;
    }
    const t0: number = Date.now();
    const txt: string = await Http.text(url, undefined, ms);
    hilog.info(0x1000, 'BOXN', 'cache MISS %{public}s  %{public}d ms',
      Cms.short(url), Date.now() - t0);
    Cms.keep(url, txt);
    return txt;
  }

  /** 日志里只留参数部分，URL 太长会把 hilog 刷屏 */
  private static short(url: string): string {
    const i: number = url.indexOf('?');
    const q: string = i >= 0 ? url.substring(i + 1) : url;
    return q.length > 48 ? q.substring(0, 48) : q;
  }

  /** 用户更换配置后主动清空，避免旧响应还留着 */
  static clearCache(): void {
    Cms.hits = [];
  }

  /** 接口缓存里有几条（设置页「清理缓存」展示用） */
  static cacheCount(): number {
    return Cms.hits.length;
  }

  /** 接口缓存占用的字符数，1 个中文字符约 3 字节，显示时按 3 倍折算 */
  static cacheChars(): number {
    let n: number = 0;
    for (let i = 0; i < Cms.hits.length; i++) {
      n += Cms.hits[i].body.length;
    }
    return n;
  }

  private site: Site;
  /** 筛选条件尾巴，形如 &area=大陆&year=2025。由点播页切换筛选时塞进来 */
  private extra: string = '';

  constructor(site: Site) {
    this.site = site;
  }

  setExtra(q: string): void {
    this.extra = q;
  }

  // ---------- 公共入口 ----------

  async categories(): Promise<Category[]> {
    const txt: string = await Cms.fetch(this.u('ac=list'), Cms.TTL_CAT, 15000);
    if (this.site.type === 0 || Cms.looksXml(txt)) {
      const cats: Category[] = Cms.catFromXml(txt);
      if (cats.length > 0) {
        const all = new Category();
        all.id = '';
        all.name = '全部';
        cats.unshift(all);
        return cats;
      }
      // 该站的 ?ac=list 直接返回影片列表，只能从条目里反推分类；
      // 这时补一个「全部」（tid 传空串接口会返回全集），否则会被锁死在单个分类里
      const derived: Category[] = Cms.catsFromVideos(txt);
      if (derived.length > 0) {
        const all = new Category();
        all.id = '';
        all.name = '全部';
        derived.unshift(all);
      }
      return derived;
    }
    const root: JResp = Cms.root(Cms.parse(txt));
    const out: Category[] = [];
    if (root.catList !== undefined) {
      for (let i = 0; i < root.catList.length; i++) {
        const c = new Category();
        c.id = String(root.catList[i].type_id === undefined ? '' : root.catList[i].type_id);
        c.name = Cms.s(root.catList[i].type_name);
        // type_pid 为 0 / 缺省都算顶级分类
        const pidAny: number | undefined = root.catList[i].type_pid;
        const pidRaw: number = pidAny === undefined ? 0 : pidAny;
        c.pid = pidRaw > 0 ? String(pidRaw) : '';
        if (c.id.length > 0 && c.name.length > 0) {
          out.push(c);
        }
      }
    }
    if (out.length === 0 && root.list !== undefined) {
      const seen: string[] = [];
      for (let i = 0; i < root.list.length; i++) {
        const tid: string = String(root.list[i].tid === undefined ? '' : root.list[i].tid);
        const tn: string = Cms.s(root.list[i].type_name);
        if (tid.length > 0 && tn.length > 0 && seen.indexOf(tid) < 0) {
          seen.push(tid);
          const c = new Category();
          c.id = tid;
          c.name = tn;
          out.push(c);
        }
      }
    }
    if (out.length > 0) {
      // t 传空串多数 CMS 会返回全集，作为默认入口体验更好：
      // 部分站点的分类 id 里只有零星几条，不开「全部」会让人以为没内容
      const all = new Category();
      all.id = '';
      all.name = '全部';
      out.unshift(all);
    }
    return out;
  }

  async list(tid: string, page: number): Promise<VodPage> {
    const q: string = 'ac=videolist&t=' + encodeURIComponent(tid) + '&pg=' + page + this.extra;
    const txt: string = await Cms.fetch(this.u(q), Cms.TTL_LIST, 18000);
    if (this.site.type === 0 || Cms.looksXml(txt)) {
      return Cms.listFromXml(txt, page, this.site);
    }
    const root: JResp = Cms.root(Cms.parse(txt));
    const pg = new VodPage();
    pg.page = root.page === undefined ? page : root.page;
    pg.pageCount = root.pagecount === undefined ? 1 : root.pagecount;
    pg.total = root.total === undefined ? 0 : root.total;
    if (root.list !== undefined) {
      for (let i = 0; i < root.list.length; i++) {
        pg.items.push(this.toVod(root.list[i]));
      }
    }
    return pg;
  }

  /**
   * 把一个父分类和它的子分类合在一起取第一页。
   *
   * 为什么需要：父分类（如 `电视剧`）通常**没有直属影片**，
   * 直接请求 `t=1` 返回空列表，界面就会显示「这个分类下没有内容」——
   * 但下面明明排着 欧美剧/韩剧/日剧。用户会以为软件坏了。
   * 这里把父 + 子同时请求、按 vod id 去重合并，父分类点进去也有内容。
   *
   * 只取第 1 页且不做翻页：聚合结果本来就是「各类最新的混排」，
   * 继续翻页的语义说不清（翻谁的页？），不如把翻页留给具体的子分类。
   */
  async listMerged(ids: string[], page: number): Promise<VodPage> {
    const out = new VodPage();
    out.page = 1;
    out.pageCount = 1;
    const seen: string[] = [];
    const tasks: Promise<VodPage>[] = [];
    for (let i = 0; i < ids.length; i++) {
      tasks.push(this.list(ids[i], page));
    }
    const got: VodPage[] = await Promise.all(tasks);
    for (let i = 0; i < got.length; i++) {
      const items: Vod[] = got[i].items;
      for (let k = 0; k < items.length; k++) {
        if (seen.indexOf(items[k].id) < 0) {
          seen.push(items[k].id);
          out.items.push(items[k]);
        }
      }
    }
    out.total = out.items.length;
    return out;
  }

  async detail(id: string): Promise<Vod> {
    const q: string = 'ac=detail&ids=' + encodeURIComponent(id);
    const txt: string = await Cms.fetch(this.u(q), Cms.TTL_DETAIL, 18000);
    if (this.site.type === 0 || Cms.looksXml(txt)) {
      return Cms.detailFromXml(txt, this.site, id);
    }
    const root: JResp = Cms.root(Cms.parse(txt));
    if (root.list !== undefined && root.list.length > 0) {
      return this.toVod(root.list[0]);
    }
    throw new Error('接口没有返回详情数据');
  }

  /** 搜索；不同站对 ac / wd 的接受度不同，做两级兜底 */
  async search(kw: string): Promise<Vod[]> {
    const e: string = encodeURIComponent(kw);
    let items: Vod[] = [];
    try {
      const txt: string = await Http.text(this.u('ac=videolist&wd=' + e), undefined, 12000);
      items = this.pickList(txt);
    } catch (err) {
      items = [];
    }
    if (items.length === 0) {
      const txt2: string = await Http.text(this.u('wd=' + e), undefined, 12000);
      items = this.pickList(txt2);
    }
    return items;
  }

  private pickList(txt: string): Vod[] {
    if (this.site.type === 0 || Cms.looksXml(txt)) {
      return Cms.listFromXml(txt, 1, this.site).items;
    }
    const root: JResp = Cms.root(Cms.parse(txt));
    const out: Vod[] = [];
    if (root.list !== undefined) {
      for (let i = 0; i < root.list.length; i++) {
        out.push(this.toVod(root.list[i]));
      }
    }
    return out;
  }

  // ---------- 内部 ----------

  private u(params: string): string {
    const a: string = this.site.api;
    if (a.endsWith('?')) {
      return a + params;
    }
    if (a.indexOf('?') >= 0) {
      return a + '&' + params;
    }
    return a + '?' + params;
  }

  private toVod(j: JVod): Vod {
    const v = new Vod();
    v.id = String(j.vod_id === undefined ? '' : j.vod_id);
    v.name = Cms.s(j.vod_name);
    v.pic = Cms.s(j.vod_pic);
    v.remark = Cms.s(j.vod_remarks);
    v.year = Cms.s(j.vod_year);
    v.area = Cms.s(j.vod_area);
    v.actor = Cms.s(j.vod_actor);
    v.director = Cms.s(j.vod_director);
    v.content = Cms.plain(Cms.s(j.vod_content).length > 0 ? Cms.s(j.vod_content) : Cms.s(j.vod_blurb));
    v.typeName = Cms.s(j.type_name);
    v.from = Cms.s(j.vod_play_from);
    v.playUrl = Cms.s(j.vod_play_url);
    v.siteKey = this.site.key;
    v.siteName = this.site.name;
    return v;
  }

  // ---------- 静态工具 ----------

  static s(v: string | undefined | null): string {
    if (v === undefined || v === null) {
      return '';
    }
    return String(v).trim();
  }

  static looksXml(txt: string): boolean {
    const t: string = txt.trimStart();
    return t.startsWith('<');
  }

  /** 配置 JSON 容错：去 BOM、去 // 注释行、把保留字 class 改名 */
  static cleanJson(txt: string): string {
    let t: string = txt;
    if (t.charCodeAt(0) === 0xFEFF) {
      t = t.substring(1);
    }
    const raw: string[] = t.split('\n');
    const keep: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      const line: string = raw[i].replace('\r', '');
      if (line.trimStart().startsWith('//')) {
        continue;
      }
      keep.push(line);
    }
    return keep.join('\n').replace(/"class"\s*:/g, '"catList":');
  }

  static parse(txt: string): JResp {
    const t: string = Cms.cleanJson(txt);
    if (t.trim().length === 0) {
      throw new Error('接口返回空内容');
    }
    try {
      return JSON.parse(t) as JResp;
    } catch (err) {
      throw new Error('接口返回的不是合法 JSON（数据源可能已失效）');
    }
  }

  static root(j: JResp): JResp {
    if (j.data !== undefined && j.data !== null) {
      return j.data;
    }
    return j;
  }

  /** HTML 实体 + 标签清理，用于简介 */
  static plain(s: string): string {
    let r: string = s.replace(/<br\s*\/?>/gi, '\n');
    r = r.replace(/<\/p>/gi, '\n');
    r = r.replace(/<[^>]+>/g, '');
    r = r.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&');
    r = r.replace(/\n{3,}/g, '\n\n');
    return r.trim();
  }

  /** XML 节点取值：先取 CDATA 内容，再清标签与实体。
   *  注意顺序——不能先跑 plain()，否则 <![CDATA[片名]]> 会被当成标签整段删掉。 */
  static node(block: string, tag: string): string {
    const re = new RegExp('<' + tag + '>([\\s\\S]*?)</' + tag + '>', 'i');
    const m = block.match(re);
    if (m === null) {
      return '';
    }
    return Cms.text(m[1]);
  }

  static text(s: string): string {
    let r: string = s;
    const c: number = r.indexOf('<![CDATA[');
    if (c >= 0) {
      const e: number = r.indexOf(']]>', c);
      if (e > 0) {
        r = r.substring(c + 9, e);
      }
    }
    return Cms.plain(r);
  }

  /** 部分站点的 ?ac=list 不返回 <class>，而是直接返回影片列表。
   *  这时从每条影片的 tid/type 反推分类，比"没有分类"更好用。 */
  static catsFromVideos(xml: string): Category[] {
    const out: Category[] = [];
    const seen: string[] = [];
    const blocks = xml.match(/<video>[\s\S]*?<\/video>/gi);
    if (blocks === null) {
      return out;
    }
    for (let i = 0; i < blocks.length; i++) {
      const tid: string = Cms.node(blocks[i], 'tid');
      const tn: string = Cms.node(blocks[i], 'type');
      if (tid.length > 0 && tn.length > 0 && seen.indexOf(tid) < 0) {
        seen.push(tid);
        const c = new Category();
        c.id = tid;
        c.name = tn;
        out.push(c);
      }
    }
    return out;
  }

  static catFromXml(xml: string): Category[] {
    const out: Category[] = [];
    const re = /<ty\b[^>]*\bid="(\d+)"[^>]*>([\s\S]*?)<\/ty>/gi;
    let m = re.exec(xml);
    while (m !== null) {
      const c = new Category();
      c.id = m[1];
      c.name = Cms.plain(m[2]);
      if (c.name.length > 0) {
        out.push(c);
      }
      m = re.exec(xml);
    }
    return out;
  }

  static listFromXml(xml: string, page: number, site: Site): VodPage {
    const pg = new VodPage();
    pg.page = page;
    const head = xml.match(/<list\b[^>]*>/i);
    if (head !== null) {
      const p = head[0].match(/\bpage="(\d+)"/i);
      const pc = head[0].match(/\bpagecount="(\d+)"/i);
      const rc = head[0].match(/\brecordcount="(\d+)"/i);
      if (p !== null) {
        pg.page = parseInt(p[1], 10);
      }
      if (pc !== null) {
        pg.pageCount = parseInt(pc[1], 10);
      }
      if (rc !== null) {
        pg.total = parseInt(rc[1], 10);
      }
    }
    const blocks = xml.match(/<video>[\s\S]*?<\/video>/gi);
    if (blocks !== null) {
      for (let i = 0; i < blocks.length; i++) {
        const b: string = blocks[i];
        const v = new Vod();
        v.id = Cms.node(b, 'id');
        v.name = Cms.node(b, 'name');
        v.pic = Cms.node(b, 'pic');
        const note: string = Cms.node(b, 'note');
        v.remark = note.length > 0 ? note : Cms.node(b, 'dt');
        v.typeName = Cms.node(b, 'type');
        v.siteKey = site.key;
        v.siteName = site.name;
        if (v.name.length > 0) {
          pg.items.push(v);
        }
      }
    }
    return pg;
  }

  static detailFromXml(xml: string, site: Site, id: string): Vod {
    const blocks = xml.match(/<video>[\s\S]*?<\/video>/gi);
    if (blocks === null || blocks.length === 0) {
      throw new Error('接口没有返回详情数据');
    }
    const b: string = blocks[0];
    const v = new Vod();
    v.id = Cms.node(b, 'id');
    if (v.id.length === 0) {
      v.id = id;
    }
    v.name = Cms.node(b, 'name');
    v.pic = Cms.node(b, 'pic');
    v.remark = Cms.node(b, 'note');
    v.typeName = Cms.node(b, 'type');
    v.year = Cms.node(b, 'year');
    v.area = Cms.node(b, 'area');
    v.actor = Cms.node(b, 'actor');
    v.director = Cms.node(b, 'director');
    v.content = Cms.node(b, 'des');
    v.siteKey = site.key;
    v.siteName = site.name;

    // <dl><dd flag="ckm3u8">第1集$http://...</dd></dl>
    const flags: string[] = [];
    const urls: string[] = [];
    const ddRe = /<dd\b[^>]*\bflag="([^"]*)"[^>]*>([\s\S]*?)<\/dd>/gi;
    let m = ddRe.exec(b);
    while (m !== null) {
      flags.push(m[1]);
      urls.push(Cms.text(m[2]));
      m = ddRe.exec(b);
    }
    if (flags.length === 0) {
      const ddRe2 = /<dd\b[^>]*>([\s\S]*?)<\/dd>/gi;
      let m2 = ddRe2.exec(b);
      let n: number = 1;
      while (m2 !== null) {
        flags.push('线路' + n);
        urls.push(Cms.text(m2[1]));
        n++;
        m2 = ddRe2.exec(b);
      }
    }
    v.from = flags.join('$$$');
    v.playUrl = urls.join('$$$');
    return v;
  }

  /** vod_play_url / vod_play_from → 线路与剧集 */
  static splitLines(from: string, playUrl: string): Line[] {
    const out: Line[] = [];
    if (playUrl.length === 0) {
      return out;
    }
    const fArr: string[] = from.length > 0 ? from.split('$$$') : [];
    const uArr: string[] = playUrl.split('$$$');
    for (let i = 0; i < uArr.length; i++) {
      const ln = new Line();
      ln.name = i < fArr.length && fArr[i].length > 0 ? fArr[i] : ('线路 ' + (i + 1));
      const segs: string[] = uArr[i].split('#');
      for (let k = 0; k < segs.length; k++) {
        const seg: string = segs[k].trim();
        if (seg.length === 0) {
          continue;
        }
        const ep = new Episode();
        const p: number = seg.indexOf('$');
        if (p > 0) {
          ep.name = seg.substring(0, p).trim();
          ep.url = seg.substring(p + 1).trim();
        } else {
          ep.name = '第 ' + (k + 1) + ' 集';
          ep.url = seg;
        }
        if (ep.url.length > 0 && ep.url.indexOf('://') > 0) {
          ln.eps.push(ep);
        }
      }
      // 标记这条线路能否直接喂给播放器：常见站点第一组是网页地址
      // （如 https://cdn/play/xxx），第二组才是真流（.../index.m3u8）
      let directCount: number = 0;
      for (let k = 0; k < ln.eps.length; k++) {
        if (Cms.isDirect(ln.eps[k].url)) {
          directCount++;
        }
      }
      ln.direct = ln.eps.length > 0 && directCount * 2 >= ln.eps.length;
      if (ln.eps.length > 0) {
        out.push(ln);
      }
    }
    return out;
  }

  static isDirect(url: string): boolean {
    const u: string = url.toLowerCase();
    return u.indexOf('.m3u8') >= 0 || u.indexOf('.mp4') >= 0 || u.indexOf('.flv') >= 0 ||
      u.indexOf('.mkv') >= 0 || u.indexOf('.ts') >= 0 || u.indexOf('.m4v') >= 0;
  }

  /**
   * 从站点 ext 里取出该分类的筛选组。
   * ext 形如 {"class":[...],"filters":{"1":[{"key":"area","name":"地区","value":[{"n":"全部","v":""}]}]}}
   * 没有 ext、不是 JSON、或该分类没配筛选时返回空数组。
   */
  static filtersOf(ext: string, tid: string): FilterGroup[] {
    const out: FilterGroup[] = [];
    const txt: string = ext.trim();
    if (txt.length === 0 || txt.charAt(0) !== '{') {
      return out;
    }
    let j: JExt;
    try {
      j = JSON.parse(txt) as JExt;
    } catch (err) {
      return out;
    }
    const map: Record<string, JFilterGroup[]> | undefined = j.filters;
    if (map === undefined) {
      return out;
    }
    const groups: JFilterGroup[] | undefined = map[tid];
    if (groups === undefined || groups === null) {
      return out;
    }
    for (let i = 0; i < groups.length; i++) {
      const src: JFilterGroup = groups[i];
      const g = new FilterGroup();
      g.key = src.key === undefined ? '' : src.key;
      g.name = src.name === undefined ? g.key : src.name;
      const vs: JFilterValue[] | undefined = src.value;
      if (vs !== undefined) {
        for (let k = 0; k < vs.length; k++) {
          const sv: JFilterValue = vs[k];
          const v = new FilterValue();
          v.n = sv.n === undefined ? '' : sv.n;
          v.v = sv.v === undefined ? '' : sv.v;
          if (v.n.length > 0) {
            g.values.push(v);
          }
        }
      }
      if (g.key.length > 0 && g.values.length > 0) {
        out.push(g);
      }
    }
    return out;
  }
}

export function mapClasses(list: JClass[]): Category[] {
  const out: Category[] = [];
  for (let i = 0; i < list.length; i++) {
    const c = new Category();
    c.id = String(list[i].type_id === undefined ? '' : list[i].type_id);
    c.name = Cms.s(list[i].type_name);
    out.push(c);
  }
  return out;
}

// ============ 站点 ext 的原始结构（只取筛选那一段） ============

interface JFilterValue {
  n?: string;
  v?: string;
}

interface JFilterGroup {
  key?: string;
  name?: string;
  value?: JFilterValue[];
}

interface JExt {
  filters?: Record<string, JFilterGroup[]>;
}
