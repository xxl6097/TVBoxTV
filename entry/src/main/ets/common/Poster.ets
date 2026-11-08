import { T } from './Model';

/**
 * 统一的影视封面。
 *
 * 为什么单独抽出来：原来 8 处海报全是裸 `Image(url)`，一处 `.onError` 都没有。
 * 真机上翻到列表深处时封面先是整屏黑块、过十几秒才逐张显形，看起来像渲染崩了；
 * 源站 404 / 防盗链 / 超时的时候那块黑就一直留着，用户以为是卡片坏了。
 *
 * 这里做三件之前没人管的事：
 *  1. 底下永远垫一层「底色 + 淡应用图标」骨架，加载过程中不是纯黑
 *  2. 加载失败退到骨架，不留黑洞
 *  3. 圆角 / 裁剪 / objectFit 统一，不再每页各写一套
 */
@Component
export struct Poster {
  /** 封面地址；空串直接显示骨架 */
  @Prop @Watch('onUrlChanged') url: string = '';
  /** 目标宽度（vp）；0 表示撑满父容器 */
  @Prop w: number = 0;
  /** 目标高度（vp）；0 表示撑满父容器 */
  @Prop h: number = 0;
  /** 上两角圆角 */
  @Prop radius: number = T.RADIUS;
  /** 下两角圆角；-1 表示跟 radius 一致（卡片底部还要接名称条时传 0） */
  @Prop bot: number = -1;
  /** 当前这张图加载失败，退到骨架。换地址时由 @Watch 复位 */
  @State private failed: boolean = false;

  onUrlChanged(): void {
    this.failed = false;
  }

  build() {
    Stack() {
      // 骨架：淡应用图标 + 卡片底色，起「占位」作用而不是装饰
      Image($r('app.media.app_icon'))
        .width('42%')
        .objectFit(ImageFit.Contain)
        .opacity(0.22)

      if (this.url.length > 0 && !this.failed) {
        Image(this.url)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.Medium)
          .onError(() => {
            this.failed = true;
          })
      }
    }
    .width(this.w > 0 ? this.w : '100%')
    .height(this.h > 0 ? this.h : '100%')
    .backgroundColor(T.CARD)
    .clip(true)
    .borderRadius({
      topLeft: this.radius,
      topRight: this.radius,
      bottomLeft: this.bot < 0 ? this.radius : this.bot,
      bottomRight: this.bot < 0 ? this.radius : this.bot
    })
  }
}
