/**
 * 播放页的浮层（HUD）：解析中 / 缓冲中 / 无法播放。
 *
 * 从 Player.ets 的 build() 里抽出来的第一块（优化 #140）。
 * 这三块有共同点：都盖满全屏、都只是「告诉用户现在什么情况」、都不持有播放器引用，
 * 所以适合先按「状态进、回调出」的方式独立成组件：
 *   - 状态由页面 @Prop 传入（errMsg / buffering / resolving …）
 *   - 交互通过 onRetry / onBack 回调回页面，组件自己不碰播放器
 *
 * 为什么不做成 @Builder：@Builder 的入参是值传递，状态变了不会重建，
 * 之前 Tip.ets 就踩过「壳子出来但文字是空的」的坑。这里用 @Component + @Prop，
 * 由页面状态驱动刷新。
 */

import { T } from './Model';

@Component
export struct PlayerHud {
  /** 直播 / 点播，决定文案（频道 vs 剧集） */
  @Prop isLive: boolean = false;
  /** 非空即进入错误态 */
  @Prop errMsg: string = '';
  /** 网络测速文案，缓冲时附在「缓冲中…」后面 */
  @Prop netTxt: string = '';
  /** 片源是否有多档清晰度（决定是否提示「会自动降画质」） */
  @Prop multiLevel: boolean = false;
  /** 当前是否自动画质（qCap === 0） */
  @Prop autoQuality: boolean = true;
  @Prop resolving: boolean = false;
  @Prop buffering: boolean = false;
  @Prop prepared: boolean = false;
  /** 两个按钮的高亮态，由页面的 hover 状态传入 */
  @Prop retryHi: boolean = false;
  @Prop backHi: boolean = false;

  onRetry: () => void = () => {
  };
  onBack: () => void = () => {
  };
  onHoverRetry: (on: boolean) => void = () => {
  };
  onHoverBack: (on: boolean) => void = () => {
  };

  build() {
    Stack() {
      // ① 解析地址中：直播要逐个探源，这一步可能好几秒，必须给明确反馈
      if (this.resolving) {
        Column() {
          LoadingProgress().width(52).height(52).color(T.PANEL_TXT)
          Text(this.isLive ? '正在连接频道…' : '正在解析播放地址…')
            .fontSize(18).fontColor(T.PANEL_SUB).margin({ top: 14 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#000000')
      }

      // ② 缓冲中：卡住时以前就是黑屏干等，现在明确告诉你「在等数据」
      if (this.buffering && this.prepared && this.errMsg.length === 0 && !this.resolving) {
        Column() {
          Row() {
            LoadingProgress().width(26).height(26).color(T.PANEL_TXT)
            Text(this.netTxt.length > 0 ? ('缓冲中…  网络 ' + this.netTxt) : '缓冲中…')
              .fontSize(17).fontColor(T.PANEL_TXT).margin({ left: 14 })
            if (this.multiLevel && this.autoQuality) {
              Text('网络偏慢会自动降画质').fontSize(14).fontColor(T.PANEL_DIM).margin({ left: 14 })
            }
          }
          .padding({ left: 24, right: 24, top: 14, bottom: 14 })
          .backgroundColor(T.BLACK_70)
          .borderRadius(14)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // ③ 无法播放：给出原因 + 就地重试，不让用户只能退出
      if (this.errMsg.length > 0) {
        Column() {
          Text('无法播放').fontSize(30).fontColor(T.ERR)
          Text(this.errMsg)
            .fontSize(19).fontColor(T.PANEL_SUB).margin({ top: 12 })
            .textAlign(TextAlign.Center).width('80%')
          Text(this.isLive
            ? '直播源里的单个频道经常失效，可以在控制条上按「下一台」换一个；整源打不开就去设置页换一个源。'
            : '常见原因：站源已失效、播放地址需要专用解析器、或编码不被系统支持。')
            .fontSize(16).fontColor(T.PANEL_DIM).margin({ top: 16 })
            .textAlign(TextAlign.Center).width('80%')
          Row() {
            Text('重试')
              .fontSize(19).fontColor('#FFFFFF')
              .height(52).padding({ left: 38, right: 38 })
              .backgroundColor(this.retryHi ? T.PANEL_TXT : T.WHITE_15)
              .borderRadius(26).textAlign(TextAlign.Center)
              .animation({ duration: 120, curve: Curve.EaseOut })
              .onHover((hv: boolean) => this.onHoverRetry(hv))
              .onClick(() => this.onRetry())
            Text(this.isLive ? '返回频道列表' : '返回选集')
              .fontSize(19).fontColor('#FFFFFF')
              .height(52).padding({ left: 38, right: 38 })
              .backgroundColor(this.backHi ? T.PANEL_BTN_HI : T.WHITE_15)
              .borderRadius(26).textAlign(TextAlign.Center)
              .margin({ left: 18 })
              .animation({ duration: 120, curve: Curve.EaseOut })
              .onHover((hv: boolean) => this.onHoverBack(hv))
              .onClick(() => this.onBack())
          }
          .margin({ top: 28 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor(T.BLACK_80)
      }
    }
    .width('100%')
    .height('100%')
    // 关键：这层是铺满全屏的，默认 HitTestMode.Default 会把点击「吃掉」，
    // 导致播放页根节点上的 onClick / onMouse 收不到 —— 表现就是「点画面唤不出控制条、
    // 指针移动也不亮」。没有内容要显示时让命中测试穿透过去；
    // 只有真的有错误页时才拦截，保证「重试 / 返回」按钮不被下层抢走。
    .hitTestBehavior(this.errMsg.length > 0 ? HitTestMode.Default : HitTestMode.Transparent)
  }
}
