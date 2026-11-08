/**
 * WebDAV 网盘「扫码录入」面板（电视端）。
 *
 * 为什么单独抽成组件：设置页的「添加挂载」弹窗和网盘页的空态都要能扫码添加，
 * 两处逻辑一模一样（起本地服务 → 画二维码 → 收手机提交 → 探活 → 落盘），
 * 抽成 @Component 后各页面只需要挂一个 `if (open) { WdQrPanel({...}) }`。
 *
 * 链路：电视起 QrServer（局域网 HTTP）→ 二维码里是 http://<电视IP>:8788/?t=wd
 *       → 手机扫码打开表单 → 提交 JSON → 电视侧 Webdav.probe() 探活 → Store 落盘。
 * 全程不经过云，手机和电视同一个 Wi-Fi 即可；密码错了手机当场红字提示。
 *
 * 只给电视（遥控器）用：手机端本身就是输入设备，直接调起键盘更快。
 */

import { Feedback } from './Feedback';
import { Device } from './Device';
import { WebdavSource, T } from './Model';
import { Store } from './Store';
import { Webdav } from './Webdav';
import { QrCode } from './QrCode';
import { QrServer } from './QrServer';

/** 手机端表单提交的字段（JSON） */
interface WdForm {
  url?: string;
  name?: string;
  user?: string;
  pass?: string;
  root?: string;
}

@Component
export struct WdQrPanel {
  /** 关闭面板（点遮罩 / ✕ / 遥控器返回都走这里） */
  onClose: () => void = () => {
  };
  /** 保存成功：父页面刷新源列表，顺手把弹窗收起来 */
  onSaved: (src: WebdavSource) => void = () => {
  };

  @State qrUrl: string = '';
  @State qrTip: string = '';
  @State qrHas: boolean = false;
  @State busy: boolean = false;
  @State hoverKey: string = '';

  private matrix: boolean[][] = [];
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;
  /** 二维码画布边长（vp） */
  private readonly BOX: number = 200;

  async aboutToAppear(): Promise<void> {
    this.qrTip = '正在启动手机录入服务…';
    const base: string = await QrServer.start((kind: string, value: string): Promise<string> => {
      return this.save(kind, value);
    });
    if (base.length === 0) {
      this.qrTip = '没拿到电视的局域网 IP（可能没连 Wi-Fi）。关掉本窗口，用遥控器逐项填写。';
      return;
    }
    const full: string = base + '?t=wd';
    this.qrUrl = full;
    this.matrix = QrCode.make(full);
    this.qrHas = this.matrix.length > 0;
    this.qrTip = this.qrHas
      ? '手机和电视连同一个 Wi-Fi → 扫码 → 填地址和账号密码 → 提交。电视这边会自动测试连接并保存。'
      : ('二维码生成失败，可在手机浏览器直接打开：' + full);
    this.draw();
  }

  aboutToDisappear(): void {
    // 离开面板就不再接受手机写入，避免后台被人往配置里塞东西
    QrServer.stop();
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

  /** 手机提交：解析 → 探活 → 落盘。返回给手机显示的一句话 */
  async save(kind: string, value: string): Promise<string> {
    if (kind !== 'wd') {
      return '这个面板只接受网盘信息';
    }
    let f: WdForm = { url: '', name: '', user: '', pass: '', root: '' };
    try {
      f = JSON.parse(value) as WdForm;
    } catch (e) {
      return '提交的内容格式不对，请重新填写';
    }
    const url: string = WdQrPanel.str(f.url);
    if (url.length === 0) {
      return '服务器地址不能为空';
    }
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      return '地址要以 http:// 或 https:// 开头';
    }

    const src = new WebdavSource();
    src.url = url;
    src.user = WdQrPanel.str(f.user);
    src.pass = WdQrPanel.str(f.pass);
    src.root = WdQrPanel.str(f.root);
    const name: string = WdQrPanel.str(f.name);
    src.name = name.length > 0 ? name : Webdav.hostOf(url);

    this.busy = true;
    this.qrTip = '手机正在提交「' + src.name + '」，测试连接中…';
    // 先探活再落盘：地址错、密码错在这里就拦住，不把坏配置写进列表
    let count: number = 0;
    try {
      count = await Webdav.probe(src);
    } catch (err) {
      const e = err as Error;
      this.busy = false;
      this.qrTip = '「' + src.name + '」连接失败，未保存：' + e.message;
      return '连接失败，未保存：' + e.message;
    }

    try {
      await Store.saveWebdavSource(src);
    } catch (err) {
      const e = err as Error;
      this.busy = false;
      return '保存失败：' + e.message;
    }
    this.busy = false;
    this.qrTip = '已保存「' + src.name + '」，根目录 ' + count + ' 项';
    // 等手机的响应先回去再收面板：面板一消失 QrServer 就不再接写入，
    // 立刻关掉会让手机那边只看到 "网络错误"，误以为没保存成功。
    const saved: WebdavSource = src;
    setTimeout(() => {
      this.onSaved(saved);
    }, 700);
    return '已保存「' + src.name + '」，根目录 ' + count + ' 项，电视端可以直接浏览了';
  }

