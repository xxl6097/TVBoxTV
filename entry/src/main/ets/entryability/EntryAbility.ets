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

        /**
         * 监听窗口尺寸变化 → 横竖屏状态。
         *
         * module.json5 声明的 auto_rotation 只负责「系统允许转」，
         * 转过去之后布局要不要重排是应用自己的事。此前没有这层监听，
         * 手机横过来界面仍是竖屏那套窄布局。
         */
        Device.watchWindow(win);

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
          /**
           * 手机跟随系统方向 —— 用的是 RESTRICTED 这一档。
           *
           * 关键区别（window.Orientation）：
           *   AUTO_ROTATION = 5           跟着传感器转，**不受**控制面板的旋转开关约束
           *   AUTO_ROTATION_RESTRICTED = 8 同样跟传感器转，但**受**旋转开关约束
           *
           * 之前配置写的是 auto_rotation，对应用第 5 档：用户明明在系统里
           * 锁了竖屏（下拉快捷开关），把手机横过来应用还是横过去了 —— 这正是
           * AUTO_ROTATION 的既定行为，不是 bug。
           *
           * 这里显式设成第 8 档：系统锁竖屏时就不转，解锁后才跟随传感器。
           * module.json5 也同步改成了 auto_rotation_restricted，两处一致；
           * 运行时再设一次是保险 —— 部分机型上 manifest 的取值会被系统覆盖。
           */
          try {
            win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
          } catch (e) {
            // 个别系统不支持运行时设方向，回退到 manifest 的声明
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
