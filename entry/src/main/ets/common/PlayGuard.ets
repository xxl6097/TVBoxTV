/**
 * 全局播放守卫。
 *
 * 页面级的 onPageHide / aboutToDisappear 在电视上并不可靠：
 *   - TV 按 Home 直接回桌面时，部分系统只走 Ability.onBackground，页面回调来得晚甚至不来；
 *   - 页面停在播放页时被系统直接回收，aboutToDisappear 也可能不触发。
 * 这两种情况都会留下一个还活着的 AVPlayer —— 表现就是「退出后还在出声」。
 *
 * 所以在 Ability.onBackground / onDestroy 里兜一道：只要应用离开前台，强制停掉所有
 * 注册过的播放器。播放页在 aboutToAppear 注册、aboutToDisappear 注销。
 *
 * 只用数组存停止函数，不持有 player 引用，避免和页面生命周期互相拉扯。
 */
export type PlayStopFn = () => void;

export class PlayGuard {
  private static stops: PlayStopFn[] = [];

  /** 注册一个「停止播放」回调。重复注册会被忽略 */
  static bind(fn: PlayStopFn): void {
    for (let i = 0; i < PlayGuard.stops.length; i++) {
      if (PlayGuard.stops[i] === fn) {
        return;
      }
    }
    PlayGuard.stops.push(fn);
  }

  /** 注销回调。页面销毁时必须调，否则会持有已销毁组件的闭包 */
  static unbind(fn: PlayStopFn): void {
    const next: PlayStopFn[] = [];
    for (let i = 0; i < PlayGuard.stops.length; i++) {
      if (PlayGuard.stops[i] !== fn) {
        next.push(PlayGuard.stops[i]);
      }
    }
    PlayGuard.stops = next;
  }

  /** 应用离开前台时调用：把所有还在播的播放器停掉 */
  static stopAll(): void {
    for (let i = 0; i < PlayGuard.stops.length; i++) {
      try {
        PlayGuard.stops[i]();
      } catch (e) {
        // 单个失败不影响其他
      }
    }
  }
}