  private static str(s: string | undefined): string {
    return s === undefined || s === null ? '' : s.trim();
  }

  /** 整数倍模块 + 四周留白，边缘锐利才好扫 */
  draw(): void {
    if (!this.ready || this.matrix.length === 0) {
      return;
    }
    const n: number = this.matrix.length;
    const quiet: number = 4;
    const total: number = n + quiet * 2;
    let unit: number = Math.floor(this.BOX / total);
    if (unit < 1) {
      unit = 1;
    }
    const drawn: number = unit * total;
    const off: number = Math.floor((this.BOX - drawn) / 2) + unit * quiet;
    this.ctx.fillStyle = '#FFFFFF';
    this.ctx.fillRect(0, 0, this.BOX, this.BOX);
    this.ctx.fillStyle = '#000000';
    for (let r = 0; r < n; r++) {
      for (let c = 0; c < n; c++) {
        if (this.matrix[r][c]) {
          this.ctx.fillRect(off + c * unit, off + r * unit, unit, unit);
        }
      }
    }
  }

  build() {
    Stack() {
      // 遮罩：点一下即关
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(T.BLACK_70)
        .onClick(() => {
          Feedback.tap();
          this.onClose();
        })

      Column() {
        Row() {
          Column() {
            Text('扫码添加网盘')
              .fontSize(20)
              .fontColor(T.TXT)
            Text('电视上敲地址太费劲，用手机填完提交，电视直接保存')
              .fontSize(13)
              .fontColor(T.DIM)
              .margin({ top: 6 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('✕')
            .fontSize(20)
            .fontColor(this.hi('wqx') ? T.SELECTED : T.SUB)
            .width(44)
            .height(44)
            .textAlign(TextAlign.Center)
            .borderRadius(T.RADIUS_PILL)
            .backgroundColor(this.hi('wqx') ? T.CARD_HI : '#00000000')
            .focusable(true)
            .onFocus(() => this.hover('wqx', true))
            .onBlur(() => this.hover('wqx', false))
            .onHover((hv: boolean) => this.hover('wqx', hv))
            .onClick(() => {
              Feedback.tap();
              this.onClose();
            })
        }
        .width('100%')

        Row() {
          // 白底留白：深色面板上直接贴黑码，相机对焦会失败
          Column() {
            if (this.qrHas) {
              Canvas(this.ctx)
                .width(this.BOX)
                .height(this.BOX)
                .onReady(() => {
                  this.ready = true;
                  this.draw();
                })
            } else {
              Column() {
                LoadingProgress().width(36).height(36).color(T.SUB)
                Text('生成中…').fontSize(13).fontColor(T.DIM).margin({ top: 8 })
              }
              .width(this.BOX)
              .height(this.BOX)
              .justifyContent(FlexAlign.Center)
            }
          }
          .width(this.BOX + 24)
          .height(this.BOX + 24)
          .backgroundColor('#FFFFFF')
          .borderRadius(T.RADIUS)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)

          Column() {
            Text(this.qrTip)
              .fontSize(14)
              .fontColor(this.qrUrl.length > 0 ? T.SUB : T.WARN)
              .width('100%')
              .lineHeight(22)

            if (this.qrUrl.length > 0) {
              Text(this.qrUrl)
                .fontSize(19)
                .fontColor(T.SELECTED)
                .margin({ top: 10 })
            }

            Text('也可以关掉本窗口，用遥控器逐项填写。')
              .fontSize(12)
              .fontColor(T.DIM)
              .margin({ top: 14 })

            Text(this.busy ? '测试中…' : '关闭')
              .fontSize(15)
              .fontColor(T.TXT)
              .height(42)
              .padding({ left: 24, right: 24 })
              .borderRadius(T.RADIUS_PILL)
              .border({ width: T.BORDER, color: this.hi('wqo') ? T.TXT : T.WHITE_30 })
              .backgroundColor(this.hi('wqo') ? T.CARD_HI : '#00000000')
              .margin({ top: 12 })
              .textAlign(TextAlign.Center)
              .focusable(true)
              .onFocus(() => this.hover('wqo', true))
              .onBlur(() => this.hover('wqo', false))
              .onHover((hv: boolean) => this.hover('wqo', hv))
              .onClick(() => {
                Feedback.tap();
                this.onClose();
              })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 24 })
        }
        .width('100%')
        .margin({ top: 20 })
        .alignItems(VerticalAlign.Center)
      }
      .width(Device.panelW(660))
      .padding(24)
      .backgroundColor(T.SURFACE)
      .borderRadius(28)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
