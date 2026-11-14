/**
 * 设备形态识别 —— 让同一套 UI 在「手机 / 电视」上各自适配。
 *
 * 判据：
 *   1. deviceInfo.deviceType 是官方分类，取值 'phone' | 'tv' | 'tablet' | '2in1' | 'wearable' | 'default'。
 *      手机（含折叠屏 Pura X）返回 'phone'，电视返回 'tv'，这是主判据。
 *   2. 兜底：有些固件/模拟器返回 'default' / 'tablet'，此时用屏幕短边（vp）猜：
 *      短边 < 600vp 视为手机。电视横屏大屏、平板大屏都不落在这个区间。
 *
 * 结果写进 AppStorage（全局单例，跨页面共享）：
 *   isPhone : boolean  —— 手机布局（底部 Tab + 网格 + 触摸）
 *   isTv    : boolean  —— 电视布局（顶部功能行 + 横向轨道 + 遥控器焦点）
 *
 * 页面用 @StorageProp('isPhone') isPhone: boolean = false 读取。
 * Device.init() 必须在 loadContent 之前调用（放 EntryAbility.onCreate 最前面），
 * 这样首页第一次 build 就能读到正确值，不会闪一帧错误的布局。
 */

import deviceInfo from '@ohos.deviceInfo';
import display from '@ohos.display';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';

/** AppStorage 键名，页面用 @StorageProp 绑定 */
export const KEY_IS_PHONE: string = 'isPhone';
export const KEY_IS_TV: string = 'isTv';
/** 当前是否横屏。手机转屏后由窗口尺寸监听实时更新，页面 @StorageProp 读它 */
export const KEY_LANDSCAPE: string = 'isLandscape';
/** 当前窗口宽度（vp），需要按宽度分档排版的地方读它 */
export const KEY_WIN_W: string = 'winW';
/** 当前窗口高度（vp）。横竖屏切换后高度变化很大，面板限高要用它 */
export const KEY_WIN_H: string = 'winH';

export class Device {
  /** 入口初始化，必须在 EntryAbility.onCreate 里最先调用 */
  static init(): void {
    let dt: string = 'default';
    try {
      dt = deviceInfo.deviceType;
    } catch (e) {
      dt = 'default';
    }

    let isPhone: boolean = dt === 'phone';
    let isTv: boolean = dt === 'tv';

    // 官方分类拿不准时（default / tablet / 2in1 / wearable），用屏幕短边兜底
    if (dt !== 'phone' && dt !== 'tv') {
      try {
        const d = display.getDefaultDisplaySync();
        // 注意：display 的 width/height 单位是 **px**，不是 vp。
        // 原来直接拿 px 和 600 比，手机短边 1080px、平板 1600px 全都 > 600，
        // 兜底分支永远判不出手机 —— default/tablet/折叠屏 会落到电视布局
        // （6 列网格 + 遥控焦点），在这些机器上完全没法用。
        // 一律先换成 vp 再比：手机 360~440vp，平板 600+vp。
        const shortVp: number = Math.min(px2vp(d.width), px2vp(d.height));
        if (shortVp > 0 && shortVp < 600) {
          isPhone = true;
          isTv = false;
        }
      } catch (e) {
        // 拿不到屏幕信息就维持默认（按电视处理）
      }
    }

    AppStorage.setOrCreate<boolean>(KEY_IS_PHONE, isPhone);
    AppStorage.setOrCreate<boolean>(KEY_IS_TV, isTv);

    // 先给一组初值，避免首帧读到 undefined 而按竖屏排版
    try {
      const d = display.getDefaultDisplaySync();
      const wVp: number = px2vp(d.width);
      const hVp: number = px2vp(d.height);
      AppStorage.setOrCreate<boolean>(KEY_LANDSCAPE, wVp > hVp);
      AppStorage.setOrCreate<number>(KEY_WIN_W, Math.min(wVp, hVp) > 0 ? wVp : 360);
      AppStorage.setOrCreate<number>(KEY_WIN_H, Math.min(wVp, hVp) > 0 ? hVp : 744);
    } catch (e) {
      AppStorage.setOrCreate<boolean>(KEY_LANDSCAPE, false);
      AppStorage.setOrCreate<number>(KEY_WIN_W, 360);
      AppStorage.setOrCreate<number>(KEY_WIN_H, 744);
    }
  }

