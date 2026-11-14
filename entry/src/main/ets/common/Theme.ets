/**
 * 主题：深色（默认）/ 浅色两套色板，运行时整体替换 `T` 上的颜色常量。
 *
 * 为什么改 `T` 而不是让每个页面读「当前色板对象」：全站 11 个页面、上千处
 * `T.TXT` / `T.CARD` 引用，改成 `Theme.c('TXT')` 等于全文重写一遍，既容易漏
 * 也丢掉了静态检查。`T` 的字段本来就是 `static`，运行时整体赋值最省事。
 *
 * 代价是 ArkUI 感知不到 `T` 的变化，所以每个页面要订阅 `KEY_THEME`
 * （@StorageProp），并且**必须在 build 里真的用到**那个变量，否则状态变了
 * 也不会重绘。约定做法：根容器 `.id('theme_' + this.themeMode)`。
 *
 * 浅色板刻意不用纯白底（#FFFFFF）而用暖白：电视/手机在暗环境里纯白底刺眼，
 * 暖白配深灰字对比够、又不硌眼。
 */

import dataPreferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { T } from './Model';

/** AppStorage 键：当前主题，'dark' / 'light' */
export const KEY_THEME: string = 'themeMode';
export const THEME_DARK: string = 'dark';
export const THEME_LIGHT: string = 'light';
/** 与 Store 里同一个 preferences 库名 */
const STORE_NAME: string = 'boxtv_store_v1';

export class Theme {
  private static cur: string = THEME_DARK;

  /** 应用某个主题：先改色板，再广播（顺序不能反，页面重绘时要读到新色） */
  static apply(mode: string): void {
    const m: string = mode === THEME_LIGHT ? THEME_LIGHT : THEME_DARK;
    Theme.paint(m);
    Theme.cur = m;
    AppStorage.setOrCreate(KEY_THEME, m);
  }

  static current(): string {
    return Theme.cur;
  }

  static isLight(): boolean {
    return Theme.cur === THEME_LIGHT;
  }

  /** 在深/浅之间切一次，返回切换后的模式 */
  static toggle(): string {
    const next: string = Theme.cur === THEME_LIGHT ? THEME_DARK : THEME_LIGHT;
    Theme.apply(next);
    return next;
  }

  /**
   * 启动时同步读一次主题，必须在 loadContent 之前调用。
   *
   * 为什么不用异步：`aboutToAppear` 是 async 的，ArkUI 不会等它返回就先 build 首帧，
   * 首帧拿到的是默认深色板，浅色主题下就会「先白一下再变」；更糟的是首页那次
   * build 用旧色渲染的标题/图标，如果后续重绘没覆盖到，就一直停在深色配色上
   * （实测首页标题白字压在暖白底上，几乎看不见）。
   */
  static loadSync(ctx: common.UIAbilityContext): void {
    let mode: string = THEME_DARK;
    try {
      const p = dataPreferences.getPreferencesSync(ctx, { name: STORE_NAME });
      mode = p.getSync('theme', THEME_DARK) as string;
    } catch (e) {
      // 读不到就按默认深色走，UI 不能因为一次读盘失败起不来
    }
    Theme.apply(mode);
  }

  private static paint(m: string): void {
    if (m === THEME_LIGHT) {
      // ---- 浅色：暖白底 + 深灰字 ----
      T.BG = '#F7F5F2';
      T.SURFACE = '#FFFFFF';
      // 卡片用「黑的一点点透明度」压在暖白上，天然得到带暖意的浅灰，
      // 不用为每种底色另配一个灰，叠在任何背景上都协调
      T.CARD = '#0F000000';
      T.CARD_HI = '#1F000000';
      T.PRIMARY = '#1C1B1F';
      T.ACCENT = '#1C1B1F';
      T.ACCENT_DIM = '#14000000';
      // 选中态：深色下用 yellow_500，浅底上黄字几乎看不见，换成琥珀
      T.SELECTED = '#B26A00';
      T.TXT = '#1C1B1F';
      T.SUB = '#5F6368';
      T.DIM = '#8A8F98';
      T.WARN = '#B3261E';
      T.ERR = '#B3261E';
      T.LIVE = '#D32F2F';
      // 失效频道的文字：深色下是「白 35%」，浅色下要反过来用浅灰，否则看不见
      T.DEAD = '#BDBDBD';
      return;
    }
    // ---- 深色：FongMi leanback 原色板 ----
    T.BG = '#141218';
    T.SURFACE = '#1C1B1F';
    /**
     * 深色下的卡片必须用「白色叠加」而不是「黑色叠加」。
     *
     * 原来是 #33000000 / #66000000 —— 在深色背景上叠黑等于把卡片压得更黑：
     * 底色 #141218 叠 20% 黑 → rgb(16,14,19)，叠 40% 黑 → rgb(12,12,14)。
     * 也就是「高亮」比常态**更暗**，和用户直觉相反。4K 电视上实测，
     * 8 个功能按钮的底色分别是 (16,14,19) 和 (12,12,14)，肉眼根本分不出
     * 哪个是焦点 —— 首页顶部一排按钮看起来「全都是灰的、没有选中状态」。
     *
     * 改成白色低透明度叠加：常态 6% 白、高亮 18% 白，卡片从「比背景暗」
     * 变成「比背景亮」，焦点/选中一眼可见，也更接近 leanback 的原生观感。
     */
    T.CARD = '#0FFFFFFF';
    T.CARD_HI = '#2EFFFFFF';
    T.PRIMARY = '#FFFFFF';
    T.ACCENT = '#FFFFFF';
    T.ACCENT_DIM = '#4DFFFFFF';
    T.SELECTED = '#FFEB3B';
    T.TXT = '#FFFFFF';
    T.SUB = '#B3FFFFFF';
    T.DIM = '#80FFFFFF';
    T.WARN = '#FFB4AB';
    T.ERR = '#FFB4AB';
    T.LIVE = '#F44336';
    T.DEAD = '#5AFFFFFF';
  }
}
