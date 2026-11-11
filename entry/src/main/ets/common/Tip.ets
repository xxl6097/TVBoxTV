/**
 * 全局轻提示（OSD）。
 *
 * 为什么不用系统的 promptAction.showToast：
 *  1. TV 是横屏全屏 + 隐藏系统栏，系统 toast 固定贴底，在 3 米观看距离下字号太小；
 *  2. 样式跟应用整体（深色 + 白描边）不一致，看着像外来弹窗；
 *  3. 部分大屏固件会把 toast 画在解码层下面，直接看不见。
 * 所以自绘一层，位置固定在下三分之一处、字号 20、胶囊底 + 白描边，远看清晰。
 *
 * 用法（任何页面）：
 *   @StorageLink(TIP_MSG) tipMsg: string = '';
 *   build() 最外层 Stack 里加： TipLayer({ msg: this.tipMsg })
 *   触发：Tip.show('已收藏')
 *
 * 注意：TipLayer 必须是 @Component + @Prop，不能写成 @Builder 函数。
 * @Builder 的参数是**按值传递**，状态变了不会重建 —— 表现就是「气泡壳子出来了、
 * 文字却是空的」或「连着两条提示时文字停在上一条」。直播页用 visibility 控制显隐
 * （不是 if 重建），首帧 tipMsg 是空串，于是气泡可见但一个字都没有。
 *
 * 只用一个 AppStorage 键，所以同一时刻全应用只会有一条提示，
 * 后一条直接覆盖前一条 —— 这正是遥控器快速连按时期望的行为。
 */

import { T } from './Model';
import { Device } from './Device';

/** AppStorage 键名，页面用 @StorageLink 绑定 */
export const TIP_MSG: string = 'tipMsg';

/** 提示停留时长（ms）。比系统默认 1500 长一点，大屏上给人读完的时间 */
const TIP_HOLD: number = 1800;

export class Tip {
  private static timer: number = -1;

  /** 弹一条提示。同一条文字重复触发不会闪（覆盖后重新计时） */
  static show(msg: string): void {
    if (msg.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(TIP_MSG, msg);
    if (Tip.timer >= 0) {
      clearTimeout(Tip.timer);
      Tip.timer = -1;
    }
    Tip.timer = setTimeout(() => {
      AppStorage.setOrCreate<string>(TIP_MSG, '');
      Tip.timer = -1;
    }, TIP_HOLD);
  }

  /** 立即收起，切页时用，避免提示串到下一个页面 */
  static hide(): void {
    if (Tip.timer >= 0) {
      clearTimeout(Tip.timer);
      Tip.timer = -1;
    }
    AppStorage.setOrCreate<string>(TIP_MSG, '');
  }
}

/**
 * 提示层。放在页面最外层 Stack 的最后，盖在内容之上、不挡点击。
 * hitTestBehavior 用 Transparent：能看见但不吃事件，底下的按钮照常可点。
 *
 * 用 @Component + @Prop 而不是 @Builder：@Prop 会跟着页面上的 tipMsg 一起刷新，
 * 从「空 → 有字」「A → B」都能正确更新（@Builder 的按值参数两者都做不到）。
 */
@Component
export struct TipLayer {
  @Prop msg: string = '';

  build() {
    Column() {
      Row() {
        Text(this.msg)
          .fontSize(20)
          .fontColor(T.TXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
      }
      .constraintSize({ maxWidth: Device.isPhone() ? '90%' : 720 })
      .padding({ left: 28, right: 28, top: 14, bottom: 14 })
      .borderRadius(T.RADIUS_PILL)
      .backgroundColor(T.BLACK_80)
      .border({ width: T.BORDER, color: T.WHITE_30 })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: 120 })
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
