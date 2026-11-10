import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import { BusinessError } from '@ohos.base';
import { Store } from '../common/Store';
import { Device } from '../common/Device';
import { Feedback } from '../common/Feedback';
import { PlayGuard } from '../common/PlayGuard';
import { Net } from '../common/Net';
import { Theme } from '../common/Theme';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 必须先于 loadContent 判定设备形态，否则首页第一帧会按错误的布局渲染
    Device.init();
    Store.init(this.context);
    // 主题必须在 loadContent 之前定好：首帧是按 `T` 上的色板画的，
    // 放到页面的 aboutToAppear 里就晚了（异步返回时首帧已经画完）
    Theme.loadSync(this.context);
    // 加载点击反馈的音效（rawfile click.wav）
    Feedback.init(this.context);
    // 网络状态：断网/恢复各提示一次，避免多个页面同时报「网络错误」
    Net.init();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Home', (err: BusinessError) => {
      if (err.code) {
        return;
      }
      try {
        const win = windowStage.getMainWindowSync();
        win.setWindowKeepScreenOn(true);
        // 与 FongMi 的 splash_background 同色，避免启动瞬间白闪
        win.setWindowBackgroundColor('#141218');

        if (Device.isTv()) {
          // 电视：沉浸式全屏 + 隐藏系统栏 + 强制横屏
          win.setWindowLayoutFullScreen(true);
          win.setWindowSystemBarEnable([]);
          try {
            win.setPreferredOrientation(window.Orientation.LANDSCAPE);
          } catch (e) {
            // 个别系统不支持运行时锁方向，忽略
          }
        } else {
          // 手机：内容不沉浸到状态栏后面（避开刘海/状态栏占用区），
          // 只保留深色状态栏、隐藏导航栏（底部已有应用自己的 Tab）。
          // 否则 setWindowLayoutFullScreen(true) 会把顶部标题栏顶到屏幕最上沿，贴住刘海。
          win.setWindowLayoutFullScreen(false);
          win.setWindowSystemBarEnable(['status']);
          try {
            win.setWindowSystemBarProperties({
              statusBarColor: '#141218',
              statusBarContentColor: '#FFFFFF',
              navigationBarColor: '#1C1B1F'
            });
          } catch (e) {
            // 个别系统不支持状态栏配色，忽略
          }
        }
      } catch (e) {
        // 部分电视系统不支持这些窗口能力，忽略
      }
    });
  }

  /**
   * 应用退到后台 / 回桌面。电视上「退出后还在出声」的兜底就在这里：
   * 页面级的 onPageHide 在部分 TV 系统上触发不可靠，而 Ability 切后台一定会走这里。
   */
  onBackground(): void {
    PlayGuard.stopAll();
  }

  onDestroy(): void {
    PlayGuard.stopAll();
  }
}
