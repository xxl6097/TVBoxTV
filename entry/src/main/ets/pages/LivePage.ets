/**
 * 直播页 —— 对照 FongMi 的 activity_live.xml。
 *
 * 频道按三级目录组织：
 * 左侧是分组目录（电视盒子的经典布局：左分组、右频道），分组名一律用直播源
 * 里写好的原始名字：源写「央视频道」就显示「央视频道」，写「地方台/北京」就
 * 拆成两级。顶部「全部频道」回到全集。画质不进目录——播放中按网速自动选。
 */

import { Feedback } from '../common/Feedback';
import router from '@ohos.router';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';
import { Store, FavChannel } from '../common/Store';
import { Live } from '../common/Live';
import { Playlist } from '../common/Playlist';
import { Channel, LiveDir, Episode, PlayParam, T, RawLive } from '../common/Model';
import { Tip, TIP_MSG, TipLayer } from '../common/Tip';
import { fromLives, LivePreset } from '../common/LivePresets';
import { LiveProbe, LiveScore } from '../common/LiveProbe';
import { KEY_IS_PHONE } from '../common/Device';
import { PhoneTabBar } from '../common/PhoneTabBar';
import { isBackCode } from '../common/TvFocus';
import { Pointer } from '../common/Pointer';

@Entry
@Component
struct LivePage {
  @StorageProp(KEY_IS_PHONE) isPhone: boolean = false;
  @State root: LiveDir = new LiveDir();
  /** 全局轻提示（AppStorage 上的 TIP_MSG），Tip.show() 触发 */
  @StorageLink(TIP_MSG) tipMsg: string = '';
  /** 三个下标，-1 = 该级「全部」。切上级时下面的级全部回到 -1 */
  @State sel1: number = -1;
  @State sel2: number = -1;
  @State sel3: number = -1;
  /** 源里的原始分组数，跟目录层数无关，直接按文件算 */
  @State gnum: number = 0;
  @State loading: boolean = true;
  @State err: string = '';
  @State url: string = '';
  /** 当前选中/正在看的频道地址，列表里据此高亮「当前频道」 */
  @State curUrl: string = '';
  @State hoverKey: string = '';

  // ---------- 收藏 / 搜索 ----------
  /** 收藏的直播频道，按收藏时间倒序 */
  @State favChans: FavChannel[] = [];
  /** 左侧目录停在「我的收藏」而不是某个源分组 */
  @State selFav: boolean = false;
  /** 频道名关键词，空串 = 不过滤 */
  @State kw: string = '';
  /** 搜索框是否展开。电视端默认收起（遥控打字麻烦），手机端默认展开 */
  @State showSearch: boolean = false;
  /** 长按收藏时用来避免同一次长按又触发点击进播放 */
  private lastFavMs: number = 0;
  /** 下拉刷新的转圈状态（Refresh 组件要求双向绑定） */
  @State refreshing: boolean = false;

  // ---------- 测速排行 / 可用性检测 ----------
  /** 测速面板是否打开 */
  @State showSpeed: boolean = false;
  /** 各直播源的测速结论（已按评分排序） */
  @State scores: LiveScore[] = [];
  @State testing: boolean = false;
  /** 测速进度文案，如「已测 3 / 11」 */
  @State testProgress: string = '';
  /** 频道级的失效地址。用地址而不是对象字段：改嵌套对象不会触发界面刷新 */
  @State deadUrls: string[] = [];
  @State checking: boolean = false;
  @State checkProgress: string = '';
  /**
   * 面板打开的时刻。
   *
   * 必须记这个：面板是在「点测速」这一次点击里挂上去的，手指抬起时
   * 遮罩已经存在，于是同一次点击又落到遮罩的 onClick 上，面板刚出现就被关掉。
   * 实测现象是「点了测速，工具栏开始计时，但面板一闪就没了」。
   */
  private openAt: number = 0;

  aboutToAppear(): void {
    // 手机竖屏横向空间够，搜索框直接展开；电视端收起，点「搜索」再出
    this.showSearch = this.isPhone;
    this.loadFav();
    this.boot();
  }

  /**
   * 从设置页换完直播源回来时列表还是旧的，这里对一下地址，变了就重新拉。
   *
   * 注意这里**不能**在 url 为空时直接 return：第一次进直播页时还没配源，
   * url 是空的，用户去设置页配好再回来，onPageShow 会因为空值提前退出，
   * 页面就一直停在「还没有配置直播源」，非得手动点刷新才行。
   */
  onPageShow(): void {
    // 从播放页返回：同步「当前频道」高亮。播放页里可能换了台（Playlist 游标变了），
    // 这里把 current 的地址记下来，频道网格据此标出正在看的台。
    this.loadFav();
    const curEp: Episode | null = Playlist.current();
    if (curEp !== null && curEp.url.length > 0) {
      this.curUrl = curEp.url;
    }
    const cur: string = this.url;
    Store.liveUrl().then((u: string) => {
      hilog.info(0x1000, 'BOXN', 'live show cur=[%{public}s] store=[%{public}s] root=%{public}d',
        cur, u, this.root.count);
      // 两种都要重拉：
      //   1) 地址变了（在设置页换了源）
      //   2) 地址有了但页面上还没有数据（首次进页面时还没配源，配完返回）
      // 只比地址是不够的：首次进来 this.url 和 Store 里的值都可能是空串，
      // 用户在设置页存好再回来时，若本次比较的两边恰好都读到旧值就会漏掉刷新。
      if (u !== cur || (u.length > 0 && this.root.count === 0)) {
        this.boot();
      }
    });
  }

  onBackPress(): boolean {
    // 遥控器返回键：面板打开时先关面板，否则退出页面。
    // 测速中也允许关——面板只是查看窗口，关掉不影响后台测速继续跑完。
    if (this.showSpeed) {
      this.showSpeed = false;
      return true;
    }
    router.back();
    return true;
  }

