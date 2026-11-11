/**
 * 收藏页 —— 对照 FongMi 的 activity_collect.xml + adapter_collect.xml。
 * 网格卡片沿用 adapter_vod_rect 的样式，右上角挂删除按钮。
 */

import { Feedback } from '../common/Feedback';
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { Store, FavItem, FavGroupDef } from '../common/Store';
import { DetailParam, T } from '../common/Model';
import { Tip, TIP_MSG, TipLayer } from '../common/Tip';
import { Device, KEY_IS_PHONE } from '../common/Device';
import { Theme, KEY_THEME } from '../common/Theme';
import { PhoneTabBar } from '../common/PhoneTabBar';
import { Pointer } from '../common/Pointer';
import { Poster } from '../common/Poster';

/** 收藏分组：一个站源下的所有收藏 */
class FavGroup {
  siteName: string = '';
  items: FavItem[] = [];
}

@Entry
@Component
struct CollectPage {
  @StorageProp(KEY_IS_PHONE) isPhone: boolean = false;
  /** 当前主题。build 里必须用到（见 .id），否则换了色板不会重绘 */
  @StorageProp(KEY_THEME) themeMode: string = 'dark';
  @State favs: FavItem[] = [];
  /** 全局轻提示（AppStorage 上的 TIP_MSG），Tip.show() 触发 */
  @StorageLink(TIP_MSG) tipMsg: string = '';
  @State hoverKey: string = '';
  @State ready: boolean = false;
  /** 待二次确认的收藏项键（siteKey+vodId） */
  @State confirmDel: string = '';
  /** 是否按站源分组展示 */
  @State grouped: boolean = false;
  /** 自定义分组列表（用户自己建的） */
  @State groups: FavGroupDef[] = [];
  /** 当前筛选的分组 ID，空串 = 全部 */
  @State curGroup: string = '';
  /** 分组选择浮层 */
  @State showGroups: boolean = false;
  /** 新建分组输入框 */
  @State showNewGroup: boolean = false;
  @State newGroupName: string = '';
  /** 正在等待「移入哪个分组」的收藏项 */
  @State moveTarget: FavItem | null = null;
  /** 上次长按时间，用来吞掉长按抬手补发的 click */
  private lastLongPress: number = 0;

  async aboutToAppear(): Promise<void> {
    await Store.init(getContext(this) as common.UIAbilityContext);
    // 开收藏同步时，先拉一次云端合并，再读本地——否则刚从别的设备收藏的还没进来
    await Store.pullFavFromWebDAV().catch(() => {});
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
    this.groups = await Store.favGroups();
  }

  /** 当前筛选后的收藏（curGroup 为空 = 全部） */
  visibleFavs(): FavItem[] {
    if (this.curGroup.length === 0) {
      return this.favs;
    }
    const out: FavItem[] = [];
    // '__none' 是「未分组」虚拟项：筛 groupId 为空串的那些
    const want: string = this.curGroup === '__none' ? '' : this.curGroup;
    for (let i = 0; i < this.favs.length; i++) {
      if (this.favs[i].groupId === want) {
        out.push(this.favs[i]);
      }
    }
    return out;
  }

  /** 某个分组下的收藏数 */
  groupCount(id: string): number {
    let n: number = 0;
    for (let i = 0; i < this.favs.length; i++) {
      if (this.favs[i].groupId === id) {
        n++;
      }
    }
    return n;
  }

  async createGroup(): Promise<void> {
    const g: FavGroupDef | null = await Store.addFavGroup(this.newGroupName);
    if (g === null) {
      Tip.show(this.newGroupName.trim().length === 0 ? '分组名不能为空'
        : (this.groups.length >= 20 ? '最多 20 个分组' : '已有同名分组'));
      return;
    }
    this.newGroupName = '';
    this.showNewGroup = false;
    await this.reload();
    Tip.show('已新建分组「' + g.name + '」');
  }

