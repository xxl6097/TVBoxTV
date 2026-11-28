/**
 * 判定一条直播地址是不是「画面干净」的官方上游，并处理上游抽风时的降级。
 *
 * 背景：同一个 CCTV 频道，不同上游在画面上叠的东西不一样。
 * 咪咕（migu）转发会在右上角烧一组「CCTV. 咪咕视频 / 高清」水印；
 * 央视频（ysp）只有 CCTV 自己的台标和节目角标，画面是干净的。
 * 那层水印是编进画面的像素，播放器、应用都去不掉 —— 唯一的办法是
 * 换一条不带水印的上游。
 *
 * 判据只用 URL 特征、不发请求：
 *   · 命中「干净特征」才把它排到前面；
 *   · 一条都不命中就维持源里的原顺序。
 * 这样不会把不认识的源误降级 —— 宁可不动，也不要因为猜错把能播的源排到后面。
 *
 * 冷却：干净上游并不可靠（央视频对转发的第三方 IP 经常直接 403）。真失败一次
 * 就说明这会儿拉不动，短时间内别再优先它 —— 否则每进一个台都要先黑屏一秒
 * 再回退，比不优化还糟。过了冷却期自动恢复优先，不需要用户干预。
 */

/** 已知画面干净的上游特征（小写比对） */
const CLEAN_HINTS: string[] = [
  'ysp.cctv.cn', // 央视频官方 CDN（CCTV 自己家的流）
  '/relay/ysp', // iFan 把央视频转发成本地路径
  '/ysp/',
];

/** 干净上游失败后的降级时长：5 分钟 */
const CLEAN_COOLDOWN_MS: number = 5 * 60 * 1000;

let cleanCooldownUntil: number = 0;

/** 只看 URL 特征，不管现在的冷却状态（给「失败的这条是不是干净源」用） */
export function hasCleanHint(url: string): boolean {
  if (url.length === 0) {
    return false;
  }
  const u: string = url.toLowerCase();
  for (let i = 0; i < CLEAN_HINTS.length; i++) {
    if (u.indexOf(CLEAN_HINTS[i]) >= 0) {
      return true;
    }
  }
  return false;
}

/** 这条地址现在值不值得优先选：本身干净，且干净上游没在冷却 */
export function isCleanStream(url: string): boolean {
  if (Date.now() < cleanCooldownUntil) {
    return false;
  }
  return hasCleanHint(url);
}

/** 干净上游刚失败：进入冷却，这段时间不再优先它 */
export function markCleanFail(): void {
  cleanCooldownUntil = Date.now() + CLEAN_COOLDOWN_MS;
}

/** 冷却还剩多少毫秒（0 表示没在冷却）。只给日志/诊断用 */
export function cleanCooldownLeftMs(): number {
  const left: number = cleanCooldownUntil - Date.now();
  return left > 0 ? left : 0;
}
