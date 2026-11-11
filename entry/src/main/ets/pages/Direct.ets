/**
 * 直连播放 —— 不经过任何站源，直接把一个地址交给播放器。
 *
 * 这个页面的存在有两层意思：
 *  1. 实用：家里 NAS / 路由器上挂的电影、单条直播流、别人发来的 m3u8，
 *     不用为了播一个文件去导入整套 TVBox 配置。
 *  2. 定位：应用市场审核看的就是「这个 App 到底有没有自己的内容」。
 *     把「手动填地址就能播」摆在首页，比在介绍里写「我们只是播放器」有说服力。
 *
 * 电视上敲地址很痛苦，所以同时提供扫码：手机与电视同一 Wi-Fi，扫码后粘地址提交，
 * 电视这边收到就开播（沿用设置页那套局域网服务，不经过任何外部服务器）。
 */

import { Feedback } from '../common/Feedback';
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { Store } from '../common/Store';
import { PlayParam, T } from '../common/Model';
import { Playlist } from '../common/Playlist';
import { Pointer } from '../common/Pointer';
import { QrCode } from '../common/QrCode';
import { QrServer } from '../common/QrServer';
import { Tip, TIP_MSG, TipLayer } from '../common/Tip';
import { Device, KEY_IS_PHONE } from '../common/Device';
import { Theme, KEY_THEME } from '../common/Theme';

@Entry
@Component
struct Direct {
  @State url: string = '';
  /** 全局轻提示（AppStorage 上的 TIP_MSG），Tip.show() 触发 */
  @StorageLink(TIP_MSG) tipMsg: string = '';
  @State recent: string[] = [];
  @State msg: string = '';
  @State msgColor: string = T.SUB;
  @State hoverKey: string = '';
  /** 扫码面板 */
  @State qrOpen: boolean = false;
  @State qrUrl: string = '';
  @State qrTip: string = '';
  @State qrHas: boolean = false;
  /** 设备形态：手机竖屏时扫码弹窗改上下排列（左右排列文字列太窄） */
  @StorageProp(KEY_IS_PHONE) isPhone: boolean = false;
  /** 当前主题。build 里必须用到（见 .id），否则换了色板不会重绘 */
  @StorageProp(KEY_THEME) themeMode: string = 'dark';

