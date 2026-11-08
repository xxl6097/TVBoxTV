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

/** AppStorage 键名，页面用 @StorageProp 绑定 */
export const KEY_IS_PHONE: string = 'isPhone';
export const KEY_IS_TV: string = 'isTv';

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
   * 弹窗/浮层/面板宽度：手机竖屏用相对宽度留边（固定宽度会超出屏宽被裁切），
   * 电视端保持固定宽度不变。isPhone 在启动时已定、运行期不变，静态读取即可。
   */
  static panelW(base: number): string | number {
    return Device.isPhone() ? '92%' : base;
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
