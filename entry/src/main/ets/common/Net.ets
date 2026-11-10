/**
 * 网络状态：当前能不能出网 + 断网/恢复时给一次轻提示。
 *
 * 为什么不做成每个页面各自弹「网络错误」：一个断网动作会让首页、直播、搜索
 * 同时失败，用户一次看到三处红字。这里统一在系统层监听，状态翻转时只提示
 * 一次（Tip 是全局的），页面只管照常显示自己的错误文案。
 *
 * 判定优先用 NET_CAPABILITY_VALIDATED 而不是「有没有连上 WiFi」：
 * 连上路由器但没通外网（酒店门户、路由器没拨号）时 VALIDATED 不带，
 * 这时提示「已连接 WiFi」是错的，用户会一直以为是应用本身的问题。
 */

import connection from '@ohos.net.connection';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { Tip } from './Tip';

/** AppStorage 键：'1' 在线 / '0' 离线。页面可选读它来改文案 */
export const NET_ONLINE: string = 'netOnline';

export class Net {
  private static inited: boolean = false;
  /** 上一次的在线状态，用来只在翻转时提示 */
  private static lastOnline: boolean = true;
  /** 监听句柄，必须留着才能 unregister（也防止被 GC 后监听失效） */
  private static nc: connection.NetConnection | null = null;

  /** 进程内初始化一次：登记网络变化监听 + 先判一次当前状态 */
  static init(): void {
    if (Net.inited) {
      return;
    }
    Net.inited = true;
    AppStorage.setOrCreate(NET_ONLINE, '1');
    try {
      const nc: connection.NetConnection = connection.createNetConnection();
      // 四个事件都要收：只监听 netLost 会漏掉「WiFi 还连着但出不了网」
      // 这种最常见的情况（拔网线、路由器断网），那类变化走 netCapabilitiesChange
      nc.on('netAvailable', () => {
        Net.apply();
      });
      nc.on('netLost', () => {
        Net.apply();
      });
      nc.on('netCapabilitiesChange', () => {
        Net.apply();
      });
      nc.on('netUnavailable', () => {
        Net.apply();
      });
      nc.register((err: BusinessError) => {
        if (err) {
          hilog.info(0x1000, 'BOXN', 'net register failed code=%{public}d', err.code);
        }
      });
      Net.nc = nc;
    } catch (e) {
      // 没有 GET_NETWORK_INFO 权限或系统不支持：退化成「只在请求失败时判定」
      hilog.info(0x1000, 'BOXN', 'net watch unavailable, fallback to passive check');
    }
    Net.apply();
    hilog.info(0x1000, 'BOXN', 'net init online=%{public}s', Net.online() ? 'y' : 'n');
  }

  /**
   * 现在能不能出网。
   * 取不到能力集时一律返回 true —— 宁可漏报，也不要因为一次系统调用异常
   * 就把用户正在用的网络判成「断网」，那会让所有页面都挂上错误态。
   */
  static online(): boolean {
    try {
      const h: connection.NetHandle = connection.getDefaultNetSync();
      if (h === null || h.netId === 0) {
        return false;
      }
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(h);
      const list: connection.NetCap[] | undefined = caps.networkCap;
      if (list === undefined) {
        // 老版本系统不返回能力集，只能认为「有默认网络就算在线」
        return true;
      }
      if (list.indexOf(connection.NetCap.NET_CAPABILITY_VALIDATED) >= 0) {
        return true;
      }
      // 没有 VALIDATED 但声明了 INTERNET：可能只是联通性探测还没出结果，
      // 判成离线会误伤刚开始播放的用户，交给真实请求去证伪
      return list.indexOf(connection.NetCap.NET_CAPABILITY_INTERNET) >= 0;
    } catch (e) {
      return true;
    }
  }

  /** 判一次并处理状态翻转（提示 + 写 AppStorage） */
  private static apply(): void {
    const on: boolean = Net.online();
    AppStorage.setOrCreate(NET_ONLINE, on ? '1' : '0');
    if (on === Net.lastOnline) {
      return;
    }
    Net.lastOnline = on;
    hilog.info(0x1000, 'BOXN', 'net online=%{public}s', on ? 'y' : 'n');
    if (on) {
      Tip.show('网络已恢复');
    } else {
      Tip.show('网络已断开，请检查 WiFi 或网线');
    }
  }
}
