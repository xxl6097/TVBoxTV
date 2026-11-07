/**
 * TV 遥控器焦点适配 —— 公共基础设施。
 *
 * ArkUI 的遥控器焦点「三件套」（接线在各页面，这里只放常量与辅助）：
 *   1. 可交互元素加 .focusable(true)：方向键能聚焦它，聚焦后按 OK/确定 键自动触发它的 onClick。
 *   2. 页面首个可交互元素加 .defaultFocus(true)：进入页面时焦点自动落在这里。
 *   3. 焦点视觉反馈：onFocus/onBlur 驱动与 onHover 相同的高亮状态（鼠标悬停与遥控器焦点并存）。
 *
 * 方向键在可聚焦组件间的移动、焦点跟随滚动到可见，均由 ArkUI 自动完成，无需手写导航。
 * 只有「返回」「菜单」这类全局语义键需要 onKeyEvent 显式处理（用下面的辅助函数判断）。
 */

import { KeyCode } from '@ohos.multimodalInput.keyCode';

/** 是否为「返回」键（遥控器 BACK，键值 2）。页面级 onKeyEvent 里据此决定 pop 或退出 */
export function isBackCode(code: number): boolean {
  return code === KeyCode.KEYCODE_BACK;
}

/** 是否为「菜单」键（部分遥控器右上角菜单键） */
export function isMenuCode(code: number): boolean {
  return code === KeyCode.KEYCODE_MENU;
}
