/**
 * 播放页的时间格式化（纯函数，无状态）。
 *
 * 从 Player.ets 抽出来的：#140 拆分里「提取工具函数到 common/」那一条。
 * 这两个函数原来是页面方法，纯输入输出、不碰任何状态，留在 3300 行的文件里
 * 只会让查找变慢。
 *
 * 这里保留「能被单测覆盖」的写法：不依赖 ArkUI、不读 AppStorage，传什么算什么。
 */
export class PlayerFmt {
  /** 毫秒 → `mm:ss`，超过一小时自动变 `h:mm:ss`；<=0 一律 `00:00` */
  static time(ms: number): string {
    if (ms <= 0) {
      return '00:00';
    }
    const total: number = Math.floor(ms / 1000);
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    const mm: string = (m < 10 ? '0' : '') + m;
    const ss: string = (s < 10 ? '0' : '') + s;
    if (h > 0) {
      return h + ':' + mm + ':' + ss;
    }
    return mm + ':' + ss;
  }

  /** 秒 → 中文口语：90 → `1分30秒`；45 → `45秒`；60 → `1分钟` */
  static sec(sec: number): string {
    const m: number = Math.floor(sec / 60);
    const s: number = sec % 60;
    if (m > 0 && s > 0) {
      return m + '分' + s + '秒';
    }
    if (m > 0) {
      return m + '分钟';
    }
    return s + '秒';
  }
}