  async boot(): Promise<void> {
    await Store.init(getContext(this) as common.UIAbilityContext);
    this.url = await Store.liveUrl();
    // 旧版本存的是 raw 直连，这台设备 TLS 过不去（报 Internal error），自动换成镜像
    if (this.url.indexOf('raw.githubusercontent.com') >= 0 && this.url.indexOf('gh-proxy') < 0) {
      this.url = 'https://gh-proxy.com/' + this.url;
      await Store.setLiveUrl(this.url);
    }
    if (this.url.trim().length === 0) {
      // 包里不内置直播源了。先看订阅文档有没有下发 lives，有就自动选第一个；
      // 没有则引导用户去设置页订阅或手动填。
      const lives: RawLive[] = await Store.subLives();
      if (lives.length > 0) {
        const first: string = lives[0].url !== undefined ? lives[0].url : '';
        if (first.length > 0) {
          this.url = first;
          await Store.setLiveUrl(this.url);
          Tip.show('已自动选用订阅源「' +
            (lives[0].name !== undefined ? lives[0].name : '') + '」，可在设置里更换');
        }
      }
    }
    if (this.url.trim().length === 0) {
      this.loading = false;
      this.err = '还没有直播源，去「设置 → 订阅」导入';
      return;
    }
    await this.reload();
  }

