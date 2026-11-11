/**
 * 设置页的行组件（tvOS 风格「标题 + 当前值 + 箭头」）。
 *
 * 从 pages/SettingPage.ets 搬出来的：那一个文件原本 2361 行，
 * 前 250 行全是这三个纯展示组件 + 视觉常量。它们不依赖页面任何业务状态，
 * 只有 @Prop 进来的几个字段和两个回调，属于「搬出去零风险、留在里面纯占地方」的那类。
 *
 * 为什么是 @Component 而不是 @Builder：@Builder 按值传参，传进来的字符串
 * 不会跟着页面状态更新（本项目踩过两次）。这些行右侧恰恰都是随状态变的「当前值」，
 * 必须用 @Prop 单向同步。
 */

import { T } from './Model';
import { Pointer } from './Pointer';
import { Feedback } from './Feedback';

/** 一个站源的测速结果，按 key 与 Site 对应 */
export class SiteSpeed {
  key: string = '';
  ms: number = -1;
  ok: boolean = false;

  constructor(key: string) {
    this.key = key;
  }
}

/**
 * 设置页视觉参数 —— 参照 tvOS「设置」的分组卡片 + 行式条目。
 *
 * 为什么用这套结构：原先把每个设置项都做成独立小卡片、按钮散落在各行右侧，
 * 一屏里同时出现 6 种卡片高度和 5 种按钮样式，用户扫一眼分不清「哪些是设置项、
 * 哪些是操作」。tvOS 的做法是把同一类的项收进一张卡，每项只占一行、
 * 右侧固定两列（当前值 + 箭头），要操作就整行进二级——层次一眼可见。
 *
 * 尺寸按横屏电视收紧了：tvOS 的行高约 76pt，这屏只有 366vp 高，
 * 用 52 才能在一屏里放下 5 行，同时保持「一行一项」的节奏。
 */
export class S {
  /** 分组卡片圆角 */
  static readonly CARD_R: number = 14;
  /** 行高 */
  static readonly ROW_H: number = 52;
  /** 行的左右内边距（右边比左边大一点，给箭头留呼吸） */
  static readonly PAD_L: number = 15;
  static readonly PAD_R: number = 18;
  /** 行间分割线：从文字起始位置缩进，和 tvOS 的内缩分隔线一致 */
  static readonly DIV_INSET: number = 18;
  static readonly DIV_COLOR: string = '#1FFFFFFF';
  /** 分组标题颜色（white 55%） */
  static readonly GROUP_TXT: string = '#8CFFFFFF';
  /** 焦点行底色：20% 白。比纯白反色柔和，也兼容 Toggle（不会出现白底白开关） */
  static readonly ROW_HI: string = '#33FFFFFF';
  /** 焦点竖条宽度 */
  static readonly BAR_W: number = 3;
}

/**
 * 设置行 —— tvOS 风格的「标题 + 当前值 + 箭头」。
 *
 * 为什么是 @Component 而不是 @Builder：@Builder 按值传参，传进来的字符串
 * 不会跟着页面状态更新（本项目已经踩过一次：播放按钮一直显示「播放」）。
 * 设置页的每一行右侧恰恰都是随状态变的「当前值」——配置地址有没有配、
 * 直播源选了哪个、站源启用了几个。用 @Builder 的结果就是首帧拿到什么就
 * 永远显示什么（实测「未配置 / 0 个」一直不刷新）。@Prop 是单向同步，
 * 父组件的状态一变这里就重建，才对得上。
 */
@Component
export struct SRowView {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop arrow: boolean = false;
  @Prop focused: boolean = false;
  /** 破坏性操作：标题用警示色 */
  @Prop warn: boolean = false;
  onTap: () => void = () => {
  };
  onHoverIn: (on: boolean) => void = () => {
  };

