/**
 * 指针类遥控器适配（华为灵犀指向遥控器等「空中鼠标」遥控器）。
 *
 * 背景：灵犀指向遥控器在智慧屏上不是发方向键，而是发**鼠标类指针事件**
 * （移动 → onHover，按下/抬起 → onMouse）。这类设备上焦点系统的行为是
 * 「指针悬停即把焦点移过去」，点击往往被焦点转移吃掉，onClick 不一定触发，
 * 表现就是「指着某个台点下去没有任何反应」。
 *
 * 所以凡是需要「点一下」的热区，除了 onClick 之外再挂一份 onMouse：
 *   .onClick(() => act())
 *   .onMouse(Pointer.pressRelease('label', () => act()))
 * 两边可能同时到达，动作入口用 Pointer.once(key) 做时间窗去重，保证只执行一次。
 *
 * 注意：onMouse 只有指针设备才发；触屏/手机走的还是 onClick，不受影响。
 */

import hilog from '@ohos.hilog';

const DOMAIN: number = 0x1000;
const TAG: string = 'BOXN';
/** 同一热区的重复触发窗口（ms）：鼠标事件与 onClick 常在同一次点击里前后脚到达 */
const DEDUPE_MS: number = 400;

export class Pointer {
  private static lastKey: string = '';
  private static lastAt: number = 0;

  /**
   * 同一个热区在 DEDUPE_MS 内的多次触发只认第一次。
   * 返回 true 表示「这次可以执行」。
   */
  static once(key: string): boolean {
    const now: number = Date.now();
    if (Pointer.lastKey === key && now - Pointer.lastAt < DEDUPE_MS) {
      return false;
    }
    Pointer.lastKey = key;
    Pointer.lastAt = now;
    return true;
  }

  /**
   * 给 onMouse 用的处理器：按下并抬起在同一热区内才算一次点击。
   *
   * 只认 Release 不够 —— 列表拖动、指针划过再抬起都会产生 Release，
   * 会把「拖一下」误判成点击。所以必须见到本元素上的 Press 才认。
   */
  static pressRelease(label: string, act: () => void): (e: MouseEvent) => void {
    let down: boolean = false;
    return (e: MouseEvent): void => {
      if (e.action === MouseAction.Press) {
        down = true;
        hilog.info(DOMAIN, TAG, 'ptr press %{public}s', label);
        return;
      }
      if (e.action === MouseAction.Release) {
        const hit: boolean = down;
        down = false;
        hilog.info(DOMAIN, TAG, 'ptr release %{public}s hit=%{public}s', label, String(hit));
        if (hit) {
          act();
        }
        return;
      }
      if (e.action !== MouseAction.Move) {
        down = false;
      }
    };
  }
}