  private qrMatrix: boolean[][] = [];
  private qrSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private qrCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.qrSettings);
  private qrReady: boolean = false;
  private readonly QR_BOX: number = 200;

  async aboutToAppear(): Promise<void> {
    await Store.init(getContext(this) as common.UIAbilityContext);
    this.recent = await Store.directList();
    // 局域网注入入口：直连页存活期间起一个极简 HTTP 服务（端口见 QrServer.PORT），
    // 电脑侧可直接 POST 一个播放地址进来，省掉「遥控器/手机敲地址」的麻烦。
    // 注意：这里只起服务、不展示任何二维码——二维码（扫码录入 UI）仅 TV 端有，
    // 手机端按设计不出现任何二维码，所以这个服务在手机上也是「静默」存在的。
    QrServer.start((kind: string, value: string): Promise<string> => {
      this.play(value);
      return Promise.resolve('已开始播放：' + this.titleOf(value));
    });
  }

  aboutToDisappear(): void {
    QrServer.stop();
  }

  onBackPress(): boolean {
    if (this.qrOpen) {
      this.closeQr();
      return true;
    }
    router.back();
    return true;
  }

  hi(key: string): boolean {
    return this.hoverKey === key;
  }

  hover(key: string, on: boolean): void {
    if (on) {
      this.hoverKey = key;
    } else if (this.hoverKey === key) {
      this.hoverKey = '';
    }
  }

  /**
   * 开播。
   * 只放行 http/https 和本地文件路径：rtmp/rtsp 系统解码器吃不下，
   * 放进去只会让用户盯着黑屏等 20 秒。
   */
  async play(target: string): Promise<void> {
    const u: string = target.trim();
    if (u.length === 0) {
      this.msg = '先填一个地址';
      this.msgColor = T.WARN;
      return;
    }
    const ok: boolean = u.indexOf('http://') === 0 || u.indexOf('https://') === 0 ||
      u.indexOf('file://') === 0 || u.indexOf('/data/') === 0;
    if (!ok) {
      this.msg = '只支持 http / https / 本地文件路径，rtmp、rtsp 系统解码器播不了';
      this.msgColor = T.WARN;
      return;
    }
    this.msg = '';
    await Store.pushDirect(u);
    this.recent = await Store.directList();
    this.closeQr();

    // 直连是一个「孤立的」地址，没有上一集/下一集的概念。
    // 必须清空播放列表：否则里面还留着上一部剧的剧集，
    // 播完后 completed 回调 hasNext() 为真，会跳到上一部剧的下一集（串台）。
    Playlist.clear();

    const p = new PlayParam();
    p.url = u;
    p.title = this.titleOf(u);
    p.siteKey = '';
    p.vodId = '';
    p.from = 'direct';
    p.epIndex = 0;
    router.pushUrl({ url: 'pages/Player', params: p });
  }

  /** 从地址里取个像样的标题：最后一段去掉 query，再去掉扩展名 */
  titleOf(u: string): string {
    let s: string = u;
    const q: number = s.indexOf('?');
    if (q > 0) {
      s = s.substring(0, q);
    }
    const slash: number = s.lastIndexOf('/');
    if (slash >= 0 && slash < s.length - 1) {
      s = s.substring(slash + 1);
    }
    const dot: number = s.lastIndexOf('.');
    if (dot > 0) {
      s = s.substring(0, dot);
    }
    try {
      return decodeURIComponent(s);
    } catch (e) {
      return s;
    }
  }

  async openQr(): Promise<void> {
    this.qrOpen = true;
    this.qrHas = false;
    this.qrTip = '正在启动手机录入服务…';
    this.qrUrl = '';
    const base: string = await QrServer.start((kind: string, value: string): Promise<string> => {
      // 手机提交过来直接开播，省掉「电视上再点一次播放」
      this.play(value);
      return Promise.resolve('电视端已开始播放：' + this.titleOf(value));
    });
    if (base.length === 0) {
      this.qrTip = '没拿到本机 IP（设备可能没连 Wi-Fi）。可以点「本机地址」用遥控器填。';
      return;
    }
    const full: string = base + '?t=play';
    this.qrUrl = full;
    this.qrMatrix = QrCode.make(full);
    this.qrHas = this.qrMatrix.length > 0;
    if (!this.qrHas) {
      this.qrTip = '二维码生成失败，可在手机浏览器打开：' + full;
      return;
    }
    this.qrTip = '手机扫码 → 粘视频地址（m3u8 / mp4）→ 提交，电视立刻开始播放';
    this.drawQr();
  }

  closeQr(): void {
    this.qrOpen = false;
  }

  drawQr(): void {
    if (!this.qrReady || this.qrMatrix.length === 0) {
      return;
    }
    const n: number = this.qrMatrix.length;
    const quiet: number = 4;
    const total: number = n + quiet * 2;
    let unit: number = Math.floor(this.QR_BOX / total);
    if (unit < 1) {
      unit = 1;
    }
    const drawn: number = unit * total;
    const off: number = Math.floor((this.QR_BOX - drawn) / 2) + unit * quiet;
    this.qrCtx.fillStyle = '#FFFFFF';
    this.qrCtx.fillRect(0, 0, this.QR_BOX, this.QR_BOX);
    this.qrCtx.fillStyle = '#000000';
    for (let r = 0; r < n; r++) {
      for (let c = 0; c < n; c++) {
        if (this.qrMatrix[r][c]) {
          this.qrCtx.fillRect(off + c * unit, off + r * unit, unit, unit);
        }
      }
    }
  }

  @Builder
  Btn(label: string, key: string, primary: boolean, act: () => void) {
    Text(label)
      .fontSize(16)
      .height(48)
      .padding({ left: 26, right: 26 })
      .borderRadius(T.RADIUS_PILL)
      .backgroundColor(primary ? T.ACCENT : (this.hi(key) ? T.CARD_HI : T.CARD))
      .fontColor(primary ? T.BG : (this.hi(key) ? T.SELECTED : T.TXT))
      .border({
        width: T.BORDER,
        color: this.hi(key) ? (primary ? T.SELECTED : T.TXT) : '#00000000'
      })
      .textAlign(TextAlign.Center)
      .animation({ duration: T.ANIM, curve: Curve.EaseOut })
      .focusable(true)
      .onFocus(() => this.hover(key, true))
      .onBlur(() => this.hover(key, false))
      .onHover((hv: boolean) => this.hover(key, hv))
      .onClick(() => Pointer.fire('di_btn' + key, () => {
          Feedback.tap();
          act();
      }))
      .onMouse(Pointer.on('di_btn' + key, () => {
          Feedback.tap();
          act();
      }))
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Row() {
          Text('‹')
            .fontSize(34)
            .fontColor(this.hi('back') ? T.TXT : T.SUB)
            .width(40)
            .textAlign(TextAlign.Center)
            .focusable(true)
            .defaultFocus(true)
            .onFocus(() => this.hover('back', true))
            .onBlur(() => this.hover('back', false))
            .onHover((hv: boolean) => this.hover('back', hv))
            .onClick(() => Pointer.fire('di_back', () => {
                Feedback.tap();
                router.back();
            }))
            .onMouse(Pointer.on('di_back', () => {
                Feedback.tap();
                router.back();
            }))
          Text('直连播放')
            .fontSize(24).fontColor(T.TXT).margin({ left: 8 })
          Text('  不经过站源，直接播一个地址')
            .fontSize(14).fontColor(T.DIM)
        }
        .width('100%')
        .padding({ left: 24, right: 24, top: 24, bottom: 8 })

        Scroll() {
          Column() {
            Text('支持 http / https 的 m3u8、mp4，以及本机文件路径。\nNAS、路由器上挂的片子，或者别人发来的一条流，直接把地址粘进来就能播。')
              .fontSize(14).fontColor(T.SUB).width('100%').lineHeight(22)

            // 输入框用真 TextInput：这里就是要用户打字/粘贴，不是扫码入口
            Row() {
              TextInput({ text: this.url, placeholder: 'https://…/movie.m3u8' })
                .height(52)
                .layoutWeight(1)
                .fontSize(15)
                .fontColor(T.TXT)
                .placeholderColor(T.DIM)
                .backgroundColor(T.CARD)
                .borderRadius(T.RADIUS)
                .padding({ left: 16, right: 16 })
                .onChange((v: string) => {
                  this.url = v;
                  // 上一次的错误提示（比如「先填一个地址」）不会自动消失，
                  // 用户填好地址后还挂着这行红字，看着像还是错的
                  if (this.msg.length > 0) {
                    this.msg = '';
                  }
                })
                .onSubmit(() => {
                  this.play(this.url);
                })
            }
            .width('100%')
            .margin({ top: 14 })

            Row() {
              this.Btn('播放', 'go', true, () => {
                this.play(this.url);
              })
              // 二维码（扫码录入）仅 TV 端有；手机端按设计不出现任何二维码
              if (!this.isPhone) {
                this.Btn('手机扫码输入', 'scan', false, () => {
                  this.openQr();
                })
              }
              Blank()
            }
            .width('100%')
            .margin({ top: 14 })

            if (this.msg.length > 0) {
              Text(this.msg).fontSize(14).fontColor(this.msgColor).width('100%').margin({ top: 10 })
            }

            if (this.recent.length > 0) {
              Text('最近直连').fontSize(18).fontColor(T.TXT).width('100%').margin({ top: 26, bottom: 10 })
              Column() {
                ForEach(this.recent, (u: string, i: number) => {
                  Row() {
                    Column() {
                      Text(this.titleOf(u))
                        .fontSize(15).fontColor(T.TXT).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(u)
                        .fontSize(12).fontColor(T.DIM).margin({ top: 4 }).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Text('播放')
                      .fontSize(13).fontColor(T.SELECTED)
                  }
                  .width('100%')
                  .height(60)
                  .padding({ left: 14, right: 14 })
                  .borderRadius(T.RADIUS_SM)
                  .backgroundColor(this.hi('r_' + i) ? T.CARD_HI : T.CARD)
                  .border({ width: T.BORDER, color: this.hi('r_' + i) ? T.TXT : '#00000000' })
                  .margin({ bottom: 8 })
                  .animation({ duration: T.ANIM, curve: Curve.EaseOut })
                  .focusable(true)
                  .onFocus(() => this.hover('r_' + i, true))
                  .onBlur(() => this.hover('r_' + i, false))
                  .onHover((hv: boolean) => this.hover('r_' + i, hv))
                  .onClick(() => Pointer.fire('di_play' + u, () => {
                      Feedback.tap();
                      this.play(u);
                  }))
                  .onMouse(Pointer.on('di_play' + u, () => {
                      Feedback.tap();
                      this.play(u);
                  }))
                }, (u: string) => 'd' + u)
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding({ left: 24, right: 24, bottom: 30 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(T.pageBg(this.themeMode))

      if (this.qrOpen && !this.isPhone) {
        Stack() {
          Column()
            .width('100%').height('100%')
            .backgroundColor(T.BLACK_70)
            .onClick(() => Pointer.fire('di_qrx', () => {
                Feedback.tap();
                this.closeQr();
            }))
            .onMouse(Pointer.on('di_qrx', () => {
                Feedback.tap();
                this.closeQr();
            }))

          Column() {
            Row() {
              Text('手机扫码输入播放地址').fontSize(19).fontColor(T.TXT)
              Blank()
              Text('✕')
                .fontSize(19).fontColor(this.hi('qclose') ? T.TXT : T.SUB).width(42).height(42)
                .textAlign(TextAlign.Center)
                .borderRadius(T.RADIUS_SM)
                .backgroundColor(this.hi('qclose') ? T.CARD_HI : '#00000000')
                .focusable(true)
                .defaultFocus(true)
                .onFocus(() => this.hover('qclose', true))
                .onBlur(() => this.hover('qclose', false))
                .onHover((hv: boolean) => this.hover('qclose', hv))
                .onClick(() => Pointer.fire('di_qrx2', () => {
                    Feedback.tap();
                    this.closeQr();
                }))
                .onMouse(Pointer.on('di_qrx2', () => {
                    Feedback.tap();
                    this.closeQr();
                }))
            }
            .width('100%')

            Flex({
              direction: this.isPhone ? FlexDirection.Column : FlexDirection.Row,
              alignItems: this.isPhone ? ItemAlign.Start : ItemAlign.Center
            }) {
              Column() {
                if (this.qrHas) {
                  Canvas(this.qrCtx)
                    .width(this.QR_BOX).height(this.QR_BOX)
                    .onReady(() => {
                      this.qrReady = true;
                      this.drawQr();
                    })
                } else {
                  Column() {
                    LoadingProgress().width(32).height(32).color(T.SUB)
                    Text('生成中…').fontSize(12).fontColor(T.DIM).margin({ top: 6 })
                  }
                  .width(this.QR_BOX).height(this.QR_BOX)
                  .justifyContent(FlexAlign.Center)
                }
              }
              .width(this.QR_BOX + 20)
              .height(this.QR_BOX + 20)
              .backgroundColor('#FFFFFF')
              .borderRadius(T.RADIUS)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)

              Column() {
                Text(this.qrTip).fontSize(14)
                  .fontColor(this.qrUrl.length > 0 ? T.SUB : T.WARN)
                  .width('100%').lineHeight(22)
                if (this.qrUrl.length > 0) {
                  Text(this.qrUrl).fontSize(17).fontColor(T.SELECTED).margin({ top: 10 })
                }
                Text('提交后电视直接开播，不用再点一次。')
                  .fontSize(12).fontColor(T.DIM).margin({ top: 12 })
              }
              .layoutWeight(this.isPhone ? 0 : 1)
              .width(this.isPhone ? '100%' : '')
              .alignItems(HorizontalAlign.Start)
              .margin(this.isPhone ? { top: 18 } : { left: 22 })
            }
            .width('100%')
            .margin({ top: 18 })
          }
          .width(Device.panelW(620))
          .padding(24)
          .backgroundColor(T.SURFACE)
          .borderRadius(28)
          .alignItems(HorizontalAlign.Start)
          // 焦点锁在扫码面板内
          .focusScopeId('qr_panel', true)
        }
        .width('100%')
        .height('100%')
      }
      if (this.tipMsg.length > 0) {
        TipLayer({ msg: this.tipMsg })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(T.pageBg(this.themeMode))
    // id 带主题名：让 build 真正依赖 themeMode（否则换色板不重绘）
    .id('direct_' + this.themeMode)
  }
}
