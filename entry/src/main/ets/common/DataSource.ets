/**
 * LazyForEach 用的数组数据源。
 *
 * 为什么需要它：`ForEach` 会把**全部**数据一次性建成子组件，几百个频道就是几百个
 * GridItem（每个还带 Text、边框、动画），首屏耗内存也慢；`LazyForEach` 只创建
 * 可视区附近的（配合 Grid 的 cachedCount），滚动时边回收边建。
 *
 * 用法约定：整表替换一律走 `set()`（内部 onDataReloaded）。局部增删没必要——
 * 直播的列表变化（换分组/搜索/收藏/失效标记）本来就是成片变化的，逐条 notify
 * 只会让代码更难维护。
 */
export class ArraySource<T> implements IDataSource {
  private items: T[] = [];
  private listeners: DataChangeListener[] = [];

  /** 换一整批数据 */
  set(next: T[]): void {
    this.items = next;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  /** 当前数据长度（调用方判断空态用，不必再算一遍） */
  size(): number {
    return this.items.length;
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }
}
