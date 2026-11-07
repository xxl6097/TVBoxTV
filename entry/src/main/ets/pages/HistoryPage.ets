/**
 * 历史页 —— 对照 FongMi 的 activity_history.xml + adapter_vod_list.xml。
 *
 * 原版横条卡：48dp 缩略图 + 名称 16sp + 备注 14sp，整条可点。
 * 这里把备注位换成「看到第几集 + 时间」，信息密度更实用。
 */

import { Feedback } from '../common/Feedback';
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { Store, HistItem } from '../common/Store';
import { DetailParam, T } from '../common/Model';
import { Tip, TIP_MSG, TipLayer } from '../common/Tip';

@Entry
@Component
struct HistoryPage {
  @State hist: HistItem[] = [];
  /** 全局轻提示（AppStorage 上的 TIP_MSG），Tip.show() 触发 */
  @StorageLink(TIP_MSG) tipMsg: string = '';
  /** 「清空」的二次确认窗口：3 秒内再点一次才真清 */
  @State confirmClear: boolean = false;
  /** 「删除」单条的二次确认：存当前待确认的 siteKey+vodId，空串表示无待确认 */
  @State confirmDel: string = '';
  @State hoverKey: string = '';
  @State ready: boolean = false;

  async aboutToAppear(): Promise<void> {
    await Store.init(getContext(this) as common.UIAbilityContext);
    await this.reload();
    this.ready = true;
  }

  async onPageShow(): Promise<void> {
    if (this.ready) {
      await this.reload();
    }
  }

  onBackPress(): boolean {
    router.back();
    return true;
  }

  async reload(): Promise<void> {
    this.hist = await Store.history();
  }

  async clearAll(): Promise<void> {
    const n: number = this.hist.length;
    if (n === 0) {
      Tip.show('本来就没有记录');
      return;
    }
    // 二次确认：整表清空不可撤销，遥控器误触代价太大
    if (!this.confirmClear) {
      this.confirmClear = true;
      // 按钮同时变成「确认清空」：光靠底部提示不够，遥控器用户看完提示
      // 再找按钮经常超过 3 秒，窗口一过就白点一次。这里给 6 秒 + 按钮自解释。
      Tip.show('再点一次确认清空（共 ' + n + ' 条），6 秒内有效');
      setTimeout(() => {
        this.confirmClear = false;
      }, 6000);
      return;
    }
    this.confirmClear = false;
    await Store.clearHistory();
    await this.reload();
    Tip.show('已清空 ' + n + ' 条记录');
  }

  /** 单条删除（二次确认：遥控器误触不可恢复） */
  async removeOne(h: HistItem): Promise<void> {
    const key: string = h.siteKey + h.vodId;
    if (this.confirmDel !== key) {
      this.confirmDel = key;
      Tip.show('再点一次确认删除「' + h.name + '」，6 秒内有效');
      setTimeout(() => {
        if (this.confirmDel === key) {
          this.confirmDel = '';
        }
      }, 6000);
      return;
    }
    this.confirmDel = '';
    await Store.removeHistory(h);
    this.hist = await Store.history();
    Tip.show('已删除「' + h.name + '」');
  }