  async reload(): Promise<void> {
    this.loading = true;
    this.err = '';
    try {
      const gs = await Live.load(this.url);
      this.gnum = gs.length;
      const tree: LiveDir = Live.buildTree(gs);
      this.root = tree;
      this.sel1 = tree.children.length > 0 ? 0 : -1;
      this.sel2 = -1;
      this.sel3 = -1;
    } catch (e) {
      this.err = '直播源加载失败：' + (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  // ---------- 目录取数 ----------

  l1(): LiveDir[] {
    return this.root.children;
  }

  l2(): LiveDir[] {
    const out: LiveDir[] = [];
    if (this.sel1 < 0 || this.sel1 >= this.root.children.length) {
      for (let i = 0; i < this.root.children.length; i++) {
        const kids: LiveDir[] = this.root.children[i].children;
        for (let k = 0; k < kids.length; k++) {
          out.push(kids[k]);
        }
      }
      return out;
    }
    const kids: LiveDir[] = this.root.children[this.sel1].children;
    for (let k = 0; k < kids.length; k++) {
      out.push(kids[k]);
    }
    return out;
  }

  l3(): LiveDir[] {
    const list: LiveDir[] = this.l2();
    const out: LiveDir[] = [];
    if (this.sel2 < 0 || this.sel2 >= list.length) {
      for (let i = 0; i < list.length; i++) {
        const kids: LiveDir[] = list[i].children;
        for (let k = 0; k < kids.length; k++) {
          out.push(kids[k]);
        }
      }
      return out;
    }
    const kids: LiveDir[] = list[this.sel2].children;
    for (let k = 0; k < kids.length; k++) {
      out.push(kids[k]);
    }
    return out;
  }

  /** 当前选中的那一层往下递归收全部频道（不含搜索过滤） */
  private rawChannels(): Channel[] {
    const out: Channel[] = [];
    const a: LiveDir[] = this.l3();
    if (this.sel3 >= 0 && this.sel3 < a.length) {
      Live.collect(a[this.sel3], out);
      return out;
    }
    const b: LiveDir[] = this.l2();
    if (this.sel2 >= 0 && this.sel2 < b.length) {
      Live.collect(b[this.sel2], out);
      return out;
    }
    const c: LiveDir[] = this.l1();
    if (this.sel1 >= 0 && this.sel1 < c.length) {
      Live.collect(c[this.sel1], out);
      return out;
    }
    Live.collect(this.root, out);
    return out;
  }

  /** 收藏项转成频道对象，好让网格和播放列表复用同一套逻辑 */
  private favAsChannels(): Channel[] {
    const out: Channel[] = [];
    for (let i = 0; i < this.favChans.length; i++) {
      const f: FavChannel = this.favChans[i];
      const c = new Channel();
      c.name = f.name;
      c.url = f.url;
      c.group = f.group;
      c.urls.push(f.url);
      out.push(c);
    }
    return out;
  }

  /** 关键词匹配：不区分大小写，空关键词一律通过 */
  private hit(ch: Channel): boolean {
    const k: string = this.kw.trim().toLowerCase();
    if (k.length === 0) {
      return true;
    }
    return ch.name.toLowerCase().indexOf(k) >= 0;
  }

  /**
   * 网格要显示的频道。
   *
   * 「我的收藏」和搜索是两条互相独立的过滤轴：
   *   - 停在我的收藏 → 只显示收藏台；
   *   - 有关键词 → 在「当前所在集合」里再筛一遍。
   * 两者叠加是符合直觉的（在收藏里再搜某个台），而不是互相覆盖。
   */
  channels(): Channel[] {
    const base: Channel[] = this.selFav ? this.favAsChannels() : this.rawChannels();
    if (this.kw.trim().length === 0) {
      return base;
    }
    const out: Channel[] = [];
    for (let i = 0; i < base.length; i++) {
      if (this.hit(base[i])) {
        out.push(base[i]);
      }
    }
    return out;
  }

  /** 读取收藏列表 */
  async loadFav(): Promise<void> {
    await Store.init(getContext(this) as common.UIAbilityContext);
    this.favChans = await Store.favChannels();
  }

  /** 某个频道是否已收藏 */
  isFav(ch: Channel): boolean {
    for (let i = 0; i < this.favChans.length; i++) {
      if (this.favChans[i].url === ch.url) {
        return true;
      }
    }
    return false;
  }

  /**
   * 长按频道格子收藏 / 取消收藏。
   *
   * 为什么用长按而不是格子角上的星标：这块 Grid 的点击是挂在 GridItem 上的
   * （见下方注释，格子比文字大一圈，只挂文字会点不到），角上加小按钮会和
   * 整格点击抢事件，指针遥控对不准还会误触进播放页。长按不占视觉空间，
   * 触屏和遥控（按住确定键）都能用。
   */
  async toggleFav(ch: Channel): Promise<void> {
    // 记下时间，onClick 里据此跳过「长按抬起后紧跟的那次点击」
    this.lastFavMs = Date.now();
    const f = new FavChannel();
    f.name = ch.name;
    f.url = ch.url;
    f.group = ch.group;
    const added: boolean = await Store.toggleFavChannel(f);
    await this.loadFav();
    hilog.info(0x1000, 'BOXN', 'fav toggle %{public}s -> %{public}s', ch.name, '' + added);
    Tip.show(added ? ('已收藏「' + ch.name + '」') : ('已取消收藏「' + ch.name + '」'));
  }

  /** 进入 / 离开「我的收藏」 */
  pickFav(): void {
    this.selFav = !this.selFav;
    if (this.selFav) {
      this.sel1 = -1;
      this.sel2 = -1;
      this.sel3 = -1;
    } else {
      this.sel1 = this.root.children.length > 0 ? 0 : -1;
      this.sel2 = -1;
      this.sel3 = -1;
    }
  }

  pick1(i: number): void {
    this.selFav = false;
    this.sel1 = i;
    this.sel2 = -1;
    this.sel3 = -1;
  }

  pick2(i: number): void {
    this.selFav = false;
    this.sel2 = i;
    this.sel3 = -1;
  }

  pick3(i: number): void {
    this.selFav = false;
    this.sel3 = i;
  }

  /** 面包屑：央视频道 › 央视 › 高清，任一级没选就显示「全部」 */
  crumb(): string {
    if (this.selFav) {
      return '我的收藏';
    }
    let s: string = '';
    const a: LiveDir[] = this.l1();
    s = (this.sel1 >= 0 && this.sel1 < a.length) ? a[this.sel1].name : '全部';
    const b: LiveDir[] = this.l2();
    s = s + ' › ' + ((this.sel2 >= 0 && this.sel2 < b.length) ? b[this.sel2].name : '全部');
    const c: LiveDir[] = this.l3();
    if (c.length > 0) {
      s = s + ' › ' + ((this.sel3 >= 0 && this.sel3 < c.length) ? c[this.sel3].name : '全部');
    }
    if (this.kw.trim().length > 0) {
      // 搜索时补一个命中数：用户得知道自己筛出来了几台，
      // 否则「列表变短了」和「源挂了」看起来是一样的
      s = s + ' · 搜到 ' + this.channels().length + ' 台';
    }
    return s;
  }

  /**
   * 频道格子的统一入口。
   *
   * onClick（触屏 / 键盘确定）和 onMouse（灵犀指向遥控这类指针遥控）可能
   * 在同一次点击里都到达，这里用时间窗去重，保证只进一次播放页。
   */
  tapChannel(ch: Channel): void {
    if (!Pointer.once('ch:' + ch.name + ch.url)) {
      return;
    }
    hilog.info(0x1000, 'BOXN', 'grid tap %{public}s', ch.name);
    Feedback.tap();
    this.play(ch);
  }

  /**
   * 进播放页。
   * 把当前目录下的全部频道塞进 Playlist，播放页的「上一台/下一台」就能直接换台，
   * 单台失效时也能自动顺延——不用退回列表再点。
   */
  play(ch: Channel): void {
    hilog.info(0x1000, 'BOXN', 'play enter %{public}s url2=%{public}d', ch.name, ch.urls.length);
    const list: Channel[] = this.channels();
    const eps: Episode[] = [];
    let idx: number = 0;
    for (let i = 0; i < list.length; i++) {
      const e = new Episode();
      e.name = list[i].name;
      e.url = list[i].url;
      for (let k = 0; k < list[i].urls.length; k++) {
        e.urls.push(list[i].urls[k]);
      }
      if (e.urls.length === 0) {
        e.urls.push(list[i].url);
      }
      if (list[i].url === ch.url && list[i].name === ch.name) {
        idx = i;
      }
      eps.push(e);
    }
    Playlist.set(eps, idx, '直播');
    // 记住当前频道，返回列表时高亮它
    this.curUrl = ch.url;

    const p = new PlayParam();
    p.url = ch.url;
    p.title = ch.name;
    p.siteKey = '';
    p.vodId = '';
    p.from = 'live';
    p.epIndex = idx;
    router.pushUrl({ url: 'pages/Player', params: p });
  }

  hi(key: string): boolean {
    return this.hoverKey === key;
  }

  /** 某个频道是不是「当前选中/正在看」的那台 */
  isCur(ch: Channel): boolean {
    return this.curUrl.length > 0 && this.curUrl === ch.url;
  }

  hover(key: string, on: boolean): void {
    if (on) {
      this.hoverKey = key;
    } else if (this.hoverKey === key) {
      this.hoverKey = '';
    }
  }

  // ---------- 测速排行 ----------

  /** 待测的源：订阅下发的 lives + 当前用的那个（可能是用户自己填的，订阅里没有） */
  private async targets(): Promise<LivePreset[]> {
    const lives: RawLive[] = await Store.subLives();
    const out: LivePreset[] = fromLives(lives);
    const cur: string = this.url.trim();
    if (cur.length > 0) {
      let has: boolean = false;
      for (let i = 0; i < out.length; i++) {
        if (out[i].url === cur) {
          has = true;
          break;
        }
      }
      if (!has) {
        out.push(new LivePreset('当前自定义源', cur));
      }
    }
    return out;
  }

  /** 面板条目对应的展示文案 */
  private scoreState(sc: LiveScore): string {
    if (sc.state.length > 0) {
      return sc.state;
    }
    return sc.ok ? '待测' : '待测';
  }

  /** 某个地址是否已判定失效 */
  isDead(u: string): boolean {
    return this.deadUrls.indexOf(u) >= 0;
  }

  openSpeed(): void {
    this.showSpeed = true;
    this.openAt = Date.now();
    // 打开面板先直接列出所有源（不测速），让用户能「点一下就换源」；
    // 测速变成面板里的可选动作（点「测速」），不再强制在打开时跑一轮。
    // 已经测过就直接展示上次结论，不重复跑。
    if (this.scores.length === 0 && !this.testing) {
      this.listSources();
    }
  }

  /**
   * 只列出所有候选源（不测速），供「换源」面板直接切换用。
   *
   * 每一条 state 标「待测」，点「使用」就能换，不强制用户先等一轮测速。
   */
  async listSources(): Promise<void> {
    const list: LivePreset[] = await this.targets();
    if (list.length === 0) {
      this.showSpeed = false;
      Tip.show('还没有直播源,先去「设置 → 订阅」导入');
      return;
    }
    const seeds: LiveScore[] = [];
    for (let i = 0; i < list.length; i++) {
      const it = new LiveScore();
      it.name = list[i].name;
      it.url = list[i].url;
      it.state = '待测';
      seeds.push(it);
    }
    this.scores = seeds;
  }

  /**
   * 跑一轮测速排行。
   *
   * 先给每个源放一条「待测」占位再逐个回填，而不是等全部测完一次性出结果：
   * 十几个源要十几秒，中间界面一片空白，用户会以为按钮没生效。
   */
  async runSpeed(): Promise<void> {
    if (this.testing) {
      Tip.show('正在测速，请稍等');
      return;
    }
    const list: LivePreset[] = await this.targets();
    if (list.length === 0) {
      Tip.show('还没有直播源，先去「设置 → 订阅」导入');
      return;
    }
    const seeds: LiveScore[] = [];
    for (let i = 0; i < list.length; i++) {
      const it = new LiveScore();
      it.name = list[i].name;
      it.url = list[i].url;
      it.state = '排队中';
      seeds.push(it);
    }
    this.scores = seeds;
    this.testing = true;
    this.testProgress = '0 / ' + list.length;

    let done: number = 0;
    const result: LiveScore[] = await LiveProbe.rankAll(seeds, (i: number, r: LiveScore): void => {
      done++;
      this.testProgress = done + ' / ' + list.length;
      // 逐条替换：ForEach 的 key 会带上评分，改完那一行立刻变
      const next: LiveScore[] = this.scores.slice();
      if (i < next.length) {
        next[i] = r;
        this.scores = next;
      }
    });

    this.scores = LiveProbe.sort(result);
    this.testing = false;
    this.testProgress = '';

    let okCount: number = 0;
    let best: LiveScore | null = null;
    for (let i = 0; i < this.scores.length; i++) {
      if (this.scores[i].ok) {
        okCount++;
        if (best === null) {
          best = this.scores[i];
        }
      }
    }
    if (best === null) {
      Tip.show('所有源都没测通，检查网络后重试');
      return;
    }
    Tip.show('测完 ' + this.scores.length + ' 个源，' + okCount + ' 个可用；建议用「' + best.name + '」');
  }

  /** 换用某个源 */
  async useSource(sc: LiveScore): Promise<void> {
    if (this.testing) {
      Tip.show('正在测速，稍等一下再切换');
      return;
    }
    if (sc.url === this.url) {
      this.showSpeed = false;
      Tip.show('已经在用这个源');
      return;
    }
    this.url = sc.url;
    await Store.setLiveUrl(sc.url);
    this.showSpeed = false;
    // 换源后旧的失效标记全部作废，否则新源的台会被上一轮的结果误标灰
    this.deadUrls = [];
    Tip.show('已切到「' + sc.name + '」，正在重新加载');
    await this.reload();
  }

  // ---------- 频道可用性检测 ----------

  /**
   * 检测当前分组里的频道能不能连上。
   *
   * 只测当前看到的这一组（上限 40 台）：整份源有几百台，全测要几分钟，
   * 而且用户此刻关心的就是眼前这一屏能不能点。
   */
  async checkChannels(): Promise<void> {
    hilog.info(0x1000, 'BOXN', 'chk enter checking=%{public}s', '' + this.checking);
    if (this.checking) {
      Tip.show('正在检测，请稍等');
      return;
    }
    const list: Channel[] = this.channels();
    hilog.info(0x1000, 'BOXN', 'chk list=%{public}d', list.length);
    if (list.length === 0) {
      Tip.show('当前分组没有频道');
      return;
    }
    const CAP: number = 40;
    const use: Channel[] = list.length > CAP ? list.slice(0, CAP) : list;
    this.checking = true;
    const dead: string[] = [];
    let done: number = 0;
    this.checkProgress = '0 / ' + use.length;

    const deadCount: number = await LiveProbe.channels(use, (ch: Channel, alive: boolean): void => {
      done++;
      this.checkProgress = done + ' / ' + use.length;
      if (!alive && dead.indexOf(ch.url) < 0) {
        dead.push(ch.url);
        // 每测出一条失效就更新一次，界面边测边标灰
        const next: string[] = this.deadUrls.slice();
        next.push(ch.url);
        this.deadUrls = next;
      }
    });

    this.checking = false;
    this.checkProgress = '';
    hilog.info(0x1000, 'BOXN', 'chk done dead=%{public}d of %{public}d', deadCount, use.length);
    if (deadCount === 0) {
      Tip.show('这 ' + use.length + ' 台全部可连');
    } else {
      Tip.show(use.length + ' 台里 ' + deadCount + ' 台连不上，已标灰' +
        (list.length > CAP ? '（只测了前 ' + CAP + ' 台）' : ''));
    }
  }

  // ---------- 各级条目 ----------

  /**
   * 左侧目录树的条目。level 0/1/2 = 大类 / 分组 / 子分组，靠缩进和字号区分，
   * 跟电视盒子里的分组列表一个意思：点哪个就只看哪个。
   */
  @Builder
  TreeItem(label: string, count: number, level: number, on: boolean, key: string, act: () => void) {
    Row() {
      Text(label)
        .fontSize(level === 0 ? 16 : (level === 1 ? 15 : 14))
        .fontColor(on ? T.SELECTED : (level === 0 ? T.TXT : T.SUB))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(count > 0 ? '' + count : '')
        .fontSize(12)
        .fontColor(on ? T.SELECTED : T.DIM)
        .margin({ left: 6 })
    }
    .width('100%')
    .height(level === 0 ? 46 : (level === 1 ? 40 : 36))
    .borderRadius(T.RADIUS_SM)
    .margin({ bottom: level === 0 ? 6 : 3 })
    .padding({ left: 10 + level * 14, right: 10 })
    .backgroundColor(on || this.hi(key) ? T.CARD_HI : (level === 0 ? T.CARD : '#00000000'))
    .border({ width: T.BORDER, color: this.hi(key) ? T.TXT : '#00000000' })
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
    .focusable(true)
    .onFocus(() => this.hover(key, true))
    .onBlur(() => this.hover(key, false))
    .onHover((hv: boolean) => this.hover(key, hv))
    .onClick(() => {
      this.fire(key, act);
    })
    // 指针遥控（灵犀指向）点分组：和频道格子一样补一份鼠标事件
    .onMouse(Pointer.pressRelease('tree:' + key, () => {
      this.fire(key, act);
    }))
  }

  /**
   * 热区统一触发口：onClick 与 onMouse 可能同一次点击都到达，用时间窗去重。
   */
  fire(key: string, act: () => void): void {
    if (!Pointer.once(key)) {
      return;
    }
    Feedback.tap();
    act();
  }

  /**
   * 测速排行面板。
   *
   * 独立浮层而不是塞进工具栏下拉：一行要放「名次 + 源名 + 速度 + 台数 + 可播率 + 操作」，
   * 横屏只有 638vp 宽，塞进顶部会把「刷新」挤没。浮层还能让用户对照着看完再决定换哪个。
   */
  @Builder
  SpeedPanel() {
    Stack() {
      // 点空白关闭。测速中也允许关——关掉面板不代表取消测速，后台会继续跑完
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#B3000000')
        .onClick(() => {
          Feedback.tap();
          // 刚打开 300ms 内的点击一定是「打开它的那一次」，忽略掉
          if (Date.now() - this.openAt > 300) {
            this.showSpeed = false;
          }
        })

      Column() {
        Row() {
          Text(this.isPhone ? '直播源' : '直播源测速排行')
            .fontSize(19)
            .fontColor(T.TXT)
          // 状态文字占据剩余空间并可收缩：手机窄屏下它一收缩，「测速」「关闭」
          // 两个按钮就不会被挤出屏幕（之前固定宽导致「关闭」被顶到屏外）。
          Text(this.testing
            ? ('  测速中 ' + this.testProgress)
            : (this.scores.length > 0 && this.scores[0].ok
              ? '  可播率 70% + 响应速度 30% 综合排序'
              : '  点「使用」直接换源，或点「测速」对比'))
            .fontSize(13)
            .fontColor(T.DIM)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ right: 8 })
          Text(this.testing ? '测速中…' : (this.scores.length > 0 && this.scores[0].ok ? '重新测速' : '测速'))
            .fontSize(14)
            .fontColor(this.testing ? T.DIM : T.ACCENT)
            .height(34)
            .padding({ left: 12, right: 12 })
            .borderRadius(T.RADIUS_SM)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.hi('again') ? T.CARD_HI : '#00000000')
            .focusable(true)
            .onFocus(() => this.hover('again', true))
            .onBlur(() => this.hover('again', false))
            .onHover((hv: boolean) => this.hover('again', hv))
            .onClick(() => {
              Feedback.tap();
              this.runSpeed();
            })
          Text('关闭')
            .fontSize(14)
            .fontColor(this.hi('sclose') ? T.TXT : T.SUB)
            .height(34)
            .padding({ left: 12, right: 12 })
            .margin({ left: 6 })
            .borderRadius(T.RADIUS_SM)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.hi('sclose') ? T.CARD_HI : '#00000000')
            .focusable(true)
            .defaultFocus(true)
            .onFocus(() => this.hover('sclose', true))
            .onBlur(() => this.hover('sclose', false))
            .onHover((hv: boolean) => this.hover('sclose', hv))
            .onClick(() => {
              Feedback.tap();
              // 无条件关闭：测速中也允许关面板，后台测速继续跑
              this.showSpeed = false;
            })
        }
        .width('100%')
        .margin({ bottom: 10 })

        Scroll() {
          Column() {
            ForEach(this.scores, (sc: LiveScore, i: number) => {
              Row() {
                // 名次：前三名用强调色，让人一眼看到最优
                Text('' + (i + 1))
                  .fontSize(14)
                  .fontColor(i === 0 && sc.ok ? T.SELECTED : T.DIM)
                  .width(26)
                  .textAlign(TextAlign.Center)
                Column() {
                  Row() {
                    Text(sc.name)
                      .fontSize(15)
                      .fontColor(sc.ok ? T.TXT : T.SUB)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (sc.url === this.url) {
                      Text('使用中')
                        .fontSize(11)
                        .fontColor(T.SELECTED)
                        .border({ width: 1, color: T.SELECTED })
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .borderRadius(4)
                        .margin({ left: 8 })
                    }
                    if (i === 0 && sc.ok && sc.url !== this.url) {
                      Text('推荐')
                        .fontSize(11)
                        .fontColor(T.ACCENT)
                        .border({ width: 1, color: T.ACCENT })
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .borderRadius(4)
                        .margin({ left: 8 })
                    }
                  }
                  .width('100%')
                  Text(this.scoreState(sc))
                    .fontSize(12)
                    .fontColor(sc.ok ? T.DIM : T.WARN)
                    .margin({ top: 2 })
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .margin({ left: 6 })

                // 评分：不显示原始小数，四舍五入到整数，够区分档位
                Text(sc.ok ? (sc.score + ' 分') : '—')
                  .fontSize(13)
                  .fontColor(sc.ok ? (i === 0 ? T.SELECTED : T.SUB) : T.DIM)
                  .width(52)
                  .textAlign(TextAlign.End)

                Text(sc.url === this.url ? '当前' : '使用')
                  .fontSize(13)
                  .fontColor(sc.url === this.url ? T.DIM : T.TXT)
                  .height(32)
                  .padding({ left: 14, right: 14 })
                  .margin({ left: 12 })
                  .borderRadius(T.RADIUS_SM)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.hi('use_' + sc.url) ? T.CARD_HI : T.CARD)
                  .border({
                    width: T.BORDER,
                    color: this.hi('use_' + sc.url) ? T.TXT : '#00000000'
                  })
                  .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                  .focusable(true)
                  .onFocus(() => this.hover('use_' + sc.url, true))
                  .onBlur(() => this.hover('use_' + sc.url, false))
                  .onHover((hv: boolean) => this.hover('use_' + sc.url, hv))
                  .onClick(() => {
                    Feedback.tap();
                    this.useSource(sc);
                  })
              }
              .width('100%')
              .height(58)
              .padding({ left: 6, right: 6 })
              .borderRadius(T.RADIUS_SM)
              .backgroundColor(i === 0 && sc.ok ? '#0FFFFFFF' : '#00000000')
              // key 必须带上评分与状态：ForEach 只按 key 判断是否重建，
              // key 不变时那一行会一直停在「排队中」（首页进度条踩过同一个坑）
            }, (sc: LiveScore) => 'sc' + sc.url + '_' + sc.score + '_' + sc.state + '_' + (sc.ok ? 1 : 0))
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.Top)
      }
      .width('92%')
      .height('84%')
      .padding(18)
      .backgroundColor(T.SURFACE)
      .borderRadius(18)
      .alignItems(HorizontalAlign.Start)
      .shadow({ radius: 40, color: T.BLACK_80 })
      // 焦点锁在测速面板内
      .focusScopeId('speed_panel', true)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('‹')
            .fontSize(34)
            .fontColor(this.hi('back') ? T.TXT : T.SUB)
            .width(40)
            .textAlign(TextAlign.Center)
            .focusable(true)
            .defaultFocus(true)
            .onFocus(() => this.hover('back', true))
            .onBlur(() => this.hover('back', false))
            .onHover((hv: boolean) => this.hover('back', hv))
            .onClick(() => {
              Feedback.tap();
              router.back();
            })
          Text('直播')
            .fontSize(24)
            .fontColor(T.TXT)
            .margin({ left: 8 })
          // 电视端顶栏单行就能放下；手机竖屏把这行台数/面包屑挪到第二行，给右侧三个按钮腾地方
          if (!this.isPhone) {
            Text(this.root.count > 0 ? ('  ' + this.root.count + ' 台 · ' + this.gnum + ' 组') : '')
              .fontSize(14)
              .fontColor(T.SUB)
            // 一条频道都没有时别显示「全部 › 全部」——空态下这行没有信息量，
            // 还容易让人以为已经选过了某个分组
            if (this.root.count > 0) {
              Text('  ' + this.crumb())
                .fontSize(14)
                .fontColor(T.DIM)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          Blank()
          // 电视端搜索框默认收起：遥控器打字慢，常驻一排输入框只是占地方。
          // 手机端横竖都有位置，搜索框直接常显（见下方 showSearch 初始值）
          if (!this.isPhone) {
            Text('搜索')
              .fontSize(15)
              .fontColor(this.showSearch ? T.TXT : T.SUB)
              .height(40)
              .padding({ left: 14, right: 14 })
              .margin({ right: 4 })
              .borderRadius(T.RADIUS)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.showSearch ? T.CARD : (this.hi('srch') ? T.CARD_HI : '#00000000'))
              .border({ width: T.BORDER, color: this.hi('srch') ? T.TXT : '#00000000' })
              .animation({ duration: T.ANIM, curve: Curve.EaseOut })
              .focusable(true)
              .onFocus(() => this.hover('srch', true))
              .onBlur(() => this.hover('srch', false))
              .onHover((hv: boolean) => this.hover('srch', hv))
              .onClick(() => {
                this.fire('srch', () => {
                  this.showSearch = !this.showSearch;
                  // 收起时清空关键词，否则列表会一直停在上次的过滤结果里，
                  // 而搜索框已经看不见了，用户会以为频道没了
                  if (!this.showSearch) {
                    this.kw = '';
                  }
                });
              })
          }
          // 三个按钮的顺序按「越常用越靠右」排：刷新最常用，换源其次。
          // 「换源」打开源列表面板：点一下就能换源，测速只是面板里的可选动作。
          Text(this.testing ? ('测速 ' + this.testProgress) : '换源')
            .fontSize(15)
            .fontColor(this.testing ? T.SUB : (this.hi('spd') ? T.TXT : T.SUB))
            .height(40)
            .padding({ left: 14, right: 14 })
            .borderRadius(T.RADIUS)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.hi('spd') ? T.CARD_HI : '#00000000')
            .border({ width: T.BORDER, color: this.hi('spd') ? T.TXT : '#00000000' })
            .animation({ duration: T.ANIM, curve: Curve.EaseOut })
            .focusable(true)
            .onFocus(() => this.hover('spd', true))
            .onBlur(() => this.hover('spd', false))
            .onHover((hv: boolean) => this.hover('spd', hv))
          .onClick(() => {
            this.fire('spd', () => {
              this.openSpeed();
            });
          })
          .onMouse(Pointer.pressRelease('spd', () => {
            this.fire('spd', () => {
              this.openSpeed();
            });
          }))
          Text(this.checking ? ('检测 ' + this.checkProgress) : '检测')
            .fontSize(15)
            .fontColor(this.checking ? T.SUB : (this.hi('chk') ? T.TXT : T.SUB))
            .height(40)
            .padding({ left: 14, right: 14 })
            .margin({ left: 4 })
            .borderRadius(T.RADIUS)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.hi('chk') ? T.CARD_HI : '#00000000')
            .border({ width: T.BORDER, color: this.hi('chk') ? T.TXT : '#00000000' })
            .animation({ duration: T.ANIM, curve: Curve.EaseOut })
            .focusable(true)
            .onFocus(() => this.hover('chk', true))
            .onBlur(() => this.hover('chk', false))
            .onHover((hv: boolean) => this.hover('chk', hv))
          .onClick(() => {
            this.fire('chk', () => {
              this.checkChannels();
            });
          })
          .onMouse(Pointer.pressRelease('chk', () => {
            this.fire('chk', () => {
              this.checkChannels();
            });
          }))
          Text('刷新')
            .fontSize(15)
            .fontColor(T.TXT)
            .height(40)
            .padding({ left: 14, right: 14 })
            .margin({ left: 4 })
            .borderRadius(T.RADIUS)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.hi('re') ? T.CARD_HI : '#00000000')
            .border({ width: T.BORDER, color: this.hi('re') ? T.TXT : '#00000000' })
            .animation({ duration: T.ANIM, curve: Curve.EaseOut })
            .focusable(true)
            .onFocus(() => this.hover('re', true))
            .onBlur(() => this.hover('re', false))
            .onHover((hv: boolean) => this.hover('re', hv))
          .onClick(() => {
            this.fire('re', () => {
              // 主动刷新时把上一轮的失效标记清掉，否则新数据里的台会被旧结论误标
              this.deadUrls = [];
              this.reload();
            });
          })
          .onMouse(Pointer.pressRelease('re', () => {
            this.fire('re', () => {
              this.deadUrls = [];
              this.reload();
            });
          }))
        }
        .width('100%')
        .padding({ left: 24, right: 24, top: 24, bottom: 8 })

        // 频道搜索框。只按台名过滤（几百台里按名字找是最常见的诉求，
        // 分组切换已经由左侧目录承担，两套过滤放进一个框反而会互相打架）
        if (this.showSearch && !this.loading && this.err.length === 0) {
          Row() {
            TextInput({ text: this.kw, placeholder: '搜索频道名，如 CCTV5、湖南卫视' })
              .placeholderColor(T.DIM)
              .fontSize(14)
              .fontColor(T.TXT)
              .placeholderFont({ size: 14 })
              .backgroundColor(T.CARD)
              .borderRadius(T.RADIUS_SM)
              .border({ width: T.BORDER, color: this.hi('kwin') ? T.TXT : '#00000000' })
              .height(38)
              .layoutWeight(1)
              .onFocus(() => this.hover('kwin', true))
              .onBlur(() => this.hover('kwin', false))
              .onChange((v: string) => {
                this.kw = v;
              })
            if (this.kw.length > 0) {
              Text('清除')
                .fontSize(13)
                .fontColor(this.hi('kwclr') ? T.TXT : T.SUB)
                .height(38)
                .padding({ left: 14, right: 14 })
                .margin({ left: 8 })
                .borderRadius(T.RADIUS_SM)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.hi('kwclr') ? T.CARD_HI : '#00000000')
                .focusable(true)
                .onFocus(() => this.hover('kwclr', true))
                .onBlur(() => this.hover('kwclr', false))
                .onHover((hv: boolean) => this.hover('kwclr', hv))
                .onClick(() => {
                  Feedback.tap();
                  this.kw = '';
                })
            }
          }
          .width('100%')
          .padding({ left: 24, right: 24 })
          .margin({ top: 0, bottom: 6 })
        }

        // 手机竖屏：台数/面包屑放到顶栏第二行，避免和右侧按钮挤在一起把「刷新」顶出屏幕
        if (this.isPhone && this.root.count > 0) {
          Row() {
            Text(this.root.count + ' 台 · ' + this.gnum + ' 组')
              .fontSize(13)
              .fontColor(T.SUB)
            Text('  ' + this.crumb())
              .fontSize(13)
              .fontColor(T.DIM)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 24, right: 24 })
          .margin({ top: 2, bottom: 6 })
        }

        if (this.loading) {
          Column() {
            LoadingProgress().width(44).height(44).color(T.TXT)
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.err.length > 0) {
          Column() {
            Text(this.err).fontSize(16).fontColor(T.SUB).textAlign(TextAlign.Center).width('70%')
            Text(this.url.length === 0 ? '去设置填直播源' : '重试')
              .fontSize(16)
              .fontColor(T.TXT)
              .height(42)
              .padding({ left: 28, right: 28 })
              .borderRadius(T.RADIUS)
              .margin({ top: 16 })
              .border({ width: T.BORDER, color: T.TXT })
              .focusable(true)
              .onFocus(() => this.hover('empty', true))
              .onBlur(() => this.hover('empty', false))
              .onHover((hv: boolean) => this.hover('empty', hv))
              .backgroundColor(this.hi('empty') ? T.CARD_HI : '#00000000')
              .onClick(() => {
                Feedback.tap();
                if (this.url.length === 0) {
                  router.pushUrl({ url: 'pages/SettingPage' });
                } else {
                  this.reload();
                }
              })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          // 电视盒子的经典布局：左边分组树，右边频道网格
          Row() {
            Scroll() {
              Column() {
                // 「我的收藏」置顶：直播动辄几百台，常看的就那几台，
                // 放在分组树最上面比翻目录快得多
                this.TreeItem('★ 我的收藏', this.favChans.length, 0, this.selFav, 'fav', () => {
                  this.pickFav();
                })
                this.TreeItem('全部频道', this.root.count, 0, !this.selFav && this.sel1 < 0, 'all', () => {
                  this.pick1(-1);
                })
                ForEach(this.l1(), (d1: LiveDir, i1: number) => {
                  this.TreeItem(d1.name, d1.count, 0, this.sel1 === i1 && this.sel2 < 0, 'a' + d1.name, () => {
                    this.pick1(i1);
                  })
                  ForEach(d1.children, (d2: LiveDir, i2: number) => {
                    this.TreeItem(d2.name, d2.count, 1,
                      this.sel1 === i1 && this.sel2 === i2 && this.sel3 < 0,
                      'b' + d1.name + '/' + d2.name, () => {
                        this.pick1(i1);
                        this.pick2(i2);
                      })
                    ForEach(d2.children, (d3: LiveDir, i3: number) => {
                      this.TreeItem(d3.name, d3.count, 2,
                        this.sel1 === i1 && this.sel2 === i2 && this.sel3 === i3,
                        'c' + d1.name + '/' + d2.name + '/' + d3.name, () => {
                          this.pick1(i1);
                          this.pick2(i2);
                          this.pick3(i3);
                        })
                    }, (d3: LiveDir, i3: number) => 'c' + d3.name + '_' +
                      (this.sel1 === i1 && this.sel2 === i2 && this.sel3 === i3 ? 'on' : 'off'))
                  }, (d2: LiveDir, i2: number) => 'b' + d2.name + '_' +
                    (this.sel1 === i1 && this.sel2 === i2 && this.sel3 < 0 ? 'on' : 'off'))
                }, (d1: LiveDir, i1: number) => 'a' + d1.name + '_' +
                  (this.sel1 === i1 && this.sel2 < 0 ? 'on' : 'off'))
              }
              .width('100%')
            }
            // 手机竖屏把分组栏收窄：200vp 时右侧两列各只有 ~85vp，
            // 「CCTV5+体育赛事」这类名字必被拦腰切断。收窄后频道区每列多出 ~20vp，
            // 分组名本身（"全部频道" + 计数）在这个宽度里仍然放得下。
            .width(this.isPhone ? 170 : 200)
            .height('100%')
            .scrollBar(BarState.Off)

            if (this.channels().length === 0) {
              // 空态分三种：收藏为空、搜不到、分组本身没台——给不同的话，
              // 用户才知道下一步该干什么（去收藏 / 换关键词 / 换分组）
              Column() {
                Text(this.selFav && this.kw.trim().length === 0 ? '还没有收藏频道' :
                  (this.kw.trim().length > 0 ? ('没有匹配「' + this.kw.trim() + '」的频道') : '这个分组没有频道'))
                  .fontSize(16)
                  .fontColor(T.SUB)
                  .textAlign(TextAlign.Center)
                Text(this.selFav && this.kw.trim().length === 0 ? '长按任意频道卡片即可收藏' :
                  (this.kw.trim().length > 0 ? '换个关键词试试' : '换左边别的分组看看'))
                  .fontSize(13)
                  .fontColor(T.DIM)
                  .margin({ top: 8 })
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
            } else {
              // 下拉刷新：手机顶栏位置被收藏/搜索占了，往下拉一把重新拉源更顺手。
              // Refresh 必须直接套在可滚动组件上——中间夹一层 Column 时它拿不到
              // 滚动位置，手势不会被识别（实测怎么拉都不刷新）
              Refresh({ refreshing: $$this.refreshing }) {
                Grid() {
                ForEach(this.channels(), (ch: Channel) => {
                  GridItem() {
                    // Stack 的尺寸由里面那个 Text 撑出来（**不能写 height('100%')**：
                    // GridItem 里 100% 会被解析成整个网格的高度，星标就飘到网格顶上去，
                    // 实测「★」跑到屏幕最上面而不是格子右上角）
                    Stack({ alignContent: Alignment.TopEnd }) {
                      Text(ch.name)
                        // 手机两列时格子只有 ~85vp 宽，"CCTV5体育"按 14fp 排需要 ~75vp，
                        // 减去左右 padding 后正好差几个像素，于是被硬断成「CCTV5体 / 育」。
                        // 手机端降一档字号：整串能进一行，长一点的也断在中英交界
                        // （"CCTV5+" / "体育赛事"），而不是拦腰切一个汉字。
                        .fontSize(this.isPhone ? 13 : 14)
                        // 检测出连不上的台用灰色 + 删除线：既没从列表里消失（源里确实有这台），
                        // 又一眼能看出别点。不删掉是因为有些台只是当时抽风，重启源可能又好了。
                        .fontColor(this.isDead(ch.url) ? '#5AFFFFFF' : (this.isCur(ch) ? T.SELECTED : T.TXT))
                        .decoration({
                          type: this.isDead(ch.url) ? TextDecorationType.LineThrough : TextDecorationType.None,
                          color: '#4DFFFFFF'
                        })
                        .width('100%')
                        .height(58)
                        .borderRadius(T.RADIUS_SM)
                        .textAlign(TextAlign.Center)
                        .maxLines(2)
                        // 保留西文单词完整，配合上面的字号让断点落在中英文交界处。
                        .wordBreak(WordBreak.BREAK_WORD)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .padding({ left: 6, right: 6 })
                        .backgroundColor(this.isCur(ch) ? T.CARD_HI :
                          (this.hi('ch_' + ch.name + ch.url) ? T.CARD_HI : '#00000000'))
                        .border({
                          width: T.BORDER,
                          color: this.isCur(ch) ? T.SELECTED :
                            (this.hi('ch_' + ch.name + ch.url) ? T.TXT : '#00000000')
                        })
                        .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                        .focusable(true)
                        .onFocus(() => this.hover('ch_' + ch.name + ch.url, true))
                        .onBlur(() => this.hover('ch_' + ch.name + ch.url, false))
                        .onHover((hv: boolean) => this.hover('ch_' + ch.name + ch.url, hv))

                      if (this.isFav(ch)) {
                        Text('★')
                          .fontSize(11)
                          .fontColor(T.SELECTED)
                          .margin({ top: 3, right: 5 })
                          // 星标不参与事件，否则点在星星上会吞掉整格的点击
                          .hitTestBehavior(HitTestMode.None)
                      }
                    }
                    .width('100%')
                  }
                  // 点击挂在 GridItem 上而不是里面那个 Text 上：
                  // Grid 的行高是按可用高度均分的，格子（约 110vp）比 Text(58vp) 高不少，
                  // 只把 onClick 挂在 Text 上时，点格子上下那圈空白完全没反应——
                  // 电视上用指针遥控器对不准文字就表现为「点了没反应」。
                  .onClick(() => {
                    // 长按收藏后的抬手会再补一次 click，这里 900ms 内直接吞掉，
                    // 否则「想收藏」会变成「收藏 + 进播放页」
                    if (Date.now() - this.lastFavMs < 900) {
                      return;
                    }
                    this.tapChannel(ch);
                  })
                  // 灵犀指向遥控发的是鼠标事件：指针悬停就把焦点抢走，onClick 常常被吃掉，
                  // 所以这里再挂一份 onMouse，按「按下+抬起都在本格」算一次点击。
                  .onMouse(Pointer.pressRelease('ch:' + ch.name, () => {
                    if (Date.now() - this.lastFavMs < 900) {
                      return;
                    }
                    this.tapChannel(ch);
                  }))
                  // 长按收藏 / 取消收藏（触屏长按、遥控按住确定键都走这里）
                  .gesture(
                    LongPressGesture({ repeat: false, duration: 600 })
                      .onAction(() => {
                        this.toggleFav(ch);
                      })
                  )
                },
                // key 里只放「数据态」（是否失效 / 是否当前台 / 是否已收藏），**绝不能放悬停态**：
                // ForEach 只按 key 判断要不要重建，把悬停编进 key 会变成
                // 「指针悬停 → key 变 → 格子重建 → 新节点又触发悬停 → 再重建」的活循环，
                // 格子每秒被销毁重建好几次，按下去的那一下永远落在已销毁的节点上——
                // 用灵犀指向遥控就表现为「指着某个台点下去毫无反应」。
                // 悬停高亮本来就走状态绑定，不需要重建也能刷新。
                (ch: Channel) => 'ch' + ch.name + ch.url +
                  (this.isDead(ch.url) ? 'd' : 'a') +
                  (this.isCur(ch) ? 'c' : '') +
                  (this.isFav(ch) ? 'f' : ''))
              }
              .columnsTemplate(this.isPhone ? '1fr 1fr' : '1fr 1fr 1fr 1fr')
              .columnsGap(10)
              .rowsGap(10)
              // 在 Refresh 里只能给 height('100%')：拿到父容器的完整高度它才会
              // 自己滚；给 layoutWeight 时高度由 Refresh 的测量结果决定，行数一多
              // 就撑到屏幕外，底下的频道够不到
              .height('100%')
              .padding({ left: 12, right: 24, bottom: 24 })
              .scrollBar(BarState.Off)
              .cachedCount(20)
              // 交给外层 Refresh：Spring 的「回弹」会把已到顶时的那段下拉吃掉，
              // 下拉手势就传不到 Refresh 上，表现是「怎么拉都不刷新」
              .edgeEffect(EdgeEffect.None)
              }
              .width('100%')
              .layoutWeight(1)
              .onRefreshing(() => {
                // 手动下拉 = 换一轮新数据：顺带清掉上一轮的失效标记，
                // 否则刚测出来的「台挂了」会一直贴着旧结论显示
                this.refreshing = true;
                this.deadUrls = [];
                this.reload().then(() => {
                  this.refreshing = false;
                });
              })
              }
            }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 24 })
        }
        if (this.isPhone) {
          PhoneTabBar('pages/LivePage')
        }
      }
      .width('100%')
      .height('100%')

      // 用 Stack 包裹 + visibility 代替 if 条件渲染：
      // ArkTS 中 @Builder 方法在 if 块里可能不触发重渲染
      Stack() {
        this.SpeedPanel()
      }
      .width('100%')
      .height('100%')
      .visibility(this.showSpeed ? Visibility.Visible : Visibility.None)
      .hitTestBehavior(this.showSpeed ? HitTestMode.Default : HitTestMode.None)

      Stack() {
        TipLayer(this.tipMsg)
      }
      .width('100%')
      .height('100%')
      .visibility(this.tipMsg.length > 0 ? Visibility.Visible : Visibility.None)
      .hitTestBehavior(this.tipMsg.length > 0 ? HitTestMode.Default : HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
