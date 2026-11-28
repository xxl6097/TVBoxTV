/**
 * 「本机解不了这个编码」的线路黑名单（进程内存储，不落盘）。
 *
 * 用它的场景很具体：模拟器和部分老设备没有 HEVC 解码器，而直播源里同一个台
 * 常常按来源拆成多路，编码还不一样 —— iFan 的 CCTV1 就是「央视」分组的
 * migu H.265 和「央视频」分组的 ysp H.264 同名并存。
 *
 * 失败一次就知道哪条线路解不了，记下来下次直接跳过，省掉「先黑屏一秒再换线」
 * 的那一下。不持久化是有意的：换个设备、装个系统更新解码器就可能有了，
 * 不该让一次失败永久否掉一条线路。
 */

const bad: Set<string> = new Set<string>();

/** 记下一条解不了的线路 */
export function markCodecBad(url: string): void {
  if (url.length > 0) {
    bad.add(url);
  }
}

/** 这条线路是不是已经确认本机解不了 */
export function isCodecBad(url: string): boolean {
  return bad.has(url);
}

/** 清空（设置页「重试全部线路」之类的地方可以调） */
export function clearCodecBad(): void {
  bad.clear();
}