  ago(t: number): string {
    if (t <= 0) {
      return '';
    }
    const d: number = Date.now() - t;
    if (d < 60000) {
      return '刚刚';
    }
    if (d < 3600000) {
      return Math.floor(d / 60000) + ' 分钟前';
    }
    if (d < 86400000) {
      return Math.floor(d / 3600000) + ' 小时前';
    }
    return Math.floor(d / 86400000) + ' 天前';
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

  build() {
    Stack() {
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
          .onClick(() => {
            Feedback.tap();
            router.back();
          })
        Text('历史')
          .fontSize(24)
          .fontColor(T.TXT)
          .margin({ left: 8 })
        Text('  ' + this.hist.length + ' 条').fontSize(14).fontColor(T.SUB)
        Blank()
        if (this.hist.length > 0) {
          Text(this.confirmClear ? '确认清空？' : '清空')
            .fontSize(16)
            .fontColor(this.confirmClear ? T.ERR : T.TXT)
            .height(40)
            .padding({ left: 20, right: 20 })
            .borderRadius(T.RADIUS)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.hi('clr') ? T.CARD_HI : (this.confirmClear ? T.WHITE_15 : '#00000000'))
            .border({ width: T.BORDER, color: this.hi('clr') || this.confirmClear ? T.TXT : '#00000000' })
            .animation({ duration: T.ANIM, curve: Curve.EaseOut })
            .focusable(true)
            .onFocus(() => this.hover('clr', true))
            .onBlur(() => this.hover('clr', false))
            .onHover((hv: boolean) => this.hover('clr', hv))
            .onClick(() => {
              Feedback.tap();
              this.clearAll();
            })
        }
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 24, bottom: 8 })

      if (this.hist.length === 0) {
        Column() {
          Text('还没有播放记录').fontSize(18).fontColor(T.SUB)
          Text('看过的影片会出现在这里').fontSize(15).fontColor(T.DIM).margin({ top: 10 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.hist, (h: HistItem) => {
            ListItem() {
              Row() {
                Image(h.pic.length > 0 ? h.pic : $r('app.media.app_icon'))
                  .width(84)
                  .height(48)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(T.RADIUS)
                  .backgroundColor(T.CARD)
                Column() {
                  Text(h.name)
                    .fontSize(16)
                    .fontColor(T.TXT)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text((h.epName.length > 0 ? h.epName : '未开始') + '   ·   ' +
                    h.siteName + '   ·   ' + this.ago(h.time))
                    .fontSize(14)
                    .fontColor(T.SUB)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .margin({ left: 16 })

                // 单条删除：独立 onClick，不会冒泡触发整行的「进入详情」
                Text(this.confirmDel === (h.siteKey + h.vodId) ? '确认删除？' : '删除')
                  .fontSize(14)
                  .fontColor(this.confirmDel === (h.siteKey + h.vodId) ? T.ERR : T.SUB)
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .borderRadius(T.RADIUS)
                  .backgroundColor(this.hi('del_' + h.siteKey + h.vodId) ? T.CARD_HI : '#00000000')
                  .border({
                    width: T.BORDER,
                    color: this.hi('del_' + h.siteKey + h.vodId) ? T.TXT : '#00000000'
                  })
                  .focusable(true)
                  .onFocus(() => this.hover('del_' + h.siteKey + h.vodId, true))
                  .onBlur(() => this.hover('del_' + h.siteKey + h.vodId, false))
                  .onHover((hv: boolean) => this.hover('del_' + h.siteKey + h.vodId, hv))
                  .onClick(() => {
                    Feedback.tap();
                    this.removeOne(h);
                  })
              }
              .width('100%')
              .padding(16)
              .borderRadius(T.RADIUS)
              .backgroundColor(this.hi('h_' + h.siteKey + h.vodId) ? T.CARD_HI : '#00000000')
              .border({
                width: T.BORDER,
                color: this.hi('h_' + h.siteKey + h.vodId) ? T.TXT : '#00000000'
              })
              .animation({ duration: T.ANIM, curve: Curve.EaseOut })
              .focusable(true)
              .onFocus(() => this.hover('h_' + h.siteKey + h.vodId, true))
              .onBlur(() => this.hover('h_' + h.siteKey + h.vodId, false))
              .onHover((hv: boolean) => this.hover('h_' + h.siteKey + h.vodId, hv))
              .onClick(() => {
                Feedback.tap();
                const p = new DetailParam();
                p.siteKey = h.siteKey;
                p.siteName = h.siteName;
                p.vodId = h.vodId;
                router.pushUrl({ url: 'pages/Detail', params: p });
              })
            }
          }, (h: HistItem) => 'hist' + h.siteKey + h.vodId + h.time)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 24, right: 24, bottom: 24 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
      if (this.tipMsg.length > 0) {
        TipLayer(this.tipMsg)
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
