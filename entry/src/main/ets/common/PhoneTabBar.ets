/**
 * 手机端底部 Tab 导航 —— 全局共享，供首页和各子页面复用。
 *
 * 电视端没有这个：电视用顶部功能行 + 遥控器焦点导航。
 * 手机端首页和各功能页底部都放同一个栏，用户不用回首页就能切换页面。
 *
 * active 传「当前页面的路由」，对应项高亮、点击不重复跳转（避免页面无限堆叠）；
 * 首页传空字符串（首页不属于任何子页面 Tab）。
 */

import router from '@ohos.router';
import { T } from './Model';

function tabIcon(label: string): Resource {
  if (label === '直播') {
    return $r('app.media.ic_live');
  }
  if (label === '搜索') {
    return $r('app.media.ic_search');
  }
  if (label === '收藏') {
    return $r('app.media.ic_collect');
  }
  if (label === '设置') {
    return $r('app.media.ic_setting');
  }
  return $r('app.media.ic_vod');
}

/** 单个 Tab 项：图标 + 文字，整块可点 */
@Builder
function TabItem(label: string, page: string, active: string) {
  Column() {
    Image(tabIcon(label))
      .width(20)
      .height(20)
      .objectFit(ImageFit.Contain)
      // 白色单色 svg：浅色主题下要染色，否则图标消失（只剩文字）
      .fillColor(page === active ? T.SELECTED : T.SUB)
    Text(label)
      .fontSize(11)
      .fontColor(page === active ? T.SELECTED : T.SUB)
      .margin({ top: 3 })
      .maxLines(1)
  }
  .layoutWeight(1)
  .height('100%')
  .justifyContent(FlexAlign.Center)
  .onClick(() => {
    if (page !== active) {
      // 从首页进子页用 push（保留首页在栈底，back 能回首页）；
      // 子页之间切换用 replace（替换当前页，来回点 tab 不堆栈，back 直接回首页）。
      if (active === '') {
        router.pushUrl({ url: page });
      } else {
        router.replaceUrl({ url: page });
      }
    }
  })
}

/** 底部 Tab 栏：5 个入口，触屏拇指热区 */
@Builder
export function PhoneTabBar(active: string) {
  Row() {
    TabItem('点播', 'pages/VodPage', active)
    TabItem('直播', 'pages/LivePage', active)
    TabItem('搜索', 'pages/Search', active)
    TabItem('收藏', 'pages/CollectPage', active)
    TabItem('设置', 'pages/SettingPage', active)
  }
  .width('100%')
  .height(54)
  .padding({ left: 4, right: 4 })
  .backgroundColor(T.SURFACE)
  .border({ width: { top: 1 }, color: '#1FFFFFFF' })
}
