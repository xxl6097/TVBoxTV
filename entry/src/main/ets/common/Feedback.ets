/**
 * 全局点击反馈（声音 + 震动）。
 *
 * 用户按任意按钮时给一个「声音 + 震动」的即时反馈，让操作有实感。
 * 两个通道各自独立开关，偏好存本机 preferences：
 *   tapSound   0 = 关 / 1 = 开（默认开）
 *   tapVibrate 0 = 关 / 1 = 开（默认开）
 *
 * 声音用 SoundPool（低延迟短音效，播放 28ms 的 click.wav，混音模式不打断正在播的片），
 * 震动用 vibrator 触发一次 20ms 短震。二者都 fire-and-forget，
 * 不阻塞 UI 线程，点击响应依然跟手。
 *
 * 用法（任何页面）：
 *   import { Feedback } from '../common/Feedback';
 *   .onClick(() => { Feedback.tap(); this.xxx(); })
 *
 * 启动时 EntryAbility.onCreate 调 Feedback.init(this.context) 加载音效；
 * 设置页切换开关后调 Feedback.refresh() 刷新内存缓存。
 */

import vibrator from '@ohos.vibrator';
import soundPool from '@ohos.multimedia.soundPool';
import audio from '@ohos.multimedia.audio';
import common from '@ohos.app.ability.common';
import { Store } from './Store';

export class Feedback {
  private static sp: soundPool.SoundPool | null = null;
  private static soundId: number = -1;
  private static ready: boolean = false;
  private static soundOn: boolean = true;
  private static vibrateOn: boolean = true;
  private static inited: boolean = false;

  /** 启动时调用一次（EntryAbility.onCreate），传入 context 用于加载 rawfile 音效 */
  static init(ctx?: common.UIAbilityContext): void {
    if (Feedback.inited) {
      return;
    }
    Feedback.inited = true;
    Feedback.refresh();
    if (ctx !== undefined) {
      Feedback.loadSound(ctx);
    }
  }

  private static loadSound(ctx: common.UIAbilityContext): void {
    try {
      const info: audio.AudioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      };
      Feedback.sp = soundPool.createSoundPool(1, info);
      ctx.resourceManager.getRawFd('click.wav').then((fd) => {
        if (Feedback.sp === null) {
          return;
        }
        Feedback.sp.load(fd.fd, fd.offset, fd.length).then((id: number) => {
          Feedback.soundId = id;
          Feedback.ready = true;
        }).catch(() => {
        });
      }).catch(() => {
      });
    } catch (e) {
      // 音效加载失败不影响震动反馈
    }
  }

  /** 开关变更后刷新内存缓存（设置页切换开关时调用） */
  static refresh(): void {
    Store.tapSound().then((v: number) => {
      Feedback.soundOn = v !== 0;
    });
    Store.tapVibrate().then((v: number) => {
      Feedback.vibrateOn = v !== 0;
    });
  }

  /** 点一下的反馈（任何按钮 onClick 开头调用） */
  static tap(): void {
    if (Feedback.vibrateOn) {
      try {
        vibrator.vibrate(20);
      } catch (e) {
        // 忽略：个别设备无马达或权限受限
      }
    }
    if (Feedback.soundOn && Feedback.ready && Feedback.sp !== null && Feedback.soundId >= 0) {
      try {
        const params: soundPool.PlayParameters = {
          loop: 0,
          rate: 1,
          leftVolume: 0.7,
          rightVolume: 0.7,
          priority: 0
        };
        Feedback.sp.play(Feedback.soundId, params).catch(() => {
        });
      } catch (e) {
        // 忽略
      }
    }
  }
}
