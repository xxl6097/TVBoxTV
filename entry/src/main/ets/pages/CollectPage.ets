/**
 * 收藏页 —— 对照 FongMi 的 activity_collect.xml + adapter_collect.xml。
 * 网格卡片沿用 adapter_vod_rect 的样式，右上角挂删除按钮。
 */

import { Feedback } from '../common/Feedback';
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { Store, FavItem } from '../common/Store';
import { DetailParam, T } from '../common/Model';
import { Tip, TIP_MSG, TipLayer } from '../common/Tip';
import { KEY_IS_PHONE } from '../common/Device';
import { PhoneTabBar } from '../common/PhoneTabBar';

@Entry
@Component
struct CollectPage {
  @StorageProp(KEY_IS_PHONE) isPhone: boolean = false;
  @State favs: FavItem[] = [];
  /** 全局轻提示（AppStorage 上的 TIP_MSG），Tip.show() 触发 */
  @StorageLink(TIP_MSG) tipMsg: string = '';
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
    this.favs = await Store.favorites();
  }

  async del(f: FavItem): Promise<void> {
    // 删除后列表会变短，用户需要知道「确实是删了」而不是点歪了
    await Store.toggleFavorite(f);
    await this.reload();
    Tip.show('已取消收藏：' + f.name);
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
        Text('收藏')
          .fontSize(24)
          .fontColor(T.TXT)
          .margin({ left: 8 })
        Text('  ' + this.favs.length + ' 部').fontSize(14).fontColor(T.SUB)
        Blank()
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 24, bottom: 8 })

      if (this.favs.length === 0) {
        Column() {
          Text('还没有收藏').fontSize(18).fontColor(T.SUB)
          Text('在详情页点「收藏」后会出现在这里')
            .fontSize(15).fontColor(T.DIM).margin({ top: 10 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Grid() {
          ForEach(this.favs, (f: FavItem) => {
            GridItem() {
              Column() {
                Stack({ alignContent: Alignment.TopEnd }) {
                  Image(f.pic.length > 0 ? f.pic : $r('app.media.app_icon'))
                    .width('100%')
                    .height('100%')
                    .objectFit(ImageFit.Cover)
                    .backgroundColor(T.CARD)
                    .borderRadius({ topLeft: T.RADIUS, topRight: T.RADIUS })
                  Text('×')
                    .fontSize(16)
                    .fontColor(T.TXT)
                    .backgroundColor(this.hi('x_' + f.siteKey + f.vodId) ? T.BLACK_80 : T.CARD_HI)
                    .width(26)
                    .height(26)
                    .borderRadius(13)
                    .textAlign(TextAlign.Center)
                    .margin(6)
                    .focusable(true)
                    .onFocus(() => this.hover('x_' + f.siteKey + f.vodId, true))
                    .onBlur(() => this.hover('x_' + f.siteKey + f.vodId, false))
                    .onHover((hv: boolean) => this.hover('x_' + f.siteKey + f.vodId, hv))
                    .onClick(() => {
                      Feedback.tap();
                      this.del(f);
                    })
                }
                .width('100%')
                .aspectRatio(16 / 9)

                Text(f.name)
                  .fontSize(16)
                  .fontColor(T.TXT)
                  .backgroundColor(T.CARD)
                  .width('100%')
                  .padding(6)
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .borderRadius({ bottomLeft: T.RADIUS, bottomRight: T.RADIUS })
              }
              .width('100%')
              .borderRadius(T.RADIUS)
              .border({ width: T.BORDER, color: this.hi('f_' + f.siteKey + f.vodId) ? T.TXT : '#00000000' })
              .animation({ duration: T.ANIM, curve: Curve.EaseOut })
              .focusable(true)
              .onFocus(() => this.hover('f_' + f.siteKey + f.vodId, true))
              .onBlur(() => this.hover('f_' + f.siteKey + f.vodId, false))
              .onHover((hv: boolean) => this.hover('f_' + f.siteKey + f.vodId, hv))
              .onClick(() => {
                Feedback.tap();
                const p = new DetailParam();
                p.siteKey = f.siteKey;
                p.siteName = f.siteName;
                p.vodId = f.vodId;
                router.pushUrl({ url: 'pages/Detail', params: p });
              })
            }
          }, (f: FavItem) => 'fav' + f.siteKey + f.vodId)
        }
        .columnsTemplate(this.isPhone ? '1fr 1fr 1fr' : '1fr 1fr 1fr 1fr 1fr 1fr')
        .columnsGap(12)
        .rowsGap(20)
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 24, right: 24, top: 8, bottom: 24 })
        .scrollBar(BarState.Off)
      }
      if (this.isPhone) {
        PhoneTabBar('pages/CollectPage')
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