  async removeGroup(id: string): Promise<void> {
    await Store.delFavGroup(id);
    if (this.curGroup === id) {
      this.curGroup = '';
    }
    await this.reload();
    Tip.show('已删除分组，里面的收藏已退回「未分组」');
  }

  /** 把 moveTarget 移到分组 */
  async doMove(groupId: string): Promise<void> {
    const f: FavItem | null = this.moveTarget;
    if (f === null) {
      return;
    }
    const ok: boolean = await Store.moveFavToGroup(f, groupId);
    this.moveTarget = null;
    await this.reload();
    if (!ok) {
      Tip.show('这条收藏已不存在');
      return;
    }
    const name: string = groupId.length === 0 ? '未分组'
      : (this.groupNameOf(groupId));
    Tip.show('已移到「' + name + '」');
  }

  groupNameOf(id: string): string {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].id === id) {
        return this.groups[i].name;
      }
    }
    return '未分组';
  }

  /**
   * 取消收藏。
   *
   * 两个修正：
   *  1. 用 removeFavorite 而不是 toggleFavorite —— 后者是翻转，
   *     列表过期时会把这条加回去，提示却还是「已取消收藏」
   *  2. 二次确认。和历史页删除保持一致：电视上指针/遥控误触一下
   *     收藏就没了，而同一批数据在首页单条删除是要确认的，两套标准很怪
   */
  async del(f: FavItem): Promise<void> {
    const key: string = f.siteKey + f.vodId;
    if (this.confirmDel !== key) {
      this.confirmDel = key;
      Tip.show('再点一次确认取消收藏「' + f.name + '」，6 秒内有效');
      setTimeout(() => {
        if (this.confirmDel === key) {
          this.confirmDel = '';
        }
      }, 6000);
      return;
    }
    this.confirmDel = '';
    const ok: boolean = await Store.removeFavorite(f);
    await this.reload();
    Tip.show(ok ? ('已取消收藏：' + f.name) : ('「' + f.name + '」已不在收藏里'));
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

  /** 按站源分组，每组内按收藏时间倒序，没有 time 字段的排最后 */
  groupedFavs(): FavGroup[] {
    const map: Map<string, FavGroup> = new Map();
    // 走 visibleFavs()：自定义分组筛选与「按站源分组」可以叠加
    const src: FavItem[] = this.visibleFavs();
    for (let i = 0; i < src.length; i++) {
      const f: FavItem = src[i];
      const key: string = f.siteName.length > 0 ? f.siteName : f.siteKey;
      let g: FavGroup | undefined = map.get(key);
      if (g === undefined) {
        g = new FavGroup();
        g.siteName = key;
        map.set(key, g);
      }
      g.items.push(f);
    }
    const groups: FavGroup[] = [];
    map.forEach((g: FavGroup) => {
      g.items.sort((a: FavItem, b: FavItem) => (b.time || 0) - (a.time || 0));
      groups.push(g);
    });
    return groups;
  }

  /** 提取 Grid 中的卡片内容，供平铺和分组两种布局复用 */
  @Builder
  FavCard(f: FavItem) {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Poster({ url: f.pic, bot: 0 })
          .width('100%')
          .height('100%')
        Text(this.confirmDel === (f.siteKey + f.vodId) ? '删' : '×')
          .fontSize(16)
          .fontColor(this.confirmDel === (f.siteKey + f.vodId) ? T.ERR : T.TXT)
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
          .onClick(() => Pointer.fire('cp_del' + f.siteKey + f.vodId, () => {
              Feedback.tap();
              this.del(f);
          }))
          .onMouse(Pointer.on('cp_del' + f.siteKey + f.vodId, () => {
              Feedback.tap();
              this.del(f);
          }))
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
    // 长按卡片 → 移入分组。收藏页原本只有「删除」一个操作入口，
    // 分类得进设置，这里给个就地入口；记住长按时间是为了吞掉随后的 click
    .gesture(
      LongPressGesture({ duration: 500 })
        .onAction(() => {
          Feedback.tap();
          this.lastLongPress = Date.now();
          this.moveTarget = f;
        })
    )
    .onFocus(() => this.hover('f_' + f.siteKey + f.vodId, true))
    .onBlur(() => this.hover('f_' + f.siteKey + f.vodId, false))
    .onHover((hv: boolean) => this.hover('f_' + f.siteKey + f.vodId, hv))
    .onClick(() => Pointer.fire('cp_open' + f.siteKey + f.vodId, () => {
        // 长按抬手后会补一次 click，1 秒内吞掉，否则「想分组」变成「进了详情页」
        if (Date.now() - this.lastLongPress < 1000) {
          return;
        }
        Feedback.tap();
        const p = new DetailParam();
        p.siteKey = f.siteKey;
        p.siteName = f.siteName;
        p.vodId = f.vodId;
        router.pushUrl({ url: 'pages/Detail', params: p });
    }))
    .onMouse(Pointer.on('cp_open' + f.siteKey + f.vodId, () => {
        Feedback.tap();
        const p = new DetailParam();
        p.siteKey = f.siteKey;
        p.siteName = f.siteName;
        p.vodId = f.vodId;
        router.pushUrl({ url: 'pages/Detail', params: p });
    }))
  }

  /**
   * 分组管理浮层：切换筛选、新建、删除。
   *
   * 删除只删分组本身，组里的收藏退回「未分组」—— 顺带删收藏太吓人，
   * 用户建分组的目的通常只是归类。
   */
  @Builder
  GroupPanel() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor('#B3000000')
        .onClick(() => {
          Feedback.tap();
          this.showGroups = false;
          this.showNewGroup = false;
          this.newGroupName = '';
        })

      Column() {
        Row() {
          Text('收藏分组').fontSize(19).fontColor(T.TXT)
          Blank()
          Text('✕')
            .fontSize(18)
            .fontColor(this.hi('gp_x') ? T.TXT : T.SUB)
            .width(36).height(36)
            .textAlign(TextAlign.Center)
            .borderRadius(T.RADIUS_SM)
            .backgroundColor(this.hi('gp_x') ? T.CARD_HI : '#00000000')
            .onHover((hv: boolean) => this.hover('gp_x', hv))
            .onClick(() => {
              Feedback.tap();
              this.showGroups = false;
              this.showNewGroup = false;
              this.newGroupName = '';
            })
        }
        .width('100%')
        .padding({ bottom: 12 })

        // 「全部」与「未分组」是虚拟分组，计数实时算
        this.GroupRow('全部收藏', '', this.favs.length)
        this.GroupRow('未分组', '__none', this.groupCount(''))
        ForEach(this.groups, (g: FavGroupDef) => {
          this.GroupRow(g.name, g.id, this.groupCount(g.id))
        }, (g: FavGroupDef) => 'g_' + g.id)

        if (this.showNewGroup) {
          TextInput({ placeholder: '分组名称', text: this.newGroupName })
            .placeholderColor(T.DIM)
            .fontSize(15)
            .fontColor(T.TXT)
            .height(44)
            .padding({ left: 14, right: 14 })
            .backgroundColor(T.CARD)
            .borderRadius(T.RADIUS_SM)
            .width('100%')
            .margin({ top: 10 })
            .onChange((v: string) => {
              this.newGroupName = v;
            })
            .onSubmit(() => {
              this.createGroup();
            })
          Row() {
            Text('取消')
              .fontSize(14).fontColor(T.SUB)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .borderRadius(T.RADIUS_PILL)
              .backgroundColor(T.CARD)
              .onClick(() => {
                Feedback.tap();
                this.showNewGroup = false;
                this.newGroupName = '';
              })
            Text('创建')
              .fontSize(14).fontColor(T.SELECTED)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .margin({ left: 8 })
              .borderRadius(T.RADIUS_PILL)
              .backgroundColor(T.CARD)
              .onClick(() => {
                Feedback.tap();
                this.createGroup();
              })
          }
          .width('100%')
          .margin({ top: 10 })
        } else {
          Text('+ 新建分组')
            .fontSize(15)
            .fontColor(T.SELECTED)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 10, bottom: 10 })
            .margin({ top: 6 })
            .borderRadius(T.RADIUS_SM)
            .backgroundColor(this.hi('gp_new') ? T.CARD_HI : '#00000000')
            .onHover((hv: boolean) => this.hover('gp_new', hv))
            .onClick(() => {
              Feedback.tap();
              this.showNewGroup = true;
            })
        }
      }
      .width(Device.panelW(520))
      .constraintSize({ maxHeight: '70%' })
      .padding(20)
      .backgroundColor(T.SURFACE)
      .borderRadius(24)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%')
  }

  /** 分组浮层里的一行 */
  @Builder
  GroupRow(label: string, id: string, count: number) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor(this.curGroup === id ? T.SELECTED : T.TXT)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('' + count)
        .fontSize(13).fontColor(T.DIM)
        .margin({ right: 10 })
      // 自定义分组才给删除入口（全部/未分组是虚拟分组，删不了）
      if (id.length > 0 && id !== '__none') {
        Text('删除')
          .fontSize(13).fontColor(T.WARN)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(T.RADIUS_SM)
          .onClick(() => {
            Feedback.tap();
            this.removeGroup(id);
          })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 9, bottom: 9 })
    .borderRadius(T.RADIUS_SM)
    .backgroundColor(this.hi('gr_' + id) ? T.CARD_HI : '#00000000')
    .onHover((hv: boolean) => this.hover('gr_' + id, hv))
    .onClick(() => {
      Feedback.tap();
      this.curGroup = id;
      this.showGroups = false;
    })
  }

  /** 「移入分组」浮层 */
  @Builder
  MovePanel() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor('#B3000000')
        .onClick(() => {
          Feedback.tap();
          this.moveTarget = null;
        })

      Column() {
        Text('移入分组')
          .fontSize(18).fontColor(T.TXT)
          .width('100%')
          .padding({ bottom: 4 })
        if (this.moveTarget !== null) {
          Text(this.moveTarget.name)
            .fontSize(13).fontColor(T.DIM)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ bottom: 12 })
        }
        this.MoveRow('未分组', '')
        ForEach(this.groups, (g: FavGroupDef) => {
          this.MoveRow(g.name, g.id)
        }, (g: FavGroupDef) => 'mv_' + g.id)
      }
      .width(Device.panelW(460))
      .constraintSize({ maxHeight: '70%' })
      .padding(20)
      .backgroundColor(T.SURFACE)
      .borderRadius(24)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%')
  }

  @Builder
  MoveRow(label: string, id: string) {
    Text(label)
      .fontSize(15)
      .fontColor(T.TXT)
      .width('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: 10 })
      .margin({ top: 4 })
      .borderRadius(T.RADIUS_SM)
      .backgroundColor(this.hi('mv_' + id) ? T.CARD_HI : '#00000000')
      .onHover((hv: boolean) => this.hover('mv_' + id, hv))
      .onClick(() => {
        Feedback.tap();
        this.doMove(id);
      })
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
          .onClick(() => Pointer.fire('cp_back', () => {
              Feedback.tap();
              router.back();
          }))
          .onMouse(Pointer.on('cp_back', () => {
              Feedback.tap();
              router.back();
          }))
        Text('收藏')
          .fontSize(24)
          .fontColor(T.TXT)
          .margin({ left: 8 })
        Text('  ' + this.favs.length + ' 部').fontSize(14).fontColor(T.SUB)
        Blank()
        // 自定义分组入口：建了分组才显示，避免空白状态下多一排按钮
        if (this.groups.length > 0) {
          Text(this.curGroup.length === 0 ? '分组' : ('分组：' + this.groupNameOf(this.curGroup)))
            .fontSize(15)
            .fontColor(this.curGroup.length > 0 ? T.SELECTED : (this.hi('cp_gsel') ? T.TXT : T.SUB))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .margin({ right: 4 })
            .borderRadius(T.RADIUS_PILL)
            .backgroundColor(this.hi('cp_gsel') ? T.CARD_HI : '#00000000')
            .animation({ duration: T.ANIM, curve: Curve.EaseOut })
            .focusable(true)
            .onFocus(() => this.hover('cp_gsel', true))
            .onBlur(() => this.hover('cp_gsel', false))
            .onHover((hv: boolean) => this.hover('cp_gsel', hv))
            .onClick(() => Pointer.fire('cp_gsel', () => {
                Feedback.tap();
                this.showGroups = true;
            }))
            .onMouse(Pointer.on('cp_gsel', () => {
                Feedback.tap();
                this.showGroups = true;
            }))
        }
        // 分组切换按钮
        Text(this.grouped ? '取消分组' : '按站源分组')
          .fontSize(15)
          .fontColor(this.hi('cp_grp') ? T.SELECTED : T.SUB)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(T.RADIUS_PILL)
          .backgroundColor(this.hi('cp_grp') ? T.CARD_HI : '#00000000')
          .animation({ duration: T.ANIM, curve: Curve.EaseOut })
          .visibility(this.favs.length > 0 ? Visibility.Visible : Visibility.None)
          .focusable(true)
          .onFocus(() => this.hover('cp_grp', true))
          .onBlur(() => this.hover('cp_grp', false))
          .onHover((hv: boolean) => this.hover('cp_grp', hv))
          .onClick(() => Pointer.fire('cp_grp', () => {
              Feedback.tap();
              this.grouped = !this.grouped;
          }))
          .onMouse(Pointer.on('cp_grp', () => {
              Feedback.tap();
              this.grouped = !this.grouped;
          }))
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 24, bottom: 8 })

      if (this.visibleFavs().length === 0) {
        Column() {
          Text(this.curGroup.length > 0 ? '这个分组还没有收藏' : '还没有收藏').fontSize(18).fontColor(T.SUB)
          Text('在详情页点「收藏」后会出现在这里')
            .fontSize(15).fontColor(T.DIM).margin({ top: 10 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.grouped) {
        // 分组模式：按站源分节
        Scroll() {
          Column() {
            ForEach(this.groupedFavs(), (g: FavGroup, gi: number) => {
              Text(g.siteName + ' (' + g.items.length + ')')
                .fontSize(18).fontColor(T.SUB)
                .width('100%')
                .margin({ top: gi === 0 ? 0 : 24, bottom: 10 })
              Grid() {
                ForEach(g.items, (f: FavItem) => {
                  GridItem() {
                    this.FavCard(f)
                  }
                }, (f: FavItem) => 'fav_g' + gi + '_' + f.siteKey + f.vodId)
              }
              .columnsTemplate(this.isPhone ? '1fr 1fr 1fr' : '1fr 1fr 1fr 1fr 1fr 1fr')
              .columnsGap(12)
              .rowsGap(20)
              .width('100%')
            }, (g: FavGroup, gi: number) => 'grp_' + gi + '_' + g.siteName)
          }
          .width('100%')
          .padding({ left: 24, right: 24, bottom: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        Grid() {
          ForEach(this.visibleFavs(), (f: FavItem) => {
            GridItem() {
              this.FavCard(f)
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
        TipLayer({ msg: this.tipMsg })
      }
      if (this.showGroups) {
        this.GroupPanel()
      }
      if (this.moveTarget !== null) {
        this.MovePanel()
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    .backgroundColor(T.pageBg(this.themeMode))
    // id 带主题名：让 build 真正依赖 themeMode（否则换色板不重绘）
    .id('collect_' + this.themeMode)
  }
}