  /**
   * 监听窗口尺寸变化，把横竖屏状态写进 AppStorage。
   *
   * 为什么必须有这个：module.json5 声明的是 auto_rotation（跟随系统），
   * 屏幕确实会转，但**页面不会自己重排** —— isPhone 是启动时算一次的静态值，
   * 布局里那些按竖屏定的列数、面板宽度全都不变。结果就是手机横过来以后，
   * 界面还是竖屏那套窄布局，两边空一大片。
   *
   * 这里用窗口宽高比判断横竖屏（不是用 display 的方向枚举：
   * 分屏/悬浮窗下方向枚举不变，但窗口已经是宽的了，按窗口算才准）。
   *
   * 必须在 onWindowStageCreate 里、拿到 window 之后调用。
   */
  static watchWindow(win: window.Window): void {
    /**
     * 启动后的稳定期。
     *
     * 实测真机启动瞬间会连报 4 次尺寸：744x440(横) → 440x744(竖) → … → 744x440。
     * 系统先按「上次的方向」建窗，再按实际姿态纠正，中间那几次是过程态。
     * 如果每次都写 AppStorage，首页就会先按横屏排一遍再改回竖屏，肉眼可见地闪。
     * 启动 900ms 内只更新一次，稳定下来之后再真正响应转屏。
     */
    const born: number = Date.now();
    let settled: boolean = false;
    // 启动期最后一次收到的尺寸，稳定后再统一应用
    let pendingW: number = 0;
    let pendingH: number = 0;

    const write = (wPx: number, hPx: number): void => {
      if (!(wPx > 0) || !(hPx > 0)) {
        return;
      }
      const wVp: number = px2vp(wPx);
      const hVp: number = px2vp(hPx);
      // 留一点容差：正方形窗口/折叠屏展开时不要来回抖
      const land: boolean = wVp > hVp * 1.05;
      if (AppStorage.get<boolean>(KEY_LANDSCAPE) !== land) {
        AppStorage.setOrCreate<boolean>(KEY_LANDSCAPE, land);
      }
      const w: number = Math.round(wVp);
      if (AppStorage.get<number>(KEY_WIN_W) !== w) {
        AppStorage.setOrCreate<number>(KEY_WIN_W, w);
      }
      const hh: number = Math.round(hVp);
      if (AppStorage.get<number>(KEY_WIN_H) !== hh) {
        AppStorage.setOrCreate<number>(KEY_WIN_H, hh);
      }
    };

    const apply = (wPx: number, hPx: number): void => {
      if (!(wPx > 0) || !(hPx > 0)) {
        return;
      }
      if (!settled) {
        // 启动期：先记下来，等稳定期结束再一次性写入
        pendingW = wPx;
        pendingH = hPx;
        return;
      }
      write(wPx, hPx);
    };

    try {
      // 先按当前窗口给一次，别等第一次回调
      const r = win.getWindowProperties().windowRect;
      apply(r.width, r.height);
    } catch (e) {
      // 拿不到就等回调
    }

    try {
      win.on('windowSizeChange', (size: window.Size) => {
        apply(size.width, size.height);
      });
    } catch (e) {
      // 个别系统不支持该事件，保持初值即可
    }

    // 稳定期结束：用最后一次收到的尺寸定稿，之后转为实时响应
    setTimeout(() => {
      settled = true;
      if (pendingW > 0 && pendingH > 0) {
        write(pendingW, pendingH);
      }
      hilog.info(0x1000, 'BOXN', 'win watch settled after %{public}dms', Date.now() - born);
    }, 900);
  }

  /** 当前是否横屏（非 UI 代码用；页面请用 @StorageProp(KEY_LANDSCAPE)） */
  static isLandscape(): boolean {
    return AppStorage.get<boolean>(KEY_LANDSCAPE) === true;
  }

  /** 是否是手机（含折叠屏）。UI 层优先用 @StorageProp 读，这里给非 UI 代码用 */
  static isPhone(): boolean {
    return AppStorage.get<boolean>(KEY_IS_PHONE) === true;
  }

  /** 是否是电视 */
  static isTv(): boolean {
    return AppStorage.get<boolean>(KEY_IS_TV) === true;
  }

  /**
   * 弹窗/浮层/面板宽度。
   *
   *  - 手机竖屏：用相对宽度留边（固定宽度会超出屏宽被裁切）
   *  - 手机横屏：屏幕窄边变成了高度，同一块面板反而可以更窄、居中显示更舒服，
   *    但仍不能给固定 vp（小屏横过来可能只有 640vp 宽）
   *  - 电视：保持固定宽度不变
   */
  static panelW(base: number): string | number {
    if (!Device.isPhone()) {
      return base;
    }
    return Device.isLandscape() ? '78%' : '92%';
  }

  /** 手机竖屏时留出状态栏/安全区后的可用宽度（vp）下限，供需要精确计算的场景用 */
  static phoneW(): number {
    try {
      const d = display.getDefaultDisplaySync();
      // 同样要换单位：返回值是 px，而调用方按 vp 用来算布局
      return Math.min(px2vp(d.width), px2vp(d.height));
    } catch (e) {
      return 440;
    }
  }
}