  build() {
    Row() {
      // 焦点竖条：常态透明但占位，出现时文字不会左右跳
      Row()
        .width(S.BAR_W)
        .height(20)
        .borderRadius(S.BAR_W / 2)
        .backgroundColor(this.focused ? (this.warn ? T.WARN : T.TXT) : '#00000000')
      // 标签绝不收缩：之前这里给了 layoutWeight(1)，轮到「上次更新」这种
      // 「短标签 + 一长串值」的组合时，Row 会优先满足值想要的宽度，把标签压到
      // 只剩 ~37vp，屏幕上直接显示成「上…」——四个字被砍掉三个。
      Text(this.label)
        .fontSize(16)
        .fontColor(this.warn ? T.WARN : T.TXT)
        // 没有值时才由标签撑开剩余空间（把箭头顶到最右）；
        // 有值时标签按自身宽度定住，不跟值抢空间。
        .layoutWeight(this.value.length > 0 ? 0 : 1)
        .flexShrink(0)
        .margin({ left: 12 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.value.length > 0) {
        // 值改成占剩余空间并靠右省略，短值时位置和原来一致，
        // 长值时由它自己缩，而不是去抢标签的宽度。
        Text(this.value)
          .fontSize(14)
          .fontColor(this.focused ? T.TXT : (this.warn ? T.DIM : T.SUB))
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 12 })
      }
      if (this.arrow) {
        Text('›')
          .fontSize(20)
          .fontColor(this.focused ? T.TXT : T.DIM)
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .height(S.ROW_H)
    .padding({ left: S.PAD_L, right: S.PAD_R })
    .backgroundColor(this.focused ? S.ROW_HI : '#00000000')
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
    .focusable(true)
    .onFocus(() => {
      this.onHoverIn(true);
    })
    .onBlur(() => {
      this.onHoverIn(false);
    })
    .onHover((hv: boolean) => {
      this.onHoverIn(hv);
    })
    .onClick(() => Pointer.fire('st_row_' + this.label, () => {
        Feedback.tap();
        this.onTap();
    }))
    .onMouse(Pointer.on('st_row_' + this.label, () => {
        Feedback.tap();
        this.onTap();
    }))
  }
}

/** 展开出来的子列表项：缩进 + 小一号字，体现「这是上一级的明细」 */
@Component
export struct SChildView {
  @Prop label: string = '';
  @Prop meta: string = '';
  @Prop value: string = '';
  @Prop focused: boolean = false;
  /** 当前正在使用的项：黄色高亮 */
  @Prop hot: boolean = false;
  onTap: () => void = () => {
  };
  onHoverIn: (on: boolean) => void = () => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(15)
        .fontColor(this.hot ? T.SELECTED : T.TXT)
        .width(160)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.meta)
        .fontSize(13)
        .fontColor(T.DIM)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 12 })
      Text(this.value)
        .fontSize(13)
        .fontColor(this.hot ? T.SELECTED : T.SUB)
        .margin({ left: 12 })
    }
    .width('100%')
    .height(42)
    .padding({ left: 30, right: S.PAD_R })
    .backgroundColor(this.focused ? S.ROW_HI : '#00000000')
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
    .onHover((hv: boolean) => {
      this.onHoverIn(hv);
    })
    .onClick(() => Pointer.fire('st_child_' + this.label, () => {
        Feedback.tap();
        this.onTap();
    }))
    .onMouse(Pointer.on('st_child_' + this.label, () => {
        Feedback.tap();
        this.onTap();
    }))
  }
}

/** 站源行：名称 + 类型/原因 + 测速结果 + 开关。开关行不做整行点击 */
@Component
export struct SSiteView {
  @Prop name: string = '';
  @Prop detail: string = '';
  @Prop usable: boolean = true;
  /** 开关状态。不能叫 enabled —— 那是 CustomComponent 基类的属性（禁用组件），会冲突 */
  @Prop sw: boolean = true;
  @Prop speed: string = '';
  @Prop speedColor: string = '';
  @Prop focused: boolean = false;
  onToggle: (on: boolean) => void = () => {
  };
  onHoverIn: (on: boolean) => void = () => {
  };

  build() {
    Row() {
      Row()
        .width(S.BAR_W)
        .height(18)
        .borderRadius(S.BAR_W / 2)
        .backgroundColor(this.focused ? T.TXT : '#00000000')
      Column() {
        Text(this.name)
          .fontSize(15)
          .fontColor(this.usable ? T.TXT : T.DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.detail)
          .fontSize(12)
          .fontColor(this.usable ? T.DIM : T.WARN)
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      if (this.speed.length > 0) {
        Text(this.speed)
          .fontSize(12)
          .fontColor(this.speedColor)
          .margin({ right: 14 })
      }
      if (this.usable) {
        Toggle({ type: ToggleType.Switch, isOn: this.sw })
          .selectedColor(T.ACCENT)
          .onChange((on: boolean) => {
            this.onToggle(on);
          })
      } else {
        Text('不支持')
          .fontSize(12)
          .fontColor(T.WARN)
          .border({ width: 1, color: T.WARN })
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(4)
      }
    }
    .width('100%')
    .height(58)
    .padding({ left: 30, right: S.PAD_R })
    .backgroundColor(this.focused ? S.ROW_HI : '#00000000')
    .animation({ duration: T.ANIM, curve: Curve.EaseOut })
    .onHover((hv: boolean) => {
      this.onHoverIn(hv);
    })
  }
}
